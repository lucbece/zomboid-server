# Architecture

How the pieces fit together, and the design decisions currently in force. Operational procedures
are in [`runbook.md`](runbook.md); the provider-specific part is in
[`deploy-oracle.md`](deploy-oracle.md).

## Local layout

On any Linux host, the server is a single Docker Compose service. The versioned configuration is
rendered into the bind mount that the container reads.

```
config/*.tpl, *.lua, mods.txt ─┐
                               ├─> scripts/render-config.sh ─> data/zomboid/Server/
.env (secrets, ports, heap) ───┘                                        │
                                                                        v
                                        docker compose up ──> zomboid container
                                                                 │        │
                                       data/zomboid  <───────────┘        │
                                       data/workshop <──────────── Steam Workshop
```

Shutdown never goes through `docker stop`. `scripts/stop.sh` warns players over RCON, issues
`save` and `quit`, and waits for the container to exit on its own.

## Cloud deployment

```
./setup.sh
   │  writes
   ├──> infra/terraform/envs/prod/terraform.tfvars   (account, sizing, passwords)
   └──> .env                                          (local server config)
              │
              v
      make deploy ──> OpenTofu ──> infra/terraform/modules/oci
                                        │
                                        ├─ compartment, VCN, subnet, internet gateway
                                        ├─ network security group
                                        │     UDP 16261-16262   from anywhere
                                        │     TCP 22, 27015     from admin_cidr only
                                        │     TCP survey_port   only when > 0
                                        │     TCP panel_port    only when > 0
                                        ├─ VM.Standard.E5.Flex, Ubuntu 24.04
                                        │     user_data = infra/cloud-init.yaml (rendered)
                                        ├─ reserved public IP  (survives stop/start)
                                        ├─ Object Storage bucket + lifecycle rule
                                        ├─ dynamic group + IAM policy  (instance principal)
                                        ├─ budget + alert rules  (email only)
                                        └─ when bot_enabled: a second compartment holding an
                                           Always Free instance for the Discord bot, its own
                                           NSG (SSH from admin_cidr only), and a policy scoped
                                           to inspecting and power-cycling the game instance
                                        │
                                        v
                                   cloud-init, first boot
                                        ├─ flush the image's preinstalled iptables rules
                                        ├─ install Docker CE + compose plugin
                                        ├─ configure ufw
                                        ├─ clone the repo into /opt/zomboid-server
                                        ├─ write .env from terraform.tfvars, mode 0600
                                        ├─ build mcrcon
                                        ├─ configure rclone by instance principal
                                        ├─ install /etc/cron.d/zomboid (daily backup)
                                        ├─ enable zomboid-watchdog.timer (every 2 min)
                                        ├─ enable zomboid-mod-updater.timer (every 5 min)
                                        └─ enable zomboid.service
                                        │
                                        v
                              systemd ── docker compose up ── the game server
                                 ExecStop = scripts/stop.sh (RCON save + quit)
```

Operation afterwards:

