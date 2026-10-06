import csv
import json
import os
import sys
from datetime import datetime, timedelta
import shutil
import glob
import re
import subprocess

# I moduli della cassa vocale (excel_turno.py) stanno nella cartella di Tasker
sys.path.insert(0, os.path.expanduser("~/.termux/tasker"))

# Uso: python3 info_turno.py [notifica | ultimi | totali | market | adblue |
#                             apri turno | chiudi turno [HH:MM] |
#                             cancella ultima | cancella penultima | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
PATH_TURNO = os.path.expanduser("~/turno_corrente.json")
PATH_ULTIMO_CONTEGGIO = os.path.expanduser("~/ultimo_conteggio.txt")
# Se esiste: i turni VERI hanno comunque TEST nel nome dei file (per non confonderli con quelli fatti a mano)
PATH_NOMI_TEST = os.path.expanduser("~/.cassa_nomi_test")
CARTELLA_CHIUSURE = os.path.expanduser("~/storage/downloads/Chiusure_Turno")
# Stessa intestazione che scrive processa_ia.py
INTESTAZIONE = ['data_ora', 'dettagli_json', 'importo']
CARBURANTI = ("BENZINA", "GASOLIO", "GPL")
TURNI = {'Mattina': (6, "06-14"), 'Pomeriggio': (14, "14-22"), 'Notte': (22, "22-06")}


# ---------- lettura e scrittura ----------

def leggi_csv(path=PATH_CSV):
    if not os.path.exists(path):
        return []
    righe = []
    with open(path, mode='r', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader, None)
        for r in reader:
            if len(r) >= 2 and r[1].strip():
                righe.append(r)
    return righe


