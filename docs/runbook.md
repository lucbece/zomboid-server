# Runbook

Operations reference for the Project Zomboid server: how each moving part works, and what to do
when something breaks. It is provider-independent — everything here applies equally to a server
running on a laptop and to one running on a cloud VM.

The starting point for a new installation is [`../README.md`](../README.md). Anything specific to
Oracle Cloud lives in [`deploy-oracle.md`](deploy-oracle.md). The component layout and the
decisions behind it are in [`architecture.md`](architecture.md).

## 1. Layout

| Path | Contents |
|---|---|
| `config/` | Source of truth: `servertest.ini.tpl`, the spawn Lua files, and two per-world files that are not in git: `servertest_SandboxVars.lua` and `mods.txt` (created from their `.example` twins) |
| `.env` | Secrets and per-machine settings. Not in git |
| `data/zomboid/` | The container's `/home/steam/Zomboid`: rendered config, saves, logs, native backups, `db/` |
| `data/workshop/` | Downloaded Workshop content, under `content/108600/<workshop_id>/` |
| `backups/` | Local `.tar.zst` archives written by `scripts/backup.sh` |
| `bin/mcrcon` | The RCON client, built by `make mcrcon` |

On a cloud VM the repository lives in `/opt/zomboid-server`, the administrative user is `pz`, and
cron logs go to `/var/log/zomboid/`.

Never edit files under `data/` by hand. `make render` overwrites them from `config/` and `.env`.

## 2. Rendering the configuration

`scripts/render-config.sh` produces `data/zomboid/Server/servertest.ini` from
`config/servertest.ini.tpl` with `envsubst`, and copies the `.lua` files alongside it. It runs
automatically as part of `make up` and `make restart`.

Two safeguards are worth knowing about. Every `${VAR}` in the template must be defined in `.env`,
and — with the exception of the Discord and mod placeholders — non-empty; otherwise the script
fails instead of writing a half-configured server. And if any placeholder survives substitution,
the output is discarded.

The mod keys are generated from `config/mods.txt`, which is optional: without it both keys are
empty and the server is vanilla. See [`mods.md`](mods.md) §1 for how the file reaches a VM and
for the guard against rendering an empty list over a modded world.