```
admin machine                              VM
─────────────                              ──
make sync [RESTART=1] ──rsync──> config/, scripts/, tools/, infra/systemd/, Makefile, compose
make remote-* ──────────ssh───> make status | logs | up | down | restart, scripts/rcon.sh
make remote-backup ─────ssh───> scripts/backup.sh ──rclone──> Object Storage bucket
                                cron, daily ──────────────────┘
./scripts/cloud-stop.sh ──oci──> clean shutdown + backup, then SOFTSTOP
./scripts/cloud-start.sh ─oci──> START; the reserved IP is unchanged

on-demand                                  VM
─────────                                  ──
cron, every 5 min ──> scripts/idle-shutdown.sh
                        ├─ RCON `players` == 0 for IDLE_MINUTES
                        ├─ scripts/stop.sh + scripts/backup.sh
                        └─ shutdown -h now ──> the instance reaches STOPPED

Discord                     bot instance (separate, always on)
───────                     ──────────────────────────────────
/pz start|status|stop ──> tools/pz-bot/bot.py
                            ├─ GetInstance / InstanceAction ──oci──> the game VM
                            │     (instance principal, INSTANCE_INSPECT + POWER_ACTIONS)
                            ├─ A2S_INFO on UDP 16261 ──────────────> the game server
                            └─ edits its own reply until the game answers

moderators                                 VM
──────────                                 ──
http://ip:8081/m/<token> ──POST──> tools/panel/server.py ──> scripts/restart.sh (detached)

unattended                                 VM
──────────                                 ──
zomboid-watchdog.timer, every 2 min ──> scripts/watchdog.sh
                                          ├─ restart / stop+bundle+up / disk cleanup
                                          ├─ notify ──────────────────> Discord webhook
                                          └─ escalate ──> scripts/autorepair.sh (opt-in)
                                                            └─ claude -p, tools restricted

zomboid-mod-updater.timer, every 5 min ──> scripts/mod-updater.sh
                                          ├─ Steam API time_updated vs appworkshop_108600.acf
                                          ├─ servermsg countdown ──> the players in game
                                          ├─ scripts/restart.sh (shares /var/tmp/zomboid-ops.lock
                                          │                      with the watchdog)
                                          └─ notify ──────────────────> Discord webhook

zomboid-notifier.service, always on ──> tools/discord-notifier/notifier.py
                                          ├─ docker compose logs -f   SERVER STARTED, version
                                          ├─ docker events            the container stopped
                                          ├─ data/zomboid/Logs/*_user.txt  joins, leaves, deaths
                                          ├─ data/zomboid/Logs/*_PerkLog.txt  hours survived
                                          ├─ scripts/rcon.sh players  how many are connected
                                          └─ post ────────────────────> Discord webhook
```

`make sync` deliberately excludes `.env`, `data/` and `bin/`. The VM's `.env` is generated by
cloud-init from `terraform.tfvars` and is never synchronised or committed.

## Decisions in force

