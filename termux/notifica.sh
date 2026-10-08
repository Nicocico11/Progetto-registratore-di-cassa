#!/bin/bash
# Notifica fissa "Stato Turno" nella tendina: solo con il turno aperto.
# Pulsanti: "+ Danea" e "+ Fax" segnano una vendita da registrare dopo (quando c'è tanta gente),
# "Segna" chiede importo e pagamento di quelle rimaste (da_segnare.sh).
# Con prodotti nel carrello dello scanner: "💳 Paga" e "🗑️ Svuota" (carrello.sh).
PID_CARRELLO=~/.cassa_carrello.pid
if ! python3 ~/info_turno.py aperto; then
  termux-notification-remove distributore_turno 2>/dev/null
  # Turno chiuso: si spegne il ricevitore dello scanner
  [ -f $PID_CARRELLO ] && kill "$(cat $PID_CARRELLO)" 2>/dev/null; rm -f $PID_CARRELLO
  exit 0
fi
# Ricevitore dello scanner (Binary Eye): acceso finché il turno è aperto
if ! { [ -f $PID_CARRELLO ] && kill -0 "$(cat $PID_CARRELLO)" 2>/dev/null; }; then
  nohup python3 ~/.termux/tasker/carrello.py server > /dev/null 2>&1 &   # scrive lui il pid, se si accende
fi
TESTO_NOTIFICA=$(python3 ~/info_turno.py notifica)
TITOLO=$(python3 ~/info_turno.py titolo)   # turno e ora di chiusura del collega
SEGNARE=~/.termux/tasker/da_segnare.sh
CARRELLO=$(python3 ~/.termux/tasker/carrello.py riepilogo 2>/dev/null)
DA_SEGNARE=$(bash $SEGNARE conta 2>/dev/null)
if [ -n "$CARRELLO" ]; then
  TESTO_NOTIFICA="🛒 CARRELLO: $CARRELLO"$'\n'"$TESTO_NOTIFICA"
  PULSANTI=(--button1 "💳 Paga carrello" --button1-action "bash ~/.termux/tasker/carrello.sh paga"
            --button2 "🗑️ Svuota" --button2-action "bash ~/.termux/tasker/carrello.sh svuota")
else
  PULSANTI=(--button1 "🛒 + Danea" --button1-action "bash $SEGNARE danea"
            --button2 "📠 + Fax" --button2-action "bash $SEGNARE fax")
fi
if [ -n "$DA_SEGNARE" ]; then
  TESTO_NOTIFICA="📝 DA SEGNARE: $DA_SEGNARE"$'\n'"$TESTO_NOTIFICA"
  PULSANTI+=(--button3 "📝 Segna ($(grep -c . ~/.cassa_da_segnare))" --button3-action "bash $SEGNARE segna")
fi
if [ -z "$CARRELLO" ] && [ -z "$DA_SEGNARE" ]; then
  # Terzo posto libero: si apre un carrello con quello che non si scansiona (carburante, fax, prodotto...)
  PULSANTI+=(--button3 "🧺 Apri carrello" --button3-action "bash ~/.termux/tasker/carrello.sh aggiungi")
fi
if [ -n "$CARRELLO" ]; then
  # Carrello: il terzo pulsante aggiunge quello che non si scansiona (carburante, fax, AdBlue);
  # "Segna" torna appena il carrello è pagato
  PULSANTI=("${PULSANTI[@]:0:8}" --button3 "➕ Aggiungi" --button3-action "bash ~/.termux/tasker/carrello.sh aggiungi")
fi
termux-notification \
  --id "distributore_turno" \
  --title "$TITOLO" \
  --content "$TESTO_NOTIFICA" \
  --ongoing \
  --alert-once \
  --priority high \
  "${PULSANTI[@]}"
