# Project Zomboid Build 42 Dedicated Server on Linux — Research (as of September 3, 2026)

## 1. SteamCMD app ID, branch, current version, MP status

- **Dedicated server SteamCMD App ID: `380870`** (confirmed on pzwiki and on pimylifeup). The client game's Steam App ID is `108600` (this shows up in `steam_appid.txt` troubleshooting and in Workshop content paths). Source: [pzwiki Dedicated server](https://pzwiki.net/wiki/Dedicated_server), [pimylifeup](https://pimylifeup.com/project-zomboid-dedicated-server-linux/).
- **No beta flag is needed for Build 42 anymore.** Build 42 (version **42.20**) became the **default public Stable branch on Wednesday, July 29, 2026**, replacing Build 41 as what you get with a plain `app_update 380870 validate` (no `-beta`). Source: [BUILD 42 STABLE PLANS (2026-07-24)](https://projectzomboid.com/blog/news/2026/07/build-42-stable-plans/), [PROJECT ZOMBOID BUILD 42.20 RELEASED! (2026-07-29)](https://projectzomboid.com/blog/news/2026/07/project-zomboid-build-42-20-released/).
- If you specifically want to **stay on Build 41** (e.g., an existing B41 server/community), opt into the beta branch named **`legacy41`**:
  ```
  app_update 380870 -beta legacy41 validate
  ```
  (Steam UI: right-click → Properties → "Game Versions & Betas" → select `legacy41`.) Source: [pzwiki Dedicated server – Running Legacy Builds](https://pzwiki.net/wiki/Dedicated_server), [42.20 release blog](https://projectzomboid.com/blog/news/2026/07/project-zomboid-build-42-20-released/).
- If you want to finish an in-progress **Unstable 42.19** save (incompatible with 42.20 due to new map content), opt into beta `42.19`. Source: same 42.20 release blog.
- **IWBUMS / unstable branch still exists** for pre-release testing of the *next* patch beyond stable (e.g., testing 42.20.x or a future 42.21). As of Aug 18, 2026 both Stable and IWBUMS sat at the same version, 42.20.3; by early September the current stable point release is **42.20.4** (per pzwiki page revision banners, fetched 2026-09-03) and legacy pzwiki content that hadn't been refreshed still referenced 42.17.0. No password is required for either the default stable branch or the IWBUMS beta (public betas). Source: [pzfans — Project Zomboid Latest Version](https://pzfans.com/ProjectZomboidLatestVersion/), [pzwiki Startup parameters](https://pzwiki.net/wiki/Startup_parameters), [pzwiki Java](https://pzwiki.net/wiki/Java) (revision banner shows 42.20.4 current stable, page current as of 42.20.0).
- **Current B42 version number: 42.20.4** (latest stable point release referenced on pzwiki as of Sept 3, 2026; the big content update was 42.20 released July 29, 2026, followed by 42.20.1 and 42.20.4 patches). Source: [pzwiki Dedicated server](https://pzwiki.net/wiki/Dedicated_server) ("This page has been revised for the current stable version (42.20.0)... Parts of this page may have been automatically updated to the latest build (42.20.4)"), [pzwiki Java](https://pzwiki.net/wiki/Java).
- **MP release timeline / stability:**
  - Multiplayer for Build 42 first shipped for public stress-testing on the **unstable** branch in update **42.13**, **December 11, 2025**.
  - It moved to the **stable** branch with **42.20** on **July 29, 2026** — players/hosts no longer need any beta opt-in to get B42 multiplayer.
  - **Known MP issues** reported by the community: crouch-related desync (one player freezes on others' screens while moving fine locally; zombies aggro on them become unhittable), a chunk-boundary desync bug that made zombies "teleport" across loaded-chunk boundaries (addressed), and zombie culling problems in MP (the 42.20 patch notes explicitly call out fixes to "Zombie culling in MP", plus fixes to character spawns, controllers, meat yield from butcher hooks, and vehicle towing). The dev team (The Indie Stone) has explicitly stated "continued multiplayer and controller improvement" will keep happening throughout the B42 support/patch cycle — i.e., **MP in B42 stable is playable but still actively being hardened, not considered fully mature**.
  Sources: [Shockbyte — B42 Multiplayer](https://shockbyte.com/en-gb/blog/project-zomboid-build-42-multiplayer), [HostedGG — B42 MP status mid-2026](https://hostedgg.com/blog/project-zomboid-build-42-multiplayer-status), [BUILD 42 STABLE PLANS](https://projectzomboid.com/blog/news/2026/07/build-42-stable-plans/) (lists MP/culling fixes), [Steam Bug Reports — "BUILD 42 MULTIPLAYER - INSANE DESYNC"](https://steamcommunity.com/app/108600/discussions/6/691996029262886646/), [supercraft.host stability guide](https://supercraft.host/wiki/project-zomboid/pz_b42_mp_patch_stability_guide/).

## 2. SteamCMD install, directory layout, start script, JVM heap, Java requirement

### Install (Debian/Ubuntu)

```bash
# steamcmd prerequisites
sudo add-apt-repository multiverse
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install steamcmd -y
# (may also need) sudo apt-get install software-properties-common -y && sudo apt-add-repository non-free

# dedicated, non-root user
sudo adduser pzuser
sudo mkdir /opt/pzserver
sudo chown pzuser:pzuser /opt/pzserver
sudo -u pzuser -i

# scripted install/update file
cat >$HOME/update_zomboid.txt <<'EOL'
@ShutdownOnFailedCommand 1
@NoPromptForPassword 1
force_install_dir /opt/pzserver/
login anonymous
app_update 380870 validate
quit
EOL

export PATH=$PATH:/usr/games
steamcmd +runscript $HOME/update_zomboid.txt
```

Re-run the same `steamcmd +runscript $HOME/update_zomboid.txt` command any time you want to update the server. Source: [pzwiki Dedicated server — Through SteamCMD / Linux](https://pzwiki.net/wiki/Dedicated_server).

### Directory layout

- **Server install/binaries** (the SteamCMD `force_install_dir` target, e.g. `/opt/pzserver/`), containing (among others):
  - `start-server.sh` — the Linux launch script.
  - `java/` — server-side classpath jars, including `projectzomboid.jar`.
  - `jre64/` — the **bundled JRE** (no separate Java install required).
  - `ProjectZomboid64.json` — launcher config that carries the JVM classpath and (per the pzwiki Java page) certain JVM flags such as `--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED`.
  - `steam_appid.txt` — should contain only `108600`; stale files here cause the "Assertion Failed: Illegal termination of worker thread" startup error after upgrading from a B41 install on the same box.
  If installed via the Steam client instead of SteamCMD, default path on Windows is `C:\Program Files (x86)\Steam\steamapps\common\Project Zomboid Dedicated Server`; on Linux via the Steam client it would be under `~/.steam/steam/steamapps/common/Project Zomboid Dedicated Server/`.
- **Runtime data / user config** (separate from the install dir), by default at `~/Zomboid` for whichever OS user runs the server (e.g. `/home/pzuser/Zomboid` if you followed the SteamCMD-as-`pzuser` setup above). This is where `Server/`, `Saves/`, `mods/`, `Workshop/`, `logs/`, `db/`, `Sandbox Presets/`, etc. live (see section 5). This location can be overridden — see `-cachedir` below.
Source: [pzwiki Dedicated server](https://pzwiki.net/wiki/Dedicated_server), [pzwiki Java](https://pzwiki.net/wiki/Java), [pzwiki Mod structure](https://pzwiki.net/wiki/Mod_structure).

### Running the server

```bash
tmux                      # keep server alive across SSH disconnects
cd /opt/pzserver/
bash start-server.sh                       # normal run
bash start-server.sh -nosteam              # non-Steam server (e.g. for GOG players)
bash start-server.sh -servername SERVERNAME   # custom server/save name
```
Source: [pzwiki Dedicated server — Running the server / Linux](https://pzwiki.net/wiki/Dedicated_server).

### Startup / game flags (from `pzwiki.net/wiki/Startup_parameters`, page marked as written against 42.17.0 but cross-checked against the current 42.20.4 stable; flag names below are the exact documented ones)

Client & server:
- `-cachedir={path}` — sets the absolute path for the game/server's cache (data) directory, i.e., relocates the `~/Zomboid`-equivalent folder. Example: `-cachedir="/home/pzuser/zomboid_data"`.
- `-console_dot_txt_size_kb={int}` — max size of `console.txt` in KB.
- `-nosteam` — disable Steam integration (equivalent to `-Dzomboid.steam=0`/unset).

Server-specific:
- `-adminusername {name}` — sets a different name for the default admin user created on first run.
- `-adminpassword {pass}` — **sets the default admin's password non-interactively**, bypassing the interactive password prompt if the default admin account doesn't exist yet. This is the documented way to automate first-run setup / systemd.
- `-ip {ip}` — force-bind the server to a specific IP.
- `-port {int}` — overrides `DefaultPort` from the INI (default 16261).
- `-udpport {int}` — overrides `UDPPort` from the INI (default 16262).
- `-steamvac {true|false}` — enable/disable Valve Anti-Cheat, overriding the INI's `SteamVAC` setting.
- `-servername {name}` — sets which save/INI set is loaded (`SERVERNAME.ini`, `SERVERNAME_SandboxVars.lua`, etc., and the `Saves/Multiplayer/SERVERNAME` folder).
- `-statistic {seconds}` — enables MP statistics monitoring, written under `cachedir/Statistic`.
- `-coop` — run a co-op (not fully "dedicated") server; disables default admin.
- `-gui` — (documented as unfinished/buggy, uses extra memory) launches a server GUI.
- `-disablelog=` / `-debuglog=` — enable/disable `DebugType` console log filters.

JVM args (must precede game args and be separated with `--` **only** when passed via Steam launch options / a shortcut; the `start-server.sh`/`.bat` scripts already separate them so `--` is not needed there):
- `-Xms{size}{g|m}` / `-Xmx{size}{g|m}` — min/max JVM heap. **This is where you set server memory**, directly in `start-server.sh` (Linux) or `StartServer64.bat` (Windows), on the java invocation line. Windows default in the .bat is 16 GB and **must be edited down/up** or the server fails to start with a memory error if the machine can't satisfy `-Xms`. Recommendation from the wiki: generally don't set `-Xms` at all, only `-Xmx`, since a heap that can't reach the requested minimum simply refuses to boot.
- `-XX:+AlwaysPreTouch` — recommended alongside ZGC as of Java 21 to pre-fault heap pages.
- `-Dzomboid.steam={0|1}` — toggle Steam API integration.
- `-Ddeployment.user.cachedir={path}` — Linux-only equivalent of `-cachedir`.
- `-Dzomboid.ConsoleDotTxtSizeKB={int}`.

Source: [pzwiki Startup parameters](https://pzwiki.net/wiki/Startup_parameters).

### Heap size recommendations

- The wiki itself doesn't publish a per-player-count table, but examples given are 6–16 GB for the stock scripts (Windows `StartServer64.bat` ships with `-Xms16g -Xmx16g` by default; a 6 GB example is also shown "equivalent to Server Memory when using Host").
- Community hosting-guide consensus for **Build 42** (heavier than B41):
  - **8 players**: ~8 GB heap is treated as the practical minimum for a small-to-medium group; base engine footprint alone is roughly 6 GB.
  - **16 players**: **12–16 GB** recommended.
  - Rule of thumb cited: ~500 MB extra heap per connected player on top of the ~6 GB base; heavily modded servers should budget several GB more.
  - Because the server is Java-based, it will not use more RAM than `-Xmx` allows regardless of how much physical RAM the box has — an unedited/low `-Xmx` will crash the server even with RAM to spare.
  Sources: [pinehosting — B42 RAM & server requirements](https://pinehosting.com/blog/project-zomboid-build-42-server-requirements-ram-cpu-hosting/), [pinehosting — how much RAM for B42](https://pinehosting.com/blog/how-much-ram-do-you-need-for-build-42-project-zomboid-server-hosting/), [supercraft.host — B42 requirements](https://supercraft.host/wiki/project-zomboid/project_zomboid_build_42_server_hosting/), [pzwiki Startup parameters](https://pzwiki.net/wiki/Startup_parameters).

### Java requirement

- The dedicated server (like the client) **bundles its own JRE** in the `jre64/` folder — no separate system Java install is required to *run* it.
- As of **Build 42.13.0**, Project Zomboid runs on **Java 25** (specifically reported as Oracle GraalVM `25.0.3+9.1`, an LTS release). A JDK matching this version (25) is only needed if you're compiling Java-level mods (`javac`), not for running the server.
Source: [pzwiki Java](https://pzwiki.net/wiki/Java) ("As of Build 42.13.0, Project Zomboid runs on Java 25... Use JDK 25."), corroborated by web search on bundled `jre64` java version.

## 3. Ports and RCON

- **Game/UDP ports (unchanged in B42):**
  - **16261/UDP** — `DefaultPort`, the main player-data port; must be forwarded on router/firewall.
  - **16262/UDP** — `UDPPort`, the "Direct Connection Port".
  - These are the two ports the current pzwiki "Dedicated server" page (revised for 42.20.0) lists as the ones required to be open — it does **not** list separate Steam query ports (e.g., the historically-cited 8766/8767) as required; those legacy Steam master-server ports are not mentioned on the current stable-version page. Flag this as the one place where older tutorials (some third-party hosting blogs) may still reference 8766/8767 UDP from Build 41-era guidance without it being re-confirmed for B42 on the primary wiki page.
  - Multiple instances on one box each need **their own pair of UDP ports** (example given: second instance uses 16274/16275), edited per-instance in each instance's `SERVERNAME.ini`.
  - Linux firewall (ufw) example:
    ```bash
    sudo ufw allow 16261/udp
    sudo ufw allow 16262/udp
    sudo ufw reload
    ```
  Source: [pzwiki Dedicated server — Forwarding required ports](https://pzwiki.net/wiki/Dedicated_server), [pzwiki Server settings](https://pzwiki.net/wiki/Server_settings) (`DefaultPort=16261`, `UDPPort=16262`).
- **RCON:**
  - INI keys: `RCONPort=27015` (default), `RCONPassword=` (must be set to a strong password to use RCON at all).
  - RCON uses the **Source RCON protocol** (TCP) on that port.
  - Recommended Linux CLI client: **`mcrcon`** — usage pattern: `mcrcon -H <ip> -P 27015 -p <RCONPassword> "<command>"` (e.g., `players`, `save`, `servermsg`, `quit`). A generic `rcon` client binary is also commonly used (as shown in the pimylifeup systemd walkthrough) for exactly the same purpose — issuing `save` then `quit` on `ExecStop`.
  - Security note repeated across sources: keep RCON's TCP port firewalled to admin IPs only, never expose 0.0.0.0.
  Source: [pzwiki Server settings](https://pzwiki.net/wiki/Server_settings) (`RCONPort`, `RCONPassword` fields), [RCON for Project Zomboid gist](https://gist.github.com/jamiemtdwyer/e504cd817b97e6d64c574531bb203f18), [XGamingServer RCON docs](https://xgamingserver.com/docs/project-zomboid/rcon), [pimylifeup guide](https://pimylifeup.com/project-zomboid-dedicated-server-linux/).

## 4. Hardware requirements (B42, community reports)

- **CPU:** Single-thread clock speed matters more than core count — zombie AI pathing for large hordes (reports cite 10,000+ active zombie paths) is largely single-threaded. Guidance: a modern 4-core CPU at 3 GHz+ is enough for a small server; for 16+ players prioritize a high boost clock (4.5+ GHz cited).
- **RAM:** See heap guidance above — 8 GB minimum-practical for a small group, **12–16 GB recommended for 8–16 players** in B42 specifically, plus more for heavy modlists. Multiple hosting-guide sources explicitly frame **B42 as heavier on RAM/CPU than B41** due to expanded systems (deeper crafting/building, animal husbandry, lighting/atmosphere overhaul, larger/denser map content), though none of the sources found gave hard published minimum-spec numbers from The Indie Stone itself for the dedicated server — this is community-guide consensus, not an official spec sheet.
- **Storage:** 50+ GB on NVMe SSD recommended; `/Saves` and the server's internal `db/` files can grow large on long-running or big-map/heavily-modded servers.
Sources: [pinehosting — B42 requirements](https://pinehosting.com/blog/project-zomboid-build-42-server-requirements-ram-cpu-hosting/), [pinehosting — B42 optimization guide](https://pinehosting.com/blog/how-to-improve-project-zomboid-build-42-server-performance/), [supercraft.host — B42 requirements](https://supercraft.host/wiki/project-zomboid/project_zomboid_build_42_server_hosting/), [dedicatedgameservers.net — B42 RAM reality](https://dedicatedgameservers.net/articles/project-zomboid-dedicated-server-requirements-2026/).
**Uncertainty flag:** these are third-party hosting-provider blog estimates (some may be lightly SEO-oriented), not a number published directly by The Indie Stone; treat as directional, not authoritative.

## 5. File/path layout

All under the runtime cache dir, default **`~/Zomboid`** for the OS user running the server (i.e., **not** the SteamCMD install directory) — e.g. `/home/pzuser/Zomboid` in the SteamCMD-as-`pzuser` setup:

- `~/Zomboid/Server/servertest.ini` — main server config (non-gameplay settings, ports, RCON, mods, etc.). ("servertest" is the default server name; changes with `-servername`.)
- `~/Zomboid/Server/servertest_SandboxVars.lua` — sandbox/gameplay config (loot abundance, zombie settings, etc.).
- `~/Zomboid/Server/servertest_spawnpoints.lua` — custom spawn points.
- `~/Zomboid/Server/servertest_spawnregions.lua` — spawn regions (Muldraugh, Rosewood, etc.).
- `~/Zomboid/Saves/Multiplayer/servertest/` — the actual generated/saved world data.
- `~/Zomboid/mods/` — manually-installed (non-Workshop) mods.
- `~/Zomboid/Workshop/` — mod-development / Workshop-upload staging folder (not the same as downloaded Workshop content).
- `~/Zomboid/logs/` — server/game logs; `~/Zomboid/console.txt` also exists at the cache-dir root.
- `~/Zomboid/db/` — per-server player database files, named after the server name.
- `~/Zomboid/Crafting/`, `~/Zomboid/joypads/`, `~/Zomboid/Lua/`, `~/Zomboid/messaging/`, `~/Zomboid/Recording/`, `~/Zomboid/Sandbox Presets/` — other cache-folder subfolders.
- Downloaded Steam Workshop mod content itself lives **outside** `~/Zomboid`, under the SteamCMD/Steam library path `steamapps/workshop/content/108600/<WorkshopID>/mods/<ModName>/mod.info` (folder named by Workshop ID).
- **`-cachedir={path}`** (or `-Ddeployment.user.cachedir={path}` on Linux) relocates the entire `~/Zomboid`-equivalent tree (Server/, Saves/, mods/, Workshop/, logs/, db/, etc.) to an arbitrary path — useful for running the server as a system service without depending on a real user's `$HOME`, or for running multiple isolated instances under one OS user.
- On Windows the equivalent root is `%USERPROFILE%\Zomboid` (or `C:\Users\<name>\Zomboid`), with the same `Server\`, `Saves\Multiplayer\`, etc. subfolders.
Sources: [pzwiki Dedicated server — Configuring the server game settings](https://pzwiki.net/wiki/Dedicated_server), [pzwiki Server settings](https://pzwiki.net/wiki/Server_settings), [pzwiki Mod structure — cache folder layout](https://pzwiki.net/wiki/Mod_structure), [pzwiki Startup parameters — `-cachedir`](https://pzwiki.net/wiki/Startup_parameters).

## 6. Mods in Build 42

### INI keys
- `Mods=` — semicolon-free? **No** — actually the wiki's own field description just says "Enter the mod loading ID here. It can be found in `\Steam\steamapps\workshop\modID\mods\modName\info.txt`" without stating a delimiter on the Server-settings page itself, but every practical guide and the WorkshopItems example show **semicolon-separated** IDs for both keys, e.g. `Mods=ModID1;ModID2`.
- `WorkshopItems=` — semicolon-separated numeric **Workshop IDs** the server should fetch via SteamCMD, e.g. `WorkshopItems=514427485;513111049`. This is explicitly documented on the Server settings page: "List Workshop Mod IDs for the server to download. Each must be separated by a semicolon."
- **`Mods=` (the mod's internal Mod ID from its `mod.info`) and `WorkshopItems=` (the numeric Steam Workshop item ID) are two different identifiers and both are normally needed**: `WorkshopItems` makes SteamCMD download the content; `Mods` tells the game engine which mod IDs to actually activate/load. This Mod-ID-vs-Workshop-ID confusion is called out repeatedly as the single most common mod-setup mistake.
- Recommended workflow: put all mods into one Steam Workshop **collection**, then use a "PZ ID Grabber" tool (e.g. pzidgrabber.com) against the collection URL to generate both the `Mods=` and `WorkshopItems=` lines at once.

### Build 42-specific mod ID/folder format
- Build 42 introduced a **versioned mod folder structure**: instead of B41's flat `Contents/mods/<ModName>/{media,mod.info}`, a B42 mod folder is `Contents/mods/<ModName>/{common/, 42/ (or 42.X, 42.X.Y version folders)}`, each containing its own `media/` and `mod.info`. The engine loads the **common** folder first, then the **closest matching version folder** for the running build (e.g. a `42.1.5` folder is treated as `42.1`; folders don't support minor-version granularity beyond `build.major`). At least one common or versioning folder is required or the mod isn't recognized at all.
- **Backslash-prefixed Mod IDs**: community tooling (e.g. WinterNode's Mod ID Grabber) initially output Build 42 `Mods=` entries with a **leading backslash per ID**, i.e. `Mods=\ModNameA;\ModNameB;\ModNameC`, reflecting an early-B42 requirement. However, **more recent Build 42 versions (current 42.20.x stable) no longer require the leading backslash** — plain semicolon-separated Mod IDs work as in B41. **Flag as uncertain / worth testing on your exact patch**: which exact 42.1x version dropped the backslash requirement was not pinned down precisely by the sources found; if mods silently fail to load on 42.20.x, try both forms.
- A single uploaded Workshop item ("mod folder") can contain **multiple mods** (multiple subfolders under `Contents/mods/`), e.g. for optional variants — each still needs its own `mod.info` in its `common/`/version folder.

### Auto-download behavior
- **Yes** — on server startup, the dedicated server automatically invokes its embedded SteamCMD-based downloader against every ID listed in `WorkshopItems=`, fetching/updating them straight from Steam Workshop with no manual `steamcmd +workshop_download_item` step required. First boot with a heavy modlist can take 5–15 minutes; subsequent boots only need to fetch deltas/updates. A manual/forced refresh outside the server is still possible via `steamcmd +login anonymous +workshop_download_item 108600 <id> validate +quit`.
- Downloaded workshop mod content replaces/updates files under the server's own `mods`/workshop cache area.

### Load order
- Mod load order is controlled by the **order in which Mod IDs are listed in `Mods=`** (this is unchanged from B41 practice; the wiki's dedicated `Load order` page — not separately fetched here — governs file-overwrite precedence between mods, later entries generally able to overwrite earlier ones' files depending on load position). The client-side `-modfolders {workshop,steam,mods}` startup parameter additionally controls which of the three physical mod source folders (workshop-subscribed / Steam Workshop-downloaded-serverside / manually-installed `mods`) are consulted and in what order, letting you disable or reorder entire sources.

### Common pitfalls (aggregated from hosting guides + wiki)
1. **Mod ID vs Workshop ID confusion** — putting the Workshop numeric ID into `Mods=` (or vice versa) silently fails to load the mod.
2. **Client/server mod mismatch** — every mod (and matching version) enabled server-side via `Mods=`/`WorkshopItems=` must also be present/subscribed on the client, or the client can't connect / desyncs. `DoLuaChecksum=true` (INI) is meant to kick clients whose files don't match the server's, but the wiki flags a known **Linux-specific bug causing false-positive kicks**, forcing many Linux server owners to set `DoLuaChecksum=false` as a workaround (at the cost of that security check).
3. **Version mismatches** — a mod built only for one B42 sub-version (via its versioned folder) may not have a version folder matching the server's exact build, causing it to not load or fall back unexpectedly; mod authors are advised to maintain a `common/` folder for shared assets and add new version folders only when a game update breaks compatibility.
4. **Backslash-prefix inconsistency** described above between early and current B42 tooling/builds.
5. Two copies of the same Mod ID in different locally-recognized folders (`mods/` vs `Workshop/` vs Steam Workshop download cache) **clash and overwrite each other**, causing confusing "my changes aren't appearing" bugs — relevant mainly to people also developing mods on the same box as they host.
Sources: [pzwiki Server settings](https://pzwiki.net/wiki/Server_settings), [pzwiki Dedicated server — Installing mods](https://pzwiki.net/wiki/Dedicated_server), [pzwiki Mod structure](https://pzwiki.net/wiki/Mod_structure), [pzwiki Startup parameters — `-modfolders`](https://pzwiki.net/wiki/Startup_parameters), [WinterNode Mod ID Grabber](https://winternode.com/tools/project-zomboid/mod-id-grabber), [pzfans — Add mods B41 & B42.19](https://pzfans.com/how-to-add-mods-to-project-zomboid-server/), [doomhosting — installing mods B42](https://www.doomhosting.com/help/articles/how-to-install-mods-project-zomboid-server-build-42), [nodecraft — download & enable workshop mods](https://nodecraft.com/support/games/project-zomboid/how-to-download-and-enable-workshop-mods-on-your-project-zomboid-server).

## 7. First-run gotchas, non-interactive setup, systemd, graceful shutdown

- **First run always prompts interactively** for a password for the auto-created default `admin` account, both on Windows and Linux, whether launched via `.bat`/`start-server.sh` directly.
- **Non-interactive setup**: pass **`-adminpassword {pass}`** (optionally with `-adminusername {name}`) as a game argument to `start-server.sh`/`StartServer64.bat` — this sets the admin password automatically and bypasses the prompt **only if the default admin user doesn't already exist**; it does not remove/reset a pre-existing admin account. Example (Windows .bat style shown on wiki, same flag applies via `bash start-server.sh -adminpassword ... -adminusername ...` on Linux):
  ```
  %1 %2 -nosteam -servername MySecondServer -adminpassword Password123
  ```
- **`-Duser.home`**: shown in a wiki example (`-Xmx16g -Duser.home=C:\Zomboid`) as a JVM property that can redirect where the game/server treats "home" for config resolution on Windows; the more universally-documented, cross-platform way to relocate all data is `-cachedir`/`-Ddeployment.user.cachedir` (Linux) as covered in section 5 — prefer that over `-Duser.home` for portability.
- **Non-root execution**: every official/community guide has the server run as a dedicated **unprivileged Linux user** (`pzuser`/`zomboid`), created with `adduser`, with the install directory owned by that user; SteamCMD, the update script, and `start-server.sh` are all run as that user (`sudo -u pzuser -i`), never as root.
- **systemd**: The Indie Stone devs **explicitly discourage** running under systemd because (as of the linked forum thread) the dedicated server does **not cleanly handle SIGTERM**, and there's no absolute guarantee of a clean save on that signal alone — but they provide a workaround using a FIFO socket:
  ```ini
  # /etc/systemd/system/zomboid.service
  [Unit]
  Description=Project Zomboid Server
  After=network.target

  [Service]
  PrivateTmp=true
  Type=simple
  User=pzuser
  WorkingDirectory=/opt/pzserver/
  ExecStart=/bin/sh -c "exec /opt/pzserver/start-server.sh </opt/pzserver/zomboid.control"
  ExecStop=/bin/sh -c "echo save > /opt/pzserver/zomboid.control; sleep 15; echo quit > /opt/pzserver/zomboid.control"
  Sockets=zomboid.socket
  KillSignal=SIGCONT

  [Install]
  WantedBy=multi-user.target
  ```
  ```ini
  # /etc/systemd/system/zomboid.socket
  [Unit]
  BindsTo=zomboid.service

  [Socket]
  ListenFIFO=/opt/pzserver/zomboid.control
  FileDescriptorName=control
  RemoveOnStop=true
  SocketMode=0660
  SocketUser=pzuser
  ```
  Usage: `systemctl start zomboid.socket` / `systemctl stop zomboid` / `systemctl restart zomboid` / `systemctl status zomboid`; logs via `journalctl -u zomboid -f`; send arbitrary console commands with `echo "command" > /opt/pzserver/zomboid.control` (or via `sudo tee` if you need elevation). **Precondition**: you must manually start the server once first to set the admin password (or use `-adminpassword` baked into `start-server.sh`) before wiring up the service, and must not still be logged in as `pzuser` when running the `systemctl`/root-level setup commands.
  An alternative pattern seen in a separate community guide (pimylifeup, pre-B42 but same mechanism) uses an installed `rcon`/`mcrcon` binary in `ExecStop` to send `save` then `quit` over RCON instead of the FIFO trick — functionally equivalent, just via RCON instead of stdin.
- **Graceful shutdown** (either interactively at the console, via the systemd FIFO, or via RCON) is always **`save`** followed by **`quit`** — never `Ctrl+C` / `kill`, which can corrupt or lose recent world-state saves. This is called out identically across the wiki systemd section and third-party guides.
- **Config changes require a restart** (or, for the specific case of `servertest.ini`, an in-place edit can be applied live with **`reloadoptions`** run as an admin command, without a full restart) — the wiki explicitly notes: "Changes can be saved to `servertest.ini` while the server is running. After `servertest.ini` is saved, use admin command `reloadoptions` to make the changes live." Sandbox vars / spawn regions / spawn points, by contrast, are generally only picked up at next server start (not documented as hot-reloadable). Settings can be verified live with the admin command `showoptions`.
Sources: [pzwiki Dedicated server](https://pzwiki.net/wiki/Dedicated_server) (Systemd section, "Do not launch via Steam" note, first-run password note, `reloadoptions`/`showoptions` note), [pzwiki Startup parameters](https://pzwiki.net/wiki/Startup_parameters) (`-adminpassword`, `-adminusername`, `-Duser.home` example), [pimylifeup guide](https://pimylifeup.com/project-zomboid-dedicated-server-linux/) (rcon-based ExecStop alternative), [forum thread the wiki cites on SIGTERM handling](https://theindiestone.com/forums/index.php?/topic/63563-4178-multiplayer-zomboid-dedicated-server-does-not-handle-sigterm/#comment-376957).

## Summary of explicit uncertainty flags

1. **8766/8767 Steam query ports** — not confirmed as currently required on the up-to-date (42.20.0-revised) pzwiki Dedicated-server page, which lists only 16261/16262 UDP. Older/third-party guides may still reference them from Build 41 era; treat as unconfirmed for B42 unless you hit connectivity issues specifically related to the Steam server browser.
2. **Exact hardware minimums (CPU/RAM/disk) for B42 at 8 vs 16 players** are community hosting-provider estimates, not an official Indie Stone spec sheet.
3. **Whether `Mods=` IDs still need a leading backslash (`\ModName`)** in the very latest 42.20.x — sources say this requirement existed early in B42 and has since been dropped, but the exact version boundary wasn't pinned down; test on your exact patch.
4. **Exact current IWBUMS/unstable point version** at the moment of writing wasn't independently re-confirmed beyond "42.20.3 as of Aug 18, 2026" / "42.20.4 current stable per pzwiki" — by the time you read this it may have advanced further; always check `pzwiki.net/wiki/Dedicated_server`'s revision banner or the in-game "Game Versions & Betas" list for the live number.
