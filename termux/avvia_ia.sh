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
      # Orario del terminale pompe con i secondi: detto nella frase
      # ("chiusura turno 14 05 32") oppure scritto nel popup (es. 140532)
      ORARIO=$(grep -oE '[0-9]+' <<< "$FRASE" | tr '\n' ' ')
      if [ -z "$ORARIO" ]; then
        ORARIO=$(termux-dialog text -n -t "Orario terminale pompe" -i "ore minuti secondi, es. 140532" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("code") == -1:
        print(d.get("text", ""))
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
