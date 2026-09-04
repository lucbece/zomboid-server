#!/usr/bin/env python3
"""La logica de /pz start, /pz status y /pz stop, sin nada de discord.py adentro.

Cada comando es un generador asincronico que va largando el texto a mostrar: el primero es la
respuesta inmediata a la interaccion y los siguientes editan ese mismo mensaje. Asi el usuario
ve "Prendiendo el server..." al toque (Discord da 3 segundos para responder) y despues el
mensaje se va actualizando solo hasta "En linea".

Todo lo que toca el mundo real (OCI, la consulta A2S, el reloj y el sleep) entra por el
Contexto, que en los tests se arma con dobles. Por eso este archivo se puede probar entero sin
red, sin credenciales y sin esperar tres minutos.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator, Awaitable, Callable, Optional, Sequence

from a2s import InfoServidor
from power import PROVISIONING, RUNNING, STARTING, STOPPED, STOPPING, estado_legible

# Cuanto se sigue esperando a que el juego conteste despues de mandar el START.
ESPERA_MAXIMA = 420.0  # 7 minutos: el arranque tipico es ~3, con mods pesados puede ser mas
INTERVALO = 10.0


# --- Estado persistente ------------------------------------------------------------------
# La API de OCI no dice desde cuando esta encendida una instancia (time_created es la fecha de
# creacion, no la del ultimo arranque) y A2S tampoco tiene uptime. Se guarda entonces el momento
# en que el bot la vio encendida por primera vez: exacto cuando el arranque lo pidio el bot,
# aproximado cuando el bot arranco con la VM ya prendida.

@dataclass
class EstadoBot:
    """Cuando vimos la VM encendida por ultima vez. Se persiste para sobrevivir un restart."""

    ruta: Optional[Path] = None
    encendida_desde: Optional[float] = None
    aproximado: bool = True

    def cargar(self) -> "EstadoBot":
        if self.ruta and self.ruta.exists():
            try:
                datos = json.loads(self.ruta.read_text())
                self.encendida_desde = datos.get("encendida_desde")
                self.aproximado = bool(datos.get("aproximado", True))
            except (OSError, ValueError):
                pass
        return self

    def guardar(self) -> None:
        if not self.ruta:
            return
        try:
            self.ruta.parent.mkdir(parents=True, exist_ok=True)
            self.ruta.write_text(json.dumps({
                "encendida_desde": self.encendida_desde,
                "aproximado": self.aproximado,
            }))
        except OSError:
            pass

    def marcar_encendida(self, cuando: float, aproximado: bool = False) -> None:
        # Un arranque que pidio el bot pisa siempre a una observacion aproximada anterior.
        if self.encendida_desde is None or not aproximado:
            self.encendida_desde = cuando
            self.aproximado = aproximado
            self.guardar()

    def marcar_apagada(self) -> None:
        self.encendida_desde = None
        self.aproximado = True
        self.guardar()


def duracion_legible(segundos: float) -> str:
    segundos = max(0, int(segundos))
    minutos, _ = divmod(segundos, 60)
    horas, minutos = divmod(minutos, 60)
    dias, horas = divmod(horas, 24)
    if dias:
        return f"{dias} d {horas} h"
    if horas:
        return f"{horas} h {minutos} min"
    return f"{minutos} min"


# --- Contexto ------------------------------------------------------------------------------

@dataclass
class Contexto:
    """Todo lo que la logica necesita del mundo, inyectado para poder probarla."""

    oci: object                                   # .estado() .arrancar() .apagar()
    consultar: Callable[[], Optional[InfoServidor]]
    direccion: str                                # "IP:puerto" que ponen los amigos
    ejecutar: Callable[[Callable], Awaitable]     # corre algo bloqueante fuera del loop
    dormir: Callable[[float], Awaitable]
    ahora: Callable[[], float] = time.monotonic
    estado: EstadoBot = field(default_factory=EstadoBot)
    espera_maxima: float = ESPERA_MAXIMA
    intervalo: float = INTERVALO

    async def estado_vm(self) -> str:
        return await self.ejecutar(self.oci.estado)

    async def info_juego(self) -> Optional[InfoServidor]:
        return await self.ejecutar(self.consultar)


# --- Textos --------------------------------------------------------------------------------

def texto_jugadores(info: InfoServidor) -> str:
    if info.jugadores == 0:
        return "sin jugadores"
    if info.jugadores == 1:
        return "1 jugador"
    return f"{info.jugadores} jugadores"


def texto_en_linea(info: InfoServidor, direccion: str) -> str:
    return (f"**{info.nombre}** · En línea · `{direccion}`\n"
            f"{texto_jugadores(info)} de {info.max_jugadores} · {info.mapa} · "
            f"versión {info.version_juego}")


# --- Comandos ------------------------------------------------------------------------------

async def accion_start(ctx: Contexto) -> AsyncIterator[str]:
    """Prende la VM si hace falta y sigue el arranque hasta que el juego contesta por A2S."""
    try:
        estado = await ctx.estado_vm()
    except Exception as exc:
        yield f"No se pudo consultar el estado del server. {exc}"
        return

    if estado == RUNNING:
        info = await ctx.info_juego()
        if info is not None:
            ctx.estado.marcar_encendida(ctx.ahora(), aproximado=True)
            yield f"Ya está en línea.\n{texto_en_linea(info, ctx.direccion)}"
            return
        yield "El server está prendido y el juego todavía no responde. Esperando…"
    elif estado == STOPPED:
        yield "Prendiendo el server. Tarda ~3 minutos."
        try:
            await ctx.ejecutar(ctx.oci.arrancar)
        except Exception as exc:
            yield f"No se pudo prender el server. {exc}"
            return
    elif estado in (STARTING, PROVISIONING):
        yield "El server ya se está prendiendo. Tarda ~3 minutos."
    elif estado == STOPPING:
        yield "El server se está apagando. Probá de nuevo en un minuto."
        return
    else:
        yield f"El server está {estado_legible(estado)}. No se puede prender desde acá."
        return

    inicio = ctx.ahora()
    limite = inicio + ctx.espera_maxima
    while ctx.ahora() < limite:
        await ctx.dormir(ctx.intervalo)
        info = await ctx.info_juego()
        if info is not None:
            ctx.estado.marcar_encendida(ctx.ahora(), aproximado=False)
            yield texto_en_linea(info, ctx.direccion)
            return
        transcurrido = ctx.ahora() - inicio
        yield f"Prendiendo el server… {duracion_legible(transcurrido)}"

    yield ("El server no respondió después de "
           f"{duracion_legible(ctx.espera_maxima)}. Probá `/pz status` en unos minutos.")


async def accion_status(ctx: Contexto) -> AsyncIterator[str]:
    """Estado de la VM y, si el juego esta arriba, lo que reporta el propio server."""
    try:
        estado = await ctx.estado_vm()
    except Exception as exc:
        yield f"No se pudo consultar el estado del server. {exc}"
        return

    if estado != RUNNING:
        ctx.estado.marcar_apagada()
        yield f"Server {estado_legible(estado)}. Para prenderlo: `/pz start`."
        return

    info = await ctx.info_juego()
    if info is None:
        yield ("Server prendido, el juego todavía no responde: puede estar cargando los mods. "
               "Reintentá en un minuto.")
        return

    ctx.estado.marcar_encendida(ctx.ahora(), aproximado=True)
    lineas = [texto_en_linea(info, ctx.direccion)]
    if ctx.estado.encendida_desde is not None:
        transcurrido = duracion_legible(ctx.ahora() - ctx.estado.encendida_desde)
        lineas.append(f"Encendido hace {'~' if ctx.estado.aproximado else ''}{transcurrido}")
    yield "\n".join(lineas)


async def accion_stop(ctx: Contexto, autorizado: bool = True) -> AsyncIterator[str]:
    """Apaga la VM, y solo si el juego reporta 0 jugadores conectados."""
    if not autorizado:
        yield "Solo los admins pueden apagar el server."
        return

    try:
        estado = await ctx.estado_vm()
    except Exception as exc:
        yield f"No se pudo consultar el estado del server. {exc}"
        return

    if estado == STOPPED:
        yield "El server ya está apagado."
        return
    if estado == STOPPING:
        yield "El server ya se está apagando."
        return
    if estado != RUNNING:
        yield f"El server está {estado_legible(estado)}. No se puede apagar desde acá."
        return

    info = await ctx.info_juego()
    if info is None:
        # Nunca a ciegas: si A2S no contesta no hay forma de saber si hay alguien adentro.
        yield ("El juego no responde y no se puede saber si hay gente jugando. "
               "No se apaga. Probá de nuevo en un minuto.")
        return

    if info.jugadores > 0:
        yield (f"Hay {texto_jugadores(info)} conectados: no se apaga. "
               "Se apaga solo cuando pasan 30 minutos sin nadie.")
        return

    yield "Sin jugadores. Apagando el server; la partida se guarda antes."
    try:
        await ctx.ejecutar(ctx.oci.apagar)
    except Exception as exc:
        yield f"No se pudo apagar el server. {exc}"
        return
    ctx.estado.marcar_apagada()
    yield "Apagado en curso: el server guarda la partida y se apaga. Para volver a jugar: `/pz start`."


# --- Autorizacion ---------------------------------------------------------------------------

def puede_apagar(user_id: int, admins: Sequence[int]) -> bool:
    """Sin admins configurados, cualquiera puede apagar (siempre con 0 jugadores)."""
    return not admins or user_id in admins


def puede_usar(roles: Sequence[int], permitidos: Sequence[int]) -> bool:
    """Sin roles configurados, cualquier miembro del server puede usar los comandos."""
    return not permitidos or any(r in permitidos for r in roles)


def ids_desde_env(valor: str) -> list[int]:
    """'123, 456' -> [123, 456]. Lo que no sea un numero se ignora en silencio."""
    ids = []
    for parte in (valor or "").replace(";", ",").split(","):
        parte = parte.strip()
        if parte.isdigit():
            ids.append(int(parte))
    return ids
