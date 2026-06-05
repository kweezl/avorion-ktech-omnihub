# modinfo.lua Field Reference

The `modinfo.lua` file must exist at the mod root (next to `data/`). It defines a global table named `meta` — no `return` statement.

## Complete field listing

```lua
meta = {
    -- ── Identity ─────────────────────────────────────────────────────────────
    id      = "MyModInternalId",   -- REQUIRED. Unique string ID. Letters, digits, hyphens only.
                                    -- The engine OVERWRITES this with the Steam Workshop ID on upload.
                                    -- Before publishing, use any unique string. After publishing,
                                    -- keep whatever the Workshop assigned (to avoid breaking existing saves).
    name    = "MyModInternalId",   -- Internal name used in Mods() listing. Typically same as id.
    version = "1.0.0",             -- REQUIRED. Semver "major.minor.patch" or "major.minor".
    type    = "mod",               -- "mod" (default) or "factionpack" (lore faction data only).

    -- ── Display ──────────────────────────────────────────────────────────────
    title       = "My Mod Title",
    description = "One or two paragraphs describing what the mod does.",
    authors     = { "YourName" },  -- table of strings
    contact     = "discord: yourhandle#0000",

    -- ── Scope flags ──────────────────────────────────────────────────────────
    serverSideOnly  = false,   -- If true: clients are notified the mod exists but don't download it.
                                -- Scripts attached to Player/Entity/Sector MUST be absent or
                                -- client-side behavior will break. Only safe for pure server logic.
    clientSideOnly  = false,   -- If true: mod is purely cosmetic/UI; server doesn't load it.
    saveGameAltering = true,   -- If true: warns player that removing the mod may break the save.
                                -- Set true whenever you add persistent data (secure/restore).

    -- ── Dependencies ─────────────────────────────────────────────────────────
    dependencies = {
        -- Always declare the Avorion version range your mod is tested against:
        { id = "Avorion", min = "2.0", max = "2.1" },

        -- Hard dependency with minimum version:
        { id = "SomeMod",          min = "1.2" },

        -- Hard dependency with exact version:
        { id = "AnotherMod",       exact = "3.0" },   -- sugar for min = max = "3.0"

        -- Optional dependency (loads if present, not required):
        { id = "NiceToHave",       min = "0.5", optional = true },

        -- Incompatible mod (player is warned; both cannot be active):
        { id = "ConflictingMod",   incompatible = true },

        -- Incompatible at a specific version only:
        { id = "ProblematicMod",   exact = "2.0", incompatible = true },
    },
}
```

## Field details

### `id`

- Used as the canonical identifier in other mods' `dependencies` arrays
- Must be ASCII (alphanumeric + hyphen/underscore)
- The Steam Workshop upload process **replaces** this with the numeric Workshop ID (e.g., `"3315794988"`)
- After publishing, never change `id` in an existing published mod — saves that recorded the old ID will stop finding the mod

### `version`

- Semver `"major.minor.patch"` or `"major.minor"` (the dot-separated form)
- Used in `min`/`max`/`exact` version comparisons by mods that depend on yours

### `type`

- `"mod"` — general purpose. Default; use this.
- `"factionpack"` — pure data mod describing AI factions for lore. Restricted capabilities.

### `serverSideOnly` vs `clientSideOnly`

- `serverSideOnly = true`: the server loads the mod; clients receive a notification that it's active but never download or execute its scripts. Safe for backend-only mods. **Any script attached to Entity/Player/Sector must not exist or must guard against client execution** — a server-only mod whose scripts run on the client produces a runtime error.
- `clientSideOnly = true`: only the client loads it. Server ignores it. Safe for HUD overlays, purely cosmetic changes.
- Both `false` (default): mod loads on both sides. Required for mods that attach scripts to in-game objects.

### Dependency keys

| Key | Type | Meaning |
|-----|------|---------|
| `id` | string | **Required** in each dependency entry. Either an Avorion internal name (`"Avorion"`) or another mod's `id` field |
| `min` | version string | Minimum acceptable version (inclusive) |
| `max` | version string | Maximum acceptable version (inclusive) |
| `exact` | version string | Sugar for `min = max = exact`. Mod must be exactly this version |
| `optional` | boolean | If `true`, mod loads if present but absence is not an error |
| `incompatible` | boolean | If `true`, the game warns the player and prevents enabling both mods simultaneously |

## Workshop thumbnail

Place `thumb.png` or `thumb.jpg` (not `thumbnail.jpg`) **next to** `modinfo.lua` at the mod root:

- Maximum 1 MB
- Any resolution; the Workshop UI displays it at ~512×512
- **ASCII-only filename** — all filenames and folder names in the mod tree must be ASCII for Workshop upload to succeed

## Steam Workshop upload flow

1. In-game: Settings → Mods → select your mod (must appear — if not, `modinfo.lua` has a syntax error)
2. Click **Upload** (blue indicator = already uploaded; white = not yet; grey = invalid/someone else's)
3. The engine rewrites `meta.id` to the Workshop item's ID number and stamps an Avorion max-version dependency
4. To update: select mod → enter change notes → **Update Existing Mod**

The Workshop URL format is `https://steamcommunity.com/sharedfiles/filedetails/?id=<id>` — the trailing number is what becomes your `meta.id`.

## Dedicated server `modconfig.lua`

Separate from `modinfo.lua`. Lives in the galaxy directory (not the mod root). Schema:

```lua
modLocation = ""     -- optional; default = <galaxy>/mods/
forceEnabling = false
mods = {
    { workshopid = "1234567890" },
    { path = "absolute/path/to/mymod" },
}
allowed = {   -- client-side mods that may coexist
    { id = "1234567890" },
}
```