#!/usr/bin/env python3
"""Servidor de la encuesta de reglas de la partida.

Solo stdlib: se copia a la VM y se corre con el python3 del sistema, sin venv ni pip.
No hay base de datos: cada voto es una linea JSON en votos.jsonl.

    python3 server.py                       # 0.0.0.0:8080, datos en ./datos
    python3 server.py --puerto 8080 --datos /opt/zomboid-server/data/encuesta
    ENCUESTA_PUERTO=8080 ENCUESTA_DATOS=/var/tmp/enc python3 server.py

Rutas:
    GET  /                -> index.html
    GET  /preguntas.json  -> la fuente de verdad de las preguntas
    GET  /salud           -> {"ok": true, "votos": N}
    POST /votar           -> {"identificador", "respuestas": {id: valor}, "comentario"}

votos.jsonl NO se sirve por HTTP: los votos se bajan por scp (scripts/encuesta.sh resultados).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import unicodedata
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

AQUI = Path(__file__).resolve().parent

MAX_BODY = 16 * 1024  # 16 KB: un voto completo entra en ~2 KB
MIN_ID = 2
MAX_ID = 80
MAX_COMENTARIO = 500
RATE_LIMITE = 30  # requests
RATE_VENTANA = 60.0  # segundos

# Identificador: un apodo o un mail. Letras (con tildes), numeros, espacio y los signos que
# aparecen en una direccion de correo. No es un login: solo sirve para pisar el voto anterior.
RE_ID = re.compile(r"^[\w .'+@\-]+$", re.UNICODE)


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def normalizar_id(valor: str) -> str:
    """Clave de deduplicacion: sin mayusculas, sin espacios de mas y sin acentos.

    Asi 'Jose', 'JOSÉ ' y 'jose' son la misma persona y el voto nuevo pisa al viejo.
    """
    plano = " ".join(valor.split()).casefold()
    descompuesto = unicodedata.normalize("NFKD", plano)
    return "".join(c for c in descompuesto if not unicodedata.combining(c))


class Encuesta:
    """Preguntas cargadas en memoria + escritura serializada de votos.jsonl."""

    def __init__(self, preguntas_path: Path, datos_dir: Path) -> None:
        self.preguntas_path = preguntas_path
        self.datos_dir = datos_dir
        self.votos_path = datos_dir / "votos.jsonl"
        self._lock = threading.Lock()

        self.preguntas_bytes = preguntas_path.read_bytes()
        datos = json.loads(self.preguntas_bytes.decode("utf-8"))
        self.validos: dict[str, set[str]] = {}
        for p in datos["preguntas"]:
            self.validos[p["id"]] = {o["valor"] for o in p["opciones"]}
        if not self.validos:
            raise ValueError("preguntas.json no tiene preguntas")

        datos_dir.mkdir(parents=True, exist_ok=True)

    def validar(self, cuerpo: object) -> tuple[dict | None, str]:
        """Devuelve (voto, "") o (None, motivo del rechazo)."""
        if not isinstance(cuerpo, dict):
            return None, "el cuerpo tiene que ser un objeto JSON"

        ident = cuerpo.get("identificador")
        if not isinstance(ident, str):
            return None, "falta 'identificador'"
        ident = " ".join(ident.split())
        if len(ident) < MIN_ID:
            return None, f"el nombre o mail tiene que tener al menos {MIN_ID} caracteres"
        if len(ident) > MAX_ID:
            return None, f"el nombre o mail no puede tener mas de {MAX_ID} caracteres"
        if not RE_ID.match(ident):
            return None, "el nombre o mail tiene caracteres no permitidos"

        respuestas = cuerpo.get("respuestas")
        if not isinstance(respuestas, dict) or not respuestas:
            return None, "faltan las respuestas"
        if len(respuestas) > len(self.validos):
            return None, "hay mas respuestas que preguntas"

        limpias: dict[str, str] = {}
        for pid, valor in respuestas.items():
            if pid not in self.validos:
                return None, f"pregunta desconocida: {pid}"
            if not isinstance(valor, str):
                return None, f"el valor de {pid} tiene que ser un string"
            if valor not in self.validos[pid]:
                return None, f"valor invalido para {pid}: {valor}"
            limpias[pid] = valor

        comentario = cuerpo.get("comentario", "")
        if comentario is None:
            comentario = ""
        if not isinstance(comentario, str):
            return None, "'comentario' tiene que ser un string"
        comentario = comentario.strip()[:MAX_COMENTARIO]

        return {
            "identificador": ident,
            "id_norm": normalizar_id(ident),
            "respuestas": limpias,
            "comentario": comentario,
        }, ""

    def guardar(self, voto: dict, ip: str) -> int:
        """Agrega el voto al final del archivo. Devuelve cuantas preguntas contesto."""
        linea = dict(voto)
        linea["ts"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        linea["ip"] = ip
        with self._lock:
            with self.votos_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(linea, ensure_ascii=False) + "\n")
        return len(voto["respuestas"])

    def contar(self) -> int:
        """Cantidad de personas distintas que votaron (para /salud)."""
        ids: set[str] = set()
        try:
            with self.votos_path.open(encoding="utf-8") as fh:
                for linea in fh:
                    linea = linea.strip()
                    if not linea:
                        continue
                    try:
                        ids.add(json.loads(linea).get("id_norm", ""))
                    except json.JSONDecodeError:
                        continue
        except FileNotFoundError:
            return 0
        ids.discard("")
        return len(ids)


class RateLimiter:
    """Ventana deslizante por IP. Sin dependencias: un deque casero por IP."""

    def __init__(self, limite: int, ventana: float) -> None:
        self.limite = limite
        self.ventana = ventana
        self._lock = threading.Lock()
        self._hits: dict[str, list[float]] = {}

    def permitido(self, ip: str) -> bool:
        ahora = time.monotonic()
        corte = ahora - self.ventana
        with self._lock:
            # Limpieza oportunista para que el dict no crezca sin fin.
            if len(self._hits) > 1000:
                self._hits = {k: v for k, v in self._hits.items() if v and v[-1] > corte}
            hits = [t for t in self._hits.get(ip, []) if t > corte]
            if len(hits) >= self.limite:
                self._hits[ip] = hits
                return False
            hits.append(ahora)
            self._hits[ip] = hits
            return True


class Handler(BaseHTTPRequestHandler):
    server_version = "encuesta/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    encuesta: Encuesta
    limiter: RateLimiter
    index_path: Path

    # --- helpers -----------------------------------------------------------------------------

    def _ip(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _responder(self, codigo: int, cuerpo: bytes, ctype: str, cache: str = "no-store") -> None:
        self.send_response(codigo)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(cuerpo)

    def _json(self, codigo: int, datos: dict) -> None:
        cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
        self._responder(codigo, cuerpo, "application/json; charset=utf-8")

    def _error(self, codigo: int, mensaje: str) -> None:
        self._json(codigo, {"ok": False, "error": mensaje})

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 - firma de la stdlib
        log(f"{self._ip()} {fmt % args}")

    # --- rutas -------------------------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 - firma de la stdlib
        if not self.limiter.permitido(self._ip()):
            self._error(HTTPStatus.TOO_MANY_REQUESTS, "Demasiados pedidos. Espera un minuto.")
            return

        ruta = self.path.split("?", 1)[0].rstrip("/") or "/"

        if ruta in ("/", "/index.html"):
            try:
                cuerpo = self.index_path.read_bytes()
            except OSError:
                self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "no se pudo leer index.html")
                return
            self._responder(HTTPStatus.OK, cuerpo, "text/html; charset=utf-8")
            return

        if ruta == "/preguntas.json":
            self._responder(
                HTTPStatus.OK,
                self.encuesta.preguntas_bytes,
                "application/json; charset=utf-8",
            )
            return

        if ruta == "/salud":
            self._json(HTTPStatus.OK, {"ok": True, "votos": self.encuesta.contar()})
            return

        # votos.jsonl y cualquier otra cosa: 404. No hay servidor de archivos estaticos.
        self._error(HTTPStatus.NOT_FOUND, "no existe")

    def do_HEAD(self) -> None:  # noqa: N802 - firma de la stdlib
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802 - firma de la stdlib
        ip = self._ip()
        if not self.limiter.permitido(ip):
            self._error(HTTPStatus.TOO_MANY_REQUESTS, "Demasiados pedidos. Espera un minuto.")
            return

        if self.path.split("?", 1)[0].rstrip("/") != "/votar":
            self._error(HTTPStatus.NOT_FOUND, "no existe")
            return

        try:
            largo = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._error(HTTPStatus.BAD_REQUEST, "Content-Length invalido")
            return
        if largo <= 0:
            self._error(HTTPStatus.BAD_REQUEST, "cuerpo vacio")
            return
        if largo > MAX_BODY:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "el voto es demasiado grande")
            return

        crudo = self.rfile.read(largo)
        try:
            cuerpo = json.loads(crudo.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._error(HTTPStatus.BAD_REQUEST, "el cuerpo no es JSON valido")
            return

        voto, motivo = self.encuesta.validar(cuerpo)
        if voto is None:
            log(f"voto rechazado de {ip}: {motivo}")
            self._error(HTTPStatus.BAD_REQUEST, motivo)
            return

        try:
            cuantas = self.encuesta.guardar(voto, ip)
        except OSError as exc:
            log(f"ERROR guardando el voto: {exc}")
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "no se pudo guardar el voto")
            return

        log(f"voto de {voto['identificador']!r} ({cuantas} respuestas) desde {ip}")
        self._json(
            HTTPStatus.OK,
            {"ok": True, "identificador": voto["identificador"], "respuestas": cuantas},
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Servidor de la encuesta de reglas.")
    p.add_argument(
        "--puerto",
        type=int,
        default=int(os.environ.get("ENCUESTA_PUERTO", "8080")),
        help="puerto TCP (env ENCUESTA_PUERTO, default 8080)",
    )
    p.add_argument(
        "--host",
        default=os.environ.get("ENCUESTA_HOST", "0.0.0.0"),  # noqa: S104 - tiene que ser publico
        help="interfaz donde escuchar (env ENCUESTA_HOST, default 0.0.0.0)",
    )
    p.add_argument(
        "--datos",
        type=Path,
        default=Path(os.environ.get("ENCUESTA_DATOS", AQUI / "datos")),
        help="carpeta donde se escribe votos.jsonl (env ENCUESTA_DATOS)",
    )
    p.add_argument(
        "--preguntas",
        type=Path,
        default=Path(os.environ.get("ENCUESTA_PREGUNTAS", AQUI / "preguntas.json")),
        help="ruta de preguntas.json",
    )
    p.add_argument(
        "--index",
        type=Path,
        default=Path(os.environ.get("ENCUESTA_INDEX", AQUI / "index.html")),
        help="ruta de index.html",
    )
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    for ruta in (args.preguntas, args.index):
        if not ruta.is_file():
            print(f"encuesta: ERROR: no existe {ruta}", file=sys.stderr)
            return 1

    try:
        encuesta = Encuesta(args.preguntas.resolve(), args.datos.resolve())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"encuesta: ERROR: preguntas.json no se pudo cargar: {exc}", file=sys.stderr)
        return 1

    Handler.encuesta = encuesta
    Handler.limiter = RateLimiter(RATE_LIMITE, RATE_VENTANA)
    Handler.index_path = args.index.resolve()

    httpd = ThreadingHTTPServer((args.host, args.puerto), Handler)
    httpd.daemon_threads = True

    log(f"escuchando en http://{args.host}:{args.puerto}")
    log(f"preguntas: {args.preguntas} ({len(encuesta.validos)} preguntas)")
    log(f"votos:     {encuesta.votos_path}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("cortado a mano, cerrando")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
