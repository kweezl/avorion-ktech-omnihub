---
name: avorion-modding
description: >
  Avorion mod development in Lua. Use whenever working in an Avorion mod repo
  or writing/modifying any Lua file destined for data/scripts/. Covers
  modinfo.lua scaffolding, the magic "-- namespace X" header (load-bearing —
  the C++ engine parses it), include vs require, entity/sector/player script
  anatomy, the auto-discovered callback set (initialize, update, secure,
  restore, etc.), callable + invokeServerFunction/invokeClientFunction RPCs,
  the cache-then-wrap pattern for extending vanilla scripts, persistence via
  secure/restore, the %_t localization operator, /devmode + F5 hot-reload, and
  Workshop publishing rules. Trigger even when the user only says "add a
  callback", "extend the factory", "make a station behavior", or "deploy this
  mod" — they likely don't know to ask for an "Avorion skill" by name.
---

# Avorion Modding

## Environment check

Verify `AVORION_DATA_DIR` and `AVORION_MODS_DIR` are set (defined in `.claude/settings.json`; documented in `CLAUDE.md`). If either is unset or points to a non-existent path, ask the user to update `.claude/settings.json` before proceeding. The EmmyLua type stubs in `stubs/` are IDE-only — never deployed.

## Quick-reference: jump to the right section

| Task | Read first |
|------|-----------|
| New script from scratch | § *Script anatomy* below, then `assets/entity_script.lua.template` or `assets/sector_script.lua.template` |
| Extending a vanilla script (factory.lua, civilship.lua …) | `references/extending_vanilla.md` + `references/persistence.md` |
| Adding / wiring a callback | `references/callbacks.md` |
| Server ↔ client communication | `references/server_client_rpc.md` + `assets/rpc_pair.lua.template` |
| Persisting state across save/load | `references/persistence.md` |
| Writing `modinfo.lua` | `references/modinfo_reference.md` + `assets/modinfo.lua.template` |
| Deploying or hot-reloading | § *Deployment loop* below |
| Debugging a runtime error | `references/debugging.md` |
| Finding the right lib helper | `references/lib_modules.md` |
| Publishing to Workshop | `references/workshop_publishing.md` |
| Investigating a subtle bug | `references/pitfalls.md` |

---

## Script anatomy — five rules that silently break a script if omitted

Every Avorion Lua script must follow these five rules. Violating any of them produces a script that silently misbehaves (wrong VM, missing callbacks, mod extensions not applied) rather than throwing a runtime error.

### 1. Extend `package.path` before any `include`

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"
```

Avorion's VFS mounts mods on top of the base data directory, but Lua's standard loader doesn't know about that. This line points the loader at the right place. Sector and player scripts that need sibling directories add more:

```lua
package.path = package.path .. ";data/scripts/?.lua"
package.path = package.path .. ";?"
```

### 2. Use `include()`, never `require()`

`include("utility")` goes through Avorion's VFS, which means mod fragments are injected into library files before execution. `require("utility")` bypasses this entirely and loads only the vanilla copy — extensions that other mods (or your own mod) appended to that library are silently skipped.

Three call styles exist depending on the library:

```lua
include("stringutility")          -- side-effecting: injects globals, returns nil
local Mod = include("plangenerator")     -- module-returning: library returns a table
local Mod = include("upgradegenerator")()  -- factory: library returns a constructor
```

### 3. The magic namespace comment (load-bearing)

```lua
-- namespace MyScript
```

This comment is parsed by the C++ engine, not Lua. It tells the engine which namespace VM this script belongs to. The Avorion wiki is explicit: *"Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break."* Consequences of removal: the script runs in its own isolated VM, callbacks across scripts sharing the namespace break, and extension by other mods fails.

### 4. Assign the namespace table as a global

```lua
MyScript = {}
```

Must be a **global**, not `local MyScript = {}`. The engine discovers it by name. Mods that extend this file are appended after this line and see the same table.

### 5. Unconditional trailing `return MyScript`

```lua
return MyScript    -- always the last line
```

The engine injects mod extensions *before* the `return`, not at the end of the file. If you conditionally return early (`if onServer() then return MyScript end`), the injection point disappears and no extension can run. Instead, put side-gating *above* the namespace assignment, and keep `return` unconditional at the bottom.

---

## Server / client mental model

Most attached scripts (Entity, Player, Alliance, Sector) run in **both** server and client VMs. Gate side-specific code with `onServer()` / `onClient()`. Two common patterns:

```lua
-- Pattern A: shared file with per-side blocks
if onServer() then
    function MyScript.getUpdateInterval() return 1 end
    function MyScript.update(timeStep) ... end
