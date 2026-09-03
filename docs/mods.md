# Mods

How to add, remove and debug Steam Workshop mods on this server. Everything here was verified
against Project Zomboid 42.20.4 on the pinned image.

## 1. Source of truth: `config/mods.txt`

Mods are never edited directly in `servertest.ini`. They are declared in `config/mods.txt`, one
line per Workshop item, and `scripts/render-config.sh` generates the `Mods=` and `WorkshopItems=`
keys from it.

```
# <workshop_id>  <mod_id>[; <mod_id>; ...]  # free-form comment
3171167894  damnlib                                     # a library other mods depend on
2719850086  CapacityLimitBypass; CustomizableBackpacks  # one item shipping two mods
3389606570  Jump Jump                                   # a Mod ID containing a space
```

- File order is load order: `Mods=` is built in the order the lines appear.
- The Mod ID field runs from after the Workshop ID to the `#` or the end of the line, so it may
  contain spaces.
- A Workshop item that ships several mods lists them on one line separated by `;`.
  `WorkshopItems=` gets the item once, `Mods=` gets every ID.
- Blank lines and `#` comments are ignored.

## 2. Getting the two identifiers

| Identifier | Where it comes from |
|---|---|
| **Workshop ID** (numeric) | The `?id=` parameter of the mod's Workshop URL |
| **Mod ID** (text) | The `id=` field of the mod's `mod.info`. Most Workshop pages publish it in the description as "Mod ID: …" |

In Build 42, `mod.info` is no longer at the root of the mod: it sits inside `common/` or inside a
version directory such as `42/` or `42.1/`, depending on how the author packaged it. Both
locations are valid. If the mod is already downloaded on the server, read the ID directly:

```bash
find data/workshop/content/108600 -name mod.info -exec grep -H '^id=' {} \;
```

A Workshop page's "Mod ID" line is occasionally wrong or out of date. The `mod.info` file is
authoritative.

## 3. Dependencies

Before adding a mod, open its `mod.info` and read the `require=` line. It is a comma-separated
list of Mod IDs that must be loaded before it. The Workshop description often does not mention
them, and a missing dependency usually shows up as the dependent mod silently failing to load —
or as the server refusing to start.

Typical dependency libraries in the Build 42 ecosystem are `damnlib`, `ModLoadOrderSorter_b42`
and `daneLibrary`. Each is a separate Workshop item that has to be added to `config/mods.txt` in
its own right, above the mods that need it.

To read the requirements of everything already downloaded:

```bash
grep -rh '^require=' data/workshop/content/108600 --include=mod.info | sort -u
```

Dependencies are transitive: a library may itself require another one. Resolve them until the
list closes.

### Two cases that cannot be resolved

**Manual-installation mods.** A `mod.info` containing `versionMin=100` (or any implausibly high
version floor) marks a mod its author does not intend to be loaded from the Workshop. The server
downloads the item, then never loads the mod. There is no server-side workaround; drop it from
the list. This happens with items that bundle an optional component alongside the main mod — for
example a capacity-limit patch shipped next to a backpack mod, where only the backpack loads.

**Dependencies removed from the Workshop.** If a required library has been taken down, the mod
that needs it cannot be installed at all: the Workshop ID no longer resolves and there is nothing
to download. Nothing on the server side fixes this. The only options are a fork of the library
that is still published, or dropping the mod.

## 4. Diagnosing a mod that does not load

Watch the log while the server starts:

```bash
make logs          # or: make remote-logs on a cloud VM
```

The two lines that matter:

```
Workshop: download 352656/352656 ID=3750253491     # the item was downloaded
LOG  : Mod          f:0 st:…> loading VB_CommonSense   # the mod was loaded
```

If the Workshop ID appears but no `loading <ModID>` line follows, the **Mod ID** is wrong, not the
Workshop ID: the files are on disk, but the server found no mod declaring that `id=`.

Missing dependencies and unresolvable IDs are reported as `not found`:

```bash
docker compose logs | grep 'not found'
```

Each hit names the Mod ID the engine could not resolve. Match it against the `require=` lines from
section 3: either the dependency is absent from `config/mods.txt`, or it is present but placed
after the mod that needs it.

## 5. The ini format and the `\` prefix

```ini
Mods=ModA;ModB
WorkshopItems=111111111;222222222
```

`WorkshopItems=` tells the server what to download; `Mods=` tells it what to load. Both are
`;`-separated.

Third-party documentation for early Build 42 stated that each Mod ID in `Mods=` required a
leading `\`. Both forms were tested on 42.20.4, with a full server start in each case, and both
load the mod identically. This repository uses the unprefixed form (`MOD_ID_PREFIX=` empty in
`.env`).

If a future version reintroduces the requirement, `config/mods.txt` does not need to change; set
the prefix in `.env`:

```sh
MOD_ID_PREFIX="\\"
```

The exact syntax matters. `.env` is parsed both by bash `source` and by Docker Compose's own
parser. `MOD_ID_PREFIX='\'` makes Compose fail with `unterminated quoted value`, and a bare
`MOD_ID_PREFIX=\` makes bash swallow the following line. Only the double-quoted, double-backslash
form works for both.

## 6. Load order

Load order rarely matters. It does when two mods overwrite the same file or the same map cell,
and it always matters for libraries, which must be loaded before their dependants. The effective
order is the order of `config/mods.txt`; keeping libraries in a block at the top of the file is
the simplest arrangement.

For map mods, check for overlapping cells before combining them.

## 7. Adding a mod

1. Confirm on the Workshop page that the mod targets Build 42. The ecosystem fragmented when
   Build 42 became stable, and many mods have parallel Build 41 and Build 42 versions.
2. Note the Workshop ID and the Mod ID.
3. Read `require=` and add any missing dependencies first (section 3).
4. Add the line to `config/mods.txt` at the position that gives the load order you want.
5. `make restart` locally, or `make sync RESTART=1` against a VM.
6. Verify in the log that the item downloaded and the mod loaded (section 4).

Clients download the mod automatically when they connect, provided Workshop downloads are enabled.

## 8. Removing a mod

1. Delete or comment out the line in `config/mods.txt`.
2. `make restart`.

Removing a mod from a world that already contains its content can corrupt the save: items in
player inventories and generated map cells stop resolving. It is safe for pure UI and
quality-of-life mods; it is risky for map mods whose cells have been generated and for content
mods whose items are in circulation. Take a backup first.

## 9. Mod updates

Workshop mods are re-downloaded every time the server starts. If an author publishes an update
while the server is running, clients end up with a different version from the server's and fail to
connect with a mismatch error. The fix is always a restart, which makes the server pick up the new
version.

## 10. Operational notes

- `SELF_MANAGED_MODS=1` is set in `docker-compose.yml`. Without it, the image's entrypoint blanks
  `Mods=` and `WorkshopItems=` in the ini on every start, because it sets those keys from its own
  `MOD_IDS` / `WORKSHOP_IDS` variables and writes an empty value when they are unset. The log
  confirms it is in effect: `*** INFO: SELF_MANAGED_MODS is set; leaving Mods and WorkshopItems
  untouched ***`.
- **Map mods.** If a mod ships `media/maps/<Map>`, the entrypoint rewrites the ini's `Map=` key
  and appends entries to `servertest_spawnregions.lua`. With no map mods installed it touches
  neither.
- Downloaded content lives in `data/workshop/content/108600/<workshop_id>/`. Deleting that
  directory forces a clean re-download on the next start.
