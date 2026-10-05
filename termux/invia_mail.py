import glob, json, os, smtplib, ssl, subprocess, sys
from email.message import EmailMessage

# Invio automatico della chiusura per email (Gmail, Libero, Outlook: il server si sceglie dall'indirizzo).
# I dati di accesso stanno SOLO sul telefono, in ~/.cassa_email.json (mai su GitHub).
#
# Uso:  python3 invia_mail.py configura          -> chiede mittente, password per app, destinatario
#       python3 invia_mail.py prova              -> manda una mail di prova
#       python3 invia_mail.py invia <cartella>   -> manda i file della cartella del turno (alla chiusura)
#       python3 invia_mail.py coda               -> rimanda le mail rimaste in coda (senza internet)

CONFIG = os.path.expanduser('~/.cassa_email.json')
# dominio -> (server, porta, SSL diretto); con SSL False si usa STARTTLS
SERVER = {
    'gmail.com': ('smtp.gmail.com', 465, True), 'googlemail.com': ('smtp.gmail.com', 465, True),
    'libero.it': ('smtp.libero.it', 465, True), 'inwind.it': ('smtp.libero.it', 465, True),
    'iol.it': ('smtp.libero.it', 465, True), 'blu.it': ('smtp.libero.it', 465, True),
    'outlook.com': ('smtp-mail.outlook.com', 587, False), 'outlook.it': ('smtp-mail.outlook.com', 587, False),
    'hotmail.com': ('smtp-mail.outlook.com', 587, False), 'hotmail.it': ('smtp-mail.outlook.com', 587, False),
    'live.com': ('smtp-mail.outlook.com', 587, False), 'live.it': ('smtp-mail.outlook.com', 587, False),
}


def server_di(mittente):
    return SERVER.get(mittente.split('@')[-1].lower(), ('smtp.gmail.com', 465, True))
CODA = os.path.expanduser('~/.cassa_email_coda')
FINTO = os.environ.get('INVIA_MAIL_FINTO')   # solo per la prova su computer: salva la mail invece di spedirla


def leggi_config():
    try:
        with open(CONFIG, encoding='utf-8') as f:
            c = json.load(f)
        return c if c.get('mittente') and c.get('password') and c.get('destinatario') else None
    except Exception:
        return None


def registra(testo):
    """Esito nel registro (debug_tasker.log), per capire cosa è successo."""
    try:
        import datetime
        with open(os.path.expanduser('~/debug_tasker.log'), 'a') as f:
            f.write(f"{datetime.datetime.now():%H:%M:%S} mail: {testo}\n")
    except Exception:
        pass


