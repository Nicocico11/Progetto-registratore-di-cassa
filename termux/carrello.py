import json, os, re, subprocess, sys, time

# Carrello dello scanner (app Binary Eye, "Inoltra le scansioni" a http://127.0.0.1:8765/?c=):
# ogni codice letto arriva qui e si aggiunge al carrello; la tendina mostra prodotti e totale,
# "💳 Paga" chiede il pagamento e salva tutto come una vendita sola (carrello.sh).
#
# Uso: python3 carrello.py server      -> ricevitore (lo avvia notifica.sh a turno aperto)
#      python3 carrello.py riepilogo   -> "2× RED BULL, 1× TWIX · 8,00 €" (niente se vuoto)
#      python3 carrello.py codici      -> i codici, per la vendita
#      python3 carrello.py togli       -> toglie l'ultimo prodotto letto
#      python3 carrello.py svuota

PORTA = 8765
FILE = os.path.expanduser('~/.cassa_carrello')
PREZZI = os.path.expanduser('~/prezzi.json')
NOTIFICA = os.path.expanduser('~/.termux/tasker/notifica.sh')


def leggi():
    try:
        with open(FILE, encoding='utf-8') as f:
            return [r.split('\t') for r in f.read().splitlines() if r.strip()]   # [codice, ora]
    except FileNotFoundError:
        return []


def scrivi(righe):
    if not righe:
        if os.path.exists(FILE):
            os.remove(FILE)
        return
    with open(FILE, 'w', encoding='utf-8') as f:
        f.write("".join("\t".join(r) + "\n" for r in righe))


def listino_per_codice():
    try:
        with open(PREZZI, encoding='utf-8') as f:
            return {str(v['barre']).lower(): (nome, float(v['prezzo'])) for nome, v in json.load(f).items()
                    if isinstance(v, dict) and v.get('barre')}
    except Exception:
        return {}


def riepilogo():
    righe = leggi()
    if not righe:
        return ""
    mappa = listino_per_codice()
    conta, totale, sconosciuti = {}, 0.0, 0
    for codice, _ in righe:
        if codice.lower() in mappa:
            nome, prezzo = mappa[codice.lower()]
            conta[nome] = conta.get(nome, 0) + 1
            totale += prezzo
        else:
            sconosciuti += 1
    parti = [f"{n}× {nome}" for nome, n in conta.items()]
    if sconosciuti:
        parti.append(f"❓ {sconosciuti} {'codice sconosciuto' if sconosciuti == 1 else 'codici sconosciuti'}")
    return ", ".join(parti) + f" · {totale:.2f} €".replace(".", ",")


def aggiorna_notifica():
    subprocess.Popen(['bash', NOTIFICA], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def server():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse, parse_qs, unquote
    ultimo = {'codice': None, 'quando': 0.0}

    class Ricevitore(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlparse(self.path)
            codice = (parse_qs(url.query).get('c') or [unquote(url.path.strip('/'))])[0].strip()
            if re.fullmatch(r'[0-9A-Za-z]{4,20}', codice):
                adesso = time.time()
                # lo stesso codice entro un secondo è una lettura doppia dello stesso pezzo
                if not (codice == ultimo['codice'] and adesso - ultimo['quando'] < 1.0):
                    with open(FILE, 'a', encoding='utf-8') as f:
                        f.write(f"{codice}\t{time.strftime('%H:%M:%S')}\n")
                    aggiorna_notifica()
                ultimo.update(codice=codice, quando=adesso)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        do_POST = do_GET

        def log_message(self, *args):
            pass

    ThreadingHTTPServer(('127.0.0.1', PORTA), Ricevitore).serve_forever()


if __name__ == '__main__':
    comando = sys.argv[1] if len(sys.argv) > 1 else 'riepilogo'
    if comando == 'server':
        server()
    elif comando == 'riepilogo':
        print(riepilogo())
    elif comando == 'codici':
        print(" ".join(c for c, _ in leggi()))
    elif comando == 'togli':
        scrivi(leggi()[:-1])
    elif comando == 'svuota':
        scrivi([])
