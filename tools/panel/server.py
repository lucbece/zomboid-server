#!/usr/bin/env python3
"""Panel de moderadores: una pagina con el estado del server y un boton para reiniciarlo.

Solo stdlib, igual que tools/encuesta/server.py: se copia a la VM y corre con el python3 del
sistema, sin venv ni pip. No hay base de datos ni sesiones: la URL ES la credencial.

    python3 server.py                       # 0.0.0.0:8081, datos en ./datos
    python3 server.py --puerto 8081 --datos /opt/zomboid-server/data/panel
    PANEL_PUERTO=8081 PANEL_DATOS=/var/tmp/panel python3 server.py

Rutas:
    GET  /m/<token>          -> pagina con el estado y el boton
    POST /m/<token>/restart  -> lanza scripts/restart.sh desacoplado del request
    GET  /salud              -> {"ok": true, ...}  (no expone ningun token)
    cualquier otra cosa      -> 404 generico

Un token invalido devuelve el MISMO 404 que una ruta que no existe: desde afuera no se puede
distinguir "no existe el panel" de "el token esta mal".

GET nunca ejecuta nada. Los previews de links de WhatsApp/Discord/Slack hacen GET (a veces
varias veces), asi que el reinicio solo puede salir de un POST con el token en la ruta.

Los tokens viven en <datos>/moderadores.json, que crea y edita tools/panel/tokens.py.
Cada accion queda en <datos>/acciones.jsonl y el ultimo reinicio en <datos>/estado.json.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

AQUI = Path(__file__).resolve().parent

MAX_BODY = 4 * 1024  # el POST del boton no lleva cuerpo; el margen es por si un cliente manda uno
RATE_LIMITE = 30  # requests
RATE_VENTANA = 60.0  # segundos
CACHE_ESTADO = 5.0  # segundos que se reusa el estado (docker + rcon) entre GETs seguidos
TIMEOUT_CMD = 15  # segundos para docker/rcon; el reinicio en si no espera

# Un token urlsafe de 32 bytes son 43 caracteres. El rango es amplio a proposito: si algun dia
# cambia el largo, los tokens viejos siguen entrando por esta puerta.
RE_TOKEN = re.compile(r"^[A-Za-z0-9_-]{20,128}$")
RE_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
RE_JUGADORES = re.compile(r"Players connected \((\d+)\)")

# Lo que se le manda al chat del juego no puede llevar comillas ni backslashes: viaja como un
# argumento de mcrcon dentro de servermsg "...".
RE_NOMBRE_CHAT = re.compile(r'["\\\r\n]')


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def ahora_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def hace_cuanto(segundos: float) -> str:
    """'hace 3 minutos' en castellano, sin librerias."""
    seg = int(max(0, segundos))
    if seg < 60:
        return "hace menos de un minuto"
    minutos = seg // 60
    if minutos < 60:
        return f"hace {minutos} minuto{'s' if minutos != 1 else ''}"
    horas = minutos // 60
    if horas < 24:
        return f"hace {horas} hora{'s' if horas != 1 else ''}"
    dias = horas // 24
    return f"hace {dias} dia{'s' if dias != 1 else ''}"


def falta(segundos: float) -> str:
    seg = int(max(0, segundos))
    if seg < 60:
        return f"{seg} segundos"
    minutos = (seg + 59) // 60
    return f"{minutos} minuto{'s' if minutos != 1 else ''}"


# =================================================================================================
# Moderadores
# =================================================================================================


class Moderadores:
    """moderadores.json cargado en memoria, recargado cuando cambia el mtime.

    Asi `scripts/panel.sh token add` no necesita reiniciar el servicio para que el token nuevo
    funcione.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._mtime = -1.0
        self._datos: dict[str, dict] = {}

    def _recargar(self) -> None:
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            self._datos = {}
            self._mtime = -1.0
            return
        if mtime == self._mtime:
            return
        try:
            with self.path.open(encoding="utf-8") as fh:
                datos = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            log(f"ERROR leyendo {self.path}: {exc}")
            return
        if not isinstance(datos, dict):
            log(f"ERROR: {self.path} no es un objeto JSON")
            return
        self._datos = {k: v for k, v in datos.items() if isinstance(v, dict)}
        self._mtime = mtime
        log(f"moderadores.json recargado: {len(self._datos)} tokens")

    def buscar(self, token: str) -> dict | None:
        """Devuelve el moderador activo cuyo token coincide, o None.

        La comparacion es con hmac.compare_digest contra todos los tokens: no corta en el
        primero que difiere y no filtra por prefijo.
        """
        import hmac

        with self._lock:
            self._recargar()
            entradas = list(self._datos.items())
        encontrado = None
        for guardado, info in entradas:
            if hmac.compare_digest(guardado, token):
                encontrado = info
        if encontrado is None or not encontrado.get("activo", False):
            return None
        return encontrado

    def cantidad_activos(self) -> int:
        with self._lock:
            self._recargar()
            return sum(1 for v in self._datos.values() if v.get("activo", False))