- `WorkshopItems=` lists each Workshop ID once, in file order.
- `Mods=` lists every Mod ID, in file order, which is the load order.
- A single Workshop item that ships several mods puts them on one line separated by `;`.
- `MOD_ID_PREFIX` in `.env` prepends a string to each Mod ID. It exists because early Build 42
  builds required a `\` prefix. On 42.20.4 both forms load identically and the prefix is left
  empty. Details in [`mods.md`](mods.md).

The server name is `servertest` throughout. It is the game's default and it names every config
file; changing it means renaming all of them.

## 3. Starting and stopping

The game does not handle `SIGTERM` reliably. Every shutdown path goes through RCON.

`scripts/stop.sh` announces the shutdown in chat, waits `WARN_SECONDS` (60 by default), issues
`save` and then `quit`, and waits up to `SHUTDOWN_TIMEOUT` seconds for the container to exit. It
first clears the container's restart policy, because `restart: unless-stopped` would otherwise
bring the server straight back up. `WARN_SECONDS=0 scripts/stop.sh` skips the warning when nobody
is connected.

`scripts/restart.sh` is `stop.sh`, then a re-render, then `docker compose up -d`. This is the way
to apply changes to mods or to the ini.

Some ini keys can be reloaded without a restart:

```bash
make rcon CMD=reloadoptions
```

Mods and most sandbox variables cannot.

On a VM, `infra/systemd/zomboid.service` starts the server at boot and calls `scripts/stop.sh`
as its `ExecStop`, so an operating system shutdown also saves the world. The unit is installed
from the repository, so `make sync` updates it.

## 4. Backups

Three independent layers:

1. **The game's own rolling backups.** Configured in `config/servertest.ini.tpl`:
   `BackupsCount=5`, `BackupsPeriod=60`, `BackupsOnStart=true`, `BackupsOnVersionChange=true`.
   They are written as dated zip files into `data/zomboid/backups/`. Short-term safety net only —
   they live on the same disk as the world.
2. **`scripts/backup.sh`.** Issues `save` over RCON when the server is running, waits, then
   archives `Saves/Multiplayer/servertest`, `Server/` and `db/` into
   `backups/zomboid-YYYYmmdd-HHMM[-label].tar.zst`. If `BACKUP_BUCKET` is set in `.env` it copies
   the archive to object storage with `rclone`. Local archives older than
   `BACKUP_KEEP_LOCAL_DAYS` (3 by default) are deleted. It works with the server stopped, in
   which case the `save` step is skipped, and `--no-upload` keeps it local.
3. **A daily cron job** on the VM, at the hour set by `backup_hour`, guarded by `flock` and
   logged to `/var/log/zomboid/backup.log`.

Retention in the bucket is enforced by an object storage lifecycle rule, 30 days by default.

Copying a running world without a preceding `save` can produce a torn archive: the saves are a
mix of flat files and SQLite. Always go through `backup.sh` rather than tarring `data/` directly.

### Restoring

```bash
make restore FILE=backups/zomboid-20260903-0600.tar.zst
```

`scripts/restore.sh` asks for confirmation (type `restore`), stops the server cleanly, archives
the current world as `pre-restore`, deletes it, extracts the chosen archive and starts the server
again. `--yes` skips the confirmation. The argument may also be a remote path, for example
`oci:zomboid-backups/zomboid-20260903-0600.tar.zst`; list what is available with
`rclone lsl oci:zomboid-backups`.

## 5. Wiping and starting the real world

Several sandbox settings are baked in when the world is generated — the loot map size, the
initial zombie population, the erosion speed. Changing them afterwards does not fully apply. The
usual sequence is therefore: run a throwaway world to validate the setup, decide the rules, then
wipe and start the world that counts.

```bash
make wipe
```

`scripts/wipe.sh` performs a clean shutdown, takes a `pre-wipe` backup, and deletes
`Saves/Multiplayer/servertest`, `db/` and the native backups. It asks you to type `wipe`, and
`--yes` skips that. It deliberately does not restart the server: the point of a wipe is to change
the configuration before the new world is generated.

After a wipe:

1. Edit `config/servertest_SandboxVars.lua` (not versioned; `setup.sh` creates it from the vanilla example).
2. Set the final mod list in `config/mods.txt` (not versioned; absent means vanilla).
3. Review `PVP`, `MaxPlayers`, `Public` and `SafetySystem` in `config/servertest.ini.tpl`.
4. Commit the versioned files, `make sync` against a VM, then start the server.

Leave `ServerPlayerID` and `ResetID` alone. Changing them forces every client to create a new
character; they are versioned so that a rebuilt server keeps the same identity.

## 6. Updating

### The game image

`docker-compose.yml` pins the image by digest, so nothing changes on its own. To move to a newer
build, resolve the digest of the tag you want:

```bash
docker pull danixu86/project-zomboid-dedicated-server:latest
docker image inspect danixu86/project-zomboid-dedicated-server:latest \
  --format '{{index .RepoDigests 0}}'
