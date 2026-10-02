# Copia di sicurezza dei file attuali (solo la prima volta: le copie .vecchio non vengono sovrascritte)
for f in ~/.termux/tasker/avvia_ia.sh ~/.termux/tasker/avvia_server.sh ~/.termux/tasker/processa_ia.py ~/info_turno.py; do [ -f "$f" ] && [ ! -f "$f.vecchio" ] && cp "$f" "$f.vecchio"; done
cat > ~/.termux/tasker/avvia_ia.sh <<'FINE_FILE'
#!/bin/bash
# Unico punto d'ingresso da Tasker: riceve tutto quello che dici.
# Se è un comando (apri turno, cancella ultima, totali...) lo esegue,
# altrimenti lo tratta come una vendita.
# Al termine: notifica aggiornata e vibrazione in base all'esito
#   1 vibrazione corta = tutto ok
#   2 vibrazioni corte = salvato, ma controlla
#   1 vibrazione lunga = errore, niente salvato

CARTELLA=~/.termux/tasker

# Log di debug per Tasker
echo "$(date) - Ricevuto da Tasker: '$1'" >> ~/debug_tasker.log

TESTO="$1"

if [ -z "$TESTO" ] || [[ "$TESTO" == %* ]]; then
  echo "❌ Errore: Testo vocale non valido o variabile Tasker non espansa ($TESTO)" | tee -a ~/debug_tasker.log
  nohup bash $CARTELLA/vibra.sh errore > /dev/null 2>&1 &
  exit 0
fi

FRASE="${TESTO,,}"   # tutto minuscolo
ESITO=0

case "$FRASE" in
  *turno*)
    # Qualsiasi frase con "turno" è un comando, mai una vendita
    if [[ "$FRASE" =~ (apri|apertura|inizio|inizia|avvia|comincia) ]]; then
      echo "🟢 TURNO APERTO"
      python3 ~/info_turno.py apri turno
      bash $CARTELLA/avvia_server.sh
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]]; then
      # Orario del terminale pompe: detto nella frase ("chiusura turno 14:05")
      # oppure inserito nel popup
      ORARIO=""
      if [[ "$FRASE" =~ ([0-9]{1,2})[:.\ ]([0-9]{2}) ]]; then
        ORARIO=$(printf "%02d:%s" "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}")
      else
        ORARIO=$(termux-dialog time -t "Orario chiusura terminale pompe" 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
    m = re.search(r"(\d{1,2}):(\d{2})", d.get("text", ""))
    if d.get("code") == -1 and m:
        print(f"{int(m.group(1)):02d}:{m.group(2)}")
except Exception:
    pass')
      fi
      echo "🔴 TURNO CHIUSO - IA spenta"
      python3 ~/info_turno.py "chiudi turno" "$ORARIO"
      pkill -x llama-server
      termux-wake-unlock
    else
      echo "❓ Comando turno non capito: \"$TESTO\" (di' \"apri turno\" o \"chiudi turno\")"
      ESITO=1
    fi ;;
  *"market"*|*"danea"*|*"negozio"*)
    python3 ~/info_turno.py market ;;
  *"erogazion"*|*"quanto adblue"*|*"quante adblue"*)
    python3 ~/info_turno.py adblue ;;
  *"penultima"*)
    python3 ~/info_turno.py "cancella penultima" ;;
  *"cancella ultima"*|*"elimina ultima"*|*"annulla ultima"*)
    python3 ~/info_turno.py "cancella ultima" ;;
  *"totali"*|*"riepilogo"*)
    python3 ~/info_turno.py totali ;;
  *"ultime"*|*"ultimi"*)
    python3 ~/info_turno.py ultimi ;;
  *"archivio"*|*"storico"*)
    python3 ~/info_turno.py archivio ;;
  *)
    python3 $CARTELLA/processa_ia.py "$TESTO"
    ESITO=$? ;;
esac

case $ESITO in
  0) VIBRAZIONE=ok ;;
  2) VIBRAZIONE=attenzione ;;
  *) VIBRAZIONE=errore ;;
esac

# Vibrazione subito (non in sottofondo: in sottofondo Android poteva bloccarla),
# notifica in sottofondo per non far aspettare Tasker
bash $CARTELLA/vibra.sh $VIBRAZIONE > /dev/null 2>&1
nohup bash $CARTELLA/notifica.sh > /dev/null 2>&1 &

# Sempre 0: l'esito lo comunicano messaggio e vibrazione, così Tasker non interrompe il Task
exit 0
FINE_FILE
cat > ~/.termux/tasker/avvia_server.sh <<'FINE_FILE'
#!/bin/bash
# Avvia llama-server una sola volta, a inizio turno.
termux-wake-lock

# Percorso esplicito del modello: cambia solo questa riga per provare un altro modello.
MODELLO=~/llama.cpp/models/qwen2.5-3b-instruct-q4_k_m.gguf
SERVER_BIN=~/llama.cpp/build/bin/llama-server

# Se il server risponde già, non ne avviamo un secondo (sprecherebbe RAM e CPU)
if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q ok; then
  echo "✅ IA già accesa e pronta"
  exit 0
fi

