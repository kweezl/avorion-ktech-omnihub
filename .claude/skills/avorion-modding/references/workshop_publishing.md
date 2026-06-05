# Workshop Publishing

## Pre-publish checklist

- [ ] `modinfo.lua` is syntactically valid (mod appears in Settings → Mods in-game)
- [ ] `meta.id` is set (will be overwritten by Workshop ID on upload, but must exist)
- [ ] `meta.version` is set
- [ ] `meta.title`, `meta.description`, `meta.authors`, `meta.contact` are filled in
- [ ] `meta.dependencies` includes at least `{ id = "Avorion", min = "X.Y", max = "X.Y" }` with your tested version
- [ ] Thumbnail `thumb.png` or `thumb.jpg` exists next to `modinfo.lua`, ≤ 1 MB
- [ ] **All file and folder names in the mod tree are ASCII only** — non-ASCII names cause silent upload failure
- [ ] Tested in singleplayer and (if applicable) multiplayer

## Upload flow

1. In-game → Settings → Mods
2. Find your mod in the list:
   - **Blue indicator**: already uploaded; use "Update Existing Mod"
   - **White indicator**: not yet uploaded; use "Upload"
   - **Grey indicator**: invalid `modinfo.lua` or the mod belongs to another Steam account
3. Click **Upload** or **Update Existing Mod**
4. Enter change notes (Update only)
5. Confirm

After upload, the engine:
- Rewrites `meta.id` to the numeric Steam Workshop ID (e.g., `"3315794988"`)
- Stamps an Avorion max-version dependency entry (records the current Avorion version as the tested maximum)

Keep the updated `modinfo.lua` (with the Workshop ID) in version control. Any saves that were created with your mod will look for the Workshop ID going forward.

## Thumbnail specs

- File: `thumb.png` or `thumb.jpg` (exactly; no other names)
- Location: mod root (same directory as `modinfo.lua`)
- Max size: **1 MB**
- Recommended resolution: 512×512 or 1024×1024 (Workshop UI crops to square)
- Format: PNG (preferred) or JPEG

## ASCII-only filenames

The Workshop upload pipeline does not support non-ASCII characters in file or folder names. This includes:
- Accented characters (é, ü, ñ, etc.)
- CJK characters
- Emoji or special symbols

Rename any non-ASCII named files before uploading. The game can load them fine locally, but upload silently fails.

## Updating an existing mod

1. Increment `meta.version` in `modinfo.lua`
2. In-game → Settings → Mods → select mod → **Update Existing Mod**
3. Enter change notes (shown on the Workshop page)

You do not need to change `meta.id` for updates — it stays as the Workshop-assigned numeric ID.

## Checking the Workshop URL

The Workshop item URL is:
```
https://steamcommunity.com/sharedfiles/filedetails/?id=<meta.id>
```

The trailing number is the ID the engine will have written into `modinfo.lua` after upload.

## Dedicated server `modconfig.lua`

For dedicated servers, mods are listed in `modconfig.lua` inside the galaxy directory (not the mod root). The server always enables every mod listed; comment out entries to disable.

```lua
-- modconfig.lua (inside galaxy directory, e.g. %AppData%\Avorion\galaxies\MyGalaxy\)

modLocation = ""     -- optional; default = <galaxy_dir>/mods/
                     -- set to an absolute path to use mods from elsewhere

forceEnabling = false  -- if true, listed mods are enabled even if the client doesn't have them

mods = {
    -- Workshop mod (downloaded by server automatically):
    { workshopid = "3315794988" },

    -- Local mod by path:
    { path = "/absolute/path/to/mymod" },
}

allowed = {
    -- Client-side mods that are allowed alongside server mods:
    { id = "3315794988" },
}
```

On conflict between a Workshop entry and a `path` entry with the same mod ID, the Workshop entry is preferred.

## Mod visibility and server-side-only

If your mod uses `serverSideOnly = true`:
- The server loads and executes it
- Connecting clients are told "this server uses mod X" but don't download or execute any scripts
- Useful for: server economy tweaks, spawn-rate changes, AI behavior changes where client visual feedback doesn't differ

If `serverSideOnly = false` (default) and a client doesn't have the mod:
- The client will be prompted to subscribe to / download the mod before joining
- Workshop mods are downloaded automatically by Steam; local mods require manual installation