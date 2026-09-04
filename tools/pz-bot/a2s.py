#!/usr/bin/env python3
"""Consulta A2S_INFO (Source Engine Query) contra el server de Project Zomboid.

Solo stdlib. Es la unica forma que tiene el bot de saber si el JUEGO esta arriba: la API de
OCI dice si la VM esta encendida, no si el server termino de cargar los mods (que es lo que
tarda los ~3 minutos).

El protocolo:

    -> \\xff\\xff\\xff\\xff T "Source Engine Query\\0"
    <- \\xff\\xff\\xff\\xff A <4 bytes de challenge>     (casi siempre; hay que reintentar)
    -> \\xff\\xff\\xff\\xff T "Source Engine Query\\0" <los mismos 4 bytes>
    <- \\xff\\xff\\xff\\xff I <payload>

El payload trae nombre, mapa, jugadores conectados, maximo y version: nada de eso se
hardcodea en el bot, sale del propio server.

Verificado contra la respuesta real del server B42 42.20.4 que esta en
tests/fixtures/a2s_info.bin.
"""

from __future__ import annotations

import socket
import struct
from dataclasses import dataclass
from typing import Callable, Optional

CABECERA = b"\xff\xff\xff\xff"
PEDIDO = CABECERA + b"TSource Engine Query\x00"

RESPUESTA_INFO = 0x49  # 'I'
RESPUESTA_CHALLENGE = 0x41  # 'A'

TIMEOUT = 3.0
INTENTOS = 3


class ErrorA2S(Exception):
    """La consulta no se pudo completar o la respuesta no tiene la forma esperada."""


class SinRespuesta(ErrorA2S):
    """El server no contesto dentro del timeout (VM apagada, juego cargando, UDP perdido)."""


@dataclass(frozen=True)
class InfoServidor:
    """Lo que interesa de la respuesta A2S_INFO."""

    nombre: str
    mapa: str
    juego: str
    jugadores: int
    max_jugadores: int
    version: str
    puerto: Optional[int] = None
    etiquetas: str = ""

    @property
    def version_juego(self) -> str:
        """La version de B42 sale de las keywords ('VERSION:42.20'), no del campo version.

        El campo `version` del protocolo lo llena Project Zomboid con '1.0.0.0' siempre.
        """
        for parte in self.etiquetas.split(";"):
            if parte.startswith("VERSION:"):
                return parte[len("VERSION:"):]
        return self.version


class _Lector:
    """Lector secuencial de los tipos del protocolo (little endian, strings con \\0 al final)."""

    def __init__(self, datos: bytes) -> None:
        self.datos = datos
        self.pos = 0

    def queda(self, n: int = 1) -> bool:
        return self.pos + n <= len(self.datos)

    def _tomar(self, n: int) -> bytes:
        if not self.queda(n):
            raise ErrorA2S(f"respuesta truncada: faltan {n} bytes en la posicion {self.pos}")
        trozo = self.datos[self.pos:self.pos + n]
        self.pos += n
        return trozo

    def byte(self) -> int:
        return self._tomar(1)[0]

    def corto(self) -> int:
        return struct.unpack("<H", self._tomar(2))[0]

    def saltar(self, n: int) -> None:
        self._tomar(n)

    def cadena(self) -> str:
        fin = self.datos.find(b"\x00", self.pos)
        if fin < 0:
            raise ErrorA2S("string sin terminador en la respuesta")
        crudo = self.datos[self.pos:fin]
        self.pos = fin + 1
        # errors="replace": el nombre del server lo elige una persona y puede traer cualquier cosa.
        return crudo.decode("utf-8", errors="replace")


def es_challenge(datos: bytes) -> Optional[bytes]:
    """Devuelve los 4 bytes del challenge si la respuesta es una, o None."""
    if len(datos) >= 9 and datos.startswith(CABECERA) and datos[4] == RESPUESTA_CHALLENGE:
        return datos[5:9]
    return None


