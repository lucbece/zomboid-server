# Windows support: native dedicated server driven by PowerShell

Status: specification, 2026-09-04. Implementation pending. When the work lands, the user-facing
documentation lives in `docs/windows.md` and this file moves to `docs/history/`.

## Problem

Most people who would use this repository play on Windows and want a dedicated server on their
own PC, not on a cloud VM. Today the repository assumes Linux: bash, GNU make, Docker Compose,
`envsubst`, `rsync`. On Windows the only way to run it is WSL2 plus Docker Desktop, which asks a
non-technical user for virtualization in the BIOS, a reboot, a 10 GB image, and then hits WSL2
networking limits (NAT mode cannot forward UDP; mirrored mode needs Windows 11 and Hyper-V
firewall rules). That is not a path the general public will follow.

## Decision

Windows gets a **native engine**: the official Windows dedicated server installed by SteamCMD
and driven by PowerShell scripts, with **no Docker, no WSL, no VM**. The engine shares the
repository's contract with the Linux/Docker engine:

- The same `config/` directory is the source of truth: `servertest.ini.tpl`, the spawn Lua
  files, and the per-world `servertest_SandboxVars.lua` and `mods.txt` created from their
  `.example` twins.
- The same `.env` file and keys.
- The same data layout: the server runs with `-cachedir=<repo>\data\zomboid`, so
  `data\zomboid\Server\`, `Saves\`, `db\` and `Logs\` are where they are on Linux. A world can be
  moved between a Windows PC and a Linux host by copying `data\zomboid`.
- The same operating rules: the server is stopped with RCON `save` + `quit`, never by killing
  the process; configuration is rendered from `config/`, never edited under `data/`.

Rejected alternatives:

- **Docker Desktop + WSL2** (documented as an option for people who already use Docker, not
  supported as the main path): heavy install, virtualization overhead on the same PC that runs
  the game, UDP port forwarding problems in WSL2 NAT mode.
- **A PowerShell port of the whole bash tool set**: the cloud path (OpenTofu, rsync, cloud-init)
  stays Linux/macOS only. It is a minority use case and already works from WSL2.
- **A single cross-platform binary (Go) replacing bash and PowerShell**: the right long-term
  shape if both engines keep growing, not the first step.

Verified facts the design relies on (pzwiki, 2026-09):

- `-cachedir={path}` "sets the absolute path for the game's cache directory" and applies to the
  server. `-servername`, `-adminusername`, `-adminpassword`, `-port` are server arguments.
- `StartServer64.bat` runs `.\jre64\bin\java.exe` with `-Xms/-Xmx`, `-XX:+UseZGC`,
  `-Djava.library.path=natives/;natives/win64/;.`, a classpath of the jars in `java\`, main class
  `zombie.network.GameServer`, and `-statistic 0`. The JRE ships with the server.
- SteamCMD installs the server anonymously: `+login anonymous +app_update 380870 validate`.
  Workshop content is downloaded by the server itself at startup, as on Linux.
- Ports: `16261-16262/udp` to players; RCON `27015/tcp` must stay closed to the outside.

## Layout

```
windows/
  setup.cmd          Double-click entry point. First configuration, install, start.
  zs.cmd             Operations: zs start|stop|restart|status|logs|backup|update|render|rcon
  zs.ps1             Dispatcher for zs.cmd (PowerShell 5.1 and 7 compatible)
  setup.ps1          Implementation of setup.cmd
  lib/
    Env.ps1          Read and write .env (same format and keys as the Linux .env)
    I18n.ps1         Message catalogs es/en (windows/lib/i18n/es.psd1, en.psd1), ZS_LANG
    Mods.ps1         config/mods.txt parser, same rules as scripts/render-config.sh
    Render.ps1       config/ + .env -> data/zomboid/Server/, same output as render-config.sh
    Rcon.ps1         Source RCON client over TCP (auth, exec, the PZ "late packet" workaround)
    SteamCmd.ps1     Download steamcmd.zip, install/update app 380870 into .\server\
    Server.ps1       Start (java.exe with -cachedir), stop (save+quit), status, pid file
    Firewall.ps1     Inbound UDP rule for the game ports, requested with elevation once
    Backup.ps1       RCON save, then zip Server/ Saves/ db/ into backups\, retention
  tests/             Pester tests runnable on Linux pwsh (no server needed)
docs/windows.md      User documentation (English; Spanish section in README.es.md)
```

Gitignored: `server/`, `steamcmd/`, `*.pid`, `data/`, `backups/`, `.env` (the last three already
are).

## Behaviour

### setup.cmd

1. Launches `powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1`. No
   execution-policy change is persisted on the machine.
2. Checks: 64-bit Windows 10 1809 or later, PowerShell 5.1 or later, at least 20 GB free on the
   drive, warns below 8 GB of RAM, warns if the repository path contains spaces or non-ASCII
   characters (Java and the game handle them badly).
3. Asks, in order, with the current value as default when re-run: language (`Idioma / Language
   [es/en]`), server name, server password (a generated `three-words-1234` suggestion, same
   validation as `setup.sh`), max players (default 8), RAM for the server (default: 8g, capped at
   half of the machine's RAM, minimum 4g), enable UPnP (default yes), open the Windows firewall
   for the game ports (default yes). `-NonInteractive` takes every answer from `ZS_*` environment
   variables, as `setup.sh --no-preguntar` does.
4. Writes `.env` with the same keys `setup.sh` writes (plus `UPNP=true|false`), generates the
   admin and RCON passwords, copies `config/mods.example.txt` and
   `config/servertest_SandboxVars.example.lua` into place when missing.
5. Downloads `https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip` into `steamcmd\`,
   then installs the server into `server\` (`+login anonymous +app_update 380870 validate`).
   Shows progress; this is several GB.
6. Adds the firewall rule through a single elevated PowerShell (UAC prompt), idempotent.
7. Renders the configuration, starts the server, waits for `SERVER STARTED` in the log (up to
   10 minutes; the first start also downloads Workshop mods), then prints what to send to the
   players: LAN address, public address (`https://api.ipify.org`), port, password, and whether
   UPnP mapped the ports (from the server log) or the router needs a manual forward of
   `16261-16262/udp`.