# =================================================================================================
# Estado del panel (ultimo reinicio, cooldowns) y del server de juego
# =================================================================================================


class Panel:
    """Todo lo que el handler necesita: rutas, cooldowns, el proceso de reinicio y el estado."""

    def __init__(
        self,
        datos_dir: Path,
        repo_dir: Path,
        restart_cmd: str,
        rcon_cmd: str,
        log_reinicio: Path,
        cooldown: int,
        cooldown_mod: int,
    ) -> None:
        self.datos_dir = datos_dir
        self.repo_dir = repo_dir
        self.restart_cmd = restart_cmd
        self.rcon_cmd = rcon_cmd
        self.log_reinicio = log_reinicio
        self.cooldown = cooldown
        self.cooldown_mod = cooldown_mod

        datos_dir.mkdir(parents=True, exist_ok=True)
        self.moderadores = Moderadores(datos_dir / "moderadores.json")
        self.acciones_path = datos_dir / "acciones.jsonl"
        self.estado_path = datos_dir / "estado.json"

        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._cache: tuple[float, dict] | None = None
        self._estado = self._leer_estado()

    # --- persistencia -----------------------------------------------------------------------

    def _leer_estado(self) -> dict:
        try:
            with self.estado_path.open(encoding="utf-8") as fh:
                datos = json.load(fh)
            if isinstance(datos, dict):
                datos.setdefault("ultimo", None)
                datos.setdefault("por_moderador", {})
                return datos
        except (OSError, json.JSONDecodeError):
            pass
        return {"ultimo": None, "por_moderador": {}}

    def _guardar_estado(self) -> None:
        tmp = self.estado_path.with_suffix(".json.tmp")
        try:
            with tmp.open("w", encoding="utf-8") as fh:
                json.dump(self._estado, fh, ensure_ascii=False, indent=2)
            tmp.replace(self.estado_path)
        except OSError as exc:
            log(f"ERROR guardando {self.estado_path}: {exc}")

    def registrar(self, nombre: str, ip: str, accion: str, resultado: str) -> None:
        linea = {
            "ts": ahora_iso(),
            "nombre": nombre,
            "ip": ip,
            "accion": accion,
            "resultado": resultado,
        }
        try:
            with self.acciones_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(linea, ensure_ascii=False) + "\n")
        except OSError as exc:
            log(f"ERROR escribiendo acciones.jsonl: {exc}")
        log(f"{accion} {resultado} nombre={nombre!r} ip={ip}")

    # --- cooldown ---------------------------------------------------------------------------

    def reinicio_en_curso(self) -> bool:
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    def espera(self, nombre: str) -> tuple[float, str]:
        """Segundos que faltan para poder reiniciar y el motivo ('' si se puede ya)."""
        ahora = time.time()
        with self._lock:
            ultimo = self._estado.get("ultimo") or {}
            propio = (self._estado.get("por_moderador") or {}).get(nombre, 0)
        resta_global = self.cooldown - (ahora - float(ultimo.get("epoch", 0) or 0))
        resta_propia = self.cooldown_mod - (ahora - float(propio or 0))
        if resta_propia > 0 and resta_propia >= resta_global:
            return resta_propia, "propio"
        if resta_global > 0:
            return resta_global, "global"
        return 0.0, ""

    def ultimo_reinicio(self) -> dict | None:
        with self._lock:
            ultimo = self._estado.get("ultimo")
        return dict(ultimo) if isinstance(ultimo, dict) else None

    # --- reinicio ---------------------------------------------------------------------------

    def _abrir_log(self):
        """Log del reinicio. Si no se puede escribir donde pide la unit, cae a datos/."""
        for destino in (self.log_reinicio, self.datos_dir / "panel-restart.log"):
            try:
                destino.parent.mkdir(parents=True, exist_ok=True)
                return destino.open("a", encoding="utf-8"), destino
            except OSError as exc:
                log(f"ADVERTENCIA: no se pudo abrir {destino}: {exc}")
        return None, None

    def avisar_por_chat(self, nombre: str) -> None:
        """servermsg con quien pidio el reinicio.

        La cuenta regresiva la hace scripts/stop.sh (WARN_SECONDS=60, y la omite si no hay
        nadie conectado): aca solo se agrega el dato que stop.sh no tiene, que es el nombre.
        """
        limpio = RE_NOMBRE_CHAT.sub("", nombre)[:40]
        cmd = shlex.split(self.rcon_cmd) + [
            f'servermsg "Reinicio del servidor solicitado por {limpio}."'
        ]
        try:
            subprocess.run(  # noqa: S603 - comando fijo, el nombre va saneado
                cmd,
                cwd=self.repo_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=TIMEOUT_CMD,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            log(f"ADVERTENCIA: no se pudo avisar por RCON: {exc}")

    def lanzar_reinicio(self, nombre: str) -> tuple[bool, str]:
        """Arranca restart.sh desacoplado del request. Devuelve (ok, motivo del rechazo)."""
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return False, "ya hay un reinicio en curso"
            ahora = time.time()
            ultimo = self._estado.get("ultimo") or {}
            if ahora - float(ultimo.get("epoch", 0) or 0) < self.cooldown:
                return False, "cooldown"
            if ahora - float((self._estado.get("por_moderador") or {}).get(nombre, 0) or 0) < self.cooldown_mod:
                return False, "cooldown"

            # Se marca ANTES de lanzar: si dos moderadores tocan el boton a la vez, el segundo
            # ya encuentra el cooldown puesto.
            self._estado["ultimo"] = {"ts": ahora_iso(), "epoch": ahora, "nombre": nombre}
            self._estado.setdefault("por_moderador", {})[nombre] = ahora
            self._guardar_estado()
            self._cache = None

        self.avisar_por_chat(nombre)

        fh, destino = self._abrir_log()
        cmd = shlex.split(self.restart_cmd)
        try:
            if fh is not None:
                fh.write(f"\n===== {ahora_iso()} reinicio pedido por {nombre} =====\n")
                fh.flush()
            proc = subprocess.Popen(  # noqa: S603 - comando fijo (PANEL_RESTART_CMD)
                cmd,
                cwd=self.repo_dir,
                stdin=subprocess.DEVNULL,
                stdout=fh or subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
                start_new_session=True,  # sobrevive a que el request (y el panel) se corten
            )
        except OSError as exc:
            log(f"ERROR lanzando {cmd}: {exc}")
            if fh is not None:
                fh.close()
            return False, f"no se pudo lanzar el reinicio: {exc}"
        finally:
            # El hijo se queda con su propio descriptor; el padre no lo necesita mas.
            if fh is not None:
                try:
                    fh.close()
                except OSError:
                    pass

        with self._lock:
            self._proc = proc
        log(f"reinicio lanzado (pid {proc.pid}) por {nombre!r}, log en {destino}")
        return True, ""

    # --- estado del juego -------------------------------------------------------------------

    def _correr(self, cmd: list[str]) -> tuple[int, str]:
        try:
            res = subprocess.run(  # noqa: S603 - comandos fijos
                cmd,
                cwd=self.repo_dir,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_CMD,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return 1, f"{exc}"
        return res.returncode, RE_ANSI.sub("", res.stdout or "")

    def estado_juego(self) -> dict:
        """{'estado': 'arriba'|'arrancando'|'abajo'|'desconocido', 'jugadores': [...]}.

        Cachea unos segundos: cada refresh de la pagina no puede disparar un docker+rcon.
        """
        ahora = time.monotonic()
        with self._lock:
            if self._cache is not None and ahora - self._cache[0] < CACHE_ESTADO:
                return self._cache[1]

        contenedor = False
        rc, salida = self._correr(["docker", "compose", "ps", "-q", "--status", "running", "zomboid"])
        if rc == 0:
            contenedor = bool(salida.strip())
        else:
            log(f"ADVERTENCIA: docker compose ps fallo: {salida.strip()[:200]}")

        jugadores: list[str] = []
        estado = "abajo"
        if contenedor:
            estado = "arrancando"
            rc, salida = self._correr(shlex.split(self.rcon_cmd) + ["players"])
            m = RE_JUGADORES.search(salida)
            if rc == 0 and m:
                estado = "arriba"
                for linea in salida.splitlines():
                    linea = linea.strip()
                    if linea.startswith("-") and len(linea) > 1:
                        jugadores.append(linea[1:].strip())
        elif rc != 0:
            estado = "desconocido"

        datos = {"estado": estado, "jugadores": jugadores}
        with self._lock:
            self._cache = (time.monotonic(), datos)
        return datos


# =================================================================================================
# Rate limit (mismo patron que la encuesta)
# =================================================================================================


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
            if len(self._hits) > 1000:
                self._hits = {k: v for k, v in self._hits.items() if v and v[-1] > corte}
            hits = [t for t in self._hits.get(ip, []) if t > corte]
            if len(hits) >= self.limite:
                self._hits[ip] = hits
                return False
            hits.append(ahora)
            self._hits[ip] = hits
            return True


# =================================================================================================
# HTML
# =================================================================================================


def render(plantilla: str, **campos: str) -> bytes:
    salida = plantilla
    for clave, valor in campos.items():
        salida = salida.replace("{{" + clave + "}}", valor)
    return salida.encode("utf-8")


def bloque_estado(juego: dict) -> str:
    estado = juego["estado"]
    jugadores = juego["jugadores"]
    if estado == "arriba":
        n = len(jugadores)
        if n:
            detalle = "Conectados: " + ", ".join(html.escape(j) for j in jugadores)
        else:
            detalle = "Nadie conectado en este momento."
        return (
            '<p class="linea"><span class="punto ok"></span><b>El servidor está en línea</b></p>'
            f'<p class="detalle">{detalle}</p>'
        )
    if estado == "arrancando":
        return (
            '<p class="linea"><span class="punto tibio"></span><b>El servidor está arrancando</b></p>'
            '<p class="detalle">El contenedor está corriendo pero todavía no responde a RCON. '
            "Suele tardar uno o dos minutos.</p>"
        )
    if estado == "abajo":
        return (
            '<p class="linea"><span class="punto mal"></span><b>El servidor está apagado</b></p>'
            '<p class="detalle">El botón lo levanta de nuevo.</p>'
        )
    return (
        '<p class="linea"><span class="punto mal"></span><b>Estado desconocido</b></p>'
        '<p class="detalle">No se pudo consultar a Docker desde el panel. Avisale al admin.</p>'
    )


def pagina_estado(panel: Panel, token: str, nombre: str, mensaje: str = "") -> str:
    juego = panel.estado_juego()
    en_curso = panel.reinicio_en_curso()
    restan, motivo = panel.espera(nombre)
    ultimo = panel.ultimo_reinicio()

    partes = [bloque_estado(juego)]

    if ultimo:
        cuando = hace_cuanto(time.time() - float(ultimo.get("epoch", 0) or 0))
        quien = html.escape(str(ultimo.get("nombre", "?")))
        partes.append(f'<p class="dato">Último reinicio: {cuando}, a pedido de <b>{quien}</b>.</p>')
    else:
        partes.append('<p class="dato">Sin reinicios registrados desde este panel.</p>')

    if mensaje:
        partes.append(f'<p class="aviso">{html.escape(mensaje)}</p>')

    accion = f"/m/{html.escape(token)}/restart"
    if en_curso:
        partes.append(
            '<p class="aviso">Hay un reinicio en curso. Esperá a que termine, tarda unos dos '
            "minutos.</p>"
            '<button class="boton" type="button" disabled>Reinicio en curso</button>'
        )
    elif restan > 0:
        texto = (
            "Ya reiniciaste hace poco."
            if motivo == "propio"
            else "El servidor se reinició hace poco."
        )
        partes.append(
            f'<p class="aviso">{texto} El botón se habilita en {falta(restan)}.</p>'
            '<button class="boton" type="button" disabled>Reiniciar servidor</button>'
        )
    else:
        partes.append(
            f'<form method="post" action="{accion}">'
            '<button class="boton" type="submit">Reiniciar servidor</button>'
            "</form>"
            '<p class="pie">Apaga el servidor de forma limpia (aviso a los jugadores, guardado '
            "del mundo) y lo vuelve a levantar. Tarda unos dos minutos. No borra nada.</p>"
        )

    partes.append(
        f'<p class="pie"><a href="/m/{html.escape(token)}">Actualizar el estado</a></p>'
    )
    return '<div class="tarjeta">' + "\n".join(partes) + "</div>"


def pagina_lanzado(token: str) -> str:
    return (
        '<div class="tarjeta">'
        '<p class="linea"><span class="punto tibio"></span><b>Reinicio en curso</b></p>'
        '<p class="detalle">Se avisó a los jugadores, se guarda el mundo y el servidor arranca '
        "de nuevo. Tarda unos dos minutos.</p>"
        '<p class="dato">No hace falta que toques nada más. Si en cinco minutos el servidor '
        "sigue caído, avisale al admin.</p>"
        f'<p class="pie"><a href="/m/{html.escape(token)}">Volver al estado</a></p>'
        "</div>"
    )


# =================================================================================================
# Handler
# =================================================================================================


class Handler(BaseHTTPRequestHandler):
    server_version = "panel/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    panel: Panel
    limiter: RateLimiter
    plantilla: str
    server_name_html: str

    # --- helpers -----------------------------------------------------------------------------

    def _ip(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _responder(self, codigo: int, cuerpo: bytes, ctype: str) -> None:
        self.send_response(codigo)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        # La URL es la credencial: que no se filtre por Referer ni la indexe nadie.
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(cuerpo)

    def _html(self, codigo: int, titulo: str, cuerpo: str, refresco: str = "") -> None:
        pagina = render(
            self.plantilla,
            SERVER_NAME=self.server_name_html,
            TITULO=html.escape(titulo),
            CUERPO=cuerpo,
            REFRESCO=refresco,
        )
        self._responder(codigo, pagina, "text/html; charset=utf-8")

    def _json(self, codigo: int, datos: dict) -> None:
        cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
        self._responder(codigo, cuerpo, "application/json; charset=utf-8")

    def _404(self) -> None:
        """404 identico para ruta inexistente y token invalido: no confirma nada."""
        self._responder(HTTPStatus.NOT_FOUND, b"404 Not Found\n", "text/plain; charset=utf-8")

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 - firma de la stdlib
        # El token viaja en la ruta: se recorta para que no quede escrito en el journal.
        linea = fmt % args
        linea = re.sub(r"/m/[A-Za-z0-9_-]+", "/m/<token>", linea)
        log(f"{self._ip()} {linea}")

    def _ruta(self) -> str:
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def _moderador(self, token: str) -> dict | None:
        if not RE_TOKEN.match(token):
            return None
        return self.panel.moderadores.buscar(token)

    # --- rutas -------------------------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 - firma de la stdlib
        if not self.limiter.permitido(self._ip()):
            self._responder(
                HTTPStatus.TOO_MANY_REQUESTS,
                b"429 Too Many Requests\n",
                "text/plain; charset=utf-8",
            )
            return

        ruta = self._ruta()

        if ruta == "/salud":
            juego = self.panel.estado_juego()
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "servidor": juego["estado"],
                    "jugadores": len(juego["jugadores"]),
                    "moderadores": self.panel.moderadores.cantidad_activos(),
                    "reinicio_en_curso": self.panel.reinicio_en_curso(),
                    "ultimo_reinicio": (self.panel.ultimo_reinicio() or {}).get("ts"),
                },
            )
            return

        partes = ruta.strip("/").split("/")
        # GET /m/<token>. Nada mas cuelga de /m/: /m/<token>/restart por GET es 404 a proposito,
        # para que ningun preview ni prefetch pueda siquiera parecerse a un reinicio.
        if len(partes) == 2 and partes[0] == "m":
            mod = self._moderador(partes[1])
            if mod is None:
                self._404()
                return
            nombre = str(mod.get("nombre", "?"))
            self._html(
                HTTPStatus.OK,
                "Panel de moderación",
                self._cabecera_mod(nombre) + pagina_estado(self.panel, partes[1], nombre),
            )
            return

        self._404()

    def do_HEAD(self) -> None:  # noqa: N802 - firma de la stdlib
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802 - firma de la stdlib
        ip = self._ip()
        if not self.limiter.permitido(ip):
            self._responder(
                HTTPStatus.TOO_MANY_REQUESTS,
                b"429 Too Many Requests\n",
                "text/plain; charset=utf-8",
            )
            return

        # Se consume el cuerpo aunque no se use: si no, la conexion keep-alive queda sucia.
        try:
            largo = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            largo = 0
        if largo > 0:
            self.rfile.read(min(largo, MAX_BODY))
            if largo > MAX_BODY:
                self._responder(
                    HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                    b"413 Payload Too Large\n",
                    "text/plain; charset=utf-8",
                )
                return

        partes = self._ruta().strip("/").split("/")
        if len(partes) != 3 or partes[0] != "m" or partes[2] != "restart":
            self._404()
            return

        token = partes[1]
        mod = self._moderador(token)
        if mod is None:
            log(f"POST /m/<token>/restart rechazado desde {ip}: token invalido o revocado")
            self._404()
            return

        nombre = str(mod.get("nombre", "?"))
        ok, motivo = self.panel.lanzar_reinicio(nombre)
        if not ok:
            self.panel.registrar(nombre, ip, "restart", f"rechazado: {motivo}")
            # El cooldown y el reinicio en curso ya se explican solos en la pagina de estado;
            # el mensaje extra queda para lo inesperado (que no se pudo lanzar el proceso).
            mensaje = "" if motivo in ("cooldown", "ya hay un reinicio en curso") else motivo
            self._html(
                HTTPStatus.CONFLICT,
                "Panel de moderación",
                self._cabecera_mod(nombre) + pagina_estado(self.panel, token, nombre, mensaje),
            )
            return

        self.panel.registrar(nombre, ip, "restart", "lanzado")
        self._html(
            HTTPStatus.OK,
            "Reinicio en curso",
            self._cabecera_mod(nombre) + pagina_lanzado(token),
            refresco=f'<meta http-equiv="refresh" content="45; url=/m/{html.escape(token)}">',
        )

    def _cabecera_mod(self, nombre: str) -> str:
        return f'<p class="quien">Entraste como <b>{html.escape(nombre)}</b></p>'


# =================================================================================================
# main
# =================================================================================================


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Panel de moderadores del server de Zomboid.")
    p.add_argument(
        "--puerto",
        type=int,
        default=int(os.environ.get("PANEL_PUERTO", "8081")),
        help="puerto TCP (env PANEL_PUERTO, default 8081)",
    )
    p.add_argument(
        "--host",
        default=os.environ.get("PANEL_HOST", "0.0.0.0"),  # noqa: S104 - tiene que ser publico
        help="interfaz donde escuchar (env PANEL_HOST, default 0.0.0.0)",
    )
    p.add_argument(
        "--datos",
        type=Path,
        default=Path(os.environ.get("PANEL_DATOS", AQUI / "datos")),
        help="carpeta con moderadores.json, acciones.jsonl y estado.json (env PANEL_DATOS)",
    )
    p.add_argument(
        "--repo",
        type=Path,
        default=Path(os.environ.get("PANEL_REPO", AQUI.parent.parent)),
        help="raiz del repo, desde donde se corren restart.sh y rcon.sh (env PANEL_REPO)",
    )
    p.add_argument(
        "--plantilla",
        type=Path,
        default=Path(os.environ.get("PANEL_PLANTILLA", AQUI / "plantilla.html")),
        help="ruta de plantilla.html",
    )
    p.add_argument(
        "--cooldown",
        type=int,
        default=int(os.environ.get("PANEL_COOLDOWN", "600")),
        help="segundos entre reinicios, para cualquier moderador (env PANEL_COOLDOWN)",
    )
    p.add_argument(
        "--cooldown-moderador",
        type=int,
        default=int(os.environ.get("PANEL_COOLDOWN_MOD", "1800")),
        help="segundos entre reinicios del mismo moderador (env PANEL_COOLDOWN_MOD)",
    )
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not args.plantilla.is_file():
        print(f"panel: ERROR: no existe {args.plantilla}", file=sys.stderr)
        return 1
    repo = args.repo.resolve()
    if not repo.is_dir():
        print(f"panel: ERROR: no existe el repo {repo}", file=sys.stderr)
        return 1

    restart_cmd = os.environ.get("PANEL_RESTART_CMD", "scripts/restart.sh")
    rcon_cmd = os.environ.get("PANEL_RCON_CMD", "scripts/rcon.sh")
    log_reinicio = Path(os.environ.get("PANEL_RESTART_LOG", "/var/log/zomboid/panel-restart.log"))

    try:
        panel = Panel(
            datos_dir=args.datos.resolve(),
            repo_dir=repo,
            restart_cmd=restart_cmd,
            rcon_cmd=rcon_cmd,
            log_reinicio=log_reinicio,
            cooldown=args.cooldown,
            cooldown_mod=args.cooldown_moderador,
        )
    except OSError as exc:
        print(f"panel: ERROR: no se pudo preparar {args.datos}: {exc}", file=sys.stderr)
        return 1

    nombre = os.environ.get("PUBLIC_NAME", "").strip().strip('"').strip("'") or "Servidor de Zomboid"

    Handler.panel = panel
    Handler.limiter = RateLimiter(RATE_LIMITE, RATE_VENTANA)
    Handler.plantilla = args.plantilla.read_text(encoding="utf-8")
    Handler.server_name_html = html.escape(nombre)

    httpd = ThreadingHTTPServer((args.host, args.puerto), Handler)
    httpd.daemon_threads = True

    log(f"escuchando en http://{args.host}:{args.puerto}")
    log(f"repo:        {repo}")
    log(f"datos:       {panel.datos_dir}")
    log(f"reinicio:    {restart_cmd} (log en {log_reinicio})")
    log(f"cooldown:    {args.cooldown}s global, {args.cooldown_moderador}s por moderador")
    log(f"moderadores: {panel.moderadores.cantidad_activos()} activos")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("cortado a mano, cerrando")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
