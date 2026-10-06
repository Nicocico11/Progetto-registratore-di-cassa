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
except Exception:
    pass'
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
        AVANZO=$(chiedi "Avanzo cassa turno precedente (€)" "es. 150,50")
        ORA_PREC=$(chiedi "Ora chiusura turno precedente" "tutto attaccato, es. 140532" -n)
        CONTATORE=$(chiedi "Contatore AdBlue iniziale" "numero sulla colonnina, es. 68624,4")
        TANICHE=$(chiedi "Taniche AdBlue presenti" "es. 59" -n)
      fi
      echo "🟢 TURNO APERTO"
      # "apertura turno notte": turno scelto a voce invece che dall'orario
      TIPO=$(grep -oE 'mattina|pomeriggio|notte' <<< "$FRASE" | head -1)
      # "apertura turno prova" / "test": file con TEST nel nome, contatori veri non toccati
      PROVA=$(grep -oE 'prova|test' <<< "$FRASE" | head -1)
      python3 ~/info_turno.py apri turno "$AVANZO" "$ORA_PREC" "$CONTATORE" "$TANICHE" "$TIPO" "$PROVA"
      # L'IA non si accende più da sola: le vendite si capiscono con le regole ("accendi ia" se serve)
    elif [[ "$FRASE" =~ (chiudi|chiusura|fine|finisci|termina) ]]; then
      # Orario del terminale pompe con i secondi: detto nella frase
      # ("chiusura turno 14 05 32") oppure scritto nel popup (es. 140532)
      ORARIO=$(grep -oE '[0-9]+' <<< "$FRASE" | tr '\n' ' ')
      if [ -z "$ORARIO" ]; then
        ORARIO=$(chiedi "Orario terminale pompe" "ore minuti secondi, es. 140532" -n)
      fi
      # I contanti attesi li calcola da solo dalle vendite: serve solo la cassaforte
      CASSAFORTE=$(chiedi "In cassaforte (€)" "vuoto se non c'è niente")
      echo "🔴 TURNO CHIUSO - IA spenta"
      python3 ~/info_turno.py "chiudi turno" "$ORARIO" "" "$CASSAFORTE"
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
    python3 $CARTELLA/processa_ia.py --correggi $QUALE "$TESTO"
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
        TITOLO="🏦 Banconote del versamento di $IMPORTO_V €"
        for TENTATIVO in 1 2 3; do
          BANCONOTE=""
          if [ -n "$IMPORTO_V" ]; then
            BANCONOTE=$(chiedi "$TITOLO" "es. 200 50 50 50  oppure  1x200 3x50 (vuoto = le calcolo io)")
            if [ $TENTATIVO -gt 1 ] && [ -z "$BANCONOTE" ]; then   # annullato dopo un errore: niente salvato
              RISPOSTA_V="❌ Banconote non corrette: versamento NON salvato. Ridillo."; ESITO=3; break
            fi
          fi
          RISPOSTA_V=$(python3 ~/info_turno.py versamento "$FRASE" "$BANCONOTE")
          ESITO=$?
          [ $ESITO -ne 3 ] && break
          # Le banconote non tornano: si richiedono (niente salvato finché non tornano)
          TITOLO="❌ Non tornano, riscrivi le banconote di $IMPORTO_V €"
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
        -v "Ultima operazione (qualsiasi),Ultimo Danea (anche taniche AdBlue),Ultimo carburante,Ultimo AdBlue sfuso,Ultimo fax" 2>/dev/null \
        | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin); print(d.get("text", "") if d.get("code") == -1 else "")
except Exception:
    pass')
      case "$SCELTA_C" in
        Ultima*) TIPO_C=tutto ;; *Danea*) TIPO_C=danea ;; *carburante*) TIPO_C=carburante ;;
        *AdBlue*) TIPO_C=adblue ;; *fax*) TIPO_C=fax ;; *) TIPO_C="" ;;
      esac
    fi
    if [ -z "$TIPO_C" ]; then
      echo "Niente cancellato."
    elif [ "$TIPO_C" = tutto ]; then
      python3 ~/info_turno.py "cancella ultima"
    else
      python3 ~/info_turno.py "cancella ultima" "$TIPO_C"
    fi
    ESITO=$? ;;
  *"totali"*|*"riepilogo"*)
    # In una finestra che resta finché non premi OK (il messaggio a schermo di Tasker è troppo piccolo);
    # il riepilogo completo è nel pulsante 04 Totali
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
      RISPOSTA=$(python3 $CARTELLA/processa_ia.py "$TESTO")
      ESITO=$?
      echo "$RISPOSTA"
      # Frase non capita (parola sentita male): riquadro per scriverla giusta
      if [ $ESITO -eq 1 ] && [[ "$RISPOSTA" == *"❓"* ]] && [[ "$RISPOSTA" != *"Quale prodotto"* ]]; then
        CORRETTA=$(chiedi "✏️ Non capito: scrivi la frase giusta" "$TESTO")
        if [ -n "$CORRETTA" ]; then
          echo "$(date) - Corretta a mano: '$CORRETTA'" >> ~/debug_tasker.log
          echo "✏️ $CORRETTA"
          python3 $CARTELLA/processa_ia.py "$CORRETTA"
          ESITO=$?
        fi
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
