# Self-healing

The server is meant to survive the night without anybody watching it. A systemd timer runs
`scripts/watchdog.sh` every two minutes; when something is wrong it applies a small, fixed
playbook and posts what happened to a Discord channel. If the playbook is not enough it escalates
— to a human by default, and optionally to Claude Code running headless on the machine.

There are two layers, and they are independent:

| Layer | What it is | Default |
|---|---|---|
| 1 | `scripts/watchdog.sh`: deterministic checks and a fixed playbook | always on |
| 2 | `scripts/autorepair.sh`: hands the diagnosis to Claude Code | off (`CLAUDE_AUTOREPAIR=0`) |

Layer 1 is the one that matters. It handles the failures that actually happen — a hung RCON, a
crash loop, a full disk — and it does so without any judgement, any network call to a model, and
any risk of creativity. Layer 2 exists for the case that layer 1 cannot classify, and is off
until somebody reads [Layer 2](#layer-2-claude-code) and decides otherwise.

## Components

| File | Role |
|---|---|
| `scripts/watchdog.sh` | The checks, the playbooks and the escalation. One pass per invocation |
| `scripts/lib/notificar.sh` | `log()` and `notificar()`: the log line and the Discord embed |
| `tools/watchdog/patrones-fatales.txt` | Regular expressions that mean "this server is not coming back" |
| `tools/watchdog/patrones-ignorar.txt` | Known mod noise that matches the above but is harmless |
| `scripts/autorepair.sh` | The optional escalation to Claude Code |
| `tools/autorepair/prompt.md` | The task, with `{{BUNDLE_DIR}}`, `{{MOTIVO}}` and `{{INTENTOS}}` |
| `tools/autorepair/CLAUDE.md` | The hard rules, appended to the system prompt |
| `infra/systemd/zomboid-watchdog.service` | One pass. `Type=oneshot`, runs as `pz` |
| `infra/systemd/zomboid-watchdog.timer` | Every two minutes, five minutes after boot |

State lives in `/var/tmp/zomboid-watchdog/`. It has to survive between runs but not between
reinstalls, and `/tmp` is cleared on boot:

| File | Contents |
|---|---|
| `rcon-fallos` | Consecutive failed RCON checks |
| `restartcount` | `epoch<TAB>count`: the Docker `RestartCount` baseline for crash-loop detection |
| `reinicios` | One `epoch<TAB>reason` line per automatic restart, for the hourly quota |
| `escalaciones` | One line per escalation, for the daily count |
| `ultima-escalacion` | The last one, so the same alert is not posted every two minutes |
| `ultimo-problema` | What was wrong last time, so "recovered" can be announced |
| `autorepair-invocaciones` | One line per Claude invocation, for the hourly and daily quotas |
| `lock` | `flock`. A run that takes longer than the interval makes the next one skip |

## What it detects

Checks run in this order and stop at the first problem, except the disk check, which always runs:

| # | Check | Fails when |
|---|---|---|
| 1 | `zomboid.service` | `systemctl is-active` is neither `active` nor `activating`. Skipped when the unit is not installed |
| 2 | The container | `docker inspect` says `State.Running` is not `true` |
| 3 | Crash loop | `RestartCount` grew by 3 or more within 10 minutes |
| 4 | RCON | `scripts/rcon.sh players` failed 3 checks in a row, i.e. for about 6 minutes |
| 5 | Fatal log patterns | `docker compose logs --since 3m` matches `patrones-fatales.txt` and not `patrones-ignorar.txt` |
| 6 | Kernel OOM | `journalctl -k --since -10m` contains `Out of memory: Killed process … java` |
| 7 | Disk | Less than 2 GB free on the partition holding `data/` |

The RCON check has a five-minute grace period after `State.StartedAt`: a server that is loading
200 mods does not answer RCON, and restarting it for that reason would produce an infinite loop.

Check 5 is the one that needs care. A Project Zomboid log is full of `ERROR` and `SEVERE` lines
that mean nothing — a mod referencing a texture that was renamed, a map cell with bad room
metadata. Every one of those that reaches the fatal list costs everybody a two-minute restart, so
the two files work as a pair: `patrones-fatales.txt` is deliberately broad (it includes a bare
`SEVERE`), and `patrones-ignorar.txt` subtracts the noise that is known to be harmless. When a
false positive shows up, the fix is usually a new line in the second file, not a narrower first
one.

## What it does

| Problem | Playbook |
|---|---|
| RCON down, container alive | `WARN_SECONDS=0 scripts/restart.sh` |
| Crash loop, fatal pattern, kernel OOM, container down | `scripts/stop.sh` (falling back to `docker compose down`), build a diagnostic bundle, `make up`, wait up to 5 minutes for `SERVER STARTED` |
| Disk almost full | Delete local `backups/*.tar.*` older than a day and `data/zomboid/Logs/*` older than a week, `docker system prune -f`, then check again |

Every playbook is capped at `WATCHDOG_MAX_RESTARTS_HOUR` automatic restarts per hour (2 by
default). Beyond that it stops restarting and escalates: a server that needs three restarts an
hour has a problem that a fourth restart will not fix.

When a check passes again after a failure, one `Todo en orden de nuevo` notification is posted,
so the channel shows the end of an incident and not only its beginning.

## What it never does

Not as a matter of configuration — these paths do not exist in the code:

- **No wipe and no restore.** Nothing under `data/zomboid/Saves` or `data/zomboid/db` is ever
  deleted, moved or overwritten.
- **No `docker stop` and no `docker kill`** against the game container. Shutdown is always
  `scripts/stop.sh`, which does RCON `save` + `quit` and waits for the world to be written.
  `docker compose down` is used only after `stop.sh` itself has failed.
- **It does not touch `config/`.** Layer 1 restarts and cleans up; it never edits configuration,
  mods, sandbox variables or passwords.
- **It does not power the VM off**, and it does not run backups on its own.

## The diagnostic bundle

Before restarting after a critical failure, the watchdog writes everything a human — or Claude —
needs into `data/diagnostico/<timestamp>/`:

| File | Contents |
|---|---|
| `motivo.txt` | What was detected, when, on which host |
| `log-contenedor.txt` | The last 800 lines of the container log |
| `docker-inspect.json` | Full container state, including `RestartCount` |
| `df.txt`, `free.txt` | Disk and memory at the moment of the failure |
| `journal-zomboid.txt` | The last 100 journal lines of the unit |
| `journal-oom.txt` | Kernel messages matching `oom` or `killed` from the last 30 minutes |
| `mods.txt` | A copy of `config/mods.txt` |
| `mods-errores.txt` | Log lines matching `required mod`, `not found` or `ERROR` |
| `servertest.ini` | The effective configuration, with `Password`, `RCONPassword` and `DiscordToken` replaced by `REDACTADO` |

Bundles are not rotated automatically. They are small (a few hundred kilobytes), but if one ever
matters it is the one nobody deleted.

## Installing it

On a new VM, cloud-init installs and enables the timer; there is nothing to do. On a VM that is
already running:

```bash
make watchdog-install     # rsyncs the repo, installs both units, enables the timer
make watchdog-status      # next run, last result, and the tail of the log
```

The log is `/var/log/zomboid/watchdog.log`, rotated weekly by the same logrotate rule as the
backup log.

The unit declares `SuccessExitStatus=20` because exit code 20 means "escalated": that is a
result of the check, not a failure of the watchdog, and `systemctl status` should not claim
otherwise.

## Discord notifications

Without `DISCORD_WEBHOOK_URL` the watchdog only writes to its log — everything still works, it is
just quiet. To get the notifications, in four steps:

1. In Discord, open the server settings of the channel you want the alerts in:
   **Edit Channel → Integrations → Webhooks → New Webhook**.
2. Name it (`zomboid-watchdog` is a fine name), pick the channel, and press **Copy Webhook URL**.
3. On the VM, put it in `/opt/zomboid-server/.env`:

   ```bash
   ssh pz@<address>
   sudoedit /opt/zomboid-server/.env      # DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
   ```

4. Check it: `cd /opt/zomboid-server && ./scripts/watchdog.sh`. A healthy server posts nothing, so
   to see a message, temporarily lower the threshold:
   `WATCHDOG_MIN_DISK_MB=99999999 ./scripts/watchdog.sh`.

**That URL is a credential.** Anyone holding it can post in the channel as the webhook. It lives
only in the VM's `.env` (mode 0600, never committed, never synchronised by `make sync`), and the
scripts never print it.

Alerts are colour-coded: green for recovery, yellow for an action taken, red for a failure that
needs somebody. The same escalation is not reposted for an hour, so a server that is down
overnight produces one message, not thirty.

## Layer 2: Claude Code

Off by default. When it is on and the watchdog's own playbook has failed, `scripts/autorepair.sh`
starts Claude Code in headless mode on the VM, pointed at the bundle, and posts its final report
to the same channel.

### Enabling it

```bash
# in /opt/zomboid-server/.env, on the VM
CLAUDE_AUTOREPAIR=1
ANTHROPIC_API_KEY=sk-ant-...        # one of the two, not both
CLAUDE_CODE_OAUTH_TOKEN=...
```

Claude Code has to be installed on the VM and reachable as `claude` in `pz`'s `PATH`. Two ways to
authenticate an unattended run:

- `ANTHROPIC_API_KEY`, from an API account. It bills per token.
- `CLAUDE_CODE_OAUTH_TOKEN`, generated by running `claude setup-token` once (interactively, on any
  machine) and pasting the result. It uses a Claude subscription and lasts about a year, after
  which the command has to be run again.

Without either, or without the CLI, the script posts one notification saying so and exits
non-zero. It does not retry.

### The invocation

```bash
timeout 40m claude -p "<tools/autorepair/prompt.md, rendered>" \
  --output-format json \
  --max-turns 40 \
  --permission-mode acceptEdits \
  --allowedTools "Bash(make up:*),Bash(make restart:*),…,Read,Edit,Grep,Glob" \
  --append-system-prompt "$(cat tools/autorepair/CLAUDE.md)"
```

Flags, JSON envelope, authentication variables and exit codes were checked against the official
documentation on 2026-09-04:
[headless mode](https://code.claude.com/docs/en/headless),
[CLI reference](https://code.claude.com/docs/en/cli-reference),
[authentication](https://code.claude.com/docs/en/authentication).
(`docs.claude.com/en/docs/claude-code/*` now redirects to those URLs.)

The result is parsed from the JSON envelope: `result` is the report that goes to Discord,
`is_error` decides whether the run counts as a failure, and `total_cost_usd` and `num_turns` are
appended to the message. The whole envelope is kept in the bundle as `autorepair.json`, and
anything the CLI wrote to stderr in `autorepair.err`.

The working directory is `/opt/zomboid-server`, so the repository's own `CLAUDE.md` is picked up
the way it would be interactively; `tools/autorepair/CLAUDE.md` is appended on top of it with the
rules that only apply to an unattended run.

### Guard rails

- **One invocation per hour, three per day** (`AUTOREPAIR_MAX_PER_DAY`). Past the quota the
  script posts "the server is still down and needs somebody" and stops.
- **A 40-minute wall clock and 40 turns.** A timeout is reported as a failure, not as success.
- **A deliberately narrow tool list.** Everything not on it is denied automatically: in `-p` mode
  there is nobody to ask, so an unlisted tool call simply fails and Claude has to work around it.
  The list allows exactly the restart scripts, read-only inspection (`cat`, `grep`, `tail`,
  `head`, `ls`, `df`, `free`, `docker compose logs|ps`), and `Read`/`Edit`/`Grep`/`Glob`.
  `make` is allowed one target at a time — `up`, `down`, `restart`, `render`, `status`, `logs` —
  rather than as `Bash(make:*)`, precisely so that `make wipe` and `make restore` are not
  reachable through it.
- **The hard rules in `tools/autorepair/CLAUDE.md`**: no wipe, no restore, nothing deleted under
  `Saves` or `db`, no password or `SandboxVars` changes, no `docker stop`/`kill`, no software
  installs, no git operations, at most three repair attempts.
- **No `git commit` and no `git push`.** Whatever Claude changes stays in the VM's working tree
  on purpose, so that a person reviews it.

### Reviewing what it changed

```bash
make remote-diff
```

That runs `git status --short` and `git diff` over `/opt/zomboid-server` by ssh. Anything there
was written by the auto-repair (or by somebody editing on the VM) and has to be brought back into
the repository by hand — the VM is disposable and a `tofu apply` that recreates it clones the
repository again, losing everything that was never committed.

The most likely change is a commented-out line in `config/mods.txt`:

```
# DESACTIVADO por autorepair 2026-09-04: rompe el arranque, ver data/diagnostico/20260904-0312
3171167894  damnlib
```

That is a decision a person still has to confirm: keep the mod disabled, wait for the author to
fix it, or find a replacement.

### Cost

Claude Code reports the cost of each run in `total_cost_usd`, and the watchdog puts it in the
Discord message, so the real number is always visible rather than estimated. As an order of
magnitude, a debugging session of a few dozen turns over a large log costs roughly USD 0.40 to
1.50 depending on how much of the context is cached. With the three-per-day cap, the worst case
is a few dollars on a very bad day — but the cap exists for a better reason than money: a
problem that survives three attempts is not going to yield to a fourth.

### The risk, stated plainly

Giving an agent shell access to the machine that holds the world is a real risk, and the
mitigations above are mitigations, not proofs:

- **The tool allowlist is enforced by Claude Code, not by the operating system.** It is a strong
  guard against a wrong decision; it is not a sandbox. A command like `Bash(cat:*)` is matched
  against a pattern, and pattern matching over shell syntax is a hard problem.
- **The rules in `CLAUDE.md` are instructions, not permissions.** They are followed because the
  model follows instructions, which is very reliable and not certain.
- **The blast radius is the VM.** The `.env` on that machine holds the game passwords and, if you
  set it, an API key. There are no cloud credentials on disk — backups go out through the
  instance principal — so the bucket cannot be reached from a shell there.
- **The world has copies.** Daily backups to object storage with 30-day retention are the actual
  safety net, and the reason this is an acceptable trade at all. Do not enable layer 2 on a
  server whose backups you have never restored from.

If any of that reads as too much for a game server for eight friends, leave `CLAUDE_AUTOREPAIR=0`.
Layer 1 handles the failures that actually happen, and a red message in Discord at 3 a.m. that
nobody reads until morning is a perfectly good outcome for a world that is backed up.

## Tuning

Everything below can be set in the VM's `.env` or in the environment:

| Variable | Default | Meaning |
|---|---|---|
| `WATCHDOG_MAX_RESTARTS_HOUR` | `2` | Automatic restarts per hour before escalating |
| `WATCHDOG_GRACE_SECONDS` | `300` | RCON grace period after the container starts |
| `WATCHDOG_RCON_FAILS` | `3` | Consecutive failures before RCON counts as down |
| `WATCHDOG_MIN_DISK_MB` | `2048` | Free space below which the disk playbook runs |
| `WATCHDOG_CRASH_DELTA` | `3` | `RestartCount` increase that counts as a crash loop |
| `WATCHDOG_BOOT_WAIT` | `300` | Seconds to wait for `SERVER STARTED` after `make up` |
| `WATCHDOG_RENOTIFY_SECONDS` | `3600` | How long before the same escalation is posted again |
| `AUTOREPAIR_MAX_PER_DAY` | `3` | Claude invocations per day (there is also one per hour) |
| `AUTOREPAIR_MAX_TURNS` | `40` | `--max-turns` |
| `AUTOREPAIR_TIMEOUT` | `40m` | The `timeout` around the CLI |

`DRY_RUN=1 ./scripts/watchdog.sh` runs every check and prints what it would do, without doing it.

## Testing locally

The watchdog resolves the repository from `WATCHDOG_REPO_DIR`, its state from
`WATCHDOG_STATE_DIR` and its log from `WATCHDOG_LOG`, and it looks up `docker`, `systemctl`,
`journalctl`, `df`, `free`, `curl`, `make` and `claude` through `PATH`. That is enough to run the
whole thing against stubs on a workstation, with no container and no VM:

```bash
env PATH="/path/to/stubs:$PATH" \
    WATCHDOG_REPO_DIR=/tmp/repo-falso \
    WATCHDOG_STATE_DIR=/tmp/estado \
    WATCHDOG_LOG=/tmp/watchdog.log \
    ./scripts/watchdog.sh
```

The stubs read what to answer from control files (is the container running, what does the log
say, how much disk is free) and record every call, so each scenario — healthy, RCON down, crash
loop, fatal pattern, mod noise, full disk, each escalation path — is a fixture plus a handful of
assertions. The `curl` stub keeps the webhook payload, which is how the JSON is checked without a
Discord server.
