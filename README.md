# zomboid-server

*Leer en español: [README.es.md](README.es.md)*

A reproducible dedicated server for **Project Zomboid Build 42**, run with Docker Compose. The
game rules, the server settings and the mod list live in `config/` under version control, so the
same world can be rebuilt on any machine from this repository plus a backup archive. Operation is
done through `make` targets that always shut the game down cleanly over RCON, so the world is
saved before the process exits.

It runs on any Linux machine with Docker: a spare desktop, a home server, or a VPS. Deploying to
a cloud provider is supported as one option, not as a requirement — see
[Deploying to a cloud provider](#deploying-to-a-cloud-provider).

## Features

- Build 42 dedicated server on a pinned image digest: the game version only changes when you
  change it.
- Game rules, spawn points, spawn regions and server settings versioned in `config/`; secrets
  kept out of git in `.env`.
- Vanilla by default. Workshop mods are declared in a single text file (`config/mods.txt`) that
  also defines load order, and are kept in step with the Workshop automatically so a mod update
  does not lock players out.
- Clean shutdown and restart: RCON `save` + `quit`, never a bare `docker stop`.
- Backups: a `save`-then-archive script with optional upload to object storage, plus restore and
  wipe procedures.
- Self-healing: a watchdog checks the server every two minutes, recovers from the common
  failures on its own and reports to Discord.
- Optional web survey for the group to vote on the sandbox rules before the world is created.
- Optional one-command deployment to Oracle Cloud with OpenTofu, including a reserved public IP,
  daily off-machine backups and a monthly budget alert.

## Requirements

- Linux with Docker Engine and the Docker Compose plugin. On Windows, use WSL2.
- `make`, `bash` 4 or newer, `git`, `gcc` (to build the RCON client), and `gettext-base` for
  `envsubst`.
- About 15 GB of free disk: the server image is roughly 10.4 GB, plus the world and backups.
- RAM: the JVM heap is set by `MAX_MEMORY` in `.env`. 8 GB of heap is enough for up to 8 players,
  12 GB for up to 16. Leave about 4 GB on top of the heap for the operating system and Docker.
- Every player needs Project Zomboid on Steam on the **stable branch (Build 42)**, with no beta
  selected.

## Quick start

Run the server on a Linux machine you already have.

```bash
git clone https://github.com/lucbece/zomboid-server.git
cd zomboid-server
cp .env.example .env
```

Edit `.env` and set at least `ADMINPASSWORD`, `RCONPASSWORD` and `SERVER_PASSWORD`. These are
three different passwords:

| Name in `.env` | What it is |
|---|---|
| `SERVER_PASSWORD` | The **server password**. Players type it to join. This is the one you hand out. |
| `ADMINPASSWORD` | The **admin password** for the in-game `admin` account. Keep it to yourself. |
| `RCONPASSWORD` | The **RCON password**, used by the management scripts. Never exposed to players. |

Passwords must be 8 to 64 characters and must not contain spaces, quotes, backslashes or `$`:
`.env` is read both by bash and by Docker Compose, which do not escape the same way.

Then start the server:

```bash
make mcrcon    # builds ./bin/mcrcon, the RCON client used by the scripts
make up        # renders config/ into the data directory and starts the container
make logs      # the server is ready when it prints "*** SERVER STARTED ****"
```

The first start downloads the image and generates the world; expect several minutes. To stop:

```bash
make down      # warns players, saves over RCON, then quits
```

Do not stop the container with `docker stop` or `docker kill`. The game does not handle SIGTERM
reliably and the world can be left in an inconsistent state.

### Connecting from the game

In Project Zomboid on the stable branch, with no Steam beta selected:

1. Main menu → **Join**.
2. **Favorites** tab → **Add server**.
3. Fill in:
   - **Name**: any label, local to the player.
   - **IP**: the server's address. On a local network, the machine's LAN address.
   - **Port**: `16261`.
   - **Account username** and **Account password**: chosen by each player. They are created on
     first join and are not the server password.
   - **Server password**: the value of `SERVER_PASSWORD`.
4. **Save**, then **Join**.

To grant in-game administrator rights to a player who has already logged in once:

```bash
make rcon CMD='setaccesslevel "player_name" admin'
```

## Configuration

Everything under `config/` is the source of truth. Files under `data/` are generated and must not
be edited by hand: `make render` (run automatically by `make up` and `make restart`) rewrites them
from `config/` plus `.env`.

| File | What it controls |
|---|---|
| `config/servertest.ini.tpl` | Server settings: PVP, max players, visibility, chat, anti-cheat, native backups. Secrets are placeholders filled from `.env`. |
| `config/servertest_SandboxVars.lua` | Game rules: zombie count and behaviour, loot, weather, XP rates, erosion. Each value is documented in place. |
| `config/servertest_spawnpoints.lua` | Where new characters spawn. |
| `config/servertest_spawnregions.lua` | Which spawn regions are offered. |
| `config/mods.txt` | Workshop mods, one per line; file order is load order. Not in git: `setup.sh` creates it from `config/mods.example.txt`, and without it the server runs vanilla. |
| `.env` | Passwords, ports, JVM heap, backup settings. Not in git. |

Apply configuration changes with:

```bash
make restart
```

Note: several sandbox options are fixed when the world is first generated — the loot map size,
the initial zombie population and the erosion speed among them. Changing them later has no
effect on an existing world. Decide those before the first real session, or start a new world
with `make wipe`.

Two keys in `config/servertest.ini.tpl` should not be changed on a live world: `ServerPlayerID`
and `ResetID`. If they change, every client is forced to create a new character. They are
versioned precisely so a rebuilt server keeps the same identity.

By default the template sets `Public=true`, so the server is listed in the in-game browser and
protected by the server password. Set `Public=false` if you want it to be reachable only by
direct IP.

### Mods

The server runs vanilla until you declare mods. The list lives in `config/mods.txt`, which is
specific to your world and therefore not versioned; `setup.sh` creates it from
`config/mods.example.txt`, or copy the example yourself:

```bash
cp config/mods.example.txt config/mods.txt
```

Add one line per Workshop item with the Workshop ID and the Mod ID, then `make restart`
(or `make sync RESTART=1` against a cloud VM):

```
3750253491  VB_CommonSense  # Common Sense
```

On a first cloud deployment the file is shipped to the VM with the rest of the configuration, so
the world is created with the mods already loaded. If the file is missing, the render step refuses
to turn a world that had mods into a vanilla one; `ALLOW_VANILLA=1 make restart` overrides that
on purpose.

Removing a mod from a world that already contains its items or map cells can corrupt saves. Take
a backup first. Full procedure, including how to read a mod's `require=` dependencies and how to
diagnose a mod that fails to load: [`docs/mods.md`](docs/mods.md).

#### Keeping up with the Workshop

The server downloads mods only when it starts, while Steam updates the same mods on the players'
machines by itself. So when an author publishes a new version with the server already running,
every player who has received it is a version ahead and cannot connect — the server reads as
incompatible, or simply as offline — until somebody restarts it. On the cloud VM a systemd timer
runs `scripts/mod-updater.sh` every five minutes to close that gap: it compares each mod's
`time_updated` in the Steam API against what SteamCMD actually installed, and when something has
fallen behind it restarts — immediately if nobody is connected, or after a fifteen-minute
countdown announced in game and on Discord if there is. If the API does not answer it does
nothing at all. `MOD_UPDATE_AUTO_RESTART=0` reduces it to a notification. See
[`docs/mods.md`](docs/mods.md).

```bash
make mods-check            # per mod: Workshop date, installed date, verdict
make mod-updater-install   # install and enable the timer on an existing VM
make mod-updater-status    # next run, last result, tail of the log
```

## Operations

| Command | What it does |
|---|---|
| `make up` | Render the config and start the server |
| `make down` | Clean shutdown: warning, `save`, `quit` |
| `make restart` | Clean shutdown, re-render, start — the way to apply config and mod changes |
| `make logs` | Follow the server log |
| `make status` | Container state and connected players |
| `make rcon CMD=players` | Run any admin command over RCON |
| `make backup` | `save`, archive the world, upload if a bucket is configured. `LABEL=` adds a suffix |
| `make restore FILE=…` | Restore an archive over the current world |
| `make wipe` | Delete the world after a `pre-wipe` backup. Asks for confirmation |
| `make update` | Backup, clean shutdown, `docker compose pull`, start |
| `make render` | Regenerate the rendered config without restarting |
| `make mcrcon` | Build the RCON client into `./bin/mcrcon` |

Run `make help` for the full list, including the cloud targets.

### Backups

`make backup` runs `save` over RCON, archives `Saves/Multiplayer/servertest`, `Server/` and `db/`
into `backups/` as a `.tar.zst`, and copies it to object storage when `BACKUP_BUCKET` is set in
`.env`. Local archives older than `BACKUP_KEEP_LOCAL_DAYS` are removed. It also works with the
server stopped, in which case the `save` step is skipped.

The game's own rolling backups are configured in `config/servertest.ini.tpl`
(`BackupsCount`, `BackupsPeriod`, `BackupsOnStart`) and land in `data/zomboid/backups/`. They are
a short-term safety net, not a substitute for off-machine copies.

Restoring asks for confirmation, stops the server, archives the current world as `pre-restore`,
and then extracts the chosen archive:

```bash
make restore FILE=backups/zomboid-20260903-0600.tar.zst
```

### Updating the game

The image is pinned by digest in `docker-compose.yml`, so nothing updates on its own. To move to
a newer build, resolve the digest of the tag you want, edit `docker-compose.yml`, and run
`make update`. A new image can bring a new game version; clients on an older version will be
rejected until Steam updates them. The procedure is in [`docs/runbook.md`](docs/runbook.md).

## Exposing the server from a home network

The server listens on UDP `16261` and `16262`. RCON listens on TCP `27015` and is bound to
`127.0.0.1`, so it is not reachable from outside the host.

To let friends connect to a machine on your home network:

1. Give the machine a static address on the LAN, or a DHCP reservation.
2. Forward UDP `16261-16262` from the router to that address. Do not forward `27015`.
3. Hand out your public IP address and the server password.

Two caveats. Most residential connections have a dynamic public IP, so the address changes
periodically; a dynamic DNS hostname avoids re-sending it after every change. And connections
behind CGNAT have no forwardable public address at all. In both cases a tunnel service or an
overlay network (Tailscale, ZeroTier, Cloudflare Tunnel and similar) is the usual workaround;
this repository does not configure one.

## Deploying to a cloud provider

If you would rather not run the server at home, the repository can provision a virtual machine
and configure it end to end. **Oracle Cloud** is the provider supported today, for three reasons:
it has a São Paulo region, a stopped instance is not billed for compute, and its reserved public
IP addresses are free, so the address survives stop/start cycles.

Two commands, after the Oracle Cloud account exists:

```bash
./setup.sh      # interactive wizard: checks tools, generates passwords, writes the config
make deploy     # creates the infrastructure and waits for the game to come up
```

`setup.sh` sizes the machine from the number of players you declare: up to 8 players it selects
2 OCPU / 12 GB with an 8 GB heap, above that 4 OCPU / 16 GB with a 12 GB heap. Set `ZS_OCPUS`
and `ZS_MEMORY_GB` to override.

Approximate list prices for the `VM.Standard.E5.Flex` shape as of 2026-09
(0.03 USD per OCPU-hour, 0.002 USD per GB-hour). Re-check them before committing: prices change,
and local taxes on foreign digital services are charged on top.

| VM size | Players | Per hour | ~20 h/week | ~6 h/day | 24/7 |
|---|---|---|---|---|---|
| 2 OCPU / 12 GB | up to 8 | 0.084 USD | ~7 USD/month | ~15 USD/month | ~61 USD/month |
| 4 OCPU / 16 GB | up to 16 | 0.152 USD | ~13 USD/month | ~28 USD/month | ~111 USD/month |

The 80 GB boot volume costs about 2 USD/month and is billed whether the machine is running or
not. Backups in object storage cost cents. The reserved IP is free.

Note: a running VM is billed whether or not players are connected. Stop it with
`./scripts/cloud-stop.sh`, which saves the world, takes a backup and shuts the instance down;
`./scripts/cloud-start.sh` brings it back with the same address. `make destroy-all` deletes
everything and stops all charges.

Account setup, API keys, the full deployment walkthrough, cost details and Oracle-specific
troubleshooting are in [`docs/deploy-oracle.md`](docs/deploy-oracle.md).

### Other providers

The Terraform code is organised as `infra/terraform/modules/<provider>` with a thin environment
in `infra/terraform/envs/prod`, so another provider can be added as a sibling module. A new
module has to supply: an Ubuntu 24.04 VM with a public address, ingress for UDP 16261-16262 from
anywhere and TCP 22 restricted to the administrator, the rendered `infra/cloud-init.yaml` as user
data, and — optionally — an object storage bucket plus credentials for the backup upload. The
cloud-init file itself is provider-neutral.

## Rules survey

`tools/encuesta/` is a small self-hosted web survey that lets a group vote on the sandbox rules
before the world is created. It serves a mobile-friendly page, records one JSON line per vote,
tallies the results and can write the winning options straight into `config/`. It is optional and
off by default. See [`docs/survey.md`](docs/survey.md), including the security considerations of
running it over plain HTTP.

## Moderator panel

`tools/panel/` is an optional web page that lets two to four trusted people restart the game
server without an SSH account: it shows the server state and the connected players, and offers a
single button that runs the same clean restart as `make restart`. Each moderator gets their own
link, which is also their credential, and restarts are rate-limited and logged. It is optional
and off by default. See [`docs/panel.md`](docs/panel.md), including the security model of
handing out an unauthenticated URL over plain HTTP.

## Self-healing

A systemd timer runs `scripts/watchdog.sh` every two minutes on the VM. It checks the unit, the
container, RCON, the log and the free disk space; when something is wrong it applies a fixed
playbook — a clean restart, or a stop, a diagnostic bundle and a fresh start, or a disk cleanup —
and posts the outcome to a Discord channel if `DISCORD_WEBHOOK_URL` is set. It is capped at two
automatic restarts per hour, and it never wipes, restores, deletes a save or edits `config/`.
When the playbook is not enough it escalates: to a human by default, or optionally to Claude Code
running headless on the machine with a deliberately narrow set of tools. See
[`docs/self-healing.md`](docs/self-healing.md) for what it detects, what it never does, how to
create the Discord webhook, and the risks of the optional second layer.

```bash
make watchdog-install    # install and enable the timer on an existing VM
make watchdog-status     # next run, last result, tail of the log
make remote-diff         # what the auto-repair changed on the VM, still uncommitted
```

## Discord

Two independent integrations, either of which can be left off. The game's own chat bridge mirrors
global chat into a channel and needs a bot with the Message Content intent; it is off by default.
The status notifier is a small systemd daemon on the VM that posts to a webhook when the server
comes up, when it goes down, and when players join or leave. The status message is titled with
the server's name and carries five fields — state, IP, port, password and game version — so
nobody has to ask how to get in. It shares `DISCORD_WEBHOOK_URL` with the watchdog, groups events inside a 30-second window,
and stays quiet if no webhook is configured. Putting the password in a channel is a decision:
`NOTIFIER_INCLUDE_PASSWORD=0` leaves it out. See [`docs/discord.md`](docs/discord.md) for both
integrations, how to create the webhook, and how joins and leaves are read out of the game's logs.

```bash
make notifier-install    # install and enable the daemon on an existing VM
make notifier-status     # unit state and the last 20 journal lines
```

## On-demand start and stop

The server does not have to run while nobody is playing. `scripts/idle-shutdown.sh` powers the
VM off after 30 minutes with no players — saving the world and uploading a backup first — and a
Discord bot on a separate always-on instance powers it back on. Oracle Cloud does not bill
compute for a stopped instance, and the reserved IP survives the cycle, so the address the
players keep in their favourites never changes.

`/pz start` answers immediately and then edits its own message until the game answers an
`A2S_INFO` query, ending in "En línea". `/pz status` reports what the server itself says: name,
map, players, version. `/pz stop` refuses unless the server reports zero players, and refuses
just as firmly when it cannot tell. The bot authenticates to the cloud API as an instance
principal with permission to inspect and power-cycle exactly one instance — no credentials on
disk. See [`docs/on-demand.md`](docs/on-demand.md) for the Discord application, the free-tier
shapes and what the cycle costs.

```bash
make bot-install            # deploy or update the bot on its instance
make bot-status             # unit state and the last journal lines
make idle-shutdown-install  # enable the idle shutdown, once the bot works
```

## Documentation

| Document | Contents |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | How the pieces fit together and the design decisions in force |
| [`docs/runbook.md`](docs/runbook.md) | Operations reference: deployment, backups, wipes, updates, troubleshooting |
| [`docs/deploy-oracle.md`](docs/deploy-oracle.md) | Deploying to Oracle Cloud: account, API key, `setup.sh`, `make deploy`, costs |
| [`docs/mods.md`](docs/mods.md) | Adding, removing and debugging Workshop mods, and keeping them in step with the Workshop |
| [`docs/survey.md`](docs/survey.md) | The rules survey: running it, tallying it, closing it |
| [`docs/panel.md`](docs/panel.md) | The moderator panel: tokens, cooldowns, security model |
| [`docs/self-healing.md`](docs/self-healing.md) | The watchdog, the Discord alerts and the optional Claude Code auto-repair |
| [`docs/discord.md`](docs/discord.md) | The two Discord integrations: the native chat bridge and the status notifier |
| [`docs/on-demand.md`](docs/on-demand.md) | Idle shutdown and the Discord bot that starts the server on demand |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Checks to run before opening a pull request |
| [`docs/history/`](docs/history/) | The original plan and research notes, in Spanish. Historical, not maintained |

## License

[MIT](LICENSE). Project Zomboid is a product of The Indie Stone; this project is not affiliated
with them.
