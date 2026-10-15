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


OLIO = {'olio', 'oli', 'motore', 'lubrificante', 'lubrificanti'}


def cerca(testo):
    """Prodotti del listino con nel nome le parole scritte ("red bull" -> RED BULL, "olio 5w40" -> oli 5W-40).
    Parole intere (o inizio parola, se lunghe); "olio"/"motore" = solo oli motore.
    Prima quelli con tutte le parole; se nessuno, quelli con più parole in comune."""
    parole_di = lambda t: re.findall(r'[a-z0-9]+', t.lower().replace('-', ''))
    parole = [w for w in parole_di(testo) if len(w) >= 2]
    listino = leggi_listino()
    solo_oli = bool(OLIO & set(parole))
    parole = [w for w in parole if w not in OLIO]
    candidati = {n: v for n, v in listino.items() if not solo_oli or v.get('categoria') == 'LUBRIFICANTI'}
    if not parole:
        return sorted(candidati, key=len) if solo_oli else []
    uguale = lambda w, p: p == w or (len(w) >= 4 and p.startswith(w)) or (len(w) >= 5 and w.startswith(p[:-1]) and len(p) >= 5)
    punti = {}
    for nome, v in candidati.items():
        migliore = max(sum(any(uguale(w, p) for p in parole_di(n)) for w in parole)
                       for n in [nome] + v.get('alias', []))
        if migliore:
            punti[nome] = migliore
    if not punti:
        return []
    massimo = max(punti.values())
    if massimo < len(parole) and massimo < 2 and len(parole) > 1:
        return []           # una parola sola in comune su tante: meglio non indovinare
    return sorted((n for n, p in punti.items() if p == massimo), key=len)


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


def aggiungi_prodotto():
    """➕ Aggiungi → 🛒 Prodotto: nome scritto ("tanica adblue", "2 olio 5w40"), scelta se più prodotti."""
    r = dialogo('text', '-t', '🛒 Prodotto da aggiungere', '-i', 'tanica adblue · 2 olio 5w40')
    if not r or not r[0].strip():
        sys.exit(1)
    m = re.match(r'\s*(\d+)\s*(?:x\s*)?(.*)', r[0])
    quanti, nome_scritto = (int(m.group(1)), m.group(2)) if m and m.group(2) else (1, r[0])
    trovati = cerca(nome_scritto)
    if not trovati:
        dialogo('confirm', '-t', '❓ Prodotto non trovato', '-i', f'"{nome_scritto}" non è nel listino')
        sys.exit(1)
    if len(trovati) > 1:
        listino = leggi_listino()
        voci = [f"{n} {listino[n]['prezzo']:.2f}€".replace(',', ' ') for n in trovati[:20]]
        r = dialogo('radio', '-t', '🛒 Quale prodotto?', '-v', ','.join(voci))
        if not r or not isinstance(r[1], int) or not 0 <= r[1] < len(voci):
            sys.exit(1)
        trovati = [trovati[r[1]]]
    with open(FILE, 'a', encoding='utf-8') as f:
        f.write(f"+prodotto:{trovati[0]}\t{time.strftime('%H:%M:%S')}\n" * quanti)


def riepilogo():
    righe = leggi()
    if not righe:
        return ""
    mappa = listino_per_codice()
    conta, totale, sconosciuti = {}, 0.0, []
    for codice, _ in righe:
        if codice.startswith('+'):                 # aggiunta a mano (carburante, fax, AdBlue, prodotto)
            nome, importo = voce_a_mano(codice)
            conta[nome] = conta.get(nome, 0) + 1
            totale += importo
        elif codice.lower() in mappa:
            nome, prezzo = mappa[codice.lower()]
            conta[nome] = conta.get(nome, 0) + 1
            totale += prezzo
        else:
            sconosciuti.append(codice)
    parti = [nome if nome.startswith(('⛽', '📠', '🧪')) else f"{n}× {nome}" for nome, n in conta.items()]
    if sconosciuti:
        parti.append(f"❓ {len(sconosciuti)} {'codice sconosciuto' if len(sconosciuti) == 1 else 'codici sconosciuti'} "
                     f"({', '.join(dict.fromkeys(sconosciuti))})")
    return ", ".join(parti) + f" · {totale:.2f} €".replace(".", ",")