### zs.cmd

| Command | Behaviour |
|---|---|
| `zs start` | Render, start `java.exe` from `server\` as a background process with stdout and stderr to `data\logs\server.log`, write `data\server.pid`, wait for `SERVER STARTED` or fail with the last log lines. |
| `zs stop` | Same sequence as `scripts/stop.sh`: RCON `players`; if anyone is online, `servermsg` warning and wait `WARN_SECONDS` (default 60, 0 when nobody is connected); `save`; 5 s; `quit`; wait up to 120 s for the process to exit. Only after that timeout does it terminate the process, and it says so. |
| `zs restart` | stop, render, start. |
| `zs status` | Process alive (pid file plus `Get-Process`), RCON `players` output, listening ports, last log lines. |
| `zs logs` | `data\logs\server.log`, following. |
| `zs backup` | RCON `save`, zip `data\zomboid\{Server,Saves,db}` into `backups\<timestamp>.zip`, delete zips older than `BACKUP_KEEP_LOCAL_DAYS`. |
| `zs update` | Refuses while the server runs. SteamCMD `app_update 380870 validate`. |
| `zs render` | Render only, print `Mods=` and `WorkshopItems=`. |
| `zs rcon <command>` | One RCON command. |

The Java command line is built from the installed `StartServer64.bat`: the script reads the
line that invokes `java.exe`, keeps its classpath and JVM flags, replaces `-Xms`/`-Xmx` with
`MIN_MEMORY`/`MAX_MEMORY` from `.env`, and appends `-servername servertest`, `-adminusername`,
`-adminpassword`, `-cachedir=<absolute data\zomboid>` and `-port`. Parsing the shipped file
instead of hardcoding the classpath keeps the launcher valid across game updates. Working
directory: `server\`.

### Rendering parity

`Render.ps1` produces byte-identical output to `scripts/render-config.sh` for the same inputs:
same placeholder rule (`${VAR}` only; every variable defined; the same `MAY_BE_EMPTY` set), same
`mods.txt` grammar (comments, `;`-separated mod IDs, Workshop ID listed once, file order = load
order, `MOD_ID_PREFIX`), same vanilla fallback for a missing `servertest_SandboxVars.lua`, same
refusal to render an empty mod list over an ini that had mods unless `ALLOW_VANILLA=1`. CI runs
both implementations on Linux against the same fixtures and diffs the output.

The template gains one variable: `UPnP=${UPNP}`. `setup.sh`, `.env.example` and cloud-init get
`UPNP=false`; the Windows setup writes the user's answer.

### RCON

Source RCON protocol: little-endian int32 size, id, type (3 = auth, 2 = command), body,
two null bytes. Auth failure is id `-1`. Project Zomboid answers a command with a trailing
"late" packet; `scripts/rcon.sh` documents the workaround in use and `Rcon.ps1` applies the same
one. Timeouts: 5 s connect, 10 s read. The client only ever connects to `127.0.0.1`.

### Security

- RCON listens on all interfaces on the native server (Docker mapped it to localhost). The
  Windows firewall has no rule for `27015/tcp`, the setup never adds one, and the documentation
  says not to forward it on the router.
- `.env` and the rendered ini contain passwords; the scripts never print the admin or RCON
  password, only the server password in the final summary, as `deploy.sh` does.
- Nothing is downloaded from anywhere but Valve's SteamCMD URL and Steam itself.

### i18n

Same rule as the bash CLI: `ZS_LANG` from the environment, then `.env`, then the system UI
culture (`es*` → `es`), else `en`. Catalogs are PowerShell data files, one key set, checked by a
Pester test. Player-facing text (`servermsg`) stays out of the catalogs.

## Tests

- `windows/tests/*.Tests.ps1` (Pester 5, run with pwsh on `ubuntu-latest` in CI, no game needed):
  `.env` parsing and writing round-trip; `mods.txt` grammar cases (the same cases as the bash
  script, including a Mod ID with spaces, a `;` list, duplicate Workshop IDs, invalid IDs);
  render parity (diff against `scripts/render-config.sh` output on the same temp copy); RCON
  packet encoding and decoding; catalogs in sync.
- `PSScriptAnalyzer` on `windows/**` with the default rule set.
- `.github/workflows/windows-smoke.yml`, `workflow_dispatch` (manual, a few GB of download):
  `windows-latest`, `setup.ps1 -NonInteractive` with `ZS_*` answers, wait for `SERVER STARTED`,
  `zs status`, `zs rcon players`, `zs backup`, `zs stop`; assert the process exited cleanly, the
  zip exists, and `data\zomboid\Saves\Multiplayer\servertest` exists.

The maintainer has no Windows machine; the smoke workflow is the Windows validation. A first
real-user run is still required before announcing support.

## Out of scope for the first iteration

Mod auto-updater as a scheduled task, Discord notifier and watchdog on Windows, start at boot,
backups to cloud storage, a desktop shortcut, a graphical installer. A native Linux engine
(SteamCMD without Docker) would reuse this design and is a natural follow-up.
