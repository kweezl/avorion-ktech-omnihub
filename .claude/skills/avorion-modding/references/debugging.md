# Debugging and Development Tools

## Enabling dev mode

Two separate things are both called "dev mode":

### `/devmode` chat command (in-game)

Type `/devmode` in the in-game chat (requires a key bound to "open chat" in input settings). Triggers a game restart prompt. After restart:

- Every entity gets the `entitydbg.lua` script auto-attached (accessible via the `~dev` interaction menu on any entity)
- **F5** — reload scripts for the currently selected entity
- **Shift-F5** — reload player scripts
- **Ctrl-F5** — reload sector + all entity scripts
- **F6** — clear all client-side caches (tooltips, parts list, upgrade list, fighter templates, sector specs)
- **Ctrl-F6** — F6 + reload shaders, textures, and client config. Use carefully — can crash the client
- **Shift-F7** — cycle background render variants
- **F11** — reload `volumes.ini`

`/devmode` persists across sessions (saved in client config). Disable by running it again.

### Dev Mode checkbox (mod window)

Settings → Mods → checkbox labeled **Dev Mode** next to the mod. This disables script-path caching for that mod, so newly created `.lua` files are discovered without a game restart. Without it, new files are invisible until restart even in `/devmode`.

Costs a little performance — enable it during development, disable it for testing "as shipped".

---

## Print functions

| Function | Output destination | Notes |
|----------|--------------------|-------|
| `print(...)` | In-game console (client) and log | Standard Lua print; safe to use everywhere |
| `printlog(...)` | Log file only | Use for verbose diagnostic output you don't want cluttering the in-game console |
| `eprint(...)` | Error stream | Appears highlighted in some log viewers |
| `printTable(tbl, indent)` | Console + log | From `utility.lua`; recursively dumps a table. Useful for inspecting save data, config tables, etc. |

All print output is tagged by VM (server vs client) in the log file. Timestamps are included.

---

## Log file locations

| Type | Path |
|------|------|
| Client log | `%AppData%\Avorion\clientlog*.txt` (most recent = largest number) |
| Server/galaxy log | `%AppData%\Avorion\galaxies\<save-name>\server.log` |
| Server tracebacks | Same galaxy directory, look for files with "traceback" in the name |

On Linux: `~/.avorion/` is the root.

To watch the log live (PowerShell):
```powershell
Get-Content "$env:APPDATA\Avorion\clientlog0.txt" -Wait -Tail 50
```

---

## Type introspection

Avorion API objects return `"userdata"` from standard Lua `type()`. To get the actual API class name:

```lua
local e = Entity()
print(type(e))          -- "userdata"
print(e.__avoriontype)  -- "Entity"

local v = vec3(1, 2, 3)
print(v.__avoriontype)  -- "vec3" (or "Vector" depending on version)
```

`__avoriontype` is a special property (not a standard Lua field) that the engine exposes on all its userdata objects. Use it when you receive an unknown object and need to branch on its type.

---

## Attaching the debug script manually

If `/devmode` isn't active, you can attach the entity debug UI to a specific entity via the in-game command console:

```
/run Entity():addScript("lib/entitydbg.lua")
```

This opens the `~dev` interaction menu on the currently selected entity, which lets you inspect values, call functions, and view attached scripts.

---

## Common diagnostic patterns

### Check if a script is attached

```lua
print(Entity():hasScript("data/scripts/entity/merchants/factory.lua"))
```

### Dump all values on an entity

```lua
local values = Entity():getValues()
printTable(values)
```

### Check what scripts are running on a sector

```lua
for _, script in pairs(Sector():getScripts()) do
    print(script)
end
```

### Trace a missing callback

If a callback fires on another script but not yours, check:
1. Does `-- namespace MyScript` appear literally (no trailing spaces, correct case)?
2. Is `MyScript = {}` a global (not `local`)?
3. Did you register the callback? (`Entity():registerCallback("eventName", "funcName")`)
4. Is the function name spelled exactly right (`MyScript.funcName`)?
5. Is `/devmode` on? Press **F5** to reload and try again.

---

## The `modinfo.lua` syntax check

If your mod doesn't appear in Settings → Mods at all, `modinfo.lua` has a Lua syntax error or a missing required field. Run:

```bat
lua -c modinfo.lua
```

...if you have a standalone Lua interpreter. Otherwise check `clientlog*.txt` for an error around mod loading at startup.