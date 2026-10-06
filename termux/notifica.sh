#!/bin/bash
# Notifica fissa "Stato Turno" nella tendina: solo con il turno aperto.
# Pulsanti: "+ Danea" e "+ Fax" segnano una vendita da registrare dopo (quando c'è tanta gente),
# "Segna" chiede importo e pagamento di quelle rimaste (da_segnare.sh)
if ! python3 ~/info_turno.py aperto; then
  termux-notification-remove distributore_turno 2>/dev/null
  exit 0
fi
TESTO_NOTIFICA=$(python3 ~/info_turno.py notifica)
TITOLO=$(python3 ~/info_turno.py titolo)   # turno e ora di chiusura del collega
SEGNARE=~/.termux/tasker/da_segnare.sh
PULSANTI=(--button1 "🛒 + Danea" --button1-action "bash $SEGNARE danea"
          --button2 "📠 + Fax" --button2-action "bash $SEGNARE fax")
DA_SEGNARE=$(bash $SEGNARE conta 2>/dev/null)
if [ -n "$DA_SEGNARE" ]; then
  TESTO_NOTIFICA="📝 DA SEGNARE: $DA_SEGNARE"$'\n'"$TESTO_NOTIFICA"
  PULSANTI+=(--button3 "📝 Segna ($(grep -c . ~/.cassa_da_segnare))" --button3-action "bash $SEGNARE segna")
fi
termux-notification \
  --id "distributore_turno" \
  --title "$TITOLO" \
  --content "$TESTO_NOTIFICA" \
  --ongoing \
  --alert-once \
  --priority high \
  "${PULSANTI[@]}"
