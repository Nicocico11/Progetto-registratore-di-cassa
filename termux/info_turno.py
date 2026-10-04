import csv
import json
import os
import sys
from datetime import datetime, timedelta
import shutil
import glob
import re

# I moduli della cassa vocale (excel_turno.py) stanno nella cartella di Tasker
sys.path.insert(0, os.path.expanduser("~/.termux/tasker"))

# Uso: python3 info_turno.py [notifica | ultimi | totali | market | adblue |
#                             apri turno | chiudi turno [HH:MM] |
#                             cancella ultima | cancella penultima | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
PATH_TURNO = os.path.expanduser("~/turno_corrente.json")
PATH_ULTIMO_CONTEGGIO = os.path.expanduser("~/ultimo_conteggio.txt")
CARTELLA_CHIUSURE = os.path.expanduser("~/storage/downloads/Chiusure_Turno")
# Stessa intestazione che scrive processa_ia.py
INTESTAZIONE = ['data_ora', 'dettagli_json', 'importo']
CARBURANTI = ("BENZINA", "GASOLIO")
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
    """'150', '150,50', '150.50 €' -> 150.5; None se vuoto o non valido."""
    m = re.search(r'\d+(?:[.,]\d{1,2})?', (testo or "").replace(" ", ""))
    return float(m.group(0).replace(",", ".")) if m else None


def euro(x):
    return f"{x:.2f} €"


# ---------- turno ----------

def tipo_turno(momento):
    """Il turno il cui inizio (6, 14, 22) è più vicino all'orario dato, e la sua data d'inizio."""
    minuti = momento.hour * 60 + momento.minute

    def distanza(nome):
        d = abs(minuti - TURNI[nome][0] * 60)
        return min(d, 1440 - d)

    nome = min(TURNI, key=distanza)
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


def apri_turno(avanzo_testo=""):
    esistente = leggi_turno()
    if esistente:
        print(f"ℹ️ Turno già aperto: {descrivi_turno(esistente)}")
        return
    adesso = datetime.now()
    nome, data_inizio = tipo_turno(adesso)
    turno = {"tipo": nome, "data": data_inizio.strftime("%d/%m/%Y"),
             "data_file": data_inizio.isoformat(), "apertura": adesso.strftime("%Y-%m-%d %H:%M")}
    turno["documento"] = nuovo_documento(turno, adesso)
    turno["avanzo"] = importo_da_testo(avanzo_testo)
    salva_turno(turno)
    print(f"📅 {descrivi_turno(turno)}")
    print(f"💶 Avanzo cassa turno precedente: {euro(turno['avanzo']) if turno['avanzo'] is not None else '(non inserito)'}")
    try:
        import excel_turno
        stato = excel_turno.leggi_stato()
        c, tn = stato.get("contatore"), stato.get("taniche")
        print(f"🧪 AdBlue: contatore {c:g}" if c is not None else "🧪 Di' \"contatore adblue …\" (valore sulla colonnina)")
        print(f"🧪 Taniche: {tn}" if tn is not None else "🧪 Di' \"contatore taniche …\" (taniche in magazzino)")
    except Exception:
        pass
    print(salva_documento([], turno))


def salva_turno(turno):
    with open(PATH_TURNO, 'w', encoding='utf-8') as f:
        json.dump(turno, f)


def nuovo_documento(turno, adesso):
    """Percorso del documento in Download: <data>_<turno>.txt (se esiste già, con l'ora)."""
    base = os.path.join(CARTELLA_CHIUSURE, f"{turno['data_file']}_{turno['tipo']}")
    return base + ".txt" if not os.path.exists(base + ".txt") else f"{base}_{adesso.strftime('%H%M')}.txt"


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
    testo = re.sub(r'\s+virgola\s+', ',', testo.lower())
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