def notifica(titolo, testo):
    try:
        subprocess.Popen(['termux-notification', '--id', 'cassa_email', '--title', titolo, '--content', testo],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def spedisci(c, oggetto, corpo, allegati):
    msg = EmailMessage()
    msg['From'], msg['To'], msg['Subject'] = c['mittente'], c['destinatario'], oggetto
    msg.set_content(corpo)
    for path in allegati:
        with open(path, 'rb') as f:
            dati = f.read()
        if path.endswith('.xlsx'):
            tipo = ('application', 'vnd.openxmlformats-officedocument.spreadsheetml.sheet')
        else:
            tipo = ('text', 'plain')
        msg.add_attachment(dati, maintype=tipo[0], subtype=tipo[1], filename=os.path.basename(path))
    if FINTO:
        with open(os.path.join(FINTO, 'mail_%d.eml' % len(os.listdir(FINTO))), 'wb') as f:
            f.write(bytes(msg))
        return
    host, porta, ssl_diretto = server_di(c['mittente'])
    if ssl_diretto:
        server = smtplib.SMTP_SSL(host, porta, context=ssl.create_default_context(), timeout=30)
    else:
        server = smtplib.SMTP(host, porta, timeout=30)
        server.starttls(context=ssl.create_default_context())
    with server as s:
        s.login(c['mittente'], c['password'])
        s.send_message(msg)


def file_del_turno(cartella):
    excel = sorted(glob.glob(os.path.join(cartella, 'Excel', '*.xlsx')))
    riepilogo = sorted(glob.glob(os.path.join(cartella, 'Documenti', '*.txt')))
    return excel, riepilogo


def invia_turno(cartella, prova=False):
    """Spedisce la chiusura; se non riesce la mette in coda. Restituisce il messaggio da mostrare."""
    c = leggi_config()
    if not c:
        return ""
    excel, riepilogo = file_del_turno(cartella)
    if not excel and not riepilogo:
        registra(f"niente da mandare in {cartella}")
        return "📧 Mail: nessun file da mandare"
    nome = os.path.basename(cartella.rstrip('/'))            # es. 2026-10-05_Notte
    if prova:
        c = dict(c, destinatario=c['mittente'])   # turno di prova: la mail arriva solo a me, non al lavoro
    corpo = "Chiusura turno " + nome.replace('_', ' ') + "\n\n"
    if riepilogo:
        with open(riepilogo[0], encoding='utf-8') as f:
            corpo += f.read().split("\n📋")[0]               # riepilogo senza l'elenco di tutte le vendite
    try:
        spedisci(c, f"Chiusura turno {nome.replace('_', ' ')}", corpo, excel + riepilogo)
        notifica("📧 Mail della chiusura inviata", f"{nome} → {c['destinatario']}")
        registra(f"inviata {nome} a {c['destinatario']} ({len(excel + riepilogo)} allegati)")
        return f"📧 Mail inviata a {c['destinatario']} ({len(excel + riepilogo)} allegati)"
    except smtplib.SMTPAuthenticationError:
        notifica("📧 Mail NON inviata: password sbagliata",
                 "Rifai: python3 ~/.termux/tasker/invia_mail.py configura")
        registra(f"password rifiutata, {nome} in coda")
        esito = "📧 Mail NON inviata: password rifiutata (rifai la configurazione). Resta in coda"
    except Exception as e:
        notifica("📧 Mail in coda (niente internet?)", f"{nome}: riparte da sola al prossimo comando")
        registra(f"non inviata ({e}), {nome} in coda")
        esito = "📧 Mail in coda (niente internet?): riparte da sola al prossimo comando"
    metti_in_coda(cartella, prova)
    return esito


def metti_in_coda(cartella, prova=False):
    # una riga per cartella: "<cartella>\t1" = turno di prova (mail solo a me), "\t0" = turno vero
    coda = [r for r in leggi_coda() if r[0] != cartella] + [(cartella, bool(prova))]
    with open(CODA, 'w', encoding='utf-8') as f:
        f.write("".join(f"{c}\t{int(p)}\n" for c, p in coda))


def leggi_coda():
    """[(cartella, prova)]; le righe vecchie senza segno valgono come prova se il nome ha TEST."""
    try:
        with open(CODA, encoding='utf-8') as f:
            righe = [r.rstrip('\n') for r in f if r.strip()]
    except Exception:
        return []
    coda = []
    for r in righe:
        cartella, _, segno = r.partition('\t')
        coda.append((cartella, segno == '1' if segno else '_TEST' in cartella))
    return coda


def svuota_coda():
    coda = leggi_coda()
    if not coda:
        return
    os.remove(CODA)
    for cartella, prova in coda:
        if os.path.isdir(cartella):
            invia_turno(cartella, prova)   # se fallisce di nuovo torna in coda


def configura():
    import getpass
    print("📧 CONFIGURAZIONE EMAIL")
    print("Gmail: serve la 'password per le app' di Google (16 lettere), NON la password normale.")
    print("Libero: di solito va bene la password normale della casella.")
    print("I dati restano solo su questo telefono.\n")
    vecchia = leggi_config() or {}
    mittente = input(f"Indirizzo che invia (Gmail o Libero){' [' + vecchia['mittente'] + ']' if vecchia.get('mittente') else ''}: ").strip() \
        or vecchia.get('mittente', '')
    password = getpass.getpass("Password (non si vede mentre scrivi): ").replace(' ', '') \
        or vecchia.get('password', '')
    destinatario = input(f"Indirizzo a cui mandare la chiusura"
                         f"{' [' + vecchia['destinatario'] + ']' if vecchia.get('destinatario') else ''}: ").strip() \
        or vecchia.get('destinatario', '')
    if not (mittente and password and destinatario):
        print("❌ Mancano dei dati: niente salvato.")
        sys.exit(1)
    with open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump({'mittente': mittente, 'password': password, 'destinatario': destinatario}, f)
    os.chmod(CONFIG, 0o600)
    print("✅ Salvato. Ora prova: python3 ~/.termux/tasker/invia_mail.py prova")


def prova():
    c = leggi_config()
    if not c:
        print("❌ Email non configurata: python3 ~/.termux/tasker/invia_mail.py configura")
        sys.exit(1)
    try:
        spedisci(c, "Prova cassa vocale", "Se leggi questa mail, l'invio automatico della chiusura funziona.", [])
        print(f"✅ Mail di prova inviata a {c['destinatario']}")
    except smtplib.SMTPAuthenticationError:
        print("❌ Il server non accetta indirizzo/password.\n"
              "   Gmail: serve la 'password per le app' (16 lettere). Libero: controlla la password e che\n"
              "   nelle impostazioni di Libero Mail sia permesso l'accesso da programmi esterni.\n"
              "   Poi rifai: python3 ~/.termux/tasker/invia_mail.py configura")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Invio non riuscito ({e}). C'è internet?")
        sys.exit(1)


if __name__ == '__main__':
    comando = sys.argv[1] if len(sys.argv) > 1 else ''
    if comando == 'configura':
        configura()
    elif comando == 'prova':
        prova()
    elif comando == 'invia' and len(sys.argv) > 2:
        svuota_coda()
        print(invia_turno(sys.argv[2]))
    elif comando == 'coda':
        print("📭 Nessuna mail in coda" if not leggi_coda() else f"📤 In coda: {len(leggi_coda())}, riprovo…")
        svuota_coda()
        print("✅ Coda vuota" if not leggi_coda() else "⚠️ Ancora in coda (guarda il registro)")
    else:
        print(__doc__ or "Uso: invia_mail.py configura | prova | invia <cartella> | coda")
