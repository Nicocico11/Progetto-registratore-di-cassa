#!/bin/bash
# Chiamato da Tasker con la frase dettata come primo argomento.
# Tutto il lavoro (regex veloce, eventuale IA, salvataggio) lo fa processa_ia.py.

# Log di debug per Tasker
echo "$(date) - Ricevuto da Tasker: '$1'" >> ~/debug_tasker.log

TESTO_VOCALE="$1"

if [ -z "$TESTO_VOCALE" ] || [[ "$TESTO_VOCALE" == %* ]]; then
  echo "❌ Errore: Testo vocale non valido o variabile Tasker non espansa ($TESTO_VOCALE)" | tee -a ~/debug_tasker.log
  exit 1
fi

python3 ~/.termux/tasker/processa_ia.py "$TESTO_VOCALE"
ESITO=$?

# Aggiorna la notifica del turno in sottofondo, senza far aspettare Tasker
nohup bash ~/.termux/tasker/notifica.sh > /dev/null 2>&1 &

exit $ESITO
