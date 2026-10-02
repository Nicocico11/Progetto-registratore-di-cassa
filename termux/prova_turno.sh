#!/bin/bash
# Prova automatica di un turno completo, da eseguire su computer prima di ogni aggiornamento.
# Simula i comandi di Termux:API e il server IA in una cartella temporanea; non tocca i dati veri.
# Uso: bash termux/prova_turno.sh   (esce con errore se qualcosa non va)

set -u
QUI=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d)
mkdir -p $HOME/.termux/tasker $HOME/bin $HOME/storage/downloads $HOME/llama.cpp/build/bin
cp $QUI/*.sh $QUI/processa_ia.py $QUI/migra_prezzi.py $HOME/.termux/tasker/
cp $QUI/info_turno.py $HOME/
printf '#!/bin/bash\n' > $HOME/.termux/tasker/notifica.sh
for c in termux-vibrate termux-wake-lock termux-wake-unlock termux-notification; do
  printf '#!/bin/bash\n' > $HOME/bin/$c; chmod +x $HOME/bin/$c
done
printf '#!/bin/bash\necho %s\n' "'{\"code\": -1, \"text\": \"140532\"}'" > $HOME/bin/termux-dialog
printf '#!/bin/bash\nsleep 1\n' > $HOME/llama.cpp/build/bin/llama-server
chmod +x $HOME/bin/termux-dialog $HOME/llama.cpp/build/bin/llama-server
export PATH=$HOME/bin:$PATH
echo '{"adblue_sfuso":1.30,"adblue_tanica":26.00,"redbull":3.00,"mars":2.00}' > $HOME/prezzi.json
python3 $HOME/.termux/tasker/migra_prezzi.py > /dev/null

S=$HOME/.termux/tasker/avvia_ia.sh
D=$HOME/storage/downloads/Chiusure_Turno
ERRORI=0
controlla() {  # controlla "descrizione" "frase" "testo atteso nella risposta"
  local out
  out=$(bash $S "$2" 2>&1)
  if [[ "$out" == *"$3"* ]] && [[ "$out" != *Traceback* ]]; then
    echo "  ok   $1"
  else
    echo "  ERRORE $1"; echo "$out" | sed 's/^/         /'; ERRORI=$((ERRORI+1))
  fi
}

echo "Prova turno completo:"
controlla "apertura turno"            "apertura turno"                               "TURNO APERTO"
[ -f $D/*.txt ] && echo "  ok   documento creato in Download all'apertura" || { echo "  ERRORE documento non creato"; ERRORI=$((ERRORI+1)); }
controlla "vendita carburante"        "20 euro di gasolio carta"                     "Gasolio 20.00"
controlla "numeri in lettere"         "trentacinque di verde col pos"                "Benzina 35.00"
controlla "centesimi"                 "venti e cinquanta di gasolio"                 "Gasolio 20.50"
controlla "vendita mista"             "50 gasolio, 20 litri di adblue e 2 red bull con carta" "3 voci"
controlla "ricevuta market con carta" "2 mars bancomat"                              "STAMPARE RICEVUTA"
controlla "cartissima"                "40 gasolio cartissima"                        "Carta carburante"
controlla "fax"                       "5 fax"                                        "5 fogli"
controlla "frase senza importo"       "ciao"                                         "Niente salvato"
controlla "totali"                    "totali"                                       "PER PAGAMENTO"
controlla "market"                    "market"                                       "Red Bull"
controlla "erogazioni adblue"         "erogazioni"                                   "litri erogati"
controlla "cancella ultima"           "cancella ultima"                              "Cancellata"
grep -q "Gasolio\|gasolio" $D/*_dati.csv && echo "  ok   copia dati aggiornata in Download" || { echo "  ERRORE copia dati"; ERRORI=$((ERRORI+1)); }
rm $HOME/transazioni_turno.csv
controlla "ripristino da Download"    "ripristina turno"                             "Ripristinate"
controlla "chiusura turno"            "chiusura turno"                               "Terminale pompe: 14:05:32"
grep -q "CHIUSURA TURNO" $D/*.txt && echo "  ok   documento finale in Download" || { echo "  ERRORE documento finale"; ERRORI=$((ERRORI+1)); }
[ ! -s $HOME/turno_corrente.json ] && echo "  ok   turno azzerato" || { echo "  ERRORE turno non azzerato"; ERRORI=$((ERRORI+1)); }

rm -rf "$HOME"
if [ $ERRORI -eq 0 ]; then echo "✅ Tutto ok"; else echo "❌ $ERRORI errori"; exit 1; fi
