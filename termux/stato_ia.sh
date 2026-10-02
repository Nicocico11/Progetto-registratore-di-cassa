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
