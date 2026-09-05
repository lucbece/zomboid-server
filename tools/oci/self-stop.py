#!/usr/bin/env python3
"""Apaga la VM en la que corre, por la API de OCI (instance principal). Solo stdlib + SDK oci.

    self-stop.py            # SOFTSTOP de esta instancia
    self-stop.py --dry-run  # solo muestra el OCID y el estado, no apaga

Por que no `shutdown -h now`: cuando el sistema operativo se apaga solo, OCI no siempre
registra el cambio y la instancia puede quedar en RUNNING con el huesped apagado. En ese
estado el bot de Discord no la prende (cree que ya esta prendida) y el computo se sigue
cobrando. Un SOFTSTOP pedido por la API deja el estado consistente: OCI manda el ACPI de
apagado al huesped y pasa la instancia a STOPPED.

Necesita la policy INSTANCE_POWER_ACTIONS del dynamic group de la VM (infra/terraform).
"""
import argparse
import json
import sys
import urllib.request

METADATA = "http://169.254.169.254/opc/v2/instance/"


def instancia_local() -> dict:
    req = urllib.request.Request(METADATA, headers={"Authorization": "Bearer Oracle"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="no apaga: muestra instancia y estado")
    args = ap.parse_args()

    try:
        import oci  # noqa: PLC0415 - import diferido para que --help funcione sin el SDK
    except ImportError:
        sys.exit("self-stop: falta el SDK de OCI (pip install oci) en el venv que ejecuta este script")

    meta = instancia_local()
    ocid = meta["id"]
    firmante = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    compute = oci.core.ComputeClient(config={"region": meta.get("canonicalRegionName") or firmante.region}, signer=firmante)
    estado = compute.get_instance(ocid).data.lifecycle_state
    print(f"self-stop: instancia {ocid} en estado {estado}")
    if args.dry_run:
        return
    if estado != "RUNNING":
        print("self-stop: no esta RUNNING, no se manda nada")
        return
    compute.instance_action(ocid, "SOFTSTOP")
    print("self-stop: SOFTSTOP pedido; OCI apaga el sistema y pasa la instancia a STOPPED")


if __name__ == "__main__":
    main()
