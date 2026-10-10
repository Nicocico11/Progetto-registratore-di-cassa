#!/bin/bash
# Unico punto d'ingresso da Tasker: riceve tutto quello che dici.
# Se è un comando (apri turno, cancella ultima, totali...) lo esegue,
# altrimenti lo tratta come una vendita.
# Al termine: notifica aggiornata e vibrazione in base all'esito
#   1 vibrazione corta = tutto ok
#   2 vibrazioni corte = salvato, ma controlla
#   1 vibrazione lunga = errore, niente salvato
# A turno chiuso: niente vendite, niente notifiche, IA spenta.

CARTELLA=~/.termux/tasker

# Log di debug per Tasker
echo "$(date) - Ricevuto da Tasker: '$1'" >> ~/debug_tasker.log

TESTO="$1"

if [ -z "$TESTO" ] || [[ "$TESTO" == %* ]]; then
  echo "❌ Errore: Testo vocale non valido o variabile Tasker non espansa ($TESTO)" | tee -a ~/debug_tasker.log
  nohup bash $CARTELLA/vibra.sh errore > /dev/null 2>&1 &
  exit 0
fi

# Popup di testo (Termux:API): stampa quello che è stato scritto, niente se annullato
chiedi() {  # chiedi "titolo" "suggerimento" [-n per tastiera numerica]
  termux-dialog text $3 -t "$1" -i "$2" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("code") == -1:
        print(d.get("text", ""))
        sys.exit(0)
except Exception:
    pass
sys.exit(1)'
}

# Come chiedi, ma se il riquadro si chiude senza OK (Annulla o tocco fuori) chiede se riaprirlo:
# un campo lasciato vuoto per sbaglio non passa in silenzio. Falso se non si vuole riaprire.
chiedi_ok() {
  local risposta
  while true; do
    if risposta=$(chiedi "$@"); then echo "$risposta"; return 0; fi
    chiedi_si "↩️ Riquadro chiuso senza OK" "Riapro \"$1\"?" || return 1
  done
}

# Popup Sì/No: vero se la risposta è "sì"
chiedi_si() {
  termux-dialog confirm -t "$1" -i "$2" 2>/dev/null | python3 -c '
import sys, json
try:
    sys.exit(0 if str(json.load(sys.stdin).get("text", "")).strip().lower() in ("yes", "si", "sì") else 1)
except Exception:
    sys.exit(1)'
}

# Vero se il turno è aperto; altrimenti avvisa e segna l'errore
turno_aperto() {
  if python3 ~/info_turno.py aperto; then
    return 0
  fi
  echo "❌ Turno non aperto: di' prima \"apertura turno\". Niente salvato."
  ESITO=1
  return 1
}

spegni_ia() {
  # stato_ia.sh aspetta che l'IA sia davvero spenta e aggiorna (o toglie) la notifica
  bash $CARTELLA/stato_ia.sh spegni
}

FRASE="${TESTO,,}"   # tutto minuscolo
ESITO=0

