#!/bin/bash
# Avvia llama-server una sola volta, a inizio turno.
termux-wake-lock
CARTELLA=~/.termux/tasker

# Percorso esplicito del modello: cambia solo questa riga per provare un altro modello.
MODELLO=~/llama.cpp/models/qwen2.5-3b-instruct-q4_k_m.gguf
SERVER_BIN=~/llama.cpp/build/bin/llama-server

# Se il server risponde già, non ne avviamo un secondo (sprecherebbe RAM e CPU)
if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q ok; then
  echo "✅ IA già accesa e pronta"
  nohup bash $CARTELLA/stato_ia.sh aggiorna > /dev/null 2>&1 &
  exit 0
fi
# Già partito e ancora in caricamento: aspettiamo quello
if pgrep -x llama-server > /dev/null; then
  echo "🟡 IA già in avvio: pronta tra pochi secondi"
  exit 0
fi

nohup "$SERVER_BIN" -m "$MODELLO" --host 127.0.0.1 --port 8080 --ctx-size 1024 -t 4 > ~/llama_server.log 2>&1 &
echo "🚀 IA in avvio: pronta tra circa 30 secondi"
# La notifica "IA" passa da gialla a verde quando il modello è caricato
nohup bash $CARTELLA/stato_ia.sh attendi > /dev/null 2>&1 &
