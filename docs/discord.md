# Discord

There are two ways this server talks to Discord, and they answer different questions. They are
independent: either, both or neither can be on.

| | Native chat bridge | Status notifier |
|---|---|---|
| What it does | Mirrors in-game global chat into a Discord channel, and back | Posts when the server comes up, goes down, and when players join or leave |
| Where it lives | Inside the game server (`servertest.ini`) | `tools/discord-notifier/notifier.py`, a systemd daemon on the VM |
| What it needs | A Discord **bot** with privileged intents | A **webhook** URL |
| Configured by | `DISCORD_ENABLE`, `DISCORD_TOKEN`, `DISCORD_CHAT_CHANNEL` in `.env` | `DISCORD_WEBHOOK_URL` in `.env` |
| Default | off | on, quiet without a webhook URL |

The notifier is the one worth setting up first: it costs one URL, it answers "is the server up
and who is playing", and it cannot post anything a player typed. The chat bridge needs a bot
application and privileged intents, and it relays whatever is said in game.

## The native chat bridge

Build 42 ships a Discord client inside the server. `scripts/render-config.sh` writes these keys
of `servertest.ini` from `.env`:

| `.env` | `servertest.ini` | Meaning |
|---|---|---|
| `DISCORD_ENABLE` | `DiscordEnable` | `true` turns the bridge on |
| `DISCORD_TOKEN` | `DiscordToken` | The bot token, not a webhook URL |
| `DISCORD_CHAT_CHANNEL` | `DiscordChatChannel` | Channel **name**, not its numeric id |
| `DISCORD_LOG_CHANNEL` | `DiscordLogChannel` | Optional, server log lines |
| `DISCORD_COMMAND_CHANNEL` | `DiscordCommandChannel` | Optional, admin commands from Discord |

To use it you need a bot, not a webhook: create an application at
<https://discord.com/developers/applications>, add a bot to it, invite it to the server, and copy
its token. In **Bot → Privileged Gateway Intents**, enable **Message Content Intent** — without
it the bot receives empty message bodies and nothing typed in Discord reaches the game. **Server
Members Intent** is needed as well if you want the bridge to resolve display names. Both are
toggles on that page; below 100 servers they need no approval.

The token is a credential with the same weight as the RCON password: it lives only in the VM's
`.env`, and changing any of these keys means a `make remote-restart`, because they are read from
the ini at startup.

`DISCORD_ENABLE=false` in `.env.example` is deliberate. The bridge is left off until somebody
decides that everything said in global chat should be readable in Discord.

## The status notifier

A systemd daemon (`zomboid-notifier.service`) that watches three sources and posts embeds to a
webhook. It runs as `pz`, is restarted by systemd if it dies, and keeps its state in
`/var/tmp/zomboid-notifier/` so a restart does not repost anything.

| Source | Used for |
|---|---|
| `docker compose logs -f zomboid` | `*** SERVER STARTED ****` and the `version=42.x` line |
| `docker events` | The container stopped (`die`, `stop`, `kill`) |
| `data/zomboid/Logs/*_user.txt` | Players joining and leaving |
| `scripts/rcon.sh players` | How many are connected, and a reconciliation every 60 s |

### Creating the webhook, in four steps

1. In Discord, open the settings of the channel you want the messages in:
   **Edit Channel → Integrations → Webhooks → New Webhook**.
2. Name it (`zomboid` is a fine name), confirm the channel, and press **Copy Webhook URL**.
3. On the VM, put it in `/opt/zomboid-server/.env`:

   ```bash
   ssh pz@<address>
   sudoedit /opt/zomboid-server/.env      # DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
   ```

4. Install and restart the notifier, then check it:

   ```bash
   make notifier-install
   make notifier-status
   ```

   With the game server already up, the first message arrives within a minute.

The same URL is used by the watchdog (see [`self-healing.md`](self-healing.md)). One webhook is
enough for both.

**That URL is a credential.** Anyone holding it can post in the channel as the webhook. It lives
only in the VM's `.env` (mode 0600, never committed, never synchronised by `make sync`), and
neither the notifier nor the watchdog ever prints it.

### What it posts

| Title | Colour | When |
|---|---|---|
| **&lt;PUBLIC_NAME&gt; · En línea** | green | `*** SERVER STARTED ****` appears in the container log, and once when the daemon starts against a server that is already up |
| **&lt;PUBLIC_NAME&gt; · Fuera de línea** | grey | Docker reports the container died or was stopped |
| **&lt;name&gt; entró · N en línea** | blue | A player finished connecting |
| **&lt;name&gt; salió · N en línea** | blue | A player's connection ended |
| **Movimiento de jugadores · N en línea** | blue | Two or more of the above within the same 30-second window |

The server name is always in the title of the status messages, so a channel that carries more
than one server stays readable; on player messages it is the footer.

The status message is a fixed set of fields — **Estado**, **IP**, **Puerto**, **Contraseña**,
**Versión** — and nothing else. It is what somebody needs in order to join, and every state
message says the same five things, so there is no reading between the lines about whether it is
retroactive: the state is whatever the last message says it is. The mod count used to be there
and was removed; nobody acts on the number, and an embed cannot fold away a list of forty.

Messages are in Spanish, matching the rest of the player-facing output. Player names are escaped
before they go into an embed and `allowed_mentions` is empty, so a player called `@everyone`
cannot ping the channel.

### Including the password

`NOTIFIER_INCLUDE_PASSWORD=1` (the default) puts `SERVER_PASSWORD` in the **Contraseña** field of
the "En línea" message, so nobody has to ask for it.

