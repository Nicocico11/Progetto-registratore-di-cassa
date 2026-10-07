#!/bin/bash
# Pulsanti del carrello nella tendina (prodotti letti con lo scanner Binary Eye):
#   carrello.sh paga    -> pagamento, poi salva tutto come una vendita sola
#   carrello.sh svuota  -> chiede conferma e svuota
. ~/.termux/tasker/widget_comune.sh
C="python3 $HOME/.termux/tasker/carrello.py"
NOTIFICA=~/.termux/tasker/notifica.sh

case "$1" in
  paga)
    RIEPILOGO=$($C riepilogo)
    [ -z "$RIEPILOGO" ] && { finestra "🛒 Carrello" "Il carrello è vuoto."; exit 0; }
    SCELTA=$(scegli "🛒 $RIEPILOGO" "Contanti,POS cassa,POS nero,POS bianco,Petrolifere,🗑️ Togli l'ultimo letto")
    case "$SCELTA" in
      "") exit 0 ;;                                     # annullato: il carrello resta
      🗑️*) $C togli; bash "$NOTIFICA"; exec bash "$0" paga ;;
      Contanti) PAGATO="contanti" ;;
      "POS cassa") PAGATO="in cassa" ;;
      "POS nero") PAGATO="sul nero" ;;
      "POS bianco") PAGATO="sul bianco" ;;
      Petrolifere) PAGATO="petrolifere" ;;
    esac
    RISPOSTA=$(bash "$CASSA" "$($C codici) $PAGATO")
    # Salvata: carrello vuoto. Non capita (es. codice sconosciuto): il carrello resta, si corregge
    if grep -qE '✅|⚠️ Vendita salvata' <<< "$RISPOSTA"; then $C svuota; fi
    bash "$NOTIFICA"
    finestra "🛒 Carrello" "$(grep -m4 -E '✅|⚠️|❌|❓|🧾' <<< "$RISPOSTA" || head -3 <<< "$RISPOSTA")"
    ;;
  svuota)
    if conferma "🗑️ Svuoto il carrello?" "$($C riepilogo)"; then
      $C svuota
      bash "$NOTIFICA"
    fi
    ;;
esac
