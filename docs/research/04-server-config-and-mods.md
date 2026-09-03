# Project Zomboid Build 42 Dedicated Server Configuration — Research Notes
Compiled 2026-09-03. Primary source: PZwiki (fetched via r.jina.ai reader proxy because pzwiki.net returns HTTP 403 to direct curl/WebFetch from this environment — Cloudflare is blocking the datacenter IP). All pzwiki pages below were captured at PZwiki's "current stable" revision marker of **Build 42.20.0 / 42.20.4** (stable branch went live 29 July 2026; wiki pages explicitly say they were revised for 42.20.0 and some content "may have been automatically updated to the latest build 42.20.4").

**Sources used (re-read these for later implementation):**
- https://pzwiki.net/wiki/Server_settings — full servertest.ini + servertest_SandboxVars.lua + servertest_spawnregions.lua + servertest_spawnpoints.lua reference. THE key page.
- https://pzwiki.net/wiki/Dedicated_server — install, run, admin, mods overview, troubleshooting.
- https://pzwiki.net/wiki/Admin_commands — full admin command table.
- https://pzwiki.net/wiki/Mod.info — mod.info file format/fields.
- https://pzwiki.net/wiki/Mod_structure — mod folder layout, common/versioning (`42/`) folders, Workshop vs mods folder.
- https://pzwiki.net/wiki/Workshop_ID — what Workshop ID is / where to find it; also carries the B42.20.1/42.20.4 changelog blurbs (security fix removing `loadstring`).
- https://pzwiki.net/wiki/Load_order — load order rules for mods.
- https://pzwiki.net/wiki/Sandbox_options — (modder-facing page on how sandbox options are registered/translated; not a settings reference, of secondary use here).
- https://pzwiki.net/wiki/Startup_parameters — server launch flags (fetched, see note below).
- Steam Workshop pages (steamcommunity.com/sharedfiles/filedetails/?id=...) for individual mod verification.
- WinterNode, Connect Hosting, XGamingServer, Supercraft Host, PZFans blog posts — used only for cross-checking/triangulating claims already sourced from pzwiki; not treated as authoritative on their own.

**Access note for implementer:** pzwiki.net blocks this sandbox's outbound IP (403 from curl and from the WebFetch tool). Fetching succeeded via `https://r.jina.ai/https://pzwiki.net/wiki/<PageName>` (a read-only proxy that renders the page to markdown). If that proxy is unavailable later, try a different UA/IP, a search-engine cache, or ask the user to fetch directly from a residential connection.

---

## 0. The four config files and where they live

Per https://pzwiki.net/wiki/Server_settings and https://pzwiki.net/wiki/Dedicated_server:

