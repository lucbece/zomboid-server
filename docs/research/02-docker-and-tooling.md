# Project Zomboid Dedicated Server: Docker/Linux tooling research (Sept 2026), focus on Build 42

Research date: 2026-09-03. All info below is from web search + GitHub/Docker Hub fetches on that date; treat "last updated" figures as of this date.

## 0. Critical context: Build 42 is now the STABLE branch (since 29 July 2026)

This changes the whole framing of "B42 support" for tooling.

- Project Zomboid **42.20 went to the public/stable Steam branch on 29 July 2026**. Build 42 is no longer a beta you opt into — it is now what `steamcmd +app_update 380870` installs **by default**, with no `-beta` flag needed.
  Source: https://respawnhost.com/en/wiki/games/project-zomboid/project-zomboid-b42-server/
- Steam branches for app id 380870 (dedicated server) as of Sept 2026:
  - *(no branch flag)* → current stable = Build 42.20+
  - `-beta legacy41` → last Build 41 release (Dec 2021), for people who want to stay on B41
  - `-beta 42.19` → last B42 *unstable* build, for save-compatibility edge cases
  - Source: https://respawnhost.com/en/wiki/games/project-zomboid/project-zomboid-b42-server/
- Practical implication for the requested repo: **you no longer need to fight for "B42 access"** — you need tooling that (a) doesn't hardcode an old `-beta unstable`/`-beta b42multiplayer`-style branch name that predates the promotion (this would now be *wrong*, pointing at the frozen 42.19 unstable snapshot instead of current stable), and (b) still lets you pin `legacy41` if you ever need to roll back to B41, or pin a specific B42 point release if a future B43 unstable appears.
- General discussion / community background: https://supercraft.host/article/project-zomboid-roadmap-2026/ , https://winternode.com/blog/project-zomboid/build-42-multiplayer-setup , https://pzfans.com/project_zomboid_server_survival_admin_tips_for_b41__b42/

---

## 1. Docker images

### 1.1 Danixu/project-zomboid-server-docker (Docker Hub: `danixu86/project-zomboid-dedicated-server`) — **most actively maintained, recommended**

- GitHub: https://github.com/Danixu/project-zomboid-server-docker
- README: https://github.com/Danixu/project-zomboid-server-docker/blob/main/README.MD
- **Activity**: last push **2026-09-01** (yesterday relative to research date). Only 4 open issues, and recent closed issues are explicitly B42-migration related:
  - #46 "fix: skip the unstable image when there is no open beta" (closed)
  - #39 "Allow Steam public branch when STEAMAPPBRANCH is unset" (closed)
  - #45 "fix: pass the server arguments without a second shell parsing them"
  - #43 "graceful shutdowns"
  This shows the maintainer actively adapted the image for the B42-goes-stable transition.
