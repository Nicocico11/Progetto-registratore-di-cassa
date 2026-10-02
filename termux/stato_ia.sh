#!/bin/bash
# Notifica fissa "IA" con lo stato del server e i pulsanti Accendi / Spegni / Aggiorna.
# Solo con il turno aperto: a turno chiuso niente notifica e IA sempre spenta.
# Uso: stato_ia.sh [aggiorna | accendi | spegni | attendi]
#   attendi = ricontrolla ogni 3 secondi finché l'IA è pronta (massimo 2 minuti)

CARTELLA=/data/data/com.termux/files/home/.termux/tasker
[ -d "$CARTELLA" ] || CARTELLA=~/.termux/tasker
BASH_BIN=$(command -v bash)
QUESTO="$BASH_BIN $CARTELLA/stato_ia.sh"

# Traccia nel log ogni comando (serve a capire se i pulsanti della notifica arrivano)
[ "${1:-aggiorna}" != "attendi" ] && echo "$(date '+%H:%M:%S') stato_ia ${1:-aggiorna}" >> ~/debug_tasker.log

stato() {
  if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q '"ok"'; then
    echo accesa
  elif pgrep -x llama-server > /dev/null; then
    echo avvio   # il processo c'è ma sta ancora caricando il modello
  else
    echo spenta
  fi
}

spegni_ia() {
  pkill -x llama-server
  termux-wake-unlock
}

mostra() {
  case "$1" in
    accesa) TITOLO="🟢 IA accesa e pronta"; TESTO="Le frasi difficili vengono capite dall'IA" ;;
    avvio)  TITOLO="🟡 IA in avvio…"; TESTO="Pronta tra pochi secondi" ;;
    *)      TITOLO="⚫ IA spenta"; TESTO="Le vendite normali funzionano lo stesso. Tocca Accendi per l'IA" ;;
  esac
  termux-notification --id stato_ia --ongoing --alert-once --priority low \
    --title "$TITOLO" --content "$TESTO" \
    --button1 "Accendi" --button1-action "$QUESTO accendi" \
    --button2 "Spegni"  --button2-action "$QUESTO spegni" \
    --button3 "Aggiorna" --button3-action "$QUESTO aggiorna" > /dev/null 2>&1
}

# Turno chiuso: IA spenta e nessuna notifica
if ! python3 ~/info_turno.py aperto; then
  pgrep -x llama-server > /dev/null && spegni_ia
  termux-notification-remove stato_ia 2>/dev/null
  [ "${1:-}" = "accendi" ] && echo "❌ Turno non aperto: di' \"apertura turno\""
  exit 0
fi

case "${1:-aggiorna}" in
  accendi)
    bash $CARTELLA/avvia_server.sh > /dev/null 2>&1   # avvia_server.sh lancia anche "attendi"
    mostra "$(stato)" ;;
  spegni)
    spegni_ia
    sleep 1
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
