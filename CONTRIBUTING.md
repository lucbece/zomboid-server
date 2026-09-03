# Cómo contribuir

Gracias por pasar. Este repo es una plantilla para que cualquiera levante su propio servidor de
Project Zomboid, así que la prioridad número uno es que **siga funcionando para alguien sin
experiencia técnica**.

## Antes de abrir un PR

1. Los scripts son bash con `set -euo pipefail` y tienen que pasar `shellcheck`:

   ```bash
   docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x setup.sh scripts/*.sh scripts/lib/*.sh
   ```

2. La infraestructura tiene que pasar formato y validación:

   ```bash
   tofu fmt -check -recursive infra/terraform
   tofu -chdir=infra/terraform/envs/prod init -backend=false
   tofu -chdir=infra/terraform/envs/prod validate
   ```

3. Si tocaste `infra/cloud-init.yaml`, validá los dos modos de clonado del repo:

   ```bash
   scripts/render-cloud-init.sh https /tmp/ci-https.yaml
   scripts/render-cloud-init.sh ssh   /tmp/ci-ssh.yaml
   docker run --rm -v /tmp:/mnt ubuntu:24.04 bash -c \
     'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
      cloud-init schema --config-file /mnt/ci-https.yaml &&
      cloud-init schema --config-file /mnt/ci-ssh.yaml'
   ```

4. Nada de secretos en el repo. El CI corre `gitleaks`; también podés instalarlo local:

   ```bash
   pip install pre-commit && pre-commit install
   ```

## Convenciones

- **Documentación y mensajes al usuario, en castellano y sin jerga.** Si un mensaje de error no
  dice qué hacer a continuación, todavía no está terminado.
- Comentarios del código en castellano; explican el *por qué*, no el *qué*.
- Nunca se commitean `.env`, `terraform.tfvars`, `*.tfstate*`, `data/`, `backups/` ni
  `config/servertest.ini` (sí el `.tpl`). Tampoco IPs reales ni OCIDs.
- Cambios de comportamiento del deploy: actualizar `README.md` **y** `docs/runbook.md`.

## Reportar un problema

Usá la plantilla "No puedo conectarme" si el problema es entrar al server. Para cualquier otra
cosa, contá qué esperabas, qué pasó, y pegá la salida de `make doctor`.
