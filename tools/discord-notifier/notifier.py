#!/usr/bin/env python3
"""Avisos automaticos del estado del server de Project Zomboid a un webhook de Discord.

Solo stdlib: se copia a la VM y se corre con el python3 del sistema, sin venv ni pip.
Es un daemon (systemd, Restart=always), no un chequeo periodico: escucha tres fuentes y
publica lo que pasa.

    python3 notifier.py                 # lee todo del entorno (EnvironmentFile=.env)
    python3 notifier.py --una-vez       # publica el estado actual y sale (para probar)
    NOTIFIER_DRY_RUN=1 python3 notifier.py   # no postea nada, solo lo escribe al log

Que publica:

    Servidor activo   cuando aparece '*** SERVER STARTED ****' en el log del contenedor.
                      Trae nombre, direccion, password, mods y version del juego.
    Servidor apagado  cuando Docker emite un evento die/stop/kill del contenedor.
    Jugadores         entradas y salidas, agrupadas en una ventana de 30 segundos.

De donde sale cada cosa:

    docker compose logs -f  -> '*** SERVER STARTED ****' y 'version=42.x' (se reconecta solo)
    docker events           -> el contenedor se detuvo
    data/zomboid/Logs/*_user.txt -> entradas y salidas de jugadores
    scripts/rcon.sh players -> cuantos hay conectados, y como red de seguridad cada 60 s

El archivo de usuarios cambia de nombre en cada arranque del server ('YYYY-MM-DD_HH-MM_user.txt')
y el viejo se archiva en Logs/logs_YYYY-MM-DD/: se sigue siempre el mas nuevo de Logs/.

Patrones del archivo de usuarios (verificados contra los logs reales del server, B42 42.20.4):

    [04-09-26 03:27:35.424] 76561198000000000 "Fulano" fully connected (10624,9801,0).
    [04-09-26 03:23:41.740] Connection disconnect index=0 guid=1139411779812053871 id=76561198000000000.
    [04-09-26 03:15:59.025] 76561198000000000 "Fulano" disconnected player (7919,11484,0).

La entrada es 'fully connected'. La salida es 'Connection disconnect ... id=<steamid>', que es
la unica linea que aparece en los tres casos (salir al menu, timeout y apagado del server).
'disconnected player' NO sirve como salida: tambien la escribe el juego cuando alguien muere y
respawnea, seguida de un 'fully connected' 100 ms despues. Por eso una entrada de alguien que ya
esta adentro se ignora, y la salida se toma de 'Connection disconnect'.

El estado (offset del archivo de usuarios, ultimo arranque avisado) vive en
/var/tmp/zomboid-notifier/estado.json para no repetir avisos cuando el servicio se reinicia.

DISCORD_WEBHOOK_URL y SERVER_PASSWORD son credenciales: no se imprimen nunca en el log.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

AQUI = Path(__file__).resolve().parent

# --- Configuracion ----------------------------------------------------------------------------
# Todo pisable desde el entorno: es lo que hace que se pueda probar entero con stubs.

REPO = Path(os.environ.get("NOTIFIER_REPO", AQUI.parent.parent)).resolve()
STATE_DIR = Path(os.environ.get("NOTIFIER_STATE", "/var/tmp/zomboid-notifier"))
LOGS_DIR = Path(os.environ.get("NOTIFIER_LOGS_DIR", REPO / "data" / "zomboid" / "Logs"))
MODS_TXT = Path(os.environ.get("NOTIFIER_MODS_TXT", REPO / "config" / "mods.txt"))
RCON = os.environ.get("NOTIFIER_RCON", str(REPO / "scripts" / "rcon.sh"))
SERVICIO = os.environ.get("NOTIFIER_SERVICE", "zomboid")
CONTENEDOR = os.environ.get("NOTIFIER_CONTAINER", "zomboid-server")

WEBHOOK = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
PUBLIC_NAME = os.environ.get("PUBLIC_NAME", "Project Zomboid").strip() or "Project Zomboid"
PUBLIC_IP = os.environ.get("PUBLIC_IP", "").strip()
GAME_PORT = os.environ.get("GAME_PORT", "16261").strip() or "16261"
SERVER_PASSWORD = os.environ.get("SERVER_PASSWORD", "")
INCLUIR_PASSWORD = os.environ.get("NOTIFIER_INCLUDE_PASSWORD", "1").strip() not in ("0", "no", "false")
DRY_RUN = os.environ.get("NOTIFIER_DRY_RUN", "0").strip() not in ("0", "", "no", "false")

VENTANA = float(os.environ.get("NOTIFIER_GROUP_SECONDS", "30"))  # agrupacion de jugadores
INTERVALO_POST = float(os.environ.get("NOTIFIER_POST_INTERVAL", "2"))  # rate limit propio
INTERVALO_RCON = float(os.environ.get("NOTIFIER_RCON_INTERVAL", "60"))  # red de seguridad
ESPERA_RECONEXION = float(os.environ.get("NOTIFIER_RECONNECT_SECONDS", "5"))
TIMEOUT_RCON = float(os.environ.get("NOTIFIER_RCON_TIMEOUT", "15"))
TIMEOUT_HTTP = float(os.environ.get("NOTIFIER_HTTP_TIMEOUT", "15"))
REINTENTOS = int(os.environ.get("NOTIFIER_MAX_RETRIES", "5"))

# Colores de los embeds, en decimal como los espera la API (mismos que scripts/lib/notificar.sh).
VERDE = 3066993
GRIS = 9807270
AZUL = 3447003

# --- Patrones ---------------------------------------------------------------------------------

RE_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
RE_ARRANQUE = re.compile(r"\*\*\* SERVER STARTED \*\*\*\*")
RE_VERSION = re.compile(r"\bversion=([0-9][0-9A-Za-z.]*)")
RE_ENTRA = re.compile(r'^\[[^\]]*\]\s+(\d{5,25})\s+"(.*)"\s+fully connected\b')
RE_NOMBRE = re.compile(r'^\[[^\]]*\]\s+(\d{5,25})\s+"(.*)"\s+(?:attempting to join|allowed to join)\b')
RE_SALE = re.compile(r"^\[[^\]]*\]\s+Connection disconnect\b.*\bid=(\d{5,25})\b")
RE_RCON_N = re.compile(r"Players connected\s*\((\d+)\)")

# Caracteres de markdown que hay que neutralizar en un nombre elegido por el jugador.
RE_MARKDOWN = re.compile(r"([\\`*_~|>\[\]()#-])")


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def ahora_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def escapar(texto: str) -> str:
    """Nombre de jugador listo para meter en un embed: sin markdown y sin arrancar una mencion."""
    return RE_MARKDOWN.sub(r"\\\1", texto).replace("@", "@​")[:80]


# =============================================================================================
# Estado persistente
# =============================================================================================


class Estado:
    """estado.json: el offset del archivo de usuarios y el ultimo arranque ya avisado.

    Sin esto, un reinicio del servicio volveria a leer el archivo de usuarios desde el
    principio y publicaria de nuevo cada entrada de la partida.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self.datos: dict = {}
        try:
            self.datos = json.loads(path.read_text("utf-8"))
        except (OSError, ValueError):
            self.datos = {}
        if not isinstance(self.datos, dict):
            self.datos = {}

    def get(self, clave: str, default=None):
        return self.datos.get(clave, default)

    def set(self, clave: str, valor) -> None:
        self.datos[clave] = valor
        self.guardar()

    def guardar(self) -> None:
        # Escritura atomica: si el proceso se muere a la mitad, el archivo viejo sigue entero.
        tmp = self.path.with_suffix(".tmp")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(json.dumps(self.datos, ensure_ascii=False), "utf-8")
            tmp.replace(self.path)
        except OSError as e:
            log(f"ADVERTENCIA: no se pudo guardar {self.path}: {e}")