| Decision | Rationale |
|---|---|
| Docker Compose on Ubuntu 24.04 | Reproducible across providers; the image encapsulates SteamCMD and the JRE. |
| Image `danixu86/project-zomboid-dedicated-server`, pinned by digest | The actively maintained image with explicit Build 42 support and an option not to overwrite the ini. Pinning by digest means the game version changes only when the digest does. |
| `SELF_MANAGED_MODS=1` | Without it the entrypoint sets `Mods=` and `WorkshopItems=` from its own variables, blanking them when those are unset. With it, both keys are left to `render-config.sh`. |
| `config/` is the source of truth | The ini template, sandbox, spawn files and mod list are versioned; secrets are substituted from `.env` at render time. Files under `data/` are generated. |
| Server name `servertest` | It is the game's default and it names every configuration file. Renaming it means renaming all of them. |
| Shutdown by RCON `save` + `quit` | The game does not handle `SIGTERM` reliably, and a large world takes longer to write than the default grace period. `stop_grace_period` is a backstop, not the mechanism. |
| Reserved public IP | An ephemeral address is lost when the instance stops. Players keep `address:16261` in their favourites, so it has to survive stop/start cycles. On Oracle Cloud a reserved IP is free. |
| Backups by `rclone` under instance principal | The VM authenticates with its own instance certificate. No API key or secret is stored on the disk; the permissions come from the dynamic group and policy created by OpenTofu. |
| ufw on the host plus a network security group | Defence in depth with the same rules in both. Docker publishes ports through `DOCKER-USER`, bypassing ufw's `INPUT` chain, so for the game ports the effective filter is the security group; ufw protects host services such as SSH. |
| `repo_url` determines the clone mode | An `https://` URL is cloned anonymously and no key pair is created. An SSH URL causes OpenTofu to generate an ed25519 deploy key, which must be registered on GitHub before first boot. |
| Budget alerts by email only | An automated spend cap that could delete a running world is worse than a late email. |
| OpenTofu, one module per provider | The VM is disposable; what persists is the repository and the backup bucket. `preserve_boot_volume` is false for the same reason. |
| The idle shutdown is only enabled together with the bot | Powering the VM off automatically would leave players with no way to bring it back. The cron line ships commented out and `make idle-shutdown-install` turns it on once `/pz start` has been shown to work. The two halves are one feature. |
| The bot runs on its own instance, in its own compartment | It cannot live on the game VM, which is off precisely when it is needed. The compartment is not cosmetic: OCI has no policy variable naming a specific instance — the general variables stop at `target.compartment.id`, and the Core Services table adds only `target.boot-volume.kms-key.id` and `target.image.id`. Keeping the bot out of the game's compartment is what makes "power-cycle instances in compartment `zomboid`" mean one machine, and not include the bot itself. See [`on-demand.md`](on-demand.md). |
| The bot decides "is the server up" from A2S, not from the instance state | `RUNNING` means the VM booted, not that the game finished loading its mods — the three minutes between the two are the whole reason `/pz start` follows up instead of answering once. A2S also gives the player count that `/pz stop` refuses to act without, and the name, map and version that the messages quote, so nothing about the server is duplicated in the bot's configuration. |
| `/pz stop` refuses when A2S does not answer | An unreachable server is not an empty one: it may be loading with people waiting to join. The failure mode of refusing is a message; the failure mode of guessing is somebody's progress. |
| The watchdog only restarts and cleans up | It runs unattended every two minutes, so every action it can take has to be one that is safe to take at 3 a.m. with nobody watching. Restarting is idempotent and disk cleanup only removes what regenerates or is already in the bucket; wipe, restore and configuration changes are not, so they are not in the playbook. See [`self-healing.md`](self-healing.md). |
| Fatal log patterns live in two files, one of them subtractive | A Project Zomboid log is full of `ERROR` and `SEVERE` lines from mods that mean nothing. A broad fatal list plus an explicit ignore list makes a false positive a one-line fix in the ignore file, instead of a progressively narrower regex nobody dares to touch. A false positive costs every player a two-minute restart. |
| Escalation to Claude Code is opt-in and off by default | Layer 1 handles the failures that actually happen. Layer 2 gives an agent a shell on the machine that holds the world: the tool allowlist and the hard rules are mitigations, not a sandbox, so the decision to accept that trade belongs to whoever runs the server, not to the template. |
| The auto-repair never commits | Whatever it changes stays in the VM's working tree, surfaced by `make remote-diff`, so a person reviews it before it becomes the configuration of record. A disabled mod is a decision about everyone's game, not a fix. |
| The status notifier reads the game's log files, not RCON polling | RCON `players` gives a count, not events: it cannot say who arrived or when, and polling it often enough to feel live is a request every few seconds against the game loop. The `_user.txt` file already records every join and leave with a timestamp and a Steam ID, so RCON is left for the count and for a reconciliation once a minute. See [`discord.md`](discord.md). |
| Leaves come from `Connection disconnect`, not from `disconnected player` | The line that reads like a disconnect is also written when a player dies and respawns, followed by a fresh `fully connected` a tenth of a second later. `Connection disconnect … id=<steam id>` is the only line present for all three real cases — quit, timeout and server shutdown — and it carries the Steam ID, which resolves to a name from earlier in the same file. |
| The server password goes in the Discord message by default | The channel is the group's private channel, and the alternative is somebody asking for the password every time a friend reinstalls. It is a default, not a rule: `NOTIFIER_INCLUDE_PASSWORD=0` drops it, and the trade — the message is as durable and as widely readable as the channel — is written down in [`discord.md`](discord.md). |
| Every status message says the same five things | State, IP, port, password and version, with the server name in the title, whether the server just started or the daemon was installed against one that was already running. A message that qualified itself ("this is only the current state") made the reader work out what was being claimed; a message that always states the state does not. |
| The moderator panel authenticates by URL token, over plain HTTP | There is no domain name, so there is no certificate and no login worth the name. A 32-byte token in the path is as strong as the channel allows, and the blast radius is deliberately one action: a clean restart, rate-limited and logged. See [`panel.md`](panel.md). |
| The panel restarts the game, never the VM | It runs on the VM, so it cannot power one on; and a moderator who could stop the instance could strand everyone, including the administrator. Wipe and restore stay behind SSH for the same reason. |

## History

The original planning document and the research notes that led to these decisions are kept, in
Spanish, under [`history/`](history/). They are a record, not a specification: where they disagree
with this document, this document is correct.
