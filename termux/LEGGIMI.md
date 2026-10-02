# Script Termux ottimizzati

| File | Dove va sul telefono |
|---|---|
| `avvia_ia.sh` | `~/.termux/tasker/avvia_ia.sh` |
| `avvia_server.sh` | `~/.termux/tasker/avvia_server.sh` |
| `processa_ia.py` | `~/.termux/tasker/processa_ia.py` |
| `info_turno.py` | `~/info_turno.py` |
| `vibra.sh` | `~/.termux/tasker/vibra.sh` |
| `migra_prezzi.py` | `~/.termux/tasker/` (converte `~/prezzi.json` al nuovo formato) |
| `Cassa_Vocale.tsk.xml` | Download → da importare in Tasker (Task) |
| `Continuazione.prf.xml` | Download → da importare in Tasker (Profilo AutoVoice + Task) |

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
| apri turno / apertura turno / inizio turno | accende l'IA |
| apertura turno | registra orario e tipo di turno (Mattina 6-14, Pomeriggio 14-22, Notte 22-6) |
| chiudi turno / chiusura turno / fine turno [HH MM SS] | popup orario terminale pompe (con secondi, es. 140532), documento in Download/Chiusure_Turno, archivia, spegne l'IA |
| market / danea / negozio | prodotti market venduti, raggruppati con quantità |
| erogazioni / quanto adblue | elenco erogazioni AdBlue, litri sfuso e taniche |
| cancella ultima / annulla ultima | elimina l'ultima vendita |
| cancella penultima | elimina la penultima |
| totali / riepilogo | prospetto per la chiusura |
| ultime / ultimi | notifica con le ultime vendite |
| archivio / storico | turni archiviati |
| qualsiasi altra frase | vendita |

Vibrazioni: 1 corta = ok · 2 corte = salvata ma da controllare · 1 lunga = errore, niente salvato.

Sicurezza: senza un numero nella frase non viene salvato nulla; se l'IA propone un importo che non è tra i numeri detti, la vendita viene scartata.

## Listino `~/prezzi.json`

    "Red Bull":      {"prezzo": 3.0,  "alias": ["red bull", "redbull"], "reparto": "Market", "unita": "pz"},
    "AdBlue sfuso":  {"prezzo": 1.3,  "alias": ["adblue", "sfuso"],    "reparto": "AdBlue", "unita": "l"}

"2 red bull" = 2 × prezzo; "adblue 20 litri" = 20 × 1,30; "adblue 13 euro" = importo 13 (10 litri).

## Vendite miste e ricevute

- Una frase può contenere più voci con un solo pagamento: "50 di gasolio, 20 litri di adblue e 2 red bull con carta"
  → 3 righe con lo stesso numero di transazione; "cancella ultima" le toglie tutte insieme.
- Pagamenti: Contanti, Carta, Carta carburante (anche "cartissima"), POS, Bancomat.
- Market o tanica AdBlue pagati non in contanti → notifica "🧾 STAMPA RICEVUTA".
