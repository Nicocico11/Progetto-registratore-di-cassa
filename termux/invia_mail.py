import glob, json, os, smtplib, ssl, subprocess, sys
from email.message import EmailMessage

# Invio automatico della chiusura per email (Gmail).
# I dati di accesso stanno SOLO sul telefono, in ~/.cassa_email.json (mai su GitHub).
#
# Uso:  python3 invia_mail.py configura          -> chiede mittente, password per app, destinatario
#       python3 invia_mail.py prova              -> manda una mail di prova
#       python3 invia_mail.py invia <cartella>   -> manda i file della cartella del turno (alla chiusura)
#       python3 invia_mail.py coda               -> rimanda le mail rimaste in coda (senza internet)

CONFIG = os.path.expanduser('~/.cassa_email.json')
CODA = os.path.expanduser('~/.cassa_email_coda')
FINTO = os.environ.get('INVIA_MAIL_FINTO')   # solo per la prova su computer: salva la mail invece di spedirla


def leggi_config():
    try:
        with open(CONFIG, encoding='utf-8') as f:
            c = json.load(f)
        return c if c.get('mittente') and c.get('password') and c.get('destinatario') else None
    except Exception:
        return None


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
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, context=ssl.create_default_context(), timeout=30) as s:
        s.login(c['mittente'], c['password'])
        s.send_message(msg)


def file_del_turno(cartella):
    excel = sorted(glob.glob(os.path.join(cartella, 'Excel', '*.xlsx')))
    riepilogo = sorted(glob.glob(os.path.join(cartella, 'Documenti', '*.txt')))
    return excel, riepilogo


def invia_turno(cartella):
    """True se spedita (o non configurata: niente da fare), False se rimasta in coda."""
    c = leggi_config()
    if not c:
        return True
    excel, riepilogo = file_del_turno(cartella)
    if not excel and not riepilogo:
        return True
    nome = os.path.basename(cartella.rstrip('/'))            # es. 2026-10-05_Notte
    corpo = "Chiusura turno " + nome.replace('_', ' ') + "\n\n"
    if riepilogo:
        with open(riepilogo[0], encoding='utf-8') as f:
            corpo += f.read().split("\n📋")[0]               # riepilogo senza l'elenco di tutte le vendite
    try:
        spedisci(c, f"Chiusura turno {nome.replace('_', ' ')}", corpo, excel + riepilogo)
        notifica("📧 Mail della chiusura inviata", f"{nome} → {c['destinatario']}")
        return True
    except smtplib.SMTPAuthenticationError:
        notifica("📧 Mail NON inviata: password sbagliata",
                 "Rifai: python3 ~/.termux/tasker/invia_mail.py configura")
    except Exception as e:
        notifica("📧 Mail in coda (niente internet?)", f"{nome}: riparte da sola al prossimo comando")
    metti_in_coda(cartella)
    return False


def metti_in_coda(cartella):
    coda = leggi_coda()
    if cartella not in coda:
        coda.append(cartella)
    with open(CODA, 'w', encoding='utf-8') as f:
        f.write("\n".join(coda) + "\n")


def leggi_coda():
    try:
        with open(CODA, encoding='utf-8') as f:
            return [r.strip() for r in f if r.strip()]
    except Exception:
        return []


def svuota_coda():
    coda = leggi_coda()
    if not coda:
        return
    os.remove(CODA)
    for cartella in coda:
        if os.path.isdir(cartella):
            invia_turno(cartella)   # se fallisce di nuovo torna in coda


def configura():
    import getpass
    print("📧 CONFIGURAZIONE EMAIL (Gmail)")
    print("Serve la 'password per le app' di Google (16 lettere), NON la password normale.")
    print("I dati restano solo su questo telefono.\n")
    vecchia = leggi_config() or {}
    mittente = input(f"Gmail che invia{' [' + vecchia['mittente'] + ']' if vecchia.get('mittente') else ''}: ").strip() \
        or vecchia.get('mittente', '')
    password = getpass.getpass("Password per le app (non si vede mentre scrivi): ").replace(' ', '') \
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
        print("❌ Gmail non accetta mittente/password. Serve la 'password per le app' (16 lettere):\n"
              "   rifai: python3 ~/.termux/tasker/invia_mail.py configura")
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
        invia_turno(sys.argv[2])
    elif comando == 'coda':
        svuota_coda()
    else:
        print(__doc__ or "Uso: invia_mail.py configura | prova | invia <cartella> | coda")
