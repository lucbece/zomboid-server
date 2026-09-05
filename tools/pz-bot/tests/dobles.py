"""Dobles de prueba: cliente de OCI, consulta A2S y reloj, para probar logica.py sin red."""

from __future__ import annotations

from typing import Optional

import a2s
from logica import Contexto, EstadoBot


class OCIFalso:
    """Cliente de instancia con un guion de estados. arrancar()/apagar() lo hacen avanzar."""

    def __init__(self, estados, falla_en=None):
        # estados: uno por cada llamada a estado(); el ultimo se repite.
        self.estados = list(estados)
        self.llamadas_estado = 0
        self.arrancadas = 0
        self.apagadas = 0
        self.reinicios = 0
        self.falla_en = falla_en or set()

    def estado(self):
        if "estado" in self.falla_en:
            raise RuntimeError("OCI rechazo la credencial del bot.")
        i = min(self.llamadas_estado, len(self.estados) - 1)
        self.llamadas_estado += 1
        return self.estados[i]

    def arrancar(self):
        if "arrancar" in self.falla_en:
            raise RuntimeError("OCI devolvio un error.")
        self.arrancadas += 1

    def apagar(self):
        if "apagar" in self.falla_en:
            raise RuntimeError("OCI devolvio un error.")
        self.apagadas += 1

    def reiniciar(self):
        if "reiniciar" in self.falla_en:
            raise RuntimeError("OCI devolvio un error.")
        self.reinicios += 1


class A2SFalso:
    """Devuelve None hasta `responde_desde` segundos del reloj, y despues la info."""

    def __init__(self, reloj, responde_desde=None, info=None, jugadores=0):
        self.reloj = reloj
        self.responde_desde = responde_desde
        self.info = info or a2s.InfoServidor(
            nombre="PandaParkour",
            mapa="Muldraugh, KY",
            juego="Project Zomboid",
            jugadores=jugadores,
            max_jugadores=16,
            version="1.0.0.0",
            puerto=16261,
            etiquetas=";modded;pvp;VERSION:42.20",
        )
        self.consultas = 0

    def __call__(self) -> Optional[a2s.InfoServidor]:
        self.consultas += 1
        if self.responde_desde is None:
            return None
        return self.info if self.reloj.t >= self.responde_desde else None


class Reloj:
    """Reloj monotonico manual: dormir() adelanta el tiempo en vez de esperarlo."""

    def __init__(self):
        self.t = 0.0

    def __call__(self) -> float:
        return self.t

    async def dormir(self, segundos: float) -> None:
        self.t += segundos


async def ejecutar(fn):
    """En los tests no hace falta un thread: se llama y ya."""
    return fn()


def contexto(oci, consultar, reloj, **kw) -> Contexto:
    return Contexto(
        oci=oci,
        consultar=consultar,
        direccion="203.0.113.10:16261",
        ejecutar=ejecutar,
        dormir=reloj.dormir,
        ahora=reloj,
        estado=EstadoBot(ruta=None),
        **kw,
    )


async def recolectar(generador) -> list:
    return [texto async for texto in generador]