# =============================================================================================
# Publicador: una sola cola de salida, con el rate limit del webhook
# =============================================================================================


class Publicador(threading.Thread):
    """Postea los embeds de a uno, nunca mas rapido que INTERVALO_POST y respetando el 429.

    Discord contesta 429 con {"retry_after": <segundos>} en el cuerpo; el header Retry-After
    dice lo mismo. Se espera lo que pida y se reintenta el mismo payload.
    """

    def __init__(self, url: str) -> None:
        super().__init__(name="publicador", daemon=True)
        self.url = url
        self.cola: queue.Queue = queue.Queue()
        self.ultimo = 0.0

    def enviar(self, payload: dict) -> None:
        self.cola.put(payload)

    def run(self) -> None:
        while True:
            payload = self.cola.get()
            if payload is None:
                return
            try:
                self._postear(payload)
            except Exception as e:  # noqa: BLE001 - un aviso perdido no puede matar el daemon
                log(f"ADVERTENCIA: no se pudo publicar el aviso: {e}")

    def _postear(self, payload: dict) -> None:
        titulo = payload.get("embeds", [{}])[0].get("title", "?")
        if DRY_RUN or not self.url:
            log(f"(sin publicar) {titulo}")
            return

        cuerpo = json.dumps(payload).encode("utf-8")
        for intento in range(1, REINTENTOS + 1):
            espera = INTERVALO_POST - (time.monotonic() - self.ultimo)
            if espera > 0:
                time.sleep(espera)
            req = urllib.request.Request(
                self.url,
                data=cuerpo,
                headers={"Content-Type": "application/json", "User-Agent": "zomboid-notifier/1.0"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT_HTTP) as r:
                    self.ultimo = time.monotonic()
                    log(f"publicado: {titulo} (HTTP {r.status})")
                    return
            except urllib.error.HTTPError as e:
                self.ultimo = time.monotonic()
                if e.code == 429:
                    time.sleep(self._retry_after(e))
                    continue
                if 500 <= e.code < 600 and intento < REINTENTOS:
                    log(f"ADVERTENCIA: el webhook contesto HTTP {e.code}, reintento {intento}")
                    time.sleep(INTERVALO_POST * intento)
                    continue
                log(f"ADVERTENCIA: el webhook contesto HTTP {e.code}: descarto '{titulo}'")
                return
            except (urllib.error.URLError, OSError) as e:
                self.ultimo = time.monotonic()
                if intento < REINTENTOS:
                    log(f"ADVERTENCIA: falla de red al publicar ({e}), reintento {intento}")
                    time.sleep(INTERVALO_POST * intento)
                    continue
                log(f"ADVERTENCIA: no se pudo publicar '{titulo}': {e}")
                return
        log(f"ADVERTENCIA: se agotaron los reintentos, descarto '{titulo}'")

    @staticmethod
    def _retry_after(e: urllib.error.HTTPError) -> float:
        segundos = 0.0
        try:
            cuerpo = json.loads(e.read().decode("utf-8", "replace"))
            segundos = float(cuerpo.get("retry_after", 0))
        except (ValueError, AttributeError, OSError):
            segundos = 0.0
        if segundos <= 0:
            try:
                segundos = float(e.headers.get("Retry-After", 0) or 0)
            except (TypeError, ValueError):
                segundos = 0.0
        segundos = min(max(segundos, 1.0), 60.0)
        log(f"el webhook pidio esperar {segundos:.1f}s (429)")
        return segundos + 0.25


# =============================================================================================
# Datos del server para el mensaje de "activo"
# =============================================================================================


def correr(cmd: list[str], timeout: float, cwd: Path | None = None) -> str | None:
    """Corre un comando y devuelve su stdout, o None si fallo. Nunca levanta."""
    try:
        p = subprocess.run(
            cmd, cwd=str(cwd) if cwd else None, capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.SubprocessError) as e:
        log(f"ADVERTENCIA: fallo '{shlex.join(cmd)}': {e}")
        return None
    if p.returncode != 0:
        return None
    return p.stdout


_ip_cache: str | None = None


def ip_publica() -> str:
    """PUBLIC_IP del .env; si no esta, la metadata de OCI; si no, ifconfig.me. Se cachea.

    En esta infra la IP publica es un oci_core_public_ip reservado y la VNIC se crea con
    assign_public_ip=false, asi que la metadata NO trae 'publicIp': el camino que funciona
    es el de ifconfig.me. Se deja igual el de la metadata porque no cuesta nada y es el
    correcto en una VM con IP efimera.
    """
    global _ip_cache
    if PUBLIC_IP:
        return PUBLIC_IP
    if _ip_cache:
        return _ip_cache

    req = urllib.request.Request(
        "http://169.254.169.254/opc/v2/vnics/", headers={"Authorization": "Bearer Oracle"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            vnics = json.loads(r.read().decode("utf-8"))
        for v in vnics:
            if v.get("publicIp"):
                _ip_cache = str(v["publicIp"])
                return _ip_cache
    except Exception:  # noqa: BLE001 - fuera de OCI esto ni existe
        pass

    try:
        with urllib.request.urlopen("https://ifconfig.me", timeout=8) as r:
            texto = r.read().decode("utf-8", "replace").strip()
        if re.fullmatch(r"[0-9.]{7,15}", texto):
            _ip_cache = texto
            return _ip_cache
    except Exception:  # noqa: BLE001
        pass

    log("ADVERTENCIA: no se pudo averiguar la IP publica (poner PUBLIC_IP en .env)")
    return "?"


def cantidad_de_mods() -> int:
    """Lineas utiles de config/mods.txt: una por item del Workshop, sin comentarios ni vacias."""
    try:
        crudo = MODS_TXT.read_text("utf-8")
    except OSError:
        return 0
    n = 0
    for linea in crudo.splitlines():
        if linea.split("#", 1)[0].strip():
            n += 1
    return n


def debug_log_actual() -> Path | None:
    """El DebugLog-server.txt del arranque en curso (mismo contenido que el log del contenedor).

    Se usa solo al iniciar el notifier: leer un archivo de 800 KB es mucho mas barato que
    volcar todo el log de Docker para buscar dos lineas.
    """
    try:
        candidatos = sorted(LOGS_DIR.glob("*_DebugLog-server.txt"), key=lambda p: p.stat().st_mtime)
    except OSError:
        return None
    return candidatos[-1] if candidatos else None


def version_del_juego() -> str:
    """'42.20.4' de la linea 'version=42.20.4 <hash> demo=false' del log del arranque."""
    archivo = debug_log_actual()
    if not archivo:
        return "?"
    try:
        with archivo.open("r", encoding="utf-8", errors="replace") as fh:
            for i, linea in enumerate(fh):
                if i > 4000:  # la linea aparece entre las primeras 100
                    break
                m = RE_VERSION.search(linea)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return "?"


def ya_arranco() -> bool:
    """True si el arranque en curso ya llego a 'SERVER STARTED' (mirando el log del juego)."""
    archivo = debug_log_actual()
    if not archivo:
        return False
    try:
        with archivo.open("r", encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                if RE_ARRANQUE.search(linea):
                    return True
    except OSError:
        pass
    return False


def contenedor_arrancado_en() -> str | None:
    """State.StartedAt del contenedor, que identifica el arranque. None si no esta corriendo."""
    salida = correr(["docker", "inspect", "--format",
                     "{{.State.Running}} {{.State.StartedAt}}", CONTENEDOR], timeout=15)
    if not salida:
        return None
    partes = salida.strip().split(None, 1)
    if len(partes) != 2 or partes[0] != "true":
        return None
    return partes[1]


def rcon_players() -> tuple[int, set[str]] | None:
    """(cantidad, nombres) de 'Players connected (N):' + lineas '-Nombre'. None si RCON no anda."""
    salida = correr([RCON, "players"], timeout=TIMEOUT_RCON, cwd=REPO)
    if salida is None:
        return None
    limpio = RE_ANSI.sub("", salida)
    m = RE_RCON_N.search(limpio)
    if not m:
        return None
    nombres = set()
    for linea in limpio.splitlines():
        linea = linea.strip()
        if linea.startswith("-") and len(linea) > 1:
            nombres.add(linea[1:].strip())
    return int(m.group(1)), nombres


# =============================================================================================
# Mensajes
# =============================================================================================


def embed(titulo: str, descripcion: str, color: int, campos: list[dict] | None = None) -> dict:
    e = {
        "title": titulo[:256],
        "description": descripcion[:3900],
        "color": color,
        "timestamp": ahora_iso(),
    }
    if campos:
        e["fields"] = campos
    # allowed_mentions vacio: un jugador que se llame '@everyone' no puede pingear al canal.
    return {"embeds": [e], "allowed_mentions": {"parse": []}}


def mensaje_activo(version: str, snapshot: bool) -> dict:
    campos = [
        {"name": "Direccion", "value": f"`{ip_publica()}:{GAME_PORT}`", "inline": True},
        {"name": "Mods", "value": str(cantidad_de_mods()), "inline": True},
        {"name": "Version", "value": version or "?", "inline": True},
    ]
    if INCLUIR_PASSWORD and SERVER_PASSWORD:
        campos.insert(1, {"name": "Contrasena", "value": f"`{SERVER_PASSWORD}`", "inline": True})

    descripcion = f"**{PUBLIC_NAME}**"
    if snapshot:
        descripcion += "\nEstado actual: el servidor ya estaba en linea."
    else:
        descripcion += "\nYa se puede entrar."
    return embed("Servidor activo", descripcion, VERDE, campos)


def mensaje_apagado(motivo: str) -> dict:
    return embed("Servidor apagado", f"**{PUBLIC_NAME}**\n{motivo}", GRIS)


def mensaje_jugadores(entradas: list[str], salidas: list[str], conectados: int) -> dict:
    cuenta = f"{conectados} conectado" + ("" if conectados == 1 else "s")
    if len(entradas) + len(salidas) == 1:
        quien = escapar((entradas or salidas)[0])
        verbo = "entró al server" if entradas else "salió del server"
        return embed(f"{quien} {verbo} ({cuenta})", f"**{PUBLIC_NAME}**", AZUL)

    lineas = [f"**{PUBLIC_NAME}**"]
    if entradas:
        lineas.append("Entraron: " + ", ".join(escapar(n) for n in entradas))
    if salidas:
        lineas.append("Salieron: " + ", ".join(escapar(n) for n in salidas))
    return embed(f"Movimiento de jugadores ({cuenta})", "\n".join(lineas), AZUL)


# =============================================================================================
# Fuentes de eventos (un hilo cada una, todas escriben en la misma cola)
# =============================================================================================


class Fuente(threading.Thread):
    def __init__(self, nombre: str, cola: queue.Queue, parar: threading.Event) -> None:
        super().__init__(name=nombre, daemon=True)
        self.cola = cola
        self.parar = parar


class SeguidorDeLog(Fuente):
    """`docker compose logs -f`: detecta 'SERVER STARTED' y la version, y se reconecta solo.

    --tail 0 para no releer el arranque anterior cuando el servicio se reinicia. Si el stream
    se corta (el contenedor se fue, o Docker hipo) se reintenta cada ESPERA_RECONEXION.
    """

    def run(self) -> None:
        while not self.parar.is_set():
            cmd = ["docker", "compose", "logs", "-f", "--no-color", "--no-log-prefix",
                   "--tail", "0", SERVICIO]
            try:
                proc = subprocess.Popen(
                    cmd, cwd=str(REPO), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, errors="replace", bufsize=1,
                )
            except (OSError, subprocess.SubprocessError) as e:
                log(f"ADVERTENCIA: no se pudo seguir el log del contenedor: {e}")
                self.parar.wait(ESPERA_RECONEXION)
                continue

            log("siguiendo el log del contenedor")
            version = ""
            assert proc.stdout is not None
            for linea in proc.stdout:
                if self.parar.is_set():
                    break
                m = RE_VERSION.search(linea)
                if m:
                    version = m.group(1)
                if RE_ARRANQUE.search(linea):
                    self.cola.put(("arranque", version or version_del_juego()))
            proc.stdout.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            if self.parar.is_set():
                return
            # El stream se corto. Puede ser que el contenedor se haya ido (docker events ya lo
            # dijo) o un hipo de Docker: se avisa y el cerebro decide segun lo que sepa.
            self.cola.put(("stream-fin", None))
            self.parar.wait(ESPERA_RECONEXION)


class SeguidorDeEventos(Fuente):
    """`docker events`: la señal autoritativa de que el contenedor se detuvo."""

    def run(self) -> None:
        while not self.parar.is_set():
            cmd = ["docker", "events", "--filter", f"container={CONTENEDOR}",
                   "--filter", "event=die", "--filter", "event=stop", "--filter", "event=kill",
                   "--format", "{{.Action}}"]
            try:
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, errors="replace", bufsize=1,
                )
            except (OSError, subprocess.SubprocessError) as e:
                log(f"ADVERTENCIA: no se pudo seguir docker events: {e}")
                self.parar.wait(ESPERA_RECONEXION)
                continue

            log("siguiendo los eventos de Docker")
            assert proc.stdout is not None
            for linea in proc.stdout:
                if self.parar.is_set():
                    break
                accion = linea.strip()
                if accion:
                    self.cola.put(("evento", accion))
            proc.stdout.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            self.parar.wait(ESPERA_RECONEXION)


class SeguidorDeUsuarios(Fuente):
    """Sigue el *_user.txt mas nuevo de Logs/ y publica entradas y salidas.

    El server abre un archivo nuevo en cada arranque y archiva el viejo en logs_YYYY-MM-DD/,
    asi que hay que re-elegir el archivo cada vuelta y no quedarse pegado a un descriptor.
    """

    def __init__(self, cola: queue.Queue, parar: threading.Event, estado: Estado) -> None:
        super().__init__("usuarios", cola, parar)
        self.estado = estado
        self.actual: Path | None = None
        self.inode: int | None = None
        self.offset = 0
        self.nombres: dict[str, str] = {}  # steamid -> nombre

    # --- eleccion del archivo -----------------------------------------------------------
    def mas_nuevo(self) -> Path | None:
        try:
            candidatos = [p for p in LOGS_DIR.glob("*_user.txt") if p.is_file()]
        except OSError:
            return None
        if not candidatos:
            return None
        # Por mtime, con el nombre (que es cronologico) como desempate.
        return max(candidatos, key=lambda p: (p.stat().st_mtime, p.name))

    def adoptar(self, archivo: Path, primera_vez: bool) -> list[tuple[str, tuple[str, str]]]:
        """Pasa a seguir 'archivo'. Devuelve los eventos de la parte ya escrita, en silencio.

        Al arrancar el notifier se relee lo que va del archivo sin publicar nada: sirve para
        saber quien esta adentro y como se llama cada steamid. Si el estado guardado ya tiene
        un offset para este mismo archivo, se retoma desde ahi (nada de duplicados) y solo se
        relee la parte vieja para reconstruir los nombres.
        """
        st = archivo.stat()
        guardado = self.estado.get("user_log") or {}
        retomar = (
            primera_vez
            and guardado.get("path") == str(archivo)
            and guardado.get("inode") == st.st_ino
            and 0 <= int(guardado.get("offset", 0)) <= st.st_size
        )
        hasta = int(guardado["offset"]) if retomar else st.st_size

        eventos = self._leer(archivo, 0, hasta)
        self.actual = archivo
        self.inode = st.st_ino
        self.offset = hasta
        self._guardar()
        log(f"archivo de usuarios: {archivo.name} (desde el byte {hasta})")
        return [] if retomar else eventos

    def _guardar(self) -> None:
        self.estado.set("user_log", {
            "path": str(self.actual), "inode": self.inode, "offset": self.offset,
        })

    # --- lectura ------------------------------------------------------------------------
    def _leer(self, archivo: Path, desde: int, hasta: int) -> list[tuple[str, tuple[str, str]]]:
        if hasta <= desde:
            return []
        try:
            with archivo.open("rb") as fh:
                fh.seek(desde)
                crudo = fh.read(hasta - desde)
        except OSError as e:
            log(f"ADVERTENCIA: no se pudo leer {archivo}: {e}")
            return []
        eventos = []
        for linea in crudo.decode("utf-8", "replace").splitlines():
            ev = self.interpretar(linea)
            if ev:
                eventos.append(ev)
        return eventos

    def interpretar(self, linea: str) -> tuple[str, tuple[str, str]] | None:
        """Devuelve ('entra'|'sale', (steamid, nombre)) o None si la linea no dice nada."""
        m = RE_NOMBRE.match(linea)
        if m:
            self.nombres[m.group(1)] = m.group(2)
            return None
        m = RE_ENTRA.match(linea)
        if m:
            self.nombres[m.group(1)] = m.group(2)
            return ("entra", (m.group(1), m.group(2)))
        m = RE_SALE.match(linea)
        if m:
            sid = m.group(1)
            return ("sale", (sid, self.nombres.get(sid, sid)))
        return None

    def run(self) -> None:
        primera_vez = True
        while not self.parar.is_set():
            archivo = self.mas_nuevo()
            if archivo is None:
                self.parar.wait(5)
                continue

            try:
                st = archivo.stat()
            except OSError:
                self.parar.wait(2)
                continue

            if self.actual is None or st.st_ino != self.inode:
                # Archivo nuevo (arranque nuevo del server): nadie sigue adentro del anterior.
                if self.actual is not None:
                    self.nombres.clear()
                    self.cola.put(("usuarios-reset", None))
                for ev in self.adoptar(archivo, primera_vez):
                    self.cola.put(("silencioso", ev))
                self.cola.put(("usuarios-listo", None))
                primera_vez = False
                continue

            if st.st_size < self.offset:  # truncado: se relee desde cero
                log(f"{archivo.name} se acorto: se relee desde el principio")
                self.offset = 0
            if st.st_size > self.offset:
                for ev in self._leer(archivo, self.offset, st.st_size):
                    self.cola.put(ev)
                self.offset = st.st_size
                self._guardar()
            self.parar.wait(2)


class EncuestadorRcon(Fuente):
    """Cada INTERVALO_RCON pregunta quien esta conectado. Es la red de seguridad del conteo."""

    def run(self) -> None:
        while not self.parar.is_set():
            self.parar.wait(INTERVALO_RCON)
            if self.parar.is_set():
                return
            r = rcon_players()
            if r is not None:
                self.cola.put(("rcon", r))


# =============================================================================================
# Cerebro: el unico lugar donde se toca el estado
# =============================================================================================


class Notificador:
    def __init__(self, estado: Estado, publicador: Publicador) -> None:
        self.estado = estado
        self.pub = publicador
        self.presentes: dict[str, str] = {}  # steamid (o 'rcon:<nombre>') -> nombre
        self.entradas: list[str] = []
        self.salidas: list[str] = []
        self.limite: float | None = None  # cuando vence la ventana de agrupacion
        self.activo = False
        self.diferencia_previa: tuple[frozenset, frozenset] | None = None
        self.conectados = 0

    # --- jugadores ----------------------------------------------------------------------
    def entra(self, sid: str, nombre: str, silencioso: bool = False) -> None:
        if sid in self.presentes:
            # Ya estaba adentro: es el 'fully connected' que sigue a un respawn, no una entrada.
            self.presentes[sid] = nombre
            return
        self.presentes[sid] = nombre
        if not silencioso:
            self.entradas.append(nombre)
            self._agendar()

    def sale(self, sid: str, nombre: str, silencioso: bool = False) -> None:
        if sid not in self.presentes:
            return  # se desconecto sin haber llegado a entrar (cola de carga)
        nombre = self.presentes.pop(sid) or nombre
        if not silencioso:
            self.salidas.append(nombre)
            self._agendar()

    def _agendar(self) -> None:
        if self.limite is None:
            self.limite = time.monotonic() + VENTANA

    def descartar_pendientes(self) -> None:
        self.entradas.clear()
        self.salidas.clear()
        self.limite = None

    def vaciar(self) -> None:
        if not self.entradas and not self.salidas:
            self.limite = None
            return
        r = rcon_players()
        if r is not None:
            self.conectados = r[0]
        else:
            self.conectados = len(self.presentes)
        self.pub.enviar(mensaje_jugadores(self.entradas, self.salidas, self.conectados))
        self.descartar_pendientes()

    # --- server -------------------------------------------------------------------------
    def arranco(self, version: str, snapshot: bool = False) -> None:
        clave = contenedor_arrancado_en() or ahora_iso()
        if self.estado.get("ultimo_arranque") == clave:
            log("el arranque actual ya se aviso: no se repite")
            self.activo = True
            return
        self.estado.set("ultimo_arranque", clave)
        self.activo = True
        self.descartar_pendientes()
        if not snapshot:
            self.presentes.clear()  # arranque nuevo: no queda nadie del anterior
        self.pub.enviar(mensaje_activo(version, snapshot))

    def apago(self, motivo: str) -> None:
        if not self.activo:
            return
        self.activo = False
        # Las desconexiones del apagado no son gente que se fue: se descartan.
        self.descartar_pendientes()
        self.presentes.clear()
        self.estado.set("ultimo_arranque", "")
        self.pub.enviar(mensaje_apagado(motivo))

    # --- reconciliacion con RCON --------------------------------------------------------
    def reconciliar(self, n: int, nombres: set[str]) -> None:
        """Corrige la lista si el log y RCON no coinciden dos veces seguidas.

        Una sola discrepancia no alcanza: un jugador puede estar entre 'fully connected' y
        aparecer en `players`. Dos lecturas iguales seguidas ya no son un transitorio.
        """
        self.conectados = n
        mios = set(self.presentes.values())
        faltan = frozenset(mios - nombres)  # los daba por adentro y no estan
        sobran = frozenset(nombres - mios)  # estan y no los tenia
        if not faltan and not sobran:
            self.diferencia_previa = None
            return
        if self.diferencia_previa != (faltan, sobran):
            self.diferencia_previa = (faltan, sobran)
            return

        self.diferencia_previa = None
        log(f"RCON no coincide con el log: faltan={sorted(faltan)} sobran={sorted(sobran)}")
        for nombre in sorted(faltan):
            for sid, n2 in list(self.presentes.items()):
                if n2 == nombre:
                    self.sale(sid, nombre)
                    break
        for nombre in sorted(sobran):
            self.entra(f"rcon:{nombre}", nombre)


# =============================================================================================
# main
# =============================================================================================


def arrancar(una_vez: bool) -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    estado = Estado(STATE_DIR / "estado.json")
    publicador = Publicador(WEBHOOK)
    publicador.start()

    if not WEBHOOK:
        log("ADVERTENCIA: DISCORD_WEBHOOK_URL vacia: se escribe al log y no se publica nada")
    if INCLUIR_PASSWORD and not SERVER_PASSWORD:
        log("ADVERTENCIA: NOTIFIER_INCLUDE_PASSWORD=1 pero SERVER_PASSWORD esta vacia")
    log(f"repo={REPO} logs={LOGS_DIR} servicio={SERVICIO} contenedor={CONTENEDOR}")

    n = Notificador(estado, publicador)

    # Foto del estado actual: si el server ya estaba arriba antes de instalar el notifier, se
    # avisa una sola vez (la clave es el StartedAt del contenedor, asi que un reinicio del
    # servicio no lo repite).
    if contenedor_arrancado_en() and ya_arranco():
        # Solo el conteo: la lista de quien esta adentro la reconstruye SeguidorDeUsuarios
        # releyendo el user.txt del arranque en curso, que ademas trae el steamid de cada uno.
        r = rcon_players()
        if r is not None:
            n.conectados = r[0]
        n.arranco(version_del_juego(), snapshot=True)
    else:
        log("el server no esta arriba (o todavia no llego a SERVER STARTED)")

    if una_vez:
        while not publicador.cola.empty():
            time.sleep(0.2)
        time.sleep(INTERVALO_POST)
        return 0

    cola: queue.Queue = queue.Queue()
    parar = threading.Event()
    hilos = [
        SeguidorDeLog("log", cola, parar),
        SeguidorDeEventos("eventos", cola, parar),
        SeguidorDeUsuarios(cola, parar, estado),
        EncuestadorRcon("rcon", cola, parar),
    ]
    for h in hilos:
        h.start()

    def adios(_signo, _marco):
        log("señal de parada: saliendo")
        parar.set()

    signal.signal(signal.SIGTERM, adios)
    signal.signal(signal.SIGINT, adios)

    silencioso = False
    while not parar.is_set():
        espera = 1.0
        if n.limite is not None:
            espera = max(0.05, min(espera, n.limite - time.monotonic()))
        try:
            tipo, dato = cola.get(timeout=espera)
        except queue.Empty:
            tipo = dato = None

        if tipo == "arranque":
            n.arranco(dato or "?")
        elif tipo == "evento":
            n.apago("El contenedor se detuvo.")
        elif tipo == "stream-fin":
            # El stream se corto sin evento de Docker: se pregunta directamente.
            if contenedor_arrancado_en() is None:
                n.apago("El contenedor se detuvo.")
        elif tipo == "usuarios-reset":
            n.presentes.clear()
            n.descartar_pendientes()
            silencioso = True
        elif tipo == "usuarios-listo":
            silencioso = False
        elif tipo == "silencioso":
            clase, (sid, nombre) = dato
            (n.entra if clase == "entra" else n.sale)(sid, nombre, silencioso=True)
        elif tipo == "entra":
            n.entra(dato[0], dato[1], silencioso=silencioso)
        elif tipo == "sale":
            n.sale(dato[0], dato[1], silencioso=silencioso)
        elif tipo == "rcon":
            n.reconciliar(dato[0], dato[1])

        if n.limite is not None and time.monotonic() >= n.limite:
            n.vaciar()

    parar.set()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Avisos del server de Zomboid a Discord")
    ap.add_argument("--una-vez", action="store_true",
                    help="publica el estado actual y sale (para probar el webhook)")
    args = ap.parse_args()
    try:
        return arrancar(args.una_vez)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