- **Branch selection**: `STEAMAPPBRANCH` build-arg (not a plain runtime env var — it's baked in at `docker build --build-arg STEAMAPPBRANCH=<branch>`, or resolved automatically from `.env` when using `docker compose build`). If unset, it now correctly falls back to Steam's public (stable) branch — i.e. **Build 42 today** — per issue #39.
- **Config/env vars**: Runtime env vars include `ADMINUSERNAME`/`ADMINPASSWORD` (password required on first start), `PUBLIC`, `DISPLAYNAME`/`SERVERNAME`, `SERVERPRESET` (Apocalypse/Beginner/Builder/FirstWeek/SixMonthsLater/Survival/Survivor).
- **Mods**: `WORKSHOP_IDS` (semicolon-separated) and `MOD_IDS`. Mods install on the *second* server start (first start generates configs).
- **INI ownership**: By default the entrypoint **rewrites** `servertest.ini`'s Mods/WorkshopItems (and other env-mapped fields) on every boot. Set `SELF_MANAGED_MODS=1` (or `true`) to tell the container **not** to touch Mods/WorkshopItems, so you can bind-mount your own `servertest.ini` / manage mods by hand. This is exactly the mechanism a git-managed config repo needs.
- **Volumes**: `CACHEDIR` env var controls where server data (saves, ini, logs) lives, default `/home/steam/Zomboid`. Compose example maps game data to `/home/steam/Zomboid` and Workshop mods to `/home/steam/pz-dedicated/steamapps/workshop`. Both should be bind-mounted for persistence.
- **Ports**: Steam clients need UDP 8766-8767 and UDP 16261 (configurable via `PORT`); non-Steam clients additionally need TCP 16262-16272. Compose file also exposes TCP 27015 for RCON.
- **User/UID**: Runs as a `steam` user inside the container (not root); directories under `/home/steam`.
- **Memory**: `MIN_MEMORY` / `MAX_MEMORY` (independent JVM heap limits), or `MEMORY` as a single fallback for both.
- **RCON**: `RCONPASSWORD` env var; docs stress it must be non-trivial ("secure").
- **Auto-update**: `FORCEUPDATE` env var forces a SteamCMD update on every container start; `FORCESTEAMCLIENTSOUPDATE` works around a known Workshop-download bug related to `steamclient.so`.
- **B42 verdict**: Works today essentially "for free" because B42 is the default branch and the image's fallback-to-public-branch bug was fixed in #39. This is the image with the freshest git history addressing exactly this transition.

### 1.2 Renegade-Master/zomboid-dedicated-server (Docker Hub/ghcr/quay: `renegademaster/zomboid-dedicated-server`) — **stale, caution**

- GitHub: https://github.com/Renegade-Master/zomboid-dedicated-server
- **Activity**: `updated_at` shows 2026-08-28 (recent *repo metadata* touch, e.g. a star or GitHub Actions run) but the actual **last code push (`pushed_at`) is 2024-06-06** — over 2 years stale relative to the B42 stable promotion (July 2026). 32 open issues, including open reports like "Mods not working?" (#81) and "Don't recreate the entire server on restart" (#46) that remain unresolved.
- **Branch selection**: `GAME_VERSION` env var ("Game version to serve `[a-zA-Z0-9_]+` public") — use `public` for current stable. Because the image predates the July 2026 promotion, any docs/examples referencing an "unstable"/B42-beta value are now obsolete; `public` is the only value you should trust.
- **Config**: Env vars overwrite the generated `[name].ini` under `/home/steam/Zomboid/Server/`; the README explicitly warns that hand-editing the ini gets clobbered back to defaults/env values — i.e. **no clean way to bring your own ini** without patching the entrypoint. This is a real drawback for a git-managed-config workflow.
- **Mods**: `MOD_NAMES` + `MOD_WORKSHOP_IDS` env vars, also override ini values (same overwrite caveat).
- **Volumes**: `ZomboidConfig` and `ZomboidDedicatedServer` bind mounts must be pre-created by the user or Docker will create them as root and you'll hit permission errors — a known rough edge, explicitly called out in the README.
- **Ports**: 16261/udp (game), 16262/udp (added later per issue/PR #43), 27015/tcp (RCON).
- **User**: Designed to run rootless (non-root `steam`-like user) — a genuine strength — but combined with the pre-create-folders gotcha above.
- **Memory**: `MAX_RAM` (regex `[0-9]+m`, default `4096m`).
- **RCON**: `RCON_PASSWORD` + `RCON_PORT`.
- **Auto-update**: not documented; appears manual (re-pull image / restart container).
- **B42 verdict**: **Uncertain/likely functional but unverified and unmaintained through the transition.** Because it wasn't touched since mid-2024, nobody has fixed anything B42-specific in it; it may "just work" since it defaults to Steam's public branch, but there's no evidence in the repo that the maintainer validated it against 42.20, and the no-custom-ini limitation is a real blocker for a git-config-driven setup. **Do not build a repo around this image without testing it yourself first.**

### 1.3 cyrale/project-zomboid — **dead, archived**

- GitHub: https://github.com/cyrale/project-zomboid (README: https://github.com/cyrale/project-zomboid/blob/main/README.md)
- **Archived on GitHub** (`"archived": true`), last actual push 2021-07-24 (5 years stale). Wraps LinuxGSM inside Docker rather than steamcmd directly.
- **B42 verdict**: Not usable as-is; ignore for new deployments.

### 1.4 afey/zomboid (Docker Hub) — **dead**

- Docker Hub: https://hub.docker.com/r/afey/zomboid — "last updated over 4 years ago", 100K+ pulls (legacy popularity, not current relevance). Wraps LinuxGSM.
- **B42 verdict**: Predates B42 entirely. Do not use.

### 1.5 ich777/docker-steamcmd-server (the generic base for "steamcmd-zomboid" on Unraid)

- GitHub: https://github.com/ich777/docker-steamcmd-server (branch `projectzomboid` holds the Zomboid-specific Dockerfile: https://github.com/ich777/docker-steamcmd-server/tree/projectzomboid)
- **Activity**: repo-wide last push 2026-07-18, actively maintained; this is a generic "steamcmd + selected game" framework used across ich777's whole catalog of ~100 Unraid game-server templates, with Zomboid as one branch/template.
- **Design**: Primarily built for **Unraid's Community Applications** UI (env vars mapped to Unraid template XML), not a bare docker-compose-first workflow — usable outside Unraid but the docs/UX assume it.
- **Update behavior**: "If a newer version of the game is available, simply restart the container to update" — implies auto-update-on-restart via steamcmd validate, not a pinned/reproducible version by default (you'd need to freeze the image tag or add `validate`-skip logic yourself for reproducibility).
- **B42 verdict**: Since it just calls steamcmd against 380870 with no branch pinned, it inherits current-stable = B42 automatically. Good option **if you're specifically on Unraid**; less ideal for a plain cloud VM / git-driven repo because of the Unraid-first design and update-on-restart model working against reproducibility.

### 1.6 Other actively-maintained candidates found during research

- **`m4lagon/project-zomboid-server`** (Docker Hub: https://hub.docker.com/r/m4lagon/project-zomboid-server, source likely https://github.com/meshi-team/project-zomboid-server — not independently verified via GitHub API in this pass) — **updated ~4 days before research date**, explicitly documents Build 42 as `latest`, keeps B41 available pinned as `41.78.19`, and an `unstable` tag tracks Steam's beta branch when one is open. Clean separation of startup/server/sandbox env-var groups, RCON via `docker exec ... admin-console`, `SERVER_MEMORY`, two volumes (`/root/Zomboid`, steam workshop dir). `FORCE_PRESET=1` fully regenerates config from env — implies (unconfirmed) there's a way to *not* force it and bring your own ini, but this needs verification by reading the actual Dockerfile/entrypoint before relying on it. Worth a second look if you want richer sandbox-var env-var coverage than Danixu's image offers, but it's less proven (smaller community footprint, GitHub source not conclusively located).
- **`indifferentbroccoli/projectzomboid-server-docker`** (https://github.com/indifferentbroccoli/projectzomboid-server-docker) — actively maintained, last push 2026-08-07, 6 open issues. Not deep-dived in this pass but worth short-listing.
- **`0xjemm/pz-panel`** (https://github.com/0xjemm/pz-panel) — not a server image but a **Docker-native admin panel for B42 servers specifically** (web UI, RCON console, scheduled tasks, backups, mod checking; runs each game server as a sibling container it manages). Last push 2026-08-09, brand new (0 stars, 0 issues — essentially unproven/early). Interesting if you want a UI layer on top of a Docker server later, but too new/unvalidated to be the backbone of a serious deployment today.
- Numerous other thin forks/clones exist (`PepsiDogs/docker-zomboid`, `PepeCitron/projectzomboid-server`, `daniel-gwilt-software/project-zomboid-server`, `Tunederuz/project-zomboid-docker`, `DinoDevs/docker-project-zomboid-server`, `underaft/zomboid-docker` — this last one's GitHub API entry now 301-redirects, i.e. **the repo/owner was renamed or the account changed**, so treat that specific link as unstable) — none showed evidence of activity/maturity beyond Danixu's and m4lagon's images in this research pass.

---

## 2. LinuxGSM `pzserver`

- GitHub source: https://github.com/GameServerManagers/LinuxGSM (repo-wide, last push 2026-08-07, very active — 403 open issues across the whole multi-game project, which is normal for LinuxGSM's scale).
- Docs: https://linuxgsm.com/servers/pzserver/
- Default config: https://github.com/GameServerManagers/LinuxGSM/blob/master/lgsm/config-default/config-lgsm/pzserver/_default.cfg
- **Branch config**: LinuxGSM has a generic SteamCMD `branch` setting (empty by default = Steam's public/stable branch) plus a `betapassword` field, applied uniformly across all LGSM-managed SteamCMD games — there is no Zomboid-specific "`branch=`" documented on the pzserver marketing page itself, but the mechanism is the standard LGSM one: set `branch="legacy41"` (or another `-beta` value) in your instance's `common.cfg`/`pzserver.cfg` to override the default, and leave it unset to track current stable (today, B42). I could not find a LinuxGSM changelog/forum post from 2026 explicitly confirming a validated B42 dedicated-server pass — **flag this as unconfirmed**; the mechanism should work because it's a generic passthrough to steamcmd's `-beta` flag, but I found no direct community report of someone using `branch=` for Zomboid B42 specifically as of Sept 2026.
- **Pros of LinuxGSM vs Docker**:
  - Mature, single well-documented tool covering >100 game servers with a consistent CLI (`./pzserver start|stop|update|backup|monitor`), so if you already run other LGSM servers the operational muscle-memory transfers.
  - Built-in backup/monitor/details commands, systemd integration is first-class and documented.
  - No container runtime dependency — lighter weight on a small VPS if Docker itself feels like overhead.
- **Cons of LinuxGSM vs Docker**:
  - Installs directly onto the host OS (Ubuntu 24.04 LTS / Debian 11 / EL8 per docs) rather than being isolated — less reproducible across different base images/distros than a container, and upgrading the *host* OS carries more risk of breaking the install.
  - Config-in-git story is weaker: LGSM's own `.cfg` files control startup behavior, while the actual game config (`servertest.ini`, `SandboxVars.lua`) still lives under the LGSM-managed data directory on the host — you'd symlink these into a git repo yourself; there's no built-in "bring your own ini" concept the way some Docker images expose via an env-var opt-out.
  - No image versioning/pinning story — reproducing "exactly this setup" on a new VM means re-running the LGSM installer + your own config restore, versus `docker pull <image>@<digest>` + volume restore.

---

## 3. Bare-metal: steamcmd + systemd + bash wrapper

Representative community examples:
- https://github.com/nicholi/pz_scripts — install scripts for `/opt/steamcmd`, `/opt/steamgames/ProjectZomboid`, `/opt/steamdata/Zomboid`; ships a systemd-integrated install script, a **graceful-restart script that warns players 30 minutes ahead**, a **Workshop-update poller** (checks Steam Web API every 30 min so server mods stay in sync with client versions), and RCON shell helper functions (`pz.bashrc`). Includes a **systemd timer for daily scheduled restart-with-backup and 2-week backup retention** — a genuinely useful pattern to copy even if you don't use this repo verbatim.
- https://github.com/Dyarven/zomboid-server-on-arm — similar pattern targeted at ARM64 VMs, also sets up a systemd service.
- https://blog.sergeantbiggs.net/posts/project-zomboid-or-taming-misbehaving-services-with-systemd/ — a detailed writeup specifically about the quirks of wrapping PZ's Java-based server launch script in systemd cleanly (signal handling, etc.) — good background reading before hand-rolling a unit file.
- https://shattered.io/project-zomboid-dedicated-server/ — general 2026 walkthrough covering steamcmd anonymous install of app 380870, config tuning, opening UDP ports, RCON, mods, and systemd.
- Official/community wiki: https://pzwiki.net/wiki/Dedicated_server (returned HTTP 403 to automated fetch during this research — worth reading manually, but treat as authoritative once accessed).

**Docker vs bare-metal for an 8-16 player friends server:**
- **Simplicity**: Bare metal is arguably *simpler to reason about* for a single-game single-VM box — no image layers, no volume-permission gotchas (several Docker images in section 1 have documented UID/permission foot-guns on first run). But Docker is simpler to *get right the first time* because the image encodes the java/steamcmd dependency chain for you; on bare metal you own that (32-bit libs historically needed by steamcmd, correct JVM, etc.).
- **Upgrade path**: Roughly a wash today, since B42-as-stable means both approaches just re-run `steamcmd ... +app_update 380870 validate` with no special branch flag. Docker's advantage appears when you want to **pin** a known-good server version against a save file (build a tagged image once, keep running it, upgrade deliberately) — harder to enforce on bare metal where a bare `systemctl restart` + validate will always pull whatever is currently "stable" unless your wrapper script explicitly checks/pins a buildid.
- **Reproducibility**: Docker wins clearly here — `docker-compose.yml` + a `.env` + bind-mounted config directory is a complete, portable description of the server that reproduces identically on a new VM/provider. Bare metal reproducibility depends entirely on how well you've scripted the install (the `pz_scripts`-style repos above are a reasonable answer to this, but you're maintaining that idempotent-installer discipline yourself).
- **Overhead for 8-16 players**: Negligible either way — PZ's own JVM/RAM footprint dwarfs Docker's overhead at this scale. Choose based on the reproducibility/config-in-git story, not performance.

---

## 4. Backup tooling

- RCON-triggered save before backup is the standard recommended pattern: `rcon -a 127.0.0.1:16261 -p <password> "save"` forces an in-memory flush to disk before you copy files, reducing (not eliminating) the chance of copying a save mid-write. Source: https://steamcommunity.com/sharedfiles/filedetails/?id=2821744058 , https://gist.github.com/jamiemtdwyer/e504cd817b97e6d64c574531bb203f18
- Practical guidance from hosting-provider docs (useful even if self-hosting): saves live under `Zomboid/Saves/Multiplayer/<savename>/`, and providers recommend timestamped copies of that directory. Sources: https://wabbanode.com/help/project-zomboid/how-to-configure-server-backups-on-your-project-zomboid-server , https://connecthosting.net/help/games/project-zomboid/project-zomboid-backups-and-saves , https://supercraft.host/wiki/project-zomboid/backup_player_data/ , https://pingplayers.com/knowledgebase/project-zomboid/how-to-back-up-your-server-data-and-restore-it-to-a-server
- **Safe procedure synthesized from the above + general best practice for a live SQLite-backed game save** (PZ multiplayer saves are largely file/SQLite based, so copying while the DB is being written risks a torn/corrupt copy):
  1. RCON `save` to force a flush.
  2. Give the server a few seconds (saves are not synchronous/instant across all files).
  3. Either (a) briefly pause writes — e.g. RCON `players` quiet period / scheduled low-traffic window — before copying, or (b) use a filesystem-level atomic snapshot (LVM snapshot, ZFS snapshot, or a cloud provider's disk snapshot) instead of a live `cp`/`rsync`, which avoids the torn-write risk entirely without needing to stop the server. Full server stop + copy is the only *guaranteed*-consistent method but is disruptive for a 24/7 friends server — reserve it for periodic "cold" backups (e.g. weekly) layered on top of frequent "hot" RCON-save+copy backups (e.g. hourly/daily).
  4. Ship the resulting archive off-box with `rclone` (supports S3/B2/Drive/SFTP/etc.) on a cron/systemd-timer schedule; `restic` is also usable for deduplicated/encrypted backups, though the search here surfaced only a general note that restic's SFTP backend has caveats — pair it with rclone's SFTP support if SFTP is your target rather than restic's own SFTP backend.
  5. `pz_scripts` (https://github.com/nicholi/pz_scripts) demonstrates this end-to-end already: systemd timer → daily restart+backup → 2-week retention. A reasonable starting point to copy/adapt rather than inventing from scratch.
- I did not find a polished, dedicated "rclone/restic + Project Zomboid" open-source project distinct from generic game-server backup patterns — this is a gap you'd fill yourself with a small script (RCON save → tar → rclone sync), which is genuinely simple to write (~30 lines).

---

## 5. Terraform / Ansible / cloud-init repos

- **https://github.com/bingops-com/pz-server** (blog: https://blog.bingops.com/blog/project-zomboid/ , Medium writeup: https://medium.com/@bingops/deploying-a-project-zomboid-server-with-terraform-ansible-c27312be0db5)
  - Terraform provisions a **Proxmox VE** VM (not a public cloud — relevant if you're not self-hosting a hypervisor); Ansible (`bootstrap.yml`, `site.yml`) configures SSH/firewall/app. Uses **Playit.gg tunnel** to expose the server without port-forwarding — convenient for home-lab, but adds a third-party relay dependency you may not want for a "friends server" you fully control.
  - Config management: Ansible role defaults (`roles/server/defaults/main.yml`) + `group_vars` (with `ansible-vault`-encrypted secrets) — reasonably professional structure, but **not framed around Build 42 at all** (no mention found), and the repo's own game-config story is role-variables-driven rather than "drop your servertest.ini/SandboxVars.lua files in git and have them deployed verbatim."
  - 33 commits total; well-documented with troubleshooting notes. Best of the IaC examples found, but **Proxmox-only** and **not B42-verified**.
- **https://github.com/hectorfaria/pz-server**
  - Targets **AWS** specifically: EC2 Spot Instances (cost optimization), S3 (save/config storage), Global Accelerator (latency). Uses Terraform + Ansible + Vagrant.
  - Explicitly marked **work-in-progress** with open TODOs (move S3 management into Terraform, create the pz service user via Ansible, add monitoring) — 27 commits, clearly earlier-stage than bingops' repo.
  - Config is **not git-managed**: expects a custom AMI baked with server config, plus manual upload of the Zomboid folder to S3 — the opposite of the git-driven config workflow you want.
  - No Build 42 mention found.
- No purpose-built "project zomboid cloud-init" single-file repo was found that's both current and B42-aware; cloud-init would in practice just be "install docker + docker-compose, pull your repo, `docker compose up -d`" — simple enough to write yourself rather than adopt a stale template.
- **Conclusion for this section**: nothing found is both (a) actively validated against Build 42 and (b) structured so that `servertest.ini`/`SandboxVars.lua`/mod lists live in git and deploy verbatim. This is the gap your own repo would fill — and it's a small gap: Terraform for the VM + a `docker-compose.yml` referencing Danixu's image + bind-mounting a `config/` directory from the same git repo covers most of what these two example repos do, more simply, and without the AWS-Spot/Proxmox-specific complexity.

---

## 6. Recommendation

**Build the git repo around Docker, not LinuxGSM or raw bare-metal, using `danixu86/project-zomboid-dedicated-server` as the base image**, structured like:

```
repo/
  terraform/            # VM (any cloud), security group opening 16261/udp, 16262-16272/tcp (non-Steam), 27015/tcp (RCON, keep restricted to your IP)
  docker-compose.yml     # pins the image by tag/digest; sets STEAMAPPBRANCH build-arg unset (tracks Steam stable = B42)
  config/
    servertest.ini        # hand-authored, bind-mounted; SELF_MANAGED_MODS=1 so the container never rewrites it
    SandboxVars.lua        # hand-authored, bind-mounted
    mods.txt / workshop-ids.txt   # source of truth you diff in PRs; feed WORKSHOP_IDS from this at deploy time
  scripts/
    backup.sh              # RCON save -> tar config+Saves dir -> rclone sync to off-box storage, run via systemd timer or cron
  README.md
```

Why this combination:
- **B42 is now free**: since 42.20 is Steam's default branch (since 29 July 2026), you don't need any special beta wrangling — just don't let an old image's stale `-beta` default fight you. Danixu's image is the one with a *recent, documented* fix (#39) for exactly the "what happens when `STEAMAPPBRANCH` is unset" question, and its maintainer has been pushing commits as recently as the day before this research.
- **Config-in-git works cleanly** only if the image lets you opt out of ini-rewriting. Danixu's `SELF_MANAGED_MODS=1` gives you that; Renegade-Master's image does not (it always overwrites the ini from env vars, per its own README warning) — that alone rules it out for your stated requirement.
- **Reproducibility**: Docker + Terraform beats bare-metal/LinuxGSM for "redeploy identically on a new VM," which is explicitly what you asked for.
- **Backups**: adopt the RCON-save-then-copy pattern, but prefer a filesystem/cloud snapshot over a live `cp`/`rsync` for the hot path, and keep a periodic full-stop cold backup as a safety net; ship offsite with rclone. Model the systemd-timer/retention structure on `nicholi/pz_scripts` even though that repo itself is bare-metal-oriented — the backup logic is runtime-agnostic and works unchanged against the Docker bind-mount paths.

**Flags/uncertainty to resolve before committing to this stack**:
1. I could not directly verify Danixu's entrypoint script source line-by-line in this pass (I relied on README + issue titles) — before relying on `SELF_MANAGED_MODS` in production, read `entrypoint.sh` in the repo to confirm exactly what it skips.
2. `m4lagon/project-zomboid-server` looked equally promising (explicit B42/B41/unstable tag scheme, richer sandbox-var coverage) but I could not conclusively locate/verify its GitHub source in this pass — worth a manual look before ruling it out as an alternative to Danixu's image.
3. LinuxGSM's `branch=` mechanism for B42 is architecturally sound (generic SteamCMD passthrough) but I found **no direct 2026 community confirmation** it's been exercised against Build 42 specifically for `pzserver` — treat as "should work, unverified" if you go that route instead.
4. No Terraform/Ansible example found is B42-validated; you're the first to combine "IaC + B42 + git-managed config" as far as this research surfaced — plan to test the full pipeline against a throwaway save before trusting it with your real world.

---

## 7. Verificación del entrypoint de Danixu (2026-09-03)

Resuelve el punto 1 de "Flags/uncertainty" de §6 y la tarea 1 de la Fase 1 de `PLAN.md`.
Fuente: clon de `https://github.com/Danixu/project-zomboid-server-docker` (branch `main`) leído línea
por línea el 2026-09-03: `Dockerfile`, `scripts/entry.sh`, `scripts/search_folder.sh`,
`docker-compose.yml`, `.env.template`.

Imagen verificada (la misma que usa este repo):

```
danixu86/project-zomboid-dedicated-server@sha256:a98b0f219f63ad9f08b0658cf77c2c165705ab8d74775fd3db6e50fd6f4961e1
```

### 7.1 Qué hace el entrypoint con `servertest.ini`

El entrypoint es `scripts/entry.sh` y **corre como root** (la base es `cm2network/steamcmd:root`);
solo el servidor en sí se lanza con `runuser -u steam`.

Antes de arrancar el server hace, en este orden:

1. **Pre-crea el ini vacío si no existe** (`entry.sh:171-175`):
   ```bash
   SERVERINI="${HOMEDIR}/Zomboid/Server/${SERVERNAME}.ini"
   if [ ! -f "${SERVERINI}" ]; then mkdir -p "${HOMEDIR}/Zomboid/Server/"; touch "${SERVERINI}"; fi
   ```
   No borra ni regenera un ini existente. Si el archivo ya está (nuestro caso: lo escribe
   `scripts/render-config.sh` antes del `up`), lo respeta y el server completa las claves que falten
   con sus defaults.

2. **Reescribe claves puntuales con `set_ini_option()`** (`entry.sh:178-214`), que hace
   `sed -i "s|^${key}=.*|${key}=${value}|"` si la clave existe, o la agrega al final si no.
   **Cada reescritura está condicionada a que la env var correspondiente esté definida y no vacía.**

   | Clave del ini | Env var que la dispara | Se toca si… |
   |---|---|---|
   | `Password` | `PASSWORD` | `PASSWORD` no vacía |
   | `RCONPassword` | `RCONPASSWORD` | `RCONPASSWORD` no vacía |
   | `Public` | `PUBLIC` | `PUBLIC` ∈ {1,true,0,false} |
   | `PublicName` | `DISPLAYNAME` | `DISPLAYNAME` no vacía |
   | `UDPPort` | `UDPPORT` | `UDPPORT` no vacía |
   | `Mods` | `MOD_IDS` | **solo si `SELF_MANAGED_MODS` NO está en 1/true** |
   | `WorkshopItems` | `WORKSHOP_IDS` | **solo si `SELF_MANAGED_MODS` NO está en 1/true** |
   | `Map` | (ninguna) | solo si algún mod del Workshop ya descargado aporta mapas (ver 7.2) |

   **No hay ninguna otra clave del ini que el entrypoint escriba.** Todo el resto
   (`MaxPlayers`, `Open`, `PVP`, `PauseEmpty`, `SaveWorldEveryMinutes`, `BackupsCount`,
   `BackupsPeriod`, `RCONPort`, `UPnP`, `Discord*`, anticheat, safehouses, etc.) queda 100 %
   bajo control del archivo que bind-montamos.

3. **`SELF_MANAGED_MODS=1`** (`entry.sh:216-234`) hace exactamente lo que promete: imprime
   `*** INFO: SELF_MANAGED_MODS is set; leaving Mods and WorkshopItems untouched ***` y **salta
   por completo** el bloque que setea `Mods` y `WorkshopItems`. Detalle importante: **sin** esa
   variable, `MOD_IDS`/`WORKSHOP_IDS` vacías **no** significan "no tocar" sino
   `set_ini_option "Mods" ""` — es decir, *borra* las listas del ini en cada arranque. Por eso
   `SELF_MANAGED_MODS=1` es obligatorio para un repo con la config en git.

4. **`SERVERPRESET`** (`entry.sh:114-132`): si está definida, copia
   `media/lua/shared/Sandbox/<preset>.lua` a `Server/<name>_SandboxVars.lua` **solo si el archivo
   no existe** (o si `SERVERPRESETREPLACE=true`). Dejándola vacía —como hacemos— nunca toca nuestro
   `servertest_SandboxVars.lua`.

### 7.2 Único caso en que toca `Map=` y `_spawnregions.lua`

`entry.sh:239-287`: si existe `${STEAMAPPDIR}/steamapps/workshop/content/108600`, corre
`search_folder.sh`, que escribe `~/maps.txt` **solo si algún mod ya descargado trae carpetas
`media/maps/<Mapa>`**. Si ese listado sale no vacío:

- `set_ini_option "Map" "<mapas>;Muldraugh, KY"` — pisa nuestra clave `Map`.
- Agrega líneas `{ name = ..., file = ... }` a `Server/<name>_spawnregions.lua` para los mapas que
  tengan `spawnpoints.lua`, solo si aún no están (`grep -q`).

**Con una lista de mods sin mapas (el caso de la Fase 1: `VB_CommonSense`) `maps.txt` no se genera
y ni `Map=` ni `_spawnregions.lua` se tocan.** Queda anotado como el único riesgo real de
"el contenedor me pisó la config": el día que se agregue un **map mod**, `Map=` del ini renderizado
va a ser reescrito por el entrypoint (agregando los mapas del mod y `Muldraugh, KY` al final) y el
`_spawnregions.lua` va a recibir entradas extra. Es un comportamiento *aditivo* y deseable, pero
hay que saber que la fuente de verdad de `Map=` deja de ser el `.tpl` en ese escenario.

### 7.3 UID/GID y permisos de los bind mounts

- La imagen hereda el usuario `steam` de `cm2network/steamcmd`: **`uid=1000(steam) gid=1000(steam)`**
  (verificado con `docker run --rm --entrypoint id <imagen> steam`). Coincide con el usuario `luc`
  del usuario del host (1000:1000), así que los bind mounts son escribibles desde ambos lados sin trucos.
- El entrypoint además arregla los permisos por su cuenta antes de arrancar (`entry.sh:300-305`):
  ```bash
  chown -R "${USER}:${USER}" "${STEAMAPPDIR}/steamapps/workshop" "${HOMEDIR}/Zomboid"
  chmod 755 "${HOMEDIR}/Zomboid"
  ```
  Como corre como root, esto neutraliza el clásico problema de "Docker creó el directorio como root".
  Igual creamos `data/zomboid` y `data/workshop` con `install -d -o 1000 -g 1000` antes del primer
  `up`, porque `chown -R` sobre un host con otro UID cambiaría el dueño de los archivos del host.

### 7.4 Rutas reales de volúmenes

Confirmadas contra `Dockerfile` (`STEAMAPPDIR=${HOMEDIR}/pz-dedicated`, `HOMEDIR=/home/steam`) y
contra el `docker-compose.yml` upstream:

| Contenido | Ruta en el contenedor | Bind mount de este repo |
|---|---|---|
| Datos del server (`Server/`, `Saves/`, `Logs/`, `db/`, `backups/`) | `/home/steam/Zomboid` | `./data/zomboid` |
| Mods del Workshop | `/home/steam/pz-dedicated/steamapps/workshop` (contenido en `.../content/108600`) | `./data/workshop` |
| Juego (no persistir) | `/home/steam/pz-dedicated` | — (viene en la imagen) |

`CACHEDIR` cambiaría la primera ruta vía `-cachedir=`, pero **`set_ini_option` y el chown usan
`${HOMEDIR}/Zomboid` hardcodeado**, así que setear `CACHEDIR` desincroniza el entrypoint del server.
Se deja vacía.

### 7.5 Apagado limpio

`entry.sh:325-386`: el entrypoint crea un FIFO `/tmp/pz-console` como stdin del server y atrapa
`TERM`/`INT` para escribir `quit` y esperar a que la JVM termine de guardar. Es decir, **un
`docker compose stop` sí guarda el mundo** en esta imagen. Aun así seguimos usando
`scripts/stop.sh` (RCON `servermsg` + `save` + `quit`) porque avisa a los jugadores y hace el `save`
explícito antes; `docker compose stop` queda solo como red de seguridad tras 120 s.

### 7.6 Decisión

**Se sigue con la imagen de Danixu; no se activa el fallback de Dockerfile propio de `PLAN.md` §1.**

Razón: con `SELF_MANAGED_MODS=1` y dejando **sin definir** `PASSWORD`, `PUBLIC` y `DISPLAYNAME`, el
entrypoint no escribe ninguna clave del ini salvo `RCONPassword` y `UDPPort`, y ésas las setea con
exactamente los mismos valores que ya venimos a poner desde `.env`/`.tpl` (`RCONPASSWORD` y
`UDPPORT`), así que el resultado es idéntico al renderizado. El control de la config desde git es
total. Como bonus, la imagen trae el juego ya instalado (buildid `24909836`), con lo que el primer
arranque no descarga los ~7 GB por steamcmd.

Notas operativas derivadas de la lectura del código:

- En este repo el nombre del server se fija con `SERVERNAME=servertest`; si no se define, el
  entrypoint igual usa `servertest` como default para los nombres de archivo pero **no** pasa
  `-servername`, lo cual es equivalente. Se define explícito para que no dependa del default.
- `FORCEUPDATE=true` actualiza el juego con steamcmd en cada arranque y rompe el pinneo por digest.
  Se deja en `false`; para actualizar se hace `docker compose pull` de una imagen nueva.
- `MEMORY` es ignorada si `MIN_MEMORY` **y** `MAX_MEMORY` están definidas (`entry.sh:42-46`).

---

### Sources (deduplicated)
- https://respawnhost.com/en/wiki/games/project-zomboid/project-zomboid-b42-server/
- https://supercraft.host/article/project-zomboid-roadmap-2026/
- https://winternode.com/blog/project-zomboid/build-42-multiplayer-setup
- https://pzfans.com/project_zomboid_server_survival_admin_tips_for_b41__b42/
- https://github.com/Danixu/project-zomboid-server-docker
- https://github.com/Danixu/project-zomboid-server-docker/blob/main/README.MD
- https://github.com/Danixu/project-zomboid-server-docker/blob/main/docker-compose.yml
- https://hub.docker.com/r/danixu86/project-zomboid-dedicated-server
- https://github.com/Renegade-Master/zomboid-dedicated-server
- https://github.com/Renegade-Master/zomboid-dedicated-server/blob/main/README.md
- https://hub.docker.com/r/renegademaster/zomboid-dedicated-server
- https://github.com/cyrale/project-zomboid
- https://hub.docker.com/r/afey/zomboid
- https://github.com/ich777/docker-steamcmd-server
- https://github.com/ich777/docker-steamcmd-server/tree/projectzomboid
- https://hub.docker.com/r/m4lagon/project-zomboid-server
- https://github.com/indifferentbroccoli/projectzomboid-server-docker
- https://github.com/0xjemm/pz-panel
- https://github.com/GameServerManagers/LinuxGSM
- https://linuxgsm.com/servers/pzserver/
- https://github.com/GameServerManagers/LinuxGSM/blob/master/lgsm/config-default/config-lgsm/pzserver/_default.cfg
- https://github.com/nicholi/pz_scripts
- https://github.com/Dyarven/zomboid-server-on-arm
- https://blog.sergeantbiggs.net/posts/project-zomboid-or-taming-misbehaving-services-with-systemd/
- https://shattered.io/project-zomboid-dedicated-server/
- https://pzwiki.net/wiki/Dedicated_server (403 to automated fetch; read manually)
- https://steamcommunity.com/sharedfiles/filedetails/?id=2821744058
- https://gist.github.com/jamiemtdwyer/e504cd817b97e6d64c574531bb203f18
- https://wabbanode.com/help/project-zomboid/how-to-configure-server-backups-on-your-project-zomboid-server
- https://connecthosting.net/help/games/project-zomboid/project-zomboid-backups-and-saves
- https://supercraft.host/wiki/project-zomboid/backup_player_data/
- https://pingplayers.com/knowledgebase/project-zomboid/how-to-back-up-your-server-data-and-restore-it-to-a-server
- https://github.com/bingops-com/pz-server
- https://blog.bingops.com/blog/project-zomboid/
- https://medium.com/@bingops/deploying-a-project-zomboid-server-with-terraform-ansible-c27312be0db5
- https://github.com/hectorfaria/pz-server