end

if onClient() then
    function MyScript.initUI() ... end
end

-- Pattern B: server-only file — short-circuit at the top
if not onServer() then return end
-- (the unconditional return MyScript at the bottom still applies)
```

Critical nuances:
- **Client Sector/Entity scripts re-initialize on every sector change** — including the player's own ship. Never store unsaved client-side state across jumps.
- **AIFaction scripts are server-only** and never run on the client.
- **`callingPlayer`** is only valid inside a function reached via `invokeServerFunction`. Reading it in `update` or `initialize` gives garbage.

→ Full RPC wiring: `references/server_client_rpc.md`

---

## Override vs extend

| Situation | Approach |
|-----------|----------|
| Add behavior on top of an existing vanilla script | Mirror the path under your mod's `data/scripts/` (same filename) and use the cache-then-wrap pattern |
| Entirely new script, no vanilla counterpart | New path; attach via `entity:addScriptOnce("mymod/myscript.lua")` from your `init.lua` |
| Replace a non-script asset (texture, sound) | Shadow: put file at the same relative path; engine uses the mod's copy first |

The engine concatenates all files with the same path (in dependency order) into one virtual file before loading. Your extension appended to vanilla's `factory.lua` sees `Factory.initialize`, `Factory.secure`, etc. already defined and can safely wrap them.

→ Full idiom + worked examples: `references/extending_vanilla.md`

---

## Deployment loop

**First-time setup — Windows junction (run once in an admin terminal):**

```bat
mklink /J "%APPDATA%\Avorion\mods\avorion-omnihub" "<path-to-repo>\avorion-omnihub"
```

A directory junction (not a symlink) is used because junctions work without elevated UAC on Windows 10/11. The mod folder is now live-linked to the repo — edits in the repo are immediately visible to the game.

**Enable in-game:** Settings → Mods → check `avorion-omnihub` → restart.

**Iterative hot-reload (no restart needed):**

1. Edit Lua files in the repo
2. In-game chat: `/devmode` (once per session)
3. Select an entity → **F5** reloads its scripts; **Shift-F5** reloads player scripts; **Ctrl-F5** reloads sector + all entity scripts
4. **F6** clears client caches (tooltips, parts list, upgrades); **Ctrl-F6** also reloads shaders — use sparingly, can crash
5. **Dev Mode checkbox** in Settings → Mods disables script-path caching so *new* `.lua` files are picked up without a game restart

→ Detailed debug tooling: `references/debugging.md`

---

## Common task recipes

### Periodic behavior on an entity script

```lua
function MyScript.getUpdateInterval()
    return 5.0   -- engine calls update() every 5 seconds; omit entirely if no polling needed
end

function MyScript.update(timeStep)
    if not onServer() then return end
    -- timeStep = seconds elapsed since last update call
end
```

Registering a named callback on a different event:

```lua
function MyScript.initialize()
    Entity():registerCallback("onDestroyed", "onEntityDestroyed")
end

function MyScript.onEntityDestroyed(lastDamageInflictor)
    -- runs on server when this entity is destroyed
