# Contributing

This repository is a template: someone with no operational experience should be able to clone it
and end up with a working server. Changes are evaluated against that first.

## Before opening a pull request

Run the same checks CI runs.

1. Shell scripts use `set -euo pipefail` and must pass `shellcheck`:

   ```bash
   docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
     -x setup.sh scripts/*.sh scripts/lib/*.sh
   ```

2. Infrastructure must pass formatting and validation:

   ```bash
   tofu fmt -check -recursive infra/terraform
   tofu -chdir=infra/terraform/envs/prod init -backend=false
   tofu -chdir=infra/terraform/envs/prod validate
   ```

3. If you changed `infra/cloud-init.yaml`, validate both clone modes. It is an OpenTofu template,
   so it has to be rendered first:

   ```bash
   scripts/render-cloud-init.sh https /tmp/ci-https.yaml
   scripts/render-cloud-init.sh ssh   /tmp/ci-ssh.yaml
   docker run --rm -v /tmp:/mnt ubuntu:24.04 bash -c \
     'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
      cloud-init schema --config-file /mnt/ci-https.yaml &&
      cloud-init schema --config-file /mnt/ci-ssh.yaml'
   ```

4. If you changed `tools/encuesta/`, the Python must compile and `preguntas.json` must stay
   coherent — every question needs exactly one option marked as the game default:

   ```bash
   python3 -m py_compile tools/encuesta/server.py tools/encuesta/tally.py
   ```

5. No secrets. CI runs `gitleaks` over the full history; you can run it locally too:

   ```bash
   pip install pre-commit && pre-commit install
   ```

6. If you changed `setup.sh`, check both machine sizes still come out right:

   ```bash
   ZS_MAX_PLAYERS=8  ... ./setup.sh --no-preguntar   # expect 2 OCPU / 12 GB, heap 8g
   ZS_MAX_PLAYERS=16 ... ./setup.sh --no-preguntar   # expect 4 OCPU / 16 GB, heap 12g
   ```

   `--no-preguntar` takes every answer from the `ZS_*` environment variables; the full list is in
   the header of `setup.sh`. Run it in a scratch clone: it overwrites `.env` and
   `terraform.tfvars`.

## Conventions

- **Documentation is written in English.** `README.es.md` is a full translation of `README.md`
  and has to be updated alongside it. Everything under `docs/history/` is a historical record in
  Spanish and is not maintained or translated.
- **The CLI is currently in Spanish.** The output of `setup.sh`, the scripts in `scripts/`, the
  `make` target descriptions and the survey page are written in Spanish, and their tone is more
  informal than the documentation's. Aligning them — and whether to translate them at all — is an
  open question; keep new messages consistent with the surrounding code for now.
- Every user-facing message states what to do next. An error that only reports a failure is not
  finished.
- Code comments explain why, not what.
- Never commit `.env`, `terraform.tfvars`, `*.tfstate*`, `data/`, `backups/` or the rendered
  `config/servertest.ini` — the `.tpl` is the versioned one. No real IP addresses, OCIDs or email
  addresses either, not even in comments. Use `203.0.113.10` for addresses and
  `ocid1.tenancy.oc1..aaaaaaaaCAMBIAME` for OCIDs.
- A change to deployment behaviour updates `README.md`, `README.es.md` and the relevant document
  under `docs/`.
- Every `make` target mentioned in the documentation has to exist in the `Makefile`.

## Reporting a problem

Use the "Cannot connect" issue template if the problem is joining the server. For anything else,
describe what you expected, what happened, and include the output of `make doctor`.
