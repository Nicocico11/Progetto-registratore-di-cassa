#!/bin/bash
# Funzioni comuni ai pulsanti del widget: riquadri (termux-dialog) invece del terminale,
# esito in un messaggio a schermo, poi ritorno alla schermata home.
CASSA=~/.termux/tasker/avvia_ia.sh

_leggi() {  # testo scritto o scelto nel riquadro; niente se annullato
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("code") == -1:
        print(d.get("text", ""))
except Exception:
    pass'
}

testo()    { termux-dialog text -t "$1" -i "$2" 2>/dev/null | _leggi; }         # testo "titolo" "esempio"
numero()   { termux-dialog text -n -t "$1" -i "$2" 2>/dev/null | _leggi; }      # numero "titolo" "esempio"
scegli()   { termux-dialog radio -t "$1" -v "$2" 2>/dev/null | _leggi; }        # scegli "titolo" "a,b,c"
# Sì/No: vale la risposta "yes", qualunque sia il codice restituito dal riquadro
conferma() {
  termux-dialog confirm -t "$1" -i "$2" 2>/dev/null | python3 -c '
import sys, json
try:
    sys.exit(0 if str(json.load(sys.stdin).get("text", "")).strip().lower() in ("yes", "si", "sì") else 1)
except Exception:
    sys.exit(1)'
}

# Finestra con un testo lungo (riepiloghi), da chiudere con OK
finestra() { termux-dialog confirm -t "$1" -i "$2" > /dev/null 2>&1; }

# Esito breve in basso, come i messaggi di Tasker: le righe con ✅ ⚠️ ❌ ❓ 🧾 (o la prima riga)
esito() {
  local corto
  corto=$(grep -m3 -E '✅|⚠️|❌|❓|🧾|🗑️|🏦|💶|📅|🔴|🟢|📧|🧪' <<< "$1")
  termux-toast -g bottom "${corto:-$(head -1 <<< "$1")}" 2>/dev/null
  echo "$1"
}

casa() {    # torna alla schermata home e chiude il pulsante (da Tasker non serve: Termux non si apre)
  if [ -n "$SENZA_TERMINALE" ]; then exit 0; fi
  sleep 1
  am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1
  exit 0
}

annullato() { termux-toast "Niente salvato" 2>/dev/null; casa; }

# Pagamento con i riquadri: stampa la frase da aggiungere ("sul nero", "in cassa"...)
pagamento() {   # pagamento "titolo" [senza_cassa]
  local scelte="Contanti,POS cassa (negozio),POS nero,POS bianco,Petrolifere (Cartissima)"
  [ -n "$2" ] && scelte="Contanti,POS nero,POS bianco,Petrolifere (Cartissima)"
  case "$(scegli "$1" "$scelte")" in
    Contanti) echo "contanti" ;;
    "POS cassa"*) echo "in cassa" ;;
    "POS nero") echo "sul nero" ;;
    "POS bianco") echo "sul bianco" ;;
    Petrolifere*) echo "petrolifere" ;;
  esac
}