- Windows: `%USERPROFILE%\Zomboid\Server\`
- Linux: `$HOME/Zomboid/Server/`

Files inside (assuming default server name `servertest`, set via `-servername` launch flag otherwise):
- `servertest.ini` — non-gameplay server settings (network, mods, PVP toggle, backups, RCON, chat, anti-cheat, Discord…).
- `servertest_SandboxVars.lua` — gameplay/world sandbox settings (zombies, loot, weather, XP…).
- `servertest_spawnpoints.lua` — custom per-occupation spawn point coordinates.
- `servertest_spawnregions.lua` — which named regions/towns appear on the character-creation spawn screen.

World save data lives separately in `Zomboid/Saves/Multiplayer/<servername>/`.

**Editing workflow (per pzwiki + corroborated by hosting-provider docs):**
- You can edit `servertest.ini` while the server is running, but changes only take effect after either restarting the server or running the admin command `/reloadoptions` (which "reloads server options (ServerOptions.ini) and sends to clients"). Settings can be verified live with `/showoptions`.
- Sandbox vars / spawn files: no confirmed live-reload path in the pzwiki text — treat these as requiring a server restart. (Uncertain — pzwiki doesn't explicitly say sandbox vars support hot-reload; the safer, commonly recommended approach from hosting guides is: **stop the server, edit, start the server**.)
- Changing `Mods=`/`WorkshopItems=` requires a restart to take effect (mods are loaded at server boot). It does **not** by itself require a fresh save/wipe, EXCEPT: removing a mod that added map tiles/items already placed in the save, or removing a mod whose items exist in players' inventories, can corrupt/break that save. Adding pure Lua/UI QoL mods to an existing save is normally safe.
- The in-game "Host → Manage Settings" editor (or the dedicated Server-Settings UI) **does persist to the .ini/.lua files** — pzwiki: "Select servertest from the list of saved server settings → Edit Settings → Edit desired settings and save. The next time the server successfully starts it will use the defined servertest.ini and lua files." This is the recommended way to generate/regenerate `servertest_SandboxVars.lua` cleanly (host locally once, tweak in the UI, then copy the resulting `.lua`/`.ini` files to the dedicated server).

---

## 1. `servertest.ini` — server settings

Below is the reference dump pulled verbatim from https://pzwiki.net/wiki/Server_settings (Build 42.20.x), organized by topic. Where the user's question named a key that does **not** appear on the current pzwiki page, I've flagged it explicitly as "not found / possibly renamed or removed."

### Core identity / listing
| Key | Default | Meaning |
|---|---|---|
| `PublicName` | `My PZ Server` | Name shown in in-game/Steam server browser |
| `PublicDescription` | (empty) | Description shown in the public browser; typing creates a new line |
| `Public` | `false` | Whether the server is listed in the in-game browser. Note: Steam-enabled servers are **always** visible in the Steam server browser regardless of this flag |
| `Password` | (empty) | Join password for clients. **Ignored when hosting via the in-game "Host" button** |
| `MaxPlayers` | `32` | Max concurrent players (admins excluded from count). Min 1 / Max 100. Wiki warns: "Server player counts above 32 will potentially result in poor map streaming and desync" — for a private 8–16 player server this is a non-issue |
| `Open` | (not explicitly in the dumped defaults, but documented) | Clients may join without a pre-existing whitelist account. If `false`, admins must `/adduser` every account manually |
| `PVP` | `true` | Players can hurt/kill each other |
| `SafetySystem` | `true` | Players individually toggle PVP mode on/off per-player (skull icon). If `false`, PVP applies to everyone unconditionally when `PVP=true` |
| `ShowSafety` | `true` | Show skull icon over players in PVP mode |
| `SafetyToggleTimer` | `2` (sec) | Time to enter/leave PVP mode. Min 0 / Max 1000 |
| `SafetyCooldownTimer` | `3` (sec) | Cooldown before re-toggling PVP. Min 0 / Max 1000 |
| `SafetyDisconnectDelay` | `60` | Min 0 / Max 60 |
| `PauseEmpty` | `true` | Game time stops when no players are online |
| `GlobalChat` | `true` | Toggles global chat on/off |
| `ChatStreams` | `s,r,a,w,y,sh,f,all` | Enabled chat channels: `/s` local, `/r` radio transcript, `/a` admin, `/w` whisper, `/y` yell, `/sh` safehouse, `/f` faction, `/all` global. Removing any disables that stream |
| `ServerWelcomeMessage` | `Welcome to Project Zomboid Multiplayer!` | First chat message on login. Supports RGB color codes (`<RGB:1,0,0>`) and `<LINE>` (no space) for line breaks |

### Networking / ports
| Key | Default | Meaning |
|---|---|---|
| `DefaultPort` | `16261` | Main port. Must be forwarded on router/firewall. Min 0 / Max 65535 |
| `UDPPort` | `16262` | Second UDP port (direct-connection port). Min 0 / Max 65535 |
| `UPnP` | `true` | Attempts automatic port-forwarding via UPnP; falls back to default ports on failure |
| `RCONPort` | `27015` | RCON port. Min 0 / Max 65535. (Note: several third-party hosting blogs claim "game port + 1"/16262 as the RCON port default — that does **not** match the pzwiki-documented default of `27015`; trust the pzwiki value, flagged here because of the discrepancy) |
| `RCONPassword` | (empty) | RCON password — set a strong one |
| `PingLimit` | `0` | Kick players above this ping in ms; 0 = disabled. Min 0 / Max 2147483647 |
| `MaxPacketsPerSecond` | `300` | Per-client packet processing cap. Min 100 / Max 1000 |
| `server_browser_announced_ip` | (empty) | Override broadcast IP (multi-IP/server-farm setups) |
| `SpeedLimit` | `70.0` | (vehicle) Min 10 / Max 150 |

Required open ports per https://pzwiki.net/wiki/Dedicated_server: **16261/UDP** and **16262/UDP**.

### Whitelist / accounts / login
| Key | Default | Meaning |
|---|---|---|
| `Open` | see above | `true`: anyone can create an account by connecting. `false`: admin must whitelist via `/adduser "username" "password"` first |
| `MaxAccountsPerUser` | `0` | Cap on accounts per Steam user; 0 = unlimited. Ignored via Host button |
| `DropOffWhiteListAfterDeath` | `false` | Removes the account from the whitelist after death — forces a new `/adduser` per life on `Open=false` servers |
| `AllowCoop` | `true` | Allow co-op/splitscreen players |
| `AllowNonAsciiUsername` | `false` | Allow Cyrillic etc. in usernames |
| `LoginQueueEnabled` | `false` | Enable a login queue |
| `LoginQueueConnectTimeout` | `60` | Min 20 / Max 1200 |
| `DenyLoginOnOverloadedServer` | `true` | Refuse logins when server is overloaded |
| `ServerPlayerID` / `ResetID` | blank / `8564414` (example seen; wiki text elsewhere shows default `863866116`) | Used to detect soft-resets — if these don't match what the client has stored, the client is forced to create a new character. **Back these up if you ever need to preserve characters across a server rebuild** |
| `AutoCreateUserInWhiteList` | **Not found on the current pzwiki Server_settings page** | Uncertain — this key appeared in older Build 41 community docs; it does not appear in the current 42.20 dump. Treat as possibly removed/renamed in B42; verify directly in a freshly generated `servertest.ini` before relying on it |

### Discord / webhook integration
| Key | Default | Meaning |
|---|---|---|
| `DiscordEnable` | `false` | Enables chat bridge to Discord |
| `DiscordToken` | (empty) | Bot token |
| `DiscordChatChannel` | (empty) | Discord channel name for chat relay |
| `DiscordLogChannel` | (empty) | Discord channel name for server logs |
| `DiscordCommandChannel` | (empty) | Discord channel name for remote commands |
| `WebhookAddress` | (empty) | Slack incoming-webhook URL (yes — this ini also supports a Slack webhook, separate from Discord) |

**Correction vs. the task prompt:** there is no single `DiscordChannel` key — B42's ini splits it into `DiscordChatChannel`, `DiscordLogChannel`, `DiscordCommandChannel`.

### Mods / Workshop / Map
| Key | Default | Meaning |
|---|---|---|
| `Mods` | (empty) | Semicolon-separated list of **Mod IDs** (from each mod's `mod.info`). In Build 42 each ID must be prefixed with a backslash: `Mods=\ModA;\ModB` (per community tooling; see §4) |
| `WorkshopItems` | (empty) | Semicolon-separated list of numeric **Workshop IDs** to auto-subscribe/download server-side, e.g. `WorkshopItems=514427485;513111049` |
| `Map` | `Muldraugh, KY` | Map folder name (as found under a mod's `media/maps/<MapName>/`); semicolon-list supported for multi-map servers per general PZ convention |

### Safehouses
| Key | Default | Meaning |
|---|---|---|
| `PlayerSafehouse` | `false` | Both admins and players can claim safehouses |
| `AdminSafehouse` | `false` | Only admins can claim |
| `SafehouseAllowTrepass` | `true` | Allow non-members to enter without invite |
| `SafehouseAllowFire` | `true` | Fire can damage safehouses |
| `SafehouseAllowLoot` | `true` | Non-members can loot safehouses |
| `SafehouseAllowRespawn` | `false` | Respawn in a previously-claimed safehouse |
| `SafehouseDaySurvivedToClaim` | `0` | In-game days survived before claiming allowed |
| `SafeHouseRemovalTime` | `144` (real hours) | Auto-removed from safehouse after this many real-world hours absent |
| `SafehouseAllowNonResidential` | `false` | Allow claiming non-residential buildings |
| `SafehouseDisableDisguises` | (present, default not captured in fetch) | disables disguises in safehouse context |
| `MaxSafezoneSize` | `20000` | |
| `SafehousePreventsLootRespawn` | `true` | Items won't respawn in claimed-safehouse buildings |
| `DisableSafehouseWhenOwnerConnected` | `false` | Safehouse loses protection while the owner is online |

### Sleep / stealth / misc gameplay toggles
| Key | Default | Meaning |
|---|---|---|
| `SleepAllowed` | `false` | Players CAN sleep (optional) |
| `SleepNeeded` | `false` | Players get tired and MUST sleep (ignored if `SleepAllowed=false`) |
| `KnockedDownAllowed` | `false` | Marked WIP by pzwiki: "may cause visual desynchronization of player positions" |
| `SneakModeHideFromOtherPlayers` | `true` | |
| `MouseOverToSeeDisplayName` | `true` | Requires mouse-over to see other players' display names |
| `DisplayUserName` | `true` | Show usernames over heads |
| `ShowFirstAndLastName` | `false` | Show character's first/last name over head |
| `UsernameDisguises` / `HideDisguisedUserName` | `false` / `false` | Disguise-related display toggles |
| `SwitchZombiesOwnershipEachUpdate` | `false` | |
| `SpawnPoint` | `0,0,0` | Force every new player to spawn at fixed world x,y,z. Ignored when `0,0,0` |
| `SpawnItems` | (empty) | Comma-separated item types new players spawn with, e.g. `Base.Axe,Base.Bag_BigHikingBag` |
| `HidePlayersBehindYou` | `true` | Auto-hides players occluded behind you, like zombies |
| `PlayerBumpPlayer` | `false` | Whether running through another player bumps/knocks them |
| `MapRemotePlayerVisibility` | `1` | 1=Hidden, 2=Friends, 3=Friends+nearby, 4=Everyone (min1/max4) |

### Saves / backups
| Key | Default | Meaning |
|---|---|---|
| `SaveWorldEveryMinutes` | `0` | Force-save loaded map areas after N real minutes (0 = only saves on player-leave-area as usual) |
| `BackupsCount` | `5` | Number of rolling backups kept. Min 1 / Max 300 |
| `BackupsOnStart` | `true` | Backup taken on server start |
| `BackupsOnVersionChange` | `true` | Backup taken when the game version changes |
| `BackupsPeriod` | `0` | Periodic backup interval (units per wiki table, min0/max1500) |

### Anti-cheat (`AntiCheat*`)
Current B42 naming is by **rule name**, not a numbered `AntiCheatProtectionTypeX` scheme: `AntiCheatSafety`, `AntiCheatSpeed`, `AntiCheatNoClip`, `AntiCheatHit`, `AntiCheatPacketException`, `AntiCheatPermission`, `AntiCheatXP`, `AntiCheatSafeHouse`, `AntiCheatPlayer`, `AntiCheatChecksum`. Each takes a numeric mode: `1=Ban, 2=Kick, 3=Log, 4=Disable`. Example defaults observed: `AntiCheatSafety=2`, `AntiCheatSpeed=2`, `AntiCheatNoClip=4`, `AntiCheatHit=2`, `AntiCheatPacketException=4`, `AntiCheatPermission=2`, `AntiCheatXP=2`, `AntiCheatSafeHouse=2`, `AntiCheatPlayer=2`, `AntiCheatChecksum=2`.
(This is likely the B42 evolution of the older B41 `AntiCheatProtectionType1..N=true/false` flags the task prompt referenced — flagged as **naming changed**, could not confirm the exact old→new mapping from the fetched page.)

### Chat / moderation / logging
| Key | Default | Meaning |
|---|---|---|
| `ClientCommandFilter` | `-vehicle.*;+vehicle.damageWindow;+vehicle.fixPart;+vehicle.installPart;+vehicle.uninstallPart` | Controls what's written to `cmd.txt` |
| `ClientActionLogs` | `ISEnterVehicle;ISExitVehicle;ISTakeEngineParts;` | Actions logged to `ClientActionLogs.txt` |
| `PerkLogs` | `true` | Logs perk-level changes to `PerkLog.txt` |
| `BadWordListFile` / `GoodWordListFile` | empty | Paths to profanity block/allow lists (one word per line) |
| `BadWordPolicy` | `3` | `1=ban, 2=kick, 3=record violation, 4=mute` |
| `BadWordReplacement` | `[HIDDEN]` | |
| `ChatMessageCharacterLimit` | `200` | Min 64 / Max 1024 |
| `ChatMessageSlowModeTime` | `3` | Min 1 / Max 30 |
| `ShowCoordinates` | `false` | Shows player coordinates on-screen |
| `DisableScoreboard` | `false` | |
| `HideAdminsInPlayerList` | `false` | |
| `SteamScoreboard` | `false` | Show Steam usernames/avatars in the players list |
| `SteamVAC` | `true` | Enable Steam VAC |
| `DoLuaChecksum` | `true` | Kicks clients whose files don't match the server. **pzwiki warning:** has a known Linux-server bug causing false positives that block valid clients — many Linux server owners set this `false` despite the security tradeoff |

### Voice / radio
| Key | Default | Meaning |
|---|---|---|
| `VoiceEnable` | `true` | |
| `VoiceMinDistance` | `10.0` | Min 0 / Max 100000 |
| `VoiceMaxDistance` | `100.0` | Min 0 / Max 100000 |
| `Voice3D` | `true` | Directional VOIP |
| `DisableRadioStaff` / `DisableRadioAdmin` / `DisableRadioGM` / `DisableRadioOverseer` / `DisableRadioModerator` / `DisableRadioInvisible` | `false/true/true/false/false/true` | Disable radio transmission per access-level group |

### Faction
| Key | Default | Meaning |
|---|---|---|
| `Faction` | `true` | Enable factions |
| `FactionDaySurvivedToCreate` | `0` | |
| `FactionPlayersRequiredForTag` | `1` | |

### PVP damage / combat tuning
`PVPLogToolChat=true`, `PVPLogToolFile=true` (both log PVP events — to admin chat / to a server log file respectively), `PVPMeleeWhileHitReaction=false`, `PVPMeleeDamageModifier=30.0` (min0/max500), `PVPFirearmDamageModifier=50.0` (min0/max500).

### Misc server behavior
`NoFire=false` (disables all fire except campfires), `AnnounceDeath=false`, `AnnounceAnimalDeath=false`, `War`/`WarStartDelay=600`/`WarDuration=3600`/`WarSafehouseHitPoints=3` (a "server war" event system), `TrashDeleteAll=false`, `ItemNumbersLimitPerContainer=0`, `BloodSplatLifespanDays=0`, `RemovePlayerCorpsesOnCorpseRemoval=false`, `BanKickGlobalSound=true`, `CarEngineAttractionModifier=0.5`, `DisableVehicleTowing`/`DisableTrailerTowing`/`DisableBurntTowing=false`, `UltraSpeedDoesnotAffectToAnimals=false`, `AllowDestructionBySledgehammer=true`, `SledgehammerOnlyInSafehouse=false`, `PlayerRespawnWithSelf=false`, `PlayerRespawnWithOther=false`, `FastForwardMultiplier=40.0` (sleep time-skip speed), `Seed=<worldgen seed>` (change only alongside deleting `map_worldgen.bin`), `MultiplayerStatisticsPeriod=1`, `UsePhysicsHitReaction=false`.

Keys named in the task prompt that I could **not** find on the current pzwiki page (flag as uncertain / possibly outdated or B41-only): `ServerImage`, `AutoCreateUserInWhiteList`. Recommend verifying against a freshly generated `servertest.ini` (launch the server once with no pre-existing ini, or use the in-game "Create New Settings" flow) rather than assuming they still exist.

### Recommended values for a private 8–16 player friends server
(my own synthesis, not a direct quote)
- `Open=false` + manually `/adduser` each friend, or `Open=true` if you trust the invite link isn't leaked and rely on `Password=`.
- `MaxPlayers=16` (or a little above for headroom), well under the 32-desync warning threshold.
- `Public=false` (keeps it off the browser; friends connect via direct IP/Steam invite).
- `PVP=true` + `SafetySystem=true` if you want optional/opt-in PvP, or `PVP=false` for a pure co-op survival server.
- `PauseEmpty=true` so the world doesn't decay while everyone's offline.
- `SaveWorldEveryMinutes=15–30` and `BackupsCount≥7`, `BackupsOnStart=true`, `BackupsOnVersionChange=true` for safety on a small friend group's single shared world.
- `DoLuaChecksum=true` unless running Linux and hitting the known false-positive bug.
- Set a strong `RCONPassword` even for a friends server if you plan to use RCON tools/bots.

---

## 2. `servertest_SandboxVars.lua`

Source: https://pzwiki.net/wiki/Server_settings ("Sandbox Variables Lua" section — full Lua dump with inline `--` comments giving min/max/default and enum meanings for every option). Structure:

```lua
SandboxVars = {
  VERSION = 6,
  Zombies = 4,              -- population multiplier: 1 Insane .. 6 None (default 4 = Normal)
  Distribution = 1,         -- 1 Urban Focused / 2 Uniform
  ZombieVoronoiNoise = true,
  ZombieRespawn = 4,        -- 1 High .. 4 None (default None)
  ZombieMigrate = true,
  DayLength = 4,            -- 1=15min .. 27=Real-time (default "1hr30")
  StartYear = 1, StartMonth = 7, StartDay = 9, StartTime = 2,  -- default July 9, ~9AM
  DayNightCycle = 1, ClimateCycle = 1, FogCycle = 1,
  WaterShut = 2, ElecShut = 2, AlarmDecay = 2,                 -- + *Modifier variants (days, default 14)
  -- ~20 loot-category multipliers: FoodLootNew, LiteratureLootNew, SkillBookLoot,
  -- MedicalLootNew, WeaponLootNew, RangedWeaponLootNew, AmmoLootNew, ClothingLootNew,
  -- ContainerLootNew, KeyLootNew, MementoLootNew, CookwareLootNew, MaterialLootNew,
  -- FarmingLootNew, ToolLootNew, etc. (0.00-4.00 each)
  RollsMultiplier = 1.0,     -- loot table roll count, "highly recommended not be changed"
  InsaneLootFactor/ExtremeLootFactor/RareLootFactor/NormalLootFactor/CommonLootFactor/AbundantLootFactor,
  Temperature = 3, Rain = 3, ErosionSpeed = 4, Farming = 3, CompostTime = 2,
  StatsDecrease = 3, NatureAbundance = 3, Alarm = 4, LockedHouses = 6,
  StarterKit = false, Nutrition = true, FoodRotSpeed = 3, FridgeFactor = 3,
  HoursForLootRespawn = 0, MaxItemsForLootRespawn = 5, ConstructionPreventsLootRespawn = true,
  SeenHoursPreventLootRespawn = 0, WorldItemRemovalList = "Base.Hat, ...", HoursForWorldItemRemoval = 24.0,
  Helicopter = 2,           -- 1 Never .. 4 Often (default "Once")
  MetaEvent = 2, SleepingEvent = 1,
  GeneratorFuelConsumption = 0.1, GeneratorSpawning = 4,
  CharacterFreePoints = 0, ConstructionBonusPoints = 3,
  NightDarkness = 3, NightLength = 3,
  BoneFracture = true, InjurySeverity = 2,
  HoursForCorpseRemoval = 216.0, DecayingCorpseHealthImpact = 3, ZombieHealthImpact = false,
  BloodLevel = 3, ClothingDegradation = 3, FireSpread = true,
  EnableVehicles = true, CarSpawnRate = 3, ZombieAttractionMultiplier = 1.0,
  VehicleEasyUse = false, InitialGas = 2, FuelStationGasInfinite = false,
  Basement = { SpawnFrequency = 4 },                -- NEW in B42: basement generation frequency
  Map = { AllowMiniMap=false, AllowWorldMap=true, MapAllKnown=false, MapNeedsLight=true },
  ZombieLore = {
    Speed = 4,          -- 1 Sprinters / 2 Fast Shamblers / 3 Shamblers / 4 Random
    SprinterPercentage = 0,
    Strength = 2,       -- 1 Superhuman / 2 Normal / 3 Weak / 4 Random
    Toughness = 4,      -- 1 Tough / 2 Normal / 3 Fragile / 4 Random
    Transmission = 1, Mortality = 5, Reanimate = 3,
    Cognition = 3,      -- 1 Navigate+Doors / 2 Navigate / 3 Basic Navigation / 4 Random
    DoorOpeningPercentage = 0,
    CrawlUnderVehicle = 5,
    Memory = 2,         -- 1 Long / 2 Normal / 3 Short / 4 None / 5 Random / 6 Random(Normal-None)
    Sight = 5, Hearing = 5,           -- both default "Random between Normal and Poor"
    SpottedLogic = true,              -- advanced stealth mechanics (hide behind cars etc.)
    ThumpNoChasing = false, ThumpOnConstruction = true,
    ActiveOnly = 1, TriggerHouseAlarm = true,
    -- Rally/grouping (real zombie group formation):
    RallyGroupSize = 20, RallyGroupSizeVariance = 50, RallyTravelDistance = 20,
    RallyGroupSeparation = 15, RallyGroupRadius = 3,
    ZombiesCountBeforeDelete = 300,   -- perf-critical, "strongly recommended" not to raise/disable
  },
  MultiplierConfig = {
    Global = 1.0, GlobalToggle = true,   -- master XP multiplier switch
    Fitness = 1.0, Strength = 1.0, Sprinting = 1.0, ... Husbandry = 1.0, Tracking = 1.0,
    Blacksmith = 1.0, Butchering = 1.0, Glassmaking = 1.0,
    -- one multiplier per skill, ~30 entries total, 0.00-1000.00 each
  },
}
```

### B42-specific additions confirmed on this page
- **`Basement = { SpawnFrequency }`** — a whole new sub-table controlling how often basements generate (1 Never .. 7 Always). Basements are a new B42 map feature.
- **`ZombieLore.SpottedLogic`** — new "advanced stealth" system (hiding behind cars, weather/traits factored into detection).
- **`ZombieLore` "Rally" group fields** (`RallyGroupSize`, `RallyGroupSizeVariance`, `RallyTravelDistance`, `RallyGroupSeparation`, `RallyGroupRadius`, `ZombiesCountBeforeDelete`) — B42's rewritten zombie-grouping/culling system for performance.
- **`MultiplierConfig.Husbandry`** — XP multiplier for the new **Animal Care** skill (animal husbandry is a new B42 system: farm animals, breeding, milking/wool per `AnimalMilkIncModifier`/`AnimalWoolIncModifier` etc. in the loot/animal section of the same file — see `AnimalStatsModifier`, `AnimalMetaStatsModifier`, `AnimalPregnancyTime`, `AnimalAgeModifier`, `AnimalRanchChance`, `AnimalGrassRegrowTime`, `AnimalMetaPredator`, `AnimalMatingSeason`, `AnimalEggHatch`, `AnimalSoundAttractZombies`, `AnimalTrackChance`, `AnimalPathChance`).
- **`MultiplierConfig.Fitness`** — XP multiplier for the new **Fitness** skill (separate from Strength).
- New loot-category granularity (SurvivalGears, Cookware, Material, Farming, Tool, Media, Memento categories) reflecting B42's reworked, more granular loot-container system.
- I did **not** find an explicit "sadistic AI director" toggle by that name on this page — the closest analogues are `MetaEvent` (zombie-attracting metagame events like gunshots) and `SleepingEvent` (sleep-time events/nightmares), plus `Helicopter`. If a literal "Sadistic" setting exists it wasn't present in this dump — flag as unconfirmed, possibly a modded/renamed concept rather than vanilla B42.

### How to generate/edit this file
Per §0 above: use in-game **Host → Manage Settings → Create New Settings / Edit Settings**, tune sandbox values in the UI, save, then either run the dedicated server directly against those files or copy the resulting `Zomboid/Server/<name>_SandboxVars.lua` to the dedicated box. Comments in the file (as dumped above) already document min/max/default/enum meaning per field, so hand-editing is also practical — restart the server after changes.

---

## 3. `servertest_spawnregions.lua` and `servertest_spawnpoints.lua`

Source: https://pzwiki.net/wiki/Server_settings (bottom sections) — this is the authoritative, current format.

### `servertest_spawnregions.lua`
```lua
function SpawnRegions()
return {
{ name = "Brandenburg, KY", file = "media/maps/Brandenburg, KY/spawnpoints.lua" },
{ name = "Echo Creek, KY", file = "media/maps/Echo Creek, KY/spawnpoints.lua" },
{ name = "Ekron, KY", file = "media/maps/Ekron, KY/spawnpoints.lua" },
{ name = "Fallas Lake, KY", file = "media/maps/Fallas Lake, KY/spawnpoints.lua" },
{ name = "Irvington, KY", file = "media/maps/Irvington, KY/spawnpoints.lua" },
{ name = "March Ridge, KY", file = "media/maps/March Ridge, KY/spawnpoints.lua" },
{ name = "Muldraugh, KY", file = "media/maps/Muldraugh, KY/spawnpoints.lua" },
{ name = "Riverside, KY", file = "media/maps/Riverside, KY/spawnpoints.lua" },
{ name = "Rosewood, KY", file = "media/maps/Rosewood, KY/spawnpoints.lua" },
{ name = "Valley Station, KY", file = "media/maps/Valley Station, KY/spawnpoints.lua" },
{ name = "West Point, KY", file = "media/maps/West Point, KY/spawnpoints.lua" },
}
end
```
- By default, **only Muldraugh, Riverside, Rosewood, and West Point are active in Multiplayer** (the others are listed but not enabled by default — pzwiki is explicit about this).
- To add a custom spawn region (e.g. a map mod's town), add a line: `{ name = "Mod Spawn", file = "media/maps/ModName/spawnpoints.lua" },` inside the returned table, pointing at that map's own `spawnpoints.lua`.
- A common third-party pattern (per XGamingServer/Supercraft docs, not pzwiki) is to instead point at a `serverfile` (a custom lua sitting next to the ini) for a bespoke spawn point rather than a map's own file, e.g. `{ name = "Twiggy's Bar", serverfile = "servertest_spawnpoints.lua" }` — treat this `serverfile` key as a community convention to verify against your actual server build rather than a directly pzwiki-confirmed field, since the primary page only showed the `file=` form.

### `servertest_spawnpoints.lua`
```lua
function SpawnPoints()
return {
unemployed = {
{ worldX = 40, worldY = 22, posX = 67, posY = 201 }
}
}
end
```
- Used to add extra spawn points **for a given occupation** without needing a whole Spawn Region.
- `worldX`/`worldY` = the map **Cell** coordinates; `posX`/`posY` = the **Rel(ative)** in-cell tile coordinates. These are typically read off a map tool (the community commonly uses map coordinate viewers/tools like pzmap.crash-override.net or similar cell/rel viewers — not an official pzwiki tool, flagged as third-party).
- Occupation keys correspond to the list at https://pzwiki.net/wiki/Occupation.
- Multiple points per occupation are supported:
```lua
blacksmith = {
  { worldX = 40, worldY = 22, posX = 67, posY = 201 },
  { worldX = 40, worldY = 22, posX = 10031, posY = 4432 }
}
```
- To force **every** player to one fixed point regardless of occupation, the simpler route is the `SpawnPoint=x,y,z` key in `servertest.ini` itself (ignored when `0,0,0`).

---

## 4. Adding mods

### Format in `servertest.ini`
```
Mods=\ModIDOne;\ModIDTwo;\ModIDThree
WorkshopItems=111111111;222222222;333333333
```
- Both lists are **semicolon-separated**.
- `WorkshopItems=` — numeric **Workshop IDs** (the number at the end of a Steam Workshop URL, `?id=NNNNNNNN`), telling Steam what to download.
- `Mods=` — text **Mod IDs**, the `id=` field from each mod's `mod.info` (pzwiki: "Enter the mod loading ID here. It can be found in \Steam\steamapps\workshop\modID\mods\modName\info.txt" — this phrasing on the dumped ini-comment text is legacy/imprecise; the authoritative modern location is `mod.info`'s `id=` field per https://pzwiki.net/wiki/Mod.info).
- **Build 42 specifically prefixes every Mod ID with a backslash** (`\ModID`) in the `Mods=` line — this convention is used by community tooling (e.g. WinterNode's "Mod ID Grabber") for B42 and differs from Build 41's unprefixed IDs. I could not find pzwiki's own servertest.ini dump using the backslash form (the dumped example on the wiki page doesn't show a live example with values), so **flag this as sourced from third-party tooling/community consensus, not a direct pzwiki quote** — verify empirically (a wrong prefix generally just fails to load that one mod silently or with a clear "not found" server log line, it's low-risk to test).
- **A single Workshop item can contain multiple Mod IDs** (sub-mods) — in that case `WorkshopItems=` will have fewer entries than `Mods=`. Hosting-guide folklore about "WorkshopItems and Mods list lengths must match" only holds when each Workshop item ships exactly one mod; it's not a hard engine rule.
- `Map=` also needs updating (semicolon list) if a mod adds a playable map/town, pointing at that mod's `media/maps/<FolderName>`.

### Where the two IDs come from
- **Workshop ID**: number in the Steam Workshop page URL, e.g. `.../filedetails/?id=3750253491` → `3750253491`. (https://pzwiki.net/wiki/Workshop_ID)
- **Mod ID**: the `id=` line inside that mod's `mod.info` file (https://pzwiki.net/wiki/Mod.info) — e.g. `id=myAmazingModID`. If you can't access the mod's files directly, most well-documented Workshop pages print their Mod ID(s) in the description; third-party "Mod ID Grabber" tools (e.g. WinterNode's, pzidgrabber.com per pzwiki's own dedicated-server install-mods steps) scrape a Workshop collection URL and output ready-to-paste `Mods=`/`WorkshopItems=` lines.

### Build 42 mod folder specifics (`mod.info` location)
Per https://pzwiki.net/wiki/Mod_structure, Build 42 introduced **common + versioning folders** inside a mod, replacing B41's flatter layout:
- `common/` — large static assets (textures, models, animations) shared across game versions.
- Versioning folders — named after the game build they target, e.g. **`42/`**, `42.1/`, `42.12/`, etc. — contain code and, importantly, **`mod.info`** itself, since `mod.info` often needs to change per game version. Naming rules: `42` → treated as `42.0`; `42.1.5` → treated as `42.1` (minor version not distinguished); the game picks the **closest versioning folder ≤ current game version**, whose contents overwrite same-named files from `common/`.
- At least one versioning-folder or the common folder must exist for the mod to be recognized at all.
- `common/` is **not recognized by Build 41** — a mod using only the new B42 layout won't load on a B41 server.
- Sub-mods: a single Workshop item's `Contents/mods/` folder can contain multiple independent mod folders (`MyMod1/`, `MyMod2/`), each with its own `mod.info`/ID — this is the "single Workshop ID → multiple Mod IDs" case referenced above. I did not find pzwiki using a literal backslash (`\`) syntax for sub-mods in server config; the backslash-per-ID convention referenced above (in `Mods=`) is a separate, unrelated thing (per-entry ID prefix), not a sub-mod path separator — don't conflate the two.

### Load order
Per https://pzwiki.net/wiki/Load_order: **load order rarely matters** in practice. It only matters when two mods (a) share the same map cell, or (b) override the exact same vanilla/file path. Pure Lua/script mods almost never clash if they use unique relative file paths. Practical guidance: check for shared map cells with tools like "Map Mod Manager" / "PZ Map Analyser" (community tools, linked from that wiki page) if combining multiple map mods; otherwise don't over-think ordering.

### Restart / wipe requirements
- A `Mods=`/`WorkshopItems=` change requires a **server restart** to take effect (mods load at boot).
- It does **not** inherently require wiping the save. Risk of save corruption/breakage is specific to: removing a map mod whose cells are already generated in your save, removing a mod that added items/recipes currently held by players, or major version-incompatible updates to a mod already used in-world. Pure QoL/UI mods are safe to add/remove on an existing save in the vast majority of cases.

### 4 verified Build-42-compatible example mods (Workshop ID / Mod ID), checked directly on Steam Workshop 2026-09-03
| Mod (Workshop page name) | Workshop ID | Mod ID (from mod.info / page) | B42 status quoted from the page |
|---|---|---|---|
| Common Sense [B42.20+] | 3750253491 | `VB_CommonSense` | "FOR SINGLE PLAYER IT WORKS FLAWLESSLY IN B42.20 STABLE"; multiplayer "mostly works" with acknowledged issues |
| Inventory Tetris - Grid Based Inventory Overhaul [B42 Stable MP Patch] | 3688186430 | `INVENTORY_TETRIS` | Unofficial compatibility patch adding MP support, "updated for Build 42 Stable (42.20)" |
| True Music B42 | 3397198968 | `truemusic` | "quick fixes for B42... until the Original Mod by iBrRus gets updated to B42"; tagged Build 42 |
| Brita's B42 Armor Pack | 3777418909 | `BritasArmorPackB42` | Explicit B42 port of Brita's Armor Pack |

Caveat: the B42 mod ecosystem is in heavy flux post-42.20-stable (29 July 2026) — many mods exist as multiple competing community forks/patches/ports (I saw 5+ parallel "Brita's Armor" B42 ports alone). **Always re-check the specific Workshop page's own compatibility notes/changelog at install time**, not just this list, since a mod that was B42-compatible in August may have a newer official or unofficial successor by the time this is implemented.

---

## 5. Admin operations

Source: https://pzwiki.net/wiki/Admin_commands (full table) + https://pzwiki.net/wiki/Dedicated_server.

- Commands are run either directly in the server console (no leading slash) or in-game chat with a leading `/`, and require admin access (except a few, like `/help`).
- **Whitelist / accounts**: `/adduser "username" "password"` — pzwiki: "Use this command to add a new user to a whitelisted server." Only meaningful when `Open=false`; with `Open=true` players self-register on first connect. `/removeuserfromwhitelist "username"` removes one. `/setpassword "username" "newpassword"` resets a user's password.
- **Access levels**: `/setaccesslevel "username" "accesslevel"` — pzwiki: "Current levels: user, priority, observer, gm, moderator, admin". Example: `/setaccesslevel "rj" "moderator"`.
- **World control**: `/save` ("Save the current world"), `/quit` ("Save and quit the server"), `/reloadoptions` (reload `servertest.ini` and push to clients — use after saving ini edits while server is live), `/reloadlua "filename"` / `/reloadalllua` (hot-reload Lua), `/showoptions` (dump current live server options), `/changeoption optionName "newValue"` (change one setting live, presumably persisted the same way as the in-game editor — not explicitly confirmed as ini-persistent by the wiki text, treat with caution and verify with `/showoptions` + inspecting the ini afterward).
- **Messaging**: `/servermsg "My Message"` — broadcast to all connected players.
- **Moderation**: `/kickuser` is documented under the table key `kick`: *"Kick a user. Add a -r \"reason\" to specify a reason for the kick. Use: /kickuser \"username\" -r \"reason\"."* (Note: the table's row key is literally `kick` but the usage example it gives uses `/kickuser` — both likely work; treat `/kickuser` as the safe form to use.) `/banuser "username" -ip -r "reason"` bans a user (optionally their IP, optionally with a logged reason); `/unbanuser "username"` reverses it. IP/SteamID-level equivalents also exist: `/banip`, `/unbanip`, `/banid` (SteamID), `/unbanid`. `/voiceban "username" -true|-false` mutes VOIP for a user.
- **Other useful admin commands surfaced in the table**: `/players` (list connected), `/teleport`/`/teleportto`/`/teleportplayer`, `/godmode`/`/invisible`/`/noclip` (self or targeted, debug/moderation tools), `/createhorde`, `/addvehicle`, `/additem`, `/addxp`, `/log` (set per-subsystem log verbosity), `/worldgen start|recheck|stop|status`, `/stats` (server performance stats to file/console).
- **RCON**: `RCONPort` (default `27015` per pzwiki) / `RCONPassword` in `servertest.ini` enable remote command execution without being logged into the game or console. Any RCON-capable client (e.g. community tools like "ZomboidRCON", or generic Source-style RCON clients, or BattleMetrics if using their panel) can then run the same admin commands remotely. This is third-party-tool territory — pzwiki's own dedicated-server page doesn't detail RCON client setup, so treat the specific client recommendation as unverified/optional, but the ini keys themselves are pzwiki-confirmed.
- **Admin password / first admin account**: per pzwiki, on the server's very first successful launch it "will prompt you to set a password for the admin account it will create" — this is how you get your first admin. Resetting it later would presumably use `/setpassword "adminusername" "newpassword"` as an already-logged-in admin, or another admin using `/setaccesslevel`+`/setpassword` — pzwiki does not give an explicit "I'm locked out, how do I reset the admin password from scratch" recovery path; that would likely require directly editing the server's user database (`Zomboid/db/<servername>.db`) offline, which is unconfirmed/outside the fetched pages — flag as an open question if it comes up.
- **In-game server settings editor and persistence**: Confirmed by pzwiki (§0 above) — editing via Host → Manage Settings, or presumably an equivalent in-game admin settings panel, **does write back to `servertest.ini`/the sandbox lua files** on save, and takes effect on next server start (or immediately for ini values via `/reloadoptions` after the file's been resaved).

---

## 6. Common Build 42 multiplayer problems and fixes

Synthesized from PZFans, PineHosting, Supercraft Host, Lagzapper, and the pzwiki Dedicated-server troubleshooting section — cross-referenced, not all single-sourced from pzwiki, flagged accordingly.

1. **"Version mismatch" / "different version" on connect.**
   - Causes: Steam auto-updated the client before/after the server updated; client and server are on different Steam **branches** (e.g. one on `stable` 42.20.x, the other still on `unstable`/beta — this looks identical to a mod error); or the server simply hasn't been restarted after a Workshop mod auto-update.
   - Fix: confirm both client and server are on the same branch and build number; fully restart the client (exit Steam, relaunch, let Workshop finish updating) or restart the server, per whichever side the game's own error hints is outdated.

2. **Mod mismatch errors.**
   - Cause: the mod version on the server's Workshop cache differs from the client's, most commonly right after a modder pushes a Workshop update and the server hasn't re-downloaded/restarted yet.
   - Fix: restart the server after any subscribed Workshop mod updates (SteamCMD/dedicated server re-validates and pulls `WorkshopItems=` on each boot); make sure `Mods=` and `WorkshopItems=` are internally consistent (every Mod ID actually belongs to one of the listed Workshop IDs); don't assume a Build 41 mod will "just work" on a B42 server — many require an explicit B42 port (see §4's fork/port proliferation caveat).
   - `DoLuaChecksum=true` can also produce false "modified files"-style kicks on Linux servers specifically (pzwiki-confirmed bug) — disabling it is the documented (if security-reducing) workaround.

3. **Performance / desync at higher player counts.**
   - pzwiki itself flags MaxPlayers above 32 as risking "poor map streaming and desync" — for an 8–16 player server this ceiling isn't the concern, but general B42 MP performance advice from hosting blogs: keep `ZombiesCountBeforeDelete` at its default (300) rather than raising/disabling it (pzwiki: "may cause severe performance problems... reproduce with default setting before reporting"), keep `CarEngineAttractionModifier` low if zombie-swarming near roads causes lag, and ensure adequate server RAM (`-Xms`/`-Xmx` in the start script, since B42 moved much simulation, including inventory, server-side, increasing per-tick server CPU/memory load versus B41).

4. **Save corruption after an update.**
   - Multiple sources describe B42 unstable→stable transitions and mid-build patches occasionally corrupting saves (truncated cell/chunk files). Community tooling exists (a "Project Zomboid World Recovery" checker was mentioned) to detect which pre-update backup is still structurally intact.
   - **Backup/restore procedure**: stop the server completely before copying any files (a live server actively writing chunks will produce an inconsistent backup); back up the whole `Zomboid/Saves/Multiplayer/<servername>/` folder plus `Zomboid/Server/<servername>.ini` and `<servername>_SandboxVars.lua`; on restore, you can do a **partial** restore — restore only `players.db` to recover characters without touching the world; restore just the map/chunk files while keeping the current `players.db` to reset the world but keep character progress; or restore the `.ini`/`_SandboxVars.lua` alone to recover just server settings. Retaining at least ~7 days of rolling backups (`BackupsCount`) is recommended since a bad patch's damage is sometimes only discovered days later.

5. **"Assertion Failed: Illegal termination of worker thread" on server start.**
   - pzwiki-documented cause: a Build 41 dedicated server was previously run on the same machine and B42 server files were installed over/alongside it.
   - Fix (pzwiki): verify `steam_appid.txt` contains only `108600`; then, **after backing up any `.ini`/`.lua`/save files you want to keep**, delete the entire `Zomboid` user-data folder so it regenerates clean under B42.

6. **Character stuck in the void after joining.**
   - pzwiki cause: reusing a client profile that was previously used against an in-game "Host"-launched server.
   - Fix: disconnect, create a new local profile (change the account name in the Add-Server panel, e.g. `player` → `player_1`), save, reconnect — the new profile spawns normally.

---

## Open questions / things to double-check before implementing
- Exact `Mods=\ID` backslash-prefix requirement for B42 — sourced from third-party tooling, not a direct pzwiki quote with example values; verify empirically on the target server.
- Whether `AutoCreateUserInWhiteList` and `ServerImage` keys still exist anywhere in B42's `servertest.ini` — not present on the current pzwiki dump; check a freshly-generated ini.
- Exact old-B41-name → new-B42-name mapping for the `AntiCheatProtectionTypeX` family (now named by rule, e.g. `AntiCheatSafety`) — not explicitly documented as a migration on the fetched pages.
- No literal "sadistic AI director" sandbox toggle was found; closest are `MetaEvent`/`SleepingEvent`/`Helicopter`.
- RCON default port: pzwiki's own servertest.ini dump says `27015`; several third-party hosting blogs claim "game port +1" (16262) as the convention — go with the pzwiki-documented default (27015) unless the live server's own generated ini says otherwise.
- `/kickuser` vs `/kick` — the wiki's own table lists the row under key `kick` but gives a `/kickuser` usage example; both are referenced in the same table entry, so verify which is actually the live console command on your server (`/help kickuser` or `/help kick`).
- No explicit pzwiki text on an admin-password recovery/reset procedure when fully locked out (no existing admin) — would need separate investigation into the server's user database if this becomes a real need.