**This is only reasonable in a private channel.** The message is as durable as the channel: it
stays in the history, it is visible to anyone invited later, it is carried by search, and it
appears in link previews and mobile notifications. Anyone who can read the channel can join the
server for as long as that password stands. If the channel is public, shared with a wider group,
or you would rather not think about who scrolled back, set `NOTIFIER_INCLUDE_PASSWORD=0`; the
message keeps the state, address, port and version.

Changing the password means changing `SERVER_PASSWORD` in the VM's `.env` and
`make remote-restart`; old messages keep showing the old one.

### Configuration

Everything is read from the environment, which on the VM is the `.env` loaded by the unit.

| Variable | Default | Meaning |
|---|---|---|
| `DISCORD_WEBHOOK_URL` | — | Empty means the daemon runs and only writes to the journal |
| `PUBLIC_NAME` | `Project Zomboid` | Title of the status messages, footer of the player ones |
| `PUBLIC_IP` | — | Empty means it is resolved once and cached: OCI instance metadata, then `ifconfig.me` |
| `GAME_PORT` | `16261` | The **Puerto** field |
| `SERVER_PASSWORD` | — | Shown when `NOTIFIER_INCLUDE_PASSWORD` is on |
| `NOTIFIER_INCLUDE_PASSWORD` | `1` | `0` leaves the password out |
| `NOTIFIER_GROUP_SECONDS` | `30` | Grouping window for player events |
| `NOTIFIER_POST_INTERVAL` | `2` | Minimum seconds between two POSTs |
| `NOTIFIER_RCON_INTERVAL` | `60` | How often the player list is reconciled against RCON |
| `NOTIFIER_DRY_RUN` | `0` | `1` logs the messages instead of posting them |

The rate limit is self-imposed: at most one POST every two seconds, one message at a time. A
`429` is honoured by reading `retry_after` from the response body (falling back to the
`Retry-After` header) and retrying the same message.

This VM's public IP is a reserved `oci_core_public_ip` attached to a VNIC created with
`assign_public_ip = false`, which means it does **not** appear in the instance metadata at
`/opc/v2/vnics/`. The metadata lookup is tried first because it is the correct answer on a VM
with an ephemeral address; here it falls through to `ifconfig.me`. Setting `PUBLIC_IP` in `.env`
skips both.

### How joins and leaves are detected

The game writes one `Logs/<timestamp>_user.txt` per server start and archives the previous one
into `Logs/logs_YYYY-MM-DD/`, so the notifier re-picks the newest file on every poll rather than
holding a descriptor. Three line shapes matter (real lines, with the Steam ID redacted):

```
[04-09-26 03:27:35.424] 76561198000000000 "Fulano" fully connected (10624,9801,0).
[04-09-26 03:23:41.740] Connection disconnect index=0 guid=1139411779812053871 id=76561198000000000.
[04-09-26 03:15:59.025] 76561198000000000 "Fulano" disconnected player (7919,11484,0).
```

A join is `fully connected`. A leave is `Connection disconnect … id=<steam id>`, which is the
only line present in all three cases: quitting to the menu, timing out, and being dropped when
the server shuts down. The name is resolved from the Steam ID, which the file gives earlier in
the `attempting to join` line.

`disconnected player` looks like the obvious leave line and is not usable as one: the game also
writes it when a player dies and respawns, followed by a second `fully connected` about a tenth
of a second later. That is why a `fully connected` for somebody already counted as present is
ignored rather than announced, and why leaves are taken from `Connection disconnect`.

A player who quits while still in the loading queue produces a `Connection disconnect` without
ever having produced a `fully connected`; those are ignored, because they were never in.

The count in each message comes from `scripts/rcon.sh players` (`Players connected (N)`), falling
back to the notifier's own tally if RCON does not answer. Every 60 seconds that same command is
used to reconcile the list: if RCON and the log file disagree twice in a row, RCON wins and the
difference is announced. One disagreement is not enough — a player can be between `fully
connected` and appearing in `players`.

When the container stops, the burst of `Connection disconnect` lines it produces is discarded:
those players did not leave, the server did.

### Operating it

```bash
make notifier-install    # sync, install the unit, enable and restart it
make notifier-status     # systemctl status plus the last 20 journal lines
make notifier-status N=100
```

`make notifier-install` runs `make sync` first, so it also updates the script itself. On a new VM
cloud-init installs and enables the unit; there is nothing to do beyond putting the webhook URL
in `.env`.

State lives in `/var/tmp/zomboid-notifier/estado.json`:

| Key | Contents |
|---|---|
| `user_log` | Path, inode and byte offset of the user file being followed |
| `ultimo_arranque` | The container's `StartedAt` for the boot already announced |

Deleting that file makes the next start announce the current state again. It never re-reads the
history of a user file it has already consumed.

### Testing without a Discord server

The notifier resolves the repository from `NOTIFIER_REPO`, its state from `NOTIFIER_STATE`, the
game logs from `NOTIFIER_LOGS_DIR` and RCON from `NOTIFIER_RCON`, and it looks `docker` up
through `PATH`. That is enough to run the whole daemon against stubs on a workstation: a `docker`
stub that tails control files for `compose logs -f` and `events`, a synthetic `user.txt` that
grows, an `rcon.sh` stub, and a local HTTP server standing in for the webhook that records every
payload — and, on demand, answers one `429` with a `retry_after` so the retry path is exercised.
`NOTIFIER_DRY_RUN=1` is the cheaper version: it logs what it would post and posts nothing.
