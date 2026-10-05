import json, re, csv, datetime, os, sys, subprocess, urllib.request

# Uso: python3 processa_ia.py "50 di gasolio, 20 litri di adblue e 2 red bull con carta"
# 1) Divide la frase nelle sue voci (carburante, AdBlue, market): stesso pagamento per tutte.
# 2) Ogni voce si capisce con le regole e il listino (istantaneo).
# 3) Solo una frase di carburante non capita va all'IA (llama-server sulla porta 8080).
# 4) Salva una riga per voce su transazioni_turno.csv, con lo stesso numero di transazione.
#
# Correzioni: python3 processa_ia.py --correggi ultima|penultima "correggi ultima carta 25 euro"

SERVER_URL = 'http://127.0.0.1:8080/completion'
output_path = os.path.expanduser('~/.termux/tasker/output_ia.txt')
prezzi_path = os.path.expanduser('~/prezzi.json')
csv_file = os.path.expanduser('~/transazioni_turno.csv')

CORREZIONE = None
if len(sys.argv) > 3 and sys.argv[1] == '--correggi':
    CORREZIONE = sys.argv[2]            # "ultima" o "penultima"
    sys.argv = [sys.argv[0], sys.argv[3]]
testo_originale = sys.argv[1] if len(sys.argv) > 1 else ""
if not testo_originale.strip():
    print("❌ Nessuna frase ricevuta.")
    sys.exit(1)
testo_basso = testo_originale.lower()


# "trentacinque di verde" -> "35 di verde", così le regole la capiscono senza IA
from numeri import in_cifre
testo_basso = in_cifre(testo_basso)
# Errori tipici del riconoscimento vocale
testo_basso = re.sub(r'\b(\d+):(\d{2})\b', r'\1.\2', testo_basso)                   # "20:10" -> 20.10
testo_basso = re.sub(r'\b(\d+)\s+(\d{2})(?=\s+(?:euro\s+)?d[ie]\b)', r'\1.\2', testo_basso)  # "20 10 di gasolio"
testo_basso = re.sub(r'\b(\d+(?:[.,]\d+)?)\s+ore\b', r'\1 euro', testo_basso)          # "20 ore" -> 20 euro
testo_basso = re.sub(r'\ba\s+buono\b|\babbono\b', 'abbuono', testo_basso)             # "a buono"
testo_basso = re.sub(r'\b(?:ad|add|a\s?d)\s?blu(?:e)?\b', 'adblue', testo_basso)       # "ad blu", "adblu"
testo_basso = re.sub(r'\b(tanica|taniche|litri|litro)\s+di\s+blu(?:e)?\b', r'\1 di adblue', testo_basso)  # "tanica di blu"

# Parole che identificano carburanti e metodi di pagamento
CARBURANTI = {
    'Gasolio': ['gasolio', 'diesel'],
    'Benzina': ['benzina', 'verde', 'senza piombo'],
}
# Metodi di pagamento e caselle del foglio Excel:
#   POS bianco  -> TOTALE PAX BANCARIE (D14)      POS nero -> TOTALE POS BANCA (D12)
#   Petrolifere -> CHIUSURA PETROLIFERE PAX (D9)  POS cassa -> SCONTRINI POS REG. CASSA (S27:V32)
PAGAMENTI = {
    'Petrolifere': ['petrolifera', 'petrolifere', 'carta petrolifera', 'carta carburante', 'carte carburante',
                    'cartissima', 'cartissimo', 'carta cartissima', 'carissima', 'carissimo',
                    'fuel card', 'carta q8'],
    'POS cassa': ['pos cassa', 'pos della cassa', 'pos di cassa', 'pos registratore',
                  'in cassa', 'alla cassa', 'sulla cassa'],
    'POS nero': ['pos nero', 'sul nero', 'col nero', 'con il nero', 'nel nero', 'pagato nero', 'pagato al nero'],
    'POS bianco': ['pos bianco', 'sul bianco', 'col bianco', 'con il bianco', 'nel bianco', 'pagato bianco',
                   'pagato al bianco'],
    'Contanti': ['contanti', 'contante', 'cash'],
}
# Carta senza dire quale POS: si chiede con un popup
PAGAMENTO_GENERICO = ['carta', 'carte', 'pos', 'bancomat', 'credito', 'debito', 'carta di credito']
SCELTA_POS = ['POS cassa', 'POS nero', 'POS bianco', 'Petrolifere']
# Un numero "da solo": non le cifre dentro i codici dei prodotti (q8, h7, 5w-40)
NUMERO = r'(?<![\w-])(\d+(?:[.,]\d+)?)(?![\w-])'

