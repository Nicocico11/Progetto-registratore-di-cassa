#!/bin/bash
# Prova automatica di un turno completo, da eseguire su computer prima di ogni aggiornamento.
# Simula i comandi di Termux:API e il server IA in una cartella temporanea; non tocca i dati veri.
# Uso: bash termux/prova_turno.sh   (esce con errore se qualcosa non va)

set -u
QUI=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d)
mkdir -p $HOME/.termux/tasker $HOME/bin $HOME/storage/downloads $HOME/llama.cpp/build/bin
cp $QUI/*.sh $QUI/processa_ia.py $QUI/numeri.py $QUI/invia_mail.py $QUI/migra_prezzi.py $QUI/excel_turno.py $QUI/modello_turno.xlsx $HOME/.termux/tasker/
cp $QUI/info_turno.py $HOME/
printf '#!/bin/bash\necho "$*" >> ~/toast.log\n' > $HOME/bin/termux-toast; chmod +x $HOME/bin/termux-toast
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
  *"Ora chiusura"*) echo '{"code": -1, "text": "130000"}' ;;
  *Orario*)   echo '{"code": -1, "text": "140532"}' ;;
  *cassaforte*) echo '{"code": -1, "text": "20"}' ;;
  *"Non capito"*xyz*) echo '{"code": -1, "text": "1 mars"}' ;;               # frase scritta a mano
  *"Quale prodotto"*) echo '{"code": -1, "text": "?", "index": 1}' ;;    # seconda birra della lista
  *"🧾 Cassa"*) echo '{"code": -1, "text": "01 Vendita carburante", "index": 0}' ;;   # menu di Tasker
  *"Importo carburante"*) echo '{"code": -1, "text": "45,50"}' ;;     # widget 01 Vendita carburante
  *"Prodotto Danea"*) echo '{"code": -1, "text": "2 red bull"}' ;;       # widget 02 Vendita Danea
  *"Cosa aggiungi"*) echo '{"code": -1, "text": "Abbuono (mancano: ha pagato meno)", "index": 0}' ;;  # widget 06
  *"Quanti centesimi"*) echo '{"code": -1, "text": "7"}' ;;
  *"Pagamento di"*) echo '{"code": -1, "text": "POS nero", "index": 1}' ;;
  *"quale POS"*) echo '{"code": -1, "text": "POS nero", "index": 1}' ;;   # "carta" generica -> POS nero
  *)          echo '{"code": -2, "text": ""}' ;;
esac
EOF
printf '#!/bin/bash\nsleep 1\n' > $HOME/llama.cpp/build/bin/llama-server
chmod +x $HOME/bin/termux-dialog $HOME/llama.cpp/build/bin/llama-server
export PATH=$HOME/bin:$PATH
echo '{"adblue_sfuso":1.30,"adblue_tanica":26.00,"redbull":3.00,"mars":2.00,"birra_moretti":4.00,"birra_heineken":3.50,"lampadina_h7":10.00,"lampadina_h4":9.00}' > $HOME/prezzi.json
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
controlla "apertura turno con avanzo" "apertura turno notte"                         "Notte"
[ "$(python3 $HOME/info_turno.py stato orario_chiusura)" = "13:00:00" ] && echo "  ok   ora chiusura precedente dal riquadro" || { echo "  ERRORE ora chiusura precedente"; ERRORI=$((ERRORI+1)); }
[ -f $D/*/Documenti/*.txt ] && echo "  ok   documento creato in Download all'apertura" || { echo "  ERRORE documento non creato"; ERRORI=$((ERRORI+1)); }
controlla "contatore adblue"          "contatore adblue 1000 virgola 5"              "1000.5"
controlla "contatore taniche"         "contatore taniche 10"                         "10"
sleep 1; grep -q "mostra --id stato_ia" $HOME/notifiche.log && { echo "  ERRORE notifica IA nella tendina"; ERRORI=$((ERRORI+1)); } || echo "  ok   niente notifica IA nella tendina"
controlla "carta generica -> popup"  "20 euro di gasolio carta"                     "Gasolio 20.00 € - POS nero"
controlla "correggi carburante in cassa" "correggi ultima in cassa"                 "Niente cambiato"
controlla "abbuono"                   "20 e 10 di gasolio, abbuono 10 centesimi"     "-0.10"
controlla "tanica adblue pos cassa"  "tanica di adblue pagato in cassa"             "STAMPARE RICEVUTA"
controlla "resto lasciato"            "19 e 90 di gasolio, ha lasciato 10 centesimi" "Resto lasciato dal cliente 0.1"
controlla "importo come orario"      "20:30 di gasolio sul nero"                    "Gasolio 20.30"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "danea a mano"              "danea caricabatterie 15 euro sul nero"        "CARICABATTERIE 15.00 € - POS nero"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "danea prezzo nuovo"        "danea red bull 3 e 50"                        "Red Bull 3.50"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "solo importo e nero"       "77 nero"                                      "Carburante 77.00 € - POS nero"
controlla "cancella ultimo"           "cancella ultimo"                              "Cancellata"
controlla "70 07 bianco"              "70 07 bianco"                                 "Carburante 70.07 € - POS bianco"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "pasti bianco = pos"        "€20 pasti bianco"                             "20.00 € - POS bianco"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "parola sconosciuta"        "2 xyz"                                        "Mars 2.00"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "birra: lista prodotti"     "una birra"                                    "Birra Moretti 4.00"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "lascia un centesimo"       "83 39 lascia un centesimo"                    "Carburante 83.39 € + Resto lasciato dal cliente 0.01"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "importo e prodotto"        "50 e 2 red bull sul nero"                     "Carburante 50.00 € + 2"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "codice detto male"         "lampadina acca sette"                         "Lampadina H7 10.00"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "codice staccato"           "lampadina h 4"                                "Lampadina H4 9.00"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "nome quasi giusto"         "2 red bul"                                    "capito come red bull"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
bash "$QUI/widget/02 Vendita Danea" > /dev/null 2>&1; grep -q "Red Bull 6.00 € - POS nero" $HOME/toast.log && echo "  ok   widget 02 Vendita Danea" || { echo "  ERRORE widget 12"; ERRORI=$((ERRORI+1)); }
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "quantità e importo"        "2 red bull 7 euro"                            "2 × Red Bull 7.00"
controlla "correggi quantità"         "correggi ultima 3"                            "3 × Red Bull 10.50"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "importo piccolo da solo"   "2"                                            "solo un importo piccolo"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "frase ripetuta (1)"        "1 mars"                                       "Mars 2.00"
controlla "frase ripetuta (2)"        "1 mars"                                       "registrata due volte"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "resto da solo"             "resto lasciato 5 centesimi"                   "Resto lasciato dal cliente 0.05"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
bash "$QUI/widget/06 Abbuono o resto" > /dev/null 2>&1; grep -q "Abbuono -0.07" $HOME/toast.log && echo "  ok   widget 06 abbuono" || { echo "  ERRORE widget 13"; ERRORI=$((ERRORI+1)); }
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "negozio con carta = cassa"  "2 red bull carta"                             "POS cassa"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "negozio sul nero: avviso"  "1 mars sul nero"                              "di solito si pagano IN CASSA"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "2 marzo = 2 mars"          "2 marzo"                                      "2 × Mars"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
bash "$QUI/widget/01 Vendita carburante" > /dev/null; grep -q "Carburante 45.50 € - POS nero" $HOME/toast.log && echo "  ok   widget 01 Vendita carburante" || { echo "  ERRORE widget 01"; cat $HOME/toast.log; ERRORI=$((ERRORI+1)); }
controlla "cancella"                  "cancella ultima"                              "Cancellata"
mkdir -p $HOME/.shortcuts && cp "$QUI"/widget/[0-9]* $HOME/.shortcuts/ && : > $HOME/toast.log
bash $HOME/.termux/tasker/pulsante.sh menu > /dev/null 2>&1; grep -q "Carburante 45.50 € - POS nero" $HOME/toast.log && echo "  ok   menu Cassa da Tasker (senza Termux)" || { echo "  ERRORE menu Tasker"; cat $HOME/toast.log; ERRORI=$((ERRORI+1)); }
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "20 ore = 20 euro"          "20 ore di gasolio"                            "Gasolio 20.00"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "importo molto alto"        "1990 di gasolio"                              "IMPORTO MOLTO ALTO"
grep -q "mostra --id avviso_cassa.*--sound.*IMPORTO MOLTO ALTO" $HOME/notifiche.log && echo "  ok   notifica con suono per l'avviso" || { echo "  ERRORE notifica avviso"; ERRORI=$((ERRORI+1)); }
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "camion 950: normale"       "950 di gasolio sul nero"                      "Gasolio 950.00 € - POS nero"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "versamento a parole"       "versamento cinquanta"                         "50.00"
controlla "numeri in lettere"         "trentacinque di verde sul bianco"             "Benzina 35.00 € - POS bianco"
controlla "centesimi"                 "venti e cinquanta di gasolio"                 "Gasolio 20.50"
controlla "vendita mista"             "50 gasolio, 20 litri di adblue e 2 red bull con carta" "3 voci"
controlla "ricevuta market pos cassa" "2 mars e un red bull pagato in cassa"         "STAMPARE RICEVUTA (7.00"
controlla "pos nero niente ricevuta"  "1 mars sul nero"                               "POS nero"
controlla "cartissima"                "40 gasolio cartissima"                        "Petrolifere"
controlla "fax"                       "5 fax"                                        "5 fogli"
controlla "frase senza importo"       "ciao"                                         "Niente salvato"
controlla "totali in finestra"        "totali"                                       "Totali sullo schermo"
python3 $HOME/info_turno.py totali breve | grep "Attesi in cassa" > /dev/null && echo "  ok   testo dei totali" || { echo "  ERRORE testo totali"; ERRORI=$((ERRORI+1)); }
controlla "market"                    "market"                                       "Red Bull"
controlla "erogazioni adblue"         "erogazioni"                                   "litri erogati"
controlla "correggi ultima pagamento"  "correggi ultima sul bianco"                   "POS bianco"
controlla "correggi penultima importo" "correggi penultima 7 fax"                    "ora:"
controlla "correzione vendita mista"  "50 gasolio e 1 mars" "2 voci"
controlla "mista: solo pagamento"     "correggi ultima 30 euro"                      "vendita mista"
controlla "avanzo come orario"       "avanzo 159:50"                                "159.50"
controlla "avanzo a voce"             "avanzo 160"                                   "160.00"
controlla "cancella ultima"           "cancella ultima"                              "Cancellata"
controlla "credito cliente"           "credito cliente rossi mario 50 euro"          "Rossi Mario 50.00"
controlla "credito riscosso pos nero" "credito riscosso bianchi 30 sul nero"         "Bianchi 30.00"
controlla "riscosso in cassa: ricevuta" "credito riscosso neri 12 in cassa"          "STAMPARE RICEVUTA (12.00"
controlla "cancella riscosso cassa"   "cancella ultima"                              "Cancellata"
controlla "carburante in cassa: no"   "20 gasolio e 1 mars in cassa"                 "Niente salvato"
controlla "20:10 e a buono"           "20:10 di gasolio a buono 10 centesimi"        "Gasolio 20.10 € + Abbuono -0.10"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "20 10 di gasolio"          "20 10 di gasolio abbuono 10 centesimi"        "Gasolio 20.10 € + Abbuono"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "resto senza virgola"       "19.90 di gasolio ha lasciato 10 centesimi"    "Gasolio 19.90 € + Resto lasciato"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "tanica di blu"             "tanica di blu"                                "AdBlue"
controlla "cancella"                  "cancella ultima"                              "Cancellata"
controlla "credito riscosso contanti" "credito riscosso verdi 20"                    "(Contanti): Verdi 20.00"
controlla "credito senza nome"        "credito cliente 15"                           "SENZA NOME"
controlla "cancella credito"          "cancella ultima"                              "Cancellata"
controlla "anticipo cartissima"       "anticipo cartissima 100"                      "100.00 € tolti dai contanti"
controlla "carta di credito = vendita" "10 gasolio carta di credito"                 "Gasolio 10.00 € - POS nero"
grep -q "Gasolio\|gasolio" $D/*/Documenti/*_dati.csv && echo "  ok   copia dati aggiornata in Download" || { echo "  ERRORE copia dati"; ERRORI=$((ERRORI+1)); }
rm $HOME/transazioni_turno.csv
controlla "ripristino da Download"    "ripristina turno"                             "Ripristinate"
echo '{"mittente":"prova@gmail.com","password":"x","destinatario":"capo@example.com"}' > $HOME/.cassa_email.json
export INVIA_MAIL_FINTO=$HOME/mail_finte; mkdir -p $INVIA_MAIL_FINTO
controlla "chiusura turno"            "chiusura turno"                               "Terminale pompe: 14:05:32"
[ "$(cat $HOME/ultimo_conteggio.txt 2>/dev/null)" = "90.50" ] && echo "  ok   avanzo calcolato proposto al turno dopo" || { echo "  ERRORE avanzo calcolato"; ERRORI=$((ERRORI+1)); }
sleep 1; tail -4 $HOME/notifiche.log | grep -q "togli stato_ia" && tail -4 $HOME/notifiche.log | grep -q "togli distributore_turno" && echo "  ok   notifiche tolte alla chiusura" || { echo "  ERRORE notifiche non tolte"; ERRORI=$((ERRORI+1)); }
grep -q "Contanti attesi" $D/*/Documenti/*.txt && echo "  ok   quadratura nel documento" || { echo "  ERRORE quadratura"; ERRORI=$((ERRORI+1)); }
PYTHONPATH=$HOME/.termux/tasker python3 - "$D" <<'PYEOF' && echo "  ok   file Excel compilati" || { echo "  ERRORE file Excel"; ERRORI=$((ERRORI+1)); }
import glob, sys, openpyxl
d = sys.argv[1]
files = sorted(glob.glob(d + "/*/Excel/*.xlsx"))
assert len(files) == 2, files
oggi = [f for f in files if openpyxl.load_workbook(f).active['D2'].value is None and openpyxl.load_workbook(f).active['E2'].value]
ws = openpyxl.load_workbook(oggi[0]).active
assert ws['O20'].value == 1000.5 and ws['O19'].value == 1020.5, (ws['O20'].value, ws['O19'].value)   # +20 litri
assert ws['K30'].value == 10 and ws['K31'].value == 9                     # 1 tanica venduta
assert ws['I17'].value == 20 and ws['A21'].value == 1.5                   # litri sfuso, fax
assert ws['I5'].value is None                                             # abbuono: niente SCONTI
assert ws['A39'].value.startswith('ABBUONI: - 0,10 € (1 volta) | RESTI LASCIATI DAI CLIENTI: + 0,10'), ws['A39'].value   # nota resti lasciati
scontrini = [ws[c].value for c in ('S27', 'T27', 'U27', 'V27')]
assert scontrini[:2] == [26, 7] and scontrini[2] is None, scontrini        # un scontrino per vendita in cassa
assert ws['D9'].value == 107 and ws['D12'].value == 144 and ws['D14'].value == 36.5, \
    (ws['D9'].value, ws['D12'].value, ws['D14'].value)                    # petrolifere, POS nero, POS bianco
assert ws['D7'].value == 160 and str(ws['I24'].value) == '13:00:00'      # ora chiusura precedente scritta all'apertura
assert ws['I28'].value == 20 and ws['D34'].value == 70.5, ws['D34'].value   # cassaforte, contanti attesi nel cassetto
assert ws['D2'].formula if hasattr(ws['D2'], 'formula') else True
assert ws.protection.sheet and ws['D4'].value.startswith('=')            # protezione e formule intatte
assert (ws['I8'].value, ws['L8'].value, ws['I9'].value) == ('Rossi Mario', 50, None)          # crediti clienti
assert (ws['M8'].value, ws['O8'].value, ws['M9'].value, ws['O9'].value) == ('Bianchi', 30, 'Verdi', 20)  # riscossi
import excel_turno                                                         # caselle finite: si riparte dalla prima
prova, avv = {}, []
excel_turno.riempi(prova, ['A', 'B', 'C'], [1, 2, 3, 4, 5], avv, "PROVA")
assert prova == {'A': 5, 'B': 7, 'C': 3} and avv, prova
prova = {}
excel_turno.riempi(prova, [('A', 'B')], [10, 5], [], "CREDITI", nomi=['Rossi', 'Verdi'])
assert prova == {'A': 'Rossi + Verdi', 'B': 15}, prova
import zipfile
assert 'fullCalcOnLoad="1"' in zipfile.ZipFile(oggi[0]).read('xl/workbook.xml').decode()   # Excel ricalcola all'apertura
dopo = [f for f in files if f not in oggi][0]
w2 = openpyxl.load_workbook(dopo).active
dopo_atteso = {'MATTINA': 'POMERIGGIO', 'POMERIGGIO': 'NOTTE', 'NOTTE': 'MATTINA'}[ws['I22'].value]
assert str(w2['I24'].value) == '14:05:32' and w2['I28'].value == 20     # orario terminale di oggi -> turno dopo
import json, os
stato = json.load(open(os.path.expanduser('~/stato_cassa.json')))
assert stato['orario_chiusura'] == '14:05:32' and stato['contatore'] == 1020.5 and stato['taniche'] == 9, stato
assert w2['O20'].value == 1020.5 and w2['K30'].value == 9 and w2['D7'].value == 90.5 and w2['I22'].value == dopo_atteso, \
    (w2['O20'].value, w2['K30'].value, w2['D7'].value, w2['I22'].value)
PYEOF
[ "$(ls $D | wc -l)" = 1 ] && [ "$(ls $D/*/Documenti | wc -l)" = 2 ] && [ "$(ls $D/*/Excel | wc -l)" = 2 ] && echo "  ok   cartella del turno: Documenti (2) ed Excel (2)" || { echo "  ERRORE cartelle"; find $D; ERRORI=$((ERRORI+1)); }
python3 - $HOME/mail_finte <<'PYEOF' && echo "  ok   mail della chiusura (2 Excel + riepilogo)" || { echo "  ERRORE mail"; ERRORI=$((ERRORI+1)); }
import email, glob, sys
f = glob.glob(sys.argv[1] + '/*.eml')
assert len(f) == 1, f
from email import policy
m = email.message_from_bytes(open(f[0], 'rb').read(), policy=policy.default)
allegati = sorted(p.get_filename() for p in m.iter_attachments())
assert m['To'] == 'capo@example.com' and m['Subject'].startswith('Chiusura turno'), (m['To'], m['Subject'])
assert len([a for a in allegati if a.endswith('.xlsx')]) == 2 and any(a.endswith('.txt') for a in allegati), allegati
assert 'QUADRATURA' in m.get_body().get_content()
PYEOF
grep -q "CHIUSURA TURNO" $D/*/Documenti/*.txt && echo "  ok   documento finale in Download" || { echo "  ERRORE documento finale"; ERRORI=$((ERRORI+1)); }
[ ! -s $HOME/turno_corrente.json ] && echo "  ok   turno azzerato" || { echo "  ERRORE turno non azzerato"; ERRORI=$((ERRORI+1)); }

# Turno di prova: file con TEST nel nome, stato vero (contatore, taniche, orario) non toccato
cp $HOME/stato_cassa.json $HOME/stato_prima.json
controlla "apertura turno di prova"   "apertura turno prova notte"                   "TURNO DI PROVA"
controlla "contatore nel turno prova" "contatore taniche 99"                         "99"
controlla "vendita nel turno prova"   "20 gasolio"                                   "Gasolio 20.00"
controlla "chiusura turno di prova"   "chiusura turno"                               "Mail inviata"
python3 -c "
import email, glob, sys; from email import policy
m = [email.message_from_bytes(open(f, 'rb').read(), policy=policy.default) for f in glob.glob(sys.argv[1] + '/*.eml')]
prova = [x for x in m if 'TEST' in x['Subject']]
assert prova and prova[0]['To'] == 'prova@gmail.com', [(x['Subject'], x['To']) for x in m]
" $HOME/mail_finte && echo "  ok   mail del turno di prova solo al mittente" || { echo "  ERRORE mail di prova"; ERRORI=$((ERRORI+1)); }
cmp -s $HOME/stato_cassa.json $HOME/stato_prima.json && echo "  ok   turno di prova: stato vero non toccato" || { echo "  ERRORE stato toccato dalla prova"; ERRORI=$((ERRORI+1)); }
ls $D | grep -q "_Notte_TEST$" && ls $D/*_TEST/Excel | grep -q "notte_TEST.xlsx" && echo "  ok   cartella e file con TEST nel nome" || { echo "  ERRORE nomi TEST"; ls -R $D; ERRORI=$((ERRORI+1)); }

[ -n "${TIENI:-}" ] && cp $D/*/Documenti/*.txt /tmp/claude-0/ultimo_doc.txt 2>/dev/null; rm -rf "$HOME"
if [ $ERRORI -eq 0 ]; then echo "✅ Tutto ok"; else echo "❌ $ERRORI errori"; exit 1; fi
