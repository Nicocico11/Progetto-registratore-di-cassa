#!/bin/bash
# Notifica fissa "Stato Turno" nella tendina: solo con il turno aperto.
if ! python3 ~/info_turno.py aperto; then
  termux-notification-remove distributore_turno 2>/dev/null
  exit 0
fi
TESTO_NOTIFICA=$(python3 ~/info_turno.py notifica)
TITOLO=$(python3 ~/info_turno.py titolo)   # turno e ora di chiusura del collega
termux-notification \
  --id "distributore_turno" \
  --title "$TITOLO" \
  --content "$TESTO_NOTIFICA" \
  --ongoing \
  --alert-once \
  --priority high
