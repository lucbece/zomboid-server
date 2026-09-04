# Moderator panel

`tools/panel/` is an optional web page that lets two to four trusted people restart the game
server without an SSH account. It shows whether the server is up, who is connected, when the
last restart happened and who asked for it, and offers a single button: **Reiniciar servidor**.

That button runs `scripts/restart.sh` — warn over RCON, `save`, `quit`, re-render the
configuration, start the container again. Nothing else is exposed: no wipe, no restore, no
world upload, no way to power the VM off or on.

It is off by default and requires opening a port, so read
[Security model](#security-model) before running it.

The page is in Spanish, like the survey; see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## Components

| File | Role |
|---|---|
| `tools/panel/server.py` | A `http.server` from the standard library. Serves the page, validates tokens, launches the restart. No pip, no virtualenv |
| `tools/panel/plantilla.html` | The page shell: same CSS tokens as the survey, mobile-first |
| `tools/panel/tokens.py` | Creates, lists and revokes moderator tokens. Runs on the VM |
| `scripts/panel.sh` | The administrator's side: install, start, stop, tokens, action log |
| `infra/systemd/zomboid-panel.service` | The unit. Not installed by cloud-init; `make panel-up` installs it |

There is no database and no session. State lives in three files under
`/opt/zomboid-server/data/panel`:

| File | Contents |
|---|---|
| `moderadores.json` | `{ "<token>": {"nombre", "creado", "activo"} }`, mode 0600 |
| `acciones.jsonl` | One JSON line per action: `ts`, `nombre`, `ip`, `accion`, `resultado` |
| `estado.json` | The last restart (timestamp and who) and the per-moderator cooldown clock |

## Routes

| Route | Behaviour |
|---|---|
| `GET /m/<token>` | The status page and the button. Reads only: `docker compose ps` and RCON `players` |
| `POST /m/<token>/restart` | Validates the token and the cooldown, then launches the restart detached from the request |
| `GET /salud` | JSON health: server state, number of connected players, active moderators, whether a restart is running. Exposes no token |
| anything else | A plain `404`, including `GET /m/<token>/restart` |

An invalid, unknown or revoked token returns exactly the same `404` as a route that does not
exist, so the response does not confirm that a panel is running on that port.

**`GET` never executes anything.** Link previews in WhatsApp, Discord, Telegram and Slack fetch
the URL as soon as it is pasted, sometimes several times. The restart therefore only happens on
`POST`, which no preview bot performs.

`POST` returns immediately with a "restart in progress" page: the child process is started with
`start_new_session=True`, its output redirected to `/var/log/zomboid/panel-restart.log`, and it
survives both the request and a restart of the panel itself. The unit sets `KillMode=process`
for the same reason — with the default `control-group`, a `systemctl restart zomboid-panel`
would kill a restart in flight and could leave the world half written.

## Running it

The panel runs on the same machine as the game server. On a cloud VM the port has to be opened
first; it is closed by default.

```hcl
# infra/terraform/envs/prod/terraform.tfvars
panel_port = 8081
```

```bash
make infra-apply     # adds the ingress rule for TCP 8081 from 0.0.0.0/0
make panel-up        # syncs the tool, installs the unit, opens ufw, starts the panel
```

Then one token per moderator:

```bash
make panel-token NAME=Fulano   # prints http://<address>:8081/m/<token>
make panel-tokens              # who has a token, when it was issued, active or revoked
make panel-log                 # the last actions: who restarted, when, from which address
make panel-estado              # unit status, /salud, moderator list
```

`make panel-token` prints the full URL once. That URL is the credential; `panel-tokens` shows
only a six-character prefix, so a lost link cannot be recovered — revoke it and issue a new one.

The default port can be changed with `PANEL_PUERTO`, and both cooldowns with `PANEL_COOLDOWN`
(global, 600 s) and `PANEL_COOLDOWN_MOD` (per moderator, 1800 s) in the unit.

## Cooldowns

A restart interrupts everyone's session for about two minutes, so the button is rate-limited on
three levels:

- While `restart.sh` is running, the button is disabled for everybody.
- After a restart, nobody can trigger another one for `PANEL_COOLDOWN` seconds (10 minutes).
- The same moderator has to wait `PANEL_COOLDOWN_MOD` seconds (30 minutes).

The cooldown is recorded before the process is launched, so two moderators pressing the button
at the same moment produce one restart, not two. It is persisted in `estado.json`, so it also
survives a restart of the panel service.

Before launching, the panel sends one RCON `servermsg` naming who asked for the restart. It does
not announce a countdown: `scripts/stop.sh` already warns players 60 seconds ahead, and skips
the warning when nobody is connected.

## Revoking

```bash
make panel-revoke NAME=Fulano
```

The entry stays in `moderadores.json` with `"activo": false` — a revoked token is never reissued
by accident, and the audit trail in `acciones.jsonl` keeps meaning something. `server.py` reloads
the file when its mtime changes, so a revocation takes effect on the next request without
restarting the service.

## Closing it

```bash
make panel-down        # stops the unit and removes the ufw rule; tokens stay on the VM
```

```hcl
# infra/terraform/envs/prod/terraform.tfvars
panel_port = 0
```

```bash
make infra-apply
```

`make panel-down` stops the unit and removes the host firewall rule, but the security group rule
stays until `panel_port` is set back to `0` and applied.

## Security model

State it plainly to the moderators: **the URL is the credential.**

- **There is no TLS.** Without a domain name there is no Let's Encrypt certificate, so the panel
  is plain HTTP. The token travels in the URL in clear text and is visible to anyone able to
  observe the connection — an open Wi-Fi network, a transparent proxy, the browser history on a
  shared phone. Anyone who sees the link can restart the game server.
- **That is the whole blast radius.** A leaked token restarts the server, at most once every ten
  minutes, and does nothing else: it cannot read the world, change the configuration, wipe or
  restore a save, stop the VM, or reach RCON. The worst case is a stranger annoying the players
  with a two-minute interruption, on a world that is saved cleanly every time.
- **Share the link by direct message**, one per person, and never in an open channel, a group
  chat or a screenshot. A link posted in a Discord channel is a link handed to everyone who ever
  joins that channel, plus whatever bots read the history.
- **One token per moderator, always.** The action log is only worth reading if names are not
  shared, and a token can only be revoked individually.
- **Rotate on suspicion, not on proof.** Revoking costs one command and issuing a new link costs
  another; there is no reason to wait for evidence.
- The panel is reachable from anywhere while the port is open, and rate-limited to 30 requests
  per minute per source address, beyond which it answers 429. It logs to stdout — that is, to
  the journal — with the token redacted from the request line.
- **The panel cannot power the VM on.** It runs *on* the VM. If the instance is stopped
  (`scripts/cloud-stop.sh`, or the idle shutdown discussed in
  [`architecture.md`](architecture.md)), the panel is stopped with it and the link is dead until
  the administrator starts the machine again. It is a tool for restarting a stuck or laggy game
  server, not a remote power switch.
- The panel and the survey are independent: different ports, different units, different
  Terraform variables. Opening one does not open the other.

## Testing locally

The panel can run on the workstation against a fake restart script. `PANEL_RESTART_CMD` and
`PANEL_RCON_CMD` are relative to `--repo`:

```bash
mkdir -p /tmp/panel/datos
python3 tools/panel/tokens.py --datos /tmp/panel/datos add "Prueba"

PANEL_RESTART_CMD='scripts/restart-fake.sh' PANEL_RCON_CMD='scripts/rcon-fake.sh' \
python3 tools/panel/server.py --puerto 18081 --host 127.0.0.1 \
  --datos /tmp/panel/datos --repo /tmp/panel/repo --cooldown 60

curl -s -o /dev/null -w '%{http_code}\n' -A 'WhatsApp/2.23' http://127.0.0.1:18081/m/<token>
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:18081/m/<token>/restart
```

The first command must not run anything; the second must run the fake script once and answer
`409` on the next attempt.