def scrivi_csv(righe):
    with open(PATH_CSV, mode='w', encoding='utf-8', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(INTESTAZIONE)
        writer.writerows(righe)


def vendita(r):
    """Dati di una riga del CSV, o None se illeggibile."""
    try:
        data = json.loads(r[1])
        cat = str(data.get("categoria", "altro")).replace("_", " ")
        metodo = str(data.get("metodo_pagamento", "altro"))
        metodo = {"carta carburante": "Petrolifere", "pos": "POS"}.get(metodo.lower(), metodo)
        if metodo.islower():
            metodo = metodo.capitalize()
        reparto = data.get("reparto")
        if not reparto:  # vendite salvate prima dei reparti
            if cat.upper() in CARBURANTI:
                reparto = "Carburante"
            elif "ADBLUE" in cat.upper().replace(" ", ""):
                reparto = "AdBlue"
            else:
                reparto = "Market"
        return {
            "ora": r[0].split()[-1][:5],
            "importo": float(data.get("importo", 0.0)),
            "categoria": cat,
            "metodo": metodo,
            "note": str(data.get("note", "")).strip(),
            "reparto": reparto,
            "quantita": float(data.get("quantita", 1) or 1),
            "unita": data.get("unita", "pz"),
        }
    except Exception:
        return None


def vendite(righe):
    return [v for v in (vendita(r) for r in righe) if v]


SIGLE = {"Contanti": "CON", "POS bianco": "BIA", "POS nero": "NER", "Petrolifere": "PET", "POS cassa": "CAS"}


def sigla(metodo):
    return SIGLE.get(metodo, metodo[:3].upper())


def importo_da_testo(testo):
    """'150', '150,50', '150.50 €', 'cinquanta' -> 150.5; None se vuoto o non valido."""
    try:
        from numeri import in_cifre
        testo = in_cifre(testo or "")
    except ImportError:
        pass
    testo = re.sub(r'(\d+):(\d{2})\b', r'\1.\2', testo or "")   # "20:30" scritto come un orario = 20,30
    m = re.search(r'\d+(?:[.,]\d{1,2})?', (testo or "").replace(" ", ""))
    return float(m.group(0).replace(",", ".")) if m else None


def euro(x):
    return f"{x:.2f} €"


# ---------- turno ----------

def tipo_turno(momento, forzato=""):
    """Il turno il cui inizio (6, 14, 22) è più vicino all'orario dato, e la sua data d'inizio.
    forzato: "mattina"/"pomeriggio"/"notte" detto nella frase ("apertura turno notte")."""
    minuti = momento.hour * 60 + momento.minute

    def distanza(nome):
        d = abs(minuti - TURNI[nome][0] * 60)
        return min(d, 1440 - d)

    nome = min(TURNI, key=distanza)
    if (forzato or "").capitalize() in TURNI:
        nome = forzato.capitalize()
    data_inizio = momento.date()
    if nome == 'Notte' and momento.hour >= 12:  # la notte porta la data del giorno dopo (aperta alle 22 del 4 = notte del 5)
        data_inizio += timedelta(days=1)
    return nome, data_inizio


def leggi_turno():
    try:
        with open(PATH_TURNO, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def descrivi_turno(t):
    return f"{t['tipo']} ({TURNI[t['tipo']][1]}) del {t['data']}, aperto alle {t['apertura'][-5:]}"


def turno_aperto():
    # Aperto a voce, oppure vendite già presenti (turni iniziati con le versioni precedenti)
    return bool(leggi_turno() or leggi_csv())


def apri_turno(avanzo_testo="", ora_prec_testo="", contatore_testo="", taniche_testo="", tipo="", prova=""):
    esistente = leggi_turno()
    if esistente:
        print(f"ℹ️ Turno già aperto: {descrivi_turno(esistente)}")
        return
    adesso = datetime.now()
    nome, data_inizio = tipo_turno(adesso, tipo)
    turno = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": adesso.strftime("%Y-%m-%d %H:%M")}
    if prova:
        turno["prova"] = True     # file con TEST nel nome, stato vero (contatore, taniche...) non toccato
    elif os.path.exists(PATH_NOMI_TEST):
        turno["nomi_test"] = True  # periodo di prova: turno vero (mail al lavoro), ma file con TEST nel nome
    turno["documento"] = nuovo_documento(turno, adesso)
    turno["avanzo"] = importo_da_testo(avanzo_testo)
    salva_turno(turno)
    if turno.get("nomi_test"):
        print("📛 Turno vero, file con TEST nel nome (periodo di prova): mail al lavoro")
    if prova:
        print("🧪 TURNO DI PROVA: file con TEST nel nome, contatori veri non toccati")
        try:
            import excel_turno
            shutil.copy(excel_turno.PATH_STATO, excel_turno.path_stato())
        except Exception:
            pass
    print(f"📅 {descrivi_turno(turno)}")
    print(f"💶 Avanzo cassa turno precedente: {euro(turno['avanzo']) if turno['avanzo'] is not None else '(non inserito)'}")
    try:
        import excel_turno
        stato = excel_turno.leggi_stato()
        # Valori scritti nei riquadri dell'apertura. Quelli rimasti dal mio turno precedente
        # non valgono: nel frattempo ci sono stati i turni degli altri. Vuoto = non inserito.
        ora = normalizza_orario(ora_prec_testo)
        stato["orario_chiusura"] = ora if re.fullmatch(r'\d\d:\d\d:\d\d', ora) else None
        if ora and not stato["orario_chiusura"]:
            print(f"⚠️ Ora chiusura precedente {ora}: scrivila a mano nell'Excel")
        contatore = re.search(r'\d+(?:[.,]\d+)?', contatore_testo or "")
        stato["contatore"] = float(contatore.group(0).replace(",", ".")) if contatore else None
        taniche = importo_da_testo(taniche_testo)
        stato["taniche"] = int(taniche) if taniche is not None else None
        excel_turno.salva_stato(stato)
        o, c, tn = stato.get("orario_chiusura"), stato.get("contatore"), stato.get("taniche")
        print(f"🕐 Ora chiusura turno precedente: {o}" if o else "🕐 Ora chiusura precedente non inserita")
        print(f"🧪 AdBlue: contatore {c:g}" if c is not None else "🧪 Di' \"contatore adblue …\" (valore sulla colonnina)")
        print(f"🧪 Taniche: {tn}" if tn is not None else "🧪 Di' \"contatore taniche …\" (taniche in magazzino)")
    except Exception:
        pass
    print(salva_documento([], turno))


def valore_stato(chiave):
    """Valore salvato dal turno prima (per i suggerimenti dei riquadri all'apertura)."""
    try:
        import excel_turno
        v = excel_turno.leggi_stato().get(chiave)
    except Exception:
        v = None
    if v is None:
        return ""
    return f"{v:g}".replace(".", ",") if isinstance(v, float) else str(v)


def salva_turno(turno):
    with open(PATH_TURNO, 'w', encoding='utf-8') as f:
        json.dump(turno, f)


def nuovo_documento(turno, adesso):
    """Documento del turno in Download, ogni turno nella sua cartella:
    Chiusure_Turno/<data>_<turno>/Documenti/<data>_<turno>.txt  (e .../Excel/ per i due Excel).
    Se la cartella esiste già (turno riaperto) si aggiunge l'ora."""
    nome = f"{turno['data_file']}_{turno['tipo']}" + ("_TEST" if turno.get("prova") or turno.get("nomi_test") else "")
    if os.path.exists(os.path.join(CARTELLA_CHIUSURE, nome)):
        nome += f"_{adesso.strftime('%H%M')}"
    return os.path.join(CARTELLA_CHIUSURE, nome, "Documenti", nome + ".txt")


def cartella_turno(t):
    """Cartella del turno (quella che contiene Documenti ed Excel)."""
    doc = t["documento"]
    if os.path.basename(os.path.dirname(doc)) == "Documenti":
        return os.path.dirname(os.path.dirname(doc))
    return os.path.join(CARTELLA_CHIUSURE, os.path.basename(doc)[:-4])  # turni aperti con la versione vecchia


def percorso_breve(path):
    return "Download/" + os.path.relpath(path, os.path.dirname(CARTELLA_CHIUSURE))


def imposta_avanzo(testo):
    """Comando "avanzo 150": inserisce o corregge l'avanzo del turno precedente."""
    valore = importo_da_testo(testo)
    if valore is None:
        print("❓ Di' l'importo, es. \"avanzo 150\" o \"avanzo 150,50\".")
        sys.exit(1)
    t = turno_attuale(leggi_csv())
    t["avanzo"] = valore
    salva_turno(t)
    print(f"💶 Avanzo cassa turno precedente: {euro(valore)}")


def imposta_contatore(testo):
    """"contatore adblue 68624,4" / "contatore taniche 59": valori di partenza del turno."""
    import excel_turno
    try:
        from numeri import in_cifre
        testo = in_cifre(testo)
    except ImportError:
        pass
    testo = re.sub(r'\s+virgola\s+', ',', testo.lower())
    testo = re.sub(r'(\d+):(\d+)\b', r'\1.\2', testo)
    valore = re.search(r'\d+(?:[.,]\d+)?', testo)
    if not valore:
        print("❓ Di' il numero, es. \"contatore adblue 68624,4\" o \"contatore taniche 59\".")
        sys.exit(1)
    valore = float(valore.group(0).replace(",", "."))
    stato = excel_turno.leggi_stato()
    if "tanic" in testo:
        stato["taniche"] = int(valore)
        print(f"🧪 Taniche AdBlue all'inizio del turno: {int(valore)}")
    else:
        stato["contatore"] = valore
        print(f"🧪 Contatore AdBlue all'inizio del turno: {valore:g}")
    excel_turno.salva_stato(stato)


TAGLI = (500, 200, 100, 50, 20, 10, 5)


def leggi_banconote(testo):
    """"200 50 50 50" / "1x200 3x50" / "una da 200 e tre da 50" -> {200: 1, 50: 3}."""
    try:
        from numeri import in_cifre
        testo = in_cifre(testo or "")
    except ImportError:
        testo = (testo or "").lower()
    conta = {}
    for n, taglio in re.findall(r'(\d+)\s*(?:x|\*|da|per|banconot[ae] da|pezzi da)\s*(\d+)', testo):
        if int(taglio) in TAGLI:
            conta[int(taglio)] = conta.get(int(taglio), 0) + int(n)
    testo = re.sub(r'(\d+)\s*(?:x|\*|da|per|banconot[ae] da|pezzi da)\s*(\d+)', ' ', testo)
    for taglio in re.findall(r'\d+', testo):
        if int(taglio) in TAGLI:
            conta[int(taglio)] = conta.get(int(taglio), 0) + 1
    return conta


def cancella_versamento():
    """"cancella versamento": toglie l'ultimo versamento (importo e banconote)."""
    t = turno_attuale(leggi_csv())
    if not t.get("versamenti"):
        print("❌ Nessun versamento da cancellare in questo turno.")
        sys.exit(1)
    ultimo = t["versamenti"].pop()
    t["versamento"] = round((t.get("versamento") or 0) - ultimo["importo"], 2)
    totali = dict(t.get("banconote_versamento") or {})
    for taglio, n in ultimo["banconote"].items():
        totali[taglio] = totali.get(taglio, 0) - n
    t["banconote_versamento"] = {k: v for k, v in totali.items() if v > 0}
    salva_turno(t)
    print(f"🗑️ Versamento di {euro(ultimo['importo'])} cancellato (totale versato nel turno: {euro(t['versamento'])})")


def banconote_calcolate(valore):
    """Le banconote più grandi possibili (se non sono state dette)."""
    conta, resto = {}, round(valore)
    for taglio in TAGLI:
        if resto >= taglio:
            conta[taglio], resto = divmod(resto, taglio)
    return conta, resto


def aggiungi_versamento(testo, banconote_testo=""):
    """"versamento 500": contanti tolti dal cassetto (non vanno più contati negli attesi).
    Le banconote vanno nel riquadro VERSAMENTO dell'Excel (numero di pezzi per taglio)."""
    valore = importo_da_testo(re.sub(r'\s+virgola\s+', ',', testo))
    if valore is None:
        print("❓ Di' l'importo, es. \"versamento 500\".")
        sys.exit(1)
    banconote = leggi_banconote(banconote_testo)
    avviso = ""
    if not banconote:
        banconote, resto = banconote_calcolate(valore)
        avviso = "⚠️ Banconote non dette: le ho calcolate io, controlla nell'Excel"
        if resto:
            avviso += f" (restano {resto} € che non fanno una banconota)"
    elif sum(t * n for t, n in banconote.items()) != round(valore, 2):
        # Non tornano: niente salvato, il riquadro si ripresenta (codice 3)
        print(f"❌ Le banconote fanno {sum(t * n for t, n in banconote.items())} € ma il versamento è "
              f"{euro(valore)}. Niente salvato.")
        sys.exit(3)
    t = turno_attuale(leggi_csv())
    t["versamento"] = round((t.get("versamento") or 0) + valore, 2)
    totali = {int(k): v for k, v in (t.get("banconote_versamento") or {}).items()}
    for taglio, n in banconote.items():
        totali[taglio] = totali.get(taglio, 0) + n
    t["banconote_versamento"] = {str(k): v for k, v in totali.items()}
    t.setdefault("versamenti", []).append({"importo": valore, "banconote": {str(k): v for k, v in banconote.items()}})
    salva_turno(t)
    if avviso:
        print(avviso)
    print(f"🏦 Versamento registrato: {euro(valore)} (totale versato nel turno: {euro(t['versamento'])})")
    print("   Banconote: " + ", ".join(f"{n}×{taglio}" for taglio, n in sorted(banconote.items(), reverse=True)))


def turno_attuale(righe):
    """Turno aperto a voce; se manca, lo si ricava dalla prima vendita e lo si memorizza."""
    t = leggi_turno()
    if not t:
        try:
            primo = datetime.strptime(righe[0][0][:16], "%Y-%m-%d %H:%M")
        except Exception:
            primo = datetime.now()
        nome, data_inizio = tipo_turno(primo)
        t = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": "(non registrata)"}
    if not t.get("documento"):
        t["documento"] = nuovo_documento(t, datetime.now())
        salva_turno(t)
    return t


def testo_documento(righe, t, finale=False, orario_terminale=""):
    adesso = datetime.now()
    apertura = t['apertura'][-5:] if t['apertura'][0].isdigit() else t['apertura']
    if finale:
        testa = ["🧾 CHIUSURA TURNO"]
        chiusura = adesso.strftime('%H:%M')
    else:
        testa = [f"⏳ TURNO IN CORSO - aggiornato alle {adesso.strftime('%H:%M:%S')}"]
        chiusura = "(turno ancora aperto)"
    testa += [
        f"Data:      {t['data']}",
        f"Turno:     {t['tipo']} ({TURNI[t['tipo']][1]})",
        f"Apertura:  {apertura}",
        f"Chiusura:  {chiusura}",
    ]
    if finale:
        testa.append(f"Terminale pompe: {orario_terminale or '(non inserito)'}")
    testa.append("")
    corpo = prospetto_completo(righe, "RIEPILOGO", t)
    dettaglio = ["", "📋 TUTTE LE VENDITE"] + [
        f"  {v['ora']} {euro(v['importo']):>10} {v['metodo']:<16} {v['note']}" for v in vendite(righe)]
    return "\n".join(testa + corpo + dettaglio) + "\n"


def scrivi_sicuro(path, contenuto):
    # Prima un file temporaneo, poi lo scambio: il documento non resta mai scritto a metà
    tmp = path + ".tmp"
    with open(tmp, 'w', encoding='utf-8', newline='') as f:
        f.write(contenuto)
    os.replace(tmp, path)


def salva_documento(righe, t, finale=False, orario_terminale=""):
    """Scrive (o riscrive) in Download il documento del turno e la copia dei dati (_dati.csv)."""
    try:
        path_doc = t["documento"]
        os.makedirs(os.path.dirname(path_doc), exist_ok=True)
        scrivi_sicuro(path_doc, testo_documento(righe, t, finale, orario_terminale))
        dati = [",".join(INTESTAZIONE)] + [
            ",".join('"' + c.replace('"', '""') + '"' for c in r) for r in righe]
        scrivi_sicuro(path_doc[:-4] + "_dati.csv", "\n".join(dati) + "\n")
        return f"💾 {percorso_breve(path_doc)}"
    except Exception as e:
        return f"⚠️ Copia in Download non riuscita ({e})"


def salva_copia():
    """Aggiorna il documento in Download con le vendite attuali (dopo ogni transazione)."""
    if not turno_aperto():
        return
    righe = leggi_csv()
    print(salva_documento(righe, turno_attuale(righe)))


def ripristina():
    """Se il file delle vendite in Termux è vuoto, lo ricostruisce dalla copia in Download."""
    if leggi_csv():
        print("ℹ️ Ci sono già vendite nel turno: niente da ripristinare.")
        return
    copie = sorted(glob.glob(os.path.join(CARTELLA_CHIUSURE, "**", "*_dati.csv"), recursive=True),
                   key=os.path.getmtime)
    if not copie:
        print("📭 Nessuna copia trovata in Download/Chiusure_Turno.")
        return
    shutil.copy(copie[-1], PATH_CSV)
    print(f"♻️ Ripristinate {len(leggi_csv())} vendite da {os.path.basename(copie[-1])}")


# ---------- prospetti ----------

def totali_per(vv, chiave):
    out = {}
    for v in vv:
        out[v[chiave]] = out.get(v[chiave], 0.0) + v["importo"]
    return out


def righe_market(vv):
    """Prodotti del market raggruppati: [(nome, quantità, importo)]."""
    gruppi = {}
    for v in vv:
        if v["reparto"] != "Market":
            continue
        q, imp = gruppi.get(v["categoria"], (0.0, 0.0))
        gruppi[v["categoria"]] = (q + v["quantita"], imp + v["importo"])
    return sorted(((n, q, i) for n, (q, i) in gruppi.items()), key=lambda x: -x[2])


def numero(q):
    return f"{q:g}"


def prospetto_market(vv):
    gruppi = righe_market(vv)
    out = ["🛒 MARKET (Danea)"]
    if not gruppi:
        return out + ["  Nessuna vendita market."]
    for nome, q, imp in gruppi:
        out.append(f"  {numero(q):>3} × {nome:<18} {euro(imp):>10}")
    out.append(f"  {'= Totale market':<24} {euro(sum(i for _, _, i in gruppi)):>10}")
    return out


def prospetto_adblue(vv, dettaglio=True):
    ad = [v for v in vv if v["reparto"] == "AdBlue"]
    out = [f"🧪 ADBLUE ({len(ad)} erogazioni)"]
    if not ad:
        return out + ["  Nessuna erogazione."]
    if dettaglio:
        for v in ad:
            q = f"{v['quantita']:.2f} l" if v["unita"] == "l" else f"{numero(v['quantita'])} ×"
            out.append(f"  • {v['ora']} {q} {v['categoria']} {euro(v['importo'])} ({sigla(v['metodo'])})")
    litri = sum(v["quantita"] for v in ad if v["unita"] == "l")
    euro_sfuso = sum(v["importo"] for v in ad if v["unita"] == "l")
    taniche = sum(v["quantita"] for v in ad if v["unita"] != "l")
    euro_taniche = sum(v["importo"] for v in ad if v["unita"] != "l")
    out.append(f"  Sfuso: {litri:.2f} litri erogati ({euro(euro_sfuso)})")
    out.append(f"  Taniche: {numero(taniche)} ({euro(euro_taniche)})")
    return out


def prospetto_cassa(vv, t):
    """Quadratura: avanzo + vendite in contanti = contanti attesi, confrontati con quelli contati."""
    if not t or all(t.get(k) is None for k in ("avanzo", "contati", "versamento")):
        return []
    contanti = sum(v["importo"] for v in vv if v["metodo"] == "Contanti")
    avanzo = t.get("avanzo") or 0.0

    def differenza(atteso, contato):
        d = round(contato - atteso, 2)
        if abs(d) < 0.005:
            return "✅ quadra"
        return f"⚠️ {'in più' if d > 0 else 'mancano'} {euro(abs(d))}"

    versamento = t.get("versamento") or 0.0
    attesi = avanzo + contanti - versamento
    out = ["", "💶 QUADRATURA CASSA",
           f"  {'Avanzo turno prec.':<20} {euro(avanzo) if t.get('avanzo') is not None else '(non inserito)':>12}",
           f"  {'+ Vendite contanti':<20} {euro(contanti):>12}"]
    if versamento:
        out.append(f"  {'- Versamenti':<20} {euro(versamento):>12}")
    out.append(f"  {'= Contanti attesi':<20} {euro(attesi):>12}")
    if t.get("cassaforte"):
        out.append(f"  {'di cui in cassaforte':<20} {euro(t['cassaforte']):>12}")
        attesi -= t["cassaforte"]
        out.append(f"  {'= Attesi nel cassetto':<20} {euro(attesi):>12}")
    if t.get("contati") is not None:
        out.append(f"  {'Contanti contati':<20} {euro(t['contati']):>12}   {differenza(attesi, t['contati'])}")
    return out


def prospetto_completo(righe, titolo, t=None):
    vv = vendite(righe)
    totale = sum(v["importo"] for v in vv)
    per_metodo = totali_per(vv, "metodo")
    contanti = per_metodo.get("Contanti", 0.0)
    out = [titolo, "─────────────────────────",
           f"Vendite: {numero_vendite(righe)}    TOTALE: {euro(totale)}", ""]

    out.append("💳 PER PAGAMENTO")
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<16} {euro(val):>10}")
    crediti = per_metodo.get("Credito", 0.0)
    out.append(f"  {'= Contanti':<16} {euro(contanti):>10}")
    out.append(f"  {'= Carte / POS':<16} {euro(totale - contanti - crediti):>10}")
    if crediti:
        out.append(f"  {'= Crediti clienti':<16} {euro(crediti):>10}   (non pagati)")
    out.append("")

    out.append("⛽ CARBURANTI")
    carb = {v["categoria"]: 0.0 for v in vv if v["reparto"] == "Carburante"}
    for v in vv:
        if v["reparto"] == "Carburante":
            carb[v["categoria"]] += v["importo"]
    for nome, val in sorted(carb.items()):
        out.append(f"  {nome:<16} {euro(val):>10}")
    out.append(f"  {'= Carburanti':<16} {euro(sum(carb.values())):>10}")
    out.append("")
    out += prospetto_adblue(vv, dettaglio=False)
    fax = [v for v in vv if v["reparto"] == "Fax"]
    if fax:
        out.append("")
        out.append("📠 FAX / FOTOCOPIE")
        out.append(f"  Fogli: {numero(sum(v['quantita'] for v in fax))}    Totale: {euro(sum(v['importo'] for v in fax))}")
    abbuoni = [v for v in vv if v["reparto"] == "Sconto"]
    resti = [v for v in vv if v["reparto"] == "Resto lasciato"]
    if abbuoni or resti:
        # Centesimi in meno (abbuoni) e in più (resti lasciati): sono già nei contanti
        out.append("")
        out.append("🪙 CENTESIMI (già compresi nei contanti)")
        out.append(f"  {'Abbuoni (' + str(len(abbuoni)) + ')':<20} {sum(v['importo'] for v in abbuoni):>+9.2f} €")
        out.append(f"  {'Resti lasciati (' + str(len(resti)) + ')':<20} {sum(v['importo'] for v in resti):>+9.2f} €")
        out.append(f"  {'= Saldo':<20} {sum(v['importo'] for v in abbuoni + resti):>+9.2f} €")
    out.append("")
    out += prospetto_market(vv)
    out += prospetto_cassa(vv, t)
    return out


def totali_brevi(righe):
    """Poche righe per la finestra di "totali" (il dettaglio è nel widget 04)."""
    vv = vendite(righe)
    t = leggi_turno() or {}
    per_metodo = totali_per(vv, "metodo")
    contanti = per_metodo.get("Contanti", 0.0)
    attesi = (t.get("avanzo") or 0.0) + contanti - (t.get("versamento") or 0.0)
    nomi = (("POS nero", "POS nero"), ("POS bianco", "POS bianco"), ("POS cassa", "POS cassa"),
            ("Petrolifere", "Petrolifere"), ("OPT", "OPT"), ("Credito", "Crediti clienti"))
    out = [f"Vendite: {numero_vendite(righe)}",
           f"💶 Attesi in cassa: {euro(attesi)}",
           f"   (avanzo {euro(t.get('avanzo') or 0.0)} + contanti {euro(contanti)}"
           + (f" - versamenti {euro(t['versamento'])}" if t.get('versamento') else "") + ")"]
    for m, breve in nomi:
        if per_metodo.get(m):
            out.append(f"💳 {breve}: {euro(per_metodo[m])}")
    return "\n".join(out)


def titolo_notifica():
    """Titolo della notifica: turno e ora di chiusura del collega (es. "🕐 Pomeriggio · collega chiuso alle 13:59:12")."""
    t = leggi_turno()
    if not t:
        return "🕐 Turno non aperto"
    try:
        import excel_turno
        ora = excel_turno.leggi_stato().get("orario_chiusura")
    except Exception:
        ora = None
    prova = " 🧪 PROVA" if t.get("prova") else ""
    return f"🕐 {t['tipo']}{prova} · " + (f"collega chiuso alle {ora}" if ora else "ora chiusura collega non inserita")


def notifica_breve(righe):
    vv = vendite(righe)
    if not vv:
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna transazione registrata.")
        return

    totale = sum(v["importo"] for v in vv)
    n = numero_vendite(righe)
    out = [f"📊 Tot: {euro(totale)} ({n} {'vendita' if n == 1 else 'vendite'})"]

    # Carburanti tutti insieme (gasolio, benzina e "carburante" detto senza tipo); gli altri come totale
    parti = []
    carburanti = sum(v["importo"] for v in vv if v["reparto"] == "Carburante")
    if carburanti:
        parti.append(f"CARBURANTI: {carburanti:.2f}€")
    for reparto, icona in (("AdBlue", "🧪 ADBLUE"), ("Fax", "📠 FAX"), ("Market", "🛒 MARKET"), ("Sconto", "🏷️ ABBUONI"), ("Resto lasciato", "🪙 RESTI LASCIATI"),
                           ("Credito cliente", "📒 CREDITI"), ("Credito riscosso", "💰 RISCOSSI")):
        val = sum(v["importo"] for v in vv if v["reparto"] == reparto)
        if val:
            parti.append(f"{icona}: {val:.2f}€")
    out.append("⛽ " + " | ".join(parti))
    out.append("💳 " + " | ".join(f"{m}: {val:.2f}€" for m, val in totali_per(vv, "metodo").items()))

    out.append("────────────────")
    out.append("🔍 Ultime transazioni:")
    # Le vendite market non compaiono qui (solo nel totale sopra)
    for v in reversed([v for v in vv if v["reparto"] != "Market"][-5:]):
        out.append(f"• {v['ora']} | {v['importo']:.2f}€ ({sigla(v['metodo'])}) {v['note']}")
    print("\n".join(out))


def mostra_archivio():
    pattern = os.path.expanduser("~/turno_archivio_*.csv")
    out = ["📂 STORICO TURNI ARCHIVIATI:", "─────────────────────────"]
    for path_arc in sorted(glob.glob(pattern), reverse=True):
        vv = vendite(leggi_csv(path_arc))
        if not vv:
            continue  # turni vuoti: non li mostriamo
        data_str = os.path.basename(path_arc).replace("turno_archivio_", "").replace(".csv", "").replace("_", " ")
        out.append(f"• 📅 {data_str} | 💰 {euro(sum(v['importo'] for v in vv))} ({len(vv)} vendite)")
    if len(out) == 2:
        print("📭 Nessun turno precedente archiviato.")
        return
    print("\n".join(out))


# ---------- modifiche ----------

def transazioni(righe):
    """Righe raggruppate per transazione (una vendita mista ha più righe con lo stesso numero)."""
    gruppi = []
    for r in righe:
        try:
            num = json.loads(r[1]).get("transazione")
        except Exception:
            num = None
        if num and gruppi and gruppi[-1][0] == num:
            gruppi[-1][1].append(r)
        else:
            gruppi.append((num, [r]))
    return [g for _, g in gruppi]


def numero_vendite(righe):
    """Vendite vere: un abbuono o un resto detto da solo non è una vendita."""
    n = 0
    for gruppo in transazioni(righe):
        reparti = {(vendita(r) or {}).get("reparto") for r in gruppo}
        if reparti - {"Sconto", "Resto lasciato"}:
            n += 1
    return n


def descrivi_gruppo(gruppo):
    """"Gasolio 20.10 € + Abbuono -0.10 €": cosa c'era nella vendita cancellata."""
    vv = [v for v in (vendita(r) for r in gruppo) if v]
    return " + ".join(f"{v['categoria']} {v['importo']:.2f} €" for v in vv) + (f" ({vv[0]['metodo']})" if vv else "")


def cancella_ultima():
    gruppi = transazioni(leggi_csv())
    if not gruppi:
        print("Totale: 0.00 € | Vendite: 0\nNessuna transazione da cancellare.")
        return
    righe_aggiornate = [r for g in gruppi[:-1] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print(f"🗑️ Cancellata l'ultima vendita: {descrivi_gruppo(gruppi[-1])}")
    notifica_breve(righe_aggiornate)


def cancella_penultima():
    gruppi = transazioni(leggi_csv())
    if len(gruppi) < 2:
        print("Servono almeno 2 transazioni.")
        return
    righe_aggiornate = [r for g in gruppi[:-2] + gruppi[-1:] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print(f"🗑️ Cancellata la penultima vendita: {descrivi_gruppo(gruppi[-2])}")
    notifica_breve(righe_aggiornate)


def normalizza_orario(grezzo):
    """'14 05 32', '14:05:32', '140532' -> '14:05:32'. Vuoto se non inserito."""
    gruppi = re.findall(r'\d+', grezzo or "")
    if not gruppi:
        return ""
    if len(gruppi) == 1:  # tutto attaccato: 140532 / 60532 / 1405
        cifre = gruppi[0]
        if len(cifre) in (5, 6):
            cifre = cifre.zfill(6)
            gruppi = [cifre[:2], cifre[2:4], cifre[4:]]
        elif len(cifre) in (3, 4):
            cifre = cifre.zfill(4)
            gruppi = [cifre[:2], cifre[2:]]
    try:
        h, m = int(gruppi[0]), int(gruppi[1])
        sec = int(gruppi[2]) if len(gruppi) > 2 else None
    except (ValueError, IndexError):
        return f"(non valido: {grezzo})"
    if h > 23 or m > 59 or (sec is not None and sec > 59):
        return f"(non valido: {grezzo})"
    if sec is None:
        return f"{h:02d}:{m:02d} (secondi non inseriti)"
    return f"{h:02d}:{m:02d}:{sec:02d}"


def chiudi_turno(orario_terminale="", contati_testo="", cassaforte_testo=""):
    orario_terminale = normalizza_orario(orario_terminale)
    righe = leggi_csv()
    if not righe:
        # Niente da archiviare: evita di creare file d'archivio vuoti
        if os.path.exists(PATH_TURNO):
            os.remove(PATH_TURNO)
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna vendita: niente da archiviare.")
        return

    t = turno_attuale(righe)
    t["contati"] = importo_da_testo(contati_testo)
    t["cassaforte"] = importo_da_testo(cassaforte_testo)
    if t["contati"] is not None and not t.get("prova"):
        with open(PATH_ULTIMO_CONTEGGIO, 'w') as f:  # suggerimento per l'avanzo del turno dopo
            f.write(f"{t['contati']:.2f}")
    adesso = datetime.now()
    testo = testo_documento(righe, t, finale=True, orario_terminale=orario_terminale)
    salvato = salva_documento(righe, t, finale=True, orario_terminale=orario_terminale)

    try:
        import excel_turno
        messaggi_excel, stato = excel_turno.crea_excel(righe, t, orario_terminale,
                                                         os.path.join(cartella_turno(t), "Excel"))
        if t["contati"] is None and stato.get("avanzo") is not None and not t.get("prova"):
            with open(PATH_ULTIMO_CONTEGGIO, 'w') as f:  # avanzo calcolato, proposto all'apertura dopo
                f.write(f"{stato['avanzo']:.2f}")
    except ImportError:
        messaggi_excel = ["⚠️ Excel non creato: manca openpyxl (riesegui l'installazione con internet)"]
    except Exception as e:
        messaggi_excel = [f"⚠️ Excel non creato ({e})"]

    # Mail con Excel e riepilogo, in sottofondo (se configurata; senza internet resta in coda)
    # Mail con Excel e riepilogo, subito (qualche secondo); senza internet resta in coda
    if os.path.exists(os.path.expanduser("~/.cassa_email.json")):
        try:
            import invia_mail
            invia_mail.svuota_coda()
            esito = invia_mail.invia_turno(cartella_turno(t), prova=bool(t.get("prova")))
        except Exception as e:
            esito = f"📧 Mail non inviata ({e})"
        if esito:
            messaggi_excel.append(esito)

    timestamp_backup = adesso.strftime("%Y-%m-%d_%H-%M-%S")
    shutil.copy(PATH_CSV, os.path.expanduser(f"~/turno_archivio_{timestamp_backup}.csv"))
    scrivi_csv([])
    if os.path.exists(PATH_TURNO):
        os.remove(PATH_TURNO)

    print(testo.split("\n📋")[0])
    print(salvato)
    print("\n".join(messaggi_excel))


def main():
    comando = " ".join(sys.argv[1:]).lower() if len(sys.argv) > 1 else "notifica"

    if "cancella ultima" in comando or "elimina ultima" in comando:
        cancella_ultima()
    elif "penultima" in comando:
        cancella_penultima()
    elif comando.startswith("apri turno"):
        argomenti = sys.argv[3:] + ["", "", "", "", "", ""]
        apri_turno(*argomenti[:6])
    elif comando.startswith("nomi test"):
        if comando.endswith(("si", "sì", "on")):
            open(PATH_NOMI_TEST, 'w').close()
            print("📛 Da ora i turni veri hanno TEST nel nome dei file (la mail va comunque al lavoro).")
        elif comando.endswith(("no", "off")):
            if os.path.exists(PATH_NOMI_TEST):
                os.remove(PATH_NOMI_TEST)
            print("✅ Da ora i turni veri hanno il nome normale dei file.")
        else:
            print("📛 TEST nei nomi dei turni veri: " + ("SÌ" if os.path.exists(PATH_NOMI_TEST) else "no"))
    elif comando.startswith("stato "):
        print(valore_stato(sys.argv[2] if len(sys.argv) > 2 else ""))
    elif comando == "aperto":
        sys.exit(0 if turno_aperto() else 1)
    elif comando == "ultimo conteggio":
        try:
            print(open(PATH_ULTIMO_CONTEGGIO).read().strip().replace(".", ","))
        except Exception:
            pass
    elif comando.startswith("contatore"):
        imposta_contatore(" ".join(sys.argv[2:]) or comando)
    elif comando == "titolo":
        print(titolo_notifica())
    elif comando == "cancella versamento":
        cancella_versamento()
    elif comando.startswith("versamento"):
        aggiungi_versamento(sys.argv[2] if len(sys.argv) > 2 else "", sys.argv[3] if len(sys.argv) > 3 else "")
    elif comando.startswith("importo"):
        valore = importo_da_testo(re.sub(r'\s+virgola\s+', ',', " ".join(sys.argv[2:])))
        print(f"{valore:g}" if valore is not None else "")
    elif comando.startswith("avanzo"):
        imposta_avanzo(" ".join(sys.argv[2:]))
    elif "chiudi turno" in comando or "fine turno" in comando or "azzera" in comando:
        argomenti = sys.argv[2:] + ["", "", ""]
        chiudi_turno(argomenti[0], argomenti[1], argomenti[2])
    elif comando == "salva":
        salva_copia()
    elif "ripristin" in comando:
        ripristina()
    elif "archivio" in comando or "storico" in comando:
        mostra_archivio()
    else:
        righe = leggi_csv()
        if comando == "totali breve":
            print(totali_brevi(righe))
        elif comando == "totali":
            print("\n".join(prospetto_completo(righe, "🧾 RIEPILOGO TURNO", leggi_turno())))
        elif comando == "market":
            print("\n".join(prospetto_market(vendite(righe))))
        elif comando == "adblue":
            print("\n".join(prospetto_adblue(vendite(righe))))
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
