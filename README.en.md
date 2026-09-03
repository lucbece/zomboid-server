# Your own Project Zomboid server

Run a **Project Zomboid Build 42** dedicated server for you and your friends on Oracle Cloud, in
three commands. No sysadmin experience needed.

> The full, step-by-step guide is in Spanish: **[README.md](README.md)**. This page is a summary.

```bash
git clone https://github.com/lucbece/zomboid-server.git && cd zomboid-server
./setup.sh      # interactive wizard: checks tools, generates passwords, writes the config
make deploy     # creates the server (20-40 minutes the first time)
```

When it finishes it prints the IP, the port and the server password to hand to your friends.

## What you get

8-16 players, a fixed IP that survives reboots, daily off-machine backups with 30-day retention,
Workshop mods managed from a text file, all game rules in version control, monthly budget alerts
by email, and a clean shutdown that always saves the world first.

## Cost

| Usage | Per month |
|---|---|
| Always on (24/7) | ~90 USD |
| Powered on only when you play (~20 h/week) | ~11-15 USD |

The boot disk costs 2-3 USD/month even while the machine is off. Backups cost cents. The fixed
IP is free. `./scripts/cloud-stop.sh` and `./scripts/cloud-start.sh` power the machine off and on
without losing the world or the IP; `make destroy-all` deletes everything and stops all charges.

## Requirements

- Linux or macOS. On Windows, install WSL2 (`wsl --install -d Ubuntu` in an admin PowerShell) and
  work inside it.
- An Oracle Cloud account with a credit card, upgraded to Pay As You Go, plus an API key in
  `~/.oci/config`. `./setup.sh` walks you through it and `make doctor` tells you what is missing.
- Project Zomboid on Steam, stable branch (Build 42), for you and each player.
- A GitHub account is **optional** — only needed if you want to fork the repo and keep your own
  mods and rules.

OpenTofu and the Oracle CLI are installed by `./setup.sh` into `~/.local/bin` and `~/.venvs/oci`.
No `sudo` required.

## Everyday commands

| Command | What it does |
|---|---|
| `make doctor` | Check everything and explain what is missing |
| `make remote-status` | Is it up? Who is playing? |
| `make remote-logs` | Follow the server log |
| `make remote-restart` | Clean restart, applies mod and rule changes |
| `make remote-backup` | Take a backup right now |
| `make sync RESTART=1` | Push your local config changes to the server and restart |
| `make destroy-all` | Delete everything and stop paying |

Mods go in `config/mods.txt` (one line: `workshop_id  mod_id  # name`). Game rules go in
`config/servertest_SandboxVars.lua` — set them **before** the world is created, since several are
baked in at world generation.

## How it works

OpenTofu creates the Oracle Cloud infrastructure (compartment, VCN, network security group,
`VM.Standard.E5.Flex` 4 OCPU / 16 GB running Ubuntu 24.04, reserved public IP, Object Storage
bucket with a lifecycle rule, and a monthly budget with alerts). cloud-init provisions the VM on
first boot: Docker, a clone of this repo, the `.env`, a systemd unit and a daily backup cron.
Docker runs the game; systemd stops it through RCON `save` + `quit` so the world is never lost.

Details, decisions and sources: [`docs/runbook.md`](docs/runbook.md), [`PLAN.md`](PLAN.md) and
[`docs/research/`](docs/research/) — all in Spanish.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Docs and user-facing messages are written in Spanish on
purpose: the target audience is a non-technical Spanish-speaking player.

Licensed [MIT](LICENSE). Project Zomboid belongs to The Indie Stone; this project is not
affiliated with them.
