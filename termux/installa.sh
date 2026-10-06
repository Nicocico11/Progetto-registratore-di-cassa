#!/bin/bash
# Installa / aggiorna la cassa vocale. Generato da genera_installa.sh: non modificarlo a mano.
# Copia di sicurezza dei file attuali (solo la prima volta: le copie .vecchio non vengono sovrascritte)
for f in ~/.termux/tasker/avvia_ia.sh ~/.termux/tasker/avvia_server.sh ~/.termux/tasker/processa_ia.py ~/.termux/tasker/notifica.sh ~/info_turno.py; do [ -f "$f" ] && [ ! -f "$f.vecchio" ] && cp "$f" "$f.vecchio"; done
cat > ~/.termux/tasker/avvia_ia.sh <<'FINE_FILE'
#!/bin/bash
# Unico punto d'ingresso da Tasker: riceve tutto quello che dici.
# Se è un comando (apri turno, cancella ultima, totali...) lo esegue,
# altrimenti lo tratta come una vendita.
# Al termine: notifica aggiornata e vibrazione in base all'esito
#   1 vibrazione corta = tutto ok
#   2 vibrazioni corte = salvato, ma controlla
#   1 vibrazione lunga = errore, niente salvato
# A turno chiuso: niente vendite, niente notifiche, IA spenta.

CARTELLA=~/.termux/tasker

# Log di debug per Tasker
echo "$(date) - Ricevuto da Tasker: '$1'" >> ~/debug_tasker.log

TESTO="$1"

if [ -z "$TESTO" ] || [[ "$TESTO" == %* ]]; then
  echo "❌ Errore: Testo vocale non valido o variabile Tasker non espansa ($TESTO)" | tee -a ~/debug_tasker.log
  nohup bash $CARTELLA/vibra.sh errore > /dev/null 2>&1 &
  exit 0
fi

# Popup di testo (Termux:API): stampa quello che è stato scritto, niente se annullato
chiedi() {  # chiedi "titolo" "suggerimento" [-n per tastiera numerica]
  termux-dialog text $3 -t "$1" -i "$2" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("code") == -1:
        print(d.get("text", ""))
except Exception:
    pass'
}

# Vero se il turno è aperto; altrimenti avvisa e segna l'errore
turno_aperto() {
  if python3 ~/info_turno.py aperto; then
    return 0
  fi
  echo "❌ Turno non aperto: di' prima \"apertura turno\". Niente salvato."
  ESITO=1
  return 1
}

spegni_ia() {
  # stato_ia.sh aspetta che l'IA sia davvero spenta e aggiorna (o toglie) la notifica
  bash $CARTELLA/stato_ia.sh spegni
}

FRASE="${TESTO,,}"   # tutto minuscolo
ESITO=0

# Tutto quello che il comando scrive passa anche da un file, per accorgersi degli avvisi ⚠️
USCITA=$(mktemp)
{
case "$FRASE" in
  *turno*)
    # Qualsiasi frase con "turno" è un comando, mai una vendita
    if [[ "$FRASE" =~ ripristin ]]; then
      python3 ~/info_turno.py ripristina
    elif [[ "$FRASE" =~ (apri|apertura|inizio|inizia|avvia|comincia) ]]; then
      AVANZO=""; ORA_PREC=""; CONTATORE=""; TANICHE=""
      if ! python3 ~/info_turno.py aperto; then
        # Valori del turno PRECEDENTE (di un altro operatore): si scrivono sempre a mano,
        # vuoto = non inserito (nell'Excel restano da scrivere)
        AVANZO=$(chiedi "Avanzo cassa turno precedente (€)" "es. 150,50")
        ORA_PREC=$(chiedi "Ora chiusura turno precedente" "tutto attaccato, es. 140532" -n)
        CONTATORE=$(chiedi "Contatore AdBlue iniziale" "numero sulla colonnina, es. 68624,4")
        TANICHE=$(chiedi "Taniche AdBlue presenti" "es. 59" -n)
      fi
      echo "🟢 TURNO APERTO"
      # "apertura turno notte": turno scelto a voce invece che dall'orario
      TIPO=$(grep -oE 'mattina|pomeriggio|notte' <<< "$FRASE" | head -1)
      # "apertura turno prova" / "test": file con TEST nel nome, contatori veri non toccati
      PROVA=$(grep -oE 'prova|test' <<< "$FRASE" | head -1)
      python3 ~/info_turno.py apri turno "$AVANZO" "$ORA_PREC" "$CONTATORE" "$TANICHE" "$TIPO" "$PROVA"
      # L'IA non si accende più da sola: le vendite si capiscono con le regole ("accendi ia" se serve)
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]]; then
      # Orario del terminale pompe con i secondi: detto nella frase
      # ("chiusura turno 14 05 32") oppure scritto nel popup (es. 140532)
      ORARIO=$(grep -oE '[0-9]+' <<< "$FRASE" | tr '\n' ' ')
      if [ -z "$ORARIO" ]; then
        ORARIO=$(chiedi "Orario terminale pompe" "ore minuti secondi, es. 140532" -n)
      fi
      # I contanti attesi li calcola da solo dalle vendite: serve solo la cassaforte
      CASSAFORTE=$(chiedi "In cassaforte (€)" "vuoto se non c'è niente")
      echo "🔴 TURNO CHIUSO - IA spenta"
      python3 ~/info_turno.py "chiudi turno" "$ORARIO" "" "$CASSAFORTE"
      spegni_ia
    else
      echo "❓ Comando turno non capito: \"$TESTO\" (di' \"apri turno\" o \"chiudi turno\")"
      ESITO=1
    fi ;;
  "ia"|*" ia"|"ia "*|*" ia "*|*"server"*|*"intelligenza"*)
    # "accendi ia", "spegni ia", "stato ia"
    if [[ "$FRASE" =~ (accendi|avvia|attiva) ]]; then
      turno_aperto && bash $CARTELLA/avvia_server.sh
    elif [[ "$FRASE" =~ (spegni|ferma|disattiva) ]]; then
      spegni_ia
      echo "⚫ IA spenta"
    else
      case "$(curl -s --max-time 2 http://127.0.0.1:8080/health)" in
        *'"ok"'*) echo "🟢 IA accesa e pronta" ;;
        *) if pgrep -x llama-server > /dev/null || pgrep -f "llama-server -m" > /dev/null; then echo "🟡 IA in avvio"; else echo "⚫ IA spenta"; fi ;;
      esac
    fi ;;
  "market"|"danea"|"negozio"|*"vendite market"*|*"vendite danea"*|*"prodotti venduti"*)
    # Solo la parola: elenco dei prodotti venduti. "danea 15 euro" invece è una vendita (sotto)
    python3 ~/info_turno.py market ;;
  *"erogazion"*|*"quanto adblue"*|*"quante adblue"*)
    python3 ~/info_turno.py adblue ;;
  *"correggi"*|*"correggere"*|*"modifica"*)
    # "correggi ultima carta", "correggi penultima 25 euro", "correggi ultima gasolio"
    if [[ "$FRASE" =~ penultim ]]; then QUALE=penultima; else QUALE=ultima; fi
    python3 $CARTELLA/processa_ia.py --correggi $QUALE "$TESTO"
    ESITO=$?
    python3 ~/info_turno.py salva > /dev/null 2>&1 ;;
  *"contatore"*)
    # "contatore adblue 68624,4" / "contatore taniche 59": valori di partenza
    python3 ~/info_turno.py contatore "$FRASE"
    ESITO=$? ;;
  *"versamento"*|*"versato"*)
    if turno_aperto; then
      # Le banconote servono per il riquadro VERSAMENTO dell'Excel (quante da 500, 200, 100...)
      if [[ "$FRASE" =~ (cancella|annulla|togli|elimina) ]]; then
        python3 ~/info_turno.py "cancella versamento"
        ESITO=$?
      else
        IMPORTO_V=$(python3 ~/info_turno.py importo "$FRASE")
        TITOLO="🏦 Banconote del versamento di $IMPORTO_V €"
        for TENTATIVO in 1 2 3; do
          BANCONOTE=""
          if [ -n "$IMPORTO_V" ]; then
            BANCONOTE=$(chiedi "$TITOLO" "es. 200 50 50 50  oppure  1x200 3x50 (vuoto = le calcolo io)")
            if [ $TENTATIVO -gt 1 ] && [ -z "$BANCONOTE" ]; then   # annullato dopo un errore: niente salvato
              RISPOSTA_V="❌ Banconote non corrette: versamento NON salvato. Ridillo."; ESITO=3; break
            fi
          fi
          RISPOSTA_V=$(python3 ~/info_turno.py versamento "$FRASE" "$BANCONOTE")
          ESITO=$?
          [ $ESITO -ne 3 ] && break
          # Le banconote non tornano: si richiedono (niente salvato finché non tornano)
          TITOLO="❌ Non tornano, riscrivi le banconote di $IMPORTO_V €"
        done
        [ $ESITO -eq 3 ] && ESITO=1
        echo "$RISPOSTA_V"
      fi
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
  *"avanzo"*)
    if turno_aperto; then
      python3 ~/info_turno.py avanzo "$FRASE"
      ESITO=$?
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
  *"penultima"*|*"penultimo"*)
    python3 ~/info_turno.py "cancella penultima" ;;
  *"cancella ultim"*|*"elimina ultim"*|*"annulla ultim"*|*"cancellala"*)
    python3 ~/info_turno.py "cancella ultima" ;;
  *"totali"*|*"riepilogo"*)
    # In una finestra che resta finché non premi OK (il messaggio a schermo di Tasker è troppo piccolo);
    # il riepilogo completo è nel pulsante 04 Totali
    RIEPILOGO=$(python3 ~/info_turno.py totali breve)
    nohup termux-dialog confirm -t "📊 Totali del turno" -i "$RIEPILOGO" > /dev/null 2>&1 &
    echo "📊 Totali sullo schermo" ;;
  *"ultime"*|*"ultimi"*)
    python3 ~/info_turno.py ultimi ;;
  *"archivio"*|*"storico"*)
    python3 ~/info_turno.py archivio ;;
  *)
    # Una vendita: solo a turno aperto
    if turno_aperto; then
      RISPOSTA=$(python3 $CARTELLA/processa_ia.py "$TESTO")
      ESITO=$?
      echo "$RISPOSTA"
      # Frase non capita (parola sentita male): riquadro per scriverla giusta
      if [ $ESITO -eq 1 ] && [[ "$RISPOSTA" == *"❓"* ]] && [[ "$RISPOSTA" != *"Quale prodotto"* ]]; then
        CORRETTA=$(chiedi "✏️ Non capito: scrivi la frase giusta" "$TESTO")
        if [ -n "$CORRETTA" ]; then
          echo "$(date) - Corretta a mano: '$CORRETTA'" >> ~/debug_tasker.log
          echo "✏️ $CORRETTA"
          python3 $CARTELLA/processa_ia.py "$CORRETTA"
          ESITO=$?
        fi
      fi
      # Copia di sicurezza del turno in Download, aggiornata a ogni vendita
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
esac
} > "$USCITA" 2>&1
cat "$USCITA"

# Un avviso ⚠️ qualsiasi: anche notifica nella tendina, con suono
if grep -q "⚠️" "$USCITA"; then
  termux-notification --id avviso_cassa --priority high --sound --vibrate 400,200,400 \
    --title "⚠️ Controlla" --content "$(grep -m1 "⚠️" "$USCITA" | cut -c1-200)" > /dev/null 2>&1
fi
rm -f "$USCITA"

case $ESITO in
  0) VIBRAZIONE=ok ;;
  2) VIBRAZIONE=attenzione ;;
  *) VIBRAZIONE=errore ;;
esac

# Vibrazione subito (non in sottofondo: in sottofondo Android poteva bloccarla),
# notifiche in sottofondo per non far aspettare Tasker (a turno chiuso si tolgono da sole)
bash $CARTELLA/vibra.sh $VIBRAZIONE > /dev/null 2>&1
nohup bash $CARTELLA/notifica.sh > /dev/null 2>&1 &
# Mail rimaste in coda (chiusura fatta senza internet): si riprova in sottofondo
[ -s ~/.cassa_email_coda ] && nohup python3 $CARTELLA/invia_mail.py coda > /dev/null 2>&1 &
nohup bash $CARTELLA/stato_ia.sh aggiorna > /dev/null 2>&1 &

# Sempre 0: l'esito lo comunicano messaggio e vibrazione, così Tasker non interrompe il Task
exit 0
FINE_FILE
cat > ~/.termux/tasker/widget_comune.sh <<'FINE_FILE'
#!/bin/bash
# Funzioni comuni ai pulsanti del widget: riquadri (termux-dialog) invece del terminale,
# esito in un messaggio a schermo, poi ritorno alla schermata home.
CASSA=~/.termux/tasker/avvia_ia.sh

_leggi() {  # testo scritto o scelto nel riquadro; niente se annullato
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("code") == -1:
        print(d.get("text", ""))
except Exception:
    pass'
}

testo()    { termux-dialog text -t "$1" -i "$2" 2>/dev/null | _leggi; }         # testo "titolo" "esempio"
numero()   { termux-dialog text -n -t "$1" -i "$2" 2>/dev/null | _leggi; }      # numero "titolo" "esempio"
scegli()   { termux-dialog radio -t "$1" -v "$2" 2>/dev/null | _leggi; }        # scegli "titolo" "a,b,c"
# Sì/No: vale la risposta "yes", qualunque sia il codice restituito dal riquadro
conferma() {
  termux-dialog confirm -t "$1" -i "$2" 2>/dev/null | python3 -c '
import sys, json
try:
    sys.exit(0 if str(json.load(sys.stdin).get("text", "")).strip().lower() in ("yes", "si", "sì") else 1)
except Exception:
    sys.exit(1)'
}

# Finestra con un testo lungo (riepiloghi), da chiudere con OK
finestra() { termux-dialog confirm -t "$1" -i "$2" > /dev/null 2>&1; }

# Messaggio breve: lanciato da Tasker lo scrive e basta (lo mostra Tasker, con il suo stile);
# dal widget di Termux compare in basso
messaggio() {
  if [ -n "$SENZA_TERMINALE" ]; then echo "$1"; else termux-toast -g bottom "$1" 2>/dev/null; fi
}

# Esito di un comando: solo le righe importanti (✅ ⚠️ ❌ ❓ 🧾 ...), o la prima riga
esito() {
  local corto
  corto=$(grep -m3 -E '✅|⚠️|❌|❓|🧾|🗑️|🏦|💶|📅|🔴|🟢|📧|🧪' <<< "$1")
  messaggio "${corto:-$(head -1 <<< "$1")}"
}

casa() {    # torna alla schermata home e chiude il pulsante (da Tasker non serve: Termux non si apre)
  if [ -n "$SENZA_TERMINALE" ]; then exit 0; fi
  sleep 1
  am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1
  exit 0
}

annullato() { messaggio "Niente salvato"; casa; }

# Pagamento con i riquadri: stampa la frase da aggiungere ("sul nero", "in cassa"...)
pagamento() {   # pagamento "titolo" [senza_cassa]
  local scelte="Contanti,POS cassa (negozio),POS nero,POS bianco,Petrolifere (Cartissima)"
  [ -n "$2" ] && scelte="Contanti,POS nero,POS bianco,Petrolifere (Cartissima),OPT (accettatore)"
  case "$(scegli "$1" "$scelte")" in
    Contanti) echo "contanti" ;;
    "POS cassa"*) echo "in cassa" ;;
    "POS nero") echo "sul nero" ;;
    "POS bianco") echo "sul bianco" ;;
    Petrolifere*) echo "petrolifere" ;;
    OPT*) echo "opt" ;;
  esac
}
FINE_FILE
cat > ~/.termux/tasker/pulsante.sh <<'FINE_FILE'
#!/bin/bash
# Pulsanti della cassa SENZA la finestra di Termux: li lancia Tasker (plugin Termux:Tasker).
#   pulsante.sh menu   -> lista di tutte le funzioni, si sceglie e parte
#   pulsante.sh 01 / pulsante.sh "Totali" -> direttamente quel pulsante (per numero o per nome)
# Usa gli stessi script dei pulsanti del widget (~/.shortcuts).
export SENZA_TERMINALE=1   # niente ritorno alla home: Termux non si apre proprio
. ~/.termux/tasker/widget_comune.sh
QUALE="${1:-menu}"
if [ "$QUALE" = menu ]; then
  ELENCO=$(cd ~/.shortcuts && ls -1 [0-9][0-9]\ * | paste -sd, -)
  SCELTA=$(scegli "🧾 Cassa" "$ELENCO")
  [ -z "$SCELTA" ] && { echo "Annullato"; exit 0; }
  QUALE="${SCELTA%% *}"
fi
if [[ "$QUALE" =~ ^[0-9][0-9]$ ]]; then
  FILE=$(ls ~/.shortcuts/"$QUALE "* 2>/dev/null | head -1)      # per numero: pulsante.sh 01
else
  FILE=$(ls ~/.shortcuts/[0-9][0-9]\ "$QUALE" 2>/dev/null | head -1)   # per nome: pulsante.sh "Totali"
fi
[ -z "$FILE" ] && { echo "❌ Pulsante $QUALE non trovato: rifai l'installazione"; exit 1; }
exec bash "$FILE"
FINE_FILE
cat > ~/.termux/tasker/avvia_server.sh <<'FINE_FILE'
#!/bin/bash
# Avvia llama-server una sola volta, a inizio turno.
CARTELLA=~/.termux/tasker

# A turno chiuso l'IA resta spenta
if ! python3 ~/info_turno.py aperto; then
  echo "❌ Turno non aperto: l'IA si accende con \"apertura turno\""
  exit 1
fi
termux-wake-lock

# Percorso esplicito del modello: cambia solo questa riga per provare un altro modello.
MODELLO=~/llama.cpp/models/qwen2.5-3b-instruct-q4_k_m.gguf
SERVER_BIN=~/llama.cpp/build/bin/llama-server

# Se il server risponde già, non ne avviamo un secondo (sprecherebbe RAM e CPU)
if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q ok; then
  echo "✅ IA già accesa e pronta"
  nohup bash $CARTELLA/stato_ia.sh aggiorna > /dev/null 2>&1 &
  exit 0
fi
# Già partito e ancora in caricamento: aspettiamo quello
if pgrep -x llama-server > /dev/null; then
  echo "🟡 IA già in avvio: pronta tra pochi secondi"
  exit 0
fi

nohup "$SERVER_BIN" -m "$MODELLO" --host 127.0.0.1 --port 8080 --ctx-size 1024 -t 4 > ~/llama_server.log 2>&1 &
echo "🚀 IA in avvio: pronta tra circa 30 secondi"
# La notifica "IA" passa da gialla a verde quando il modello è caricato
nohup bash $CARTELLA/stato_ia.sh attendi > /dev/null 2>&1 &
FINE_FILE
cat > ~/.termux/tasker/stato_ia.sh <<'FINE_FILE'
#!/bin/bash
# Notifica "IA" con lo stato del server e i pulsanti Spegni / Aggiorna.
# Compare SOLO se l'IA è accesa (a mano, "accendi ia"): da spenta niente notifica,
# così nella tendina resta solo il turno. A turno chiuso IA sempre spenta.
# Uso: stato_ia.sh [aggiorna | accendi | spegni | attendi]
#   attendi = ricontrolla ogni 3 secondi finché l'IA è pronta (massimo 2 minuti)

CARTELLA=/data/data/com.termux/files/home/.termux/tasker
[ -d "$CARTELLA" ] || CARTELLA=~/.termux/tasker
BASH_BIN=$(command -v bash)
QUESTO="$BASH_BIN $CARTELLA/stato_ia.sh"

# Traccia nel log ogni comando (serve a capire se i pulsanti della notifica arrivano)
[ "${1:-aggiorna}" != "attendi" ] && [ "${1:-aggiorna}" != "aggiorna" ] && echo "$(date '+%H:%M:%S') stato_ia ${1:-aggiorna}" >> ~/debug_tasker.log

ia_in_esecuzione() {
  pgrep -x llama-server > /dev/null || pgrep -f "llama-server -m" > /dev/null
}

stato() {
  if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q '"ok"'; then
    echo accesa
  elif ia_in_esecuzione; then
    echo avvio   # il processo c'è ma sta ancora caricando il modello
  else
    echo spenta
  fi
}

spegni_ia() {
  pkill -f "stato_ia.sh attendi"
  pkill -x llama-server; pkill -f "llama-server -m"
  # Aspetta che si chiuda davvero (fino a 10 secondi), poi la chiude a forza
  for i in $(seq 1 10); do
    ia_in_esecuzione || break
    sleep 1
  done
  if ia_in_esecuzione; then
    pkill -9 -x llama-server; pkill -9 -f "llama-server -m"
    sleep 1
  fi
  termux-wake-unlock
  echo "$(date '+%H:%M:%S') IA spenta ($(ia_in_esecuzione && echo 'ANCORA ATTIVA' || echo ok))" >> ~/debug_tasker.log
}

mostra() {
  case "$1" in
    accesa) TITOLO="🟢 IA accesa e pronta"; TESTO="Le frasi difficili vengono capite dall'IA" ;;
    avvio)  TITOLO="🟡 IA in avvio…"; TESTO="Pronta tra pochi secondi" ;;
    avvio_spegnimento) TITOLO="⏳ Spegnimento IA…"; TESTO="Qualche secondo" ;;
    *)      termux-notification-remove stato_ia 2>/dev/null; return ;;   # spenta: niente notifica
  esac
  termux-notification --id stato_ia --ongoing --alert-once --priority low \
    --title "$TITOLO" --content "$TESTO" \
    --button1 "Accendi" --button1-action "$QUESTO accendi" \
    --button2 "Spegni"  --button2-action "$QUESTO spegni" \
    --button3 "Aggiorna" --button3-action "$QUESTO aggiorna" > /dev/null 2>&1
}

# Turno chiuso: IA spenta e nessuna notifica
if ! python3 ~/info_turno.py aperto; then
  ia_in_esecuzione && spegni_ia
  termux-notification-remove stato_ia 2>/dev/null
  [ "${1:-}" = "accendi" ] && echo "❌ Turno non aperto: di' \"apertura turno\""
  exit 0
fi

case "${1:-aggiorna}" in
  accendi)
    bash $CARTELLA/avvia_server.sh > /dev/null 2>&1   # avvia_server.sh lancia anche "attendi"
    mostra "$(stato)" ;;
  spegni)
    mostra avvio_spegnimento 2>/dev/null
    spegni_ia
    mostra "$(stato)" ;;
  attendi)
    for i in $(seq 1 40); do
      S=$(stato)
      mostra "$S"
      [ "$S" = "avvio" ] || exit 0
      sleep 3
    done ;;
  *)
    mostra "$(stato)" ;;
esac
FINE_FILE
cat > ~/.termux/tasker/notifica.sh <<'FINE_FILE'
#!/bin/bash
# Notifica fissa "Stato Turno" nella tendina: solo con il turno aperto.
if ! python3 ~/info_turno.py aperto; then
  termux-notification-remove distributore_turno 2>/dev/null
  exit 0
fi
TESTO_NOTIFICA=$(python3 ~/info_turno.py notifica)
termux-notification \
  --id "distributore_turno" \
  --title "📊 Stato Turno Q8" \
  --content "$TESTO_NOTIFICA" \
  --ongoing \
  --alert-once \
  --priority high
FINE_FILE
cat > ~/.termux/tasker/processa_ia.py <<'FINE_FILE'
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
from numeri import in_cifre, senza_accenti
testo_basso = senza_accenti(in_cifre(testo_basso))                                    # "estathé" -> estathe
# Errori tipici del riconoscimento vocale
testo_basso = re.sub(r'\b(\d+):(\d{2})\b', r'\1.\2', testo_basso)                   # "20:10" -> 20.10
# "20 10 di gasolio", "70 07 nero", "83 39": due numeri attaccati, il secondo di 2 cifre = centesimi
testo_basso = re.sub(r'\b(\d+)\s+(\d{2})\b(?!\s*(?:litri|litro|l\b|fogli|foglio|pezzi|tanich|tanica|x\b|euro))',
                     r'\1.\2', testo_basso)
testo_basso = re.sub(r'\b(\d+(?:[.,]\d+)?)\s+ore\b', r'\1 euro', testo_basso)          # "20 ore" -> 20 euro
testo_basso = re.sub(r'\b(?:resto\s+lasciato|(?:ha\s+)?lasciato\s+(?:il\s+)?resto)\b', 'lasciato', testo_basso)  # "resto lasciato"
testo_basso = re.sub(r'\b(?:pasti|posti|post|pos|poss)\s+(bianco|nero)\b', r'pos \1', testo_basso)  # "pasti bianco"
testo_basso = re.sub(r'\b(?:o\s*\.?\s*p\s*\.?\s*t|otp|o\s+pi\s+ti|opiti|oppiti|o\s+p\s+ti|accettatore)\b', 'opt',
                     testo_basso)                                                      # "o p t", "otp" -> opt
testo_basso = re.sub(r'\bmarzo\b', 'mars', testo_basso)                              # "2 marzo"
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
    'POS nero': ['pos nero', 'sul nero', 'col nero', 'con il nero', 'nel nero', 'pagato nero', 'pagato al nero', 'nero'],
    'POS bianco': ['pos bianco', 'sul bianco', 'col bianco', 'con il bianco', 'nel bianco', 'pagato bianco',
                   'pagato al bianco', 'bianco'],
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


# Indice parola -> prodotti market: basta una parola del nome ("ichnusa", "heineken", "moretti");
# se la parola vale per più prodotti compare la lista "Quale prodotto?"
PAROLE_COMUNI = {'carta', 'carico', 'lettere', 'numeri', 'primo', 'super', 'multi', 'micro', 'power',
                 'porta', 'linea', 'tanica', 'taniche', 'double', 'travel', 'universal', 'dynamic', 'atomic',
                 'amica', 'gasolio', 'benzina', 'diesel', 'verde', 'adblue', 'litri', 'litro', 'contanti',
                 'bianco', 'cassa', 'nero', 'della', 'delle', 'dello', 'degli', 'dalla', 'alla', 'alle',
                 'type', 'fuel', 'auto', 'gusti', 'vari', 'misti', 'senza', 'euro', 'danea', 'pezzi'}
PAROLE_PRODOTTI = {}
for _nome, _p in listino.items():
    if _p.get('reparto', 'Market') == 'Market':
        for _alias in _p.get('alias') or [_nome.lower()]:
            for _w in senza_accenti(_alias.lower()).split():
                codice = re.search(r'\d', _w) and re.search(r'[a-z]', _w)
                if codice:
                    PAROLE_PRODOTTI.setdefault(re.sub(r'[-/]', '', _w), set()).add(_nome)   # 5w-40 = 5w40
                elif len(_w) >= 4 and _w.isalpha() and _w not in PAROLE_COMUNI:
                    PAROLE_PRODOTTI.setdefault(_w, set()).add(_nome)


