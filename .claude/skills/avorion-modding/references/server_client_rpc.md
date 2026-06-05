# Server / Client Split and RPC

## Which VM runs what

| Script kind | Server VM | Client VM | Persistence |
|-------------|-----------|-----------|-------------|
| Entity script | ✓ | ✓ | Travels with entity; reset on sector change for client |
| Sector script | ✓ | ✓ | Server: saved with sector; Client: re-inits on every sector entry |
| Player script | ✓ | ✓ | Travels with player across sectors |
| Alliance script | ✓ | ✓ | Persistent for alliance lifetime |
| AIFaction script | ✓ only | — | Server-only; never runs on client |

"Client Sector/Entity scripts re-initialize on every sector change" means: the client VM for your script is destroyed and recreated fresh every time the player enters a new sector — even for the player's own ship. UI state, cached values, anything not persisted through `secure`/`restore` or `entity:setValue` is lost.

## Gating code per side

```lua
-- Per-function gate (most common)
function MyScript.update(timeStep)
    if not onServer() then return end
    -- server logic
end

-- Block gate (for a set of functions defined only on one side)
if onServer() then
    function MyScript.getUpdateInterval() return 1 end
    function MyScript.update(timeStep) ... end
end

if onClient() then
    function MyScript.initUI() ... end
    function MyScript.onPreRenderHud() ... end
end

-- File-scope early exit (server-only files)
if not onServer() then return end
-- ... rest of file is server-only
-- unconditional return MyScript still goes at the very end
```

Do **not** declare `local` variables inside `if onServer() then ... end` blocks. Locals declared inside a conditional are invisible to other mod fragments appended to the same file. Declare at file scope and assign inside the conditional.

## RPC primitives

All RPCs are **fire-and-forget** — async, no return value, no delivery confirmation. To get data back, the server sends a second call to the client.

### Client → server

```lua
invokeServerFunction("functionName", arg1, arg2, ...)
```

`functionName` must be the name of a function on the **same script's namespace table** that has been registered with `callable`. Args are serialized; only basic Lua types are supported (string, number, boolean, table, nil). Userdata (Entity, Player, etc.) cannot be sent directly — send the index instead.

### Server → specific client

```lua
invokeClientFunction(player, "functionName", arg1, arg2, ...)
```

`player` is a `Player` userdata. On the server side, `Player(callingPlayer)` gives you the player who triggered the current `invokeServerFunction` call.

### Server → all clients in sector

```lua
broadcastInvokeClientFunction("functionName", arg1, arg2, ...)
```

Calls `functionName` on every connected player currently in the sector.

### Cross-sector / cross-entity (server only)

For reaching scripts on entities or sectors that aren't the current context:

```lua
invokeRemoteEntityFunction(entity, scriptPath, "funcName", ...)
invokeRemoteSectorFunction(x, y, scriptPath, "funcName", ...)
runRemoteEntityCode(entity, codeString)
runRemoteSectorCode(x, y, codeString)
```

These are also async. Cross-sector calls may take several seconds depending on server configuration.

## `callable` — marking server functions as reachable from client

```lua
-- At file scope (not inside initialize or any function):
callable(MyScript, "serverFetchData")
callable(MyScript, "serverSetConfig")
```

`callable(namespace, "funcName")`:
- On the server: registers `namespace.funcName` in `namespace.Callable["funcName"]`, making it reachable via `invokeServerFunction("funcName")`
- On the client: replaces `namespace.funcName` with a stub that calls `invokeServerFunction("funcName", ...)` — so client code can call `MyScript.serverFetchData()` directly and it gets routed to the server transparently

`rcall` is an alias for `callable`. Always call it at file scope. If called inside `initialize()` it fires only after first load (not on restore from disk), which can cause missed registrations.

## `callingPlayer`

The global `callingPlayer` holds the **integer index** of the player whose `invokeServerFunction` call triggered the current server-side execution. It is:
- Valid only inside a function reached via `invokeServerFunction`
- Invalid (undefined) in `update`, `initialize`, `restore`, `secure`, or any other non-RPC context
- An integer, not a Player userdata — wrap it: `Player(callingPlayer)`

```lua
function MyScript.serverFetchData()
    if not onServer() then return end
    local player = Player(callingPlayer)   -- always re-wrap each call
    local sectorX, sectorY = player:getSectorCoordinates()
    invokeClientFunction(player, "receiveData", {x = sectorX, y = sectorY})
end
callable(MyScript, "serverFetchData")
```

## Full round-trip pattern

```lua
-- ── Client side ───────────────────────────────────────────────────────────────

function MyScript.initUI()
    -- set up UI, then request data
    MyScript.requestData()
end

function MyScript.requestData()
    invokeServerFunction("serverProvideData")   -- async, returns immediately
end

function MyScript.receiveData(payload)
    -- update UI with payload.someValue etc.
end

-- ── Server side ───────────────────────────────────────────────────────────────

function MyScript.serverProvideData()
    if not onServer() then return end
    local player = Player(callingPlayer)
    local result = { ... }   -- gather data
    invokeClientFunction(player, "receiveData", result)
end
callable(MyScript, "serverProvideData")    -- at file scope
```

## Common mistakes

| Mistake | Consequence |
|---------|-------------|
| Forgetting `callable(NS, "fn")` | `invokeServerFunction("fn")` silently does nothing |
| Calling `invokeClientFunction(Player(callingPlayer), ...)` from `update()` | `callingPlayer` is 0/garbage; wrong player receives the message |
| Sending a userdata arg (Entity, Faction, etc.) via RPC | Serialization fails; arg arrives as nil |
| Calling `callable(...)` inside `initialize()` | Works on first load but not on restore — use file scope |
| Storing a `Player` userdata across frames | Player reference may become stale; store `player.index`, wrap fresh each call |