end
```

### Extend a vanilla script

Mirror the path under your mod's `data/scripts/`. Cache vanilla functions first, then wrap:

```lua
-- data/scripts/entity/merchants/factory.lua  (your mod's copy)
local base_secure  = Factory.secure
local base_restore = Factory.restore
local base_initialize = Factory.initialize

function Factory.initialize(...)
    base_initialize(...)
    Factory.myField = Factory.myField or defaultValue
end

function Factory.secure()
    local data = base_secure()
    data.myField = Factory.myField
    return data
end

function Factory.restore(data)
    base_restore(data)
    Factory.myField = data.myField or defaultValue
end
```

Never redefine `secure`/`restore` from scratch — always call `base_*` to preserve vanilla (and other mods') data.

### New entity script from scratch

Copy `assets/entity_script.lua.template`, rename namespace throughout, fill in callbacks. Attach to new entities via your mod's `data/scripts/entity/init.lua`:

```lua
entity:addScriptOnce("mymod/mybehavior.lua", arg1, arg2)
```

`addScriptOnce` is preferred over `addScript` so reloads/restores don't double-attach.

### Persist data across save/load

```lua
function MyScript.initialize(arg1, arg2)
    if _restoring then return end   -- engine sets _restoring=true during load-from-disk
    -- first-time initialization only
    MyScript.counter = 0
end

function MyScript.secure()
    return { counter = MyScript.counter }
end

function MyScript.restore(data)
    MyScript.counter = data.counter or 0
end
```

→ Full lifecycle and extension pattern: `references/persistence.md`

### Server ↔ client RPC

```lua
-- Client side: request data
function MyScript.fetchData()
    invokeServerFunction("serverProvideData")
end

-- Server side: gather and respond
function MyScript.serverProvideData()
    if not onServer() then return end
    local player = Player(callingPlayer)    -- callingPlayer = index of requesting player
    local payload = { ... }
    invokeClientFunction(player, "clientReceiveData", payload)
end
callable(MyScript, "serverProvideData")    -- must be at file scope

-- Client side: receive response
function MyScript.clientReceiveData(payload)
    -- update UI
end
```

Copy `assets/rpc_pair.lua.template` for a fuller scaffold. RPCs are async and fire-and-forget — no return value, no failure callback. Round-trip is always two calls.

### Deploy for the first time

```bat
mklink /J "%APPDATA%\Avorion\mods\avorion-omnihub" "<path-to-repo>\avorion-omnihub"
```

Then restart game and enable the mod.

---

## Six pitfalls worth memorizing

1. **`Entity()` / `Player()` / `Faction()` return references, not new objects.** Calling `Entity()` in a tight loop is fine; creating a `CargoBay()` once and storing the reference is fine. But a stored `Entity` userdata goes stale if the entity is destroyed or the sector changes. Cache `entity.id` (the persistent `Index`) and call `Entity(id)` fresh per frame.

2. **`mat.position.x = 5` writes to a value copy.** API objects that return struct-like types (vec3, Transform) give you a copy. Assigning a field on that copy silently does nothing. Always replace the whole value: `entity.position = myNewTransform` or rebuild with vec arithmetic.

3. **Client Sector/Entity scripts lose state on every sector transition.** Don't accumulate data in client-side script globals between sectors. Persist through `secure`/`restore` or through `entity:getValue`/`setValue`.

4. **`require` bypasses mod injection.** Other mods' extensions to `utility.lua` (or any lib) are never seen by a script that `require`d it. Use `include` for everything game-related.

5. **Trailing `return Module` must be unconditional.** `if onServer() then return Module end` at the file end breaks the engine's extension injection. Flip it: early-return at the *top* for side-gating, unconditional return at the *bottom*.

6. **`local` declarations inside `if onServer() then ... end` are invisible to extending mods.** Declare at file scope (even as `local X = nil`), assign inside the conditional.

→ Full catalog with examples: `references/pitfalls.md`

---

## Authoritative API reference

The Avorion wiki pages for callbacks and the full scripting API are stubs — the wiki explicitly redirects modders to the shipped documentation. For exhaustive callback names and function signatures open:

```
$AVORION_DATA_DIR/../documentation/index.html
```

(Default Steam install: `C:/Program Files (x86)/Steam/steamapps/common/Avorion/documentation/index.html`)