def prodotti_da_parole(testo):
    """Prodotti che hanno nel nome le parole dette (tutte quelle riconosciute)."""
    gruppi, gruppi_codici = [], []
    for w in re.findall(r"[a-z0-9][a-z0-9/-]*", testo):
        if re.search(r'\d', w):
            w = re.sub(r'[-/]', '', w)
            if re.search(r'[a-z]', w) and w in PAROLE_PRODOTTI:   # codice (5w-40, h7): pesa di più
                gruppi_codici.append(PAROLE_PRODOTTI[w])
            continue
        if len(w) < 4 or w in PAROLE_COMUNI:
            continue
        trovati = PAROLE_PRODOTTI.get(w)
        if not trovati and len(w) >= 6:   # plurale: "lampadine" -> lampadina (solo parole lunghe)
            trovati = set().union(*[n for k, n in PAROLE_PRODOTTI.items() if len(k) >= 6 and radice(k) == radice(w)])
        if trovati:
            gruppi.append(trovati)
    if not gruppi and not gruppi_codici:
        # Nessuna parola esatta: la più simile ("icnusa" -> ichnusa, "heiniken" -> heineken)
        import difflib
        nomi_alfabetici = [k for k in PAROLE_PRODOTTI if k.isalpha()]
        for w in parole_libere(testo):
            if len(w) >= 5 and w.isalpha():
                simile = difflib.get_close_matches(w, nomi_alfabetici, n=1, cutoff=0.85)
                if simile:
                    SIMILI[w] = simile[0]
                    gruppi.append(PAROLE_PRODOTTI[simile[0]])
        if not gruppi:
            # Tutto il nome insieme ("red bul" -> red bull)
            detto = " ".join(parole_libere(testo))
            alias_market = {senza_accenti(al.lower()): n for n, pr in listino.items()
                            if pr.get('reparto', 'Market') == 'Market' for al in pr.get('alias', [])}
            simile = difflib.get_close_matches(detto, list(alias_market), n=1, cutoff=0.85) if len(detto) >= 5 else []
            if simile:
                SIMILI[detto] = simile[0]
                gruppi.append({alias_market[simile[0]]})
    if gruppi_codici:
        base = set.intersection(*gruppi_codici)
        con_parole = base.intersection(*gruppi) if gruppi else base
        return sorted(con_parole or base)
    if not gruppi:
        return []
    comuni = set.intersection(*gruppi)
    return sorted(comuni or min(gruppi, key=len))


# ---------- codici dei prodotti detti male da AutoVoice ----------
# "h 7", "acca 7", "acca sette", "hsette", "p 21 doppia vu" -> h7 / p21w, solo se il codice esiste nel listino
CODICI = {}
for _p in listino.values():
    for _alias in _p.get('alias', []):
        for _w in _alias.lower().split():
            if re.search(r'\d', _w) and re.search(r'[a-z]', _w) and not re.search(r'[.,]', _w):
                CODICI[re.sub(r'[-/]', '', _w)] = _w
LETTERE = {'acca': 'h', 'erre': 'r', 'esse': 's', 'kappa': 'k', 'ics': 'x', 'zeta': 'z', 'emme': 'm',
           'enne': 'n', 'elle': 'l', 'effe': 'f', 'vu': 'v', 'vi': 'v', 'pi': 'p', 'ti': 't', 'ci': 'c',
           'bi': 'b', 'gi': 'g', 'cu': 'q', 'qu': 'q', 'doppiavu': 'w'}
_NUMERI_PAROLE = sorted((w for w in __import__('numeri')._NUMERI if len(w) > 2), key=len, reverse=True)


def pezzo_di_codice(token):
    """"acca" -> "h", "hsette" -> "h7", "7" -> "7"."""
    if token in LETTERE:
        return LETTERE[token]
    m = re.fullmatch(r'([a-z]{1,2})(' + '|'.join(_NUMERI_PAROLE) + r')', token)
    if m:
        return m.group(1) + str(__import__('numeri')._NUMERI[m.group(2)])
    return token


def normalizza_codici(testo):
    testo = re.sub(r'\bdoppi[ao]\s+vu?\b', 'doppiavu', testo)
    parole = testo.split()
    out, i = [], 0
    while i < len(parole):
        for lunghezza in (4, 3, 2, 1):
            finestra = parole[i:i + lunghezza]
            if len(finestra) < lunghezza:
                continue
            unito = re.sub(r'[-/]', '', "".join(pezzo_di_codice(w) for w in finestra))
            if unito in CODICI and (lunghezza > 1 or unito != finestra[0]):
                out.append(CODICI[unito])
                i += lunghezza
                break
        else:
            out.append(parole[i])
            i += 1
    return " ".join(out).replace('doppiavu', 'doppia vu')


testo_basso = normalizza_codici(testo_basso)

# Nomi generici per gruppi di prodotti ("cingomme" = Vigorsol, Vivident, Happydent, Daygum).
# Stesso prezzo: si salva col nome del gruppo; prezzi diversi: lista.
GRUPPI = {
    'CHEWING GUM': {'parole': ['cingomme', 'cingomma', 'chingomme', 'chingomma', 'cingum', 'chewing gum',
                               'chewingum', 'chewing gum', 'cewing gum', 'gomme da masticare',
                               'gomma da masticare', 'cicche', 'cicca', 'ciunga', 'ciungam'],
                    'prodotti': ['VIGORSOL', 'VIVIDENT', 'HAPPYDENT', 'DAYGUM']},
    # "birra" da sola: tutte le birre, anche quelle senza "birra" nel nome (Ichnusa)
    'BIRRA': {'parole': ['birra', 'birre', 'birretta', 'birrette'], 'solo_generico': True,
              'nomi_con': ['BIRRA', 'ICHNUSA', 'HEINEKEN', 'MORETTI', 'PERONI', 'CORONA', 'BECK',
                           'NASTRO AZZURRO', 'TENNENT', 'MENABREA']},
    'VINO': {'parole': ['vino', 'vini', 'bottiglia di vino'], 'solo_generico': True,
             'categorie': ['VINI']},
}


def gruppo_detto(testo):
    for nome, g in GRUPPI.items():
        if any(contiene(p, testo) for p in g['parole']):
            if g.get('solo_generico'):
                # vale solo se si dice la parola generica e basta ("una birra", non "birra moretti")
                parole_gruppo = {w for p in g['parole'] for w in p.split()}
                if not set(parole_libere(testo, togli_prodotti=False)) <= parole_gruppo:
                    continue
            prodotti = [n for n in g.get('prodotti', []) if n in listino]
            prodotti += sorted(n for n, pr in listino.items() if n not in prodotti and pr.get('reparto', 'Market') == 'Market'
                               and (any(m in n for m in g.get('nomi_con', []))
                                    or pr.get('categoria') in g.get('categorie', [])))
            if prodotti:
                return nome, prodotti
    return None, []


CATEGORIE_CIBO = {'SNACK DOLCI', 'CARAMELLE', 'SNACK SALATI', 'BEVANDE', 'GELATI', 'SALUMI FORMAGGI',
                  'PRODOTTI TIPICI', 'VINI'}
OLI_MOTORE = sorted(n for n, p in listino.items()
                    if p.get('categoria') == 'LUBRIFICANTI' and re.search(r'\d+W-?\d+', n))   # 5W-40, 0W-20...
AVVISI = []     # cose da controllare: la vendita si salva con 2 vibrazioni
SIMILI = {}     # parole sentite male e il nome del listino più simile ("icnusa": "ichnusa")
SCELTI = set()  # prodotti scelti dalla lista "Quale prodotto?"
AMBIGUI = []  # prodotti diversi con lo stesso nome detto (es. "lampadina" -> H7, H4...)


def trova_prodotto_listino(testo):
    # Vince il nome/alias più lungo trovato nella frase
    # ("acqua grande" batte "acqua", "lampadina h7" batte "lampadina").
    testo_unito = testo.replace(' ', '')
    testo_radici = radici(testo)
    gruppo, nel_gruppo = gruppo_detto(testo)
    if gruppo:
        scelto = [n for n in nel_gruppo if n in SCELTI]
        if scelto:
            return scelto[0]
        if len({listino[n]['prezzo'] for n in nel_gruppo}) == 1:
            return prodotto_generico(nel_gruppo, gruppo)
        AMBIGUI[:] = nel_gruppo
        return None
    trovati, lunghezza, vincente = [], 0, ""
    for nome, p in listino.items():
        for alias in [nome] + p.get('alias', []):
            alias = senza_accenti(alias.lower())
            # Plurali e parole attaccate solo per i nomi lunghi: "ore" non deve diventare "oreo"
            if (contiene(alias, testo)
                    or (len(alias) >= 5 and (radici(alias) in testo_radici
                                             or alias.replace(' ', '') in testo_unito))):
                if len(alias) > lunghezza:
                    trovati, lunghezza, vincente = [nome], len(alias), alias
                elif len(alias) == lunghezza and nome not in trovati:
                    trovati.append(nome)
    if trovati and all(listino[n].get('reparto', 'Market') == 'Market' for n in trovati):
        # Lo stesso nome in altri prodotti ("deodorante luxury" -> 150 ml e 300 ml;
        # "miele di acacia" -> 400 gr e 1 kg): si sceglie dalla lista
        parole = set(vincente.split())
        simili = sorted(n for n, pr in listino.items() if n not in trovati and pr.get('reparto', 'Market') == 'Market'
                        and any(parole <= set(senza_accenti(a.lower()).split()) for a in pr.get('alias', [])))
        trovati = trovati + simili
    if re.search(r'\bolio\s+(?:motore|auto|macchina|camion)\b|\blubrificant', testo) and not any(
            n in OLI_MOTORE for n in trovati):
        trovati = list(OLI_MOTORE)
    if not trovati and not carburante_detto(testo):
        # Ultima possibilità: una parola del nome ("ichnusa", "heineken"; "birra" -> lista)
        trovati = prodotti_da_parole(testo)
    if any(n in OLI_MOTORE for n in trovati):
        # Olio motore: sempre la lista di tutti gli oli, quelli detti per primi
        trovati = [n for n in trovati if n in OLI_MOTORE] + [n for n in OLI_MOTORE if n not in trovati]
    if len(trovati) > 1:
        scelto = [n for n in trovati if n in SCELTI]
        if scelto:
            return scelto[0]      # già scelto dalla lista
        if (all(listino[n].get('categoria') in CATEGORIE_CIBO for n in trovati)
                and len({listino[n]['prezzo'] for n in trovati}) == 1):
            return prodotto_generico(trovati)   # cibo simile, stesso prezzo: nome generico
        AMBIGUI[:] = trovati      # stesso nome per più prodotti (es. formati diversi): si sceglie dalla lista
        return None
    return trovati[0] if trovati else None


def prodotto_generico(nomi, nome=None):
    """"NUTELLA BISCUITS" + "NUTELLA BREADY" (stesso prezzo) -> "NUTELLA": le parole in comune."""
    comuni = set(nomi[0].split()).intersection(*[set(n.split()) for n in nomi[1:]])
    nome = nome or " ".join(w for w in nomi[0].split() if w in comuni) or nomi[0]
    if nome not in listino:
        listino[nome] = dict(listino[nomi[0]], alias=[])
    return nome


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
    prezzo_detto = prezzo
    if euro is not None and p.get('unita', 'pz') == 'pz':
        # "2 red bull 7 euro": 2 pezzi, 7 euro in tutto; "red bull 3 e 50": 1 pezzo a 3,50
        altri = [float(n.replace(',', '.')) for n in re.findall(NUMERO, testo)]
        altri = [n for n in altri if n != euro and n == int(n) and 0 < n < 100]
        intero = round(euro / prezzo)
        quantita = altri[0] if altri else (intero if intero >= 1 and abs(euro - intero * prezzo) < 0.01 else 1)
        importo = euro
        prezzo_detto = round(euro / quantita, 2)
        if abs(prezzo_detto - prezzo) >= 0.01:
            AVVISI.append(f"prezzo detto {prezzo_detto:.2f} € invece di {prezzo:.2f} € del listino")
    elif euro is not None:
        importo, quantita = euro, euro / prezzo      # AdBlue sfuso: "adblue 13 euro" = 10 litri
    else:
        quantita = primo_numero(testo) or 1.0  # "red bull" da solo = 1
        importo = quantita * prezzo
    return {
        "categoria": nome, "prodotto": nome,
        "reparto": p.get('reparto', 'Market'), "unita": p.get('unita', 'pz'),
        "quantita": round(quantita, 2), "prezzo_unitario": prezzo_detto, "importo": round(importo, 2),
    }


def voce_carburante(testo):
    # "85 euro nero", "77 bianco": senza prodotto è un rifornimento (il tipo non serve per l'Excel)
    categoria = carburante_detto(testo)
    if not categoria:
        if parole_libere(testo):
            return None      # c'è una parola che non conosco: meglio chiedere di ripetere
        categoria = 'Carburante'
    importo = numero_in_euro(testo) or primo_numero(testo)
    if not importo:
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
PAROLE_RESTO = r'\b(lasciat\w*|lascia|eccedenz\w*|resto)\b'


def voce_resto(testo):
    v = voce_sconto(testo)
    if not v:
        return None
    return {"categoria": "Resto lasciato dal cliente", "reparto": "Resto lasciato",
            "importo": -v['importo'], "metodo_pagamento": "Contanti"}


def parole_libere(testo, togli_prodotti=True):
    """Le parole che restano togliendo numeri, pagamenti e parole di servizio ("di", "euro"...)."""
    resto = re.sub(NUMERO, ' ', senza_prodotti(testo) if togli_prodotti else testo)
    for parole in list(PAGAMENTI.values()) + [PAGAMENTO_GENERICO]:
        for p in sorted(parole, key=len, reverse=True):
            resto = re.sub(r'\b' + re.escape(p) + r'\b', ' ', resto)
    resto = re.sub(PAROLE_CREDITO, ' ', resto)
    return [w for w in re.findall(r"[\w'&-]+", resto) if not re.fullmatch(r'[\d.,]+', w)]


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
        prodotto = " ".join(parole_libere(t)).upper() or "DANEA (a mano)"
    return {"categoria": prodotto, "prodotto": prodotto, "reparto": "Market", "unita": "pz",
            "quantita": quantita, "prezzo_unitario": round(importo / quantita, 2),
            "importo": round(importo, 2), "danea_a_mano": True}


def voce_opt(testo):
    """"50 opt": incasso dell'accettatore esterno (OPT). Nessun pagamento, non tocca i contanti."""
    importo = numero_in_euro(testo) or primo_numero(testo)
    if not importo:
        return None
    return {"categoria": "OPT", "reparto": "OPT", "importo": round(importo, 2), "metodo_pagamento": "OPT"}


def voce(testo):
    """Una voce della vendita, o None se il pezzo di frase non si capisce."""
    if re.search(r'\bopt\b', testo):
        return voce_opt(testo)
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


def prodotto_o_ambiguo(testo):
    """Vero se c'è un prodotto, anche se il nome vale per più prodotti (si sceglierà dopo)."""
    AMBIGUI.clear()
    trovato = trova_prodotto_listino(testo) or bool(AMBIGUI)
    AMBIGUI.clear()
    return trovato


def ha_voce(testo):
    return bool(re.search(r'\b(danea|opt)\b', testo) or re.search(PAROLE_SCONTO, testo) or re.search(PAROLE_RESTO, testo)
                or prodotto_o_ambiguo(testo) or carburante_detto(testo))


def dividi_in_pezzi(testo):
    # "50 gasolio, 20 litri adblue e 2 red bull" -> 3 pezzi.
    # Centesimi: "20 e 50" / "20 virgola 50" / "20,50" -> 20.50
    testo = re.sub(r'(\d+)\s*virgola\s*(\d+)', r'\1.\2', testo)
    # "19.90 di gasolio ha lasciato 10 centesimi" -> "19.90 di gasolio, ha lasciato 10 centesimi"
    testo = re.sub(r'\s+(?=(?:(?:mi\s+)?ha\s+)?(?:lasciat|lascia\b|abbuon|sconto\b|arrotond|eccedenz|resto\b))', ', ', testo)
    grezzi = [p.strip() for p in re.split(r',(?!\d)|\s+e\s+|\s+ed\s+|\s+piu\s+|\s+poi\s+', testo) if p.strip()]

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
        # Un importo da solo ("50 e 2 red bull") è un rifornimento, non la quantità del prodotto dopo
        solo_importo = re.search(r'\d', p) and not parole_libere(p)
        if ha_voce(p) or solo_importo:
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
    nuova_quantita = None
    if (nuovo_importo and numero_in_euro(testo_basso) is None and nuovo_importo == int(nuovo_importo)
            and len(voci) == 1 and voci[0].get('reparto') == 'Market' and voci[0].get('unita', 'pz') == 'pz'
            and nuovo_importo < 100):
        # "correggi ultima 3" dopo "2 red bull" = 3 red bull (per l'importo: "correggi ultima 3 euro")
        nuova_quantita, nuovo_importo = nuovo_importo, None
    if not (nuovo_metodo or nuovo_carburante or nuovo_importo or nuova_quantita):
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
        if nuova_quantita:
            v['quantita'] = nuova_quantita
            v['importo'] = f"{nuova_quantita * float(v['prezzo_unitario']):.2f}"
        if nuovo_importo and v.get('reparto') == 'Market' and v.get('unita', 'pz') == 'pz':
            # "correggi ultima 10 euro" dopo "3 red bull": restano 3 pezzi, cambia il prezzo
            v['importo'] = f"{nuovo_importo:.2f}"
            v['prezzo_unitario'] = round(nuovo_importo / float(v.get('quantita') or 1), 2)
        elif nuovo_importo:
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

def scegli_prodotto(candidati):
    """Lista "Quale prodotto?" con i prezzi: il nome scelto, None se annullata."""
    candidati = candidati[:20]
    voci_lista = [f"{n} {listino[n]['prezzo']:.2f}€".replace(',', ' ') for n in candidati]
    try:
        r = subprocess.run(['termux-dialog', 'radio', '-t', '🛒 Quale prodotto?', '-v', ','.join(voci_lista)],
                           capture_output=True, text=True, timeout=110)
        d = json.loads(r.stdout or '{}')
    except Exception:
        return None
    if d.get('code') != -1:
        return None
    if d.get('text') in voci_lista:
        return candidati[voci_lista.index(d['text'])]
    i = d.get('index')
    return candidati[i] if isinstance(i, int) and 0 <= i < len(candidati) else None


for _ in range(3):   # una vendita può avere più nomi da scegliere
    if not AMBIGUI:
        break
    candidati = list(AMBIGUI)
    scelto = scegli_prodotto(candidati)
    if not scelto:
        print(f"❓ Quale prodotto? {', '.join(candidati[:6])}{' …' if len(candidati) > 6 else ''}. "
              "Ripeti con il nome completo. Niente salvato.")
        sys.exit(1)
    SCELTI.add(scelto)
    AMBIGUI.clear()
    voci = [voce(p) for p in pezzi]
if AMBIGUI:
    print("❓ Troppi prodotti da scegliere: ripeti con i nomi completi. Niente salvato.")
    sys.exit(1)

if len(pezzi) > 1 and None in voci:
    # Vendita mista con un pezzo non capito: meglio ridettare che salvare a metà
    non_capiti = ", ".join(f'"{p}"' for p, v in zip(pezzi, voci) if v is None)
    print(f"❓ Non ho capito: {non_capiti}. Niente salvato, ripeti la vendita.")
    sys.exit(1)

if voci == [None]:
    # Niente salvato se non si capisce: meglio ripetere che registrare un importo o un prodotto sbagliato
    # (l'IA tirava a indovinare un carburante: con un prodotto sconosciuto sbagliava)
    if not re.findall(NUMERO, testo_basso):
        print(f"❓ Non ho capito \"{testo_originale}\": nessun importo. Niente salvato.")
    else:
        sconosciute = " ".join(parole_libere(testo_basso)) or testo_originale
        print(f"❓ Non conosco \"{sconosciute}\". Niente salvato: ripeti, oppure di' "
              f"\"danea … euro\" per un prodotto che non ho.")
    sys.exit(1)

if any(float(v['importo']) <= 0 for v in voci if v['reparto'] != 'Sconto'):
    print("❌ Transazione scartata: Nessun importo valido rilevato.")
    sys.exit(1)


# Vendita precedente (per accorgersi di una frase registrata due volte)
PRECEDENTE = None
try:
    with open(csv_file, encoding='utf-8') as f:
        ultima_riga = list(csv.reader(f))[-1]
    PRECEDENTE = (datetime.datetime.strptime(ultima_riga[0], '%Y-%m-%d %H:%M:%S'),
                  json.loads(ultima_riga[1]).get('note', ''))
except Exception:
    pass
adesso_ora = datetime.datetime.now()

# Pagamento: chiesto solo ora, a vendita capita (popup se è detto solo "carta")
# Solo prodotti del negozio (market, fax, taniche AdBlue), senza carburante: si pagano in cassa
SOLO_NEGOZIO = all(v['reparto'] in ('Market', 'Fax') or (v['reparto'] == 'AdBlue' and v.get('unita') != 'l')
                   for v in voci if v['reparto'] not in ('Sconto', 'Resto lasciato')) and \
    any(v['reparto'] not in ('Sconto', 'Resto lasciato') for v in voci)
if all(v['reparto'] == 'OPT' for v in voci):
    metodo = 'OPT'            # l'OPT non ha metodo di pagamento
elif SOLO_NEGOZIO and pagamento_detto(testo_basso) == 'chiedi':
    metodo = 'POS cassa'      # "2 red bull carta" = POS della cassa, senza chiedere
else:
    metodo = metodo_pagamento(testo_basso, carburante=any(v['reparto'] == 'Carburante' for v in voci))
if metodo == 'POS cassa' and any(v['reparto'] == 'Carburante' for v in voci):
    print(CARBURANTE_IN_CASSA)
    sys.exit(1)
salva_voci(voci, pezzi, metodo)
totale = sum(float(v['importo']) for v in voci)

# Cose da controllare: si scrivono PRIMA della vendita, così si leggono anche nel messaggio corto a schermo
if any(v.get('categoria') == 'Carburante' and float(v['importo']) < 5 for v in voci):
    AVVISI.append("solo un importo piccolo, senza prodotto: era carburante?")   # "2 mars" -> "2"
if PRECEDENTE and PRECEDENTE[1] == testo_originale and (adesso_ora - PRECEDENTE[0]).total_seconds() < 30:
    AVVISI.append("frase uguale alla vendita di pochi secondi fa: registrata due volte?")
IMPORTO_MASSIMO_CARBURANTE = 1200   # camion ~1000 €: oltre, forse "19 90" capito come 1990
if any(v['reparto'] == 'Carburante' and float(v['importo']) > IMPORTO_MASSIMO_CARBURANTE for v in voci):
    AVVISI.insert(0, "IMPORTO MOLTO ALTO")
if SOLO_NEGOZIO and metodo in ('POS nero', 'POS bianco'):
    AVVISI.append("solo prodotti del negozio: di solito si pagano IN CASSA (\"correggi ultima in cassa\")")
for detto, nome in SIMILI.items():
    AVVISI.append(f'"{detto}" capito come {nome}')
if AVVISI:
    print("⚠️ CONTROLLA: " + "; ".join(dict.fromkeys(AVVISI)) + " — se è sbagliata: \"cancella ultima\"")

simbolo = '⚠️' if origine == 'emergenza' or AVVISI else '✅'
if len(voci) == 1:
    print(f"{simbolo} Vendita salvata: {descrivi(voci[0])} - {metodo}")
else:
    print(f"{simbolo} Vendita salvata ({len(voci)} voci, {metodo}): "
          + " + ".join(descrivi(v) for v in voci) + f" = {totale:.2f} €")

avviso_ricevuta(voci, metodo)

# Codice d'uscita letto da avvia_ia.sh per scegliere la vibrazione: 2 = salvata ma da controllare
sys.exit(2 if origine == 'emergenza' or AVVISI else 0)
FINE_FILE
cat > ~/.termux/tasker/numeri.py <<'FINE_FILE'
# Numeri detti a parole -> cifre ("trentacinque" -> 35). Usato da processa_ia.py e info_turno.py.
import re
import unicodedata


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


_NUMERI = numeri_in_lettere()
_NUMERI.update({'un': 1, 'una': 1})   # "un centesimo", "una ichnusa"
_REGEX = re.compile(r'\b(' + '|'.join(sorted(_NUMERI, key=len, reverse=True)) + r')\b')


def in_cifre(testo):
    """"versamento cinquanta" -> "versamento 50"."""
    return _REGEX.sub(lambda m: str(_NUMERI[m.group(1)]), testo.lower())


def senza_accenti(testo):
    """"estathé" -> "estathe" (i nomi del listino sono senza accenti)."""
    return "".join(c for c in unicodedata.normalize('NFD', testo) if unicodedata.category(c) != 'Mn')
FINE_FILE
cat > ~/.termux/tasker/invia_mail.py <<'FINE_FILE'
import glob, json, os, smtplib, ssl, subprocess, sys
from email.message import EmailMessage

# Invio automatico della chiusura per email (Gmail, Libero, Outlook: il server si sceglie dall'indirizzo).
# I dati di accesso stanno SOLO sul telefono, in ~/.cassa_email.json (mai su GitHub).
#
# Uso:  python3 invia_mail.py configura          -> chiede mittente, password per app, destinatario
#       python3 invia_mail.py prova              -> manda una mail di prova
#       python3 invia_mail.py invia <cartella>   -> manda i file della cartella del turno (alla chiusura)
#       python3 invia_mail.py coda               -> rimanda le mail rimaste in coda (senza internet)

CONFIG = os.path.expanduser('~/.cassa_email.json')
# dominio -> (server, porta, SSL diretto); con SSL False si usa STARTTLS
SERVER = {
    'gmail.com': ('smtp.gmail.com', 465, True), 'googlemail.com': ('smtp.gmail.com', 465, True),
    'libero.it': ('smtp.libero.it', 465, True), 'inwind.it': ('smtp.libero.it', 465, True),
    'iol.it': ('smtp.libero.it', 465, True), 'blu.it': ('smtp.libero.it', 465, True),
    'outlook.com': ('smtp-mail.outlook.com', 587, False), 'outlook.it': ('smtp-mail.outlook.com', 587, False),
    'hotmail.com': ('smtp-mail.outlook.com', 587, False), 'hotmail.it': ('smtp-mail.outlook.com', 587, False),
    'live.com': ('smtp-mail.outlook.com', 587, False), 'live.it': ('smtp-mail.outlook.com', 587, False),
}


def server_di(mittente):
    return SERVER.get(mittente.split('@')[-1].lower(), ('smtp.gmail.com', 465, True))
CODA = os.path.expanduser('~/.cassa_email_coda')
FINTO = os.environ.get('INVIA_MAIL_FINTO')   # solo per la prova su computer: salva la mail invece di spedirla


def leggi_config():
    try:
        with open(CONFIG, encoding='utf-8') as f:
            c = json.load(f)
        return c if c.get('mittente') and c.get('password') and c.get('destinatario') else None
    except Exception:
        return None


