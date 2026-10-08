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

# Messaggio breve: lanciato da Tasker lo scrive e basta (lo mostra Tasker, con il suo stile);
# dal widget di Termux compare in basso
messaggio() {
  if [ -n "$SENZA_TERMINALE" ]; then echo "$1"; else termux-toast -g bottom "$1" 2>/dev/null; fi
}

# Esito di un comando: solo le righe importanti (✅ ⚠️ ❌ ❓ 🧾 ...), o la prima riga
esito() {
  local corto
  corto=$(grep -m3 -E '✅|⚠️|❌|❓|🧾|🗑️|🏦|💶|📅|🔴|🟢|📧|🧪|🎯' <<< "$1")
  messaggio "${corto:-$(head -1 <<< "$1")}"
}

casa() {    # torna alla schermata home e chiude il pulsante (da Tasker non serve: Termux non si apre)
  if [ -n "$SENZA_TERMINALE" ]; then exit 0; fi
  sleep 1
  am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1
  exit 0
}

# Esito dei pulsanti della tendina: messaggio che sparisce da solo; finestra (da chiudere) solo per gli errori
avviso() {
  if grep -qE '❌|❓' <<< "$2"; then finestra "$1" "$2"; else termux-toast -s -g bottom "$2" 2>/dev/null; fi
}

annullato() { messaggio "Niente salvato"; casa; }

# Pagamento con i riquadri: stampa la frase da aggiungere ("sul nero", "in cassa"...)
pagamento() {   # pagamento "titolo" [senza_cassa | carburante]   (OPT solo per il carburante)
  local scelte="Contanti,POS cassa,POS nero,POS bianco,Petrolifere"
  [ -n "$2" ] && scelte="Contanti,POS nero,POS bianco,Petrolifere"
  [ "$2" = carburante ] && scelte="$scelte,OPT"
  case "$(scegli "$1" "$scelte")" in
    Contanti) echo "contanti" ;;
    "POS cassa"*) echo "in cassa" ;;
    "POS nero") echo "sul nero" ;;
    "POS bianco") echo "sul bianco" ;;
    Petrolifere*) echo "petrolifere" ;;
    OPT*) echo "opt" ;;
  esac
}
