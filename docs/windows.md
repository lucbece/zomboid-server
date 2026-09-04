# Windows

A native dedicated server for Windows, driven by PowerShell: no Docker, no WSL, no virtual
machine. It shares the repository's contract with the Linux/Docker engine documented in the rest
of this repository: the same `config/` directory, the same `.env` keys, and the same data layout
under `data/zomboid`. A world can be moved between a Windows PC and a Linux host by copying that
directory.

Use this path if you want to host the server on your own Windows PC. Use the Linux/Docker path
(see [`../README.md`](../README.md)) if you already run Docker, or if you are deploying to a
cloud VM (see [`deploy-oracle.md`](deploy-oracle.md)).

## Requirements

- 64-bit Windows 10 version 1809 or later, or Windows 11.
- PowerShell 5.1 or later (included in Windows 10 and 11; `setup.cmd` runs it for you).
- About 20 GB of free disk: the dedicated server download is several GB, plus the world and
  backups.
- 8 GB of RAM or more. `setup.ps1` warns below that and caps the suggested JVM heap at half of
  the machine's RAM.
- A repository path with no spaces and no non-ASCII characters. Java and the game handle both
  poorly.

## Quick start

```
git clone https://github.com/lucbece/zomboid-server.git
cd zomboid-server
```

Double-click `windows\setup.cmd`. It runs `windows\setup.ps1` with no persistent change to the
machine's execution policy, and it keeps the console window open at the end so you can read the
result even when launched by double-click.

`setup.cmd` will:

1. Check the machine (Windows version, PowerShell version, free disk, RAM, repository path) and
   warn about anything below the recommended minimums.
2. Ask, in order: language, server name, server password (it suggests a generated
   `word-word-word-1234` password), maximum number of players, RAM for the server, whether to
   enable UPnP, and whether to open the Windows firewall for the game ports. Re-running it shows
   the current value as the default for each question.
3. Write `.env` with the same keys `setup.sh` writes on Linux, and generate the admin and RCON
   passwords.
4. Copy `config/mods.example.txt` and `config/servertest_SandboxVars.example.lua` into place if
   `config/mods.txt` and `config/servertest_SandboxVars.lua` do not exist yet.
5. Download SteamCMD and install the dedicated server into `server\` (a few GB; only on the first
   run, or when the game updates).
6. Add a firewall rule for the game ports, if you said yes. This asks for administrator rights
   once (a single UAC prompt).
7. Render the configuration and start the server, waiting up to ten minutes for `SERVER STARTED`
   to appear in the log (the first start also downloads any Workshop mods).
8. Print a summary for your players: LAN address, public address, port, the server password, and
   whether UPnP mapped the ports automatically or you need to forward
   `16261-16262/udp` on your router.

For unattended runs (used by the CI smoke test), pass `-NonInteractive` and answer through
environment variables instead of prompts:

```powershell
$env:ZS_PUBLIC_NAME = 'My Zomboid Server'
$env:ZS_SERVER_PASSWORD = 'a-strong-password'
$env:ZS_MAX_PLAYERS = '8'
$env:ZS_MAX_MEMORY = '8g'
$env:ZS_UPNP = '1'
$env:ZS_FIREWALL = '1'
.\windows\setup.ps1 -NonInteractive
```

## Day-to-day operations: `zs`

`windows\zs.cmd` (a thin wrapper around `windows\zs.ps1`) is the equivalent of the `make` targets
on Linux:

| Command | Behaviour |
|---|---|
| `zs start` | Render the configuration and start `java.exe` in the background; wait for `SERVER STARTED` or fail with the last log lines. |
| `zs stop` | Warn connected players, save, and send `quit` over RCON; wait up to two minutes for the process to exit before terminating it. Never kills the process directly first. |
| `zs restart` | `zs stop` followed by `zs start`. |
| `zs status` | Whether the process is running, the RCON `players` output, whether the game port is listening, and the last log lines. |
| `zs logs` | Follow `data\logs\server.log`. |
| `zs backup` | Save over RCON, then zip `data\zomboid\Server`, `Saves` and `db` into `backups\<timestamp>.zip`; delete zips older than `BACKUP_KEEP_LOCAL_DAYS`. |
| `zs update` | Update the dedicated server with SteamCMD. Refuses while the server is running. |
| `zs render` | Render only, and print the resulting `Mods=` and `WorkshopItems=`. |
| `zs rcon <command>` | Run one RCON command and print the response. |

Run them from a terminal, for example `windows\zs.cmd status`. Double-clicking `zs.cmd` is not
useful, since every command takes arguments.

## Layout

```
windows/
  setup.cmd, setup.ps1   First configuration, install and start
  zs.cmd, zs.ps1         Day-to-day operations (see the table above)
  lib/                   Shared PowerShell modules (dot-sourced, not executed directly)
  tests/                 Pester tests; run on Linux, no Windows machine or game needed
