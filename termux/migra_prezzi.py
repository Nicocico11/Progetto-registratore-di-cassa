# Converte ~/prezzi.json dal vecchio formato {"redbull": 3.0}
# al nuovo {"Red Bull": {"prezzo": 3.0, "alias": [...], "reparto": "Market", "unita": "pz"}}.
# Se è già nel nuovo formato non fa nulla.
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