# Tutto quello che il comando scrive passa anche da un file, per accorgersi degli avvisi ⚠️
USCITA=$(mktemp)
{
case "$FRASE" in
  *turno*)
    # Qualsiasi frase con "turno" è un comando, mai una vendita
    if [[ "$FRASE" =~ ripristin ]]; then
      python3 ~/info_turno.py ripristina
    elif [[ "$FRASE" =~ (apri|apertura|inizio|inizia|avvia|comincia) ]]; then
      AVANZO=""; ORA_PREC=""; CONTATORE=""; TANICHE=""
      if ! python3 ~/info_turno.py aperto; then
        # Valori del turno PRECEDENTE (di un altro operatore): si scrivono sempre a mano,
        # vuoto = non inserito (nell'Excel restano da scrivere)
        AVANZO=$(chiedi_ok "Avanzo (€)" "150,50")
        ORA_PREC=$(chiedi_ok "Ora chiusura precedente" "140532" -n)
        CONTATORE=$(chiedi_ok "Contatore AdBlue" "68624,4")
        TANICHE=$(chiedi_ok "Taniche AdBlue" "59" -n)
        rm -f ~/.cassa_da_segnare ~/.cassa_carrello   # "da segnare" e carrello rimasti da un turno vecchio
      fi
      echo "🟢 TURNO APERTO"
      # "apertura turno notte": turno scelto a voce invece che dall'orario
      TIPO=$(grep -oE 'mattina|pomeriggio|notte' <<< "$FRASE" | head -1)
      # "apertura turno prova" / "test": file con TEST nel nome, contatori veri non toccati
      PROVA=$(grep -oE 'prova|test' <<< "$FRASE" | head -1)
      python3 ~/info_turno.py apri turno "$AVANZO" "$ORA_PREC" "$CONTATORE" "$TANICHE" "$TIPO" "$PROVA"
      # L'IA non si accende più da sola: le vendite si capiscono con le regole ("accendi ia" se serve)
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]] && [ -s ~/.cassa_carrello ]; then
      # Prodotti letti con lo scanner e mai pagati
      echo "⚠️ NON CHIUSO: c'è il carrello dello scanner da pagare ($(python3 $CARTELLA/carrello.py riepilogo)). Tocca \"💳 Paga carrello\" o \"🗑️ Svuota\" nella tendina, poi richiudi"
      ESITO=1
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]] && [ -s ~/.cassa_da_segnare ]; then
      # Vendite segnate con i pulsanti della tendina e mai registrate: prima vanno segnate
      echo "⚠️ NON CHIUSO: ci sono vendite da segnare ($(bash $CARTELLA/da_segnare.sh conta)). Tocca \"📝 Segna\" nella tendina, poi richiudi"
      ESITO=1
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]]; then
      # Orario del terminale pompe con i secondi: detto nella frase
      # ("chiusura turno 14 05 32") oppure scritto nel popup (es. 140532)
      ORARIO=$(grep -oE '[0-9]+' <<< "$FRASE" | tr '\n' ' ')
      if [ -z "$ORARIO" ]; then
        ORARIO=$(chiedi_ok "Orario terminale" "140532" -n)
      fi
      # I contanti attesi li calcola da solo dalle vendite: serve solo la cassaforte
      CASSAFORTE=$(chiedi_ok "Cassaforte (€)" "vuoto = niente")
      # Totale della colonnina: nell'Excel (TOTALE CARBURANTI) e per la differenza; vuoto = lo scrivi sul computer
      CARBURANTI_COLONNINA=$(chiedi_ok "⛽ Totale carburanti colonnina (€)" "vuoto = lo scrivo dopo")
      echo "🔴 TURNO CHIUSO - IA spenta"
      python3 ~/info_turno.py "chiudi turno" "$ORARIO" "" "$CASSAFORTE" "$CARBURANTI_COLONNINA"
      spegni_ia
    else
      echo "❓ Comando turno non capito: \"$TESTO\" (di' \"apri turno\" o \"chiudi turno\")"
      ESITO=1
    fi ;;
  "ia"|*" ia"|"ia "*|*" ia "*|*"server"*|*"intelligenza"*)
    # "accendi ia", "spegni ia", "stato ia"
    if [[ "$FRASE" =~ (accendi|avvia|attiva) ]]; then
      turno_aperto && bash $CARTELLA/avvia_server.sh
    elif [[ "$FRASE" =~ (spegni|ferma|disattiva) ]]; then
      spegni_ia
      echo "⚫ IA spenta"
    else
      case "$(curl -s --max-time 2 http://127.0.0.1:8080/health)" in
        *'"ok"'*) echo "🟢 IA accesa e pronta" ;;
        *) if pgrep -x llama-server > /dev/null || pgrep -f "llama-server -m" > /dev/null; then echo "🟡 IA in avvio"; else echo "⚫ IA spenta"; fi ;;
      esac
    fi ;;
  "market"|"danea"|"negozio"|*"vendite market"*|*"vendite danea"*|*"prodotti venduti"*)
    # Solo la parola: elenco dei prodotti venduti. "danea 15 euro" invece è una vendita (sotto)
    python3 ~/info_turno.py market ;;
  *"erogazion"*|*"quanto adblue"*|*"quante adblue"*)
    python3 ~/info_turno.py adblue ;;
  *"correggi"*|*"correggere"*|*"modifica"*)
    # "correggi ultima carta", "correggi penultima 25 euro", "correggi ultima gasolio"
    if [[ "$FRASE" =~ penultim ]]; then QUALE=penultima; else QUALE=ultima; fi
    CORREZIONE_DETTA="$TESTO"
    if [[ "$FRASE" =~ ^[[:space:]]*(correggi|correggere|modifica|modificare)([[:space:]]+(la|l\'|il))?([[:space:]]*(ultim|penultim)[ao])?[[:space:]]*$ ]]; then
      # Detto solo "correggi ultima": si scrive cosa cambiare
      COSA=$(chiedi "✏️ Cosa correggo nella $QUALE vendita?" "83,07 · sul nero · gasolio · box acqua")
      CORREZIONE_DETTA=""; [ -n "$COSA" ] && CORREZIONE_DETTA="correggi $QUALE $COSA"
    fi
    if [ -z "$CORREZIONE_DETTA" ]; then
      echo "Niente cambiato."
    else
      python3 $CARTELLA/processa_ia.py --correggi $QUALE "$CORREZIONE_DETTA"
    fi
    ESITO=$?
    python3 ~/info_turno.py salva > /dev/null 2>&1 ;;
  *"contatore"*)
    # "contatore adblue 68624,4" / "contatore taniche 59": valori di partenza
    python3 ~/info_turno.py contatore "$FRASE"
    ESITO=$? ;;
  *"versamento"*|*"versato"*)
    if turno_aperto; then
      # Le banconote servono per il riquadro VERSAMENTO dell'Excel (quante da 500, 200, 100...)
      if [[ "$FRASE" =~ (cancella|annulla|togli|elimina) ]]; then
        python3 ~/info_turno.py "cancella versamento"
        ESITO=$?
      else
        IMPORTO_V=$(python3 ~/info_turno.py importo "$FRASE")
        TITOLO="🏦 Banconote di $IMPORTO_V €"
        for TENTATIVO in 1 2 3; do
          BANCONOTE=""
          if [ -n "$IMPORTO_V" ]; then
            BANCONOTE=$(chiedi "$TITOLO" "200 50 50 50 (vuoto = le calcolo io)")
            if [ $TENTATIVO -gt 1 ] && [ -z "$BANCONOTE" ]; then   # annullato dopo un errore: niente salvato
              RISPOSTA_V="❌ Banconote non corrette: versamento NON salvato. Ridillo."; ESITO=3; break
            fi
          fi
          RISPOSTA_V=$(python3 ~/info_turno.py versamento "$FRASE" "$BANCONOTE")
          ESITO=$?
          [ $ESITO -ne 3 ] && break
          # Le banconote non tornano: si richiedono (niente salvato finché non tornano)
          TITOLO="❌ Non tornano: banconote di $IMPORTO_V €"
        done
        [ $ESITO -eq 3 ] && ESITO=1
        echo "$RISPOSTA_V"
      fi
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
  *"avanzo"*)
    if turno_aperto; then
      python3 ~/info_turno.py avanzo "$FRASE"
      ESITO=$?
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
  *"penultima"*|*"penultimo"*)
    python3 ~/info_turno.py "cancella penultima" ;;
  *"cancella ultim"*|*"elimina ultim"*|*"annulla ultim"*|*"cancellala"*)
    # "cancella ultima danea / carburante / adblue / fax": l'ultima di quel tipo;
    # senza tipo compare il riquadro per scegliere (anche "Ultima operazione")
    if [[ "$FRASE" =~ (danea|market|negozio|prodott|tanic) ]]; then TIPO_C=danea
    elif [[ "$FRASE" =~ (carburant|gasolio|benzina|diesel|gpl|verde|rifornim) ]]; then TIPO_C=carburante
    elif [[ "$FRASE" =~ (adblue|ad\ blu|adblu|blu|sfuso|litri) ]]; then TIPO_C=adblue
    elif [[ "$FRASE" =~ (fax|fotocop|fogli) ]]; then TIPO_C=fax
    elif [[ "$FRASE" =~ (operazione|qualsiasi|tutto|vendita) ]]; then TIPO_C=tutto
    else
      SCELTA_C=$(termux-dialog radio -t "🗑️ Cosa cancello?" \
        -v "Ultima operazione (qualsiasi),Ultimo Danea (anche taniche AdBlue),Ultimo carburante,Ultimo AdBlue sfuso,Ultimo fax,📋 Scegli dall'elenco (cancella o correggi)" 2>/dev/null \
        | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin); print(d.get("text", "") if d.get("code") == -1 else "")
