# Extending Vanilla Scripts

## How the engine merges files

When the engine resolves a script path (e.g., `data/scripts/entity/merchants/factory.lua`), it:

1. Collects all files at that path from: the base game, then each enabled mod in dependency order
2. **Concatenates** them into a single virtual Lua chunk
3. Executes the combined chunk as one file

This means a mod file at `data/scripts/entity/merchants/factory.lua` is **appended after** the vanilla file. At the point your fragment runs, `Factory.initialize`, `Factory.secure`, etc. are already defined and you can read them.

The mod injection point is immediately before the file's trailing `return Factory` statement. Mod fragments go in there. This is why the trailing return must be unconditional.

## The cache-then-wrap idiom

Cache a reference to the vanilla function *before* defining your replacement:

```lua
-- Your mod: data/scripts/entity/merchants/factory.lua

local base_initialize = Factory.initialize
local base_secure     = Factory.secure
local base_restore    = Factory.restore
local base_update     = Factory.updateServer   -- if you're wrapping the server update

function Factory.initialize(...)
    base_initialize(...)           -- run vanilla first
    Factory.myConfig = {}          -- then your additions
end

function Factory.secure()
    local data = base_secure()     -- get vanilla's (and prior mods') table
    data.myModKey = Factory.myConfig
    return data                    -- add your key and return
end

function Factory.restore(data)
    base_restore(data)             -- vanilla restore first
    Factory.myConfig = data.myModKey or {}
end

function Factory.updateServer(timeStep)
    base_update(timeStep)
    -- your server-side periodic logic
end
```

### Naming conventions for cached references

Different mods use different prefixes to avoid collisions between multiple mods all wrapping the same function:

- `base_<funcName>` — simple mods, short name
- `<MyMod>_<funcName>_original` — e.g., `CosmicOverhaul_secure_original`
- `<feature>_<funcName>_original` — e.g., `mcm_TradeCommand_buildUI_original`

Using a mod-specific prefix is safer if you expect your mod to coexist with other mods that also wrap the same function. A collision (two mods using `base_secure`) would mean the second mod's `base_secure` caches the first mod's wrapper rather than the vanilla function — which still works because chains compose, but can produce unexpected behavior in edge cases.

## Library extensions work the same way

`data/scripts/lib/` files follow the same rules. The engine injects mod extensions to, say, `utility.lua` before its trailing `return`. This means:

- You can add new functions to any library by shipping a fragment at the same lib path
- The `callable.lua` lib populates `namespace.Callable` — mod extensions to a namespace fragment can `callable(NS, "fn")` and it works because `callable.lua` was loaded before the fragment

## Deciding when to extend vs create new

| Situation | Extend (same path) | New file (different path) |
|-----------|-------------------|--------------------------|
| You need to change the behavior of an existing station/AI/mechanic | ✓ | |
| You want to add a callback to vanilla factory behavior | ✓ | |
| You're adding entirely new behavior with no vanilla hook | | ✓ |
| Your behavior is orthogonal and shouldn't affect vanilla scripts | | ✓ |
| You need to override a vanilla asset (texture, sound) | n/a | Shadow at same path |

## Attaching new scripts

For new entity behaviors, attach from your mod's `data/scripts/entity/init.lua` (the engine runs this for every new entity):

```lua
-- data/scripts/entity/init.lua  (your mod's copy, appended after vanilla)
if onServer() then
    local base_init = Entity.initialize    -- if you also need to wrap init
    function Entity.initialize()
        base_init()
        entity:addScriptOnce("mymod/mybehavior.lua", arg1)
    end
end
```

`addScriptOnce` is strongly preferred over `addScript` — it's idempotent across reloads and restores. `addScript` on an entity that already has the script attached results in the callback firing twice.

## Checking for vanilla function existence

Sometimes you want to extend a function that may or may not exist depending on game version or other mods:

```lua
local base_somefn = MyScript.someFn
if base_somefn then
    function MyScript.someFn(...)
        base_somefn(...)
        -- your additions
    end
else
    function MyScript.someFn(...)
        -- you're first
    end
end
```

## pcall-guarded optional dependencies

When bridging with another mod that may or may not be installed:

```lua
local ok = pcall(include, "othermod/bridge")
if ok and type(_G.OtherModBridge) == "table" then
    -- use OtherModBridge.someFunc(...)
end
```

`pcall(include, path)` returns `true` if the file loaded without error; it does not throw even if the file doesn't exist in the VFS. Guard downstream calls with a `type` check because the mod might load an empty stub.
