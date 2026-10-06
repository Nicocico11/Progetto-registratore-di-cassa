#!/bin/bash
# Vendite "da segnare dopo" dai pulsanti della tendina (quando c'è tanta gente):
#   da_segnare.sh danea | fax  -> aggiunge una vendita da segnare (solo il tipo e l'ora, niente importo)
#   da_segnare.sh segna        -> appena c'è tempo: chiede importo e pagamento di ognuna, in ordine
#   da_segnare.sh conta        -> "2 Danea · 1 fax" (per la notifica), niente se non ce ne sono
. ~/.termux/tasker/widget_comune.sh
FILE=~/.cassa_da_segnare
NOTIFICA=~/.termux/tasker/notifica.sh

conta() {
  [ -s "$FILE" ] || return 0
  local d f
  d=$(grep -c '^danea' "$FILE"); f=$(grep -c '^fax' "$FILE")
  local testo=""
  [ "$d" -gt 0 ] && testo="$d Danea"
  [ "$f" -gt 0 ] && testo="${testo:+$testo · }$f fax"
  echo "$testo"
}

case "$1" in
  danea|fax)
    echo "$1 $(date +%H:%M)" >> "$FILE"
    termux-vibrate -d 60 > /dev/null 2>&1    # vibrazione corta: tocco preso
    bash "$NOTIFICA"
    ;;
  conta)
    conta
    ;;
  segna)
    [ -s "$FILE" ] || { finestra "📝 Da segnare" "Nessuna vendita da segnare."; exit 0; }
    FATTE=""
    while [ -s "$FILE" ]; do
      read -r TIPO ORA < "$FILE"
      TOT=$(grep -c . "$FILE")
      if [ "$TIPO" = fax ]; then
        COSA=$(numero "📠 Fax delle $ORA (ne restano $TOT): quanti euro?" "es. 1,50")
        [ -n "$COSA" ] && COSA="fax $COSA euro"
      else
        COSA=$(testo "🛒 Danea delle $ORA (ne restano $TOT): cosa?" "es. ichnusa · 2 red bull · danea caricabatterie 15")
      fi
      PAGATO=""
      [ -n "$COSA" ] && PAGATO=$(pagamento "💳 Pagamento di: $COSA")
      if [ -z "$COSA" ] || [ -z "$PAGATO" ]; then
        # Annullato: tocco sbagliato (si scarta) oppure si segna più tardi
        if conferma "🗑️ Scarto questa vendita?" "Sì = era un tocco sbagliato, la tolgo. No = la tengo e la segno dopo."; then
          sed -i '1d' "$FILE"
          FATTE+="🗑️ $TIPO delle $ORA scartato"$'\n'
          continue
        fi
        break
      fi
      RISPOSTA=$(bash "$CASSA" "$COSA $PAGATO")
      FATTE+="$(grep -m3 -E '✅|⚠️|❌|❓|🧾' <<< "$RISPOSTA" || head -1 <<< "$RISPOSTA")"$'\n'
      # Se non è stata capita resta da segnare (si riprova); altrimenti è fatta
      if grep -qE '✅|⚠️ Vendita salvata' <<< "$RISPOSTA"; then sed -i '1d' "$FILE"; else break; fi
    done
    [ -s "$FILE" ] || rm -f "$FILE"
    RESTANO=$(conta)
    [ -n "$RESTANO" ] && FATTE+=$'\n'"📝 Restano da segnare: $RESTANO"
    bash "$NOTIFICA"
    [ -n "$FATTE" ] && finestra "📝 Vendite segnate" "$FATTE"
    ;;
esac
