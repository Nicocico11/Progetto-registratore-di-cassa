# Script Termux ottimizzati

| File | Dove va sul telefono |
|---|---|
| `avvia_ia.sh` | `~/.termux/tasker/avvia_ia.sh` |
| `avvia_server.sh` | `~/.termux/tasker/avvia_server.sh` |
| `processa_ia.py` | `~/.termux/tasker/processa_ia.py` |
| `info_turno.py` | `~/info_turno.py` |

Installazione/aggiornamento (una riga in Termux):

    curl -L -o ~/.termux/tasker/installa.sh https://raw.githubusercontent.com/Nicocico11/Progetto-registratore-di-cassa/claude/cash-register-ai-latency-n0e165/termux/installa.sh && bash ~/.termux/tasker/installa.sh

Flusso: frase → regole veloci (istantaneo) → solo se non bastano, IA con risposta
limitata a 60 token e forzata in JSON → listino `~/prezzi.json` → `~/transazioni_turno.csv`
→ notifica aggiornata in sottofondo. I tempi dell'IA vengono scritti in `~/debug_tasker.log`.

`info_turno.py totali` stampa il riepilogo per la chiusura (per pagamento e per prodotto);
`chiudi turno` archivia e stampa lo stesso riepilogo.
