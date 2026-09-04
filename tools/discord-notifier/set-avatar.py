#!/usr/bin/env python3
"""Sube un avatar a un webhook de Discord o al usuario del bot. Solo stdlib.

    set-avatar.py assets/discord-avatar.png                   # webhook: DISCORD_WEBHOOK_URL del entorno o del .env
    set-avatar.py --bot ~/imagen.png                          # bot: DISCORD_BOT_TOKEN del entorno
    set-avatar.py --webhook-url https://discord.com/api/webhooks/... imagen.png

El avatar del webhook es el que muestran todos los avisos del notificador (no manda avatar por
mensaje). Para el bot, Discord limita los cambios de avatar a unos pocos por hora.
"""
import argparse
import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://discord.com/api/v10"
REPO = Path(__file__).resolve().parents[2]


def leer_env(clave: str) -> str:
    """Valor de una clave del .env del repo (sin ejecutarlo), o '' si no esta."""
    env = REPO / ".env"
    if not env.exists():
        return ""
    for linea in env.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if linea.startswith(clave + "="):
            return linea.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def data_uri(ruta: Path) -> str:
    tipo, _ = mimetypes.guess_type(str(ruta))
    if tipo not in ("image/png", "image/jpeg", "image/gif"):
        sys.exit(f"set-avatar: {ruta}: tiene que ser PNG, JPEG o GIF")
    datos = ruta.read_bytes()
    if len(datos) > 10 * 1024 * 1024:
        sys.exit("set-avatar: la imagen supera los 10 MB")
    return f"data:{tipo};base64,{base64.b64encode(datos).decode('ascii')}"


def patch(url: str, cuerpo: dict, cabeceras: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(cuerpo).encode("utf-8"),
        method="PATCH",
        headers={"Content-Type": "application/json", "User-Agent": "zomboid-server set-avatar", **cabeceras},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        detalle = e.read().decode("utf-8", "replace")[:300]
        sys.exit(f"set-avatar: Discord contesto HTTP {e.code}: {detalle}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("imagen", type=Path, help="PNG, JPEG o GIF; Discord recomienda 512x512 o mas")
    modo = ap.add_mutually_exclusive_group()
    modo.add_argument("--bot", action="store_true", help="cambia el avatar del usuario del bot (DISCORD_BOT_TOKEN)")
    modo.add_argument("--webhook-url", help="URL del webhook (por defecto DISCORD_WEBHOOK_URL del entorno o del .env)")
    args = ap.parse_args()

    if not args.imagen.exists():
        sys.exit(f"set-avatar: no existe {args.imagen}")
    imagen = data_uri(args.imagen)

    if args.bot:
        token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
        if not token:
            sys.exit("set-avatar: falta DISCORD_BOT_TOKEN en el entorno (nunca lo pases por la linea de comandos)")
        datos = patch(f"{API}/users/@me", {"avatar": imagen}, {"Authorization": f"Bot {token}"})
        print(f"set-avatar: avatar del bot {datos.get('username')} actualizado (hash {datos.get('avatar')})")
        return

    url = (args.webhook_url or os.environ.get("DISCORD_WEBHOOK_URL", "") or leer_env("DISCORD_WEBHOOK_URL")).strip()
    if not url.startswith("https://discord.com/api/webhooks/"):
        sys.exit("set-avatar: falta la URL del webhook (--webhook-url, DISCORD_WEBHOOK_URL o el .env)")
    datos = patch(url, {"avatar": imagen}, {})
    print(f"set-avatar: avatar del webhook '{datos.get('name')}' actualizado (hash {datos.get('avatar')})")


if __name__ == "__main__":
    main()