def aggiungi_versamento(testo):
    """"versamento 500": contanti tolti dal cassetto (non vanno più contati negli attesi)."""
    valore = importo_da_testo(re.sub(r'\s+virgola\s+', ',', testo))
    if valore is None:
        print("❓ Di' l'importo, es. \"versamento 500\".")
        sys.exit(1)
    t = turno_attuale(leggi_csv())
    t["versamento"] = round((t.get("versamento") or 0) + valore, 2)
    salva_turno(t)
    print(f"🏦 Versamento registrato: {euro(valore)} (totale versato nel turno: {euro(t['versamento'])})")


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
        os.makedirs(CARTELLA_CHIUSURE, exist_ok=True)
        path_doc = t["documento"]
        scrivi_sicuro(path_doc, testo_documento(righe, t, finale, orario_terminale))
        dati = [",".join(INTESTAZIONE)] + [
            ",".join('"' + c.replace('"', '""') + '"' for c in r) for r in righe]
        scrivi_sicuro(path_doc[:-4] + "_dati.csv", "\n".join(dati) + "\n")
        return f"💾 Download/Chiusure_Turno/{os.path.basename(path_doc)}"
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
    copie = sorted(glob.glob(os.path.join(CARTELLA_CHIUSURE, "*_dati.csv")), key=os.path.getmtime)
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
           f"Vendite: {len(vv)}    TOTALE: {euro(totale)}", ""]

    out.append("💳 PER PAGAMENTO")
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<16} {euro(val):>10}")
    out.append(f"  {'= Contanti':<16} {euro(contanti):>10}")
    out.append(f"  {'= Elettronico':<16} {euro(totale - contanti):>10}")
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
    sconti = [v for v in vv if v["reparto"] == "Sconto"]
    if sconti:
        out.append("")
        out.append(f"🏷️ SCONTI / ABBUONI ({len(sconti)}): {euro(sum(v['importo'] for v in sconti))}")
    out.append("")
    out += prospetto_market(vv)
    out += prospetto_cassa(vv, t)
    return out


def notifica_breve(righe):
    t = leggi_turno()
    intest = f"🕐 {t['tipo']} dalle {t['apertura'][-5:]}" if t else "🕐 Turno non aperto"
    vv = vendite(righe)
    if not vv:
        print(f"📊 Totale: 0.00 € | Vendite: 0  {intest}\n────────────────\nNessuna transazione registrata.")
        return

    totale = sum(v["importo"] for v in vv)
    out = [f"📊 Tot: {euro(totale)} ({len(vv)} vendite)  {intest}"]

    # Carburanti per tipo; AdBlue e Market solo come totale
    parti = []
    for nome, val in totali_per([v for v in vv if v["reparto"] == "Carburante"], "categoria").items():
        parti.append(f"{nome.upper()}: {val:.2f}€")
    for reparto, icona in (("AdBlue", "🧪 ADBLUE"), ("Fax", "📠 FAX"), ("Market", "🛒 MARKET"), ("Sconto", "🏷️ ABBUONI")):
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


def cancella_ultima():
    gruppi = transazioni(leggi_csv())
    if not gruppi:
        print("Totale: 0.00 € | Vendite: 0\nNessuna transazione da cancellare.")
        return
    righe_aggiornate = [r for g in gruppi[:-1] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print(f"🗑️ Cancellata l'ultima vendita ({len(gruppi[-1])} voci)" if len(gruppi[-1]) > 1
          else "🗑️ Cancellata l'ultima vendita")
    notifica_breve(righe_aggiornate)


def cancella_penultima():
    gruppi = transazioni(leggi_csv())
    if len(gruppi) < 2:
        print("Servono almeno 2 transazioni.")
        return
    righe_aggiornate = [r for g in gruppi[:-2] + gruppi[-1:] for r in g]
    scrivi_csv(righe_aggiornate)
    salva_copia()
    print("🗑️ Cancellata la penultima vendita")
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
    if t["contati"] is not None:
        with open(PATH_ULTIMO_CONTEGGIO, 'w') as f:  # suggerimento per l'avanzo del turno dopo
            f.write(f"{t['contati']:.2f}")
    adesso = datetime.now()
    testo = testo_documento(righe, t, finale=True, orario_terminale=orario_terminale)
    salvato = salva_documento(righe, t, finale=True, orario_terminale=orario_terminale)

    try:
        import excel_turno
        messaggi_excel, _ = excel_turno.crea_excel(righe, t, orario_terminale, CARTELLA_CHIUSURE)
    except ImportError:
        messaggi_excel = ["⚠️ Excel non creato: manca openpyxl (riesegui l'installazione con internet)"]
    except Exception as e:
        messaggi_excel = [f"⚠️ Excel non creato ({e})"]

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
        apri_turno(sys.argv[3] if len(sys.argv) > 3 else "")
    elif comando == "aperto":
        sys.exit(0 if turno_aperto() else 1)
    elif comando == "ultimo conteggio":
        try:
            print(open(PATH_ULTIMO_CONTEGGIO).read().strip().replace(".", ","))
        except Exception:
            pass
    elif comando.startswith("contatore"):
        imposta_contatore(" ".join(sys.argv[2:]) or comando)
    elif comando.startswith("versamento"):
        aggiungi_versamento(" ".join(sys.argv[2:]))
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
        if comando == "totali":
            print("\n".join(prospetto_completo(righe, "🧾 RIEPILOGO TURNO", leggi_turno())))
        elif comando == "market":
            print("\n".join(prospetto_market(vendite(righe))))
        elif comando == "adblue":
            print("\n".join(prospetto_adblue(vendite(righe))))
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
