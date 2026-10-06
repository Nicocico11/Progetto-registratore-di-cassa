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
OUT=$(bash "$FILE"); CODICE=$?
# Un pulsante che non scrive niente (es. chiusa la finestra dei Totali): niente "%stdout" nel messaggio
# di Tasker, ma un riassunto di quella finestra
if [ -z "$OUT" ]; then
  case "$FILE" in
    *Totali) QUALE=totali ;;
    *"Ultime vendite") QUALE=elenco ;;
    *"Prodotti venduti") QUALE=market ;;
    *"Erogazioni AdBlue") QUALE=adblue ;;
    *) QUALE="" ;;
  esac
  OUT=$(python3 ~/info_turno.py riassunto $QUALE 2>/dev/null)
fi
echo "${OUT:-OK}"
exit $CODICE