def parsear_info(datos: bytes) -> InfoServidor:
    """Parsea una respuesta A2S_INFO completa."""
    if not datos.startswith(CABECERA):
        raise ErrorA2S("la respuesta no arranca con la cabecera de un paquete simple")
    lec = _Lector(datos[len(CABECERA):])
    tipo = lec.byte()
    if tipo != RESPUESTA_INFO:
        raise ErrorA2S(f"tipo de respuesta inesperado: 0x{tipo:02x} (se esperaba 'I')")

    lec.byte()  # protocolo
    nombre = lec.cadena()
    mapa = lec.cadena()
    lec.cadena()  # carpeta del juego
    juego = lec.cadena()
    lec.corto()  # app id (16 bits; el de verdad viene en el GameID del EDF)
    jugadores = lec.byte()
    max_jugadores = lec.byte()
    lec.byte()  # bots
    lec.byte()  # tipo de server ('d' dedicado)
    lec.byte()  # entorno ('l' linux)
    lec.byte()  # visibilidad (1 = con password)
    lec.byte()  # VAC
    version = lec.cadena()

    puerto: Optional[int] = None
    etiquetas = ""
    if lec.queda():
        edf = lec.byte()
        # El orden de los campos extra lo fija el protocolo, no el bit menos significativo.
        if edf & 0x80:
            puerto = lec.corto()
        if edf & 0x10:
            lec.saltar(8)  # SteamID del server
        if edf & 0x40:
            lec.corto()
            lec.cadena()  # SourceTV
        if edf & 0x20:
            etiquetas = lec.cadena()
        # 0x01 (GameID, 8 bytes) es el ultimo y no se usa.

    return InfoServidor(
        nombre=nombre,
        mapa=mapa,
        juego=juego,
        jugadores=jugadores,
        max_jugadores=max_jugadores,
        version=version,
        puerto=puerto,
        etiquetas=etiquetas,
    )


def _transporte_udp(ip: str, puerto: int, timeout: float) -> Callable[[bytes], bytes]:
    """Transporte real: un socket UDP por consulta (no hay estado que valga la pena reusar)."""

    def enviar(datos: bytes) -> bytes:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(datos, (ip, puerto))
            respuesta, _ = s.recvfrom(4096)
            return respuesta

    return enviar


def consultar(
    ip: str,
    puerto: int = 16261,
    timeout: float = TIMEOUT,
    intentos: int = INTENTOS,
    transporte: Optional[Callable[[bytes], bytes]] = None,
) -> InfoServidor:
    """Consulta A2S_INFO resolviendo el challenge. Lanza SinRespuesta si el juego no contesta.

    `transporte` existe para los tests: recibe el datagrama y devuelve la respuesta.
    """
    enviar = transporte or _transporte_udp(ip, puerto, timeout)
    ultimo: Optional[Exception] = None

    for _ in range(max(1, intentos)):
        try:
            respuesta = enviar(PEDIDO)
            challenge = es_challenge(respuesta)
            if challenge is not None:
                respuesta = enviar(PEDIDO + challenge)
                if es_challenge(respuesta) is not None:
                    # Un segundo challenge seguido significa que se perdio el datagrama:
                    # se reintenta desde cero en vez de encadenar challenges.
                    ultimo = ErrorA2S("el server devolvio otro challenge")
                    continue
            return parsear_info(respuesta)
        except (socket.timeout, OSError) as exc:
            ultimo = exc
        except ErrorA2S as exc:
            ultimo = exc

    raise SinRespuesta(f"el server no respondio en {ip}:{puerto} ({ultimo})")


def consultar_o_none(ip: str, puerto: int = 16261, **kw) -> Optional[InfoServidor]:
    """Igual que consultar() pero devuelve None en vez de lanzar. Es lo que usa el bot."""
    try:
        return consultar(ip, puerto, **kw)
    except ErrorA2S:
        return None


if __name__ == "__main__":  # pragma: no cover - ayuda para probar a mano
    import sys

    info = consultar(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 16261)
    print(info)
    print("version del juego:", info.version_juego)
