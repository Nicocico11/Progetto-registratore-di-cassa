#!/bin/bash
# Crea installa.sh: un unico script che scrive sul telefono tutti i file della cassa vocale.
# Uso (su computer, dalla cartella del progetto): bash termux/genera_installa.sh
cd "$(dirname "$0")"
# Un file senza "a capo" finale farebbe "}FINE_FILE": il resto dell'installazione finirebbe dentro il file
incolla() { cat "$1"; [ -n "$(tail -c1 "$1")" ] && echo; true; }
{
echo '#!/bin/bash'
echo '# Installa / aggiorna la cassa vocale. Generato da genera_installa.sh: non modificarlo a mano.'
echo '# Copia di sicurezza dei file attuali (solo la prima volta: le copie .vecchio non vengono sovrascritte)'
echo 'for f in ~/.termux/tasker/avvia_ia.sh ~/.termux/tasker/avvia_server.sh ~/.termux/tasker/processa_ia.py ~/.termux/tasker/notifica.sh ~/info_turno.py; do [ -f "$f" ] && [ ! -f "$f.vecchio" ] && cp "$f" "$f.vecchio"; done'
for f in avvia_ia.sh widget_comune.sh pulsante.sh da_segnare.sh carrello.sh carrello.py avvia_server.sh stato_ia.sh notifica.sh processa_ia.py numeri.py invia_mail.py vibra.sh migra_prezzi.py danea_listino.py excel_turno.py; do
  echo "cat > ~/.termux/tasker/$f <<'FINE_FILE'"; incolla $f; echo "FINE_FILE"
done
echo "cat > ~/info_turno.py <<'FINE_FILE'"; incolla info_turno.py; echo "FINE_FILE"
echo '# Modello Excel del turno (file binario, codificato in base64)'
echo "base64 -d > ~/.termux/tasker/modello_turno.xlsx <<'FINE_FILE'"; base64 modello_turno.xlsx; echo "FINE_FILE"

echo '# Listino Danea: si installa solo se è cambiato (il listino attuale resta in prezzi.json.vecchio)'
echo "cat > ~/.termux/tasker/prezzi_danea.json <<'FINE_FILE'"; incolla prezzi_danea.json; echo "FINE_FILE"
echo 'if ! cmp -s ~/.termux/tasker/prezzi_danea.json ~/.termux/tasker/.prezzi_danea_installato; then'
echo '  [ -f ~/prezzi.json ] && cp ~/prezzi.json ~/prezzi.json.vecchio'
echo '  cp ~/.termux/tasker/prezzi_danea.json ~/prezzi.json'
echo '  cp ~/.termux/tasker/prezzi_danea.json ~/.termux/tasker/.prezzi_danea_installato'
echo '  echo "🛒 Listino Danea installato: $(grep -c "\"prezzo\"" ~/prezzi.json) prodotti"'
echo 'fi'
echo 'python3 ~/.termux/tasker/migra_prezzi.py'

echo '# Pulsanti per Termux:Widget (cartella ~/.shortcuts)'
echo 'mkdir -p ~/.shortcuts && chmod 700 ~/.shortcuts'
echo '# Pulsanti con i numeri vecchi (cambiano quando si riordinano): si tolgono e si riscrivono'
echo 'rm -f ~/.shortcuts/[0-9]\ * ~/.shortcuts/[0-9][0-9]\ * ~/.shortcuts/tasks/[0-9][0-9]\ *'
for f in widget/[0-9]*; do n=$(basename "$f"); echo "cat > ~/.shortcuts/\"$n\" <<'FINE_FILE'"; incolla "$f"; echo "FINE_FILE"; done
echo 'rmdir ~/.shortcuts/tasks 2>/dev/null; chmod +x ~/.shortcuts/*'

echo '# File di Tasker da importare: li mettiamo nella cartella Download'
echo 'if [ -d ~/storage/downloads ]; then'
echo "cat > ~/storage/downloads/Cassa_Vocale.tsk.xml <<'FINE_FILE'"; incolla Cassa_Vocale.tsk.xml; echo "FINE_FILE"
echo "cat > ~/storage/downloads/Continuazione.prf.xml <<'FINE_FILE'"; incolla Continuazione.prf.xml; echo "FINE_FILE"
echo "cat > ~/storage/downloads/Flash_Cassa.prf.xml <<'FINE_FILE'"; incolla Flash_Cassa.prf.xml; echo "FINE_FILE"
python3 genera_tasker_pulsanti.py > /dev/null
echo "cat > ~/storage/downloads/Cassa_Pulsanti.prj.xml <<'FINE_FILE'"; incolla Cassa_Pulsanti.prj.xml; echo "FINE_FILE"
echo '# Manuale d'"'"'uso, sempre aggiornato'
echo "cat > ~/storage/downloads/MANUALE_Cassa_Vocale.txt <<'FINE_FILE'"; incolla MANUALE.txt; echo "FINE_FILE"
echo 'echo "📖 Manuale: Download/MANUALE_Cassa_Vocale.txt"'
echo 'fi'
echo 'chmod +x ~/.termux/tasker/*.sh'
echo '# Libreria per leggere e scrivere i file Excel (serve internet solo la prima volta)'
echo 'python3 -c "import openpyxl" 2>/dev/null || pip install -q openpyxl 2>/dev/null || echo "⚠️ openpyxl non installato: riprova con internet"'
echo '# Copia del turno in Download e notifiche: solo se il turno è aperto'
echo 'python3 ~/info_turno.py salva > /dev/null 2>&1'
echo 'bash ~/.termux/tasker/notifica.sh'
echo 'bash ~/.termux/tasker/stato_ia.sh aggiorna'
echo 'if python3 ~/info_turno.py aperto; then echo "📅 Turno aperto: notifiche attive"; else echo "💤 Nessun turno aperto: notifiche tolte e IA spenta"; fi'
echo "echo \"✅ INSTALLAZIONE COMPLETATA - versione del $(TZ=Europe/Rome date '+%d/%m %H:%M')\""
} > installa.sh
# Controllo: ogni file incollato deve chiudersi con una riga FINE_FILE
if [ "$(grep -c "<<'FINE_FILE'" installa.sh)" != "$(grep -cx 'FINE_FILE' installa.sh)" ]; then
  echo "❌ installa.sh rotto: un file incollato non si chiude con FINE_FILE"; exit 1
fi
echo "installa.sh creato ($(wc -c < installa.sh) byte)"