nohup "$SERVER_BIN" -m "$MODELLO" --host 127.0.0.1 --port 8080 --ctx-size 1024 -t 4 > ~/llama_server.log 2>&1 &
echo "🚀 IA in avvio: pronta tra circa 30 secondi"
FINE_FILE
cat > ~/.termux/tasker/processa_ia.py <<'FINE_FILE'
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
}
PAGAMENTI = {
    'Carta': ['carta', 'credito'],
    'POS': ['pos'],
    'Bancomat': ['bancomat'],
    'Contanti': ['contanti', 'cash'],
}

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


def contiene(parola):
    return re.search(r'\b' + re.escape(parola) + r'\b', testo_basso) is not None


def trova_prodotto_listino():
    # Vince il nome/alias più lungo trovato nella frase
    # ("taniche adblue" batte "adblue", "acqua grande" batte "acqua").
    testo_unito = testo_basso.replace(' ', '')
    migliore, lunghezza = None, 0
    for nome, p in listino.items():
        for alias in [nome] + p.get('alias', []):
            alias = alias.lower()
            if contiene(alias) or (len(alias) >= 5 and alias.replace(' ', '') in testo_unito):
                if len(alias) > lunghezza:
                    migliore, lunghezza = nome, len(alias)
    return migliore


def numero_in_euro():
    # Numero detto insieme a "euro"/"€" (es. "20 euro", "€ 20")
    m = (re.search(r'(\d+(?:[.,]\d+)?)\s*(?:euro|€)', testo_basso)
         or re.search(r'€\s*(\d+(?:[.,]\d+)?)', testo_basso))
    return m.group(1).replace(',', '.') if m else None


def trova_numero():
    # Prima un numero vicino a "euro"/"€" (così "pompa 3, 20 euro" dà 20), poi il primo numero
    m = re.search(r'(\d+(?:[.,]\d+)?)', testo_basso)
    return numero_in_euro() or (m.group(1).replace(',', '.') if m else None)


def vendita_listino(nome):
    # "2 red bull" = 2 x prezzo; "adblue 20 litri" = 20 x 1,30; "adblue 20 euro" = importo 20
    p = listino[nome]
    prezzo = float(p['prezzo'])
    euro = numero_in_euro()
    m = re.search(r'(\d+(?:[.,]\d+)?)', testo_basso)
    if euro:
        importo = float(euro)
        quantita = importo / prezzo
    else:
        quantita = float(m.group(1).replace(',', '.')) if m else 1.0  # "red bull" da solo = 1
        importo = quantita * prezzo
    return {
        "categoria": nome, "prodotto": nome,
        "reparto": p.get('reparto', 'Market'), "unita": p.get('unita', 'pz'),
        "quantita": round(quantita, 2), "prezzo_unitario": prezzo,
        "metodo_pagamento": metodo_pagamento(), "importo": f"{importo:.2f}",
    }


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
    if not categoria:
        return None
    return {"categoria": categoria, "metodo_pagamento": metodo_pagamento(), "importo": numero}


# --- PASSO 2: IA, solo se le regole non bastano ---
SISTEMA = (
    "Sei il registratore di cassa di un distributore Q8. "
    "Dalla frase dell'operatore estrai: categoria (Benzina o Gasolio; "
    "verde e senza piombo sono Benzina, diesel è Gasolio), "
    "metodo_pagamento (Contanti, Carta, POS o Bancomat; se non detto: Contanti) "
    "e importo (numero in euro, es. venti -> 20). Rispondi solo con il JSON."
)

SCHEMA = {
    "type": "object",
    "properties": {
        "categoria": {"type": "string", "enum": ["Benzina", "Gasolio"]},
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
prodotto = trova_prodotto_listino()
if not numeri_detti and not prodotto:
    print(f"❓ Non ho capito \"{testo_originale}\": nessun importo. Niente salvato.")
    sys.exit(1)

if prodotto:
    # Prodotto del listino (market, AdBlue): prezzo noto, niente IA
    data, origine = vendita_listino(prodotto), 'listino'
else:
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
data.setdefault('reparto', 'Carburante')

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
    if origine == 'listino':
        q = data['quantita']
        q_txt = f"{q:g} l" if data['unita'] == 'l' else f"{q:g} ×"
        descrizione = f"{q_txt} {data['categoria']}"
    else:
        descrizione = data['categoria']
    print(f"{simbolo} Vendita salvata ({origine}): {descrizione} {float(importo_numerico):.2f} € - {data['metodo_pagamento']}")
except Exception as e:
    print('❌ Errore fatale nel salvataggio:', e)
    sys.exit(1)

# Codice d'uscita letto da avvia_ia.sh per scegliere la vibrazione: 2 = salvata ma da controllare
sys.exit(2 if origine == 'emergenza' else 0)
FINE_FILE
cat > ~/.termux/tasker/vibra.sh <<'FINE_FILE'
#!/bin/bash
# Vibrazioni diverse a seconda dell'esito (serve Termux:API).
# -f = vibra anche con il telefono in silenzioso
case "$1" in
  ok)         termux-vibrate -f -d 150 ;;
  attenzione) termux-vibrate -f -d 150; sleep 0.4; termux-vibrate -f -d 150 ;;
  errore)     termux-vibrate -f -d 900 ;;
esac
FINE_FILE
cat > ~/.termux/tasker/migra_prezzi.py <<'FINE_FILE'
# Converte ~/prezzi.json dal vecchio formato {"redbull": 3.0}
# al nuovo {"Red Bull": {"prezzo": 3.0, "alias": [...], "reparto": "Market", "unita": "pz"}}.
# Se è già nel nuovo formato non fa nulla.
import json, os, shutil

