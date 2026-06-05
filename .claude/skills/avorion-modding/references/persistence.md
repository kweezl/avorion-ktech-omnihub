# Persistence — secure / restore

## Lifecycle order on load

```
1. initialize()       — called first, always, even during restore
                        args are passed from addScript(); _restoring = true during restore
2. restore(data)      — called after initialize(), receives whatever secure() last returned
3. [update loop begins]
```

`secure()` is called asynchronously whenever the engine needs to save the object (player logout, sector unload, server shutdown, etc.). You cannot predict when it fires — don't do blocking work there, and don't assume it fires before `restore`.

## The `_restoring` guard

Because `initialize()` runs again on every restore, you must guard first-time setup:

```lua
function MyScript.initialize(arg1, arg2)
    if _restoring then return end    -- engine global; true only during load-from-disk
    -- first-time initialization
    MyScript.counter = 0
    MyScript.config = { enabled = true }
end
```

Alternatively check for nil args if first-time setup expects arguments:

```lua
function MyScript.initialize(stationIndex, factionIndex)
    if not stationIndex then return end   -- no args = restoring
end
```

## Basic secure / restore pair

```lua
function MyScript.secure()
    -- Return a plain Lua table (no userdata, no functions, no cycles).
    -- Nested tables are fine. Numbers, strings, booleans, nil are fine.
    return {
        counter = MyScript.counter,
        config  = MyScript.config,
    }
end

function MyScript.restore(data)
    -- data is exactly what the last secure() returned.
    -- Use 'or default' for backwards compat when adding new fields.
    MyScript.counter = data.counter or 0
    MyScript.config  = data.config  or { enabled = true }
end
```

## Extending vanilla secure / restore (cache-then-wrap)

When your mod adds a file at the same path as a vanilla script (e.g., `data/scripts/entity/merchants/factory.lua`), always wrap the vanilla functions rather than redefining them:

```lua
-- Your mod's data/scripts/entity/merchants/factory.lua
local base_secure  = Factory.secure    -- cache BEFORE defining your replacement
local base_restore = Factory.restore

function Factory.secure()
    local data = base_secure()         -- vanilla (and earlier mods') data
    data.myModField = Factory.myModField
    return data
end

function Factory.restore(data)
    base_restore(data)                 -- vanilla (and earlier mods') restore
    Factory.myModField = data.myModField or defaultValue
end
```

Why this matters: if two mods both redefine `Factory.secure` from scratch, only the last one's data survives. Cache-then-wrap stacks correctly regardless of mod load order.

## Per-script-kind persistence rules

| Script kind | When saved | When loaded | Client scripts |
|-------------|-----------|-------------|----------------|
| Entity script | Entity saved (sector unload, server stop) | Entity loaded into sector | Not persistent — re-init on every sector entry |
| Player script | Player logout / server stop | Player login | Persistent across sector changes; re-init only on reconnect |
| Sector script | Sector unloads | Sector loads | Not persistent on client |
| Alliance script | Alliance save events | Alliance load | Persistent |

Client-side scripts on Entity and Sector are explicitly **not** saved. Never try to persist UI state through `secure`/`restore` from the client side — it won't be called. Persist through the server script instead and push to client via RPC on `initUI`.

## Alternative persistence: entity values

For simple key-value pairs that need to survive without a full `secure`/`restore` cycle (e.g., tagging an entity so other scripts can find it):

```lua
entity:setValue("mymod_type", "salvageYard")    -- server only, string values
entity:setValue("mymod_level", tostring(5))

-- read back (any script on any entity)
local t = otherEntity:getValue("mymod_type")    -- returns nil if unset
```

`getValue`/`setValue` data is saved with the entity automatically. Prefer `secure`/`restore` for complex structured data; use entity values for simple cross-script flags.

## Serialization constraints

`secure()` must return data that the engine can serialize to disk. Allowed types:

- `nil`, `boolean`, `number`, `string`
- `table` (with string or integer keys; recursively all-serializable values)

Not allowed (will error or be silently dropped):

- Userdata: `Entity`, `Player`, `vec3`, `Rect`, `ColorRGB`, etc.
- Functions
- Tables with circular references
- Coroutines

If you need to persist an entity reference, store `entity.index` (an integer). If you need to persist a vec3, store `{x = v.x, y = v.y, z = v.z}`.