```

Everything under `server\`, `steamcmd\`, `data\`, `backups\` and `.env` is local to your machine
and is not committed to git.

## Configuration and rendering

`windows\lib\Render.ps1` reads `config\servertest.ini.tpl`, `.env` and `config\mods.txt` and
writes `data\zomboid\Server\servertest.ini`, exactly like `scripts/render-config.sh` does on
Linux: same placeholder rule, same `mods.txt` grammar (see [`mods.md`](mods.md)), same fallback to
`config\servertest_SandboxVars.example.lua` when the per-world file is missing, and the same
refusal to render an empty mod list over a world that already had mods, unless `ALLOW_VANILLA=1`
is set. CI runs both implementations against the same fixtures and diffs the output byte for
byte, so the two engines cannot silently drift apart.

The `.ini` template adds one variable on top of what the rest of this repository documents:
`UPnP=${UPNP}`. `UPNP` in `.env` is `true` or `false`; `setup.sh` and cloud-init default it to
`false`, and the Windows setup writes whatever you answered.

## Starting the server: how the Java command is built

`zs start` and `setup.cmd` do not hardcode the server's classpath. They read the
`StartServer64.bat` that SteamCMD installs, keep its JVM flags and classpath, replace `-Xms`
and `-Xmx` with `MIN_MEMORY` and `MAX_MEMORY` from `.env`, and append `-servername servertest`,
`-adminusername`, `-adminpassword`, `-cachedir=<absolute path to data\zomboid>` and `-port`.
Parsing the shipped launcher instead of hardcoding its contents keeps this working across game
updates.

## RCON

`windows\lib\Rcon.ps1` implements the Source RCON protocol directly over TCP (little-endian
`size`, `id`, `type`, body, two trailing null bytes), including the "late packet" workaround
that `scripts/rcon.sh` also applies: Project Zomboid answers a command with the *next* packet, so
the client sends a throwaway `players` command right after the real one and reads until the real
command's response arrives. The client only ever connects to `127.0.0.1`.

## Security

- RCON listens on every network interface on the native server (Docker binds it to localhost
  instead). The setup never opens `27015/tcp` on the Windows firewall, and you should not forward
  it on your router.
- `.env` and the rendered `.ini` hold passwords. The scripts never print the admin or RCON
  password; only the server password appears, in the final summary.
- Nothing is downloaded from anywhere except Valve's SteamCMD distribution URL and Steam itself.

## Language

The CLI resolves its language the same way the bash tools do: the `ZS_LANG` environment variable,
then the `ZS_LANG=` line in `.env`, then the system's UI culture (`es*` becomes `es`), otherwise
English. Message catalogs live in `windows\lib\i18n\en.psd1` and `es.psd1`, and a Pester test
keeps their key sets in sync.

## Backups

`zs backup` saves the world over RCON and zips `Server`, `Saves` and `db` under
`data\zomboid\` into `backups\<timestamp>.zip`, then deletes zips older than
`BACKUP_KEEP_LOCAL_DAYS` (default 3, same key as the Linux `.env`). There is no upload to object
storage in this first iteration; copy the zip files elsewhere yourself if you want an off-machine
copy.

## Testing this engine without a Windows machine

Everything except actually running the game is testable on Linux, because the code only uses
.NET APIs that work the same way in PowerShell 7 on Linux:

```bash
docker run --rm -v "$PWD:/repo" -w /repo mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command "
  Install-Module Pester -RequiredVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck
  Import-Module Pester -RequiredVersion 5.5.0
  \$config = New-PesterConfiguration
  \$config.Run.Path = 'windows/tests'
  \$config.Run.Exit = \$true
  Invoke-Pester -Configuration \$config
"
```

This covers `.env` parsing and writing, the `mods.txt` grammar, RCON packet encoding and
decoding, `StartServer64.bat` parsing, the render parity check against
`scripts/render-config.sh`, and the `es`/`en` catalogs. `.github/workflows/ci.yml` runs the same
suite, plus PSScriptAnalyzer, on every push and pull request.

Actually starting the game, SteamCMD, the Windows firewall, and elevation can only be exercised on
real Windows. `.github/workflows/windows-smoke.yml` (`workflow_dispatch`, manual) does that end to
end on a `windows-latest` runner: `setup.ps1 -NonInteractive`, `zs status`, `zs rcon players`,
`zs backup`, `zs stop`, then it checks the process exited, the backup zip exists and the save
directory was created.

## Out of scope for the first iteration

A scheduled task to keep mods up to date, a Discord notifier, a watchdog, starting at boot,
backups to cloud storage, a desktop shortcut and a graphical installer are not implemented yet.
The design record in `docs/history/windows-plan.md` covers the reasoning; a native
Linux engine without Docker would reuse the same approach.
