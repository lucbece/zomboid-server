#!/usr/bin/env python3
"""Alta, listado y baja de los tokens del panel de moderadores.

Corre en la VM (lo llama scripts/panel.sh por ssh) y escribe <datos>/moderadores.json:

    { "<token>": {"nombre": "Fulano", "creado": "2026-09-03T23:00:00+00:00", "activo": true} }

    python3 tokens.py --datos /opt/zomboid-server/data/panel add "Fulano"   # imprime el token
    python3 tokens.py --datos /opt/zomboid-server/data/panel list
    python3 tokens.py --datos /opt/zomboid-server/data/panel revoke "Fulano"

El token es la credencial entera: `add` lo imprime una sola vez, en una linea sola y sin nada
mas, para que scripts/panel.sh arme la URL. `list` NO lo imprime (solo el prefijo): si se
perdio el link hay que revocar y dar uno nuevo.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

LARGO_TOKEN = 32  # bytes de entropia -> 43 caracteres urlsafe


def normalizar(nombre: str) -> str:
    """Clave de comparacion de nombres: sin mayusculas, sin acentos, sin espacios de mas."""
    plano = " ".join(nombre.split()).casefold()
    descompuesto = unicodedata.normalize("NFKD", plano)
    return "".join(c for c in descompuesto if not unicodedata.combining(c))


def cargar(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as fh:
            datos = json.load(fh)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        print(f"tokens: ERROR: {path} no es JSON valido: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    if not isinstance(datos, dict):
        print(f"tokens: ERROR: {path} no es un objeto JSON", file=sys.stderr)
        raise SystemExit(1)
    return datos


def guardar(path: Path, datos: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(datos, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    tmp.chmod(0o600)  # son credenciales: nadie mas que el duenio del servicio
    tmp.replace(path)


def cmd_add(path: Path, nombre: str) -> int:
    nombre = " ".join(nombre.split())
    if len(nombre) < 2 or len(nombre) > 40:
        print("tokens: ERROR: el nombre tiene que tener entre 2 y 40 caracteres", file=sys.stderr)
        return 1
    datos = cargar(path)
    clave = normalizar(nombre)
    for info in datos.values():
        if normalizar(str(info.get("nombre", ""))) == clave and info.get("activo"):
            print(
                f"tokens: ERROR: ya hay un token activo para {nombre!r}. "
                "Revocalo primero si queres uno nuevo.",
                file=sys.stderr,
            )
            return 1
    token = secrets.token_urlsafe(LARGO_TOKEN)
    datos[token] = {
        "nombre": nombre,
        "creado": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "activo": True,
    }
    guardar(path, datos)
    print(token)
    return 0


def cmd_list(path: Path) -> int:
    datos = cargar(path)
    if not datos:
        print("(no hay moderadores cargados)")
        return 0
    filas = sorted(
        ((str(i.get("nombre", "?")), str(i.get("creado", "?")), bool(i.get("activo")), t[:6])
         for t, i in datos.items()),
        key=lambda f: (not f[2], f[0].casefold()),
    )
    print(f"{'NOMBRE':<24} {'ESTADO':<9} {'CREADO':<26} TOKEN")
    for nombre, creado, activo, prefijo in filas:
        print(f"{nombre:<24} {'activo' if activo else 'revocado':<9} {creado:<26} {prefijo}…")
    return 0


def cmd_revoke(path: Path, nombre: str) -> int:
    datos = cargar(path)
    clave = normalizar(nombre)
    tocados = 0
    for info in datos.values():
        if normalizar(str(info.get("nombre", ""))) == clave and info.get("activo"):
            info["activo"] = False
            info["revocado"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
            tocados += 1
    if not tocados:
        print(f"tokens: no habia ningun token activo para {nombre!r}", file=sys.stderr)
        return 1
    guardar(path, datos)
    print(f"tokens: {tocados} token(s) de {nombre!r} revocado(s)")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Tokens del panel de moderadores.")
    p.add_argument(
        "--datos",
        type=Path,
        default=Path("/opt/zomboid-server/data/panel"),
        help="carpeta de datos del panel (default /opt/zomboid-server/data/panel)",
    )
    sub = p.add_subparsers(dest="comando", required=True)
    a = sub.add_parser("add", help="crea un token e imprime SOLO el token")
    a.add_argument("nombre")
    sub.add_parser("list", help="lista los moderadores (sin imprimir los tokens enteros)")
    r = sub.add_parser("revoke", help="desactiva los tokens de un moderador")
    r.add_argument("nombre")
    args = p.parse_args(argv)

    path = args.datos / "moderadores.json"
    if args.comando == "add":
        return cmd_add(path, args.nombre)
    if args.comando == "list":
        return cmd_list(path)
    return cmd_revoke(path, args.nombre)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
