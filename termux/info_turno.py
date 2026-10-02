import csv
import json
import os
import sys
from datetime import datetime
import shutil
import glob

# Uso: python3 info_turno.py [notifica | ultimi | totali | cancella ultima |
#                             cancella penultima | chiudi turno | archivio]

PATH_CSV = os.path.expanduser("~/transazioni_turno.csv")
# Stessa intestazione che scrive processa_ia.py
INTESTAZIONE = ['data_ora', 'dettagli_json', 'importo']
CARBURANTI = ("BENZINA", "GASOLIO")


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
    """Restituisce (importo, categoria, metodo, note) di una riga, o None se illeggibile."""
    try:
        data = json.loads(r[1])
        imp = float(data.get("importo", 0.0))
        cat = str(data.get("categoria", "altro")).replace("_", " ").upper()
        metodo = str(data.get("metodo_pagamento", "altro")).capitalize()
        if metodo == "Pos":
            metodo = "POS"
        return imp, cat, metodo, str(data.get("note", "")).strip()
    except Exception:
        return None


def calcola_totali(righe):
    totale, per_categoria, per_metodo = 0.0, {}, {}
    for r in righe:
        v = vendita(r)
        if not v:
            continue
        imp, cat, metodo, _ = v
        totale += imp
        per_categoria[cat] = per_categoria.get(cat, 0.0) + imp
        per_metodo[metodo] = per_metodo.get(metodo, 0.0) + imp
    return totale, per_categoria, per_metodo


def notifica_breve(righe):
    if not righe:
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna transazione registrata.")
        return

    totale, per_categoria, per_metodo = calcola_totali(righe)

    # Testata con totale, categorie e metodi di pagamento
    out = [f"📊 Tot: {totale:.2f} € ({len(righe)} vendite)"]
    cats_str = " | ".join(f"{cat}: {val:.2f}€" for cat, val in per_categoria.items())
    if cats_str:
        out.append(f"⛽ {cats_str}")
    metodi_str = " | ".join(f"{m}: {val:.2f}€" for m, val in per_metodo.items())
    if metodi_str:
        out.append(f"💳 {metodi_str}")

    out.append("────────────────")
    out.append("🔍 Ultime transazioni:")

    # Ultime 5 transazioni, la più recente in cima
    for r in reversed(righe[-5:]):
        ora = r[0].split()[-1] if " " in r[0] else r[0]
        ora_breve = ora[:5]  # 05:30:22 -> 05:30
        v = vendita(r)
        if v:
            imp, _, metodo, note = v
            riga_txt = f"• {ora_breve} | {imp:.2f}€ ({metodo[:3].upper()})"
            if note:
                riga_txt += f" {note}"
            out.append(riga_txt)
        else:
            out.append(f"• {ora_breve} | {r[2] if len(r) > 2 else '?'}")

    print("\n".join(out))


def riepilogo_chiusura(righe, titolo="🧾 RIEPILOGO TURNO"):
    """Il prospetto da usare per la chiusura: totali per pagamento e per prodotto."""
    totale, per_categoria, per_metodo = calcola_totali(righe)
    out = [titolo, "─────────────────────────",
           f"Vendite: {len(righe)}    TOTALE: {totale:.2f} €", ""]

    out.append("💳 PER PAGAMENTO")
    contanti = per_metodo.get("Contanti", 0.0)
    for m, val in sorted(per_metodo.items()):
        out.append(f"  {m:<10} {val:>9.2f} €")
    out.append(f"  {'= Contanti':<10} {contanti:>9.2f} €")
    out.append(f"  {'= Elettron.':<10} {totale - contanti:>9.2f} €")
    out.append("")

    out.append("⛽ PER PRODOTTO")
    carburanti = 0.0
    for cat, val in sorted(per_categoria.items()):
        out.append(f"  {cat:<14} {val:>9.2f} €")
        if cat in CARBURANTI:
            carburanti += val
    out.append(f"  {'= Carburanti':<14} {carburanti:>9.2f} €")
    out.append(f"  {'= Market/altro':<14} {totale - carburanti:>9.2f} €")

    print("\n".join(out))


def mostra_ultimi(righe):
    notifica_breve(righe)


def mostra_totali(righe):
    riepilogo_chiusura(righe)


def mostra_archivio():
    pattern = os.path.expanduser("~/turno_archivio_*.csv")
    file_archiviati = sorted(glob.glob(pattern), reverse=True)

    out = ["📂 STORICO TURNI ARCHIVIATI:", "─────────────────────────"]
    for path_arc in file_archiviati:
        righe = leggi_csv(path_arc)
        if not righe:
            continue  # turni vuoti: non li mostriamo
        nome_file = os.path.basename(path_arc)
        data_str = nome_file.replace("turno_archivio_", "").replace(".csv", "").replace("_", " ")
        totale_turno, _, _ = calcola_totali(righe)
        out.append(f"• 📅 {data_str} | 💰 {totale_turno:.2f} € ({len(righe)} vendite)")

    if len(out) == 2:
        print("📭 Nessun turno precedente archiviato.")
        return
    print("\n".join(out))


def cancella_ultima():
    righe = leggi_csv()
    if not righe:
        print("Totale: 0.00 € | Vendite: 0\nNessuna transazione da cancellare.")
        return
    scrivi_csv(righe[:-1])
    notifica_breve(righe[:-1])


def cancella_penultima():
    righe = leggi_csv()
    if len(righe) < 2:
        print("Servono almeno 2 transazioni.")
        return
    righe_aggiornate = righe[:-2] + [righe[-1]]
    scrivi_csv(righe_aggiornate)
    notifica_breve(righe_aggiornate)


def chiudi_turno():
    righe = leggi_csv()
    if not righe:
        # Niente da archiviare: evita di creare file d'archivio vuoti
        print("📊 Totale: 0.00 € | Vendite: 0\n────────────────\nNessuna vendita: niente da archiviare.")
        return

    timestamp_backup = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    path_backup = os.path.expanduser(f"~/turno_archivio_{timestamp_backup}.csv")
    shutil.copy(PATH_CSV, path_backup)
    scrivi_csv([])

    riepilogo_chiusura(righe, titolo="🧾 TURNO CHIUSO E ARCHIVIATO")


def main():
    comando = sys.argv[1].lower() if len(sys.argv) > 1 else "notifica"

    if "cancella ultima" in comando or "elimina ultima" in comando:
        cancella_ultima()
    elif "penultima" in comando:
        cancella_penultima()
    elif "chiudi turno" in comando or "fine turno" in comando or "azzera" in comando:
        chiudi_turno()
    elif "archivio" in comando or "storico" in comando:
        mostra_archivio()
    else:
        righe = leggi_csv()
        if comando == "ultimi":
            mostra_ultimi(righe)
        elif comando == "totali":
            mostra_totali(righe)
        else:
            notifica_breve(righe)


if __name__ == "__main__":
    main()
