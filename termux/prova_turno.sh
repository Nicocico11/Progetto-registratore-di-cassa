#!/bin/bash
# Prova automatica di un turno completo, da eseguire su computer prima di ogni aggiornamento.
# Simula i comandi di Termux:API e il server IA in una cartella temporanea; non tocca i dati veri.
# Uso: bash termux/prova_turno.sh   (esce con errore se qualcosa non va)

set -u
QUI=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d)
mkdir -p $HOME/.termux/tasker $HOME/bin $HOME/storage/downloads $HOME/llama.cpp/build/bin
cp $QUI/*.sh $QUI/processa_ia.py $QUI/migra_prezzi.py $QUI/excel_turno.py $QUI/modello_turno.xlsx $HOME/.termux/tasker/
cp $QUI/info_turno.py $HOME/
for c in termux-vibrate termux-wake-lock termux-wake-unlock; do
  printf '#!/bin/bash\n' > $HOME/bin/$c; chmod +x $HOME/bin/$c
done
# Notifiche finte: annotano cosa viene mostrato o tolto
printf '#!/bin/bash\necho "mostra $*" >> ~/notifiche.log\n' > $HOME/bin/termux-notification
printf '#!/bin/bash\necho "togli $*" >> ~/notifiche.log\n' > $HOME/bin/termux-notification-remove
chmod +x $HOME/bin/termux-notification $HOME/bin/termux-notification-remove
cat > $HOME/bin/termux-dialog <<'EOF'
#!/bin/bash
# Popup finto: risponde in base al titolo
case "$*" in
  *Avanzo*)   echo '{"code": -1, "text": "150,50"}' ;;
  *Orario*)   echo '{"code": -1, "text": "140532"}' ;;
  *Contanti*) echo '{"code": -1, "text": "200"}' ;;
  *cassaforte*) echo '{"code": -1, "text": "20"}' ;;
  *)          echo '{"code": -2, "text": ""}' ;;   # POS: annullato
esac
EOF
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
controlla "vendita a turno chiuso"    "20 euro di gasolio"                           "Turno non aperto"
controlla "accendi ia a turno chiuso" "accendi ia"                                   "Turno non aperto"
sleep 1; grep -q "^mostra" $HOME/notifiche.log 2>/dev/null && { echo "  ERRORE notifiche a turno chiuso"; ERRORI=$((ERRORI+1)); } || echo "  ok   nessuna notifica a turno chiuso"
controlla "apertura turno con avanzo" "apertura turno"                               "150.50"
[ -f $D/*.txt ] && echo "  ok   documento creato in Download all'apertura" || { echo "  ERRORE documento non creato"; ERRORI=$((ERRORI+1)); }
controlla "contatore adblue"          "contatore adblue 1000 virgola 5"              "1000.5"
controlla "contatore taniche"         "contatore taniche 10"                         "10"
controlla "vendita carburante"        "20 euro di gasolio carta"                     "Gasolio 20.00"
controlla "abbuono"                   "20 e 10 di gasolio, abbuono 10 centesimi"     "-0.10"
controlla "tanica adblue con carta"   "tanica di adblue pos"                         "STAMPARE RICEVUTA"
controlla "versamento"                "versamento 50"                                "50.00"
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
controlla "correggi ultima pagamento"  "correggi ultima bancomat"                     "Bancomat"
controlla "correggi penultima importo" "correggi penultima 7 fax"                    "ora:"
controlla "correzione vendita mista"  "50 gasolio e 1 mars" "2 voci"
controlla "mista: solo pagamento"     "correggi ultima 30 euro"                      "vendita mista"
controlla "avanzo a voce"             "avanzo 160"                                   "160.00"
controlla "cancella ultima"           "cancella ultima"                              "Cancellata"
grep -q "Gasolio\|gasolio" $D/*_dati.csv && echo "  ok   copia dati aggiornata in Download" || { echo "  ERRORE copia dati"; ERRORI=$((ERRORI+1)); }
rm $HOME/transazioni_turno.csv
controlla "ripristino da Download"    "ripristina turno"                             "Ripristinate"
controlla "chiusura turno"            "chiusura turno"                               "Terminale pompe: 14:05:32"
sleep 1; tail -4 $HOME/notifiche.log | grep -q "togli stato_ia" && tail -4 $HOME/notifiche.log | grep -q "togli distributore_turno" && echo "  ok   notifiche tolte alla chiusura" || { echo "  ERRORE notifiche non tolte"; ERRORI=$((ERRORI+1)); }
grep -q "Contanti contati" $D/*.txt && echo "  ok   quadratura nel documento" || { echo "  ERRORE quadratura"; ERRORI=$((ERRORI+1)); }
python3 - "$D" <<'PYEOF' && echo "  ok   file Excel compilati" || { echo "  ERRORE file Excel"; ERRORI=$((ERRORI+1)); }
import glob, sys, openpyxl
d = sys.argv[1]
files = sorted(glob.glob(d + "/*.xlsx"))
assert len(files) == 2, files
oggi = [f for f in files if openpyxl.load_workbook(f).active['D2'].value is None and openpyxl.load_workbook(f).active['E2'].value]
ws = openpyxl.load_workbook(oggi[0]).active
assert ws['O20'].value == 1000.5 and ws['O19'].value == 1020.5, (ws['O20'].value, ws['O19'].value)   # +20 litri
assert ws['K30'].value == 10 and ws['K31'].value == 9                     # 1 tanica venduta
assert ws['I17'].value == 20 and ws['A21'].value == 1.5                   # litri sfuso, fax
assert ws['I5'].value == 0.1                                              # abbuono
assert 26 in [ws[c].value for c in ('S27', 'T27', 'U27')]                 # scontrino tanica con POS
assert ws['D7'].value == 160 and ws['I24'].value is None                 # primo turno: ora chiusura precedente sconosciuta
assert ws['I28'].value == 20                                              # cassaforte
assert ws['D2'].formula if hasattr(ws['D2'], 'formula') else True
assert ws.protection.sheet and ws['D4'].value.startswith('=')            # protezione e formule intatte
import zipfile
assert 'fullCalcOnLoad="1"' in zipfile.ZipFile(oggi[0]).read('xl/workbook.xml').decode()   # Excel ricalcola all'apertura
dopo = [f for f in files if f not in oggi][0]
w2 = openpyxl.load_workbook(dopo).active
dopo_atteso = {'MATTINA': 'POMERIGGIO', 'POMERIGGIO': 'NOTTE', 'NOTTE': 'MATTINA'}[ws['I22'].value]
assert str(w2['I24'].value) == '14:05:32' and w2['I28'].value == 20     # orario terminale di oggi -> turno dopo
import json, os
stato = json.load(open(os.path.expanduser('~/stato_cassa.json')))
assert stato['orario_chiusura'] == '14:05:32' and stato['contatore'] == 1020.5 and stato['taniche'] == 9, stato
assert w2['O20'].value == 1020.5 and w2['K30'].value == 9 and w2['D7'].value == 220 and w2['I22'].value == dopo_atteso, \
    (w2['O20'].value, w2['K30'].value, w2['D7'].value, w2['I22'].value)
PYEOF
grep -q "CHIUSURA TURNO" $D/*.txt && echo "  ok   documento finale in Download" || { echo "  ERRORE documento finale"; ERRORI=$((ERRORI+1)); }
[ ! -s $HOME/turno_corrente.json ] && echo "  ok   turno azzerato" || { echo "  ERRORE turno non azzerato"; ERRORI=$((ERRORI+1)); }

[ -n "${TIENI:-}" ] && cp $D/*.txt /tmp/claude-0/ultimo_doc.txt 2>/dev/null; rm -rf "$HOME"
if [ $ERRORI -eq 0 ]; then echo "✅ Tutto ok"; else echo "❌ $ERRORI errori"; exit 1; fi