# Listino: {"Red Bull": {"prezzo": 3.0, "alias": ["red bull", "redbull"], "reparto": "Market", "unita": "pz"}}
# (accetta anche il vecchio formato {"redbull": 3.0})
listino = {}
if os.path.exists(prezzi_path):
    try:
        with open(prezzi_path, 'r', encoding='utf-8') as pf:
            for nome, valore in json.load(pf).items():
                if not isinstance(valore, dict):
                    valore = {"prezzo": valore, "alias": [nome.replace('_', ' ')]}
                listino[nome] = valore
    except Exception as e:
        print(f"⚠️ Errore lettura prezzi.json: {e}")


# ---------- riconoscimento (su un pezzo di frase) ----------

def contiene(parola, testo):
    return re.search(r'\b' + re.escape(parola) + r'\b', testo) is not None


def radice(parola):
    # "lampadine"/"lampadina" -> "lampadin", "ghiaccioli"/"ghiacciolo" -> "ghiacciol": così valgono i plurali
    return parola[:-1] if len(parola) > 3 and parola[-1] in 'aeiou' else parola


def radici(testo):
    return " " + " ".join(radice(w) for w in re.findall(r"[\w&'-]+", testo.lower())) + " "


AMBIGUI = []  # prodotti diversi con lo stesso nome detto (es. "lampadina" -> H7, H4...)


def trova_prodotto_listino(testo):
    # Vince il nome/alias più lungo trovato nella frase
    # ("acqua grande" batte "acqua", "lampadina h7" batte "lampadina").
    testo_unito = testo.replace(' ', '')
    testo_radici = radici(testo)
    trovati, lunghezza = [], 0
    for nome, p in listino.items():
        for alias in [nome] + p.get('alias', []):
            alias = alias.lower()
            # Plurali e parole attaccate solo per i nomi lunghi: "ore" non deve diventare "oreo"
            if (contiene(alias, testo)
                    or (len(alias) >= 5 and (radici(alias) in testo_radici
                                             or alias.replace(' ', '') in testo_unito))):
                if len(alias) > lunghezza:
                    trovati, lunghezza = [nome], len(alias)
                elif len(alias) == lunghezza and nome not in trovati:
                    trovati.append(nome)
    if len(trovati) > 1 and len({listino[n]['prezzo'] for n in trovati}) > 1:
        AMBIGUI[:] = trovati      # stesso nome, prezzi diversi: meglio chiedere
        return None
    return trovati[0] if trovati else None


def carburante_detto(testo):
    for nome, parole in CARBURANTI.items():
        if any(contiene(p, testo) for p in parole):
            return nome
    return None


def numero_in_euro(testo):
    # Numero detto insieme a "euro"/"€" (es. "20 euro", "€ 20")
    m = (re.search(NUMERO + r'\s*(?:euro|€)', testo) or re.search(r'€\s*' + NUMERO, testo))
    return float(m.group(1).replace(',', '.')) if m else None


def primo_numero(testo):
    m = re.search(NUMERO, testo)
    return float(m.group(1).replace(',', '.')) if m else None


