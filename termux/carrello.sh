#!/bin/bash
# Pulsanti del carrello nella tendina (prodotti letti con lo scanner Binary Eye):
#   carrello.sh paga    -> pagamento, poi salva tutto come una vendita sola
#   carrello.sh aggiungi -> carburante, fax, AdBlue o un prodotto scritto nel carrello (cose che non si scansionano)
#   carrello.sh svuota  -> chiede conferma e svuota
. ~/.termux/tasker/widget_comune.sh
C="python3 $HOME/.termux/tasker/carrello.py"
NOTIFICA=~/.termux/tasker/notifica.sh

# Un tocco doppio sul pulsante non deve far partire due pagamenti
BLOCCO=~/.cassa_carrello.blocco
if ! mkdir "$BLOCCO" 2>/dev/null; then
  # blocco rimasto da un pagamento interrotto (più vecchio di 5 minuti): si toglie
  [ -n "$(find "$BLOCCO" -maxdepth 0 -mmin +5 2>/dev/null)" ] && rmdir "$BLOCCO" && mkdir "$BLOCCO" || exit 0
fi
trap 'rmdir "$BLOCCO" 2>/dev/null' EXIT

case "$1" in
  paga)
    RIEPILOGO=$($C riepilogo)
    [ -z "$RIEPILOGO" ] && { avviso "🛒 Carrello" "🛒 Il carrello è vuoto"; exit 0; }
    # Codici sconosciuti: "che prodotto è?" (ricordato per le prossime volte); annullato = carrello com'è
    if [[ "$RIEPILOGO" == *"❓"* ]]; then
      $C impara || { bash "$NOTIFICA"; exit 0; }
      bash "$NOTIFICA"
      RIEPILOGO=$($C riepilogo)
    fi
    SCELTA=$(scegli "🛒 $RIEPILOGO" "Contanti,POS cassa,POS nero,POS bianco,Petrolifere,🗑️ Togli l'ultimo letto")
    case "$SCELTA" in
      "") exit 0 ;;                                     # annullato: il carrello resta
      🗑️*) $C togli; bash "$NOTIFICA"; rmdir "$BLOCCO"; exec bash "$0" paga ;;
      Contanti) PAGATO="contanti" ;;
      "POS cassa") PAGATO="in cassa" ;;
      "POS nero") PAGATO="sul nero" ;;
      "POS bianco") PAGATO="sul bianco" ;;
      Petrolifere) PAGATO="petrolifere" ;;
    esac
    N=$($C quanti); CODICI=$($C codici)
    RISPOSTA=$(CASSA_CARRELLO_INCLUSO=1 bash "$CASSA" "$CODICI $PAGATO")
    # Salvata: tolti dal carrello i prodotti venduti. Non capita (es. codice sconosciuto): il carrello resta
    if grep -qE '✅|⚠️ Vendita salvata' <<< "$RISPOSTA"; then $C venduti "$N"; fi
    bash "$NOTIFICA"
    avviso "🛒 Carrello" "$(grep -m4 -E '✅|⚠️|❌|❓|🧾' <<< "$RISPOSTA" || head -3 <<< "$RISPOSTA")"
    ;;
  aggiungi)
    # Cose che non si scansionano: carburante, fax, AdBlue sfuso
    case "$(scegli "➕ Aggiungi al carrello" "⛽ Carburante (€),📠 Fax (copie),🧪 AdBlue sfuso (litri),🛒 Prodotto (scrivi il nome)")" in
      ⛽*) TIPO=carburante; VALORE=$(numero "⛽ Carburante (€)" "50") ;;
      📠*) TIPO=fogli; VALORE=$(numero "📠 Fax: quante copie?" "5") ;;
      🧪*) TIPO=adblue; VALORE=$(numero "🧪 AdBlue (litri)" "20") ;;
      🛒*) $C aggiungi_prodotto; bash "$NOTIFICA"; exit 0 ;;
      *) exit 0 ;;
    esac
    VALORE=$(python3 ~/info_turno.py importo "$VALORE")
    [ -n "$VALORE" ] && [ "$VALORE" != 0 ] && $C aggiungi "$TIPO" "$VALORE"
    bash "$NOTIFICA"
    ;;
  svuota)
    if conferma "🗑️ Svuoto il carrello?" "$($C riepilogo)"; then
      $C svuota
      bash "$NOTIFICA"
    fi
    ;;
esac