```

Put that `sha256:…` into the `image:` field of `docker-compose.yml`, commit, and run
`make update`. `scripts/update.sh` takes a `pre-update` backup, shuts the server down cleanly,
pulls, and starts it again. Confirm the result:

```bash
make logs | grep -i 'version='
```

A newer image can bring a newer game version, which clients on the previous version cannot join
until Steam updates them. Rolling back is the same procedure with the previous digest.

### The operating system

On the VM, `unattended-upgrades` is enabled with automatic reboot disabled: rebooting with
players connected loses progress. Reboot deliberately instead:

```bash
make remote-down
ssh pz@<IP> 'sudo reboot'
```

The systemd unit brings the server back on the next boot.

## 7. RCON

`scripts/rcon.sh` wraps `mcrcon` against the local server, reading the password from `.env`.
`make rcon CMD=…` and `make remote-rcon CMD=…` are the entry points. Frequently used commands:

| Command | Effect |
|---|---|
| `players` | List connected players |
| `save` | Force a world save |
| `quit` | Save and shut down |
| `servermsg "text"` | Broadcast a message |
| `setaccesslevel "name" admin` | Grant administrator rights to an existing account |
| `kickuser "name"` / `banuser "name"` | Moderation |
| `reloadoptions` | Re-read the ini keys that support hot reload |

RCON is bound to `127.0.0.1`. Exposing it to the network would hand out full control of the
server.

## 8. Troubleshooting

### "Server has different version than client"

The client and the server are on different builds.

1. Check the server's version: `make logs | grep -i 'version='`.
2. On the client, Steam → Project Zomboid → Properties → Betas must be **None**. `legacy41` is
   Build 41.
3. Let Steam finish updating, and verify the integrity of the game files.
4. If the server got ahead because the image was updated, roll the digest back and run
   `make update`.

### "You have different mods" or a checksum mismatch

The client has a different version of a mod, or is missing one.

1. The client must be subscribed to the mod and have Workshop downloads enabled. Server mods are
   fetched on connect; sometimes the client has to be restarted.
2. The server only picks up a Workshop update on restart: `make restart`.
3. On the client, verify the game files and clear `~/Zomboid/Workshop` (Linux) or
   `%USERPROFILE%\Zomboid\Workshop` (Windows), then resubscribe to the mod named in the message.
4. To clear the server's Workshop cache: stop the server, delete `data/workshop/content`, start
   it again. Everything is re-downloaded.

### A mod was added and the server no longer starts

Remove its line from `config/mods.txt` and restart. Diagnosing which mod and why — missing
dependencies, manual-install mods, dependencies deleted from the Workshop — is covered in
[`mods.md`](mods.md).

### Players cannot connect but the server is up

1. Confirm the log shows `*** SERVER STARTED ****`.
2. Confirm they are using UDP port `16261`, not `27015`.
3. Confirm the network path: on a cloud VM, the security group must allow UDP 16261-16262 from
   `0.0.0.0/0`; on a home network, the router must forward those ports. On the host,
   `sudo ufw status` and `docker compose ps` show the host firewall and the published ports.
4. As a last resort, try opening UDP `8766-8767` as well. Older guides and the upstream image's
   reference compose file list them as Steam ports; the Build 42 documentation only lists
   16261-16262. Opening them requires a rule in the security group, a published port in
   `docker-compose.yml`, and a restart.

### The world is corrupted

Restore the most recent good archive (section 4). The game's own backups in
`data/zomboid/backups/` are an alternative source.

## 9. Validating changes without deploying

All of these run locally and are the same checks CI performs.

```bash
# Shell scripts
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  -x setup.sh scripts/*.sh scripts/lib/*.sh

# Terraform/OpenTofu
tofu fmt -check -recursive infra/terraform
tofu -chdir=infra/terraform/envs/prod init -backend=false
tofu -chdir=infra/terraform/envs/prod validate

# Secrets, over the full history
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest detect --source /repo --no-banner
```

`infra/cloud-init.yaml` is an OpenTofu template, not a plain cloud-config file, so it has to be
rendered before it can be validated — and both clone modes have to be checked, because the
template contains `%{ if use_deploy_key ~}` conditionals:

```bash
scripts/render-cloud-init.sh https /tmp/ci-https.yaml
scripts/render-cloud-init.sh ssh   /tmp/ci-ssh.yaml
docker run --rm -v /tmp:/mnt ubuntu:24.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
   cloud-init schema --config-file /mnt/ci-https.yaml &&
   cloud-init schema --config-file /mnt/ci-ssh.yaml'
```

`tofu plan` also exercises the variable validation rules; without `~/.oci/config` it fails at the
provider, after every variable has been checked.
