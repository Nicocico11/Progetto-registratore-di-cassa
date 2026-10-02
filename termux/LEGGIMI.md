# Script Termux ottimizzati

| File | Dove va sul telefono |
|---|---|
| `avvia_ia.sh` | `~/.termux/tasker/avvia_ia.sh` |
| `avvia_server.sh` | `~/.termux/tasker/avvia_server.sh` |
| `processa_ia.py` | `~/.termux/tasker/processa_ia.py` |

Installazione di ogni file: aprilo su GitHub → **Raw** → seleziona tutto e copia →
in Termux esegui `termux-clipboard-get > ~/.termux/tasker/NOMEFILE`.

Poi una volta sola: `chmod +x ~/.termux/tasker/*.sh`

Flusso: frase → regole veloci (istantaneo) → solo se non bastano, IA con risposta
limitata a 60 token e forzata in JSON → listino `~/prezzi.json` → `~/transazioni_turno.csv`.
I tempi dell'IA vengono scritti in `~/debug_tasker.log`.