except Exception:
    pass')
      case "$SCELTA_C" in
        📋*) TIPO_C=elenco ;;
        Ultima*) TIPO_C=tutto ;; *Danea*) TIPO_C=danea ;; *carburante*) TIPO_C=carburante ;;
        *AdBlue*) TIPO_C=adblue ;; *fax*) TIPO_C=fax ;; *) TIPO_C="" ;;
      esac
    fi
    if [ -z "$TIPO_C" ]; then
      echo "Niente cancellato."
    elif [ "$TIPO_C" = elenco ]; then
      # Una vendita qualsiasi del turno (anche vecchia): si sceglie dalla lista, poi cancella o correggi
      ELENCO=$(python3 ~/info_turno.py "elenco scelta")
      if [ -z "$ELENCO" ]; then
        echo "Nessuna vendita da cancellare."
      else
        N_SCELTA=$(termux-dialog radio -t "📋 Quale vendita? (la più recente in alto)" -v "$(cut -f2 <<< "$ELENCO" | paste -sd,)" 2>/dev/null \
          | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin); print(d.get("index", "") if d.get("code") == -1 else "")
except Exception:
    pass')
        RIGA=""; [ -n "$N_SCELTA" ] && RIGA=$(sed -n "$((N_SCELTA + 1))p" <<< "$ELENCO")
        POS=$(cut -f1 <<< "$RIGA"); ETICHETTA=$(cut -f2 <<< "$RIGA")
        AZIONE=""; [ -n "$RIGA" ] && AZIONE=$(termux-dialog radio -t "$ETICHETTA" -v "🗑️ Cancella,✏️ Correggi (riscrivila giusta)" 2>/dev/null \
          | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin); print(d.get("text", "") if d.get("code") == -1 else "")