def registra(testo):
    """Esito nel registro (debug_tasker.log), per capire cosa è successo."""
    try:
        import datetime
        with open(os.path.expanduser('~/debug_tasker.log'), 'a') as f:
            f.write(f"{datetime.datetime.now():%H:%M:%S} mail: {testo}\n")
    except Exception:
        pass


def notifica(titolo, testo):
    try:
        subprocess.Popen(['termux-notification', '--id', 'cassa_email', '--title', titolo, '--content', testo],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def spedisci(c, oggetto, corpo, allegati):
    msg = EmailMessage()
    msg['From'], msg['To'], msg['Subject'] = c['mittente'], c['destinatario'], oggetto
    msg.set_content(corpo)
    for path in allegati:
        with open(path, 'rb') as f:
            dati = f.read()
        if path.endswith('.xlsx'):
            tipo = ('application', 'vnd.openxmlformats-officedocument.spreadsheetml.sheet')
        else:
            tipo = ('text', 'plain')
        msg.add_attachment(dati, maintype=tipo[0], subtype=tipo[1], filename=os.path.basename(path))
    if FINTO:
        with open(os.path.join(FINTO, 'mail_%d.eml' % len(os.listdir(FINTO))), 'wb') as f:
            f.write(bytes(msg))
        return
    host, porta, ssl_diretto = server_di(c['mittente'])
    if ssl_diretto:
        server = smtplib.SMTP_SSL(host, porta, context=ssl.create_default_context(), timeout=30)
    else:
        server = smtplib.SMTP(host, porta, timeout=30)
        server.starttls(context=ssl.create_default_context())
    with server as s:
        s.login(c['mittente'], c['password'])
        s.send_message(msg)


def file_del_turno(cartella):
    excel = sorted(glob.glob(os.path.join(cartella, 'Excel', '*.xlsx')))
    riepilogo = sorted(glob.glob(os.path.join(cartella, 'Documenti', '*.txt')))
    return excel, riepilogo


def invia_turno(cartella, prova=False):
    """Spedisce la chiusura; se non riesce la mette in coda. Restituisce il messaggio da mostrare."""
    c = leggi_config()
    if not c:
        return ""
    excel, riepilogo = file_del_turno(cartella)
    if not excel and not riepilogo:
        registra(f"niente da mandare in {cartella}")
        return "📧 Mail: nessun file da mandare"
    nome = os.path.basename(cartella.rstrip('/'))            # es. 2026-10-05_Notte
    if prova:
        c = dict(c, destinatario=c['mittente'])   # turno di prova: la mail arriva solo a me, non al lavoro
    corpo = "Chiusura turno " + nome.replace('_', ' ') + "\n\n"
    if riepilogo:
        with open(riepilogo[0], encoding='utf-8') as f:
            corpo += f.read().split("\n📋")[0]               # riepilogo senza l'elenco di tutte le vendite
    try:
        spedisci(c, f"Chiusura turno {nome.replace('_', ' ')}", corpo, excel + riepilogo)
        notifica("📧 Mail della chiusura inviata", f"{nome} → {c['destinatario']}")
        registra(f"inviata {nome} a {c['destinatario']} ({len(excel + riepilogo)} allegati)")
        return f"📧 Mail inviata a {c['destinatario']} ({len(excel + riepilogo)} allegati)"
    except smtplib.SMTPAuthenticationError:
        notifica("📧 Mail NON inviata: password sbagliata",
                 "Rifai: python3 ~/.termux/tasker/invia_mail.py configura")
        registra(f"password rifiutata, {nome} in coda")
        esito = "📧 Mail NON inviata: password rifiutata (rifai la configurazione). Resta in coda"
    except Exception as e:
        notifica("📧 Mail in coda (niente internet?)", f"{nome}: riparte da sola al prossimo comando")
        registra(f"non inviata ({e}), {nome} in coda")
        esito = "📧 Mail in coda (niente internet?): riparte da sola al prossimo comando"
    metti_in_coda(cartella, prova)
    return esito


def metti_in_coda(cartella, prova=False):
    # una riga per cartella: "<cartella>\t1" = turno di prova (mail solo a me), "\t0" = turno vero
    coda = [r for r in leggi_coda() if r[0] != cartella] + [(cartella, bool(prova))]
    with open(CODA, 'w', encoding='utf-8') as f:
        f.write("".join(f"{c}\t{int(p)}\n" for c, p in coda))


def leggi_coda():
    """[(cartella, prova)]; le righe vecchie senza segno valgono come prova se il nome ha TEST."""
    try:
        with open(CODA, encoding='utf-8') as f:
            righe = [r.rstrip('\n') for r in f if r.strip()]
    except Exception:
        return []
    coda = []
    for r in righe:
        cartella, _, segno = r.partition('\t')
        coda.append((cartella, segno == '1' if segno else '_TEST' in cartella))
    return coda


def svuota_coda():
    coda = leggi_coda()
    if not coda:
        return
    os.remove(CODA)
    for cartella, prova in coda:
        if os.path.isdir(cartella):
            invia_turno(cartella, prova)   # se fallisce di nuovo torna in coda


def configura():
    import getpass
    print("📧 CONFIGURAZIONE EMAIL")
    print("Gmail: serve la 'password per le app' di Google (16 lettere), NON la password normale.")
    print("Libero: di solito va bene la password normale della casella.")
    print("I dati restano solo su questo telefono.\n")
    vecchia = leggi_config() or {}
    mittente = input(f"Indirizzo che invia (Gmail o Libero){' [' + vecchia['mittente'] + ']' if vecchia.get('mittente') else ''}: ").strip() \
        or vecchia.get('mittente', '')
    password = getpass.getpass("Password (non si vede mentre scrivi): ").replace(' ', '') \
        or vecchia.get('password', '')
    destinatario = input(f"Indirizzo a cui mandare la chiusura"
                         f"{' [' + vecchia['destinatario'] + ']' if vecchia.get('destinatario') else ''}: ").strip() \
        or vecchia.get('destinatario', '')
    if not (mittente and password and destinatario):
        print("❌ Mancano dei dati: niente salvato.")
        sys.exit(1)
    with open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump({'mittente': mittente, 'password': password, 'destinatario': destinatario}, f)
    os.chmod(CONFIG, 0o600)
    print("✅ Salvato. Ora prova: python3 ~/.termux/tasker/invia_mail.py prova")


def prova():
    c = leggi_config()
    if not c:
        print("❌ Email non configurata: python3 ~/.termux/tasker/invia_mail.py configura")
        sys.exit(1)
    try:
        spedisci(c, "Prova cassa vocale", "Se leggi questa mail, l'invio automatico della chiusura funziona.", [])
        print(f"✅ Mail di prova inviata a {c['destinatario']}")
    except smtplib.SMTPAuthenticationError:
        print("❌ Il server non accetta indirizzo/password.\n"
              "   Gmail: serve la 'password per le app' (16 lettere). Libero: controlla la password e che\n"
              "   nelle impostazioni di Libero Mail sia permesso l'accesso da programmi esterni.\n"
              "   Poi rifai: python3 ~/.termux/tasker/invia_mail.py configura")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Invio non riuscito ({e}). C'è internet?")
        sys.exit(1)


if __name__ == '__main__':
    comando = sys.argv[1] if len(sys.argv) > 1 else ''
    if comando == 'configura':
        configura()
    elif comando == 'prova':
        prova()
    elif comando == 'invia' and len(sys.argv) > 2:
        svuota_coda()
        print(invia_turno(sys.argv[2]))
    elif comando == 'coda':
        print("📭 Nessuna mail in coda" if not leggi_coda() else f"📤 In coda: {len(leggi_coda())}, riprovo…")
        svuota_coda()
        print("✅ Coda vuota" if not leggi_coda() else "⚠️ Ancora in coda (guarda il registro)")
    else:
        print(__doc__ or "Uso: invia_mail.py configura | prova | invia <cartella> | coda")
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
# Aggiunge anche i prodotti fissi che mancano (es. fax / fotocopie).
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

# Prodotti fissi: aggiunti solo se mancano
FISSI = {
    'Fax / fotocopie': {'prezzo': 0.30, 'reparto': 'Fax', 'unita': 'fogli',
                        'alias': ['fax', 'fotocopie', 'fotocopia', 'copie', 'fogli', 'foglio',
                                  'lettera di vettura', 'lettere di vettura', 'cmr', 'delivery']},
}
if os.path.exists(p):
    with open(p, encoding='utf-8') as f:
        listino = json.load(f)
else:
    listino = {}
mancanti = [n for n, v in FISSI.items()
            if not any(isinstance(x, dict) and x.get('reparto') == v['reparto'] for x in listino.values())]
if mancanti:
    for n in mancanti:
        listino[n] = FISSI[n]
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(listino, f, indent=2, ensure_ascii=False)
    print('➕ Aggiunto al listino: ' + ', '.join(mancanti))
FINE_FILE
cat > ~/.termux/tasker/danea_listino.py <<'FINE_FILE'
import json, os, re, shutil, sys

# Converte l'esportazione prodotti di Danea Easyfatt (Prodotti.xlsx) nel listino della cassa vocale.
# Uso: python3 danea_listino.py ~/storage/downloads/Prodotti.xlsx [~/prezzi.json]
# Colonne attese: Categoria, Descrizione, Listino 1 (ivato).
#
# Per ogni prodotto crea i "nomi a voce" (alias) togliendo formati e misure:
# "COCA COLA BOTT 400" -> "coca cola". I nomi extra si aggiungono in ALIAS_EXTRA qui sotto.

ESCLUSE = {'CARBURANTI'}  # i carburanti si dettano come "20 di gasolio", non dal listino

# Nome Danea -> nomi detti a voce in più
ALIAS_EXTRA = {
    'RED BULL': ['red bull', 'redbull'],
    'ACQUA BOTT 0,500': ['acqua piccola', 'acqua naturale', 'bottiglietta acqua', 'acqua'],
    'ACQUA CONFEZ.1,5 LITRI': ['acqua grande', 'acqua big', 'acqua 1 litro e mezzo'],
    'BOX 6 BOTTIGLIE ACQUA': ['box acqua', 'confezione acqua'],
    'COCA COLA BOTT 400': ['coca', 'coca cola', 'cocacola'],
    'FANTA 0,400 CL': ['fanta'],
    'ESTATHE BRICK': ['estathe', 'estate', 'the brick'],
    'ESTA THE LIMONE PESCA': ['estathe bottiglia', 'the limone', 'the pesca'],
    'GHIACCIOLO': ['ghiaccioli', 'ghiacciolo'],
    'SNIKERS': ['snickers'],
    'M E MS': ['m&m', 'emmenems', 'm and m'],
    'KINDERE CIOCCOLATO': ['kinder cioccolato'],
    'SRTUDIDI FICHI': ['strudel di fichi', 'strudel'],
    'PRINGLESS MGUSTI VARI': ['pringles'],
    'PATATINA AMICA CHIPS': ['patatine', 'amica chips'],
}
SPECIALI = {
    'ADBLUE SFUSO': {'nome': 'AdBlue sfuso', 'reparto': 'AdBlue', 'unita': 'l',
                     'alias': ['adblue', 'ad blue', 'adblue sfuso', 'sfuso']},
    'TANICA ADBLUE': {'nome': 'AdBlue tanica', 'reparto': 'AdBlue', 'unita': 'pz',
                      'alias': ['tanica adblue', 'taniche adblue', 'adblue tanica',
                                'adblue taniche', 'tanica di adblue', 'taniche di adblue']},
    'TEFAX': {'nome': 'Fax / fotocopie', 'reparto': 'Fax', 'unita': 'fogli',
              'alias': ['fax', 'telefax', 'fotocopie', 'fotocopia', 'copie', 'fogli', 'foglio',
                        'lettera di vettura', 'lettere di vettura', 'cmr', 'delivery']},
}
# Parole che non possono essere il nome di un prodotto da sole (carburanti, pagamenti, comandi)
RISERVATE = {'verde', 'benzina', 'gasolio', 'diesel', 'carta', 'pos', 'bancomat', 'contanti', 'cash', 'nero', 'bianco', 'cassa',
             'euro', 'litri', 'litro', 'turno', 'ultima', 'penultima', 'totali', 'market', 'ia',
             'set', 'kit', 'mini', 'big', 'plus', 'pro', 'per', 'con', 'di', 'da'}
# Parole di formato che non si dicono a voce
FORMATO = {'bott', 'bott.', 'conf', 'conf.', 'confez', 'confez.', 'brick', 'pz', 'pezzi', 'ml', 'cl', 'lt',
           'gr', 'kg', 'cm', 'mm', 'x', 'formato'}


def alias_da_nome(descrizione):
    """Due nomi a voce: senza codici ("lampadina") e con i codici ("lampadina h7")."""
    corto, lungo = [], []
    for p in re.split(r'[\s/]+', descrizione.lower()):
        p = p.strip('.,;:()')
        if not p or p in FORMATO:
            continue
        if re.search(r'\d', p):
            if re.search(r'[a-z]', p) and not re.fullmatch(r'[\d.,]+(ml|cl|lt|l|gr|g|kg|cm|mm|m|w|x)', p):
                lungo.append(p)  # codice tipo h7, p21w, 5w-40: aiuta a distinguere
            continue             # misure (0,500 / 400 / 150ml) non si dicono
        corto.append(p)
        lungo.append(p)
    alias = []
    for a in (" ".join(corto), " ".join(lungo)):
        if len(a) >= 3 and a not in RISERVATE and a not in alias:
            alias.append(a)
    return alias


def converti(path_xlsx):
    import openpyxl
    ws = openpyxl.load_workbook(path_xlsx, read_only=True).active
    righe = list(ws.iter_rows(values_only=True))
    intest = [str(c or '').strip().lower() for c in righe[0]]
    i_cat = intest.index('categoria')
    i_desc = intest.index('descrizione')
    i_prezzo = next(i for i, c in enumerate(intest) if c.startswith('listino'))

    listino, saltati = {}, []
    for r in righe[1:]:
        desc = str(r[i_desc] or '').strip()
        cat = str(r[i_cat] or '').strip().upper()
        prezzo = r[i_prezzo]
        if not desc or r[0] == '-':
            continue  # righe di intestazione categoria
        if cat in ESCLUSE:
            continue
        if not isinstance(prezzo, (int, float)) or prezzo <= 0:
            saltati.append(desc)
            continue
        if desc.upper() in SPECIALI:
            s = SPECIALI[desc.upper()]
            listino[s['nome']] = {'prezzo': float(prezzo), 'alias': s['alias'],
                                  'reparto': s['reparto'], 'unita': s['unita'], 'danea': desc}
            continue
        alias = alias_da_nome(desc) + ALIAS_EXTRA.get(desc.upper(), [])
        if not alias:
            saltati.append(desc)
            continue
        listino[desc.upper()] = {'prezzo': float(prezzo), 'alias': sorted(set(alias)),
                                 'reparto': 'Market', 'unita': 'pz', 'categoria': cat or 'ALTRO'}
    return listino, saltati


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Uso: python3 danea_listino.py Prodotti.xlsx [prezzi.json]")
        sys.exit(1)
    destinazione = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else '~/prezzi.json')
    listino, saltati = converti(os.path.expanduser(sys.argv[1]))
    if os.path.exists(destinazione):
        shutil.copy(destinazione, destinazione + '.vecchio')
    with open(destinazione, 'w', encoding='utf-8') as f:
        json.dump(listino, f, indent=1, ensure_ascii=False)
    print(f"✅ Listino creato: {len(listino)} prodotti in {destinazione}")
    if saltati:
        print(f"⚠️ Saltati {len(saltati)} prodotti senza prezzo o senza nome utilizzabile: {', '.join(saltati[:10])}")
FINE_FILE
cat > ~/.termux/tasker/excel_turno.py <<'FINE_FILE'
import json, os
from datetime import datetime, date, time, timedelta

# Compila il modello Excel del distributore ("TURNO NUOVO") con i dati del turno appena chiuso
# e prepara ("imbastisce") il file del turno successivo.
# Si scrive SOLO nelle caselle bianche: formule e protezione del foglio restano intatte.

MODELLO = os.path.expanduser('~/.termux/tasker/modello_turno.xlsx')
PATH_STATO = os.path.expanduser('~/stato_cassa.json')  # contatore AdBlue, taniche, avanzo tra un turno e l'altro

# Caselle del modello (nell'ordine in cui le sommano le formule del foglio)
DANEA = [(f'E{r}', f'H{r}') for r in range(2, 30)]                                  # descrizione, importo
TELEFAX = [f'{c}{r}' for r in range(21, 26) for c in 'ABCD']
ADBLUE_LITRI = [f'{c}17' for c in 'IJKLMNO'] + [f'{c}18' for c in 'IJKLMN']
SCONTRINI_POS = [f'{c}{r}' for r in range(27, 33) for c in 'STUV']
OPT = [f'{c}{r}' for r in (2, 3) for c in 'IJKLMNO']                                # accettatore esterno
CREDITI_CLIENTI = [(f'I{r}', f'L{r}') for r in range(8, 16)]   # nome, importo
CREDITI_RISCOSSI = [(f'M{r}', f'O{r}') for r in range(8, 16)]
# La notte porta la data del giorno in cui finisce: pomeriggio del 4 -> notte del 5 -> mattina del 5
SUCCESSIVO = {'Mattina': ('Pomeriggio', 0), 'Pomeriggio': ('Notte', 1), 'Notte': ('Mattina', 0)}


def turno_di_prova():
    """Vero se il turno aperto è di prova ("apertura turno prova")."""
    try:
        with open(os.path.expanduser('~/turno_corrente.json'), encoding='utf-8') as f:
            return bool(json.load(f).get('prova'))
    except Exception:
        return False


def path_stato():
    # Turno di prova: contatore, taniche e orari in un file a parte, quello vero non si tocca
    return PATH_STATO.replace('.json', '_prova.json') if turno_di_prova() else PATH_STATO


