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

case "$FRASE" in
  *turno*)
    # Qualsiasi frase con "turno" è un comando, mai una vendita
    if [[ "$FRASE" =~ ripristin ]]; then
      python3 ~/info_turno.py ripristina
    elif [[ "$FRASE" =~ (apri|apertura|inizio|inizia|avvia|comincia) ]]; then
      AVANZO=""
      if ! python3 ~/info_turno.py aperto; then
        ULTIMO=$(python3 ~/info_turno.py ultimo conteggio)
        AVANZO=$(chiedi "Avanzo cassa turno precedente (€)" "es. 150,50${ULTIMO:+ — ultimo conteggio: $ULTIMO}")
      fi
      echo "🟢 TURNO APERTO"
      python3 ~/info_turno.py apri turno "$AVANZO"
      bash $CARTELLA/avvia_server.sh
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]]; then
      # Orario del terminale pompe con i secondi: detto nella frase
      # ("chiusura turno 14 05 32") oppure scritto nel popup (es. 140532)
      ORARIO=$(grep -oE '[0-9]+' <<< "$FRASE" | tr '\n' ' ')
      if [ -z "$ORARIO" ]; then
        ORARIO=$(chiedi "Orario terminale pompe" "ore minuti secondi, es. 140532" -n)
      fi
      # Quadratura: si possono lasciare vuoti
      CONTATI=$(chiedi "Contanti contati in cassa (€)" "es. 455,50 — vuoto per saltare")
      POS=$(chiedi "Totale POS / carte (€)" "es. 320,00 — vuoto per saltare")
      CASSAFORTE=$(chiedi "In cassaforte (€)" "vuoto se non c'è niente")
      echo "🔴 TURNO CHIUSO - IA spenta"
      python3 ~/info_turno.py "chiudi turno" "$ORARIO" "$CONTATI" "$POS" "$CASSAFORTE"
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
  *"market"*|*"danea"*|*"negozio"*)
    python3 ~/info_turno.py market ;;
  *"erogazion"*|*"quanto adblue"*|*"quante adblue"*)
    python3 ~/info_turno.py adblue ;;
  *"correggi"*|*"correggere"*|*"modifica"*)
    # "correggi ultima carta", "correggi penultima 25 euro", "correggi ultima gasolio"
    if [[ "$FRASE" =~ penultima ]]; then QUALE=penultima; else QUALE=ultima; fi
    python3 $CARTELLA/processa_ia.py --correggi $QUALE "$TESTO"
    ESITO=$?
    python3 ~/info_turno.py salva > /dev/null 2>&1 ;;
  *"contatore"*)
    # "contatore adblue 68624,4" / "contatore taniche 59": valori di partenza
    python3 ~/info_turno.py contatore "$FRASE"
    ESITO=$? ;;
  *"versamento"*|*"versato"*)
    if turno_aperto; then
      python3 ~/info_turno.py versamento "$FRASE"
      ESITO=$?
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
  *"avanzo"*)
    if turno_aperto; then
      python3 ~/info_turno.py avanzo "$FRASE"
      ESITO=$?
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
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
    # Una vendita: solo a turno aperto
    if turno_aperto; then
      python3 $CARTELLA/processa_ia.py "$TESTO"
      ESITO=$?
      # Copia di sicurezza del turno in Download, aggiornata a ogni vendita
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
esac

case $ESITO in
  0) VIBRAZIONE=ok ;;
  2) VIBRAZIONE=attenzione ;;
  *) VIBRAZIONE=errore ;;
esac

# Vibrazione subito (non in sottofondo: in sottofondo Android poteva bloccarla),
# notifiche in sottofondo per non far aspettare Tasker (a turno chiuso si tolgono da sole)
bash $CARTELLA/vibra.sh $VIBRAZIONE > /dev/null 2>&1
nohup bash $CARTELLA/notifica.sh > /dev/null 2>&1 &
nohup bash $CARTELLA/stato_ia.sh aggiorna > /dev/null 2>&1 &

# Sempre 0: l'esito lo comunicano messaggio e vibrazione, così Tasker non interrompe il Task
exit 0