except Exception:
    pass')
        case "$AZIONE" in
          🗑️*)
            python3 ~/info_turno.py cancellascelta "$POS" "$ETICHETTA"; ESITO=$? ;;
          ✏️*)
            # Prima si salva quella giusta (in fondo al turno); solo se è stata capita si toglie quella sbagliata
            NUOVA=$(chiedi "✏️ Vendita giusta al posto di: $ETICHETTA" "50 gasolio sul nero")
            if [ -z "$NUOVA" ]; then
              echo "Niente cambiato."
            else
              RISPOSTA=$(python3 $CARTELLA/processa_ia.py "$NUOVA")
              ESITO_NUOVA=$?
              echo "$RISPOSTA"
              if grep -qE '✅|⚠️ Vendita salvata' <<< "$RISPOSTA"; then
                TOLTA=$(python3 ~/info_turno.py cancellascelta "$POS" "$ETICHETTA")
                grep -m1 -E "🗑️|❌" <<< "$TOLTA"
                [ $ESITO_NUOVA = 2 ] && ESITO=2
              else
                echo "❌ Vendita giusta non capita: quella vecchia resta. Niente cambiato."
                ESITO=1
              fi
            fi ;;
          *) echo "Niente cancellato." ;;
        esac
      fi
      python3 ~/info_turno.py salva > /dev/null 2>&1
      (exit $ESITO)   # l'esito lo prende la riga "ESITO=$?" qui sotto
    elif [ "$TIPO_C" = tutto ]; then
      python3 ~/info_turno.py "cancella ultima"
    else
      python3 ~/info_turno.py "cancella ultima" "$TIPO_C"
    fi
    ESITO=$? ;;
  *"conta cassa"*|*"conto cassa"*|*"conta la cassa"*|*"contare la cassa"*|*"conteggio cassa"*|*"conta il cassetto"*)
    # Come il riquadro CALCOLO AVANZO CASSA ATTUALE dell'Excel: banconote e spiccioli contati
    if turno_aperto; then
      # Un riquadro chiuso senza OK e non riaperto: conteggio annullato (mai un campo a zero per sbaglio)
      if ! { BANCONOTE=$(chiedi_ok "🧮 Banconote nella borsa" "50x2 20x2 10x7 5x13") &&
             CASSETTO=$(chiedi_ok "🪙 Spiccioli cassetto (€)" "54,62") &&
             BORSA=$(chiedi_ok "👜 Monete nella borsa (pezzi)" "2x3 1x5 0,50x4") &&
             CASSAFORTE_C=$(chiedi_ok "🔒 Cassaforte (€)" "vuoto = niente"); }; then
        echo "❌ Conta cassa annullato: niente contato (rifallo quando vuoi)"
        ESITO=1
      elif [ -z "$BANCONOTE$CASSETTO$BORSA" ]; then
        echo "Niente contato"
      else
        CONTO=$(python3 ~/info_turno.py contacassa "$BANCONOTE" "$CASSETTO" "$BORSA" "$CASSAFORTE_C")
        ESITO=$?
        nohup termux-dialog confirm -t "🧮 Conta cassa" -i "$CONTO" > /dev/null 2>&1 &
        grep -E "🎯|✅|⚠️" <<< "$CONTO"
      fi
    fi ;;
  *"totali"*|*"riepilogo"*)
    # In una finestra che resta finché non premi OK (il messaggio a schermo di Tasker è troppo piccolo);
    # il riepilogo completo è nel pulsante 04 Resoconto
    RIEPILOGO=$(python3 ~/info_turno.py totali breve)
    nohup termux-dialog confirm -t "📊 Totali del turno" -i "$RIEPILOGO" > /dev/null 2>&1 &
    echo "📊 Totali sullo schermo" ;;
  *"ultime"*|*"ultimi"*)
    python3 ~/info_turno.py ultimi ;;
  *"archivio"*|*"storico"*)
    python3 ~/info_turno.py archivio ;;
  *)
    # Una vendita: solo a turno aperto
    if turno_aperto; then
      # Rifornimento con il carrello dello scanner in attesa: si può pagare tutto insieme
      CODICI_CARRELLO=""
      # (non se la vendita ha già dei codici a barre: è il carrello stesso che si sta pagando)
      if [ -s ~/.cassa_carrello ] && [ -z "$CASSA_CARRELLO_INCLUSO" ] && ! [[ "$FRASE" =~ (^|[^a-z])opt([^a-z]|$) ]] && \
         [[ "$FRASE" =~ (gasolio|diesel|benzina|verde|gpl|gas|carburante) || \
            "$FRASE" =~ ^[0-9\ .,:e]+(euro)?\ *((sul|pos|col|con\ il)\ )?(contanti|nero|bianco|petrolifere|cartissima|carta|pos)?\ *$ ]]; then
        # codici sconosciuti: prima "che prodotto è?" (se annullato il carrello resta fuori da questa vendita)
        python3 $CARTELLA/carrello.py riepilogo | grep -q "❓" && python3 $CARTELLA/carrello.py impara
        if ! python3 $CARTELLA/carrello.py riepilogo | grep -q "❓" && \
           chiedi_si "🛒 Aggiungo il carrello a questa vendita?" "$(python3 $CARTELLA/carrello.py riepilogo)"; then
          N_CARRELLO=$(python3 $CARTELLA/carrello.py quanti); CODICI_CARRELLO=$(python3 $CARTELLA/carrello.py codici)
          # Pagamento non detto: si chiede ora, per tutto
          if ! [[ "$FRASE" =~ (contant|nero|bianco|cass|cartissim|cortissim|petrolif|pos|boss|carta|bancomat) ]]; then
            PAGA_TUTTO=$(termux-dialog radio -t "💳 Pagamento (carburante + carrello)" -v "Contanti,POS nero,POS bianco,Petrolifere" 2>/dev/null \
                         | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("text","") if d.get("code")==-1 else "")' 2>/dev/null)
            case "$PAGA_TUTTO" in
              Contanti) TESTO="$TESTO contanti" ;; "POS nero") TESTO="$TESTO sul nero" ;;
              "POS bianco") TESTO="$TESTO sul bianco" ;; Petrolifere) TESTO="$TESTO petrolifere" ;;
              *) CODICI_CARRELLO="" ;;     # annullato: solo il carburante, il carrello resta
            esac
          fi
        fi
      fi
      [ -n "$CODICI_CARRELLO" ] && TESTO="$CODICI_CARRELLO e $TESTO"
      RISPOSTA=$(python3 $CARTELLA/processa_ia.py "$TESTO")
      ESITO=$?
      echo "$RISPOSTA"
      # Frase non capita (parola sentita male): riquadro per scriverla giusta
      if [ $ESITO -eq 1 ] && [[ "$RISPOSTA" == *"❓"* ]] && [[ "$RISPOSTA" != *"Quale prodotto"* ]]; then
        CORRETTA=$(chiedi "✏️ Non capito, riscrivi" "$TESTO")
        if [ -n "$CORRETTA" ]; then
          echo "$(date) - Corretta a mano: '$CORRETTA'" >> ~/debug_tasker.log
          echo "✏️ $CORRETTA"
          python3 $CARTELLA/processa_ia.py "$CORRETTA"
          ESITO=$?
        fi
      fi
      if [ -n "$CODICI_CARRELLO" ] && grep -qE '✅|⚠️ Vendita salvata' <<< "$RISPOSTA"; then
        python3 $CARTELLA/carrello.py venduti "$N_CARRELLO"   # pagato insieme al carburante
      fi
      # Copia di sicurezza del turno in Download, aggiornata a ogni vendita
      python3 ~/info_turno.py salva > /dev/null 2>&1
    fi ;;
