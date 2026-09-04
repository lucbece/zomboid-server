# On-demand server

The server does not need to run while nobody is playing. This document describes the pair of
mechanisms that make that safe: the game VM powers itself off after a period with no players,
and a Discord bot on a separate always-on instance powers it back on.

Neither half works alone. Powering the VM off automatically without a way to start it again
would leave the players locked out; a start command without an idle shutdown saves nothing.

## The cycle

```
players leave
      │
      v
scripts/idle-shutdown.sh (cron, every 5 min on the game VM)
      ├─ RCON `players` reports 0 for IDLE_MINUTES in a row
      ├─ scripts/stop.sh   (RCON save + quit)
      ├─ scripts/backup.sh (uploaded to the Object Storage bucket)
      └─ shutdown -h now  ──> the instance reaches STOPPED, compute is no longer billed
      │
      v
   (nothing runs, nothing is charged except the boot volume)
      │
      v
someone types /pz start in Discord
      │
      v
tools/pz-bot (always-on instance)
      ├─ GetInstance      -> STOPPED
      ├─ InstanceAction START
      └─ polls A2S_INFO on UDP 16261 until the game answers, editing its own message
      │
      v
the game VM boots ──> zomboid.service ──> the server loads its mods (~3 min)
      │
      v
tools/discord-notifier posts "En línea" with the address, password and version
```

The reserved public IP survives stop/start, so the `address:16261` entry the players keep in
their favourites never changes.

## Why the bot is a second instance

The bot cannot live on the game VM: the whole point is that the game VM is off. It runs on a
small instance that stays on permanently, which is affordable only because it fits in Oracle
Cloud's Always Free allowance.

That instance holds no world data, no backups and no cloud credentials. It authenticates to the
OCI API as an instance principal, and its policy is deliberately minimal:

```
Allow dynamic-group zomboid-bot-dg to use instances in compartment zomboid
  where all {
    target.instance.id = '<the game instance>',
    any { request.permission = 'INSTANCE_INSPECT', request.permission = 'INSTANCE_READ', request.permission = 'INSTANCE_POWER_ACTIONS' }
  }
```

`INSTANCE_INSPECT` covers `ListInstances`, `INSTANCE_READ` covers `GetInstance` (reading the
lifecycle state; inspect alone is not enough for it) and `INSTANCE_POWER_ACTIONS` covers
`InstanceAction` (`START` and `SOFTSTOP`). The bare `use
instances` verb would also grant `INSTANCE_UPDATE` and volume attachment; the
`request.permission` clause removes them. The `target.instance.id` clause pins the policy to the
game instance, so the bot cannot touch anything else in the compartment — not the backup bucket,
not the network, not itself.

## Commands

All three are guild-scoped slash commands, registered on startup against `PZ_BOT_GUILD_ID` so
they appear immediately. Global registration takes up to an hour.

| Command | Who | What it does |
|---|---|---|
| `/pz start` | any member (or `PZ_BOT_ALLOWED_ROLE_IDS`) | Starts the VM if it is `STOPPED`, answers "Prendiendo el server, tarda ~3 minutos" immediately, then edits that message every few seconds until A2S answers, ending in "En línea · IP:puerto". If the VM is already running it reports the player count instead. |
| `/pz status` | same | Lifecycle state of the VM. If it is running, the name, map, player count and version reported by the server itself over A2S, plus how long it has been up. |
| `/pz stop` | `PZ_BOT_ADMIN_USER_IDS`, or anyone if that is empty | Refuses unless A2S reports zero players, and refuses if A2S does not answer at all — an unreachable server is not the same as an empty one. Otherwise issues `SOFTSTOP`. |

`SOFTSTOP` rather than `STOP`: it asks the operating system to shut down, which runs the
`ExecStop` of `zomboid.service` — `scripts/stop.sh`, an RCON `save` followed by `quit` — before
the machine goes away. `STOP` is the equivalent of pulling the power cable on a world that has
not been written to disk.

Everything the bot says about the game comes from the A2S response, not from configuration: the
server name, the map and the version are whatever the server reports.

## Creating the Discord application

1. <https://discord.com/developers/applications> → **New Application**. The name is what members
   see in the member list.
2. **Bot** → **Reset Token**. Copy it once; it is shown only at that moment. This is the value of
   `discord_bot_token` in `terraform.tfvars`.
3. Leave every **Privileged Gateway Intent** off. The bot only handles slash commands; it never
   reads message content, and requesting intents it does not need would block verification later.
4. **OAuth2** → **URL Generator**: scopes `bot` and `applications.commands`, bot permissions
   `Send Messages`, `Embed Links` and `Read Message History` (integer `84992`). Open the
   generated URL and add the bot to the server.
5. Copy the server's ID (Discord settings → Advanced → Developer Mode, then right-click the
   server → Copy Server ID) into `bot_guild_id`.

