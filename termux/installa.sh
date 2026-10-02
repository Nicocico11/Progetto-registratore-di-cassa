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
  *"apri turno"*|*"inizio turno"*|*"inizia turno"*)
    bash $CARTELLA/avvia_server.sh ;;
  *"chiudi turno"*|*"fine turno"*)
    python3 ~/info_turno.py "chiudi turno"
    pkill -f llama-server
    termux-wake-unlock
    echo "💤 IA spenta fino al prossimo turno" ;;
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

# Notifica e vibrazione in sottofondo, senza far aspettare Tasker
nohup bash $CARTELLA/notifica.sh > /dev/null 2>&1 &
nohup bash $CARTELLA/vibra.sh $VIBRAZIONE > /dev/null 2>&1 &

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
  echo "✅ Server già attivo"
  exit 0
fi

nohup "$SERVER_BIN" -m "$MODELLO" --host 127.0.0.1 --port 8080 --ctx-size 1024 -t 4 > ~/llama_server.log 2>&1 &
echo "🚀 Server in avvio (pronto tra qualche secondo)"
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


data = analisi_veloce()
origine = 'regole'
if data is None:
    data = analisi_ia()
    origine = 'IA'
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
cat > ~/info_turno.py <<'FINE_FILE'
import csv
import json
import os
import sys
from datetime import datetime
import shutil
import glob

# Uso: python3 info_turno.py [notifica | ultimi | totali | cancella ultima |
#                             cancella penultima | chiudi turno | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
# Stessa intestazione che scrive processa_ia.py
INTESTAZIONE = ['data_ora', 'dettagli_json', 'importo']
CARBURANTI = ("BENZINA", "GASOLIO")


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
    """Restituisce (importo, categoria, metodo, note) di una riga, o None se illeggibile."""
    try:
        data = json.loads(r[1])
        imp = float(data.get("importo", 0.0))
        cat = str(data.get("categoria", "altro")).replace("_", " ").upper()
        metodo = str(data.get("metodo_pagamento", "altro")).capitalize()
        if metodo == "Pos":
            metodo = "POS"
        return imp, cat, metodo, str(data.get("note", "")).strip()
    except Exception:
        return None


def calcola_totali(righe):
    totale, per_categoria, per_metodo = 0.0, {}, {}
    for r in righe:
        v = vendita(r)
        if not v:
            continue
        imp, cat, metodo, _ = v
        totale += imp
        per_categoria[cat] = per_categoria.get(cat, 0.0) + imp
        per_metodo[metodo] = per_metodo.get(metodo, 0.0) + imp
    return totale, per_categoria, per_metodo


def notifica_breve(righe):
    if not righe:
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna transazione registrata.")
        return

    totale, per_categoria, per_metodo = calcola_totali(righe)

    # Testata con totale, categorie e metodi di pagamento
    out = [f"📊 Tot: {totale:.2f} € ({len(righe)} vendite)"]
    cats_str = " | ".join(f"{cat}: {val:.2f}€" for cat, val in per_categoria.items())
    if cats_str:
        out.append(f"⛽ {cats_str}")
    metodi_str = " | ".join(f"{m}: {val:.2f}€" for m, val in per_metodo.items())
    if metodi_str:
        out.append(f"💳 {metodi_str}")

    out.append("────────────────")
    out.append("🔍 Ultime transazioni:")

    # Ultime 5 transazioni, la più recente in cima
    for r in reversed(righe[-5:]):
        ora = r[0].split()[-1] if " " in r[0] else r[0]
        ora_breve = ora[:5]  # 05:30:22 -> 05:30
        v = vendita(r)
        if v:
            imp, _, metodo, note = v
            riga_txt = f"• {ora_breve} | {imp:.2f}€ ({metodo[:3].upper()})"
            if note:
                riga_txt += f" {note}"
            out.append(riga_txt)
        else:
            out.append(f"• {ora_breve} | {r[2] if len(r) > 2 else '?'}")

    print("\n".join(out))


def riepilogo_chiusura(righe, titolo="🧾 RIEPILOGO TURNO"):
    """Il prospetto da usare per la chiusura: totali per pagamento e per prodotto."""
    totale, per_categoria, per_metodo = calcola_totali(righe)
    out = [titolo, "─────────────────────────",
           f"Vendite: {len(righe)}    TOTALE: {totale:.2f} €", ""]

    out.append("💳 PER PAGAMENTO")
    contanti = per_metodo.get("Contanti", 0.0)
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<10} {val:>9.2f} €")
    out.append(f"  {'= Contanti':<10} {contanti:>9.2f} €")
    out.append(f"  {'= Elettron.':<10} {totale - contanti:>9.2f} €")
    out.append("")

    out.append("⛽ PER PRODOTTO")
    carburanti = 0.0
    for cat, val in sorted(per_categoria.items()):
        out.append(f"  {cat:<14} {val:>9.2f} €")
        if cat in CARBURANTI:
            carburanti += val
    out.append(f"  {'= Carburanti':<14} {carburanti:>9.2f} €")
    out.append(f"  {'= Market/altro':<14} {totale - carburanti:>9.2f} €")

    print("\n".join(out))


def mostra_ultimi(righe):
    notifica_breve(righe)


def mostra_totali(righe):
    riepilogo_chiusura(righe)


def mostra_archivio():
    pattern = os.path.expanduser("~/turno_archivio_*.csv")
    file_archiviati = sorted(glob.glob(pattern), reverse=True)

    out = ["📂 STORICO TURNI ARCHIVIATI:", "─────────────────────────"]
    for path_arc in file_archiviati:
        righe = leggi_csv(path_arc)
        if not righe:
            continue  # turni vuoti: non li mostriamo
        nome_file = os.path.basename(path_arc)
        data_str = nome_file.replace("turno_archivio_", "").replace(".csv", "").replace("_", " ")
        totale_turno, _, _ = calcola_totali(righe)
        out.append(f"• 📅 {data_str} | 💰 {totale_turno:.2f} € ({len(righe)} vendite)")

    if len(out) == 2:
        print("📭 Nessun turno precedente archiviato.")
        return
    print("\n".join(out))


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


def chiudi_turno():
    righe = leggi_csv()
    if not righe:
        # Niente da archiviare: evita di creare file d'archivio vuoti
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna vendita: niente da archiviare.")
        return

    timestamp_backup = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    path_backup = os.path.expanduser(f"~/turno_archivio_{timestamp_backup}.csv")
    shutil.copy(PATH_CSV, path_backup)
    scrivi_csv([])

    riepilogo_chiusura(righe, titolo="🧾 TURNO CHIUSO E ARCHIVIATO")


def main():
    comando = sys.argv[1].lower() if len(sys.argv) > 1 else "notifica"

    if "cancella ultima" in comando or "elimina ultima" in comando:
        cancella_ultima()
    elif "penultima" in comando:
        cancella_penultima()
    elif "chiudi turno" in comando or "fine turno" in comando or "azzera" in comando:
        chiudi_turno()
    elif "archivio" in comando or "storico" in comando:
        mostra_archivio()
    else:
        righe = leggi_csv()
        if comando == "ultimi":
            mostra_ultimi(righe)
        elif comando == "totali":
            mostra_totali(righe)
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
FINE_FILE
# Task di Tasker da importare: lo mettiamo nella cartella Download
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
		<Action sr="act1" ve="7">
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
echo "📥 Cassa_Vocale.tsk.xml salvato in Download"
fi
chmod +x ~/.termux/tasker/*.sh && echo "✅ INSTALLAZIONE COMPLETATA"
