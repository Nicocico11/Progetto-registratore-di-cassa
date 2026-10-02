#!/bin/bash
# Avvia llama-server una sola volta, a inizio turno.
termux-wake-lock

# Percorso esplicito del modello: cambia solo questa riga per provare un altro modello.
MODELLO=~/llama.cpp/models/qwen2.5-3b-instruct-q4_k_m.gguf
SERVER_BIN=~/llama.cpp/build/bin/llama-server

# Se il server risponde già, non ne avviamo un secondo (sprecherebbe RAM e CPU)
if curl -s --max-time 2 http://127.0.0.1:8080/health | grep -q ok; then
  echo "✅ IA già accesa e pronta"
  exit 0
fi

nohup "$SERVER_BIN" -m "$MODELLO" --host 127.0.0.1 --port 8080 --ctx-size 1024 -t 4 > ~/llama_server.log 2>&1 &
echo "🚀 IA in avvio: pronta tra circa 30 secondi"
