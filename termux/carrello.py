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


IMPARATI = os.path.expanduser('~/.cassa_codici_imparati.json')   # codici insegnati a mano: restano anche
                                                                  # quando si aggiorna il listino Danea


def leggi_listino():
    try:
        with open(PREZZI, encoding='utf-8') as f:
            return {n: v for n, v in json.load(f).items() if isinstance(v, dict)}
    except Exception:
        return {}


def leggi_imparati():
    try:
        with open(IMPARATI, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def listino_per_codice():
    """codice -> (nome, prezzo): dal listino Danea e dai codici insegnati a mano."""
    listino = leggi_listino()
    mappa = {str(v['barre']).lower(): (nome, float(v['prezzo'])) for nome, v in listino.items() if v.get('barre')}
    for codice, d in leggi_imparati().items():
        if d.get('nome') in listino:
            mappa[codice.lower()] = (d['nome'], float(listino[d['nome']]['prezzo']))
        elif d.get('prezzo') is not None:
            mappa[codice.lower()] = (d['nome'], float(d['prezzo']))
    return mappa


def cerca(testo):
    """Prodotti del listino che hanno nel nome tutte le parole scritte ("red bull" -> RED BULL)."""
    parole = [w for w in re.findall(r'[a-z0-9]+', testo.lower()) if len(w) >= 2]
    if not parole:
        return []
    trovati = []
    for nome, v in leggi_listino().items():
        nomi = [nome.lower()] + [a.lower() for a in v.get('alias', [])]
        if any(all(w in n for w in parole) for n in nomi):
            trovati.append(nome)
    return sorted(trovati, key=len)


def dialogo(*argomenti):
    """termux-dialog: (testo, indice) se confermato, None se annullato."""
    try:
        r = subprocess.run(['termux-dialog', *argomenti], capture_output=True, text=True, timeout=120)
        d = json.loads(r.stdout or '{}')
    except Exception:
        return None
    return (d.get('text', ''), d.get('index')) if d.get('code') == -1 else None


def impara_sconosciuti():
    """Per ogni codice sconosciuto chiede che prodotto è e lo ricorda. Esce con 1 se annullato."""
    mappa = listino_per_codice()
    sconosciuti = list(dict.fromkeys(c for c, _ in leggi() if c.lower() not in mappa))
    imparati = leggi_imparati()
    for codice in sconosciuti:
        r = dialogo('text', '-t', f'❓ Codice {codice}: che prodotto è?', '-i', 'red bull · caricabatterie 15')
        if not r or not r[0].strip():
            sys.exit(1)
        testo = r[0].strip()
        trovati = cerca(testo) or cerca(re.sub(r'\s*\d+(?:[.,]\d+)?\s*(?:euro|€)?\s*$', '', testo))
        if len(trovati) > 1:
            voci = [f"{n} {leggi_listino()[n]['prezzo']:.2f}€".replace(',', ' ') for n in trovati[:20]]
            r = dialogo('radio', '-t', '🛒 Quale prodotto?', '-v', ','.join(voci))
            if not r:
                sys.exit(1)
            trovati = [trovati[r[1]]] if isinstance(r[1], int) and 0 <= r[1] < len(voci) else []
        if trovati:
            imparati[codice] = {'nome': trovati[0]}
        else:
            # Prodotto nuovo, non nel listino: nome e prezzo (es. "caricabatterie 15")
            m = re.search(r'(\d+(?:[.,]\d+)?)\s*(?:euro|€)?\s*$', testo)
            nome = (testo[:m.start()] if m else testo).strip().upper()
            prezzo = float(m.group(1).replace(',', '.')) if m else None
            if prezzo is None:
                r = dialogo('text', '-n', '-t', f'💶 Prezzo di {nome} (€)', '-i', '2,50')
                try:
                    prezzo = float(r[0].replace(',', '.'))
                except Exception:
                    sys.exit(1)
            imparati[codice] = {'nome': nome, 'prezzo': prezzo}
        with open(IMPARATI, 'w', encoding='utf-8') as f:
            json.dump(imparati, f, ensure_ascii=False, indent=1)


def riepilogo():
    righe = leggi()
    if not righe:
        return ""
    mappa = listino_per_codice()
    conta, totale, sconosciuti = {}, 0.0, []
    for codice, _ in righe:
        if codice.lower() in mappa:
            nome, prezzo = mappa[codice.lower()]
            conta[nome] = conta.get(nome, 0) + 1
            totale += prezzo
        else:
            sconosciuti.append(codice)
    parti = [f"{n}× {nome}" for nome, n in conta.items()]
    if sconosciuti:
        parti.append(f"❓ {len(sconosciuti)} {'codice sconosciuto' if len(sconosciuti) == 1 else 'codici sconosciuti'} "
                     f"({', '.join(dict.fromkeys(sconosciuti))})")
    return ", ".join(parti) + f" · {totale:.2f} €".replace(".", ",")


def totale():
    mappa = listino_per_codice()
    return round(sum(mappa[c.lower()][1] for c, _ in leggi() if c.lower() in mappa), 2)


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

    try:
        server_http = ThreadingHTTPServer(('127.0.0.1', PORTA), Ricevitore)
    except OSError:
        return            # un altro ricevitore è già acceso: resta quello
    with open(os.path.expanduser('~/.cassa_carrello.pid'), 'w') as f:
        f.write(str(os.getpid()))      # solo il ricevitore acceso davvero scrive il suo numero
    server_http.serve_forever()


if __name__ == '__main__':
    comando = sys.argv[1] if len(sys.argv) > 1 else 'riepilogo'
    if comando == 'server':
        server()
    elif comando == 'riepilogo':
        print(riepilogo())
    elif comando == 'totale':
        print(f"{totale():.2f}")
    elif comando == 'codici':
        print(" ".join(c for c, _ in leggi()))
    elif comando == 'impara':
        impara_sconosciuti()
    elif comando == 'venduti':
        # Toglie solo i prodotti venduti (i primi N): uno letto mentre si pagava resta nel carrello
        scrivi(leggi()[int(sys.argv[2]):])
    elif comando == 'togli':
        scrivi(leggi()[:-1])
    elif comando == 'svuota':
        scrivi([])
