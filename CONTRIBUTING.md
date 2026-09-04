# Contributing

This repository is a template: someone with no operational experience should be able to clone it
and end up with a working server. Changes are evaluated against that first.

## Before opening a pull request

Run the same checks CI runs.

1. Shell scripts use `set -euo pipefail` and must pass `shellcheck`:

   ```bash
   docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
     -x setup.sh scripts/*.sh scripts/lib/*.sh scripts/lib/i18n/*.sh
   ```

   If you touched any user-facing message, the message catalogs also have to be consistent:

   ```bash
   scripts/i18n-check.sh
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
- **The CLI speaks Spanish and English.** See "CLI languages" below.
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

## CLI languages

The operator-facing CLI — `setup.sh`, the scripts in `scripts/`, and the `make` target
descriptions — is bilingual. Which language it uses is `ZS_LANG`, resolved by
`scripts/lib/i18n.sh` in this order:

1. the `ZS_LANG` environment variable;
2. the `ZS_LANG=` line in the repository's `.env` (written by `setup.sh`, which asks for the
   language as its first question);
3. the prefix of `LC_ALL` / `LC_MESSAGES` / `LANG` (`es*` becomes `es`);
4. `en`.

Only `es` and `en` are valid. Anything else falls back to English, and English is also the
per-key fallback: the English catalog is always loaded first and the Spanish one is layered
on top of it.

The messages themselves live in two catalogs, `scripts/lib/i18n/en.sh` and
`scripts/lib/i18n/es.sh`. Each is a set of `MSG[key]="text"` entries of a bash associative
array, so bash 4 or newer is required (as it already was). Scripts print through `t`:

```bash
ui_ok "$(t doctor.ssh.ok "${ssh_pub}")"      # MSG[doctor.ssh.ok] formatted with printf
```

Conventions:

- Keys are dot-separated and lowercase, prefixed with the script they belong to
  (`setup.`, `doctor.`, `deploy.`, `render.`, `wipe.`, `make.`, `ui.`, …).
- Placeholders are `printf` placeholders: `%s`, `%d`, and `%%` for a literal per cent sign.
  Nothing else is allowed, because the catalog value is used as the `printf` format string.
- A long block (the welcome screen, the final summary) is one entry containing newlines.
- A missing key is not fatal: `t` prints the key itself and one warning line on stderr.
- Player-facing text is **not** in the catalogs: the `servermsg` RCON warnings, the Discord
  notifications, and anything under `tools/` stay as they are.

`Makefile` target descriptions carry both languages inline:

```make
doctor: ## Check that everything is ready ## es: Revisa que este todo listo
```

Both catalogs must define exactly the same set of keys, and every key used with `t` must
exist. `scripts/i18n-check.sh` verifies both (plus the `printf` placeholders) and runs in CI
alongside shellcheck.

Language for new strings: English is sober and technical, second person, no jokes and no
exclamation marks. The Spanish is rioplatense and keeps the tone that is already there.
Command names, flags, paths and `make` targets stay literally identical in both languages.

## Reporting a problem

Use the "Cannot connect" issue template if the problem is joining the server. For anything else,
describe what you expected, what happened, and include the output of `make doctor`.