def senza_prodotti(testo):
    # Toglie i nomi dei prodotti che contengono parole di pagamento ("carta assorbente", "rutten nero")
    for p in listino.values():
        for alias in p.get('alias', []):
            if len(alias.split()) > 1 and contiene(alias.lower(), testo):
                testo = re.sub(r'\b' + re.escape(alias.lower()) + r'\b', ' ', testo)
    return testo


def pagamento_detto(testo):
    """'POS nero', 'Contanti'... se detto; 'chiedi' se solo "carta"/"pos"; None se non detto."""
    testo = senza_prodotti(testo)
    for metodo, parole in PAGAMENTI.items():
        if any(contiene(p, testo) for p in parole):
            return metodo
    if any(contiene(p, testo) for p in PAGAMENTO_GENERICO):
        return 'chiedi'
    return None


def chiedi_pos(scelte=SCELTA_POS):
    """Popup "Pagato con carta: su quale POS?". None se annullato."""
    try:
        r = subprocess.run(['termux-dialog', 'radio', '-t', '💳 Pagato con carta: su quale POS?',
                            '-v', ','.join(scelte)], capture_output=True, text=True, timeout=110)
        d = json.loads(r.stdout or '{}')
    except Exception:
        return None
    if d.get('code') != -1:
        return None
    if d.get('text') in scelte:
        return d['text']
    i = d.get('index')
    return scelte[i] if isinstance(i, int) and 0 <= i < len(scelte) else None


def metodo_pagamento(testo, carburante=False):
    """Metodo della vendita: se è detto solo "carta" chiede quale POS; esce se annullato.
    Con il carburante il POS della cassa non si propone."""
    metodo = pagamento_detto(testo) or 'Contanti'
    if metodo == 'chiedi':
        metodo = chiedi_pos([m for m in SCELTA_POS if not (carburante and m == 'POS cassa')])
        if not metodo:
            print("❌ POS non scelto. Niente salvato: ripeti dicendo \"sul nero\", \"sul bianco\", "
                  "\"in cassa\" o \"petrolifere\".")
            sys.exit(1)
    return metodo


def voce_listino(nome, testo):
    # "2 red bull" = 2 x prezzo; "adblue 20 litri" = 20 x 1,30; "adblue 13 euro" = importo 13
    p = listino[nome]
    prezzo = float(p['prezzo'])
    euro = numero_in_euro(testo)
    if euro is not None:
        importo, quantita = euro, euro / prezzo
    else:
        quantita = primo_numero(testo) or 1.0  # "red bull" da solo = 1
        importo = quantita * prezzo
    return {
        "categoria": nome, "prodotto": nome,
        "reparto": p.get('reparto', 'Market'), "unita": p.get('unita', 'pz'),
        "quantita": round(quantita, 2), "prezzo_unitario": prezzo, "importo": round(importo, 2),
    }


def voce_carburante(testo):
    categoria = carburante_detto(testo)
    importo = numero_in_euro(testo) or primo_numero(testo)
    if not categoria or not importo:
        return None
    return {"categoria": categoria, "reparto": "Carburante", "importo": importo}


PAROLE_SCONTO = r'\b(sconto|sconti|abbuono|abbuonati|abbuonato|arrotondamento|arrotondato)\b'


def voce_sconto(testo):
    # "abbuono 10 centesimi" / "sconto 0,10" / "sconto 2 euro": soldi non incassati (importo negativo)
    m = re.search(NUMERO + r'\s*centesim', testo)
    if m:
        importo = float(m.group(1).replace(',', '.')) / 100
    else:
        importo = numero_in_euro(testo) or primo_numero(testo)
    if not importo:
        return None
    return {"categoria": "Abbuono", "reparto": "Sconto", "importo": -round(importo, 2),
            "metodo_pagamento": "Contanti"}


# Il contrario dell'abbuono: il cliente lascia qualche centesimo (contanti in più nel cassetto)
PAROLE_RESTO = r'\b(lasciat\w*|lascia|eccedenz\w*)\b'


