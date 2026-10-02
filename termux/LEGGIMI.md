# Script Termux ottimizzati

| File | Dove va sul telefono |
|---|---|
| `avvia_ia.sh` | `~/.termux/tasker/avvia_ia.sh` |
| `avvia_server.sh` | `~/.termux/tasker/avvia_server.sh` |
| `processa_ia.py` | `~/.termux/tasker/processa_ia.py` |
| `info_turno.py` | `~/info_turno.py` |
| `vibra.sh` | `~/.termux/tasker/vibra.sh` |
| `Cassa_Vocale.tsk.xml` | Download → da importare in Tasker |

Installazione/aggiornamento (una riga in Termux):

    curl -L -o ~/.termux/tasker/installa.sh https://raw.githubusercontent.com/Nicocico11/Progetto-registratore-di-cassa/claude/cash-register-ai-latency-n0e165/termux/installa.sh && bash ~/.termux/tasker/installa.sh

Flusso: frase → regole veloci (istantaneo) → solo se non bastano, IA con risposta
limitata a 60 token e forzata in JSON → listino `~/prezzi.json` → `~/transazioni_turno.csv`
→ notifica aggiornata in sottofondo. I tempi dell'IA vengono scritti in `~/debug_tasker.log`.

`info_turno.py totali` stampa il riepilogo per la chiusura (per pagamento e per prodotto);
`chiudi turno` archivia e stampa lo stesso riepilogo.

## Comandi vocali (tutto passa da `avvia_ia.sh`)

| Frase | Cosa fa |
|---|---|
| apri turno / inizio turno | avvia il server IA |
| chiudi turno / fine turno | archivia, mostra il riepilogo, spegne l'IA |
| cancella ultima / annulla ultima | elimina l'ultima vendita |
| cancella penultima | elimina la penultima |
| totali / riepilogo | prospetto per la chiusura |
| ultime / ultimi | notifica con le ultime vendite |
| archivio / storico | turni archiviati |
| qualsiasi altra frase | vendita |

Vibrazioni: 1 corta = ok · 2 corte = salvata ma da controllare · 1 lunga = errore, niente salvato.
