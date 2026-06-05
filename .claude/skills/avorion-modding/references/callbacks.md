# Callbacks Reference

Two categories: (1) **auto-discovered** file-scope functions the engine calls by name, and (2) **explicit registration** via `registerCallback`.

For an exhaustive, authoritative list open `$AVORION_DATA_DIR/../documentation/index.html`.

---

## Auto-discovered callbacks (engine calls by function name)

These functions are detected by the engine if they exist at file scope on the namespace table. You do **not** need to call `registerCallback` for them — just define them.

### Lifecycle

| Function | Signature | Fires on | Notes |
|----------|-----------|----------|-------|
| `initialize` | `(...)` | First load and on restore from disk | `_restoring` is `true` during restore; args are those passed to `addScript("path", arg1, arg2, ...)` |
| `restore` | `(data)` | After `initialize` during load from disk | `data` is whatever `secure()` last returned |
| `secure` | `() → table` | Before any save event | Return a serializable table; nested tables OK, userdata not allowed |
| `onRestoredFromDisk` | `(timeSinceLastSim: number)` | Entity scripts, after database restore | `timeSinceLastSim` = seconds the entity was absent from simulation |

### Update

| Function | Signature | Fires on | Notes |
|----------|-----------|----------|-------|
| `getUpdateInterval` | `() → number` | Before each update cycle | Return seconds between calls. Omit the function entirely if you don't need polling — an empty `update` still costs CPU |
| `updateParallelRead` | `(timeStep)` | Before `updateParallelSelf` | Read-only pass; must not modify world state |
| `updateParallelSelf` | `(timeStep)` | After `updateParallelRead` | May modify own entity only |
| `update` | `(timeStep)` | Both server and client | General update |
| `updateServer` | `(timeStep)` | Server only | Runs after `update` |
| `updateClient` | `(timeStep)` | Client only | Runs after `update` |

### UI / interaction

| Function | Signature | Notes |
|----------|-----------|-------|
| `initUI` | `()` | Client; lazy — fires only when player first opens the interaction window |
| `interactionPossible` | `(playerIndex, option?) → bool` | Server; called before the interaction menu appears. Return false to hide/disable |
| `onShowWindow` | `()` | Client; fires when the interaction window opens |
| `onCloseWindow` | `()` | Client; fires when the interaction window closes |
| `onPreRenderHud` | `()` | Client; before HUD render each frame |
| `onPostRenderHud` | `()` | Client; after HUD render each frame |
| `renderUIIndicator` | `(px, py, size)` | Client; draw custom radar indicator |
| `render` | `()` | Client; custom screen-space render (non-HUD scripts) |

### Naming / display

| Function | Returns | Notes |
|----------|---------|-------|
| `getName` | `string` | Entity interaction label |
| `getIcon` | `path string` | Entity interaction icon texture path |

### Network sync

| Function | Signature | Notes |
|----------|-----------|-------|
| `sync` | `(data)` | Client receives a server-pushed payload (server calls this via `invokeClientFunction`) |
| `receiveData` | `(...)` | Conventional name for the client-side handler in a fetch/respond RPC pair |

### Sector/player events

| Function | Signature |
|----------|-----------|
| `onSectorEntered` | `(playerIndex, x, y, changeType)` |
| `onSectorLeft` | `(playerIndex, x, y, changeType)` |

---

## Explicit `registerCallback` events

Register these from `initialize()` using `Entity():registerCallback("eventName", "myHandlerName")` (or `Sector()` / `Player()` as appropriate). The handler function is then called by the engine when the event fires.

### Entity events

| Event name | Handler signature | Notes |
|------------|------------------|-------|
| `onDamaged` | `(damager: Entity, damage: number, damageType: integer)` | |
| `onShieldDamaged` | `(damager: Entity, damage: number)` | |
| `onHullHit` | `(damager: Entity)` | |
| `onCollision` | `(entity1: Entity, entity2: Entity)` | |
| `onShotFired` | `(shooter: Entity, weapon)` | |
| `onShotHit` | `(shooter: Entity)` | |
| `onTorpedoLaunched` | `(shooter: Entity, torpedo: Entity)` | |
| `onDestroyed` | `(lastDamageInflictor?: Entity)` | |
| `onBreak` | `()` | Entity broken into pieces |
| `onDockedByEntity` | `(entity: Entity)` | Another entity docked with this one |
| `onEntityDocked` | `(entity: Entity)` | This entity docked with another |
| `onEntityUndocked` | `(entity: Entity)` | |
| `onCraftSeatEntered` | `(player: Player)` | |
| `onCaptainChanged` | `(captain?)` | |
| `onCrewChanged` | `(crew)` | |
| `onPassengerAdded` | `(passenger)` | |
| `onPassengerRemoved` | `(passenger)` | |
| `onPassengersRemoved` | `()` | |
| `onAIStateChanged` | `(newState, oldState)` | AIState enum values |
| `onPlayerEntered` | `(player: Player)` | Player entered the entity (boarded, etc.) |
| `onPlayerLeft` | `(player: Player)` | |
| `onBlockPlanChanged` | `(entityId, allBlocks?: bool)` | Ship plan modified |
| `onCaptainChanged` | `(captain?)` | |
| `onEntityCreated` | `(entity: Entity)` | |
| `onEntityJump` | `()` | |
| `onHyperspaceEntered` | `()` | |
| `onSectorChanged` | `(oldX, oldY, newX, newY)` | Entity moved to new sector |
| `onEntityEntered` | `(entity: Entity)` | Another entity entered the same sector |
| `onSelected` | `()` | Player selected this entity in the UI |
| `onReconstructed` | `()` | |
| `onPlanModifiedByBuilding` | `()` | |
| `onReviveKOShips` | `()` | |

### Player events

| Event name | Notes |
|------------|-------|
| `onPlayerLogIn` | Player connected |
| `onPlayerLogOff` | Player disconnected |
| `onCargoChanged` | `(objectIndex, delta, good)` — cargo changed in player's ship |

### Sector events

Same as entity callbacks plus sector-specific ones. Attach via `Sector():registerCallback(...)`.

---

## Registration example

```lua
function MyScript.initialize()
    local entity = Entity()
    entity:registerCallback("onDamaged", "onMyScriptDamaged")
    entity:registerCallback("onDestroyed", "onMyScriptDestroyed")
end

function MyScript.onMyScriptDamaged(damager, damage, damageType)
    if not onServer() then return end
    -- damager may be nil for environmental damage
end

function MyScript.onMyScriptDestroyed(lastDamageInflictor)
    if not onServer() then return end
end
```

The handler function name must be a **string** matching a function on the same namespace table. The engine calls `MyScript.onMyScriptDamaged(...)` when the event fires.