def voce_resto(testo):
    v = voce_sconto(testo)
    if not v:
        return None
    return {"categoria": "Resto lasciato dal cliente", "reparto": "Resto lasciato",
            "importo": -v['importo'], "metodo_pagamento": "Contanti"}


def voce_danea(testo):
    """"danea 15 euro", "danea caricabatterie 15 euro", "danea red bull 3 e 50":
    prodotto market con l'importo detto (non nel listino, o prezzo cambiato)."""
    t = re.sub(r'\bdanea\b', ' ', testo)
    prodotto = trova_prodotto_listino(t)
    AMBIGUI.clear()                      # col nome generico va bene lo stesso: decide l'importo detto
    numeri = [float(n.replace(',', '.')) for n in re.findall(NUMERO, t)]
    importo = numero_in_euro(t) or (numeri[-1] if numeri else None)
    if not importo:
        return None
    altri = [n for n in numeri if n != importo]
    quantita = altri[0] if altri and altri[0] == int(altri[0]) and altri[0] < 50 else 1
    if not prodotto:
        resto = re.sub(NUMERO, ' ', senza_prodotti(t))
        for parole in list(PAGAMENTI.values()) + [PAGAMENTO_GENERICO]:
            for p in sorted(parole, key=len, reverse=True):
                resto = re.sub(r'\b' + re.escape(p) + r'\b', ' ', resto)
        resto = re.sub(PAROLE_CREDITO, ' ', resto)
        parole_nome = [w for w in re.findall(r"[\w'&.-]+", resto) if not w.isdigit()]
        prodotto = " ".join(parole_nome).upper() or "DANEA (a mano)"
    return {"categoria": prodotto, "prodotto": prodotto, "reparto": "Market", "unita": "pz",
            "quantita": quantita, "prezzo_unitario": round(importo / quantita, 2),
            "importo": round(importo, 2), "danea_a_mano": True}


def voce(testo):
    """Una voce della vendita, o None se il pezzo di frase non si capisce."""
    if re.search(r'\bdanea\b', testo):
        return voce_danea(testo)
    if re.search(PAROLE_RESTO, testo):
        return voce_resto(testo)
    if re.search(PAROLE_SCONTO, testo):
        return voce_sconto(testo)
    prodotto = trova_prodotto_listino(testo)
    if prodotto:
        return voce_listino(prodotto, testo)
    return voce_carburante(testo)


def ha_voce(testo):
    return bool(re.search(r'\bdanea\b', testo) or re.search(PAROLE_SCONTO, testo) or re.search(PAROLE_RESTO, testo) or trova_prodotto_listino(testo) or carburante_detto(testo))


def dividi_in_pezzi(testo):
    # "50 gasolio, 20 litri adblue e 2 red bull" -> 3 pezzi.
    # Centesimi: "20 e 50" / "20 virgola 50" / "20,50" -> 20.50
    testo = re.sub(r'(\d+)\s*virgola\s*(\d+)', r'\1.\2', testo)
    # "19.90 di gasolio ha lasciato 10 centesimi" -> "19.90 di gasolio, ha lasciato 10 centesimi"
    testo = re.sub(r'\s+(?=(?:(?:mi\s+)?ha\s+)?(?:lasciat|lascia\b|abbuon|sconto\b|arrotond|eccedenz))', ', ', testo)
    grezzi = [p.strip() for p in re.split(r',(?!\d)|\s+e\s+|\s+ed\s+|\s+più\s+|\s+poi\s+', testo) if p.strip()]

    # 1) "20 e 50 di gasolio", "gasolio 20 euro e 50" -> centesimi,
    #    ma non "gasolio 50 e 20 litri di adblue" (lì sono due voci diverse)
    uniti = []
    for p in grezzi:
        fine = re.search(r'(\d+)(\s*(?:euro|€))?$', uniti[-1]) if uniti else None
        cent = re.match(r'(\d{2})\b(.*)$', p)
        if fine and cent and not (ha_voce(uniti[-1]) and ha_voce(p)):
            prima = uniti[-1][:fine.start()]
            uniti[-1] = f"{prima}{fine.group(1)}.{cent.group(1)}{fine.group(2) or ''}{cent.group(2)}"
        else:
            uniti.append(p)

    # 2) Un pezzo senza prodotto ("con carta", un numero da solo) resta attaccato al vicino
    pezzi, sospesi = [], []
    for p in uniti:
        if ha_voce(p):
            pezzi.append(" e ".join(sospesi + [p]))
            sospesi = []
        elif pezzi and not re.search(r'\d', p):
            pezzi[-1] += " " + p
        else:
            sospesi.append(p)
    if sospesi:
        if pezzi:
            pezzi[-1] += " e " + " e ".join(sospesi)
        else:
            pezzi.append(" e ".join(sospesi))
    return pezzi or [testo]


