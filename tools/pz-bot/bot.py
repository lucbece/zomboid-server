#!/usr/bin/env python3
"""Bot de Discord que prende y apaga el server de Project Zomboid a pedido.

Corre en una instancia chica siempre encendida, aparte de la del juego (ver docs/on-demand.md).
Es el otro extremo del apagado por inactividad: la VM del juego se apaga sola despues de 30
minutos sin nadie, y cualquiera del server de Discord la vuelve a prender con /pz start.

    /pz start    prende la VM si esta apagada y avisa cuando el juego responde
    /pz status   estado de la VM y, si esta arriba, lo que reporta el propio server
    /pz stop     apaga la VM, solo con 0 jugadores conectados (y solo admins, si se configuro)

Configuracion (variables de entorno; en la VM salen de /etc/pz-bot/env):

    DISCORD_BOT_TOKEN       token del bot. NUNCA se imprime ni se loguea.
    PZ_BOT_GUILD_ID         id del server de Discord: los comandos se registran por guild para
                            que aparezcan al instante (los globales tardan hasta una hora).
    PZ_INSTANCE_OCID        OCID de la instancia del JUEGO (la que se prende y se apaga).
    PZ_GAME_IP              IP publica reservada del juego.
    PZ_GAME_PORT            16261 por default.
    PZ_BOT_ADMIN_USER_IDS   ids de Discord que pueden usar /pz stop. Vacio = cualquiera.
    PZ_BOT_ALLOWED_ROLE_IDS ids de rol que pueden usar los comandos. Vacio = todos.
    PZ_BOT_OCI_AUTH         instance_principal (default) o config (para probar desde la PC).
    PZ_BOT_STATE            /var/tmp/pz-bot/estado.json

No pide ningun intent privilegiado: los slash commands no necesitan leer mensajes.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path
from typing import AsyncIterator, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import discord  # noqa: E402
from discord import app_commands  # noqa: E402

import a2s  # noqa: E402
from logica import (  # noqa: E402
    Contexto,
    EstadoBot,
    accion_start,
    accion_status,
    accion_stop,
    ids_desde_env,
    puede_apagar,
    puede_usar,
)
from power import ClienteInstancia  # noqa: E402

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
GUILD_ID = os.environ.get("PZ_BOT_GUILD_ID", "").strip()
INSTANCE_OCID = os.environ.get("PZ_INSTANCE_OCID", "").strip()
GAME_IP = os.environ.get("PZ_GAME_IP", "").strip()
GAME_PORT = int(os.environ.get("PZ_GAME_PORT", "16261") or 16261)
ADMINS = ids_desde_env(os.environ.get("PZ_BOT_ADMIN_USER_IDS", ""))
ROLES = ids_desde_env(os.environ.get("PZ_BOT_ALLOWED_ROLE_IDS", ""))
AUTH = os.environ.get("PZ_BOT_OCI_AUTH", "instance_principal").strip()
PERFIL = os.environ.get("PZ_BOT_OCI_PROFILE", "DEFAULT").strip()
REGION = os.environ.get("PZ_BOT_OCI_REGION", "").strip() or None
RUTA_ESTADO = Path(os.environ.get("PZ_BOT_STATE", "/var/tmp/pz-bot/estado.json"))

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    stream=sys.stdout,
)
log = logging.getLogger("pz-bot")


def armar_contexto() -> Contexto:
    cliente = ClienteInstancia(
        INSTANCE_OCID, auth=AUTH, perfil=PERFIL, region=REGION)
    estado = EstadoBot(ruta=RUTA_ESTADO).cargar()
    return Contexto(
        oci=cliente,
        consultar=lambda: a2s.consultar_o_none(GAME_IP, GAME_PORT),
        direccion=f"{GAME_IP}:{GAME_PORT}",
        ejecutar=asyncio.to_thread,
        dormir=asyncio.sleep,
        estado=estado,
    )


async def responder(interaction: discord.Interaction, pasos: AsyncIterator[str]) -> None:
    """Primer texto = respuesta a la interaccion; los siguientes editan ese mismo mensaje.

    Se saltean los textos repetidos para no gastar rate limit editando lo mismo, y una falla
    al editar (mensaje borrado, token de interaccion vencido a los 15 minutos) corta el
    seguimiento sin tirar abajo el comando.
    """
    anterior: Optional[str] = None
    primero = True
    async for texto in pasos:
        if texto == anterior:
            continue
        anterior = texto
        try:
            if primero:
                await interaction.response.send_message(texto)
                primero = False
            else:
                await interaction.edit_original_response(content=texto)
        except discord.HTTPException as exc:
            log.warning("no se pudo actualizar el mensaje: %s", exc)
            return


class BotPZ(discord.Client):
    def __init__(self) -> None:
        # Intents por default: guilds y poco mas. Ninguno privilegiado (no se leen mensajes).
        super().__init__(intents=discord.Intents.default())
        self.tree = app_commands.CommandTree(self)
        self.ctx: Optional[Contexto] = None

    async def setup_hook(self) -> None:
        self.ctx = await asyncio.to_thread(armar_contexto)
        if GUILD_ID.isdigit():
            guild = discord.Object(id=int(GUILD_ID))
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
            log.info("comandos registrados en el guild %s", GUILD_ID)
        else:
            await self.tree.sync()
            log.info("PZ_BOT_GUILD_ID vacio: comandos globales (tardan hasta una hora)")

    async def on_ready(self) -> None:
        log.info("conectado como %s", self.user)


cliente = BotPZ()
pz = app_commands.Group(name="pz", description="Prender y apagar el server de Project Zomboid")


def _roles_de(interaction: discord.Interaction) -> list[int]:
    return [r.id for r in getattr(interaction.user, "roles", [])]


async def _rechazar_si_no_puede(interaction: discord.Interaction) -> bool:
    if puede_usar(_roles_de(interaction), ROLES):
        return False
    await interaction.response.send_message(
        "No tenés el rol necesario para usar estos comandos.", ephemeral=True)
    return True


@pz.command(name="start", description="Prende el server y avisa cuando se puede entrar")
async def cmd_start(interaction: discord.Interaction) -> None:
    if await _rechazar_si_no_puede(interaction):
        return
    log.info("/pz start pedido por %s (%s)", interaction.user, interaction.user.id)
    await responder(interaction, accion_start(cliente.ctx))


@pz.command(name="status", description="Estado del server y jugadores conectados")
async def cmd_status(interaction: discord.Interaction) -> None:
    if await _rechazar_si_no_puede(interaction):
        return
    log.info("/pz status pedido por %s (%s)", interaction.user, interaction.user.id)
    await responder(interaction, accion_status(cliente.ctx))


@pz.command(name="stop", description="Apaga el server si no hay nadie jugando")
async def cmd_stop(interaction: discord.Interaction) -> None:
    if await _rechazar_si_no_puede(interaction):
        return
    autorizado = puede_apagar(interaction.user.id, ADMINS)
    log.info("/pz stop pedido por %s (%s), autorizado=%s",
             interaction.user, interaction.user.id, autorizado)
    await responder(interaction, accion_stop(cliente.ctx, autorizado=autorizado))


cliente.tree.add_command(pz)


def main() -> int:
    faltan = [n for n, v in (
        ("DISCORD_BOT_TOKEN", TOKEN),
        ("PZ_INSTANCE_OCID", INSTANCE_OCID),
        ("PZ_GAME_IP", GAME_IP),
    ) if not v]
    if faltan:
        log.error("faltan variables de entorno: %s", ", ".join(faltan))
        return 1
    log.info("arrancando: juego en %s:%s, admins=%s, roles=%s, auth=%s",
             GAME_IP, GAME_PORT, ADMINS or "todos", ROLES or "todos", AUTH)
    cliente.run(TOKEN, log_handler=None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
