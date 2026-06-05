# Common Pitfalls

Avorion's scripting VM has several subtle behaviors that produce silent failures rather than runtime errors. These are the ones that come up most often.

---

## 1. `Entity()` / `Player()` / `Faction()` return references, not new objects

```lua
-- WRONG: creates a CargoBay reference, discards it immediately
CargoBay():addCargo(good, 10)   -- may work by coincidence, or silently fail

-- RIGHT: assign the reference and use it
local bay = CargoBay()
local added = bay:addCargo(good, amount)
```

More importantly, these functions return **references to existing engine objects**. They don't construct anything. `Entity()` returns a reference to the entity whose script is currently executing. `Entity(42)` returns a reference to entity with index 42. If that entity no longer exists, the reference is invalid — calling methods on it throws.

Check validity before use: `if valid(someEntity) then ... end`.

---

## 2. `mat.position.x = 5` writes to a value copy

Avorion's API objects (vec3, Transform, Matrix) are **value types** — property access returns a copy, not a live reference:

```lua
local e = Entity()
e.position.x = 5    -- WRONG: reads e.position (gets a copy), sets .x on that copy, discards it
                    -- e.position is unchanged
```

Correct approach — replace the entire value:

```lua
local pos = e.position    -- get copy
-- manipulate pos here:
pos = vec3(pos.x + 5, pos.y, pos.z)
e.position = pos           -- assign back
```

The warning sign is any chain of the form `a.b.c = value` where `a` is an API object. Even `e.position.y = e.position.y + 1` is broken for the same reason.

---

## 3. Cached entity references go stale

`Entity` userdata is tied to the entity's presence in the current simulation step. If you store a reference across frames, across sector changes, or across `update` calls, it may become invalid:

```lua
-- WRONG: storing userdata
MyScript.cachedFactory = Entity()

function MyScript.update(timeStep)
    MyScript.cachedFactory:getValue("x")   -- may crash if entity was recreated
end

-- RIGHT: store the persistent index
MyScript.factoryId = Entity().id

function MyScript.update(timeStep)
    local factory = Entity(MyScript.factoryId)
    if not valid(factory) then return end
    factory:getValue("x")
end
```

`entity.id` is an `Index` userdata that persists as long as the entity exists in the save. Use it as your stable reference.

---

## 4. Client Sector/Entity scripts lose state on every sector change

The client VM for scripts attached to Sector and Entity objects is destroyed and freshly initialized each time the player enters a sector — even for the player's own ship. This means:

- Client-side accumulated state (UI caches, filtered lists, etc.) is gone after every jump
- `initUI` fires again on the new sector entry
- `secure`/`restore` **is not called** for client-side scripts — persistence is server-only

Workaround: keep all persistent state on the server script and push it to the client via `invokeClientFunction` in `initUI`.

---

## 5. `initialize()` runs again on restore without arguments

`initialize(arg1, arg2, ...)` is called both on first-attach (with the args from `addScript(path, arg1, arg2, ...)`) and on restore from disk (with no args, `_restoring = true`). If your `initialize` does argument-dependent setup, guard it:

```lua
function MyScript.initialize(stationIndex, itemCount)
    if _restoring then return end   -- or: if not stationIndex then return end
    MyScript.stationIndex = stationIndex
    MyScript.itemCount = itemCount or 0
end
```

Without the guard, on restore `stationIndex` is nil, and any code that uses it immediately after will error or silently produce wrong state.

---

## 6. `require` bypasses mod injection

```lua
include("utility")   -- correct: goes through VFS, mod extensions applied
require("utility")   -- wrong: reads raw filesystem file, mod extensions skipped
```

Using `require` for game scripts means:
- Your mod's fragments appended to `utility.lua` are never executed by that script
- The `Callable` table won't be populated for library-based callable registrations
- Other mods' extensions to the library are invisible

Use `require` only for standalone third-party Lua modules that are not part of the Avorion VFS.

---

## 7. The namespace comment is load-bearing

```lua
-- namespace MyScript   ← DO NOT REMOVE OR ALTER
```

The C++ loader parses this line. Consequences of removing or altering it:
- The script is isolated in its own VM
- `entity:registerCallback("onDamaged", "onMyScriptDamaged")` — callbacks on the entity's other scripts can no longer call across to this one
- Other mods that extend this file can't share the namespace
- `entity:invokeFunction("path/myscript.lua", "funcName")` still works but `invokeServerFunction` pattern across the namespace breaks

Consequence of name mismatch (`-- namespace myScript` but `MyScript = {}`):
- Callbacks can't be found — the engine looks for `myScript.initialize`, finds nothing

---

## 8. `local` inside `if onServer()` is invisible to extending mods

```lua
-- WRONG
if onServer() then
    local helper = SomeLib.createHelper()   -- invisible outside this block
    function MyScript.update(timeStep)
        helper:doWork()   -- visible here (upvalue closure), but:
    end
end
-- Another mod appending to this file cannot access 'helper'.
-- More critically: if helper needs to be reset on restore, nothing can do it.

-- RIGHT
local helper = nil    -- declare at file scope
if onServer() then
    helper = SomeLib.createHelper()
    function MyScript.update(timeStep)
        if helper then helper:doWork() end
    end
end
```

---

## 9. Conditional `return Module` breaks extension injection

```lua
-- WRONG: injection point is inside the conditional block
if onServer() then
    return MyScript
end

-- WRONG: same problem, other side
if not onServer() then
    -- do client stuff
    return MyScript
end

-- RIGHT: early exit at TOP, unconditional return at BOTTOM
if not onServer() then return end   -- bail out of server-only file
MyScript = {}
-- ... all your callbacks ...
return MyScript    -- unconditional, always the last line
```

---

## 10. `io` is sandboxed

The `io` library is available but sandboxed. File paths are restricted to the Avorion user directory:

- **Windows:** `%AppData%\Avorion\`
- **Linux:** `~/.avorion/`

Attempting to read or write outside this directory fails silently or throws a "permission denied" error. You cannot write to the Steam install directory, system paths, or arbitrary user paths.

To persist data, use `secure`/`restore` (recommended) or `io.open` within the allowed user directory for config files.