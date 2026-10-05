#!/bin/bash
# Pulsanti della cassa SENZA la finestra di Termux: li lancia Tasker (plugin Termux:Tasker).
#   pulsante.sh menu   -> lista di tutte le funzioni, si sceglie e parte
#   pulsante.sh 01     -> direttamente il pulsante 01 (Vendita carburante), ecc.
# Usa gli stessi script dei pulsanti del widget (~/.shortcuts).
export SENZA_TERMINALE=1   # niente ritorno alla home: Termux non si apre proprio
. ~/.termux/tasker/widget_comune.sh
QUALE="${1:-menu}"
if [ "$QUALE" = menu ]; then
  ELENCO=$(cd ~/.shortcuts && ls -1 [0-9][0-9]\ * | paste -sd, -)
  SCELTA=$(scegli "🧾 Cassa" "$ELENCO")
  [ -z "$SCELTA" ] && exit 0
  QUALE="${SCELTA%% *}"
fi
FILE=$(ls ~/.shortcuts/"$QUALE "* 2>/dev/null | head -1)
[ -z "$FILE" ] && { termux-toast "Pulsante $QUALE non trovato: rifai l'installazione"; exit 1; }
exec bash "$FILE"
