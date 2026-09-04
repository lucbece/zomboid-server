#!/usr/bin/env python3
"""Compara la fecha de actualizacion de cada mod en el Workshop con la instalada.

    comparar.py <appworkshop_108600.acf> <respuesta-api.json> <workshop_id> [...]

Sale por stdout una linea TSV por mod pedido:

    <workshop_id>\t<titulo>\t<time_updated>\t<timeupdated_instalado>\t<estado>

con estado en {al-dia, desactualizado, no-instalado, sin-datos}. Con --tabla imprime lo
mismo en una tabla para leer a ojo (lo usa `make mods-check`).

Codigos de salida: 0 si la comparacion es utilizable, 3 si la respuesta de la API no sirve
(JSON roto, sin publishedfiledetails, o ningun item resuelto). El que llama no debe actuar
con 3: no se sabe nada, y actuar seria reiniciar el server a ciegas.

Solo stdlib: corre con el python3 que ya trae la VM.
"""

import json
import re
import sys
import time

# El .acf es VDF (el formato de Valve): pares "clave" "valor" y bloques "clave" { ... }.
# Se tokeniza en vez de parsearse con un regex por item porque los ids anidan un nivel mas
# adentro que el resto y un regex plano confunde "timeupdated" del item con el del appid.
TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|(\{)|(\})')

ESTADOS = ("al-dia", "desactualizado", "no-instalado", "sin-datos")


def leer_instalados(ruta):
    """{workshop_id: timeupdated} desde el bloque WorkshopItemsInstalled del .acf."""
    try:
        with open(ruta, encoding="utf-8", errors="replace") as fh:
            texto = fh.read()
    except OSError:
        return {}

    instalados = {}
    pila = []
    clave_pendiente = None
    for m in TOKEN.finditer(texto):
        cadena, abre, cierra = m.group(1), m.group(2), m.group(3)
        if cadena is not None:
            if clave_pendiente is None:
                clave_pendiente = cadena
            else:
                if (len(pila) >= 2 and pila[-2] == "WorkshopItemsInstalled"
                        and clave_pendiente == "timeupdated"):
                    try:
                        instalados[pila[-1]] = int(cadena)
                    except ValueError:
                        pass
                clave_pendiente = None
        elif abre:
            pila.append(clave_pendiente if clave_pendiente is not None else "")
            clave_pendiente = None
        else:
            if pila:
                pila.pop()
            clave_pendiente = None
    return instalados


def leer_api(ruta):
    """{workshop_id: (titulo, time_updated)} desde la respuesta de la API de Steam.

    Devuelve None si la respuesta no se puede usar en absoluto.
    """
    try:
        with open(ruta, encoding="utf-8", errors="replace") as fh:
            datos = json.load(fh)
    except (OSError, ValueError):
        return None

    detalles = (datos or {}).get("response", {}).get("publishedfiledetails")
    if not isinstance(detalles, list) or not detalles:
        return None

    por_id = {}
    for d in detalles:
        if not isinstance(d, dict):
            continue
        pid = str(d.get("publishedfileid", ""))
        # result 1 = ok. Un item borrado o privado del Workshop devuelve otro codigo y no
        # trae time_updated: se deja afuera y queda como sin-datos.
        if not pid or d.get("result") != 1:
            continue
        ts = d.get("time_updated")
        if not isinstance(ts, int):
            continue
        por_id[pid] = (str(d.get("title") or pid), ts)
    return por_id or None


def fecha(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts)) + "Z" if ts else "-"


def main(argv):
    tabla = "--tabla" in argv
    argv = [a for a in argv if a != "--tabla"]
    if len(argv) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    acf, api_json, ids = argv[1], argv[2], argv[3:]

    api = leer_api(api_json)
    if api is None:
        print("comparar: la respuesta de la API de Steam no sirve", file=sys.stderr)
        return 3
    instalados = leer_instalados(acf)

    filas = []
    for wid in ids:
        if wid not in api:
            filas.append((wid, wid, 0, instalados.get(wid, 0), "sin-datos"))
            continue
        titulo, ts_steam = api[wid]
        ts_local = instalados.get(wid)
        if ts_local is None:
            filas.append((wid, titulo, ts_steam, 0, "no-instalado"))
        elif ts_steam > ts_local:
            filas.append((wid, titulo, ts_steam, ts_local, "desactualizado"))
        else:
            filas.append((wid, titulo, ts_steam, ts_local, "al-dia"))

    if tabla:
        ancho = max([len(f[1]) for f in filas] + [6])
        ancho = min(ancho, 44)
        print(f"{'WORKSHOP ID':<12} {'TITULO':<{ancho}} {'EN STEAM':<18} "
              f"{'INSTALADO':<18} ESTADO")
        for wid, titulo, ts_steam, ts_local, estado in filas:
            corto = titulo if len(titulo) <= ancho else titulo[:ancho - 1] + "…"
            print(f"{wid:<12} {corto:<{ancho}} {fecha(ts_steam):<18} "
                  f"{fecha(ts_local):<18} {estado}")
        n = sum(1 for f in filas if f[4] == "desactualizado")
        otros = sum(1 for f in filas if f[4] in ("no-instalado", "sin-datos"))
        print()
        print(f"{len(filas)} mods: {len(filas) - n - otros} al dia, {n} desactualizados"
              + (f", {otros} sin datos o sin instalar" if otros else ""))
    else:
        for fila in filas:
            print("\t".join(str(c) for c in fila))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