p = os.path.expanduser('~/prezzi.json')
if os.path.exists(p):
    with open(p, encoding='utf-8') as f:
        vecchio = json.load(f)
    if vecchio and not any(isinstance(v, dict) for v in vecchio.values()):
        shutil.copy(p, p + '.vecchio')
        nuovo = {}
        for chiave, prezzo in vecchio.items():
            nome, alias = chiave.replace('_', ' ').title(), [chiave.replace('_', ' ')]
            reparto, unita = 'Market', 'pz'
            if 'adblue' in chiave:
                reparto = 'AdBlue'
                if 'sfuso' in chiave:
                    nome, unita = 'AdBlue sfuso', 'l'
                    alias = ['adblue', 'ad blue', 'adblue sfuso', 'sfuso']
                elif 'tanica' in chiave:
                    nome = 'AdBlue tanica'
                    alias = ['tanica', 'taniche', 'tanica adblue', 'taniche adblue', 'adblue tanica',
                             'adblue taniche', 'tanica di adblue', 'taniche di adblue']
            elif chiave == 'redbull':
                nome, alias = 'Red Bull', ['red bull', 'redbull']
            nuovo[nome] = {'prezzo': float(prezzo), 'alias': alias, 'reparto': reparto, 'unita': unita}
        with open(p, 'w', encoding='utf-8') as f:
            json.dump(nuovo, f, indent=2, ensure_ascii=False)
        print('🔄 prezzi.json convertito al nuovo formato (copia in prezzi.json.vecchio)')
FINE_FILE
cat > ~/info_turno.py <<'FINE_FILE'
import csv
import json
import os
import sys
from datetime import datetime, timedelta
import shutil
import glob

# Uso: python3 info_turno.py [notifica | ultimi | totali | market | adblue |
#                             apri turno | chiudi turno [HH:MM] |
#                             cancella ultima | cancella penultima | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
PATH_TURNO = os.path.expanduser("~/turno_corrente.json")
CARTELLA_CHIUSURE = os.path.expanduser("~/storage/downloads/Chiusure_Turno")
# Stessa intestazione che scrive processa_ia.py
INTESTAZIONE = ['data_ora', 'dettagli_json', 'importo']
CARBURANTI = ("BENZINA", "GASOLIO")
TURNI = {'Mattina': (6, "06-14"), 'Pomeriggio': (14, "14-22"), 'Notte': (22, "22-06")}


# ---------- lettura e scrittura ----------

def leggi_csv(path=PATH_CSV):
    if not os.path.exists(path):
        return []
    righe = []
    with open(path, mode='r', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader, None)
        for r in reader:
            if len(r) >= 2 and r[1].strip():
                righe.append(r)
    return righe