# ---------- IA: solo per una frase di carburante non capita ----------

SISTEMA = (
    "Sei il registratore di cassa di un distributore Q8. "
    "Dalla frase dell'operatore estrai: categoria (Benzina o Gasolio; "
    "verde e senza piombo sono Benzina, diesel è Gasolio), "
    "e importo (numero in euro, es. venti -> 20). Rispondi solo con il JSON."
)

SCHEMA = {
    "type": "object",
    "properties": {
        "categoria": {"type": "string", "enum": ["Benzina", "Gasolio"]},
        "importo": {"type": "number"},
    },
    "required": ["categoria", "importo"],
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


def descrivi(v):
    if 'quantita' not in v:
        return f"{v['categoria']} {v['importo']} €"
    unita = {'l': ' l', 'fogli': ' foglio' if v['quantita'] == 1 else ' fogli'}.get(v['unita'], ' ×')
    q = f"{v['quantita']:g}{unita}"
    return f"{q} {v['categoria']} {v['importo']} €"



CARBURANTE_IN_CASSA = ("❌ Il carburante non si paga sul POS della cassa: ridillo \"sul nero\" o \"sul bianco\". "
                       "Niente salvato.")


def avviso_ricevuta(voci, metodo):
    # Pagato sul POS della cassa: lo scontrino va stampato dal registratore
    if metodo != 'POS cassa':
        return
    importo_ricevuta = sum(float(v['importo']) for v in voci)
    print(f"🧾 STAMPARE RICEVUTA ({importo_ricevuta:.2f} €)")
    try:
        subprocess.Popen(['termux-notification', '--id', 'stampa_ricevuta', '--priority', 'max',
                          '--title', f'🧾 STAMPARE RICEVUTA {importo_ricevuta:.2f} €',
                          '--content', f"{' + '.join(descrivi(v) for v in voci)} - {metodo}",
                          '--vibrate', '300,150,300,150,300'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        # Finestra in mezzo allo schermo: resta finché non premi OK (non blocca la cassa)
        subprocess.Popen(['termux-dialog', 'confirm', '-t', f'🧾 STAMPARE RICEVUTA {importo_ricevuta:.2f} €'.replace('.', ','),
                          '-i', ' + '.join(descrivi(v) for v in voci)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def correggi(quale):
    """"correggi ultima sul nero" / "correggi penultima 25 euro" / "correggi ultima gasolio"."""
    with open(csv_file, encoding='utf-8') as f:
        tutte = list(csv.reader(f))
    intestazione, righe = tutte[:1], [r for r in tutte[1:] if len(r) >= 2 and r[1].strip()]
    # righe raggruppate per transazione (una vendita mista ha più righe)
    gruppi = []
    for indice, r in enumerate(righe):
        num = json.loads(r[1]).get('transazione')
        if num and gruppi and gruppi[-1][0] == num:
            gruppi[-1][1].append(indice)
        else:
            gruppi.append((num, [indice]))
    posizione = -2 if quale == 'penultima' else -1
    if len(gruppi) < -posizione:
        print(f"❌ Non c'è una {quale} vendita da correggere.")
        sys.exit(1)
    indici = gruppi[posizione][1]
    voci = [json.loads(righe[k][1]) for k in indici]
    prima = " + ".join(descrivi(v) for v in voci) + f" - {voci[0].get('metodo_pagamento')}"

    nuovo_metodo = pagamento_detto(senza_parole_credito(testo_basso))
    if nuovo_metodo == 'chiedi':
        nuovo_metodo = metodo_pagamento(testo_basso)
    nuovo_carburante = carburante_detto(testo_basso)
    nuovo_importo = numero_in_euro(testo_basso) or primo_numero(testo_basso)
    if not (nuovo_metodo or nuovo_carburante or nuovo_importo):
        print("❓ Cosa devo correggere? Es. \"correggi ultima sul nero\", \"correggi ultima 25 euro\", "
              "\"correggi ultima gasolio\". Niente cambiato.")
        sys.exit(1)
    if any(v.get('reparto') == 'Anticipo' for v in voci):
        print("❌ L'anticipo Cartissima non si corregge: \"cancella ultima\" e ridillo. Niente cambiato.")
        sys.exit(1)
    if nuovo_metodo and voci[0].get('reparto') == 'Credito cliente':
        print("❌ Un credito cliente non ha pagamento. Niente cambiato.")
        sys.exit(1)
    if (nuovo_carburante or nuovo_importo) and len(voci) > 1:
        print("❌ È una vendita mista: posso cambiare solo il pagamento. "
              "Per il resto cancellala e ridettala. Niente cambiato.")
        sys.exit(1)

    if nuovo_metodo == 'POS cassa' and any(v.get('reparto') == 'Carburante' for v in voci):
        print(CARBURANTE_IN_CASSA.replace("ridillo", "correggi").replace("Niente salvato", "Niente cambiato"))
        sys.exit(1)
    for v in voci:
        if nuovo_metodo:
            v['metodo_pagamento'] = nuovo_metodo
        if nuovo_carburante:
            if v.get('reparto') != 'Carburante':
                print("❌ Non è un rifornimento: non posso cambiarlo in carburante. Niente cambiato.")
                sys.exit(1)
            v['categoria'] = nuovo_carburante
        if nuovo_importo:
            v['importo'] = f"{nuovo_importo:.2f}"
            if v.get('prezzo_unitario'):
                v['quantita'] = round(nuovo_importo / float(v['prezzo_unitario']), 2)
        v['note'] = (v.get('note', '') + f" [corretta: {testo_originale}]").strip()
    for k, v in zip(indici, voci):
        righe[k] = [righe[k][0], json.dumps(v), float(v['importo'])]

    tmp = csv_file + '.tmp'
    with open(tmp, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerows(intestazione + righe)
    os.replace(tmp, csv_file)

    dopo = " + ".join(descrivi(v) for v in voci) + f" - {voci[0]['metodo_pagamento']}"
    print(f"✏️ Corretta la {quale} vendita:\n   prima: {prima}\n   ora:   {dopo}")
    if nuovo_metodo:
        avviso_ricevuta(voci, nuovo_metodo)
    sys.exit(0)


# ---------- salvataggio: una riga per voce, stesso numero di transazione ----------
def salva_voci(voci, pezzi, metodo):
    adesso = datetime.datetime.now()
    transazione = adesso.strftime('%Y%m%d%H%M%S%f')
    try:
        file_exists = os.path.isfile(csv_file)
        with open(csv_file, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(['data_ora', 'dettagli_json', 'importo'])
            for v, pezzo in zip(voci, pezzi if len(voci) == len(pezzi) else [testo_basso] * len(voci)):
                v.update({"metodo_pagamento": v.get('metodo_pagamento') or metodo, "transazione": transazione,
                          "note": testo_originale if len(voci) == 1 else pezzo,
                          "importo": f"{float(v['importo']):.2f}"})
                writer.writerow([adesso.strftime('%Y-%m-%d %H:%M:%S'), json.dumps(v), float(v['importo'])])
    except Exception as e:
        print('❌ Errore fatale nel salvataggio:', e)
        sys.exit(1)


# ---------- crediti clienti, crediti riscossi, anticipo contanti con Cartissima ----------
# Non sono vendite: vanno nelle caselle CREDITI CLIENTI / CREDITI RISCOSSI e nelle PETROLIFERE.

PAROLE_CREDITO = r'\b(crediti|credito|clienti|cliente|riscoss\w*|riscossione|anticip\w*|contanti|contante|' \
                 r'cartissim\w|petrolifer\w|euro|di|da|del|dal|della|a|al|alla|per|il|la|lo|e|ed|con|col|' \
                 r'pagato|pagata|pagati|ha|ho|dato|dati|q8|carta|carburante|sul|sulla|in|cassa|nero|bianco|pos)\b'


def senza_parole_credito(testo):
    return re.sub(r'\b(crediti|credito|clienti|cliente|riscoss\w*|riscossione)\b', ' ', testo)


def nome_cliente(testo):
    """"credito cliente rossi mario 50 euro" -> "Rossi Mario"."""
    testo = re.sub(NUMERO, ' ', testo)
    testo = re.sub(PAROLE_CREDITO, ' ', testo)
    parole = re.findall(r"[\w'&.-]+", testo)
    return " ".join(p.capitalize() for p in parole if not p.isdigit()) or None


def tipo_speciale(testo):
    if re.search(r'\banticip', testo):
        return 'anticipo'
    if re.search(r'\briscoss', testo):
        return 'riscosso'
    if re.search(r'\b(credito|crediti)\s+(al\s+|a\s+)?client|\ba credito\b', testo):
        return 'credito'
    return None


def registra_speciale(tipo):
    importo = numero_in_euro(testo_basso) or primo_numero(testo_basso)
    if not importo or importo <= 0:
        print(f"❓ Manca l'importo: \"{testo_originale}\". Niente salvato.")
        sys.exit(1)
    if tipo == 'anticipo':
        # Pagato con Cartissima come gasolio senza rifornimento: il cliente riceve i contanti
        voci = [{"categoria": "Anticipo Cartissima", "reparto": "Anticipo", "importo": importo,
                 "metodo_pagamento": "Petrolifere"},
                {"categoria": "Contanti dati al cliente", "reparto": "Anticipo", "importo": -importo,
                 "metodo_pagamento": "Contanti"}]
        salva_voci(voci, [testo_basso] * 2, 'Petrolifere')
        print(f"✅ Anticipo Cartissima: {importo:.2f} € sulle petrolifere, {importo:.2f} € tolti dai contanti")
        sys.exit(0)
    cliente = nome_cliente(testo_basso)
    if tipo == 'credito':
        # Il cliente non paga ora: nessun incasso
        voce_c = {"categoria": f"Credito cliente {cliente or '?'}", "reparto": "Credito cliente",
                  "cliente": cliente or "", "importo": importo, "metodo_pagamento": "Credito"}
        salva_voci([voce_c], [testo_basso], 'Credito')
        titolo = "Credito cliente"
    else:
        # Il cliente paga un vecchio credito: incasso con il metodo detto (contanti se non detto)
        metodo = metodo_pagamento(senza_parole_credito(testo_basso))
        voce_c = {"categoria": f"Credito riscosso {cliente or '?'}", "reparto": "Credito riscosso",
                  "cliente": cliente or "", "importo": importo, "metodo_pagamento": metodo}
        salva_voci([voce_c], [testo_basso], metodo)
        titolo = f"Credito riscosso ({metodo})"
        avviso_ricevuta([voce_c], metodo)
    if not cliente:
        print(f"⚠️ {titolo}: {importo:.2f} € salvato SENZA NOME: scrivilo a mano nell'Excel "
              "(oppure \"cancella ultima\" e ridillo con il nome)")
        sys.exit(2)
    print(f"✅ {titolo}: {cliente} {importo:.2f} €")
    sys.exit(0)


if CORREZIONE:
    correggi(CORREZIONE)

if tipo_speciale(testo_basso):
    registra_speciale(tipo_speciale(testo_basso))


# ---------- programma ----------

pezzi = dividi_in_pezzi(testo_basso)
voci = [voce(p) for p in pezzi]
origine = 'regole'

if AMBIGUI:
    print(f"❓ Quale prodotto? {', '.join(AMBIGUI[:6])}{' …' if len(AMBIGUI) > 6 else ''}. "
          "Ripeti con il nome completo. Niente salvato.")
    sys.exit(1)

if len(pezzi) > 1 and None in voci:
    # Vendita mista con un pezzo non capito: meglio ridettare che salvare a metà
    non_capiti = ", ".join(f'"{p}"' for p, v in zip(pezzi, voci) if v is None)
    print(f"❓ Non ho capito: {non_capiti}. Niente salvato, ripeti la vendita.")
    sys.exit(1)

if voci == [None]:
    # Senza un numero nella frase l'importo non si può sapere: non salviamo nulla
    # (evita che l'IA inventi importi, es. "apertura turno")
    numeri_detti = [float(n.replace(',', '.')) for n in re.findall(NUMERO, testo_basso)]
    if not numeri_detti:
        print(f"❓ Non ho capito \"{testo_originale}\": nessun importo. Niente salvato.")
        sys.exit(1)

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

    if data and data.get('categoria') in CARBURANTI:
        voci = [{"categoria": data['categoria'], "reparto": "Carburante", "importo": importo_ia}]
    else:
        # Ultimo tentativo d'emergenza: numero nella frase + parole chiave
        voci = [{"categoria": "Gasolio" if "gasolio" in testo_basso else "Benzina",
                 "reparto": "Carburante", "importo": numero_in_euro(testo_basso) or numeri_detti[0]}]
        origine = 'emergenza'

if any(float(v['importo']) <= 0 for v in voci if v['reparto'] != 'Sconto'):
    print("❌ Transazione scartata: Nessun importo valido rilevato.")
    sys.exit(1)


# Pagamento: chiesto solo ora, a vendita capita (popup se è detto solo "carta")
metodo = metodo_pagamento(testo_basso, carburante=any(v['reparto'] == 'Carburante' for v in voci))
if metodo == 'POS cassa' and any(v['reparto'] == 'Carburante' for v in voci):
    print(CARBURANTE_IN_CASSA)
    sys.exit(1)
salva_voci(voci, pezzi, metodo)
totale = sum(float(v['importo']) for v in voci)
simbolo = '⚠️' if origine == 'emergenza' else '✅'
if len(voci) == 1:
    print(f"{simbolo} Vendita salvata ({origine}): {descrivi(voci[0])} - {metodo}")
else:
    print(f"{simbolo} Vendita salvata ({len(voci)} voci, {metodo}): "
          + " + ".join(descrivi(v) for v in voci) + f" = {totale:.2f} €")

avviso_ricevuta(voci, metodo)

# Rifornimento oltre il massimo normale (camion ~1000 €): forse "19 90" capito come 1990
IMPORTO_MASSIMO_CARBURANTE = 1200
if any(v['reparto'] == 'Carburante' and float(v['importo']) > IMPORTO_MASSIMO_CARBURANTE for v in voci):
    print(f"⚠️ Importo molto alto: controlla! Se è sbagliato: \"cancella ultima\" e ridilla.")
    sys.exit(2)

# Codice d'uscita letto da avvia_ia.sh per scegliere la vibrazione: 2 = salvata ma da controllare
sys.exit(2 if origine == 'emergenza' else 0)
