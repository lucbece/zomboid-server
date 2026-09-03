#!/usr/bin/env python3
"""Cuenta los votos de la encuesta y propone (o aplica) el cambio de configuracion.

Solo stdlib. Se corre en la PC del admin, sobre el votos.jsonl bajado de la VM.

    python3 tally.py                       # cuenta y muestra la propuesta, no toca nada
    python3 tally.py --aplicar             # ademas edita config/ y muestra el diff
    python3 tally.py --votos /tmp/v.jsonl --sandbox /tmp/sb.lua --ini /tmp/s.ini.tpl

Reglas de conteo:
  - de cada persona (identificador normalizado: minusculas, sin acentos) vale SOLO el ultimo
    voto del archivo;
  - en empate gana la opcion que trae el juego por default (no se cambia nada por un empate).
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AQUI = Path(__file__).resolve().parent

ANCHO_BARRA = 24
CLAVE_LOOT = "LootNew*"

# Lineas del SandboxVars: `    Clave = valor,` y `    Tabla = {` / `    },`
RE_ABRE = re.compile(r"^(\s*)([A-Za-z_]\w*)\s*=\s*\{\s*$")
RE_CIERRA = re.compile(r"^\s*\},?\s*$")
RE_ASIGNA = re.compile(r"^(\s*)([A-Za-z_]\w*)(\s*=\s*)(.+?)(,?)(\s*)$")
# Lineas del ini: `Clave=valor` (sin espacios; asi las escribe el juego).
RE_INI = re.compile(r"^([A-Za-z_]\w*)=(.*)$")


def die(msg: str) -> None:
    print(f"tally: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# =================================================================================================
# Lectura de los archivos de config
# =================================================================================================


def indexar_sandbox(lineas: list[str]) -> dict[str, tuple[int, str]]:
    """Mapea 'ZombieLore.Speed' -> (numero de linea, valor actual como texto).

    Lleva una pila con las tablas abiertas para no confundir un `Strength` de ZombieLore con
    el `Strength` de MultiplierConfig: los dos existen y son cosas distintas.
    """
    idx: dict[str, tuple[int, str]] = {}
    pila: list[str] = []
    for i, linea in enumerate(lineas):
        if RE_ABRE.match(linea):
            pila.append(RE_ABRE.match(linea).group(2))
            continue
        if RE_CIERRA.match(linea):
            if pila:
                pila.pop()
            continue
        m = RE_ASIGNA.match(linea)
        if not m:
            continue
        # pila[0] es 'SandboxVars': la ruta que usa preguntas.json arranca adentro.
        ruta = ".".join(pila[1:] + [m.group(2)])
        idx[ruta] = (i, m.group(4))
    return idx


def indexar_ini(lineas: list[str]) -> dict[str, tuple[int, str]]:
    idx: dict[str, tuple[int, str]] = {}
    for i, linea in enumerate(lineas):
        m = RE_INI.match(linea.rstrip("\n"))
        if m:
            idx[m.group(1)] = (i, m.group(2))
    return idx


def reemplazar_sandbox(lineas: list[str], nro: int, valor: str) -> None:
    m = RE_ASIGNA.match(lineas[nro])
    if not m:  # pragma: no cover - el indice se construye con el mismo regex
        die(f"la linea {nro + 1} del SandboxVars ya no tiene la forma esperada")
    sangria, clave, sep, _viejo, coma, cola = m.groups()
    lineas[nro] = f"{sangria}{clave}{sep}{valor}{coma}{cola}"


def reemplazar_ini(lineas: list[str], nro: int, clave: str, valor: str) -> None:
    fin = "\n" if lineas[nro].endswith("\n") else ""
    lineas[nro] = f"{clave}={valor}{fin}"


# =================================================================================================
# Conteo
# =================================================================================================


def normalizar_id(valor: str) -> str:
    """Misma normalizacion que server.py: minusculas, sin espacios de mas y sin acentos."""
    plano = " ".join(valor.split()).casefold()
    return "".join(
        c for c in unicodedata.normalize("NFKD", plano) if not unicodedata.combining(c)
    )


def leer_votos(path: Path) -> list[dict]:
    """Ultimo voto por persona, en el orden en que aparecio la primera vez."""
    ultimo: dict[str, dict] = {}
    try:
        texto = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        die(f"no existe {path}. Bajalo con: make encuesta-resultados")
    except OSError as exc:
        die(f"no se pudo leer {path}: {exc}")
    for nro, linea in enumerate(texto.splitlines(), 1):
        linea = linea.strip()
        if not linea:
            continue
        try:
            voto = json.loads(linea)
        except json.JSONDecodeError:
            print(f"tally: aviso: linea {nro} de {path.name} no es JSON, se ignora")
            continue
        clave = voto.get("id_norm") or normalizar_id(str(voto.get("identificador", "")))
        if not clave or not isinstance(voto.get("respuestas"), dict):
            continue
        # dict conserva el orden de insercion: reasignar no lo mueve al final.
        ultimo[clave] = voto
    return list(ultimo.values())


def ganadora(pregunta: dict, cuenta: Counter) -> dict:
    """Opcion mas votada. En empate gana el default del juego; si el default no empata,
    gana la primera en el orden de preguntas.json (determinista)."""
    opciones = pregunta["opciones"]
    por_default = next(o for o in opciones if o.get("default"))
    if not cuenta:
        return por_default
    tope = max(cuenta.values())
    empatadas = [o for o in opciones if cuenta.get(o["valor"], 0) == tope]
    if por_default in empatadas:
        return por_default
    return empatadas[0]


def barra(n: int, tope: int) -> str:
    if tope <= 0:
        return ""
    largo = max(1, round(n * ANCHO_BARRA / tope)) if n else 0
    return "#" * largo


# =================================================================================================
# Propuesta de cambios
# =================================================================================================


def claves_lootnew(idx_sandbox: dict[str, tuple[int, str]]) -> list[str]:
    """Todas las claves *LootNew del SandboxVars actual, en orden de archivo."""
    encontradas = [k for k in idx_sandbox if k.endswith("LootNew") and "." not in k]
    return sorted(encontradas, key=lambda k: idx_sandbox[k][0])


def calcular_cambios(
    preguntas: list[dict],
    ganadoras: dict[str, dict],
    idx_sandbox: dict[str, tuple[int, str]],
    idx_ini: dict[str, tuple[int, str]],
) -> tuple[list[tuple[str, str, str]], list[tuple[str, str, str]], list[str]]:
    """Devuelve (cambios_sandbox, cambios_ini, avisos). Cada cambio es (clave, viejo, nuevo)."""
    sandbox: list[tuple[str, str, str]] = []
    ini: list[tuple[str, str, str]] = []
    avisos: list[str] = []

    for p in preguntas:
        op = ganadoras[p["id"]]
        valor = op["valor"]

        if p["clave"] == CLAVE_LOOT:
            if valor == "default":
                continue
            for clave in claves_lootnew(idx_sandbox):
                actual = idx_sandbox[clave][1]
                if actual != valor:
                    sandbox.append((clave, actual, valor))
            continue

        if "+" in p["clave"]:  # SleepAllowed+SleepNeeded
            claves = p["clave"].split("+")
            valores = valor.split(",")
            if len(claves) != len(valores):
                avisos.append(f"{p['id']}: la clave y el valor no tienen la misma cantidad de partes")
                continue
            for clave, val in zip(claves, valores):
                destino = idx_ini if p["target"] == "ini" else idx_sandbox
                if clave not in destino:
                    avisos.append(f"{p['id']}: la clave {clave} no esta en el archivo de config")
                    continue
                actual = destino[clave][1]
                if actual != val:
                    (ini if p["target"] == "ini" else sandbox).append((clave, actual, val))
            continue

        destino = idx_ini if p["target"] == "ini" else idx_sandbox
        if p["clave"] not in destino:
            avisos.append(f"{p['id']}: la clave {p['clave']} no esta en el archivo de config")
            continue
        actual = destino[p["clave"]][1]
        if actual != valor:
            (ini if p["target"] == "ini" else sandbox).append((p["clave"], actual, valor))

    return sandbox, ini, avisos


def aplicar(
    lineas: list[str],
    cambios: list[tuple[str, str, str]],
    idx: dict[str, tuple[int, str]],
    es_ini: bool,
) -> None:
    for clave, _viejo, nuevo in cambios:
        nro = idx[clave][0]
        if es_ini:
            reemplazar_ini(lineas, nro, clave, nuevo)
        else:
            reemplazar_sandbox(lineas, nro, nuevo)


def mostrar_diff(path: Path, antes: list[str], despues: list[str]) -> None:
    diff = list(
        difflib.unified_diff(antes, despues, fromfile=f"a/{path.name}", tofile=f"b/{path.name}")
    )
    if not diff:
        print(f"  (sin cambios en {path.name})")
        return
    for linea in diff:
        sys.stdout.write(linea if linea.endswith("\n") else linea + "\n")


# =================================================================================================


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Conteo de la encuesta de reglas.")
    ap.add_argument("--votos", type=Path, default=REPO / "data" / "encuesta" / "votos.jsonl")
    ap.add_argument("--preguntas", type=Path, default=AQUI / "preguntas.json")
    ap.add_argument("--sandbox", type=Path, default=REPO / "config" / "servertest_SandboxVars.lua")
    ap.add_argument("--ini", type=Path, default=REPO / "config" / "servertest.ini.tpl")
    ap.add_argument(
        "--aplicar",
        action="store_true",
        help="escribe los cambios en los archivos de config (sin esto no toca nada)",
    )
    args = ap.parse_args(argv)

    try:
        datos = json.loads(args.preguntas.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"no se pudo leer {args.preguntas}: {exc}")
    preguntas = datos["preguntas"]
    secciones = {s["id"]: s["nombre"] for s in datos["secciones"]}

    try:
        lineas_sandbox = args.sandbox.read_text(encoding="utf-8").splitlines(keepends=True)
        lineas_ini = args.ini.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError as exc:
        die(f"no se pudo leer la config: {exc}")
    idx_sandbox = indexar_sandbox(lineas_sandbox)
    idx_ini = indexar_ini(lineas_ini)

    votos = leer_votos(args.votos)
    if not votos:
        die(f"{args.votos} no tiene ningun voto valido")

    print(f"Encuesta de reglas — {len(votos)} persona(s) votaron")
    print(f"votos:   {args.votos}")
    print(f"config:  {args.sandbox.name} + {args.ini.name}")

    ganadoras: dict[str, dict] = {}
    seccion_actual = None
    for p in preguntas:
        cuenta = Counter()
        for v in votos:
            valor = v["respuestas"].get(p["id"])
            if isinstance(valor, str):
                cuenta[valor] += 1
        gana = ganadora(p, cuenta)
        ganadoras[p["id"]] = gana

        if p["seccion"] != seccion_actual:
            seccion_actual = p["seccion"]
            titulo = secciones.get(seccion_actual, seccion_actual).upper()
            print(f"\n{'=' * 78}\n{titulo}\n{'=' * 78}")

        sin_responder = len(votos) - sum(cuenta.values())
        print(f"\n{p['titulo']}  [{p['clave']}]")
        tope = max(cuenta.values(), default=0)
        for o in p["opciones"]:
            n = cuenta.get(o["valor"], 0)
            marcas = []
            if o.get("default"):
                marcas.append("default")
            if o is gana:
                marcas.append("GANA")
            sufijo = f"  <- {', '.join(marcas)}" if marcas else ""
            print(f"  {o['etiqueta'][:32]:<32} {barra(n, tope):<{ANCHO_BARRA}} {n:>2}{sufijo}")
        if sin_responder:
            print(f"  {'(no contestaron)':<32} {'':<{ANCHO_BARRA}} {sin_responder:>2}")

    comentarios = [(v.get("identificador", "?"), v["comentario"]) for v in votos if v.get("comentario")]
    if comentarios:
        print(f"\n{'=' * 78}\nCOMENTARIOS\n{'=' * 78}")
        for quien, texto in comentarios:
            print(f"\n  {quien}:\n    {texto}")

    cambios_sandbox, cambios_ini, avisos = calcular_cambios(
        preguntas, ganadoras, idx_sandbox, idx_ini
    )

    print(f"\n{'=' * 78}\nPROPUESTA DE CAMBIOS\n{'=' * 78}")
    for aviso in avisos:
        print(f"  AVISO: {aviso}")
    if not cambios_sandbox and not cambios_ini:
        print("\n  Nada que cambiar: la config actual ya es lo que gano la votacion.")
        return 0

    if cambios_sandbox:
        print(f"\n  {args.sandbox.name}")
        for clave, viejo, nuevo in cambios_sandbox:
            print(f"    {clave:<38} {viejo}  ->  {nuevo}")
    if cambios_ini:
        print(f"\n  {args.ini.name}")
        for clave, viejo, nuevo in cambios_ini:
            print(f"    {clave:<38} {viejo}  ->  {nuevo}")

    if not args.aplicar:
        print("\n  Nada se escribio. Para aplicarlo: make encuesta-aplicar")
        return 0

    antes_sandbox = list(lineas_sandbox)
    antes_ini = list(lineas_ini)
    aplicar(lineas_sandbox, cambios_sandbox, idx_sandbox, es_ini=False)
    aplicar(lineas_ini, cambios_ini, idx_ini, es_ini=True)

    try:
        if cambios_sandbox:
            args.sandbox.write_text("".join(lineas_sandbox), encoding="utf-8")
        if cambios_ini:
            args.ini.write_text("".join(lineas_ini), encoding="utf-8")
    except OSError as exc:
        die(f"no se pudo escribir la config: {exc}")

    print(f"\n{'=' * 78}\nDIFF\n{'=' * 78}")
    if cambios_sandbox:
        mostrar_diff(args.sandbox, antes_sandbox, lineas_sandbox)
    if cambios_ini:
        mostrar_diff(args.ini, antes_ini, lineas_ini)
    print("\n  Listo. Revisalo con 'git diff' y aplicalo al server con: make sync RESTART=1")
    print("  Ojo: varias reglas quedan grabadas al crear el mundo (ver README).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