def scrivi_csv(righe):
    with open(PATH_CSV, mode='w', encoding='utf-8', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(INTESTAZIONE)
        writer.writerows(righe)


def vendita(r):
    """Dati di una riga del CSV, o None se illeggibile."""
    try:
        data = json.loads(r[1])
        cat = str(data.get("categoria", "altro")).replace("_", " ")
        metodo = str(data.get("metodo_pagamento", "altro")).capitalize()
        if metodo == "Pos":
            metodo = "POS"
        reparto = data.get("reparto")
        if not reparto:  # vendite salvate prima dei reparti
            if cat.upper() in CARBURANTI:
                reparto = "Carburante"
            elif "ADBLUE" in cat.upper().replace(" ", ""):
                reparto = "AdBlue"
            else:
                reparto = "Market"
        return {
            "ora": r[0].split()[-1][:5],
            "importo": float(data.get("importo", 0.0)),
            "categoria": cat,
            "metodo": metodo,
            "note": str(data.get("note", "")).strip(),
            "reparto": reparto,
            "quantita": float(data.get("quantita", 1) or 1),
            "unita": data.get("unita", "pz"),
        }
    except Exception:
        return None


def vendite(righe):
    return [v for v in (vendita(r) for r in righe) if v]


def euro(x):
    return f"{x:.2f} €"


# ---------- turno ----------

def tipo_turno(momento):
    """Il turno il cui inizio (6, 14, 22) è più vicino all'orario dato, e la sua data d'inizio."""
    minuti = momento.hour * 60 + momento.minute

    def distanza(nome):
        d = abs(minuti - TURNI[nome][0] * 60)
        return min(d, 1440 - d)

    nome = min(TURNI, key=distanza)
    data_inizio = momento.date()
    if nome == 'Notte' and momento.hour < 12:  # aperto dopo mezzanotte: la notte è iniziata ieri
        data_inizio -= timedelta(days=1)
    return nome, data_inizio


def leggi_turno():
    try:
        with open(PATH_TURNO, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def descrivi_turno(t):
    return f"{t['tipo']} ({TURNI[t['tipo']][1]}) del {t['data']}, aperto alle {t['apertura'][-5:]}"


def apri_turno():
    esistente = leggi_turno()
    if esistente and leggi_csv():
        print(f"ℹ️ Turno già aperto: {descrivi_turno(esistente)}")
        return
    adesso = datetime.now()
    nome, data_inizio = tipo_turno(adesso)
    turno = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": adesso.strftime("%Y-%m-%d %H:%M")}
    with open(PATH_TURNO, 'w', encoding='utf-8') as f:
        json.dump(turno, f)
    print(f"📅 {descrivi_turno(turno)}")


def turno_attuale(righe):
    """Turno aperto a voce; se manca, lo si ricava dalla prima vendita."""
    t = leggi_turno()
    if t:
        return t
    try:
        primo = datetime.strptime(righe[0][0][:16], "%Y-%m-%d %H:%M")
    except Exception:
        primo = datetime.now()
    nome, data_inizio = tipo_turno(primo)
    return {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
            "data_file": data_inizio.isoformat(), "apertura": "(non registrata)"}


# ---------- prospetti ----------

def totali_per(vv, chiave):
    out = {}
    for v in vv:
        out[v[chiave]] = out.get(v[chiave], 0.0) + v["importo"]
    return out


def righe_market(vv):
    """Prodotti del market raggruppati: [(nome, quantità, importo)]."""
    gruppi = {}
    for v in vv:
        if v["reparto"] != "Market":
            continue
        q, imp = gruppi.get(v["categoria"], (0.0, 0.0))
        gruppi[v["categoria"]] = (q + v["quantita"], imp + v["importo"])
    return sorted(((n, q, i) for n, (q, i) in gruppi.items()), key=lambda x: -x[2])


def numero(q):
    return f"{q:g}"


def prospetto_market(vv):
    gruppi = righe_market(vv)
    out = ["🛒 MARKET (Danea)"]
    if not gruppi:
        return out + ["  Nessuna vendita market."]
    for nome, q, imp in gruppi:
        out.append(f"  {numero(q):>3} × {nome:<18} {euro(imp):>10}")
    out.append(f"  {'= Totale market':<24} {euro(sum(i for _, _, i in gruppi)):>10}")
    return out


def prospetto_adblue(vv, dettaglio=True):
    ad = [v for v in vv if v["reparto"] == "AdBlue"]
    out = [f"🧪 ADBLUE ({len(ad)} erogazioni)"]
    if not ad:
        return out + ["  Nessuna erogazione."]
    if dettaglio:
        for v in ad:
            q = f"{v['quantita']:.2f} l" if v["unita"] == "l" else f"{numero(v['quantita'])} ×"
            out.append(f"  • {v['ora']} {q} {v['categoria']} {euro(v['importo'])} ({v['metodo'][:3].upper()})")
    litri = sum(v["quantita"] for v in ad if v["unita"] == "l")
    euro_sfuso = sum(v["importo"] for v in ad if v["unita"] == "l")
    taniche = sum(v["quantita"] for v in ad if v["unita"] != "l")
    euro_taniche = sum(v["importo"] for v in ad if v["unita"] != "l")
    out.append(f"  Sfuso: {litri:.2f} litri erogati ({euro(euro_sfuso)})")
    out.append(f"  Taniche: {numero(taniche)} ({euro(euro_taniche)})")
    return out


def prospetto_completo(righe, titolo):
    vv = vendite(righe)
    totale = sum(v["importo"] for v in vv)
    per_metodo = totali_per(vv, "metodo")
    contanti = per_metodo.get("Contanti", 0.0)
    out = [titolo, "─────────────────────────",
           f"Vendite: {len(vv)}    TOTALE: {euro(totale)}", ""]

    out.append("💳 PER PAGAMENTO")
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<12} {euro(val):>10}")
    out.append(f"  {'= Contanti':<12} {euro(contanti):>10}")
    out.append(f"  {'= Elettronico':<12} {euro(totale - contanti):>10}")
    out.append("")

    out.append("⛽ CARBURANTI")
    carb = {v["categoria"]: 0.0 for v in vv if v["reparto"] == "Carburante"}
    for v in vv:
        if v["reparto"] == "Carburante":
            carb[v["categoria"]] += v["importo"]
    for nome, val in sorted(carb.items()):
        out.append(f"  {nome:<12} {euro(val):>10}")
    out.append(f"  {'= Carburanti':<12} {euro(sum(carb.values())):>10}")
    out.append("")
    out += prospetto_adblue(vv, dettaglio=False)
    out.append("")
    out += prospetto_market(vv)
    return out


def notifica_breve(righe):
    t = leggi_turno()
    intest = f"🕐 {t['tipo']} dalle {t['apertura'][-5:]}" if t else "🕐 Turno non aperto"
    vv = vendite(righe)
    if not vv:
        print(f"📊 Totale: 0.00 € | Vendite: 0  {intest}\n────────────────\nNessuna transazione registrata.")
        return

    totale = sum(v["importo"] for v in vv)
    out = [f"📊 Tot: {euro(totale)} ({len(vv)} vendite)  {intest}"]

    # Carburanti per tipo; AdBlue e Market solo come totale
    parti = []
    for nome, val in totali_per([v for v in vv if v["reparto"] == "Carburante"], "categoria").items():
        parti.append(f"{nome.upper()}: {val:.2f}€")
    for reparto, icona in (("AdBlue", "🧪 ADBLUE"), ("Market", "🛒 MARKET")):
        val = sum(v["importo"] for v in vv if v["reparto"] == reparto)
        if val:
            parti.append(f"{icona}: {val:.2f}€")
    out.append("⛽ " + " | ".join(parti))
    out.append("💳 " + " | ".join(f"{m}: {val:.2f}€" for m, val in totali_per(vv, "metodo").items()))

    out.append("────────────────")
    out.append("🔍 Ultime transazioni:")
    for v in reversed(vv[-5:]):
        if v["reparto"] == "Market":
            descr = "🛒 market"
        else:
            descr = v["note"]
        out.append(f"• {v['ora']} | {v['importo']:.2f}€ ({v['metodo'][:3].upper()}) {descr}")
    print("\n".join(out))


def mostra_archivio():
    pattern = os.path.expanduser("~/turno_archivio_*.csv")
    out = ["📂 STORICO TURNI ARCHIVIATI:", "─────────────────────────"]
    for path_arc in sorted(glob.glob(pattern), reverse=True):
        vv = vendite(leggi_csv(path_arc))
        if not vv:
            continue  # turni vuoti: non li mostriamo
        data_str = os.path.basename(path_arc).replace("turno_archivio_", "").replace(".csv", "").replace("_", " ")
        out.append(f"• 📅 {data_str} | 💰 {euro(sum(v['importo'] for v in vv))} ({len(vv)} vendite)")
    if len(out) == 2:
        print("📭 Nessun turno precedente archiviato.")
        return
    print("\n".join(out))


# ---------- modifiche ----------

def cancella_ultima():
    righe = leggi_csv()
    if not righe:
        print("Totale: 0.00 € | Vendite: 0\nNessuna transazione da cancellare.")
        return
    scrivi_csv(righe[:-1])
    notifica_breve(righe[:-1])


def cancella_penultima():
    righe = leggi_csv()
    if len(righe) < 2:
        print("Servono almeno 2 transazioni.")
        return
    righe_aggiornate = righe[:-2] + [righe[-1]]
    scrivi_csv(righe_aggiornate)
    notifica_breve(righe_aggiornate)


def chiudi_turno(orario_terminale=""):
    righe = leggi_csv()
    if not righe:
        # Niente da archiviare: evita di creare file d'archivio vuoti
        if os.path.exists(PATH_TURNO):
            os.remove(PATH_TURNO)
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna vendita: niente da archiviare.")
        return

    t = turno_attuale(righe)
    adesso = datetime.now()
    testa = [
        "🧾 CHIUSURA TURNO",
        f"Data:      {t['data']}",
        f"Turno:     {t['tipo']} ({TURNI[t['tipo']][1]})",
        f"Apertura:  {t['apertura'][-5:] if t['apertura'][0].isdigit() else t['apertura']}",
        f"Chiusura:  {adesso.strftime('%H:%M')}",
        f"Terminale pompe: {orario_terminale or '(non inserito)'}",
        "",
    ]
    corpo = prospetto_completo(righe, "RIEPILOGO")
    dettaglio = ["", "📋 TUTTE LE VENDITE"] + [
        f"  {v['ora']} {euro(v['importo']):>10} {v['metodo']:<9} {v['note']}" for v in vendite(righe)]
    testo = "\n".join(testa + corpo + dettaglio) + "\n"

    # Documento nella cartella Download/Chiusure_Turno
    salvato = ""
    try:
        os.makedirs(CARTELLA_CHIUSURE, exist_ok=True)
        base = os.path.join(CARTELLA_CHIUSURE, f"{t['data_file']}_{t['tipo']}")
        path_doc = base + ".txt"
        if os.path.exists(path_doc):
            path_doc = f"{base}_{adesso.strftime('%H%M')}.txt"
        with open(path_doc, 'w', encoding='utf-8') as f:
            f.write(testo)
        salvato = f"💾 Salvato in Download/Chiusure_Turno/{os.path.basename(path_doc)}"
    except Exception as e:
        salvato = f"⚠️ Documento non salvato in Download ({e})"

    timestamp_backup = adesso.strftime("%Y-%m-%d_%H-%M-%S")
    shutil.copy(PATH_CSV, os.path.expanduser(f"~/turno_archivio_{timestamp_backup}.csv"))
    scrivi_csv([])
    if os.path.exists(PATH_TURNO):
        os.remove(PATH_TURNO)

    print(testo.split("\n📋")[0])
    print(salvato)


def main():
    comando = " ".join(sys.argv[1:]).lower() if len(sys.argv) > 1 else "notifica"

    if "cancella ultima" in comando or "elimina ultima" in comando:
        cancella_ultima()
    elif "penultima" in comando:
        cancella_penultima()
    elif comando.startswith("apri turno"):
        apri_turno()
    elif "chiudi turno" in comando or "fine turno" in comando or "azzera" in comando:
        orario = sys.argv[2] if len(sys.argv) > 2 else ""
        chiudi_turno(orario)
    elif "archivio" in comando or "storico" in comando:
        mostra_archivio()
    else:
        righe = leggi_csv()
        if comando == "totali":
            print("\n".join(prospetto_completo(righe, "🧾 RIEPILOGO TURNO")))
        elif comando == "market":
            print("\n".join(prospetto_market(vendite(righe))))
        elif comando == "adblue":
            print("\n".join(prospetto_adblue(vendite(righe))))
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
FINE_FILE
# Listino nel nuovo formato (solo se è ancora nel vecchio)
python3 ~/.termux/tasker/migra_prezzi.py
# File di Tasker da importare: li mettiamo nella cartella Download
if [ -d ~/storage/downloads ]; then
cat > ~/storage/downloads/Cassa_Vocale.tsk.xml <<'FINE_FILE'
<TaskerData sr="" dvi="1" tv="6.6.20">
	<Task sr="task90">
		<cdate>1790920000000</cdate>
		<edate>1790920000000</edate>
		<id>90</id>
		<nme>Cassa Vocale</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>548</code>
			<Str sr="arg0" ve="3">🎙️ %avcomm</Str>
			<Int sr="arg1" val="0"/>
			<Str sr="arg10" ve="3"/>
			<Int sr="arg11" val="1"/>
			<Int sr="arg12" val="0"/>
			<Str sr="arg13" ve="3"/>
			<Int sr="arg14" val="0"/>
			<Str sr="arg15" ve="3"/>
			<Int sr="arg2" val="0"/>
			<Str sr="arg3" ve="3"/>
			<Str sr="arg4" ve="3"/>
			<Str sr="arg5" ve="3"/>
			<Str sr="arg6" ve="3"/>
			<Str sr="arg7" ve="3"/>
			<Str sr="arg8" ve="3"/>
			<Int sr="arg9" val="1"/>
		</Action>
		<Action sr="act1" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"%avcomm"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>avvia_ia.sh</com.termux.tasker.extra.EXECUTABLE>
					<com.termux.tasker.extra.EXECUTABLE-type>java.lang.String</com.termux.tasker.extra.EXECUTABLE-type>
					<com.termux.tasker.extra.SESSION_ACTION>&lt;null&gt;</com.termux.tasker.extra.SESSION_ACTION>
					<com.termux.tasker.extra.SESSION_ACTION-type>java.lang.String</com.termux.tasker.extra.SESSION_ACTION-type>
					<com.termux.tasker.extra.STDIN></com.termux.tasker.extra.STDIN>
					<com.termux.tasker.extra.STDIN-type>java.lang.String</com.termux.tasker.extra.STDIN-type>
					<com.termux.tasker.extra.TERMINAL>false</com.termux.tasker.extra.TERMINAL>
					<com.termux.tasker.extra.TERMINAL-type>java.lang.Boolean</com.termux.tasker.extra.TERMINAL-type>
					<com.termux.tasker.extra.VERSION_CODE>1002</com.termux.tasker.extra.VERSION_CODE>
					<com.termux.tasker.extra.VERSION_CODE-type>java.lang.Integer</com.termux.tasker.extra.VERSION_CODE-type>
					<com.termux.tasker.extra.WAIT_FOR_RESULT>true</com.termux.tasker.extra.WAIT_FOR_RESULT>
					<com.termux.tasker.extra.WAIT_FOR_RESULT-type>java.lang.Boolean</com.termux.tasker.extra.WAIT_FOR_RESULT-type>
					<com.termux.tasker.extra.WORKDIR>&lt;null&gt;</com.termux.tasker.extra.WORKDIR>
					<com.termux.tasker.extra.WORKDIR-type>java.lang.String</com.termux.tasker.extra.WORKDIR-type>
					<com.twofortyfouram.locale.intent.extra.BLURB>avvia_ia.sh "%avcomm"

Working Directory ✕
Stdin ✕
Custom Log Level null
Terminal Session ✕
Wait For Result ✓</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES>&lt;StringArray sr=""&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;%stdout
Standard Output
The &amp;lt;B&amp;gt;stdout&amp;lt;/B&amp;gt; of the command.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;%stdout_original_length
Standard Output Original Length
The original length of &amp;lt;B&amp;gt;stdout&amp;lt;/B&amp;gt;.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;%stderr
Standard Error
The &amp;lt;B&amp;gt;stderr&amp;lt;/B&amp;gt; of the command.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;%stderr_original_length
Standard Error Original Length
The original length of &amp;lt;B&amp;gt;stderr&amp;lt;/B&amp;gt;.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES4&gt;%result
Exit Code
The &amp;lt;B&amp;gt;exit code&amp;lt;/B&amp;gt; of the command.0 often means success and anything else is usually a failure of some sort.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES4&gt;&lt;/StringArray&gt;</net.dinglisch.android.tasker.RELEVANT_VARIABLES>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>[Ljava.lang.String;</net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="30"/>
			<Int sr="arg4" val="1"/>
		</Action>
		<Action sr="act2" ve="7">
			<code>548</code>
			<Str sr="arg0" ve="3">%stdout</Str>
			<Int sr="arg1" val="0"/>
			<Str sr="arg10" ve="3"/>
			<Int sr="arg11" val="1"/>
			<Int sr="arg12" val="0"/>
			<Str sr="arg13" ve="3"/>
			<Int sr="arg14" val="0"/>
			<Str sr="arg15" ve="3"/>
			<Int sr="arg2" val="0"/>
			<Str sr="arg3" ve="3"/>
			<Str sr="arg4" ve="3"/>
			<Str sr="arg5" ve="3"/>
			<Str sr="arg6" ve="3"/>
			<Str sr="arg7" ve="3"/>
			<Str sr="arg8" ve="3"/>
			<Int sr="arg9" val="1"/>
		</Action>
	</Task>
</TaskerData>
FINE_FILE
cat > ~/storage/downloads/Continuazione.prf.xml <<'FINE_FILE'
<TaskerData sr="" dvi="1" tv="6.6.20">
	<Profile sr="prof11" ve="2">
		<cdate>1790817319956</cdate>
		<edate>1790820844120</edate>
		<flags>8</flags>
		<id>11</id>
		<mid0>90</mid0>
		<nme>Continuazione</nme>
		<Event sr="con0" ve="2">
			<code>41628340</code>
			<pri>0</pri>
			<Bundle sr="arg0">
				<Vals sr="val">
					<Contains>false</Contains>
					<Contains-type>java.lang.Boolean</Contains-type>
					<LastCommandIdInvert>false</LastCommandIdInvert>
					<LastCommandIdInvert-type>java.lang.Boolean</LastCommandIdInvert-type>
					<LastCommandIdRegex>false</LastCommandIdRegex>
					<LastCommandIdRegex-type>java.lang.Boolean</LastCommandIdRegex-type>
					<NotCancelSearchGoogleNow>false</NotCancelSearchGoogleNow>
					<NotCancelSearchGoogleNow-type>java.lang.Boolean</NotCancelSearchGoogleNow-type>
					<NotOnContinuous>false</NotOnContinuous>
					<NotOnContinuous-type>java.lang.Boolean</NotOnContinuous-type>
					<NotOnNormal>false</NotOnNormal>
					<NotOnNormal-type>java.lang.Boolean</NotOnNormal-type>
					<Precision>&lt;null&gt;</Precision>
					<Precision-type>java.lang.String</Precision-type>
					<ProfileName>&lt;null&gt;</ProfileName>
					<ProfileName-type>java.lang.String</ProfileName-type>
					<Responses>&lt;null&gt;</Responses>
					<Responses-type>java.lang.String</Responses-type>
					<Source>&lt;null&gt;</Source>
					<Source-type>java.lang.String</Source-type>
					<Substitutions>&lt;null&gt;</Substitutions>
					<Substitutions-type>java.lang.String</Substitutions-type>
					<TriggerWord>&lt;null&gt;</TriggerWord>
					<TriggerWord-type>java.lang.String</TriggerWord-type>
					<TriggerWordExact>false</TriggerWordExact>
					<TriggerWordExact-type>java.lang.Boolean</TriggerWordExact-type>
					<TriggerWordRegex>false</TriggerWordRegex>
					<TriggerWordRegex-type>java.lang.Boolean</TriggerWordRegex-type>
					<VariableNames>&lt;null&gt;</VariableNames>
					<VariableNames-type>java.lang.String</VariableNames-type>
					<VariableValues>&lt;null&gt;</VariableValues>
					<VariableValues-type>java.lang.String</VariableValues-type>
					<com.twofortyfouram.locale.intent.extra.BLURB>Easy Commands: *</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<config_easy_commands>*</config_easy_commands>
					<config_easy_commands-type>java.lang.String</config_easy_commands-type>
					<configcommand>&lt;null&gt;</configcommand>
					<configcommand-type>java.lang.String</configcommand-type>
					<configcommandid>&lt;null&gt;</configcommandid>
					<configcommandid-type>java.lang.String</configcommandid-type>
					<configcommandinvert>false</configcommandinvert>
					<configcommandinvert-type>java.lang.Boolean</configcommandinvert-type>
					<configexactsub>false</configexactsub>
					<configexactsub-type>java.lang.Boolean</configexactsub-type>
					<configlastcommand>&lt;null&gt;</configlastcommand>
					<configlastcommand-type>java.lang.String</configlastcommand-type>
					<configregexsub>false</configregexsub>
					<configregexsub-type>java.lang.Boolean</configregexsub-type>
					<net.dinglisch.android.tasker.EXTRA_NSR_DEPRECATED>true</net.dinglisch.android.tasker.EXTRA_NSR_DEPRECATED>
					<net.dinglisch.android.tasker.EXTRA_NSR_DEPRECATED-type>java.lang.Boolean</net.dinglisch.android.tasker.EXTRA_NSR_DEPRECATED-type>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES>&lt;StringArray sr=""&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;%avcomm
First recognized Command
&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;%avcomms()
All recognized commands
&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;%avsource
Source of the Voice Command
Can be normal, continuous, test or googlenow&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;%avword()
Word Array
&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;&lt;/StringArray&gt;</net.dinglisch.android.tasker.RELEVANT_VARIABLES>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>[Ljava.lang.String;</net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>
					<net.dinglisch.android.tasker.extras.REQUESTED_TIMEOUT>10000</net.dinglisch.android.tasker.extras.REQUESTED_TIMEOUT>
					<net.dinglisch.android.tasker.extras.REQUESTED_TIMEOUT-type>java.lang.Integer</net.dinglisch.android.tasker.extras.REQUESTED_TIMEOUT-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>config_easy_commands plugininstanceid plugintypeid </net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
					<plugininstanceid>7be6f8e7-afce-40d0-9e06-b7fa3a68ed6e</plugininstanceid>
					<plugininstanceid-type>java.lang.String</plugininstanceid-type>
					<plugintypeid>com.joaomgcd.autovoice.intent.IntentReceiveVoiceEvent</plugintypeid>
					<plugintypeid-type>java.lang.String</plugintypeid-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.joaomgcd.autovoice</Str>
			<Str sr="arg2" ve="3">com.joaomgcd.autovoice.activity.ActivityConfigReceiveVoiceEvent</Str>
			<Int sr="arg3" val="1"/>
		</Event>
	</Profile>
	<Task sr="task90">
		<cdate>1790920000000</cdate>
		<edate>1790920000000</edate>
		<id>90</id>
		<nme>Cassa Vocale</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>548</code>
			<Str sr="arg0" ve="3">🎙️ %avcomm</Str>
			<Int sr="arg1" val="0"/>
			<Str sr="arg10" ve="3"/>
			<Int sr="arg11" val="1"/>
			<Int sr="arg12" val="0"/>
			<Str sr="arg13" ve="3"/>
			<Int sr="arg14" val="0"/>
			<Str sr="arg15" ve="3"/>
			<Int sr="arg2" val="0"/>
			<Str sr="arg3" ve="3"/>
			<Str sr="arg4" ve="3"/>
			<Str sr="arg5" ve="3"/>
			<Str sr="arg6" ve="3"/>
			<Str sr="arg7" ve="3"/>
			<Str sr="arg8" ve="3"/>
			<Int sr="arg9" val="1"/>
		</Action>
		<Action sr="act1" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"%avcomm"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>avvia_ia.sh</com.termux.tasker.extra.EXECUTABLE>
					<com.termux.tasker.extra.EXECUTABLE-type>java.lang.String</com.termux.tasker.extra.EXECUTABLE-type>
					<com.termux.tasker.extra.SESSION_ACTION>&lt;null&gt;</com.termux.tasker.extra.SESSION_ACTION>
					<com.termux.tasker.extra.SESSION_ACTION-type>java.lang.String</com.termux.tasker.extra.SESSION_ACTION-type>
					<com.termux.tasker.extra.STDIN></com.termux.tasker.extra.STDIN>
					<com.termux.tasker.extra.STDIN-type>java.lang.String</com.termux.tasker.extra.STDIN-type>
					<com.termux.tasker.extra.TERMINAL>false</com.termux.tasker.extra.TERMINAL>
					<com.termux.tasker.extra.TERMINAL-type>java.lang.Boolean</com.termux.tasker.extra.TERMINAL-type>
					<com.termux.tasker.extra.VERSION_CODE>1002</com.termux.tasker.extra.VERSION_CODE>
					<com.termux.tasker.extra.VERSION_CODE-type>java.lang.Integer</com.termux.tasker.extra.VERSION_CODE-type>
					<com.termux.tasker.extra.WAIT_FOR_RESULT>true</com.termux.tasker.extra.WAIT_FOR_RESULT>
					<com.termux.tasker.extra.WAIT_FOR_RESULT-type>java.lang.Boolean</com.termux.tasker.extra.WAIT_FOR_RESULT-type>
					<com.termux.tasker.extra.WORKDIR>&lt;null&gt;</com.termux.tasker.extra.WORKDIR>
					<com.termux.tasker.extra.WORKDIR-type>java.lang.String</com.termux.tasker.extra.WORKDIR-type>
					<com.twofortyfouram.locale.intent.extra.BLURB>avvia_ia.sh "%avcomm"

Working Directory ✕
Stdin ✕
Custom Log Level null
Terminal Session ✕
Wait For Result ✓</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES>&lt;StringArray sr=""&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;%stdout
Standard Output
The &amp;lt;B&amp;gt;stdout&amp;lt;/B&amp;gt; of the command.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES0&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;%stdout_original_length
Standard Output Original Length
The original length of &amp;lt;B&amp;gt;stdout&amp;lt;/B&amp;gt;.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES1&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;%stderr
Standard Error
The &amp;lt;B&amp;gt;stderr&amp;lt;/B&amp;gt; of the command.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES2&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;%stderr_original_length
Standard Error Original Length
The original length of &amp;lt;B&amp;gt;stderr&amp;lt;/B&amp;gt;.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES3&gt;&lt;_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES4&gt;%result
Exit Code
The &amp;lt;B&amp;gt;exit code&amp;lt;/B&amp;gt; of the command.0 often means success and anything else is usually a failure of some sort.&lt;/_array_net.dinglisch.android.tasker.RELEVANT_VARIABLES4&gt;&lt;/StringArray&gt;</net.dinglisch.android.tasker.RELEVANT_VARIABLES>
					<net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>[Ljava.lang.String;</net.dinglisch.android.tasker.RELEVANT_VARIABLES-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="30"/>
			<Int sr="arg4" val="1"/>
		</Action>
		<Action sr="act2" ve="7">
			<code>548</code>
			<Str sr="arg0" ve="3">%stdout</Str>
			<Int sr="arg1" val="0"/>
			<Str sr="arg10" ve="3"/>
			<Int sr="arg11" val="1"/>
			<Int sr="arg12" val="0"/>
			<Str sr="arg13" ve="3"/>
			<Int sr="arg14" val="0"/>
			<Str sr="arg15" ve="3"/>
			<Int sr="arg2" val="0"/>
			<Str sr="arg3" ve="3"/>
			<Str sr="arg4" ve="3"/>
			<Str sr="arg5" ve="3"/>
			<Str sr="arg6" ve="3"/>
			<Str sr="arg7" ve="3"/>
			<Str sr="arg8" ve="3"/>
			<Int sr="arg9" val="1"/>
		</Action>
	</Task>
</TaskerData>
FINE_FILE
fi
chmod +x ~/.termux/tasker/*.sh && echo "✅ INSTALLAZIONE COMPLETATA"
