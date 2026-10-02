# Converte ~/prezzi.json dal vecchio formato {"redbull": 3.0}
# al nuovo {"Red Bull": {"prezzo": 3.0, "alias": [...], "reparto": "Market", "unita": "pz"}}.
# Aggiunge anche i prodotti fissi che mancano (es. fax / fotocopie).
import json, os, shutil

p = os.path.expanduser('~/prezzi.json')
if os.path.exists(p):
    with open(p, encoding='utf-8') as f:
        vecchio = json.load(f)
    if vecchio and not any(isinstance(v, dict) for v in vecchio.values()):
        shutil.copy(p, p + '.vecchio')
        nuovo = {}
        for chiave, prezzo in vecchio.items():
            nome, alias = chiave.replace('_', ' ').title(), [chiave.replace('_', ' ')]
            reparto, unita = 'Market', 'pz'
            if 'adblue' in chiave:
                reparto = 'AdBlue'
                if 'sfuso' in chiave:
                    nome, unita = 'AdBlue sfuso', 'l'
                    alias = ['adblue', 'ad blue', 'adblue sfuso', 'sfuso']
                elif 'tanica' in chiave:
                    nome = 'AdBlue tanica'
                    alias = ['tanica', 'taniche', 'tanica adblue', 'taniche adblue', 'adblue tanica',
                             'adblue taniche', 'tanica di adblue', 'taniche di adblue']
            elif chiave == 'redbull':
                nome, alias = 'Red Bull', ['red bull', 'redbull']
            nuovo[nome] = {'prezzo': float(prezzo), 'alias': alias, 'reparto': reparto, 'unita': unita}
        with open(p, 'w', encoding='utf-8') as f:
            json.dump(nuovo, f, indent=2, ensure_ascii=False)
        print('🔄 prezzi.json convertito al nuovo formato (copia in prezzi.json.vecchio)')

# Prodotti fissi: aggiunti solo se mancano
FISSI = {
    'Fax / fotocopie': {'prezzo': 0.30, 'reparto': 'Fax', 'unita': 'fogli',
                        'alias': ['fax', 'fotocopie', 'fotocopia', 'copie', 'fogli', 'foglio',
                                  'lettera di vettura', 'lettere di vettura', 'cmr', 'delivery']},
}
if os.path.exists(p):
    with open(p, encoding='utf-8') as f:
        listino = json.load(f)
else:
    listino = {}
mancanti = [n for n, v in FISSI.items()
            if not any(isinstance(x, dict) and x.get('reparto') == v['reparto'] for x in listino.values())]
if mancanti:
    for n in mancanti:
        listino[n] = FISSI[n]
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(listino, f, indent=2, ensure_ascii=False)
    print('➕ Aggiunto al listino: ' + ', '.join(mancanti))