esac
} > "$USCITA" 2>&1
cat "$USCITA"

# Un avviso ⚠️ qualsiasi: anche notifica nella tendina, con suono
if grep -q "⚠️" "$USCITA"; then
  termux-notification --id avviso_cassa --priority high --sound --vibrate 400,200,400 \
    --title "⚠️ Controlla" --content "$(grep -m1 "⚠️" "$USCITA" | cut -c1-200)" > /dev/null 2>&1
fi
rm -f "$USCITA"

case $ESITO in
  0) VIBRAZIONE=ok ;;
  2) VIBRAZIONE=attenzione ;;
  *) VIBRAZIONE=errore ;;
esac

# Vibrazione subito (non in sottofondo: in sottofondo Android poteva bloccarla),
# notifiche in sottofondo per non far aspettare Tasker (a turno chiuso si tolgono da sole)
bash $CARTELLA/vibra.sh $VIBRAZIONE > /dev/null 2>&1
nohup bash $CARTELLA/notifica.sh > /dev/null 2>&1 &
# Mail rimaste in coda (chiusura fatta senza internet): si riprova in sottofondo
[ -s ~/.cassa_email_coda ] && nohup python3 $CARTELLA/invia_mail.py coda > /dev/null 2>&1 &
nohup bash $CARTELLA/stato_ia.sh aggiorna > /dev/null 2>&1 &

# Sempre 0: l'esito lo comunicano messaggio e vibrazione, così Tasker non interrompe il Task
exit 0