def totale():
    mappa = listino_per_codice()
    return round(sum(voce_a_mano(c)[1] if c.startswith('+') else mappa[c.lower()][1]
                     for c, _ in leggi() if c.startswith('+') or c.lower() in mappa), 2)


# Voci aggiunte a mano al carrello ("➕ Aggiungi"): "+carburante:50.00", "+fax:1.50", "+adblue:20"
def voce_a_mano(codice):
    """(descrizione per la tendina, importo)."""
    tipo, valore = codice[1:].split(':', 1)
    if tipo == 'prodotto':
        prezzo = float(leggi_listino().get(valore, {}).get('prezzo', 0))
        return valore, prezzo
    valore = float(valore)
    if tipo == 'fogli':
        fax = next((v for v in leggi_listino().values() if v.get('reparto') == 'Fax'), {})
        importo = round(valore * float(fax.get('prezzo', 0.30)), 2)
        return f"📠 Fax {valore:g} {'copia' if valore == 1 else 'copie'} {importo:.2f}".replace('.', ',') + " €", importo
    if tipo == 'adblue':
        prezzo = float(leggi_listino().get('AdBlue sfuso', {}).get('prezzo', 1.30))
        return f"🧪 AdBlue {valore:g} l {valore * prezzo:.2f}".replace('.', ',') + " €", round(valore * prezzo, 2)
    nome = {'carburante': '⛽ Carburante', 'fax': '📠 Fax'}[tipo]
    return f"{nome} {valore:.2f}".replace('.', ',') + " €", valore


def frase_a_mano(codice):
    """Il pezzo di frase per la vendita: "50.00 euro di carburante", "fax 1.50 euro", "adblue 20 litri"."""
    tipo, valore = codice[1:].split(':', 1)
    if tipo == 'prodotto':
        return "§" + valore.lower().replace(' ', '_') + "§"   # prodotto esatto del listino (niente lista)
    return {'carburante': f"{valore} euro di carburante", 'fax': f"fax {valore} euro",
            'fogli': f"{float(valore):g} fax", 'adblue': f"adblue {valore} litri"}[tipo]


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
        # codici a barre, poi le voci aggiunte a mano ("... e 50.00 euro di carburante e fax 1.50 euro")
        righe = leggi()
        prodotti = [c if not c.startswith('+') else frase_a_mano(c) for c, _ in righe
                    if not c.startswith('+') or c.startswith('+prodotto:')]
        altre = [f"e {frase_a_mano(c)}" for c, _ in righe if c.startswith('+') and not c.startswith('+prodotto:')]
        print(" ".join(prodotti + altre).removeprefix('e ').strip())
    elif comando == 'quanti':
        print(len(leggi()))
    elif comando == 'aggiungi':
        # carrello.py aggiungi carburante 50  -> riga "+carburante:50.00"
        tipo = sys.argv[2]
        valore = f"{float(sys.argv[3].replace(',', '.')):.2f}" if tipo != 'fogli' else sys.argv[3]
        with open(FILE, 'a', encoding='utf-8') as f:
            f.write(f"+{tipo}:{valore}\t{time.strftime('%H:%M:%S')}\n")
    elif comando == 'aggiungi_prodotto':
        aggiungi_prodotto()
    elif comando == 'impara':
        impara_sconosciuti()
    elif comando == 'venduti':
        # Toglie solo i prodotti venduti (i primi N): uno letto mentre si pagava resta nel carrello
        scrivi(leggi()[int(sys.argv[2]):])
    elif comando == 'togli':
        scrivi(leggi()[:-1])
    elif comando == 'svuota':
        scrivi([])