To restrict who can use the commands, copy user or role IDs the same way into
`bot_admin_user_ids` and `bot_allowed_role_ids`. Both are comma-separated and both default to
empty, which means "everyone in the server". Note that an empty `bot_admin_user_ids` still does
not let anyone shut down an occupied server: the zero-player check is unconditional.

## Deploying

```bash
# infra/terraform/envs/prod/terraform.tfvars
bot_enabled       = true
bot_guild_id      = "000000000000000000"
discord_bot_token = "..."          # gitignored file; the token also lands in the local .tfstate
```

```bash
make infra-apply          # or: tofu -chdir=infra/terraform/envs/prod apply
make bot-status           # the log should end in "conectado como <bot>"
```

`tofu apply` must report `0 to change` and `0 to destroy` for
`module.zomboid.oci_core_instance.this`. Everything the bot adds is behind `bot_enabled`, which
defaults to `false`; nothing in this feature modifies the game instance.

Afterwards, and only once `/pz start` has been shown to work end to end:

```bash
make idle-shutdown-install   # uncomments the cron line on the running game VM
make idle-shutdown-status
```

`IDLE_MINUTES` in the VM's `.env` sets the threshold; it defaults to 30. New VMs get the same
line from `infra/cloud-init.yaml`.

To update the bot's code on an instance that already exists:

```bash
make bot-install    # rsync of tools/pz-bot and infra/systemd, pip install, restart
make bot-logs
```

## Always Free limits, and what to do when there is no capacity

The bot instance is `VM.Standard.A1.Flex` with 1 OCPU and 6 GB — the smallest valid Ampere
shape, and well inside the Always Free allowance of 2 OCPU and 12 GB of A1 capacity per tenancy.
Its 50 GB boot volume fits in the 200 GB of free block storage.

A1 capacity in a given region is frequently exhausted. If `tofu apply` fails with **Out of host
capacity**, the alternative is the other Always Free shape:

```hcl
bot_shape = "VM.Standard.E2.1.Micro"    # x86, 1 OCPU, 1 GB, fixed
```

and apply again. The image data source filters the catalogue by shape, so it picks the aarch64
image for A1 and the x86 image for E2, with no further changes. `bot_ocpus` and `bot_memory_gb`
are ignored for a fixed shape — the module only emits `shape_config` for `.Flex` shapes.

1 GB is enough: the bot idles at well under 100 MB. The trade-off is that `pip install` of the
OCI SDK on first boot is slower, and there is no headroom for anything else on that machine.

If neither shape has capacity, the bot can also be run anywhere else that stays on — including a
machine at home — with `PZ_BOT_OCI_AUTH=config` and an API key in `~/.oci/config`. That
reintroduces a credential on disk, which is exactly what the instance-principal design avoids, so
it is a fallback rather than an option.

## Cost

Oracle Cloud does not bill compute for an instance in the `STOPPED` state. The boot volume is
billed either way.

For the deployed configuration — `VM.Standard.E5.Flex`, 2 OCPU and 12 GB, an 80 GB boot volume —
at list prices of USD 0.03 per OCPU-hour and USD 0.002 per GB-hour:

| | Compute | Storage | Total |
|---|---|---|---|
| Always on (730 h) | ~USD 61 | ~USD 2 | **~USD 63 / month** |
| 3 h/day (90 h) | ~USD 8 | ~USD 2 | **~USD 10 / month** |

The bot instance adds nothing while it stays inside the Always Free allowance. Check the current
rates before relying on the figures; the shape of the result — roughly an 85% reduction for a
group that plays a few evenings a week — is what matters.

The budget alert configured by the module (`budget_usd`, `alert_email`) is unaffected and still
the backstop.

## Failure modes

| What happens | What the player sees | What to do |
|---|---|---|
| The game VM is `STOPPED` and `/pz start` is issued | "Prendiendo el server, tarda ~3 minutos", then "En línea" | nothing |
| The VM boots but the server does not answer A2S within 7 minutes | "El server no respondió después de 7 min" | `make remote-logs`; usually a mod that fails to load |
| Two people run `/pz start` at once | The second one sees "El server ya se está prendiendo" | nothing; `START` on a running instance is not issued twice |
| `/pz stop` while someone is connected | "Hay N jugadores conectados: no se apaga" | nothing |
| `/pz stop` while the server is loading | "El juego no responde, así que no se puede saber si hay gente jugando" | retry in a minute |
| The bot's policy has not propagated yet | "OCI rechazó la credencial del bot" or "OCI no encuentra la instancia" | wait a few minutes after `tofu apply`; IAM changes are not immediate |
| The bot instance is down | The commands are greyed out or time out | `make bot-status`; `systemd` restarts it every 15 s |

The idle shutdown never fires blind either: if RCON does not answer while the container is
running, it resets its counter instead of assuming the server is empty.
