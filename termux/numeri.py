# Numeri detti a parole -> cifre ("trentacinque" -> 35). Usato da processa_ia.py e info_turno.py.
import re
import unicodedata


def numeri_in_lettere():
    # Costruisce {"venti": 20, "trentacinque": 35, "centoventi": 120, ...} da 1 a 999
    unita = ['', 'uno', 'due', 'tre', 'quattro', 'cinque', 'sei', 'sette', 'otto', 'nove']
    dieci_19 = ['dieci', 'undici', 'dodici', 'tredici', 'quattordici', 'quindici',
                'sedici', 'diciassette', 'diciotto', 'diciannove']
    decine = ['venti', 'trenta', 'quaranta', 'cinquanta', 'sessanta', 'settanta', 'ottanta', 'novanta']
    parole = {}
    for n in range(1, 100):
        if n < 10:
            nomi = [unita[n]]
        elif n < 20:
            nomi = [dieci_19[n - 10]]
        else:
            d, u = decine[n // 10 - 2], unita[n % 10]
            nomi = [d[:-1] + u if u in ('uno', 'otto') else d + u]
            if u == 'tre':
                nomi.append(d + 'tré')
        for nome in nomi:
            parole[nome] = n
    for c in range(1, 10):
        cento = 'cento' if c == 1 else unita[c] + 'cento'
        parole[cento] = c * 100
        for nome, n in list(parole.items()):
            if n < 100:
                parole[cento + nome] = c * 100 + n
                if nome.startswith('o'):
                    parole[cento[:-1] + nome] = c * 100 + n  # centotto
    return parole


_NUMERI = numeri_in_lettere()
_NUMERI.update({'un': 1, 'una': 1})   # "un centesimo", "una ichnusa"
_REGEX = re.compile(r'\b[a-zàèéìòù]+\b')     # ogni parola; si cambia solo se è un numero (più veloce di 2000 alternative)


# Migliaia: "mille", "milleduecento", "duemilacinquecento" (rifornimenti dei camion, versamenti)
_MIGLIAIA = re.compile(r'\b(mille|(?:due|tre|quattro|cinque|sei|sette|otto|nove|dieci)mila)([a-z]*)\b')


def _migliaia(m):
    resto = m.group(2)
    if resto and resto not in _NUMERI:
        return m.group(0)
    migliaia = 1 if m.group(1) == 'mille' else _NUMERI[m.group(1)[:-4]]
    return str(migliaia * 1000 + (_NUMERI[resto] if resto else 0))


def in_cifre(testo):
    """"versamento cinquanta" -> "versamento 50"."""
    testo = _MIGLIAIA.sub(_migliaia, testo.lower())
    testo = _REGEX.sub(lambda m: str(_NUMERI[m.group(0)]) if m.group(0) in _NUMERI else m.group(0), testo)
    # "mille e cinquecento" -> 1500 (non 1000 e 500: due vendite)
    return re.sub(r'\b([1-9]\d?000)\s+e\s+(\d{1,3})\b(?![.,]\d)', lambda m: str(int(m.group(1)) + int(m.group(2))), testo)


def senza_accenti(testo):
    """"estathé" -> "estathe" (i nomi del listino sono senza accenti)."""
    return "".join(c for c in unicodedata.normalize('NFD', testo) if unicodedata.category(c) != 'Mn')
