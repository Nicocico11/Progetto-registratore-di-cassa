import json, os, re, shutil, sys

# Converte l'esportazione prodotti di Danea Easyfatt (Prodotti.xlsx) nel listino della cassa vocale.
# Uso: python3 danea_listino.py ~/storage/downloads/Prodotti.xlsx [~/prezzi.json]
# Colonne attese: Categoria, Descrizione, Listino 1 (ivato); se c'è, anche Cod. a barre (per lo scanner).
#
# Per ogni prodotto crea i "nomi a voce" (alias) togliendo formati e misure:
# "COCA COLA BOTT 400" -> "coca cola". I nomi extra si aggiungono in ALIAS_EXTRA qui sotto.

ESCLUSE = {'CARBURANTI'}  # i carburanti si dettano come "20 di gasolio", non dal listino

# Nome Danea -> nomi detti a voce in più
ALIAS_EXTRA = {
    'RED BULL': ['red bull', 'redbull'],
    'ACQUA BOTT 0,500': ['acqua piccola', 'acqua naturale', 'bottiglietta acqua', 'acqua'],
    'ACQUA CONFEZ.1,5 LITRI': ['acqua grande', 'acqua big', 'acqua 1 litro e mezzo'],
    'BOX 6 BOTTIGLIE ACQUA': ['box acqua', 'confezione acqua'],
    'COCA COLA BOTT 400': ['coca', 'coca cola', 'cocacola'],
    'FANTA 0,400 CL': ['fanta'],
    'ESTATHE BRICK': ['estathe', 'estate', 'the brick'],
    'ESTA THE LIMONE PESCA': ['estathe bottiglia', 'the limone', 'the pesca'],
    'GHIACCIOLO': ['ghiaccioli', 'ghiacciolo'],
    'SNIKERS': ['snickers'],
    'M E MS': ['m&m', 'emmenems', 'm and m'],
    'KINDERE CIOCCOLATO': ['kinder cioccolato'],
    'SRTUDIDI FICHI': ['strudel di fichi', 'strudel'],
    'PRINGLESS MGUSTI VARI': ['pringles'],
    'PATATINA AMICA CHIPS': ['patatine', 'amica chips'],
}
SPECIALI = {
    'ADBLUE SFUSO': {'nome': 'AdBlue sfuso', 'reparto': 'AdBlue', 'unita': 'l',
                     'alias': ['adblue', 'ad blue', 'adblue sfuso', 'sfuso']},
    'TANICA ADBLUE': {'nome': 'AdBlue tanica', 'reparto': 'AdBlue', 'unita': 'pz',
                      'alias': ['tanica adblue', 'taniche adblue', 'adblue tanica',
                                'adblue taniche', 'tanica di adblue', 'taniche di adblue']},
    'TEFAX': {'nome': 'Fax / fotocopie', 'reparto': 'Fax', 'unita': 'fogli',
              'alias': ['fax', 'telefax', 'fotocopie', 'fotocopia', 'copie', 'fogli', 'foglio',
                        'lettera di vettura', 'lettere di vettura', 'cmr', 'delivery']},
}
# Parole che non possono essere il nome di un prodotto da sole (carburanti, pagamenti, comandi)
RISERVATE = {'verde', 'benzina', 'gasolio', 'diesel', 'carta', 'pos', 'bancomat', 'contanti', 'cash', 'nero', 'bianco', 'cassa',
             'euro', 'litri', 'litro', 'turno', 'ultima', 'penultima', 'totali', 'market', 'ia',
             'set', 'kit', 'mini', 'big', 'plus', 'pro', 'per', 'con', 'di', 'da'}
# Parole di formato che non si dicono a voce
FORMATO = {'bott', 'bott.', 'conf', 'conf.', 'confez', 'confez.', 'brick', 'pz', 'pezzi', 'ml', 'cl', 'lt',
           'gr', 'kg', 'cm', 'mm', 'x', 'formato'}


def alias_da_nome(descrizione):
    """Due nomi a voce: senza codici ("lampadina") e con i codici ("lampadina h7")."""
    corto, lungo = [], []
    for p in re.split(r'[\s/]+', descrizione.lower()):
        p = p.strip('.,;:()')
        if not p or p in FORMATO:
            continue
        if re.search(r'\d', p):
            if re.search(r'[a-z]', p) and not re.fullmatch(r'[\d.,]+(ml|cl|lt|l|gr|g|kg|cm|mm|m|w|x)', p):
                lungo.append(p)  # codice tipo h7, p21w, 5w-40: aiuta a distinguere
            continue             # misure (0,500 / 400 / 150ml) non si dicono
        corto.append(p)
        lungo.append(p)
    alias = []
    for a in (" ".join(corto), " ".join(lungo)):
        if len(a) >= 3 and a not in RISERVATE and a not in alias:
            alias.append(a)
    return alias


def converti(path_xlsx):
    import openpyxl
    ws = openpyxl.load_workbook(path_xlsx, read_only=True).active
    righe = list(ws.iter_rows(values_only=True))
    intest = [str(c or '').strip().lower() for c in righe[0]]
    i_cat = intest.index('categoria')
    i_desc = intest.index('descrizione')
    i_prezzo = next(i for i, c in enumerate(intest) if c.startswith('listino'))
    i_barre = next((i for i, c in enumerate(intest) if 'barre' in c), None)

    listino, saltati = {}, []
    for r in righe[1:]:
        desc = str(r[i_desc] or '').strip()
        cat = str(r[i_cat] or '').strip().upper()
        prezzo = r[i_prezzo]
        if not desc or r[0] == '-':
            continue  # righe di intestazione categoria
        if cat in ESCLUSE:
            continue
        if not isinstance(prezzo, (int, float)) or prezzo <= 0:
            saltati.append(desc)
            continue
        barre = str(r[i_barre] or '').strip() if i_barre is not None else ''
        barre = barre[:-2] if barre.endswith('.0') else barre      # numero letto da Excel come 8.05e12
        if desc.upper() in SPECIALI:
            s = SPECIALI[desc.upper()]
            listino[s['nome']] = {'prezzo': float(prezzo), 'alias': s['alias'],
                                  'reparto': s['reparto'], 'unita': s['unita'], 'danea': desc}
            if barre:
                listino[s['nome']]['barre'] = barre
            continue
        alias = alias_da_nome(desc) + ALIAS_EXTRA.get(desc.upper(), [])
        if not alias:
            saltati.append(desc)
            continue
        listino[desc.upper()] = {'prezzo': float(prezzo), 'alias': sorted(set(alias)),
                                 'reparto': 'Market', 'unita': 'pz', 'categoria': cat or 'ALTRO'}
        if barre:
            listino[desc.upper()]['barre'] = barre
    return listino, saltati


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Uso: python3 danea_listino.py Prodotti.xlsx [prezzi.json]")
        sys.exit(1)
    destinazione = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else '~/prezzi.json')
    listino, saltati = converti(os.path.expanduser(sys.argv[1]))
    if os.path.exists(destinazione):
        shutil.copy(destinazione, destinazione + '.vecchio')
    with open(destinazione, 'w', encoding='utf-8') as f:
        json.dump(listino, f, indent=1, ensure_ascii=False)
    print(f"✅ Listino creato: {len(listino)} prodotti in {destinazione}")
    if saltati:
        print(f"⚠️ Saltati {len(saltati)} prodotti senza prezzo o senza nome utilizzabile: {', '.join(saltati[:10])}")
