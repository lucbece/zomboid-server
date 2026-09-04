#!/usr/bin/env python3
"""Prender y apagar la VM del juego en OCI, con la identidad de la instancia del bot.

El bot corre en una instancia aparte (siempre encendida) que se autentica por instance
principal: no hay ninguna clave de API en el disco. Los permisos salen del dynamic group y la
policy que crea OpenTofu, acotados a INSTANCE_INSPECT e INSTANCE_POWER_ACTIONS sobre una unica
instancia (la del juego). Aunque alguien se lleve la VM del bot, lo maximo que puede hacer es
prender y apagar el server.

    GetInstance        -> INSTANCE_READ (INSTANCE_INSPECT solo alcanza para ListInstances)
    InstanceAction     -> INSTANCE_POWER_ACTIONS   (START, SOFTSTOP)

SOFTSTOP y no STOP: SOFTSTOP le pide al SO que se apague, el shutdown dispara el ExecStop de
zomboid.service (RCON save + quit) y recien ahi se corta la maquina. STOP es tirar del cable.

El SDK de OCI se importa adentro del constructor a proposito: los tests usan un cliente falso y
no tienen por que tener el paquete instalado.
"""

from __future__ import annotations

import time
from typing import Optional

# Estados del ciclo de vida de una instancia de OCI.
RUNNING = "RUNNING"
STOPPED = "STOPPED"
STARTING = "STARTING"
STOPPING = "STOPPING"
PROVISIONING = "PROVISIONING"
TERMINATED = "TERMINATED"

# Como se le cuenta cada estado a la gente en Discord.
ESTADOS_LEGIBLES = {
    RUNNING: "encendida",
    STOPPED: "apagada",
    STARTING: "prendiéndose",
    STOPPING: "apagándose",
    PROVISIONING: "creándose",
    TERMINATED: "terminada",
    "CREATING_IMAGE": "creando una imagen",
    "TERMINATING": "terminándose",
}

REINTENTOS = 3
ESPERA_REINTENTO = 2.0


class ErrorOCI(RuntimeError):
    """Falla al hablar con OCI, ya traducida a algo que se puede pegar en Discord."""


def _mensaje_de_error(exc: Exception) -> str:
    """Convierte una excepcion del SDK en una linea legible, sin volcar el stack en el chat."""
    estado = getattr(exc, "status", None)
    codigo = getattr(exc, "code", None)
    if estado == 404:
        return "OCI no encuentra la instancia (revisar PZ_INSTANCE_OCID)."
    if estado in (401, 403):
        return "OCI rechazó la credencial del bot (revisar el dynamic group y la policy)."
    if estado == 409:
        return "OCI dice que la instancia está en transición; probar de nuevo en un minuto."
    if estado == 429:
        return "OCI está limitando los pedidos; probar de nuevo en un minuto."
    detalle = getattr(exc, "message", None) or str(exc)
    if codigo:
        return f"OCI devolvió un error ({codigo}): {detalle}"
    return f"No se pudo hablar con OCI: {detalle}"


class ClienteInstancia:
    """Envoltorio del SDK de OCI acotado a una sola instancia.

    auth = "instance_principal" (lo normal en la VM del bot) o "config" (~/.oci/config, para
    probar desde la maquina del admin).
    """

    def __init__(
        self,
        instance_ocid: str,
        auth: str = "instance_principal",
        perfil: str = "DEFAULT",
        region: Optional[str] = None,
        dormir=time.sleep,
    ) -> None:
        import oci  # import diferido: los tests no necesitan el SDK

        self._oci = oci
        self.instance_ocid = instance_ocid
        self._dormir = dormir

        if auth == "instance_principal":
            firmante = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
            configuracion = {"region": region or firmante.region}
            self._compute = oci.core.ComputeClient(config=configuracion, signer=firmante)
        elif auth == "config":
            configuracion = oci.config.from_file(profile_name=perfil)
            if region:
                configuracion["region"] = region
            self._compute = oci.core.ComputeClient(configuracion)
        else:
            raise ValueError(f"auth desconocido: {auth!r} (instance_principal | config)")

    # --- Operaciones ---------------------------------------------------------------------

    def _con_reintentos(self, fn):
        ultimo: Optional[Exception] = None
        for intento in range(REINTENTOS):
            try:
                return fn()
            except Exception as exc:  # el SDK lanza ServiceError, RequestException y urllib3
                ultimo = exc
                estado = getattr(exc, "status", None)
                # Un 4xx que no sea 429 no mejora reintentando.
                if estado is not None and 400 <= estado < 500 and estado != 429:
                    break
                if intento < REINTENTOS - 1:
                    self._dormir(ESPERA_REINTENTO * (intento + 1))
        raise ErrorOCI(_mensaje_de_error(ultimo)) from ultimo

    def estado(self) -> str:
        """Lifecycle state de la instancia del juego."""
        respuesta = self._con_reintentos(
            lambda: self._compute.get_instance(self.instance_ocid))
        return respuesta.data.lifecycle_state

    def arrancar(self) -> None:
        self._con_reintentos(
            lambda: self._compute.instance_action(self.instance_ocid, "START"))

    def apagar(self) -> None:
        """SOFTSTOP: apagado ordenado del SO, que dispara el save + quit del juego."""
        self._con_reintentos(
            lambda: self._compute.instance_action(self.instance_ocid, "SOFTSTOP"))


def estado_legible(estado: str) -> str:
    return ESTADOS_LEGIBLES.get(estado, estado.lower().replace("_", " "))