def leggi_stato():
    try:
        with open(path_stato(), encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def salva_stato(stato):
    with open(path_stato(), 'w', encoding='utf-8') as f:
        json.dump(stato, f)


def riempi(ws, caselle, valori, avvisi, nome, nomi=None):
    """Scrive i valori nelle caselle, uno per casella. Se le caselle finiscono si riparte dalla
    prima sommando (la 21ª voce si somma alla 1ª, la 22ª alla 2ª...): il totale resta giusto.
    nomi: per i crediti, caselle del nome accanto all'importo (i nomi si uniscono con " + ")."""
    coppie = [(round(v, 2), n) for v, n in zip(valori, nomi or [None] * len(valori)) if v]
    if len(coppie) > len(caselle):
        avvisi.append(f"{nome}: {len(coppie)} voci per {len(caselle)} caselle: "
                      "dalla prima casella in poi alcune sono la somma di due voci")
    somme, testi = {}, {}
    for i, (v, n) in enumerate(coppie):
        k = i % len(caselle)
        somme[k] = round(somme.get(k, 0.0) + v, 2)
        if n is not None:
            testi[k] = f"{testi[k]} + {n}" if k in testi else n
    for k, v in somme.items():
        if nomi is None:
            ws[caselle[k]] = v
        else:
            ws[caselle[k][0]] = testi[k]
            ws[caselle[k][1]] = v


def nome_file(giorno, tipo, prova=False):
    return f"{giorno.strftime('%d_%m_%Y')}_{tipo.lower()}{'_TEST' if prova else ''}.xlsx"


def ora_da_testo(testo):
    try:
        h, m, s = (int(x) for x in str(testo).split()[0].split(':'))
        return time(h, m, s)
    except Exception:
        return None


def crea_excel(righe, turno, orario_terminale, cartella):
    """Crea <data>_<turno>.xlsx (turno concluso) e il file del turno successivo.
    Restituisce (lista di messaggi, stato aggiornato).
    "ORA CHIUSURA" (I24) è l'orario del terminale pompe del turno PRECEDENTE:
    quello inserito oggi va nel file del turno dopo."""
    import openpyxl
    avvisi = []
    stato = leggi_stato()
    voci = []
    for r in righe:
        try:
            voci.append(json.loads(r[1]))
        except Exception:
            pass
    imp = lambda v: float(v.get('importo', 0) or 0)
    q = lambda v: float(v.get('quantita', 1) or 1)
    giorno = date.fromisoformat(turno['data_file'])

    wb = openpyxl.load_workbook(MODELLO)
    wb.calculation.fullCalcOnLoad = True  # i totali del foglio li calcola Excel all'apertura
    ws = wb.active

    # Intestazione: data, turno, ora chiusura del turno precedente
    ws['I20'] = datetime.combine(giorno, time())
    ws['I22'] = turno['tipo'].upper()
    if ora_da_testo(stato.get('orario_chiusura')):
        ws['I24'] = ora_da_testo(stato['orario_chiusura'])
    else:
        avvisi.append("ora chiusura del turno precedente sconosciuta: scrivila a mano")
    ora_oggi = ora_da_testo(orario_terminale)
    if not ora_oggi:
        avvisi.append("orario terminale non inserito: nel file del turno dopo va scritto a mano")

    # DANEA: prodotti market raggruppati ("3x RED BULL")
    gruppi = {}
    for v in voci:
        if v.get('reparto') == 'Market':
            n, tot = gruppi.get(v['categoria'], (0.0, 0.0))
            gruppi[v['categoria']] = (n + q(v), tot + imp(v))
    danea = sorted(gruppi.items(), key=lambda x: -x[1][1])
    if len(danea) > len(DANEA):
        avvisi.append(f"DANEA: {len(danea)} prodotti, righe {len(DANEA)}: gli ultimi sono sommati in 'ALTRI'")
        resto = danea[len(DANEA) - 1:]
        danea = danea[:len(DANEA) - 1] + [('ALTRI', (sum(x[1][0] for x in resto), sum(x[1][1] for x in resto)))]
    for (c_desc, c_imp), (nome, (n, tot)) in zip(DANEA, danea):
        ws[c_desc] = nome if n == 1 else f"{n:g}x {nome}"
        ws[c_imp] = round(tot, 2)

    # TELEFAX, litri AdBlue sfuso
    riempi(ws, TELEFAX, [imp(v) for v in voci if v.get('reparto') == 'Fax'], avvisi, "TELEFAX")
    litri = [q(v) for v in voci if v.get('reparto') == 'AdBlue' and v.get('unita') == 'l']
    riempi(ws, ADBLUE_LITRI, litri, avvisi, "ADBLUE")

    # Crediti clienti (non pagati ora) e crediti riscossi (vecchi crediti pagati oggi)
    for reparto, caselle, nome in (('Credito cliente', CREDITI_CLIENTI, "CREDITI CLIENTI"),
                                   ('Credito riscosso', CREDITI_RISCOSSI, "CREDITI RISCOSSI")):
        crediti = [v for v in voci if v.get('reparto') == reparto]
        riempi(ws, caselle, [imp(v) for v in crediti], avvisi, nome,
               nomi=[v.get('cliente') or '?' for v in crediti])

    # Abbuoni (centesimi in meno) e resti lasciati dai clienti (centesimi in più): non hanno caselle,
    # finiscono nella DIFFERENZA del foglio. Una nota (A39) spiega da dove viene.
    note = []
    for reparto, titolo in (('Sconto', 'ABBUONI'), ('Resto lasciato', 'RESTI LASCIATI DAI CLIENTI')):
        lista = [imp(v) for v in voci if v.get('reparto') == reparto]
        if lista:
            totale = round(sum(lista), 2)
            note.append(f"{titolo}: {'+' if totale > 0 else '-'} {abs(totale):.2f} € ({len(lista)} {'volta' if len(lista) == 1 else 'volte'})".replace('.', ','))
    if note:
        ws['A39'] = " | ".join(note) + " - compaiono nella differenza"

    # Versamento: numero di banconote per taglio (N24 = da 500 ... N30 = da 5); il foglio fa i totali
    for taglio, n in (turno.get('banconote_versamento') or {}).items():
        riga = {500: 24, 200: 25, 100: 26, 50: 27, 20: 28, 10: 29, 5: 30}.get(int(taglio))
        if riga and n:
            ws[f'N{riga}'] = n

    # OPT (accettatore esterno): un importo per casella
    riempi(ws, OPT, [imp(v) for v in voci if v.get('reparto') == 'OPT'], avvisi, "OPT")

    # Pagamenti con carta: i tre POS "esterni" come totali, il POS della cassa uno scontrino per vendita
    metodo = lambda v: {'Carta carburante': 'Petrolifere'}.get(v.get('metodo_pagamento'), v.get('metodo_pagamento'))
    for casella, nome in (('D9', 'Petrolifere'), ('D12', 'POS nero'), ('D14', 'POS bianco')):
        totale = round(sum(imp(v) for v in voci if metodo(v) == nome), 2)
        if totale:
            ws[casella] = totale
    per_scontrino = {}
    for v in voci:
        if metodo(v) == 'POS cassa':
            chiave = v.get('transazione') or id(v)
            per_scontrino[chiave] = per_scontrino.get(chiave, 0.0) + imp(v)
    riempi(ws, SCONTRINI_POS, list(per_scontrino.values()), avvisi, "SCONTRINI POS")

    # Contatore AdBlue e taniche: iniziali dal turno prima, finali calcolati dalle vendite
    contatore_finale = taniche_attuali = None
    if stato.get('contatore') is not None:
        ws['O20'] = stato['contatore']
        contatore_finale = round(stato['contatore'] + sum(litri), 2)
        ws['O19'] = contatore_finale
    else:
        avvisi.append("contatore AdBlue iniziale sconosciuto: di' \"contatore adblue …\" all'apertura")
    vendute = sum(q(v) for v in voci if v.get('reparto') == 'AdBlue' and v.get('unita') != 'l')
    if stato.get('taniche') is not None:
        ws['K30'] = stato['taniche']
        taniche_attuali = stato['taniche'] - vendute
        ws['K31'] = taniche_attuali
    else:
        avvisi.append("taniche AdBlue sconosciute: di' \"contatore taniche …\" all'apertura")

    # Cassa: avanzo precedente; nei "spiccioli cassetto" i contanti che dovrebbero esserci
    avanzo = turno.get('avanzo')
    if avanzo is not None:
        ws['D7'] = avanzo
    # Cassaforte: va in "IN CASSAFORTE" (I28), il foglio la somma da solo all'avanzo attuale
    contanti = sum(imp(v) for v in voci if v.get('metodo_pagamento') == 'Contanti')
    totale_cassa = round((avanzo or 0) + contanti - (turno.get('versamento') or 0), 2)
    cassaforte = turno.get('cassaforte') or 0
    if cassaforte:
        ws['I28'] = cassaforte
    ws['D34'] = round(totale_cassa - cassaforte, 2)

    os.makedirs(cartella, exist_ok=True)
    path_turno = os.path.join(cartella, nome_file(giorno, turno['tipo'], turno.get('prova') or turno.get('nomi_test')))
    wb.save(path_turno)

    # Turno successivo "imbastito"
    tipo_dopo, giorni = SUCCESSIVO[turno['tipo']]
    giorno_dopo = giorno + timedelta(days=giorni)
    cassetto = turno.get('contati') if turno.get('contati') is not None else totale_cassa - cassaforte
    avanzo_dopo = round(cassetto + cassaforte, 2)
    wb2 = openpyxl.load_workbook(MODELLO)
    wb2.calculation.fullCalcOnLoad = True
    ws2 = wb2.active
    ws2['I20'] = datetime.combine(giorno_dopo, time())
    ws2['I22'] = tipo_dopo.upper()
    ws2['D7'] = avanzo_dopo
    if ora_oggi:
        ws2['I24'] = ora_oggi
    if cassaforte:
        ws2['I28'] = cassaforte
    if contatore_finale is not None:
        ws2['O20'] = contatore_finale
    if taniche_attuali is not None:
        ws2['K30'] = taniche_attuali
    path_dopo = os.path.join(cartella, nome_file(giorno_dopo, tipo_dopo, turno.get('prova') or turno.get('nomi_test')))
    if not os.path.exists(path_dopo):  # non sovrascrivere un turno già compilato
        wb2.save(path_dopo)

    stato.update({'contatore': contatore_finale if contatore_finale is not None else stato.get('contatore'),
                  'taniche': taniche_attuali if taniche_attuali is not None else stato.get('taniche'),
                  'avanzo': avanzo_dopo,
                  'orario_chiusura': ora_oggi.strftime('%H:%M:%S') if ora_oggi else None})
    salva_stato(stato)

    breve = lambda p: "Download/" + os.path.relpath(p, os.path.expanduser('~/storage/downloads'))
    messaggi = [f"📗 Excel: {breve(path_turno)}",
                f"📘 Turno dopo: {breve(path_dopo)}"]
    return messaggi + [f"⚠️ {a}" for a in avvisi], stato
FINE_FILE
cat > ~/info_turno.py <<'FINE_FILE'
import csv
import json
import os
import sys
from datetime import datetime, timedelta
import shutil
import glob
import re
import subprocess

# I moduli della cassa vocale (excel_turno.py) stanno nella cartella di Tasker
sys.path.insert(0, os.path.expanduser("~/.termux/tasker"))

# Uso: python3 info_turno.py [notifica | ultimi | totali | market | adblue |
#                             apri turno | chiudi turno [HH:MM] |
#                             cancella ultima | cancella penultima | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
PATH_TURNO = os.path.expanduser("~/turno_corrente.json")
PATH_ULTIMO_CONTEGGIO = os.path.expanduser("~/ultimo_conteggio.txt")
# Se esiste: i turni VERI hanno comunque TEST nel nome dei file (per non confonderli con quelli fatti a mano)
PATH_NOMI_TEST = os.path.expanduser("~/.cassa_nomi_test")
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
        metodo = str(data.get("metodo_pagamento", "altro"))
        metodo = {"carta carburante": "Petrolifere", "pos": "POS"}.get(metodo.lower(), metodo)
        if metodo.islower():
            metodo = metodo.capitalize()
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


SIGLE = {"Contanti": "CON", "POS bianco": "BIA", "POS nero": "NER", "Petrolifere": "PET", "POS cassa": "CAS"}


def sigla(metodo):
    return SIGLE.get(metodo, metodo[:3].upper())


def importo_da_testo(testo):
    """'150', '150,50', '150.50 €', 'cinquanta' -> 150.5; None se vuoto o non valido."""
    try:
        from numeri import in_cifre
        testo = in_cifre(testo or "")
    except ImportError:
        pass
    testo = re.sub(r'(\d+):(\d{2})\b', r'\1.\2', testo or "")   # "20:30" scritto come un orario = 20,30
    m = re.search(r'\d+(?:[.,]\d{1,2})?', (testo or "").replace(" ", ""))
    return float(m.group(0).replace(",", ".")) if m else None


def euro(x):
    return f"{x:.2f} €"


# ---------- turno ----------

def tipo_turno(momento, forzato=""):
    """Il turno il cui inizio (6, 14, 22) è più vicino all'orario dato, e la sua data d'inizio.
    forzato: "mattina"/"pomeriggio"/"notte" detto nella frase ("apertura turno notte")."""
    minuti = momento.hour * 60 + momento.minute

    def distanza(nome):
        d = abs(minuti - TURNI[nome][0] * 60)
        return min(d, 1440 - d)

    nome = min(TURNI, key=distanza)
    if (forzato or "").capitalize() in TURNI:
        nome = forzato.capitalize()
    data_inizio = momento.date()
    if nome == 'Notte' and momento.hour >= 12:  # la notte porta la data del giorno dopo (aperta alle 22 del 4 = notte del 5)
        data_inizio += timedelta(days=1)
    return nome, data_inizio


def leggi_turno():
    try:
        with open(PATH_TURNO, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def descrivi_turno(t):
    return f"{t['tipo']} ({TURNI[t['tipo']][1]}) del {t['data']}, aperto alle {t['apertura'][-5:]}"


def turno_aperto():
    # Aperto a voce, oppure vendite già presenti (turni iniziati con le versioni precedenti)
    return bool(leggi_turno() or leggi_csv())


def apri_turno(avanzo_testo="", ora_prec_testo="", contatore_testo="", taniche_testo="", tipo="", prova=""):
    esistente = leggi_turno()
    if esistente:
        print(f"ℹ️ Turno già aperto: {descrivi_turno(esistente)}")
        return
    adesso = datetime.now()
    nome, data_inizio = tipo_turno(adesso, tipo)
    turno = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": adesso.strftime("%Y-%m-%d %H:%M")}
    if prova:
        turno["prova"] = True     # file con TEST nel nome, stato vero (contatore, taniche...) non toccato
    elif os.path.exists(PATH_NOMI_TEST):
        turno["nomi_test"] = True  # periodo di prova: turno vero (mail al lavoro), ma file con TEST nel nome
    turno["documento"] = nuovo_documento(turno, adesso)
    turno["avanzo"] = importo_da_testo(avanzo_testo)
    salva_turno(turno)
    if turno.get("nomi_test"):
        print("📛 Turno vero, file con TEST nel nome (periodo di prova): mail al lavoro")
    if prova:
        print("🧪 TURNO DI PROVA: file con TEST nel nome, contatori veri non toccati")
        try:
            import excel_turno
            shutil.copy(excel_turno.PATH_STATO, excel_turno.path_stato())
        except Exception:
            pass
    print(f"📅 {descrivi_turno(turno)}")
    print(f"💶 Avanzo cassa turno precedente: {euro(turno['avanzo']) if turno['avanzo'] is not None else '(non inserito)'}")
    try:
        import excel_turno
        stato = excel_turno.leggi_stato()
        # Valori scritti nei riquadri dell'apertura. Quelli rimasti dal mio turno precedente
        # non valgono: nel frattempo ci sono stati i turni degli altri. Vuoto = non inserito.
        ora = normalizza_orario(ora_prec_testo)
        stato["orario_chiusura"] = ora if re.fullmatch(r'\d\d:\d\d:\d\d', ora) else None
        if ora and not stato["orario_chiusura"]:
            print(f"⚠️ Ora chiusura precedente {ora}: scrivila a mano nell'Excel")
        contatore = re.search(r'\d+(?:[.,]\d+)?', contatore_testo or "")
        stato["contatore"] = float(contatore.group(0).replace(",", ".")) if contatore else None
        taniche = importo_da_testo(taniche_testo)
        stato["taniche"] = int(taniche) if taniche is not None else None
        excel_turno.salva_stato(stato)
        o, c, tn = stato.get("orario_chiusura"), stato.get("contatore"), stato.get("taniche")
        print(f"🕐 Ora chiusura turno precedente: {o}" if o else "🕐 Ora chiusura precedente non inserita")
        print(f"🧪 AdBlue: contatore {c:g}" if c is not None else "🧪 Di' \"contatore adblue …\" (valore sulla colonnina)")
        print(f"🧪 Taniche: {tn}" if tn is not None else "🧪 Di' \"contatore taniche …\" (taniche in magazzino)")
    except Exception:
        pass
    print(salva_documento([], turno))


def valore_stato(chiave):
    """Valore salvato dal turno prima (per i suggerimenti dei riquadri all'apertura)."""
    try:
        import excel_turno
        v = excel_turno.leggi_stato().get(chiave)
    except Exception:
        v = None
    if v is None:
        return ""
    return f"{v:g}".replace(".", ",") if isinstance(v, float) else str(v)


def salva_turno(turno):
    with open(PATH_TURNO, 'w', encoding='utf-8') as f:
        json.dump(turno, f)


def nuovo_documento(turno, adesso):
    """Documento del turno in Download, ogni turno nella sua cartella:
    Chiusure_Turno/<data>_<turno>/Documenti/<data>_<turno>.txt  (e .../Excel/ per i due Excel).
    Se la cartella esiste già (turno riaperto) si aggiunge l'ora."""
    nome = f"{turno['data_file']}_{turno['tipo']}" + ("_TEST" if turno.get("prova") or turno.get("nomi_test") else "")
    if os.path.exists(os.path.join(CARTELLA_CHIUSURE, nome)):
        nome += f"_{adesso.strftime('%H%M')}"
    return os.path.join(CARTELLA_CHIUSURE, nome, "Documenti", nome + ".txt")


def cartella_turno(t):
    """Cartella del turno (quella che contiene Documenti ed Excel)."""
    doc = t["documento"]
    if os.path.basename(os.path.dirname(doc)) == "Documenti":
        return os.path.dirname(os.path.dirname(doc))
    return os.path.join(CARTELLA_CHIUSURE, os.path.basename(doc)[:-4])  # turni aperti con la versione vecchia


def percorso_breve(path):
    return "Download/" + os.path.relpath(path, os.path.dirname(CARTELLA_CHIUSURE))


def imposta_avanzo(testo):
    """Comando "avanzo 150": inserisce o corregge l'avanzo del turno precedente."""
    valore = importo_da_testo(testo)
    if valore is None:
        print("❓ Di' l'importo, es. \"avanzo 150\" o \"avanzo 150,50\".")
        sys.exit(1)
    t = turno_attuale(leggi_csv())
    t["avanzo"] = valore
    salva_turno(t)
    print(f"💶 Avanzo cassa turno precedente: {euro(valore)}")


def imposta_contatore(testo):
    """"contatore adblue 68624,4" / "contatore taniche 59": valori di partenza del turno."""
    import excel_turno
    try:
        from numeri import in_cifre
        testo = in_cifre(testo)
    except ImportError:
        pass
    testo = re.sub(r'\s+virgola\s+', ',', testo.lower())
    testo = re.sub(r'(\d+):(\d+)\b', r'\1.\2', testo)
    valore = re.search(r'\d+(?:[.,]\d+)?', testo)
    if not valore:
        print("❓ Di' il numero, es. \"contatore adblue 68624,4\" o \"contatore taniche 59\".")
        sys.exit(1)
    valore = float(valore.group(0).replace(",", "."))
    stato = excel_turno.leggi_stato()
    if "tanic" in testo:
        stato["taniche"] = int(valore)
        print(f"🧪 Taniche AdBlue all'inizio del turno: {int(valore)}")
    else:
        stato["contatore"] = valore
        print(f"🧪 Contatore AdBlue all'inizio del turno: {valore:g}")
    excel_turno.salva_stato(stato)


TAGLI = (500, 200, 100, 50, 20, 10, 5)


def leggi_banconote(testo):
    """"200 50 50 50" / "1x200 3x50" / "una da 200 e tre da 50" -> {200: 1, 50: 3}."""
    try:
        from numeri import in_cifre
        testo = in_cifre(testo or "")
    except ImportError:
        testo = (testo or "").lower()
    conta = {}
    for n, taglio in re.findall(r'(\d+)\s*(?:x|\*|da|per|banconot[ae] da|pezzi da)\s*(\d+)', testo):
        if int(taglio) in TAGLI:
            conta[int(taglio)] = conta.get(int(taglio), 0) + int(n)
    testo = re.sub(r'(\d+)\s*(?:x|\*|da|per|banconot[ae] da|pezzi da)\s*(\d+)', ' ', testo)
    for taglio in re.findall(r'\d+', testo):
        if int(taglio) in TAGLI:
            conta[int(taglio)] = conta.get(int(taglio), 0) + 1
    return conta


def cancella_versamento():
    """"cancella versamento": toglie l'ultimo versamento (importo e banconote)."""
    t = turno_attuale(leggi_csv())
    if not t.get("versamenti"):
        print("❌ Nessun versamento da cancellare in questo turno.")
        sys.exit(1)
    ultimo = t["versamenti"].pop()
    t["versamento"] = round((t.get("versamento") or 0) - ultimo["importo"], 2)
    totali = dict(t.get("banconote_versamento") or {})
    for taglio, n in ultimo["banconote"].items():
        totali[taglio] = totali.get(taglio, 0) - n
    t["banconote_versamento"] = {k: v for k, v in totali.items() if v > 0}
    salva_turno(t)
    print(f"🗑️ Versamento di {euro(ultimo['importo'])} cancellato (totale versato nel turno: {euro(t['versamento'])})")


def banconote_calcolate(valore):
    """Le banconote più grandi possibili (se non sono state dette)."""
    conta, resto = {}, round(valore)
    for taglio in TAGLI:
        if resto >= taglio:
            conta[taglio], resto = divmod(resto, taglio)
    return conta, resto


def aggiungi_versamento(testo, banconote_testo=""):
    """"versamento 500": contanti tolti dal cassetto (non vanno più contati negli attesi).
    Le banconote vanno nel riquadro VERSAMENTO dell'Excel (numero di pezzi per taglio)."""
    valore = importo_da_testo(re.sub(r'\s+virgola\s+', ',', testo))
    if valore is None:
        print("❓ Di' l'importo, es. \"versamento 500\".")
        sys.exit(1)
    banconote = leggi_banconote(banconote_testo)
    avviso = ""
    if not banconote:
        banconote, resto = banconote_calcolate(valore)
        avviso = "⚠️ Banconote non dette: le ho calcolate io, controlla nell'Excel"
        if resto:
            avviso += f" (restano {resto} € che non fanno una banconota)"
    elif sum(t * n for t, n in banconote.items()) != round(valore, 2):
        # Non tornano: niente salvato, il riquadro si ripresenta (codice 3)
        print(f"❌ Le banconote fanno {sum(t * n for t, n in banconote.items())} € ma il versamento è "
              f"{euro(valore)}. Niente salvato.")
        sys.exit(3)
    t = turno_attuale(leggi_csv())
    t["versamento"] = round((t.get("versamento") or 0) + valore, 2)
    totali = {int(k): v for k, v in (t.get("banconote_versamento") or {}).items()}
    for taglio, n in banconote.items():
        totali[taglio] = totali.get(taglio, 0) + n
    t["banconote_versamento"] = {str(k): v for k, v in totali.items()}
    t.setdefault("versamenti", []).append({"importo": valore, "banconote": {str(k): v for k, v in banconote.items()}})
    salva_turno(t)
    if avviso:
        print(avviso)
    print(f"🏦 Versamento registrato: {euro(valore)} (totale versato nel turno: {euro(t['versamento'])})")
    print("   Banconote: " + ", ".join(f"{n}×{taglio}" for taglio, n in sorted(banconote.items(), reverse=True)))


def turno_attuale(righe):
    """Turno aperto a voce; se manca, lo si ricava dalla prima vendita e lo si memorizza."""
    t = leggi_turno()
    if not t:
        try:
            primo = datetime.strptime(righe[0][0][:16], "%Y-%m-%d %H:%M")
        except Exception:
            primo = datetime.now()
        nome, data_inizio = tipo_turno(primo)
        t = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": "(non registrata)"}
    if not t.get("documento"):
        t["documento"] = nuovo_documento(t, datetime.now())
        salva_turno(t)
    return t


def testo_documento(righe, t, finale=False, orario_terminale=""):
    adesso = datetime.now()
    apertura = t['apertura'][-5:] if t['apertura'][0].isdigit() else t['apertura']
    if finale:
        testa = ["🧾 CHIUSURA TURNO"]
        chiusura = adesso.strftime('%H:%M')
    else:
        testa = [f"⏳ TURNO IN CORSO - aggiornato alle {adesso.strftime('%H:%M:%S')}"]
        chiusura = "(turno ancora aperto)"
    testa += [
        f"Data:      {t['data']}",
        f"Turno:     {t['tipo']} ({TURNI[t['tipo']][1]})",
        f"Apertura:  {apertura}",
        f"Chiusura:  {chiusura}",
    ]
    if finale:
        testa.append(f"Terminale pompe: {orario_terminale or '(non inserito)'}")
    testa.append("")
    corpo = prospetto_completo(righe, "RIEPILOGO", t)
    dettaglio = ["", "📋 TUTTE LE VENDITE"] + [
        f"  {v['ora']} {euro(v['importo']):>10} {v['metodo']:<16} {v['note']}" for v in vendite(righe)]
    return "\n".join(testa + corpo + dettaglio) + "\n"


def scrivi_sicuro(path, contenuto):
    # Prima un file temporaneo, poi lo scambio: il documento non resta mai scritto a metà
    tmp = path + ".tmp"
    with open(tmp, 'w', encoding='utf-8', newline='') as f:
        f.write(contenuto)
    os.replace(tmp, path)


def salva_documento(righe, t, finale=False, orario_terminale=""):
    """Scrive (o riscrive) in Download il documento del turno e la copia dei dati (_dati.csv)."""
    try:
        path_doc = t["documento"]
        os.makedirs(os.path.dirname(path_doc), exist_ok=True)
        scrivi_sicuro(path_doc, testo_documento(righe, t, finale, orario_terminale))
        dati = [",".join(INTESTAZIONE)] + [
            ",".join('"' + c.replace('"', '""') + '"' for c in r) for r in righe]
        scrivi_sicuro(path_doc[:-4] + "_dati.csv", "\n".join(dati) + "\n")
        return f"💾 {percorso_breve(path_doc)}"
    except Exception as e:
        return f"⚠️ Copia in Download non riuscita ({e})"


def salva_copia():
    """Aggiorna il documento in Download con le vendite attuali (dopo ogni transazione)."""
    if not turno_aperto():
        return
    righe = leggi_csv()
    print(salva_documento(righe, turno_attuale(righe)))


def ripristina():
    """Se il file delle vendite in Termux è vuoto, lo ricostruisce dalla copia in Download."""
    if leggi_csv():
        print("ℹ️ Ci sono già vendite nel turno: niente da ripristinare.")
        return
    copie = sorted(glob.glob(os.path.join(CARTELLA_CHIUSURE, "**", "*_dati.csv"), recursive=True),
                   key=os.path.getmtime)
    if not copie:
        print("📭 Nessuna copia trovata in Download/Chiusure_Turno.")
        return
    shutil.copy(copie[-1], PATH_CSV)
    print(f"♻️ Ripristinate {len(leggi_csv())} vendite da {os.path.basename(copie[-1])}")


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
            out.append(f"  • {v['ora']} {q} {v['categoria']} {euro(v['importo'])} ({sigla(v['metodo'])})")
    litri = sum(v["quantita"] for v in ad if v["unita"] == "l")
    euro_sfuso = sum(v["importo"] for v in ad if v["unita"] == "l")
    taniche = sum(v["quantita"] for v in ad if v["unita"] != "l")
    euro_taniche = sum(v["importo"] for v in ad if v["unita"] != "l")
    out.append(f"  Sfuso: {litri:.2f} litri erogati ({euro(euro_sfuso)})")
    out.append(f"  Taniche: {numero(taniche)} ({euro(euro_taniche)})")
    return out


def prospetto_cassa(vv, t):
    """Quadratura: avanzo + vendite in contanti = contanti attesi, confrontati con quelli contati."""
    if not t or all(t.get(k) is None for k in ("avanzo", "contati", "versamento")):
        return []
    contanti = sum(v["importo"] for v in vv if v["metodo"] == "Contanti")
    avanzo = t.get("avanzo") or 0.0

    def differenza(atteso, contato):
        d = round(contato - atteso, 2)
        if abs(d) < 0.005:
            return "✅ quadra"
        return f"⚠️ {'in più' if d > 0 else 'mancano'} {euro(abs(d))}"

    versamento = t.get("versamento") or 0.0
    attesi = avanzo + contanti - versamento
    out = ["", "💶 QUADRATURA CASSA",
           f"  {'Avanzo turno prec.':<20} {euro(avanzo) if t.get('avanzo') is not None else '(non inserito)':>12}",
           f"  {'+ Vendite contanti':<20} {euro(contanti):>12}"]
    if versamento:
        out.append(f"  {'- Versamenti':<20} {euro(versamento):>12}")
    out.append(f"  {'= Contanti attesi':<20} {euro(attesi):>12}")
    if t.get("cassaforte"):
        out.append(f"  {'di cui in cassaforte':<20} {euro(t['cassaforte']):>12}")
        attesi -= t["cassaforte"]
        out.append(f"  {'= Attesi nel cassetto':<20} {euro(attesi):>12}")
    if t.get("contati") is not None:
        out.append(f"  {'Contanti contati':<20} {euro(t['contati']):>12}   {differenza(attesi, t['contati'])}")
    return out


def prospetto_completo(righe, titolo, t=None):
    vv = vendite(righe)
    totale = sum(v["importo"] for v in vv)
    per_metodo = totali_per(vv, "metodo")
    contanti = per_metodo.get("Contanti", 0.0)
    out = [titolo, "─────────────────────────",
           f"Vendite: {numero_vendite(righe)}    TOTALE: {euro(totale)}", ""]

    out.append("💳 PER PAGAMENTO")
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<16} {euro(val):>10}")
    crediti = per_metodo.get("Credito", 0.0)
    out.append(f"  {'= Contanti':<16} {euro(contanti):>10}")
    out.append(f"  {'= Carte / POS':<16} {euro(totale - contanti - crediti):>10}")
    if crediti:
        out.append(f"  {'= Crediti clienti':<16} {euro(crediti):>10}   (non pagati)")
    out.append("")

    out.append("⛽ CARBURANTI")
    carb = {v["categoria"]: 0.0 for v in vv if v["reparto"] == "Carburante"}
    for v in vv:
        if v["reparto"] == "Carburante":
            carb[v["categoria"]] += v["importo"]
    for nome, val in sorted(carb.items()):
        out.append(f"  {nome:<16} {euro(val):>10}")
    out.append(f"  {'= Carburanti':<16} {euro(sum(carb.values())):>10}")
    out.append("")
    out += prospetto_adblue(vv, dettaglio=False)
    fax = [v for v in vv if v["reparto"] == "Fax"]
    if fax:
        out.append("")
        out.append("📠 FAX / FOTOCOPIE")
        out.append(f"  Fogli: {numero(sum(v['quantita'] for v in fax))}    Totale: {euro(sum(v['importo'] for v in fax))}")
    abbuoni = [v for v in vv if v["reparto"] == "Sconto"]
    resti = [v for v in vv if v["reparto"] == "Resto lasciato"]
    if abbuoni or resti:
        # Centesimi in meno (abbuoni) e in più (resti lasciati): sono già nei contanti
        out.append("")
        out.append("🪙 CENTESIMI (già compresi nei contanti)")
        out.append(f"  {'Abbuoni (' + str(len(abbuoni)) + ')':<20} {sum(v['importo'] for v in abbuoni):>+9.2f} €")
        out.append(f"  {'Resti lasciati (' + str(len(resti)) + ')':<20} {sum(v['importo'] for v in resti):>+9.2f} €")
        out.append(f"  {'= Saldo':<20} {sum(v['importo'] for v in abbuoni + resti):>+9.2f} €")
    out.append("")
    out += prospetto_market(vv)
    out += prospetto_cassa(vv, t)
    return out


def totali_brevi(righe):
    """Poche righe per la finestra di "totali" (il dettaglio è nel widget 04)."""
    vv = vendite(righe)
    t = leggi_turno() or {}
    per_metodo = totali_per(vv, "metodo")
    contanti = per_metodo.get("Contanti", 0.0)
    attesi = (t.get("avanzo") or 0.0) + contanti - (t.get("versamento") or 0.0)
    nomi = (("POS nero", "POS nero"), ("POS bianco", "POS bianco"), ("POS cassa", "POS cassa"),
            ("Petrolifere", "Petrolifere"), ("OPT", "OPT"), ("Credito", "Crediti clienti"))
    out = [f"Vendite: {numero_vendite(righe)}",
           f"💶 Attesi in cassa: {euro(attesi)}",
           f"   (avanzo {euro(t.get('avanzo') or 0.0)} + contanti {euro(contanti)}"
           + (f" - versamenti {euro(t['versamento'])}" if t.get('versamento') else "") + ")"]
    for m, breve in nomi:
        if per_metodo.get(m):
            out.append(f"💳 {breve}: {euro(per_metodo[m])}")
    return "\n".join(out)


def notifica_breve(righe):
    t = leggi_turno()
    intest = f"🕐 {t['tipo']} dalle {t['apertura'][-5:]}" if t else "🕐 Turno non aperto"
    vv = vendite(righe)
    if not vv:
        print(f"📊 Totale: 0.00 € | Vendite: 0  {intest}\n────────────────\nNessuna transazione registrata.")
        return

    totale = sum(v["importo"] for v in vv)
    out = [f"📊 Tot: {euro(totale)} ({numero_vendite(righe)} vendite)  {intest}"]

    # Carburanti tutti insieme (gasolio, benzina e "carburante" detto senza tipo); gli altri come totale
    parti = []
    carburanti = sum(v["importo"] for v in vv if v["reparto"] == "Carburante")
    if carburanti:
        parti.append(f"CARBURANTI: {carburanti:.2f}€")
    for reparto, icona in (("AdBlue", "🧪 ADBLUE"), ("Fax", "📠 FAX"), ("Market", "🛒 MARKET"), ("Sconto", "🏷️ ABBUONI"), ("Resto lasciato", "🪙 RESTI LASCIATI"),
                           ("Credito cliente", "📒 CREDITI"), ("Credito riscosso", "💰 RISCOSSI")):
        val = sum(v["importo"] for v in vv if v["reparto"] == reparto)
        if val:
            parti.append(f"{icona}: {val:.2f}€")
    out.append("⛽ " + " | ".join(parti))
    out.append("💳 " + " | ".join(f"{m}: {val:.2f}€" for m, val in totali_per(vv, "metodo").items()))

    out.append("────────────────")
    out.append("🔍 Ultime transazioni:")
    # Le vendite market non compaiono qui (solo nel totale sopra)
    for v in reversed([v for v in vv if v["reparto"] != "Market"][-5:]):
        out.append(f"• {v['ora']} | {v['importo']:.2f}€ ({sigla(v['metodo'])}) {v['note']}")
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

def transazioni(righe):
    """Righe raggruppate per transazione (una vendita mista ha più righe con lo stesso numero)."""
    gruppi = []
    for r in righe:
        try:
            num = json.loads(r[1]).get("transazione")
        except Exception:
            num = None
        if num and gruppi and gruppi[-1][0] == num:
            gruppi[-1][1].append(r)
        else:
            gruppi.append((num, [r]))
    return [g for _, g in gruppi]


def numero_vendite(righe):
    """Vendite vere: un abbuono o un resto detto da solo non è una vendita."""
    n = 0
    for gruppo in transazioni(righe):
        reparti = {(vendita(r) or {}).get("reparto") for r in gruppo}
        if reparti - {"Sconto", "Resto lasciato"}:
            n += 1
    return n


def descrivi_gruppo(gruppo):
    """"Gasolio 20.10 € + Abbuono -0.10 €": cosa c'era nella vendita cancellata."""
    vv = [v for v in (vendita(r) for r in gruppo) if v]
    return " + ".join(f"{v['categoria']} {v['importo']:.2f} €" for v in vv) + (f" ({vv[0]['metodo']})" if vv else "")


def cancella_ultima():
    gruppi = transazioni(leggi_csv())
    if not gruppi:
        print("Totale: 0.00 € | Vendite: 0\nNessuna transazione da cancellare.")
        return
    righe_aggiornate = [r for g in gruppi[:-1] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print(f"🗑️ Cancellata l'ultima vendita: {descrivi_gruppo(gruppi[-1])}")
    notifica_breve(righe_aggiornate)


def cancella_penultima():
    gruppi = transazioni(leggi_csv())
    if len(gruppi) < 2:
        print("Servono almeno 2 transazioni.")
        return
    righe_aggiornate = [r for g in gruppi[:-2] + gruppi[-1:] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print(f"🗑️ Cancellata la penultima vendita: {descrivi_gruppo(gruppi[-2])}")
    notifica_breve(righe_aggiornate)


def normalizza_orario(grezzo):
    """'14 05 32', '14:05:32', '140532' -> '14:05:32'. Vuoto se non inserito."""
    gruppi = re.findall(r'\d+', grezzo or "")
    if not gruppi:
        return ""
    if len(gruppi) == 1:  # tutto attaccato: 140532 / 60532 / 1405
        cifre = gruppi[0]
        if len(cifre) in (5, 6):
            cifre = cifre.zfill(6)
            gruppi = [cifre[:2], cifre[2:4], cifre[4:]]
        elif len(cifre) in (3, 4):
            cifre = cifre.zfill(4)
            gruppi = [cifre[:2], cifre[2:]]
    try:
        h, m = int(gruppi[0]), int(gruppi[1])
        sec = int(gruppi[2]) if len(gruppi) > 2 else None
    except (ValueError, IndexError):
        return f"(non valido: {grezzo})"
    if h > 23 or m > 59 or (sec is not None and sec > 59):
        return f"(non valido: {grezzo})"
    if sec is None:
        return f"{h:02d}:{m:02d} (secondi non inseriti)"
    return f"{h:02d}:{m:02d}:{sec:02d}"


def chiudi_turno(orario_terminale="", contati_testo="", cassaforte_testo=""):
    orario_terminale = normalizza_orario(orario_terminale)
    righe = leggi_csv()
    if not righe:
        # Niente da archiviare: evita di creare file d'archivio vuoti
        if os.path.exists(PATH_TURNO):
            os.remove(PATH_TURNO)
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna vendita: niente da archiviare.")
        return

    t = turno_attuale(righe)
    t["contati"] = importo_da_testo(contati_testo)
    t["cassaforte"] = importo_da_testo(cassaforte_testo)
    if t["contati"] is not None and not t.get("prova"):
        with open(PATH_ULTIMO_CONTEGGIO, 'w') as f:  # suggerimento per l'avanzo del turno dopo
            f.write(f"{t['contati']:.2f}")
    adesso = datetime.now()
    testo = testo_documento(righe, t, finale=True, orario_terminale=orario_terminale)
    salvato = salva_documento(righe, t, finale=True, orario_terminale=orario_terminale)

    try:
        import excel_turno
        messaggi_excel, stato = excel_turno.crea_excel(righe, t, orario_terminale,
                                                         os.path.join(cartella_turno(t), "Excel"))
        if t["contati"] is None and stato.get("avanzo") is not None and not t.get("prova"):
            with open(PATH_ULTIMO_CONTEGGIO, 'w') as f:  # avanzo calcolato, proposto all'apertura dopo
                f.write(f"{stato['avanzo']:.2f}")
    except ImportError:
        messaggi_excel = ["⚠️ Excel non creato: manca openpyxl (riesegui l'installazione con internet)"]
    except Exception as e:
        messaggi_excel = [f"⚠️ Excel non creato ({e})"]

    # Mail con Excel e riepilogo, in sottofondo (se configurata; senza internet resta in coda)
    # Mail con Excel e riepilogo, subito (qualche secondo); senza internet resta in coda
    if os.path.exists(os.path.expanduser("~/.cassa_email.json")):
        try:
            import invia_mail
            invia_mail.svuota_coda()
            esito = invia_mail.invia_turno(cartella_turno(t), prova=bool(t.get("prova")))
        except Exception as e:
            esito = f"📧 Mail non inviata ({e})"
        if esito:
            messaggi_excel.append(esito)

    timestamp_backup = adesso.strftime("%Y-%m-%d_%H-%M-%S")
    shutil.copy(PATH_CSV, os.path.expanduser(f"~/turno_archivio_{timestamp_backup}.csv"))
    scrivi_csv([])
    if os.path.exists(PATH_TURNO):
        os.remove(PATH_TURNO)

    print(testo.split("\n📋")[0])
    print(salvato)
    print("\n".join(messaggi_excel))


def main():
    comando = " ".join(sys.argv[1:]).lower() if len(sys.argv) > 1 else "notifica"

    if "cancella ultima" in comando or "elimina ultima" in comando:
        cancella_ultima()
    elif "penultima" in comando:
        cancella_penultima()
    elif comando.startswith("apri turno"):
        argomenti = sys.argv[3:] + ["", "", "", "", "", ""]
        apri_turno(*argomenti[:6])
    elif comando.startswith("nomi test"):
        if comando.endswith(("si", "sì", "on")):
            open(PATH_NOMI_TEST, 'w').close()
            print("📛 Da ora i turni veri hanno TEST nel nome dei file (la mail va comunque al lavoro).")
        elif comando.endswith(("no", "off")):
            if os.path.exists(PATH_NOMI_TEST):
                os.remove(PATH_NOMI_TEST)
            print("✅ Da ora i turni veri hanno il nome normale dei file.")
        else:
            print("📛 TEST nei nomi dei turni veri: " + ("SÌ" if os.path.exists(PATH_NOMI_TEST) else "no"))
    elif comando.startswith("stato "):
        print(valore_stato(sys.argv[2] if len(sys.argv) > 2 else ""))
    elif comando == "aperto":
        sys.exit(0 if turno_aperto() else 1)
    elif comando == "ultimo conteggio":
        try:
            print(open(PATH_ULTIMO_CONTEGGIO).read().strip().replace(".", ","))
        except Exception:
            pass
    elif comando.startswith("contatore"):
        imposta_contatore(" ".join(sys.argv[2:]) or comando)
    elif comando == "cancella versamento":
        cancella_versamento()
    elif comando.startswith("versamento"):
        aggiungi_versamento(sys.argv[2] if len(sys.argv) > 2 else "", sys.argv[3] if len(sys.argv) > 3 else "")
    elif comando.startswith("importo"):
        valore = importo_da_testo(re.sub(r'\s+virgola\s+', ',', " ".join(sys.argv[2:])))
        print(f"{valore:g}" if valore is not None else "")
    elif comando.startswith("avanzo"):
        imposta_avanzo(" ".join(sys.argv[2:]))
    elif "chiudi turno" in comando or "fine turno" in comando or "azzera" in comando:
        argomenti = sys.argv[2:] + ["", "", ""]
        chiudi_turno(argomenti[0], argomenti[1], argomenti[2])
    elif comando == "salva":
        salva_copia()
    elif "ripristin" in comando:
        ripristina()
    elif "archivio" in comando or "storico" in comando:
        mostra_archivio()
    else:
        righe = leggi_csv()
        if comando == "totali breve":
            print(totali_brevi(righe))
        elif comando == "totali":
            print("\n".join(prospetto_completo(righe, "🧾 RIEPILOGO TURNO", leggi_turno())))
        elif comando == "market":
            print("\n".join(prospetto_market(vendite(righe))))
        elif comando == "adblue":
            print("\n".join(prospetto_adblue(vendite(righe))))
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
FINE_FILE
# Modello Excel del turno (file binario, codificato in base64)
base64 -d > ~/.termux/tasker/modello_turno.xlsx <<'FINE_FILE'
UEsDBBQABgAIAAAAIQB0NlqmegEAAIQFAAATAAgCW0NvbnRlbnRfVHlwZXNdLnhtbCCiBAIooAAC
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACs
VM1OAjEQvpv4DpteDVvwYIxh4YB6VBLwAWo7sA3dtukMCG/vbEFiDEIIXLbZtvP9TGemP1w3rlhB
Qht8JXplVxTgdTDWzyvxMX3tPIoCSXmjXPBQiQ2gGA5ub/rTTQQsONpjJWqi+CQl6hoahWWI4Plk
FlKjiH/TXEalF2oO8r7bfZA6eAJPHWoxxKD/DDO1dFS8rHl7q+TTelGMtvdaqkqoGJ3VilioXHnz
h6QTZjOrwQS9bBi6xJhAGawBqHFlTJYZ0wSI2BgKeZAzgcPzSHeuSo7MwrC2Ee/Y+j8M7cn/rnZx
7/wcyRooxirRm2rYu1w7+RXS4jOERXkc5NzU5BSVjbL+R/cR/nwZZV56VxbS+svAJ3QQ1xjI/L1c
QoY5QYi0cYDXTnsGPcVcqwRmQly986sL+I19QodWTo9qLpErJ2GPe4yfW3qcQkSeGgnOF/DTom10
JzIQJLKwb9JDxb5n5JFzsWNoZ5oBc4Bb5hk6+AYAAP//AwBQSwMEFAAGAAgAAAAhALVVMCP0AAAA
TAIAAAsACAJfcmVscy8ucmVscyCiBAIooAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACskk1PwzAMhu9I/IfI99XdkBBCS3dBSLshVH6ASdwP
tY2jJBvdvyccEFQagwNHf71+/Mrb3TyN6sgh9uI0rIsSFDsjtnethpf6cXUHKiZylkZxrOHEEXbV
9dX2mUdKeSh2vY8qq7iooUvJ3yNG0/FEsRDPLlcaCROlHIYWPZmBWsZNWd5i+K4B1UJT7a2GsLc3
oOqTz5t/15am6Q0/iDlM7NKZFchzYmfZrnzIbCH1+RpVU2g5abBinnI6InlfZGzA80SbvxP9fC1O
nMhSIjQS+DLPR8cloPV/WrQ08cudecQ3CcOryPDJgosfqN4BAAD//wMAUEsDBBQABgAIAAAAIQAO
roDUaAMAAGAIAAAPAAAAeGwvd29ya2Jvb2sueG1srFVdb6M4FH1faf8D4p1iE0MANR2FANpK7ajq
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
DQANAGQDAAC2QAAAAAA=
FINE_FILE
# Listino Danea: si installa solo se è cambiato (il listino attuale resta in prezzi.json.vecchio)
cat > ~/.termux/tasker/prezzi_danea.json <<'FINE_FILE'
{
 "DEODORANTE LUXURY 150 ML": {
  "prezzo": 7.5,
  "alias": [
   "deodorante luxury"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ALTRO"
 },
 "CACIOTTA DELLA LUNIGIANA": {
  "prezzo": 6.1,
  "alias": [
   "caciotta della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "GILET RIFRANGENTE": {
  "prezzo": 7.0,
  "alias": [
   "gilet rifrangente"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ALTRO"
 },
 "PANNO SONAX PELLE PLASTICA": {
  "prezzo": 4.5,
  "alias": [
   "panno sonax pelle plastica"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ALTRO"
 },
 "SET TAPPI PNEUMATICI": {
  "prezzo": 2.0,
  "alias": [
   "set tappi pneumatici"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADESIVI ITALIA STIKY": {
  "prezzo": 8.0,
  "alias": [
   "adesivi italia stiky"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "NUMERI/PAROLE ADESIVI 80X35": {
  "prezzo": 1.0,
  "alias": [
   "numeri parole adesivi",
   "numeri parole adesivi 80x35"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA CAMION 25 LITRI CON RUBINETTO": {
  "prezzo": 27.0,
  "alias": [
   "tanica camion litri con rubinetto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA ROSSA 5 LITRI": {
  "prezzo": 6.5,
  "alias": [
   "tanica rossa litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PRIMO SOCCORSO": {
  "prezzo": 15.0,
  "alias": [
   "primo soccorso"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "VULCANO ZAMPIRONE": {
  "prezzo": 2.5,
  "alias": [
   "vulcano zampirone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SPONGE 2 IN UNO": {
  "prezzo": 6.5,
  "alias": [
   "sponge in uno"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SPUGNA": {
  "prezzo": 2.5,
  "alias": [
   "spugna"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TUBO 12MT GONFIAGGIO": {
  "prezzo": 48.0,
  "alias": [
   "tubo 12mt gonfiaggio",
   "tubo gonfiaggio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "KIT GONFIAGGIO": {
  "prezzo": 75.0,
  "alias": [
   "kit gonfiaggio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "VENTILATORE 24V": {
  "prezzo": 32.0,
  "alias": [
   "ventilatore",
   "ventilatore 24v"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DISCHI TACHIGRAFO": {
  "prezzo": 12.0,
  "alias": [
   "dischi tachigrafo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ATTACCO GPL": {
  "prezzo": 20.0,
  "alias": [
   "attacco gpl"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADESIVI RIFRANGENTI VELOCITA": {
  "prezzo": 6.5,
  "alias": [
   "adesivi rifrangenti velocita"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADESIVO ANGOLO MORTO": {
  "prezzo": 12.5,
  "alias": [
   "adesivo angolo morto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "POMMELLO VOLANTE": {
  "prezzo": 25.0,
  "alias": [
   "pommello volante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TAPPO SERBATOIO": {
  "prezzo": 18.0,
  "alias": [
   "tappo serbatoio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TAPPO ADBLUE": {
  "prezzo": 12.0,
  "alias": [
   "tappo adblue"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PISTOLE SOFFIAGGIO": {
  "prezzo": 14.0,
  "alias": [
   "pistole soffiaggio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "LAMPADINA H7": {
  "prezzo": 10.0,
  "alias": [
   "lampadina",
   "lampadina h7"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUSIBILI": {
  "prezzo": 2.5,
  "alias": [
   "fusibili"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CAVI BATTERIA 35MM": {
  "prezzo": 59.0,
  "alias": [
   "cavi batteria"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CORDA TIRANTE CAMION": {
  "prezzo": 21.0,
  "alias": [
   "corda tirante camion"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CORDA CRICCHETTO ITIS": {
  "prezzo": 21.0,
  "alias": [
   "corda cricchetto itis"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CORDA CRIK CAMION": {
  "prezzo": 19.0,
  "alias": [
   "corda crik camion"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TAPPETTO AUTO": {
  "prezzo": 12.0,
  "alias": [
   "tappetto auto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PARASOLE": {
  "prezzo": 15.0,
  "alias": [
   "parasole"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA 10 LT": {
  "prezzo": 12.0,
  "alias": [
   "tanica"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA ROSSA 5 LT": {
  "prezzo": 6.5,
  "alias": [
   "tanica rossa"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "VENTILATORE 12 V": {
  "prezzo": 21.0,
  "alias": [
   "ventilatore v"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CARICO SPORGENTE": {
  "prezzo": 9.5,
  "alias": [
   "carico sporgente"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CAVO BATTERIA": {
  "prezzo": 47.0,
  "alias": [
   "cavo batteria"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FRIGGITRICE ARIA": {
  "prezzo": 110.0,
  "alias": [
   "friggitrice aria"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SPAZZOLONE 2,3 METRI": {
  "prezzo": 45.0,
  "alias": [
   "spazzolone metri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CAFFETTIERA CIALDE": {
  "prezzo": 40.0,
  "alias": [
   "caffettiera cialde"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TENDINA CALZA PARASOLE": {
  "prezzo": 18.0,
  "alias": [
   "tendina calza parasole"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SECCHIO TONDO RICHIUDIBILE": {
  "prezzo": 11.0,
  "alias": [
   "secchio tondo richiudibile"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SECCHIO QUADRATO": {
  "prezzo": 11.0,
  "alias": [
   "secchio quadrato"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUSIBILI LAMA": {
  "prezzo": 4.0,
  "alias": [
   "fusibili lama"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PULITORE VALVOLE GPL": {
  "prezzo": 18.0,
  "alias": [
   "pulitore valvole gpl"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "NASTRO ISOLANTE MEDIO": {
  "prezzo": 4.5,
  "alias": [
   "nastro isolante medio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CHIAVE CROCE AUTO": {
  "prezzo": 15.0,
  "alias": [
   "chiave croce auto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FASCETTA PLASTICA NERA": {
  "prezzo": 12.0,
  "alias": [
   "fascetta plastica nera"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SPAZZOLONE FUTURA": {
  "prezzo": 20.0,
  "alias": [
   "spazzolone futura"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ANGLES MORTS": {
  "prezzo": 4.7,
  "alias": [
   "angles morts"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "KIT RIPARA GOMME": {
  "prezzo": 15.5,
  "alias": [
   "kit ripara gomme"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "GIUBBOTTO DI SICUREZZA": {
  "prezzo": 7.0,
  "alias": [
   "giubbotto di sicurezza"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TENDINE PARASOLE": {
  "prezzo": 5.0,
  "alias": [
   "tendine parasole"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "COPRIVOLANTE CAMION": {
  "prezzo": 20.0,
  "alias": [
   "coprivolante camion"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "COPRIVOLANTE": {
  "prezzo": 11.0,
  "alias": [
   "coprivolante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CHAMOIS SPONGE": {
  "prezzo": 8.0,
  "alias": [
   "chamois sponge"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PRO CLEAN ALVEOLAR": {
  "prezzo": 5.0,
  "alias": [
   "pro clean alveolar"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PANNO FIBRA DOUBLE FACE": {
  "prezzo": 15.0,
  "alias": [
   "panno fibra double face"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PANNO ANTIAPPANNANTE": {
  "prezzo": 3.0,
  "alias": [
   "panno antiappannante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CLEANING CLOTHS": {
  "prezzo": 7.0,
  "alias": [
   "cleaning cloths"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CHAMOIS LEATHER": {
  "prezzo": 15.0,
  "alias": [
   "chamois leather"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DETERGI VETRI": {
  "prezzo": 5.0,
  "alias": [
   "detergi vetri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PLUG IN EVO": {
  "prezzo": 18.0,
  "alias": [
   "plug in evo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SPINOTTO": {
  "prezzo": 9.0,
  "alias": [
   "spinotto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "MULTI SOCKET": {
  "prezzo": 19.0,
  "alias": [
   "multi socket"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DUO 4": {
  "prezzo": 18.0,
  "alias": [
   "duo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SWIVEL ADAPTER": {
  "prezzo": 12.0,
  "alias": [
   "swivel adapter"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TWIN SCKET": {
  "prezzo": 12.0,
  "alias": [
   "twin scket"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DUAL MUFFLER": {
  "prezzo": 13.0,
  "alias": [
   "dual muffler"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CUSCINO DA VIAGGIO MEMORI WAP": {
  "prezzo": 19.0,
  "alias": [
   "cuscino da viaggio memori wap"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TTIE DOWMN 2X250CM": {
  "prezzo": 12.0,
  "alias": [
   "ttie dowmn",
   "ttie dowmn 2x250cm"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TIOE DOWN 500": {
  "prezzo": 15.0,
  "alias": [
   "tioe down"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "NASTRO TENSORE": {
  "prezzo": 8.5,
  "alias": [
   "nastro tensore"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TIE DOWN 500 CM": {
  "prezzo": 15.0,
  "alias": [
   "tie down"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CORDE ELASTICHE 200M": {
  "prezzo": 11.0,
  "alias": [
   "corde elastiche"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DISCO ORARIO": {
  "prezzo": 1.5,
  "alias": [
   "disco orario"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TAPPETO ANTISCIVOLO": {
  "prezzo": 2.0,
  "alias": [
   "tappeto antiscivolo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ASHTRAY": {
  "prezzo": 13.0,
  "alias": [
   "ashtray"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PARASOLE XXL": {
  "prezzo": 15.0,
  "alias": [
   "parasole xxl"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "MOLLY FACE TENDINA": {
  "prezzo": 6.0,
  "alias": [
   "molly face tendina"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA RUBINETTO 25 LITRI": {
  "prezzo": 27.0,
  "alias": [
   "tanica rubinetto litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA PER ALIMENTI 5 LITRI": {
  "prezzo": 7.0,
  "alias": [
   "tanica per alimenti litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA PER ALIMENTI LITRI 10": {
  "prezzo": 11.0,
  "alias": [
   "tanica per alimenti litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA PER ALIMENTI 15 LITRI": {
  "prezzo": 18.0,
  "alias": [
   "tanica per alimenti litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TAN ICA PER ALIMENTI LITRI 20": {
  "prezzo": 20.0,
  "alias": [
   "tan ica per alimenti litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA CON RUBINETTO LT 15": {
  "prezzo": 20.0,
  "alias": [
   "tanica con rubinetto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA CON RUBINETTO 10 LITRI": {
  "prezzo": 20.0,
  "alias": [
   "tanica con rubinetto litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA CO RUBINETTO 20 LITRI": {
  "prezzo": 24.0,
  "alias": [
   "tanica co rubinetto litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "EASY CAP": {
  "prezzo": 9.0,
  "alias": [
   "easy cap"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CLIP ADESIVA PER TELEPASS": {
  "prezzo": 7.0,
  "alias": [
   "clip adesiva per telepass"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CLIPS": {
  "prezzo": 7.0,
  "alias": [
   "clips"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADESIVO TELEPSASS": {
  "prezzo": 5.0,
  "alias": [
   "adesivo telepsass"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "BELT STOPPER": {
  "prezzo": 7.0,
  "alias": [
   "belt stopper"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ZITTO 2": {
  "prezzo": 12.0,
  "alias": [
   "zitto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ZITTO": {
  "prezzo": 8.0,
  "alias": [
   "zitto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TRAVEL KIT 3PZ": {
  "prezzo": 9.0,
  "alias": [
   "travel kit",
   "travel kit 3pz"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "NEK SUPPORT": {
  "prezzo": 6.0,
  "alias": [
   "nek support"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FRIGGITRICE ARIA 24 VOLT": {
  "prezzo": 110.0,
  "alias": [
   "friggitrice aria volt"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "GANCI PER TENDE": {
  "prezzo": 3.5,
  "alias": [
   "ganci per tende"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SCALDAVIVANDE": {
  "prezzo": 26.0,
  "alias": [
   "scaldavivande"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADAPTOR D3": {
  "prezzo": 4.5,
  "alias": [
   "adaptor",
   "adaptor d3"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO D1": {
  "prezzo": 9.0,
  "alias": [
   "raccordo rapido",
   "raccordo rapido d1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO D2": {
  "prezzo": 5.0,
  "alias": [
   "raccordo rapido",
   "raccordo rapido d2"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO L1": {
  "prezzo": 8.5,
  "alias": [
   "raccordo rapido",
   "raccordo rapido l1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO": {
  "prezzo": 8.0,
  "alias": [
   "raccordo rapido"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D-6": {
  "prezzo": 14.0,
  "alias": [
   "fuel cap",
   "fuel cap d-6"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D 1": {
  "prezzo": 14.0,
  "alias": [
   "fuel cap d"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D-2": {
  "prezzo": 8.0,
  "alias": [
   "fuel cap",
   "fuel cap d-2"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D 3": {
  "prezzo": 15.0,
  "alias": [
   "fuel cap d"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D-4": {
  "prezzo": 12.0,
  "alias": [
   "fuel cap",
   "fuel cap d-4"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "FUEL CAP D-5": {
  "prezzo": 12.0,
  "alias": [
   "fuel cap",
   "fuel cap d-5"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "UREA CAP U1": {
  "prezzo": 7.0,
  "alias": [
   "urea cap",
   "urea cap u1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "UREA CAP U3": {
  "prezzo": 8.5,
  "alias": [
   "urea cap",
   "urea cap u3"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "UREA CAP U4": {
  "prezzo": 9.0,
  "alias": [
   "urea cap",
   "urea cap u4"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "UREA CAP U-5": {
  "prezzo": 19.0,
  "alias": [
   "urea cap",
   "urea cap u-5"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TANICA CON RUBINETTO E PORTASAPONE LT 25": {
  "prezzo": 25.0,
  "alias": [
   "tanica con rubinetto e portasapone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SKIN COVER": {
  "prezzo": 15.0,
  "alias": [
   "skin cover"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR C4": {
  "prezzo": 10.0,
  "alias": [
   "connector",
   "connector c4"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR C 5": {
  "prezzo": 15.0,
  "alias": [
   "connector c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO T 4": {
  "prezzo": 5.0,
  "alias": [
   "raccordo rapido t"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNETTORE ARIA T5": {
  "prezzo": 6.2,
  "alias": [
   "connettore aria",
   "connettore aria t5"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "MOLTIPLICATORE DI FORZA PER DADI": {
  "prezzo": 70.0,
  "alias": [
   "moltiplicatore di forza per dadi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ROTOLINI TACHIGRAFO": {
  "prezzo": 10.0,
  "alias": [
   "rotolini tachigrafo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PORTA TARGA RIPETITRICE": {
  "prezzo": 14.0,
  "alias": [
   "porta targa ripetitrice"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR T1": {
  "prezzo": 8.5,
  "alias": [
   "connector",
   "connector t1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR C1": {
  "prezzo": 12.5,
  "alias": [
   "connector",
   "connector c1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR C 2": {
  "prezzo": 14.0,
  "alias": [
   "connector c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SET PISTOLA GONFIAGGIO": {
  "prezzo": 29.0,
  "alias": [
   "set pistola gonfiaggio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNETTORE C 3": {
  "prezzo": 12.0,
  "alias": [
   "connettore c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CONNECTOR T2": {
  "prezzo": 18.0,
  "alias": [
   "connector",
   "connector t2"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "TUBO ARIA": {
  "prezzo": 14.0,
  "alias": [
   "tubo aria"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "CIGARETTE LIGHTER": {
  "prezzo": 13.0,
  "alias": [
   "cigarette lighter"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "PISTOLA SOFFIAGGIO ARIA": {
  "prezzo": 16.0,
  "alias": [
   "pistola soffiaggio aria"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "DC/CD ADAPTER": {
  "prezzo": 24.0,
  "alias": [
   "dc cd adapter"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "ADATTATORE X2 USCITE": {
  "prezzo": 11.0,
  "alias": [
   "adattatore uscite",
   "adattatore x2 uscite"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "LAMPADA P21W": {
  "prezzo": 5.0,
  "alias": [
   "lampada",
   "lampada p21w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "COPRIVOLANTE 46-48": {
  "prezzo": 20.0,
  "alias": [
   "coprivolante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "BENDA RIPARA MMARMITTE": {
  "prezzo": 5.0,
  "alias": [
   "benda ripara mmarmitte"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "KAMPADSA H7 OSRAM": {
  "prezzo": 7.0,
  "alias": [
   "kampadsa h7 osram",
   "kampadsa osram"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "RACCORDO RAPIDO T4": {
  "prezzo": 8.0,
  "alias": [
   "raccordo rapido",
   "raccordo rapido t4"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI AUTO/CAMION"
 },
 "SUPER ATTAK": {
  "prezzo": 7.0,
  "alias": [
   "super attak"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "SILICONE NERO/TRASPARENTE": {
  "prezzo": 8.0,
  "alias": [
   "silicone nero trasparente"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LUCCHETTO 40MM": {
  "prezzo": 4.0,
  "alias": [
   "lucchetto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LUCCHETTO 50MM": {
  "prezzo": 5.5,
  "alias": [
   "lucchetto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LUCCHETTO 30 MM": {
  "prezzo": 3.5,
  "alias": [
   "lucchetto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LUCCHETTO BLACK+DEKER 70MM": {
  "prezzo": 25.0,
  "alias": [
   "lucchetto black+deker"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LUCCHETTO BLACK DEKER 40MM": {
  "prezzo": 14.0,
  "alias": [
   "lucchetto black deker"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "MULTI TOOLS": {
  "prezzo": 8.0,
  "alias": [
   "multi tools"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "MULTI PLIER": {
  "prezzo": 12.0,
  "alias": [
   "multi plier"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "ACCENDIGAS": {
  "prezzo": 4.0,
  "alias": [
   "accendigas"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "PLUVIO MANTELLO": {
  "prezzo": 25.0,
  "alias": [
   "pluvio mantello"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "FORNELLO KOK": {
  "prezzo": 21.0,
  "alias": [
   "fornello kok"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "FOTNELLO KOK 150": {
  "prezzo": 37.0,
  "alias": [
   "fotnello kok"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "PONCHO PER ADULTI": {
  "prezzo": 7.5,
  "alias": [
   "poncho per adulti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "ATOMIC GAS 60ML": {
  "prezzo": 4.5,
  "alias": [
   "atomic gas"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LETTERE ADESIVE": {
  "prezzo": 1.0,
  "alias": [
   "lettere adesive"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "NASTRO TRASPARENTE": {
  "prezzo": 4.5,
  "alias": [
   "nastro trasparente"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "NASTRO TELATO": {
  "prezzo": 15.0,
  "alias": [
   "nastro telato"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "CARTA ASSORBENTE": {
  "prezzo": 12.0,
  "alias": [
   "carta assorbente"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "5 PANNI FIBRE": {
  "prezzo": 5.0,
  "alias": [
   "panni fibre"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "LAMPADINA P21W": {
  "prezzo": 9.5,
  "alias": [
   "lampadina",
   "lampadina p21w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "CACCIAVITE TAGLIO": {
  "prezzo": 3.0,
  "alias": [
   "cacciavite taglio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CACCIAVITE": {
  "prezzo": 3.0,
  "alias": [
   "cacciavite"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "CACCIAVITE CROCE": {
  "prezzo": 3.0,
  "alias": [
   "cacciavite croce"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "FORBICI 140MM": {
  "prezzo": 7.0,
  "alias": [
   "forbici"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "ACCENDINI PICCOLI BIC": {
  "prezzo": 1.5,
  "alias": [
   "accendini piccoli bic"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "ACCENDINO GRANDE BIC": {
  "prezzo": 2.0,
  "alias": [
   "accendino grande bic"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "ACCESSORI FAI DA TE"
 },
 "AdBlue sfuso": {
  "prezzo": 1.3,
  "alias": [
   "adblue",
   "ad blue",
   "adblue sfuso",
   "sfuso"
  ],
  "reparto": "AdBlue",
  "unita": "l",
  "danea": "ADBLUE SFUSO"
 },
 "AdBlue tanica": {
  "prezzo": 26.0,
  "alias": [
   "tanica adblue",
   "taniche adblue",
   "adblue tanica",
   "adblue taniche",
   "tanica di adblue",
   "taniche di adblue"
  ],
  "reparto": "AdBlue",
  "unita": "pz",
  "danea": "TANICA ADBLUE"
 },
 "BIRRA HEINEKEN 33 CL": {
  "prezzo": 3.5,
  "alias": [
   "birra heineken"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "BIRRA MORETTI 66 CL": {
  "prezzo": 4.0,
  "alias": [
   "birra moretti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "SUCCO DI FRUTTA YOGA": {
  "prezzo": 2.5,
  "alias": [
   "succo di frutta yoga"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "COCA COLA BOTT 400": {
  "prezzo": 3.0,
  "alias": [
   "coca",
   "coca cola",
   "cocacola"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "ESTATHE BRICK": {
  "prezzo": 1.5,
  "alias": [
   "estate",
   "estathe",
   "the brick"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "ESTA THE LIMONE PESCA": {
  "prezzo": 3.0,
  "alias": [
   "esta the limone pesca",
   "estathe bottiglia",
   "the limone",
   "the pesca"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "BOX 6 BOTTIGLIE ACQUA": {
  "prezzo": 5.5,
  "alias": [
   "box acqua",
   "box bottiglie acqua",
   "confezione acqua"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "ICHNUSA METODO LENTO": {
  "prezzo": 3.5,
  "alias": [
   "ichnusa metodo lento"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "RED BULL": {
  "prezzo": 3.0,
  "alias": [
   "red bull",
   "redbull"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "FANTA 0,400 CL": {
  "prezzo": 3.0,
  "alias": [
   "fanta"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "ACQUA CONFEZ.1,5 LITRI": {
  "prezzo": 2.5,
  "alias": [
   "acqua 1 litro e mezzo",
   "acqua big",
   "acqua confez.1,5 litri",
   "acqua grande",
   "acqua litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "ACQUA BOTT 0,500": {
  "prezzo": 1.5,
  "alias": [
   "acqua",
   "acqua naturale",
   "acqua piccola",
   "bottiglietta acqua"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "BEVANDE"
 },
 "RICOLA": {
  "prezzo": 3.0,
  "alias": [
   "ricola"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "FISHERMANS FRIEND": {
  "prezzo": 3.0,
  "alias": [
   "fishermans friend"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "HALLS": {
  "prezzo": 1.0,
  "alias": [
   "halls"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "PECTOL": {
  "prezzo": 1.0,
  "alias": [
   "pectol"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "CARAMELLE MARY GIO": {
  "prezzo": 3.0,
  "alias": [
   "caramelle mary gio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "VIGORSOL": {
  "prezzo": 3.0,
  "alias": [
   "vigorsol"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "DAYGUM": {
  "prezzo": 3.0,
  "alias": [
   "daygum"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "VIVIDENT": {
  "prezzo": 3.0,
  "alias": [
   "vivident"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "GOLIA ACTIVE PASTIGLIE": {
  "prezzo": 3.0,
  "alias": [
   "golia active pastiglie"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "BARATTI": {
  "prezzo": 1.5,
  "alias": [
   "baratti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "VIOLETTE": {
  "prezzo": 3.5,
  "alias": [
   "violette"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "HAPPYDENT": {
  "prezzo": 3.0,
  "alias": [
   "happydent"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "TIC TAC": {
  "prezzo": 2.0,
  "alias": [
   "tic tac"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "TIC TAC TWO": {
  "prezzo": 2.2,
  "alias": [
   "tic tac two"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "KORDOEAN LIQUIRIZIA": {
  "prezzo": 3.0,
  "alias": [
   "kordoean liquirizia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "VICKS RESPIRO VIVO": {
  "prezzo": 2.5,
  "alias": [
   "vicks respiro vivo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "LEONE PASTIGLIE VESPA": {
  "prezzo": 3.5,
  "alias": [
   "leone pastiglie vespa"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "LEONE PASTIGLIE C'ERA UNA VOLTA": {
  "prezzo": 3.5,
  "alias": [
   "leone pastiglie c'era una volta"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "PASTIGLIE LEONE": {
  "prezzo": 3.5,
  "alias": [
   "pastiglie leone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CARAMELLE"
 },
 "AREXONS ADDITTIVO/ INIETTORI/COMMON RAIL": {
  "prezzo": 12.0,
  "alias": [
   "arexons addittivo iniettori common rail"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "AREXONS ADDITTIVO ANTIGELO -20": {
  "prezzo": 11.0,
  "alias": [
   "arexons addittivo antigelo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "AREXONS TRATTAMENTO FAP/DPF": {
  "prezzo": 14.0,
  "alias": [
   "arexons trattamento fap dpf"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN PULITORE INIETTORI": {
  "prezzo": 9.5,
  "alias": [
   "rhutten pulitore iniettori"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "DISISCROSTANTE RADIATORI": {
  "prezzo": 5.5,
  "alias": [
   "disiscrostante radiatori"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "DEGHIACCIANTE SPRAY": {
  "prezzo": 5.0,
  "alias": [
   "deghiacciante spray"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "ADDITIVO D+ MOTORE DIESEL": {
  "prezzo": 11.0,
  "alias": [
   "additivo d+ motore diesel"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "ADDITIVO PER ADBLUE": {
  "prezzo": 9.0,
  "alias": [
   "additivo per adblue"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RAIN OF VISIERA": {
  "prezzo": 5.0,
  "alias": [
   "rain of visiera"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "GONFIA E RIPARA": {
  "prezzo": 8.5,
  "alias": [
   "gonfia e ripara"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "GRASSO SPRY": {
  "prezzo": 6.0,
  "alias": [
   "grasso spry"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN PASTA ABRASIVA": {
  "prezzo": 7.0,
  "alias": [
   "rhutten pasta abrasiva"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "AREXONS CERA": {
  "prezzo": 13.0,
  "alias": [
   "arexons cera"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN POLISH V10": {
  "prezzo": 9.5,
  "alias": [
   "rhutten polish",
   "rhutten polish v10"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "AREXONS RIMUOVI GRAFFI": {
  "prezzo": 6.0,
  "alias": [
   "arexons rimuovi graffi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN ACQUA BLU WC": {
  "prezzo": 8.5,
  "alias": [
   "rhutten acqua blu wc"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "VETROX LIQUIDO VETRI": {
  "prezzo": 3.5,
  "alias": [
   "vetrox liquido vetri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN LAVAVETRO 1 LITRO": {
  "prezzo": 3.5,
  "alias": [
   "rhutten lavavetro litro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "LAVAVETRO 5 LITRI": {
  "prezzo": 16.0,
  "alias": [
   "lavavetro litri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RUTTEN NERO GOMME": {
  "prezzo": 8.0,
  "alias": [
   "rutten nero gomme"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "PULITORE CERCHIONI SHELL": {
  "prezzo": 6.5,
  "alias": [
   "pulitore cerchioni shell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN VETRI AUTO": {
  "prezzo": 4.5,
  "alias": [
   "rhutten vetri auto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN SHAMPOO AUTO": {
  "prezzo": 6.0,
  "alias": [
   "rhutten shampoo auto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "AREXONS SHAMPOO CERA": {
  "prezzo": 11.0,
  "alias": [
   "arexons shampoo cera"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "LUCIDACRUSCOTTO IL PIU": {
  "prezzo": 8.0,
  "alias": [
   "lucidacruscotto il piu"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN LUCIDANTE CRUSCOTTO": {
  "prezzo": 8.0,
  "alias": [
   "rhutten lucidante cruscotto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "RHUTTEN RAVVIVANTE CRUSCOTTO": {
  "prezzo": 8.0,
  "alias": [
   "rhutten ravvivante cruscotto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "CLEANING GEL": {
  "prezzo": 4.0,
  "alias": [
   "cleaning gel"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "LAVAVETRO LAMPA": {
  "prezzo": 4.0,
  "alias": [
   "lavavetro lampa"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "POWER ONE SGRASSATORE": {
  "prezzo": 4.5,
  "alias": [
   "power one sgrassatore"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "CHIMICI"
 },
 "ARBRE MAGIQUE": {
  "prezzo": 2.5,
  "alias": [
   "arbre magique"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "DEKODORANTE POWER AIR": {
  "prezzo": 4.0,
  "alias": [
   "dekodorante power air"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "AEBRE MAGIUQUE POP": {
  "prezzo": 4.5,
  "alias": [
   "aebre magiuque pop"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "DEODORANTE DANNY": {
  "prezzo": 4.5,
  "alias": [
   "deodorante danny"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "DEODORANTE KING": {
  "prezzo": 10.0,
  "alias": [
   "deodorante king"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "RICARICHE DEODORANTE KING": {
  "prezzo": 3.5,
  "alias": [
   "ricariche deodorante king"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "DEODORANTE Q8": {
  "prezzo": 4.0,
  "alias": [
   "deodorante",
   "deodorante q8"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "DEODORANTE FRESH CARD": {
  "prezzo": 2.5,
  "alias": [
   "deodorante fresh card"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "DEODORANTI AUTO"
 },
 "NASTRO IMBALLAGGI": {
  "prezzo": 4.5,
  "alias": [
   "nastro imballaggi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "NASTRO TPL BLACK": {
  "prezzo": 15.0,
  "alias": [
   "nastro tpl black"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "NASTRO TPL SILVER": {
  "prezzo": 15.0,
  "alias": [
   "nastro tpl silver"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "T HANDLE SCREW DRIVERSET": {
  "prezzo": 28.0,
  "alias": [
   "t handle screw driverset"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "ACCENDIFUOCO": {
  "prezzo": 4.5,
  "alias": [
   "accendifuoco"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "BOMBOLETTA GAS": {
  "prezzo": 3.5,
  "alias": [
   "bomboletta gas"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "KIT SERRAGGIO": {
  "prezzo": 8.5,
  "alias": [
   "kit serraggio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "KINZO FASCETTE 4,8MM 400 MM": {
  "prezzo": 15.0,
  "alias": [
   "kinzo fascette"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CORDE ELARSTCHE 150 MM": {
  "prezzo": 8.5,
  "alias": [
   "corde elarstche"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CORDE ELASTICHE 100": {
  "prezzo": 7.5,
  "alias": [
   "corde elastiche"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIAVE 21": {
  "prezzo": 8.0,
  "alias": [
   "chiave"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "FASCETTE 6PZ": {
  "prezzo": 6.5,
  "alias": [
   "fascette",
   "fascette 6pz"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "NASTRO ADESIVO": {
  "prezzo": 4.5,
  "alias": [
   "nastro adesivo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "MIDLAND 4190": {
  "prezzo": 36.0,
  "alias": [
   "midland"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "STRISCE RIFRANGENTI": {
  "prezzo": 14.0,
  "alias": [
   "strisce rifrangenti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SCARPE ANTINFORTUNISTICHE OTAVITE": {
  "prezzo": 48.0,
  "alias": [
   "scarpe antinfortunistiche otavite"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SCARPE ANTINFORTUNISTICHE COVERGUARD": {
  "prezzo": 45.0,
  "alias": [
   "scarpe antinfortunistiche coverguard"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "PORTACHIAVI ITALIA": {
  "prezzo": 4.0,
  "alias": [
   "portachiavi italia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "STATUETTE CARICATURE": {
  "prezzo": 12.0,
  "alias": [
   "statuette caricature"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CASCO TESCHIO SALCADANAIO": {
  "prezzo": 21.0,
  "alias": [
   "casco teschio salcadanaio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "TESCHIO": {
  "prezzo": 21.0,
  "alias": [
   "teschio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIAVE 10 11 15 17 13": {
  "prezzo": 5.0,
  "alias": [
   "chiave"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SET CHIAVI": {
  "prezzo": 62.0,
  "alias": [
   "set chiavi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIVE 6": {
  "prezzo": 2.0,
  "alias": [
   "chive"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SET CACCIAVITI": {
  "prezzo": 32.0,
  "alias": [
   "set cacciaviti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "PINZA": {
  "prezzo": 10.0,
  "alias": [
   "pinza"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIAVE PAPPÈAGALLO": {
  "prezzo": 10.0,
  "alias": [
   "chiave pappèagallo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "PINZA CURVA": {
  "prezzo": 10.0,
  "alias": [
   "pinza curva"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIVE INGLESE": {
  "prezzo": 16.0,
  "alias": [
   "chive inglese"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CORDE ELASTICHE 80": {
  "prezzo": 7.5,
  "alias": [
   "corde elastiche"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SET CACCIAVITI MICRO": {
  "prezzo": 6.5,
  "alias": [
   "set cacciaviti micro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CUTTERS": {
  "prezzo": 7.0,
  "alias": [
   "cutters"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "SET CHIAVI ESAGONALI": {
  "prezzo": 9.0,
  "alias": [
   "set chiavi esagonali"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "TORX KEY SET": {
  "prezzo": 9.0,
  "alias": [
   "torx key set"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "CHIAVI BRUGOLA": {
  "prezzo": 9.0,
  "alias": [
   "chiavi brugola"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "DOUBLE SIDED": {
  "prezzo": 9.0,
  "alias": [
   "double sided"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "FASCETTE FERMACAVO": {
  "prezzo": 10.0,
  "alias": [
   "fascette fermacavo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "ADHESIVE TAPES": {
  "prezzo": 15.0,
  "alias": [
   "adhesive tapes"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "FAI DA TE"
 },
 "MR COOKIE": {
  "prezzo": 2.8,
  "alias": [
   "mr cookie"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "GHIACCIOLO": {
  "prezzo": 1.5,
  "alias": [
   "ghiaccioli",
   "ghiacciolo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "YOGHI": {
  "prezzo": 2.8,
  "alias": [
   "yoghi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "FRAGOLOTTO": {
  "prezzo": 2.8,
  "alias": [
   "fragolotto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "CHANTILLY": {
  "prezzo": 2.8,
  "alias": [
   "chantilly"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "CRUNCHY CARAMEL": {
  "prezzo": 2.8,
  "alias": [
   "crunchy caramel"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "TINORETTI": {
  "prezzo": 2.9,
  "alias": [
   "tinoretti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "LINEA VEGAN": {
  "prezzo": 2.8,
  "alias": [
   "linea vegan"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GELATI"
 },
 "GUANTO": {
  "prezzo": 7.0,
  "alias": [
   "guanto"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "GUANTI"
 },
 "H7 12V55W OSRAM": {
  "prezzo": 10.0,
  "alias": [
   "h7 12v55w osram",
   "osram"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO"
 },
 "OSRAM H7 12V 55W": {
  "prezzo": 10.0,
  "alias": [
   "osram",
   "osram h7 12v"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO"
 },
 "LAMPADE H7 BLUE": {
  "prezzo": 13.0,
  "alias": [
   "lampade blue",
   "lampade h7 blue"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO"
 },
 "LAMPADINA H4": {
  "prezzo": 9.0,
  "alias": [
   "lampadina",
   "lampadina h4"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA T10": {
  "prezzo": 13.0,
  "alias": [
   "lampadina",
   "lampadina t10"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA LED T10": {
  "prezzo": 11.0,
  "alias": [
   "lampadina led",
   "lampadina led t10"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA H1": {
  "prezzo": 7.0,
  "alias": [
   "lampadina",
   "lampadina h1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA ALOGENA": {
  "prezzo": 6.0,
  "alias": [
   "lampadina alogena"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA H5": {
  "prezzo": 8.0,
  "alias": [
   "lampadina",
   "lampadina h5"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMOADINA H7": {
  "prezzo": 9.5,
  "alias": [
   "lamoadina",
   "lamoadina h7"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA P21/5W": {
  "prezzo": 6.0,
  "alias": [
   "lampadina",
   "lampadina p21"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA PY21W": {
  "prezzo": 3.5,
  "alias": [
   "lampadina",
   "lampadina py21w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA MICRO": {
  "prezzo": 6.0,
  "alias": [
   "lampadina micro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA W5W": {
  "prezzo": 3.5,
  "alias": [
   "lampadina",
   "lampadina w5w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA T10": {
  "prezzo": 12.0,
  "alias": [
   "lampada",
   "lampada t10"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA H1": {
  "prezzo": 7.0,
  "alias": [
   "lampada",
   "lampada h1"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA R10W": {
  "prezzo": 3.0,
  "alias": [
   "lampadina",
   "lampadina r10w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADE 24 5WR5W": {
  "prezzo": 3.0,
  "alias": [
   "lampade",
   "lampade 5wr5w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINA SV8 5-8": {
  "prezzo": 10.0,
  "alias": [
   "lampadina",
   "lampadina sv8"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "CP LAMPADE   24 21": {
  "prezzo": 4.0,
  "alias": [
   "cp lampade"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA C5W": {
  "prezzo": 4.0,
  "alias": [
   "lampada",
   "lampada c5w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADE 260 LUMEN P21W": {
  "prezzo": 15.0,
  "alias": [
   "lampade lumen",
   "lampade lumen p21w"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA P21W 25 WHITE": {
  "prezzo": 12.5,
  "alias": [
   "lampada p21w white",
   "lampada white"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADINE P21W 100WHITE": {
  "prezzo": 6.0,
  "alias": [
   "lampadine",
   "lampadine p21w 100white"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA NICRO": {
  "prezzo": 3.0,
  "alias": [
   "lampada nicro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPADA T10 WHITE": {
  "prezzo": 10.0,
  "alias": [
   "lampada t10 white",
   "lampada white"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "LAMPSADA 7 LUMEN BLUE": {
  "prezzo": 3.0,
  "alias": [
   "lampsada lumen blue"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LAMPADINE AUTO/CAMION"
 },
 "ACQUA DISTILLATA": {
  "prezzo": 3.6,
  "alias": [
   "acqua distillata"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LIQUIDI X AUTO"
 },
 "TURAFALLE RADIIATORI": {
  "prezzo": 9.5,
  "alias": [
   "turafalle radiiatori"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LIQUIDI X AUTO"
 },
 "LIQUIDO LAVAVETRI Q8 250ML": {
  "prezzo": 4.0,
  "alias": [
   "liquido lavavetri",
   "liquido lavavetri q8"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LIQUIDI X AUTO"
 },
 "LIQUIDO RADIATORE  CORA": {
  "prezzo": 10.0,
  "alias": [
   "liquido radiatore cora"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LIQUIDI X AUTO"
 },
 "LIQUIDO LAVAVETRI PROF 3 LT": {
  "prezzo": 7.5,
  "alias": [
   "liquido lavavetri prof"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LIQUIDI X AUTO"
 },
 "Q8 FORMULA EXCEL PLUS 5W-40": {
  "prezzo": 16.5,
  "alias": [
   "formula excel plus",
   "q8 formula excel plus 5w-40"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA VX LONG LIFE 5W-30": {
  "prezzo": 23.0,
  "alias": [
   "formula vx long life",
   "q8 formula vx long life 5w-30"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA ULTRA 0W-20": {
  "prezzo": 23.0,
  "alias": [
   "formula ultra",
   "q8 formula ultra 0w-20"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA V BLUE 0W-20": {
  "prezzo": 23.0,
  "alias": [
   "formula v blue",
   "q8 formula v blue 0w-20"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 ZC 90  CAMBI MANUALI": {
  "prezzo": 14.0,
  "alias": [
   "q8 zc cambi manuali",
   "zc cambi manuali"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 AUTO 14 AUTOMATIC TRASMISSION FLUID": {
  "prezzo": 14.5,
  "alias": [
   "auto automatic trasmission fluid",
   "q8 auto automatic trasmission fluid"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "LIQUIDO FLUID -38 SHELL": {
  "prezzo": 9.0,
  "alias": [
   "liquido fluid shell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "LIQUIDO RADIATORI RHUTTEN BLU/ROSSO/ROSA": {
  "prezzo": 10.0,
  "alias": [
   "liquido radiatori rhutten blu rosso rosa"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "DOT 4": {
  "prezzo": 6.5,
  "alias": [
   "dot"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "RHUTTEN GARDEN OIL": {
  "prezzo": 28.0,
  "alias": [
   "rhutten garden oil"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "RHUTTEN GARDEN OIL 100 ML": {
  "prezzo": 4.5,
  "alias": [
   "rhutten garden oil"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "SF5288": {
  "prezzo": 20.0,
  "alias": [
   "sf5288"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "ATF 33 SHELL": {
  "prezzo": 8.0,
  "alias": [
   "atf shell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA M LONG LIFE 5W40": {
  "prezzo": 19.5,
  "alias": [
   "formula m long life",
   "q8 formula m long life 5w40"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA PRESTIGE V 5W-30": {
  "prezzo": 20.0,
  "alias": [
   "formula prestige v",
   "q8 formula prestige v 5w-30"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORM R LONGLIFE 5W-30": {
  "prezzo": 22.0,
  "alias": [
   "form r longlife",
   "q8 form r longlife 5w-30"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA ADVANCE PLUS 10W-40": {
  "prezzo": 16.5,
  "alias": [
   "formula advance plus",
   "q8 formula advance plus 10w-40"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA SPECIAL FE 0W-20": {
  "prezzo": 24.5,
  "alias": [
   "formula special fe",
   "q8 formula special fe 0w-20"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "Q8 FORMULA PLUS 15W-40": {
  "prezzo": 15.5,
  "alias": [
   "formula plus",
   "q8 formula plus 15w-40"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "LUBRIFICANTI"
 },
 "OCCHIALI VISTA ZIPPO": {
  "prezzo": 9.9,
  "alias": [
   "occhiali vista zippo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "OCCHIALI"
 },
 "OCCHIALI DA SOLE ZIPPO": {
  "prezzo": 19.9,
  "alias": [
   "occhiali da sole zippo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "OCCHIALI"
 },
 "DURACELL PILA TORCIA": {
  "prezzo": 6.5,
  "alias": [
   "duracell pila torcia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL PILA MEZZATORCIA": {
  "prezzo": 5.7,
  "alias": [
   "duracell pila mezzatorcia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL MIN ISTILO": {
  "prezzo": 6.0,
  "alias": [
   "duracell min istilo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL CR2430": {
  "prezzo": 4.0,
  "alias": [
   "duracell",
   "duracell cr2430"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL 2016": {
  "prezzo": 3.5,
  "alias": [
   "duracell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL 2032": {
  "prezzo": 7.5,
  "alias": [
   "duracell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURTACELL 2025": {
  "prezzo": 7.5,
  "alias": [
   "durtacell"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "TORCIA ENERGIZER": {
  "prezzo": 12.0,
  "alias": [
   "torcia energizer"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "PILE MINISTYLO ENERGIZER": {
  "prezzo": 1.5,
  "alias": [
   "pile ministylo energizer"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "DURACELL  PILE STYLO": {
  "prezzo": 6.0,
  "alias": [
   "duracell pile stylo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PILE E TORCE"
 },
 "SPRAY PEPERONCINO": {
  "prezzo": 15.0,
  "alias": [
   "spray peperoncino"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "CEROTTI SALVELOX": {
  "prezzo": 5.0,
  "alias": [
   "cerotti salvelox"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SPIRA PIASTRINE ANTIZANZARE": {
  "prezzo": 4.5,
  "alias": [
   "spira piastrine antizanzare"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SCHIUMA DA BARBA GILETTE 400": {
  "prezzo": 6.0,
  "alias": [
   "schiuma da barba gilette"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SCHIUMA DA BARBA GILETTE 300": {
  "prezzo": 4.5,
  "alias": [
   "schiuma da barba gilette"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "GILETTE RASOIO B 2": {
  "prezzo": 5.5,
  "alias": [
   "gilette rasoio b"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "\\RASOIO 20 PEZZI": {
  "prezzo": 12.0,
  "alias": [
   "\\rasoio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DENTIFRICIO SPAZZOLINO": {
  "prezzo": 7.5,
  "alias": [
   "dentifricio spazzolino"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DENTIFRICIO ACQUA FRESH": {
  "prezzo": 3.5,
  "alias": [
   "dentifricio acqua fresh"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DOCCIA SHAMPO VIDAL": {
  "prezzo": 4.0,
  "alias": [
   "doccia shampo vidal"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DOCCIASCHIUMA VIDAL": {
  "prezzo": 3.0,
  "alias": [
   "docciaschiuma vidal"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SALVIETTE FRESH CLEAN": {
  "prezzo": 4.5,
  "alias": [
   "salviette fresh clean"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DETERGENTE MANI": {
  "prezzo": 4.0,
  "alias": [
   "detergente mani"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SALVIETTA FRIA MILLEUSI": {
  "prezzo": 3.5,
  "alias": [
   "salvietta fria milleusi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SALVIETTE FRESH CLEAN BABY": {
  "prezzo": 6.0,
  "alias": [
   "salviette fresh clean baby"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "FAZZOLETTINI 6 PEZZI": {
  "prezzo": 3.5,
  "alias": [
   "fazzolettini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "VELINE 2 VELI 150": {
  "prezzo": 4.5,
  "alias": [
   "veline veli"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "OMBRELLO  BLUE DROP": {
  "prezzo": 7.0,
  "alias": [
   "ombrello blue drop"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "PETTINE": {
  "prezzo": 7.0,
  "alias": [
   "pettine"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "SPAZZOLA": {
  "prezzo": 6.0,
  "alias": [
   "spazzola"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "LAMETTE GILETTE": {
  "prezzo": 5.5,
  "alias": [
   "lamette gilette"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "REPELLENTE ZANZARE": {
  "prezzo": 7.5,
  "alias": [
   "repellente zanzare"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "KILLER ZANZARE": {
  "prezzo": 9.0,
  "alias": [
   "killer zanzare"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "DEO SPRAY MANTOVANI": {
  "prezzo": 6.0,
  "alias": [
   "deo spray mantovani"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "ASSORBENTI": {
  "prezzo": 3.0,
  "alias": [
   "assorbenti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "RASOIO BIC LADY": {
  "prezzo": 3.0,
  "alias": [
   "rasoio bic lady"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "FAZZOLETTINI": {
  "prezzo": 2.8,
  "alias": [
   "fazzolettini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI IGIENE"
 },
 "OLIO EVO FERRARI VIVALDI 0,75 LT": {
  "prezzo": 18.0,
  "alias": [
   "olio evo ferrari vivaldi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "OLIO EVO FERRARI VIVALDI 0,500": {
  "prezzo": 13.5,
  "alias": [
   "olio evo ferrari vivaldi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "LIQUORE MIRTILLO-NOCI-FRAGOLA LOMONE": {
  "prezzo": 14.5,
  "alias": [
   "liquore mirtillo-noci-fragola lomone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "PESTO GENOVESE E ROSSO": {
  "prezzo": 6.0,
  "alias": [
   "pesto genovese e rosso"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "CONFETTURA GUSTI VARI": {
  "prezzo": 6.5,
  "alias": [
   "confettura gusti vari"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIELE GUSTI VARI GR.400": {
  "prezzo": 9.0,
  "alias": [
   "miele gusti vari",
   "miele gusti vari gr.400"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIELE DI CASTAGNO PAPPINI KG 1": {
  "prezzo": 18.0,
  "alias": [
   "miele di castagno pappini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIELE DI ACACIA PAPPINI 1 KG": {
  "prezzo": 22.0,
  "alias": [
   "miele di acacia pappini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "NIELE DI MILLEFIORI PAPPINI 1 KG": {
  "prezzo": 18.0,
  "alias": [
   "niele di millefiori pappini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "RAGU DI LEPRE/CINGHIALE": {
  "prezzo": 4.5,
  "alias": [
   "ragu di lepre cinghiale"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "SUGO POMODORO E BASILICO": {
  "prezzo": 3.5,
  "alias": [
   "sugo pomodoro e basilico"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FARINA DI CASTAGNO 500 GR": {
  "prezzo": 10.0,
  "alias": [
   "farina di castagno"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FARINA DI MAIS KG 1": {
  "prezzo": 8.0,
  "alias": [
   "farina di mais"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FUNGHI PORCINI SOTT OLIO": {
  "prezzo": 17.0,
  "alias": [
   "funghi porcini sott olio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FUNGHI PORCINI SOT OLIO": {
  "prezzo": 18.5,
  "alias": [
   "funghi porcini sot olio"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FUNGHI SECCHI MISTI": {
  "prezzo": 7.0,
  "alias": [
   "funghi secchi misti"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FUNGHI SECCHI PORCINI": {
  "prezzo": 9.0,
  "alias": [
   "funghi secchi porcini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "PASTA ARTIGIANALE TOSCANA GUSTI VARI": {
  "prezzo": 6.5,
  "alias": [
   "pasta artigianale toscana gusti vari"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "CONDIMENTO SECCO GUSTI VARI": {
  "prezzo": 4.5,
  "alias": [
   "condimento secco gusti vari"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "VERDURE DEL CONTADINO": {
  "prezzo": 4.5,
  "alias": [
   "verdure del contadino"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "CARCIOFI A SPICCHI": {
  "prezzo": 4.5,
  "alias": [
   "carciofi a spicchi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "PEPERONCINO RIPIENO": {
  "prezzo": 8.0,
  "alias": [
   "peperoncino ripieno"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "TESTAROLO DELLA LUNIGIANA": {
  "prezzo": 4.7,
  "alias": [
   "testarolo della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIRTILLI SCHIACCIATI": {
  "prezzo": 6.0,
  "alias": [
   "mirtilli schiacciati"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "PANIGACCI": {
  "prezzo": 3.5,
  "alias": [
   "panigacci"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "FUNGHI PORCINI 40 GRAMMI": {
  "prezzo": 11.0,
  "alias": [
   "funghi porcini grammi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIELE DI ACACIA 400 GR": {
  "prezzo": 11.0,
  "alias": [
   "miele di acacia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "MIELE DI ACACIA 400": {
  "prezzo": 11.0,
  "alias": [
   "miele di acacia"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "SALSA PICCANTE": {
  "prezzo": 5.0,
  "alias": [
   "salsa piccante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PRODOTTI TIPICI"
 },
 "DEODORANTE LUXURY 300 ML": {
  "prezzo": 14.0,
  "alias": [
   "deodorante luxury"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PROFUMI CASA PERSONA"
 },
 "DEODORANTE LUXURY ML 150": {
  "prezzo": 7.5,
  "alias": [
   "deodorante luxury"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PROFUMI CASA PERSONA"
 },
 "LIQUIDO INSETTICIDA": {
  "prezzo": 3.5,
  "alias": [
   "liquido insetticida"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PROFUMI CASA PERSONA"
 },
 "PROFUMO UOMO": {
  "prezzo": 15.0,
  "alias": [
   "profumo uomo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "PROFUMI CASA PERSONA"
 },
 "COPPA DELLA LUNIGIANA GR 950": {
  "prezzo": 20.5,
  "alias": [
   "coppa della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "PECORINO": {
  "prezzo": 18.0,
  "alias": [
   "pecorino"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "FILETTO DELLA LUNIGIANA GR 900": {
  "prezzo": 30.0,
  "alias": [
   "filetto della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "FILETTO DELLA LLUNIGIANA GR 964": {
  "prezzo": 32.0,
  "alias": [
   "filetto della llunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "MORTADELLA DELLA LUNIGIANA GR 610": {
  "prezzo": 15.0,
  "alias": [
   "mortadella della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "MORTADELLA DELLA LUNIGIANA GR 590": {
  "prezzo": 13.8,
  "alias": [
   "mortadella della lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "SALAME LUNIGIANA GR 450": {
  "prezzo": 11.3,
  "alias": [
   "salame lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "SALAME LUNIGIANA GR": {
  "prezzo": 10.5,
  "alias": [
   "salame lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "SALAME LUNIGIANA GR 460": {
  "prezzo": 11.5,
  "alias": [
   "salame lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "LARDO LUNIGIANA": {
  "prezzo": 6.0,
  "alias": [
   "lardo lunigiana"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "BRESAOLA": {
  "prezzo": 38.5,
  "alias": [
   "bresaola"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SALUMI FORMAGGI"
 },
 "Fax / fotocopie": {
  "prezzo": 0.3,
  "alias": [
   "fax",
   "telefax",
   "fotocopie",
   "fotocopia",
   "copie",
   "fogli",
   "foglio",
   "lettera di vettura",
   "lettere di vettura",
   "cmr",
   "delivery"
  ],
  "reparto": "Fax",
  "unita": "fogli",
  "danea": "TEFAX"
 },
 "TORTINA DI ALICE": {
  "prezzo": 2.5,
  "alias": [
   "tortina di alice"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "SRTUDIDI FICHI": {
  "prezzo": 2.5,
  "alias": [
   "srtudidi fichi",
   "strudel",
   "strudel di fichi"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "KINDER BUENO": {
  "prezzo": 2.0,
  "alias": [
   "kinder bueno"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "BOUNTY": {
  "prezzo": 2.0,
  "alias": [
   "bounty"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "NUTELLA BISCUITS": {
  "prezzo": 2.0,
  "alias": [
   "nutella biscuits"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "CROCCANTE": {
  "prezzo": 1.5,
  "alias": [
   "croccante"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "SNIKERS": {
  "prezzo": 2.0,
  "alias": [
   "snickers",
   "snikers"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "KIT KAT CLASSICO": {
  "prezzo": 2.0,
  "alias": [
   "kit kat classico"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "TWIX": {
  "prezzo": 2.0,
  "alias": [
   "twix"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "MARS": {
  "prezzo": 2.0,
  "alias": [
   "mars"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "LISBONA TOMATIS": {
  "prezzo": 2.0,
  "alias": [
   "lisbona tomatis"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "KINDER CEREALI": {
  "prezzo": 1.5,
  "alias": [
   "kinder cereali"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "KINDERE CIOCCOLATO": {
  "prezzo": 2.0,
  "alias": [
   "kinder cioccolato",
   "kindere cioccolato"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "KINDER CRISPY": {
  "prezzo": 2.2,
  "alias": [
   "kinder crispy"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "NIPPON": {
  "prezzo": 3.2,
  "alias": [
   "nippon"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "NUTELLA BREADY": {
  "prezzo": 2.0,
  "alias": [
   "nutella bready"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "M E MS": {
  "prezzo": 2.0,
  "alias": [
   "emmenems",
   "m and m",
   "m e ms",
   "m&m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "LION": {
  "prezzo": 2.0,
  "alias": [
   "lion"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "BARRETTA FITNESS": {
  "prezzo": 2.0,
  "alias": [
   "barretta fitness"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "FERRERO ROCHER": {
  "prezzo": 2.5,
  "alias": [
   "ferrero rocher"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "MINI OREO": {
  "prezzo": 1.8,
  "alias": [
   "mini oreo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "OREO": {
  "prezzo": 2.4,
  "alias": [
   "oreo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "CANESTRELLI": {
  "prezzo": 3.5,
  "alias": [
   "canestrelli"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "FIOR DI COCCO": {
  "prezzo": 3.5,
  "alias": [
   "fior di cocco"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "CROSTATA FALCONE": {
  "prezzo": 1.5,
  "alias": [
   "crostata falcone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK DOLCI"
 },
 "PAN PIZZA": {
  "prezzo": 3.0,
  "alias": [
   "pan pizza"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "PAN AJO": {
  "prezzo": 3.0,
  "alias": [
   "pan ajo"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "BRUSCHETTA": {
  "prezzo": 2.8,
  "alias": [
   "bruschetta"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "PATATINA AMICA CHIPS": {
  "prezzo": 2.0,
  "alias": [
   "amica chips",
   "patatina amica chips",
   "patatine"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "TUC MINI": {
  "prezzo": 1.5,
  "alias": [
   "tuc mini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "RITZ MINI": {
  "prezzo": 1.5,
  "alias": [
   "ritz mini"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "YONKER": {
  "prezzo": 1.6,
  "alias": [
   "yonker"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "CIPSTER": {
  "prezzo": 1.6,
  "alias": [
   "cipster"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "FONZIES": {
  "prezzo": 1.6,
  "alias": [
   "fonzies"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "STIRACCHIE": {
  "prezzo": 3.0,
  "alias": [
   "stiracchie"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "PRINGLESS MGUSTI VARI": {
  "prezzo": 2.5,
  "alias": [
   "pringles",
   "pringless mgusti vari"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SNACK SALATI"
 },
 "SPAZZOLE Q8": {
  "prezzo": 15.0,
  "alias": [
   "spazzole",
   "spazzole q8"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SPAZZOLE TERGI"
 },
 "TERGI ONE FIT": {
  "prezzo": 13.5,
  "alias": [
   "tergi one fit"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SPAZZOLE TERGI"
 },
 "SPAZZOLA TERGI SKYLON": {
  "prezzo": 13.5,
  "alias": [
   "spazzola tergi skylon"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "SPAZZOLE TERGI"
 },
 "VOLT BLUETOOTH": {
  "prezzo": 28.0,
  "alias": [
   "volt bluetooth"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C CABLE 1 M": {
  "prezzo": 8.9,
  "alias": [
   "type c cable m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "POWER BANK 5000": {
  "prezzo": 16.0,
  "alias": [
   "power bank"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "APPLE 8 PIN 1 M": {
  "prezzo": 8.9,
  "alias": [
   "apple pin m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAVO TYPE C 1 M": {
  "prezzo": 8.9,
  "alias": [
   "cavo type c m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "EARPHONES APPLE 8 PIN": {
  "prezzo": 12.0,
  "alias": [
   "earphones apple pin"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAR CHARGER USB C": {
  "prezzo": 13.0,
  "alias": [
   "car charger usb c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "APPLE 8 PIN": {
  "prezzo": 14.0,
  "alias": [
   "apple pin"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C SPRING 100 CM": {
  "prezzo": 7.5,
  "alias": [
   "type c spring"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "LIGHTNING PRO 100 CM IPHOINE IPAD": {
  "prezzo": 28.0,
  "alias": [
   "lightning pro iphoine ipad"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C PRO 100 CM": {
  "prezzo": 18.0,
  "alias": [
   "type c pro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C KIT PRO 100 CM": {
  "prezzo": 25.0,
  "alias": [
   "type c kit pro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "USB POWER PRO": {
  "prezzo": 21.0,
  "alias": [
   "usb power pro"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SION 5,0": {
  "prezzo": 28.0,
  "alias": [
   "sion"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "EKKO 5,0 BLUETOOTH": {
  "prezzo": 31.0,
  "alias": [
   "ekko bluetooth"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MICRO USB CABLE 1 M": {
  "prezzo": 7.0,
  "alias": [
   "micro usb cable m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CARICATORE DOMESTICO": {
  "prezzo": 10.0,
  "alias": [
   "caricatore domestico"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAVI APPLE 8 PIN 2 METRI": {
  "prezzo": 9.9,
  "alias": [
   "cavi apple pin metri"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAVO TYPE C 2 M": {
  "prezzo": 9.9,
  "alias": [
   "cavo type c m"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "ROCKET DUAL": {
  "prezzo": 15.0,
  "alias": [
   "rocket dual"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "UNIVERSAL CONNECTOR APPLE": {
  "prezzo": 16.0,
  "alias": [
   "universal connector apple"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "UNIVERSAL CONNECTORMICRO USB": {
  "prezzo": 19.0,
  "alias": [
   "universal connectormicro usb"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CERBERO": {
  "prezzo": 29.0,
  "alias": [
   "cerbero"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "APPLE IRON": {
  "prezzo": 19.5,
  "alias": [
   "apple iron"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C IRON 100 CM": {
  "prezzo": 19.0,
  "alias": [
   "type c iron"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SPLITTER APPLE": {
  "prezzo": 25.0,
  "alias": [
   "splitter apple"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "UNIVERSAL 2 USB": {
  "prezzo": 20.0,
  "alias": [
   "universal usb"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C 100 CM": {
  "prezzo": 16.0,
  "alias": [
   "type c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TYPE C 200 CM": {
  "prezzo": 16.0,
  "alias": [
   "type c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CLIP MULTIPOINT BLUETOOTH": {
  "prezzo": 46.0,
  "alias": [
   "clip multipoint bluetooth"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MONO UNIVERSAL": {
  "prezzo": 10.0,
  "alias": [
   "mono universal"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "PÈHIXIA AUX AUX": {
  "prezzo": 9.0,
  "alias": [
   "pèhixia aux aux"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "BLUETOOTH CAR KIT": {
  "prezzo": 35.0,
  "alias": [
   "bluetooth car kit"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "DYNAMIC OUTER EARPHONE": {
  "prezzo": 56.0,
  "alias": [
   "dynamic outer earphone"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "LIGHTNINIG IPHONE IPAD": {
  "prezzo": 28.0,
  "alias": [
   "lightninig iphone ipad"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "LIGHTNING IPHONE IPAD": {
  "prezzo": 27.0,
  "alias": [
   "lightning iphone ipad"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MICRO USB ULTRA SPEED": {
  "prezzo": 13.0,
  "alias": [
   "micro usb ultra speed"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "KIT LIGHTNING 2 IN 1": {
  "prezzo": 31.0,
  "alias": [
   "kit lightning in"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "KIT MICRO USB 2 IN 1": {
  "prezzo": 21.0,
  "alias": [
   "kit micro usb in"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAVO TYPE C": {
  "prezzo": 12.0,
  "alias": [
   "cavo type c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CUFFIE BLUETOOTH": {
  "prezzo": 20.0,
  "alias": [
   "cuffie bluetooth"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "AURICOLARI TYPE C": {
  "prezzo": 14.0,
  "alias": [
   "auricolari type c"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TECNO ARM PORTATELEFONO": {
  "prezzo": 18.0,
  "alias": [
   "tecno arm portatelefono"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MAGNETO BASIC": {
  "prezzo": 13.0,
  "alias": [
   "magneto basic"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MAGNTO PLUS": {
  "prezzo": 18.0,
  "alias": [
   "magnto plus"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SNAP ELEVATOR": {
  "prezzo": 22.0,
  "alias": [
   "snap elevator"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "ATMOS ELEVATOR PORTATELEFONO": {
  "prezzo": 28.0,
  "alias": [
   "atmos elevator portatelefono"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SNAP FIN PORTA TELEFONO": {
  "prezzo": 25.0,
  "alias": [
   "snap fin porta telefono"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "ATMOS FIN PORTATELEFONO": {
  "prezzo": 25.0,
  "alias": [
   "atmos fin portatelefono"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "VISOR SNAP": {
  "prezzo": 20.0,
  "alias": [
   "visor snap"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SUPER GRIP 2,0": {
  "prezzo": 26.0,
  "alias": [
   "super grip"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "STYCKY EXTRA STRONG": {
  "prezzo": 5.0,
  "alias": [
   "stycky extra strong"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "GRAVITON BASIC PORTATELEFONO": {
  "prezzo": 25.0,
  "alias": [
   "graviton basic portatelefono"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "CAR CARGER  A+A": {
  "prezzo": 9.9,
  "alias": [
   "car carger a+a"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "HOMEUSB POWER": {
  "prezzo": 21.0,
  "alias": [
   "homeusb power"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "MAG SURFACE": {
  "prezzo": 20.0,
  "alias": [
   "mag surface"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "SIM ADDATTATORE": {
  "prezzo": 9.0,
  "alias": [
   "sim addattatore"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "TRVEL MATE": {
  "prezzo": 28.0,
  "alias": [
   "trvel mate"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "TELEFONIA"
 },
 "VERMENTINO COLLI DI LUNI": {
  "prezzo": 14.0,
  "alias": [
   "vermentino colli di luni"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "VINI"
 },
 "AUXO COLLI DI LUNI": {
  "prezzo": 14.0,
  "alias": [
   "auxo colli di luni"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "VINI"
 },
 "CASTAGNINI ROSE": {
  "prezzo": 12.5,
  "alias": [
   "castagnini rose"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "VINI"
 },
 "CASTAGNIN IBOLLA": {
  "prezzo": 12.5,
  "alias": [
   "castagnin ibolla"
  ],
  "reparto": "Market",
  "unita": "pz",
  "categoria": "VINI"
 }
}
FINE_FILE
if ! cmp -s ~/.termux/tasker/prezzi_danea.json ~/.termux/tasker/.prezzi_danea_installato; then
  [ -f ~/prezzi.json ] && cp ~/prezzi.json ~/prezzi.json.vecchio
  cp ~/.termux/tasker/prezzi_danea.json ~/prezzi.json
  cp ~/.termux/tasker/prezzi_danea.json ~/.termux/tasker/.prezzi_danea_installato
  echo "🛒 Listino Danea installato: $(grep -c "\"prezzo\"" ~/prezzi.json) prodotti"
fi
python3 ~/.termux/tasker/migra_prezzi.py
# Pulsanti per Termux:Widget (cartella ~/.shortcuts)
mkdir -p ~/.shortcuts && chmod 700 ~/.shortcuts
# Pulsanti con i numeri vecchi (cambiano quando si riordinano): si tolgono e si riscrivono
rm -f ~/.shortcuts/[0-9]\ * ~/.shortcuts/[0-9][0-9]\ * ~/.shortcuts/tasks/[0-9][0-9]\ *
cat > ~/.shortcuts/"01 Vendita carburante" <<'FINE_FILE'
#!/bin/bash
# Pulsante: vendita carburante con i riquadri (importo e pagamento)
. ~/.termux/tasker/widget_comune.sh
IMPORTO=$(numero "⛽ Importo carburante (€)" "es. 45,50"); [ -z "$IMPORTO" ] && annullato
PAGATO=$(pagamento "💳 Pagamento di $IMPORTO €" senza_cassa); [ -z "$PAGATO" ] && annullato
esito "$(bash $CASSA "$IMPORTO euro $PAGATO")"
casa
FINE_FILE
cat > ~/.shortcuts/"02 Vendita Danea" <<'FINE_FILE'
#!/bin/bash
# Pulsante: vendita market scritta (niente errori di AutoVoice)
. ~/.termux/tasker/widget_comune.sh
PRODOTTO=$(testo "🛒 Prodotto Danea" "es. ichnusa · 2 red bull e 1 mars · danea caricabatterie 15")
[ -z "$PRODOTTO" ] && annullato
PAGATO=$(pagamento "💳 Pagamento di: $PRODOTTO"); [ -z "$PAGATO" ] && annullato
esito "$(bash $CASSA "$PRODOTTO $PAGATO")"
casa
FINE_FILE
cat > ~/.shortcuts/"03 AdBlue litri" <<'FINE_FILE'
#!/bin/bash
# Pulsante: AdBlue sfuso a litri (litri e pagamento)
. ~/.termux/tasker/widget_comune.sh
LITRI=$(numero "🧪 AdBlue sfuso: litri" "es. 20"); [ -z "$LITRI" ] && annullato
PAGATO=$(pagamento "💳 Pagamento di $LITRI litri di AdBlue" senza_cassa); [ -z "$PAGATO" ] && annullato
esito "$(bash $CASSA "adblue $LITRI litri $PAGATO")"
casa
FINE_FILE
cat > ~/.shortcuts/"04 Totali" <<'FINE_FILE'
#!/bin/bash
# Pulsante: riepilogo completo del turno in una finestra
. ~/.termux/tasker/widget_comune.sh
finestra "📊 Totali del turno" "$(python3 ~/info_turno.py totali | sed '/📋 TUTTE LE VENDITE/,$d')"
casa
FINE_FILE
cat > ~/.shortcuts/"05 Ultime vendite" <<'FINE_FILE'
#!/bin/bash
# Pulsante: riepilogo veloce e ultime vendite in una finestra
. ~/.termux/tasker/widget_comune.sh
finestra "🔍 Ultime vendite" "$(python3 ~/info_turno.py notifica)"
casa
FINE_FILE
cat > ~/.shortcuts/"06 Cancella ultima" <<'FINE_FILE'
#!/bin/bash
# Pulsante: cancella l'ultima vendita, dopo averla mostrata
. ~/.termux/tasker/widget_comune.sh
ULTIME=$(python3 ~/info_turno.py ultimi | tail -4)
if conferma "🗑️ Cancellare l'ultima vendita?" "$ULTIME"; then
  esito "$(bash $CASSA "cancella ultima")"
else
  messaggio "Niente cancellato"
fi
casa
FINE_FILE
cat > ~/.shortcuts/"07 Abbuono o resto" <<'FINE_FILE'
#!/bin/bash
# Pulsante: centesimi da aggiungere dopo la vendita
#   abbuono = il cliente paga qualche centesimo in meno; resto = lascia qualche centesimo
. ~/.termux/tasker/widget_comune.sh
TIPO=$(scegli "🪙 Cosa aggiungi?" "Abbuono (mancano: ha pagato meno),Resto lasciato (in più: non ha voluto il resto)")
[ -z "$TIPO" ] && annullato
CENT=$(numero "🪙 Quanti centesimi?" "es. 10"); [ -z "$CENT" ] && annullato
case "$TIPO" in
  Abbuono*) esito "$(bash $CASSA "abbuono $CENT centesimi")" ;;
  *)        esito "$(bash $CASSA "lasciato $CENT centesimi")" ;;
esac
casa
FINE_FILE
cat > ~/.shortcuts/"08 Credito cliente" <<'FINE_FILE'
#!/bin/bash
# Pulsante: credito cliente (il cliente prende ora e paga più avanti)
. ~/.termux/tasker/widget_comune.sh
NOME=$(testo "📒 Credito cliente: nome" "es. Rossi"); [ -z "$NOME" ] && annullato
IMPORTO=$(numero "📒 Credito di $NOME (€)" "es. 50,50"); [ -z "$IMPORTO" ] && annullato
esito "$(bash $CASSA "credito cliente $NOME $IMPORTO euro")"
casa
FINE_FILE
cat > ~/.shortcuts/"09 Credito riscosso" <<'FINE_FILE'
#!/bin/bash
# Pulsante: credito riscosso (il cliente paga un vecchio credito)
. ~/.termux/tasker/widget_comune.sh
NOME=$(testo "💰 Credito riscosso: nome" "es. Rossi"); [ -z "$NOME" ] && annullato
IMPORTO=$(numero "💰 Quanto paga $NOME (€)" "es. 50,50"); [ -z "$IMPORTO" ] && annullato
PAGATO=$(pagamento "💳 Come paga $NOME?"); [ -z "$PAGATO" ] && annullato
esito "$(bash $CASSA "credito riscosso $NOME $IMPORTO euro $PAGATO")"
casa
FINE_FILE
cat > ~/.shortcuts/"10 Anticipo Cartissima" <<'FINE_FILE'
#!/bin/bash
# Pulsante: paga con Cartissima (come gasolio, senza rifornimento) e riceve i contanti
. ~/.termux/tasker/widget_comune.sh
IMPORTO=$(numero "💳 Anticipo Cartissima (€)" "pagato con Cartissima e dato in contanti"); [ -z "$IMPORTO" ] && annullato
esito "$(bash $CASSA "anticipo cartissima $IMPORTO euro")"
casa
FINE_FILE
cat > ~/.shortcuts/"11 Prodotti venduti" <<'FINE_FILE'
#!/bin/bash
# Pulsante: elenco dei prodotti market venduti nel turno
. ~/.termux/tasker/widget_comune.sh
finestra "🛒 Prodotti venduti" "$(python3 ~/info_turno.py market)"
casa
FINE_FILE
cat > ~/.shortcuts/"12 Erogazioni AdBlue" <<'FINE_FILE'
#!/bin/bash
# Pulsante: AdBlue erogato nel turno
. ~/.termux/tasker/widget_comune.sh
finestra "🧪 Erogazioni AdBlue" "$(python3 ~/info_turno.py adblue)"
casa
FINE_FILE
cat > ~/.shortcuts/"13 Apertura turno" <<'FINE_FILE'
#!/bin/bash
# Pulsante: apertura turno (vero o di prova); poi i 4 riquadri dei valori del collega
. ~/.termux/tasker/widget_comune.sh
TIPO=$(scegli "🟢 Apertura turno" "Turno vero,Turno di PROVA (file TEST - mail solo a me)")
[ -z "$TIPO" ] && annullato
case "$TIPO" in
  *PROVA*) FRASE="apertura turno prova" ;;
  *)       FRASE="apertura turno" ;;
esac
esito "$(bash $CASSA "$FRASE")"
casa
FINE_FILE
cat > ~/.shortcuts/"14 Chiusura turno" <<'FINE_FILE'
#!/bin/bash
# Pulsante: chiusura turno con conferma; poi i riquadri orario e cassaforte
. ~/.termux/tasker/widget_comune.sh
if ! conferma "🔴 Chiudere il turno?" "Poi chiede l'orario del terminale e la cassaforte"; then
  messaggio "Turno NON chiuso"; casa
fi
RISULTATO=$(bash $CASSA "chiusura turno")
messaggio "$(grep -m3 -E '🔴|📧|⚠️' <<< "$RISULTATO")"
casa
FINE_FILE
cat > ~/.shortcuts/"15 Stato IA" <<'FINE_FILE'
#!/bin/bash
# Pulsante: stato dell'IA, accensione e spegnimento a mano
. ~/.termux/tasker/widget_comune.sh
STATO=$(bash $CASSA "stato ia" | head -1)
case "$(scegli "$STATO" "Lascia così,Accendi IA,Spegni IA")" in
  "Accendi IA") esito "$(bash $CASSA "accendi ia")" ;;
  "Spegni IA")  esito "$(bash $CASSA "spegni ia")" ;;
esac
casa
FINE_FILE
rmdir ~/.shortcuts/tasks 2>/dev/null; chmod +x ~/.shortcuts/*
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
cat > ~/storage/downloads/Cassa_Pulsanti.prj.xml <<'FINE_FILE'
<TaskerData sr="" dvi="1" tv="6.6.20">
	<Project sr="proj0" ve="2">
		<cdate>1791000000000</cdate>
		<name>Cassa Pulsanti</name>
		<pid>31</pid>
		<tids>301,302,303,304,305,306,307,308,309,310,311,312,313,314,315,316</tids>
	</Project>
	<Task sr="task301">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>301</id>
		<nme>Cassa</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"menu"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh menu</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task302">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>302</id>
		<nme>Carburante</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Vendita carburante"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Vendita carburante</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task303">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>303</id>
		<nme>Danea</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Vendita Danea"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Vendita Danea</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task304">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>304</id>
		<nme>AdBlue</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"AdBlue litri"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh AdBlue litri</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task305">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>305</id>
		<nme>Totali</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Totali"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Totali</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task306">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>306</id>
		<nme>Ultime</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Ultime vendite"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Ultime vendite</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task307">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>307</id>
		<nme>Cancella</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Cancella ultima"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Cancella ultima</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task308">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>308</id>
		<nme>Centesimi</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Abbuono o resto"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Abbuono o resto</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task309">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>309</id>
		<nme>Credito</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Credito cliente"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Credito cliente</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task310">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>310</id>
		<nme>Riscosso</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Credito riscosso"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Credito riscosso</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task311">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>311</id>
		<nme>Anticipo</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Anticipo Cartissima"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Anticipo Cartissima</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task312">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>312</id>
		<nme>Venduti</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Prodotti venduti"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Prodotti venduti</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task313">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>313</id>
		<nme>Erogazioni</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Erogazioni AdBlue"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Erogazioni AdBlue</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task314">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>314</id>
		<nme>Apertura</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Apertura turno"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Apertura turno</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task315">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>315</id>
		<nme>Chiusura</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Chiusura turno"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Chiusura turno</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
	<Task sr="task316">
		<cdate>1791000000000</cdate>
		<edate>1791000000000</edate>
		<id>316</id>
		<nme>IA</nme>
		<pri>6</pri>
		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>"Stato IA"</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
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
					<com.twofortyfouram.locale.intent.extra.BLURB>pulsante.sh Stato IA</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="600"/>
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
# Manuale d'uso, sempre aggiornato
cat > ~/storage/downloads/MANUALE_Cassa_Vocale.txt <<'FINE_FILE'
🎙️ CASSA VOCALE Q8 – MANUALE D'USO

Un registratore di cassa a voce: dici la vendita ad alta voce e il telefono la registra.
A fine turno prepara da solo il riepilogo per la chiusura.

━━━━━━━━━━━━━━━━━━━━━━━━
1. COME SI USA
━━━━━━━━━━━━━━━━━━━━━━━━
• Fai un DOPPIO TAP sul retro del telefono.
• Parla subito, con frasi semplici: "20 euro di gasolio sul nero".
• Compaiono due messaggi a schermo:
  🎙️ quello che il telefono ha capito
  ✅ / ❓ / ❌ il risultato

Vibrazioni (non serve guardare il telefono):
• 1 vibrazione corta = tutto ok
• 2 vibrazioni corte = salvato, ma controlla
• 1 vibrazione lunga = errore, NIENTE salvato → ripeti

━━━━━━━━━━━━━━━━━━━━━━━━
2. INIZIO TURNO
━━━━━━━━━━━━━━━━━━━━━━━━
Di': "APERTURA TURNO". Compaiono quattro riquadri:
1) AVANZO CASSA del turno precedente (es. 150,50)
2) ORA CHIUSURA del turno precedente, tutto attaccato (es. 140532)
3) CONTATORE ADBLUE iniziale (numero sulla colonnina, es. 68624,4)
4) TANICHE ADBLUE presenti in magazzino (es. 59)
Sono i valori lasciati dal collega del turno prima: vanno scritti ogni volta.
Se ne lasci uno vuoto, nell'Excel quella casella resta da scrivere a mano.
• Il turno viene riconosciuto in automatico: Mattina 6-14, Pomeriggio 14-22, Notte 22-6.
  Per sceglierlo tu: "apertura turno notte" / "apertura turno mattina" / "apertura turno pomeriggio".
  La notte prende la data del giorno dopo (aperta alle 22 del 4 = notte del 5).
• Nella tendina compare la notifica "Stato Turno".

🧪 TURNO DI PROVA: "apertura turno prova" (o "apertura turno test", anche
"apertura turno notte prova"). Cartella, Excel e mail hanno TEST nel nome
(la mail di prova arriva solo a te, cioè all'indirizzo che invia, non al lavoro)
(es. 05_10_2026_notte_TEST.xlsx) e contatore AdBlue, taniche e orari veri NON
vengono toccati: dopo la prova basta cancellare la cartella …_TEST.

📛 PERIODO DI PROVA (turni veri, ma file con TEST nel nome per non confonderli con
quelli fatti a mano): in Termux
  python3 ~/info_turno.py nomi test si    → da ora i turni veri hanno TEST nel nome
  python3 ~/info_turno.py nomi test no    → si torna ai nomi normali
La mail dei turni veri va comunque al lavoro; contatori, taniche e avanzo si aggiornano.

⚠️ Senza "apertura turno" le vendite NON vengono salvate.
Se hai sbagliato l'avanzo: "avanzo 160".

Contatore e taniche si possono correggere anche dopo, a voce:
• "contatore adblue 68624 virgola 4"  •  "contatore taniche 59"

━━━━━━━━━━━━━━━━━━━━━━━━
3. REGISTRARE LE VENDITE
━━━━━━━━━━━━━━━━━━━━━━━━
CARBURANTE
• "20 euro di gasolio"  •  "trentacinque di verde sul bianco"  •  "50 diesel cartissima"
  (verde / senza piombo = Benzina, diesel = Gasolio)
• Basta anche solo l'importo: "85 euro nero", "77 bianco", "70 07 nero" (= 70,07)
  → registrato come "Carburante" (il tipo non serve per l'Excel).

⚠️ Un rifornimento sopra i 1200 € si salva con 2 vibrazioni e "Importo molto alto":
controlla che non sia un "19 e 90" capito come 1990.

OPT (accettatore esterno, senza metodo di pagamento)
• "50 opt" · "opt 35 e 50" · "ottanta di opt"
  → una casella della sezione OPT dell'Excel (I2:O3) per ogni importo.
  Non tocca i contanti. Anche dal pulsante 01 Vendita carburante: pagamento "OPT".

CENTESIMI
• "20 e 50 di gasolio"  oppure  "20 virgola 50 di gasolio"  = 20,50 €

ADBLUE
• Sfuso, a litri: "adblue 20 litri" (20 × 1,30 €)  oppure  "adblue 13 euro"
• Taniche: "2 taniche di adblue" (dire sempre "adblue": "tanica" da sola è la tanica da 10 litri)

MARKET (tutti i prodotti di Danea, con i prezzi del listino)
• "2 red bull", "una coca cola in cassa", "3 ghiaccioli", "kinder bueno e twix"
• Basta UNA parola del nome: "ichnusa", "heineken", "moretti", "luxury".
• I codici si capiscono comunque li scriva il telefono:
  "h7" = "h 7" = "acca 7" = "acca sette" · "p21w" = "p 21 doppia vu" · "5w40" = "5 w 40"
• Nome sentito un po' storto ("icnusa", "heiniken", "red bul"): il telefono prende
  il prodotto più simile, lo salva con 2 vibrazioni e scrive 🔎 "icnusa" = ichnusa.
  Se è sbagliato: "cancella ultima".
• Si dice il nome del prodotto, senza formati: "acqua grande", "acqua piccola",
  "formula excel plus", "lampadina h7".
• Se il nome vale per più prodotti (es. "birra", "lampadina") compare la lista
  "Quale prodotto?" con i prezzi: tocca quello giusto e premi OK.
  Compare anche per lo stesso prodotto in formati diversi
  ("deodorante luxury" → 150 ml / 300 ml, "miele di acacia" → 400 g / 1 kg).
• OLIO MOTORE: compare sempre la lista di tutti gli oli motore, con quelli detti
  in cima ("olio motore", "olio 5w40", "formula ultra").
• Alimentari simili con lo stesso prezzo si salvano col nome generico, senza lista:
  "nutella" → NUTELLA 2,00 · "leone" → LEONE PASTIGLIE 3,50 · "colli di luni" → 14,00
• Nomi generici: "cingomme" / "chewing gum" / "cicca" → CHEWING GUM 3,00
  (Vigorsol, Vivident, Happydent, Daygum). Il nome della marca va bene lo stesso.
• "birra" da sola → lista di tutte le birre (Heineken, Moretti, Ichnusa);
  "vino" → lista dei vini. Con il nome ("birra moretti", "ichnusa") va diretto.

PREZZO DIVERSO DAL LISTINO
• "2 red bull 7 euro" → 2 red bull, 7 € in tutto (2 vibrazioni: prezzo diverso dal listino)

PRODOTTO CHE NON CONOSCE O PREZZO CAMBIATO: di' "danea" e l'importo
• "danea 15 euro"                    → DANEA (a mano) 15 €
• "danea caricabatterie 15 euro"     → CARICABATTERIE 15 €
• "danea red bull 3 e 50"            → RED BULL a 3,50 (invece del prezzo del listino)
• "danea 2 red bull 7 euro in cassa" → 2 × RED BULL, 7 € in tutto
La parola "danea" da sola mostra invece l'elenco dei prodotti venduti.

FAX / FOTOCOPIE (0,30 € a foglio)
• "5 fax", "10 fotocopie", "2 lettere di vettura"

PAGAMENTI (si dicono in fondo alla frase)
• contanti ............................ se non dici niente, è contanti
• "bianco" / "sul bianco" ............ POS bianco  → TOTALE PAX BANCARIE (somma)
• "nero" / "sul nero" / "pos nero" ... POS nero    → TOTALE POS BANCA (somma)
• "petrolifere" / "cartissima" ....... Petrolifere → CHIUSURA PETROLIFERE PAX (somma)
• "in cassa" / "pos cassa" ........... POS cassa   → SCONTRINI POS REG. CASSA
                                       (una casella per ogni vendita)
Solo prodotti del negozio (market, fax, taniche AdBlue) senza carburante: con "carta"
va da sola IN CASSA; se dici "nero" o "bianco" si salva con 2 vibrazioni e
"⚠️ CONTROLLA: di solito si pagano in cassa".
Se dici solo "carta", "pos" o "bancomat" compare il riquadro
"Pagato con carta: su quale POS?": tocca quello giusto e premi OK.
Se lo annulli la vendita NON viene salvata.

RESTO ARROTONDATO / ABBUONI
• Il cliente fa 20,10 e gli dai il resto di 20:
  "20 e 10 di gasolio, abbuono 10 centesimi"
  (oppure subito dopo la vendita: "abbuono 10 centesimi")
  La vendita resta 20,10 come sulla pompa e i contanti attesi calano di 10 centesimi.
  Nell'Excel l'abbuono NON va negli SCONTI: compare nella differenza (in meno)
  e nelle NOTE viene scritto da dove viene.

RESTO LASCIATO DAL CLIENTE (il contrario: il cliente lascia qualche centesimo)
• Il cliente fa 19,90, ti dà 20 e non vuole il resto:
  "19 e 90 di gasolio, ha lasciato 10 centesimi"
  (oppure subito dopo la vendita: "lasciato 10 centesimi")
  (oppure dopo, anche a vendita già salvata: "resto 10 centesimi", "lasciato 10 centesimi")
  I centesimi si sommano ai contanti attesi (spiccioli cassetto). Nell'Excel
  compaiono come differenza in più, e nelle NOTE viene scritto da dove vengono.

PIÙ COSE NELLA STESSA VENDITA (un solo pagamento)
• "50 di gasolio, 20 litri di adblue e 2 red bull sul nero"

🧾 Se paghi "in cassa" (POS della cassa) compare in mezzo allo schermo la finestra
"STAMPARE RICEVUTA" con l'importo da battere (resta finché non premi OK),
più una notifica. Con gli altri pagamenti no.
❌ Il carburante non si paga "in cassa": una vendita con carburante detta
"in cassa" NON viene salvata → ridilla "sul nero" o "sul bianco".

CREDITI CLIENTI (il cliente prende ora e paga più avanti)
• "credito cliente Rossi 50 euro"
  → casella CREDITI CLIENTI (nome + importo). Non entra nei contanti.

CREDITI RISCOSSI (il cliente paga un vecchio credito)
• "credito riscosso Rossi 50 euro"            (contanti)
• "credito riscosso Rossi 50 euro sul nero"   (o sul bianco, in cassa, petrolifere)
  → casella CREDITI RISCOSSI (nome + importo).
  Se paga "in cassa" arriva anche la notifica STAMPARE RICEVUTA.
Se il nome non viene capito il credito si salva lo stesso, con 2 vibrazioni:
il nome lo scrivi a mano nell'Excel.

ANTICIPO CON CARTISSIMA (paga con Cartissima come gasolio, senza rifornimento,
e gli dai lo stesso importo in contanti)
• "anticipo cartissima 100"
  → +100 nelle PETROLIFERE e -100 dai contanti attesi.

━━━━━━━━━━━━━━━━━━━━━━━━
4. CORREGGERE E CANCELLARE
━━━━━━━━━━━━━━━━━━━━━━━━
• "cancella ultima" (o "cancella ultimo") / "cancella penultima": toglie la vendita intera.
• "correggi ultima sul bianco": cambia il pagamento.
• "correggi ultima 25 euro": cambia l'importo.
• "correggi ultima 3" (senza "euro") dopo "2 red bull": diventano 3 red bull.
• "correggi ultima gasolio": cambia il carburante.
• Al posto di "ultima" puoi dire "penultima".
• Nelle vendite con più cose si può correggere solo il pagamento:
  per il resto cancellala e ridettala.
• Anticipo Cartissima: non si corregge, si cancella e si ridice.

VERSAMENTI
• Se togli contanti dal cassetto per il versamento: "versamento 350"
  Compare il riquadro delle BANCONOTE: scrivi "200 50 50 50" oppure "1x200 3x50".
  Vanno nel riquadro VERSAMENTO dell'Excel (quante da 500, 200, 100, 50, 20, 10, 5).
  Se lo lasci vuoto le calcolo io (le più grandi possibili) e compare ⚠️ da controllare.
  Se le banconote NON fanno la cifra, il riquadro ricompare (fino a 3 volte): se non
  tornano o lo annulli, il versamento NON viene salvato.
  Più versamenti nello stesso turno si sommano.
• Versamento sbagliato: "cancella versamento" (toglie l'ultimo, con le sue banconote).

━━━━━━━━━━━━━━━━━━━━━━━━
5. CONTROLLARE DURANTE IL TURNO
━━━━━━━━━━━━━━━━━━━━━━━━
• "totali": si apre una finestra con i contanti attesi e i totali dei POS
  (resta finché non premi OK). Il riepilogo completo è nel pulsante 04 Totali.
• "ultime vendite": le ultime registrazioni.
• "market": prodotti venduti, raggruppati (es. 3 × Red Bull).
• "erogazioni": AdBlue erogato (litri sfuso e taniche).
• "archivio": i turni passati.
Il riepilogo è sempre visibile anche nella notifica "Stato Turno".

━━━━━━━━━━━━━━━━━━━━━━━━
6. FINE TURNO
━━━━━━━━━━━━━━━━━━━━━━━━
Di': "CHIUSURA TURNO". Compaiono due riquadri:
1) ORARIO DEL TERMINALE POMPE, con i secondi, tutto attaccato:
   140532 = 14:05:32
2) IN CASSAFORTE (vuoto se non c'è niente)
I contanti non si contano: li calcola il telefono dalle vendite
(avanzo + vendite in contanti - versamenti).

Il documento di chiusura viene salvato in:
  Download → Chiusure_Turno → una cartella per ogni turno, es. 2026-10-02_Mattina
    • Documenti → 2026-10-02_Mattina.txt (il riepilogo) e 2026-10-02_Mattina_dati.csv
    • Excel     → i due file Excel (questo turno e il turno dopo)
Contiene: pagamenti, carburanti, AdBlue, fax, market, la QUADRATURA CASSA
(avanzo + contanti - versamenti = contanti attesi) e l'elenco di tutte le vendite.

Nella sottocartella Excel vengono creati i due file del distributore:
  • 04_10_2026_pomeriggio.xlsx = il turno appena chiuso, già compilato con:
    data, turno, ora chiusura, DANEA, TELEFAX, litri AdBlue, contatori,
    taniche, petrolifere PAX, POS banca (nero), PAX bancarie (bianco),
    crediti clienti e crediti riscossi (nome e importo),
    scontrini POS registratore (cassa), avanzo precedente e (negli spiccioli
    cassetto) i contanti che dovrebbero esserci.
  • 05_10_2026_notte.xlsx = il turno dopo, già "imbastito": data, turno, avanzo,
    ORA CHIUSURA (l'orario del terminale appena inserito), contatore AdBlue
    iniziale, taniche precedenti, cassaforte.
  Se le caselle di un riquadro finiscono (es. più di 20 telefax o 24 scontrini),
  si ricomincia dalla prima casella sommando: il totale resta giusto e
  nel messaggio di chiusura compare un avviso.
  Sul computer restano da scrivere: totale carburanti, OPT,
  ricariche, versamento, operatore (e i totali dei POS se vuoi correggerli).

📧 MAIL AUTOMATICA (se configurata): alla chiusura parte da sola una mail con i
due Excel e il riepilogo. Nel messaggio di chiusura compare "📧 Mail inviata a …".
Senza internet resta in coda e riparte da sola al primo comando successivo.
Configurazione (una volta sola, in Termux):
  python3 ~/.termux/tasker/invia_mail.py configura   (Gmail o Libero, password, destinatario)
  python3 ~/.termux/tasker/invia_mail.py prova       (manda una mail di prova)
  python3 ~/.termux/tasker/invia_mail.py coda        (rimanda subito le mail in coda)
La password resta solo sul telefono.

Dopo la chiusura l'IA si spegne e le notifiche spariscono.
I contanti attesi vengono proposti come avanzo all'apertura del turno dopo.

━━━━━━━━━━━━━━━━━━━━━━━━
7. L'IA
━━━━━━━━━━━━━━━━━━━━━━━━
Non serve più per le vendite: tutto si capisce con le regole, in meno di un secondo.
Resta spenta e NON compare nella tendina (lì c'è solo "Stato Turno").
Se mai servisse: "accendi ia" (compare la notifica IA finché è accesa), "spegni ia".
Si spegne comunque con la chiusura del turno.

━━━━━━━━━━━━━━━━━━━━━━━━
8. PULSANTI SULLA SCHERMATA HOME (widget)
━━━━━━━━━━━━━━━━━━━━━━━━
Per quando non si può parlare (in ordine di uso). Tutti funzionano con i riquadri:
si scrive o si sceglie, poi compare l'esito in basso e il telefono torna da solo alla home.
01 Vendita carburante: importo e pagamento
02 Vendita Danea: SCRIVI il prodotto (es. "ichnusa", "2 red bull e 1 mars",
   "danea caricabatterie 15") e scegli il pagamento. Senza errori di AutoVoice.
03 AdBlue litri: litri e pagamento
04 Totali (finestra) · 05 Ultime vendite (finestra)
06 Cancella ultima: mostra le ultime vendite e chiede conferma
07 Abbuono o resto: scegli quale e quanti centesimi
08 Credito cliente · 09 Credito riscosso · 10 Anticipo Cartissima
11 Prodotti venduti (finestra) · 12 Erogazioni AdBlue (finestra)
13 Apertura turno: "Turno vero" oppure "Turno di PROVA" (file TEST, mail solo a te)
14 Chiusura turno: chiede conferma, poi orario e cassaforte
15 Stato IA

SENZA VEDERE TERMUX (con Tasker)
Gli stessi pulsanti si possono lanciare da Tasker: Termux non si apre mai.
• In Tasker importa il progetto Download → Cassa_Pulsanti.prj.xml
  (tieni premuto sulla barra in basso dei progetti → Importa progetto).
• Sulla schermata home: widget di Tasker "Task 1×1" → "Cassa":
  un'icona sola che apre la lista di tutte le funzioni.
  Si possono mettere anche icone singole: Carburante, Danea, AdBlue, Totali, Chiusura…
• Dopo aver modificato o importato qualcosa in Tasker, esci con il tasto indietro
  finché Tasker si chiude, altrimenti compare "dati bloccati".

━━━━━━━━━━━━━━━━━━━━━━━━
9. SICUREZZA DEI DATI
━━━━━━━━━━━━━━━━━━━━━━━━
• Dopo ogni vendita il documento del turno in Download/Chiusure_Turno/<turno>/Documenti
  viene aggiornato.
• Se le vendite in Termux vanno perse, di' "ripristina turno": vengono recuperate da lì.

━━━━━━━━━━━━━━━━━━━━━━━━
10. SE QUALCOSA NON VA
━━━━━━━━━━━━━━━━━━━━━━━━
• "❓ Non ho capito": ripeti più lentamente, con importo e prodotto.
• "⚠️ CONTROLLA" (prima riga del messaggio): la vendita è salvata ma c'è qualcosa
  di strano (2 vibrazioni + notifica "⚠️ Controlla" con suono nella tendina):
  - "solo un importo piccolo, senza prodotto": hai detto "2 mars" ma è arrivato solo "2"?
  - "frase uguale alla vendita di pochi secondi fa": registrata due volte?
  - "prezzo detto … invece di …": prezzo diverso dal listino.
  Se è sbagliata: "cancella ultima".
• Frase non capita (parola sentita male): compare il riquadro
  "✏️ Non capito: scrivi la frase giusta", con la frase sentita scritta in grigio.
  Scrivi la frase corretta (es. "20 pos bianco") e premi OK: viene registrata.
  Annulla = niente salvato. Se la parola non è nel listino usa "danea … euro".
• "❌ Turno non aperto": di' prima "apertura turno".
• "❌ IA spenta, la sto avviando": aspetta 30 secondi e ripeti la frase.
• Il testo capito è tagliato o sbagliato: ripeti, parlando subito dopo il doppio tap.
• Vendita sbagliata: "correggi ultima …" oppure "cancella ultima".
• Prezzi cambiati in Danea: esporta di nuovo i Prodotti in Excel, mettili in Download, poi in Termux:
  python3 ~/.termux/tasker/danea_listino.py ~/storage/downloads/Prodotti.xlsx
• Il manuale aggiornato è in Download → MANUALE_Cassa_Vocale.txt (si rinnova a ogni aggiornamento).
• Per aggiornare il programma, in Termux:
  curl -L -o ~/.termux/tasker/installa.sh https://raw.githubusercontent.com/Nicocico11/Progetto-registratore-di-cassa/claude/cash-register-ai-latency-n0e165/termux/installa.sh && bash ~/.termux/tasker/installa.sh
FINE_FILE
echo "📖 Manuale: Download/MANUALE_Cassa_Vocale.txt"
fi
chmod +x ~/.termux/tasker/*.sh
# Libreria per leggere e scrivere i file Excel (serve internet solo la prima volta)
python3 -c "import openpyxl" 2>/dev/null || pip install -q openpyxl 2>/dev/null || echo "⚠️ openpyxl non installato: riprova con internet"
# Copia del turno in Download e notifiche: solo se il turno è aperto
python3 ~/info_turno.py salva > /dev/null 2>&1
bash ~/.termux/tasker/notifica.sh
bash ~/.termux/tasker/stato_ia.sh aggiorna
if python3 ~/info_turno.py aperto; then echo "📅 Turno aperto: notifiche attive"; else echo "💤 Nessun turno aperto: notifiche tolte e IA spenta"; fi
echo "✅ INSTALLAZIONE COMPLETATA - versione del 06/10 15:13"
