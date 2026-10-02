import json, re, csv, datetime, os, sys, subprocess, urllib.request

# Uso: python3 processa_ia.py "20 euro di gasolio con carta"
# 1) Prova a capire la frase con le regole (istantaneo).
# 2) Solo se non ci riesce chiede all'IA (llama-server sulla porta 8080).
# 3) Applica il listino prezzi.json e salva su transazioni_turno.csv.

SERVER_URL = 'http://127.0.0.1:8080/completion'
output_path = os.path.expanduser('~/.termux/tasker/output_ia.txt')
prezzi_path = os.path.expanduser('~/prezzi.json')
csv_file = os.path.expanduser('~/transazioni_turno.csv')

testo_originale = sys.argv[1] if len(sys.argv) > 1 else ""
if not testo_originale.strip():
    print("❌ Nessuna frase ricevuta.")
    sys.exit(1)
testo_basso = testo_originale.lower()


def numeri_in_lettere():
    # Costruisce {"venti": 20, "trentacinque": 35, "centoventi": 120, ...} da 1 a 999
    unita = ['', 'uno', 'due', 'tre', 'quattro', 'cinque', 'sei', 'sette', 'otto', 'nove']
    dieci_19 = ['dieci', 'undici', 'dodici', 'tredici', 'quattordici', 'quindici',
                'sedici', 'diciassette', 'diciotto', 'diciannove']
    decine = ['venti', 'trenta', 'quaranta', 'cinquanta', 'sessanta', 'settanta', 'ottanta', 'novanta']
    parole = {}
    for n in range(1, 100):
        if n < 10:
            nomi = [unita[n]]
        elif n < 20:
            nomi = [dieci_19[n - 10]]
        else:
            d, u = decine[n // 10 - 2], unita[n % 10]
            nomi = [d[:-1] + u if u in ('uno', 'otto') else d + u]
            if u == 'tre':
                nomi.append(d + 'tré')
        for nome in nomi:
            parole[nome] = n
    for c in range(1, 10):
        cento = 'cento' if c == 1 else unita[c] + 'cento'
        parole[cento] = c * 100
        for nome, n in list(parole.items()):
            if n < 100:
                parole[cento + nome] = c * 100 + n
                if nome.startswith('o'):
                    parole[cento[:-1] + nome] = c * 100 + n  # centotto
    return parole


# "trentacinque di verde" -> "35 di verde", così le regole la capiscono senza IA
_NUMERI = numeri_in_lettere()
testo_basso = re.sub(r'\b(' + '|'.join(sorted(_NUMERI, key=len, reverse=True)) + r')\b',
                     lambda m: str(_NUMERI[m.group(1)]), testo_basso)

# Parole che identificano carburanti e metodi di pagamento
CARBURANTI = {
    'Gasolio': ['gasolio', 'diesel'],
    'Benzina': ['benzina', 'verde', 'senza piombo'],
    'AdBlue': ['adblue', 'ad blue'],
}
PAGAMENTI = {
    'Carta': ['carta', 'credito'],
    'POS': ['pos'],
    'Bancomat': ['bancomat'],
    'Contanti': ['contanti', 'cash'],
}

listino = {}
if os.path.exists(prezzi_path):
    try:
        with open(prezzi_path, 'r', encoding='utf-8') as pf:
            listino = json.load(pf)
    except Exception as e:
        print(f"⚠️ Errore lettura prezzi.json: {e}")


def contiene(parola):
    return re.search(r'\b' + re.escape(parola) + r'\b', testo_basso) is not None


def trova_prodotto_listino():
    # Sceglie il prodotto con più parole presenti nella frase
    # ("acqua grande" batte "acqua piccola" se hai detto "grande").
    testo_unito = testo_basso.replace(' ', '')
    migliore, punti_migliori = None, 0
    for prod_key in listino:
        parole = prod_key.split('_')
        punti = sum(1 for p in parole if contiene(p) or p in testo_unito)
        if punti > punti_migliori:
            migliore, punti_migliori = prod_key, punti
    return migliore


def trova_numero():
    # Prima cerca un numero vicino a "euro"/"€" (così "pompa 3, 20 euro" dà 20), poi il primo numero
    m = (re.search(r'(\d+(?:[.,]\d+)?)\s*(?:euro|€)', testo_basso)
         or re.search(r'€\s*(\d+(?:[.,]\d+)?)', testo_basso)
         or re.search(r'(\d+(?:[.,]\d+)?)', testo_basso))
    return m.group(1).replace(',', '.') if m else None


def metodo_pagamento():
    for metodo, parole in PAGAMENTI.items():
        if any(contiene(p) for p in parole):
            return metodo
    return 'Contanti'


# --- PASSO 1: regole veloci, senza IA ---
def carburante_detto():
    for nome, parole in CARBURANTI.items():
        if any(contiene(p) for p in parole):
            return nome
    return None


def analisi_veloce():
    numero = trova_numero()
    if not numero:
        return None
    categoria = carburante_detto()
    if not categoria and trova_prodotto_listino():
        categoria = 'Listino'
    if not categoria:
        return None
    return {"categoria": categoria, "metodo_pagamento": metodo_pagamento(), "importo": numero}


# --- PASSO 2: IA, solo se le regole non bastano ---
SISTEMA = (
    "Sei il registratore di cassa di un distributore Q8. "
    "Dalla frase dell'operatore estrai: categoria (prodotto, es. Benzina, Gasolio, AdBlue; "
    "verde e senza piombo sono Benzina, diesel è Gasolio), "
    "metodo_pagamento (Contanti, Carta, POS o Bancomat; se non detto: Contanti) "
    "e importo (numero in euro, es. venti -> 20). Rispondi solo con il JSON."
)

SCHEMA = {
    "type": "object",
    "properties": {
        "categoria": {"type": "string"},
        "metodo_pagamento": {"type": "string", "enum": ["Contanti", "Carta", "POS", "Bancomat"]},
        "importo": {"type": "number"},
    },
    "required": ["categoria", "metodo_pagamento", "importo"],
}


def analisi_ia():
    # Formato chat di Qwen: la parte fissa resta identica a ogni richiesta,
    # così il server la tiene in cache e rilegge solo la frase nuova.
    prompt = (
        f"<|im_start|>system\n{SISTEMA}<|im_end|>\n"
        f"<|im_start|>user\n{testo_originale}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )
    richiesta = {
        "prompt": prompt,
        "n_predict": 60,
        "temperature": 0.0,
        "cache_prompt": True,
        "json_schema": SCHEMA,
    }
    req = urllib.request.Request(
        SERVER_URL,
        data=json.dumps(richiesta).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            risposta = json.loads(r.read().decode('utf-8'))
    except Exception:
        # Server spento: lo avviamo per la prossima volta, ma questa vendita NON la salviamo
        # (meglio ridettarla che registrare un importo inventato)
        subprocess.Popen(['bash', os.path.expanduser('~/.termux/tasker/avvia_server.sh')],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        print("❌ IA spenta: la sto avviando. Ripeti la vendita tra 30 secondi.")
        sys.exit(1)

    testo = risposta.get('content', '')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(testo)
    t = risposta.get('timings', {})
    with open(os.path.expanduser('~/debug_tasker.log'), 'a') as f:
        f.write(f"   IA: prompt {t.get('prompt_n')} token in {t.get('prompt_ms', 0):.0f} ms, "
                f"risposta {t.get('predicted_n')} token in {t.get('predicted_ms', 0):.0f} ms\n")

    matches = re.findall(r'\{.*?\}', testo, re.DOTALL)
    if not matches:
        return None
    try:
        return json.loads(matches[-1])
    except Exception:
        return None


# Senza un numero nella frase l'importo non si può sapere: non salviamo nulla
# (evita che l'IA inventi importi, es. "apertura turno")
numeri_detti = [float(n.replace(',', '.')) for n in re.findall(r'\d+(?:[.,]\d+)?', testo_basso)]
if not numeri_detti:
    print(f"❓ Non ho capito \"{testo_originale}\": nessun importo. Niente salvato.")
    sys.exit(1)

data = analisi_veloce()
origine = 'regole'
if data is None:
    data = analisi_ia()
    origine = 'IA'
    # L'importo dato dall'IA deve essere uno dei numeri detti, altrimenti se l'è inventato
    try:
        importo_ia = float(str(data.get('importo')).replace(',', '.')) if data else None
    except ValueError:
        importo_ia = None
    if data and importo_ia not in numeri_detti:
        print(f"❓ Non sono sicuro di \"{testo_originale}\": ripeti più chiaramente. Niente salvato.")
        sys.exit(1)
    # Se nella frase c'è una parola chiara (verde, diesel...), vale più dell'IA
    if data and carburante_detto():
        data['categoria'] = carburante_detto()

# Ultimo tentativo d'emergenza: numero nella frase + parole chiave
if not data or 'importo' not in data:
    numero = trova_numero()
    data = {
        "categoria": "Gasolio" if "gasolio" in testo_basso else "Benzina",
        "metodo_pagamento": metodo_pagamento(),
        "importo": numero or "0",
    }
    origine = 'emergenza'

data['note'] = testo_originale

# --- INTEGRAZIONE LISTINO PREZZI.JSON: quantità x prezzo unitario ---
prod_key = trova_prodotto_listino()
if prod_key:
    qta = trova_numero()
    if qta:
        data['importo'] = f"{float(qta) * float(listino[prod_key]):.2f}"
        data['categoria'] = prod_key.replace('_', ' ').title()
# ----------------------------------------

try:
    importo_numerico = re.sub(r'[^0-9.]', '', str(data.get('importo', '0')))

    if not importo_numerico or float(importo_numerico) == 0:
        print("❌ Transazione scartata: Nessun importo valido rilevato.")
        sys.exit(1)

    now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    file_exists = os.path.isfile(csv_file)
    with open(csv_file, 'a', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(['data_ora', 'dettagli_json', 'importo'])
        writer.writerow([now, json.dumps(data), float(importo_numerico)])

    simbolo = '⚠️' if origine == 'emergenza' else '✅'
    print(f"{simbolo} Vendita salvata ({origine}): {data['categoria']} {float(importo_numerico):.2f} € - {data['metodo_pagamento']}")
except Exception as e:
    print('❌ Errore fatale nel salvataggio:', e)
    sys.exit(1)

# Codice d'uscita letto da avvia_ia.sh per scegliere la vibrazione: 2 = salvata ma da controllare
sys.exit(2 if origine == 'emergenza' else 0)
