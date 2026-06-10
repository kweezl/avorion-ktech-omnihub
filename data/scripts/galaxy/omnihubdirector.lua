package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("utility")      -- GetRelationChangeFromMoney
include("relations")    -- changeRelations
include("goods")        -- the catalog the offline sim prices/sizes goods from
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubOfflineSim = include("lib/omnihub/offlinesim")
local OmniHubLog        = include("lib/omnihub/log")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHubDirector
-- Galaxy script (one instance galaxy-wide, attached via Galaxy():addScriptOnce from a hub's server
-- initialize). Keeps offline OmniHubs producing AND trading while their sectors are unloaded:
--   * registry is heartbeat-driven: a hub's heartbeat (~30s while loaded, immediate on load)
--     creates/refreshes its entry with a compact shadow snapshot;
--   * sleep detection: no heartbeat for HEARTBEAT_TIMEOUT -> asleep -> simulated; the offline
--     credit starts at the LAST heartbeat (the snapshot's moment) — live progress after it is
--     discarded on wake, so nothing is double-counted;
--   * simulation: the PURE OmniHubOfflineSim advances production + offline trade waves on the
--     shadow; money settles live against the owner faction (so affordability stays truthful) and
--     relations move with the nearest faction — offline trading is not economically inert;
--   * wake: a loading hub pulls its shadow (synchronous Galaxy():invokeFunction) and is excluded
--     from simulation; cargo write-back happens hub-side, money is NOT re-applied.
-- Time base is an uptime clock accumulated from update(timeStep) and persisted — server downtime
-- is never credited.
OmniHubDirector = {}

local registry = {}   -- id (string) -> { x, y, owner, shadow, lastSeen, lastSim, awake }
local clock    = 0
local debugEnabled = false

local HEARTBEAT_TIMEOUT = 75   -- ~2.5x the hub heartbeat interval: two missed beats = asleep
local SIM_INTERVAL      = 30   -- how often an asleep hub is visited (latency, not outcome)

-- Lazy goods catalog view for the pure sim: name -> {price, size}.
local catalog = setmetatable({}, { __index = function(t, name)
    local g = goods[name]
    local v = g and { price = g.price, size = g.size or 1 } or nil
    rawset(t, name, v)
    return v
end })

local function dlog(fmt, ...)
    OmniHubLog.debug(debugEnabled, "director: " .. fmt, ...)
end

function OmniHubDirector.getUpdateInterval()
    return 5
end

local function simRng()
    return {
        test     = function(_, p) return math.random() < p end,
        random01 = function() return math.random() end,
    }
end

local function simulateHub(id, e)
    local elapsed = clock - e.lastSim
    e.lastSim = clock
    if not e.shadow then return end

    local owner = Faction(e.owner)
    if not owner then
        registry[id] = nil
        return
    end

    local paid, received = 0, 0
    local env = {
        tryPay = function(cost)
            if cost <= 0 then return true end
            if not owner:canPayMoney(cost) then return false end
            owner:pay("Your OmniHub bought goods while you were away."%_T, cost)
            paid = paid + cost
            return true
        end,
        receive = function(amount)
            if amount <= 0 then return end
            owner:receive("Your OmniHub sold goods while you were away."%_T, amount)
            received = received + amount
        end,
    }

    local report = OmniHubOfflineSim.simulate(e.shadow, elapsed,
        OmniHubModuleDefs.resolveRecipe, catalog, simRng(), env)

    -- Offline trades move standing like online ones; batched per visit, scaled by traded value.
    local traded = paid + received
    if traded > 0 then
        local counter = Galaxy():getNearestFaction(e.x, e.y)
        if counter and counter.index ~= owner.index then
            changeRelations(owner, counter, GetRelationChangeFromMoney(traded),
                RelationChangeType.GoodsTrade)
        end
    end

    if report.trades > 0 or report.waves > 0 then
        dlog("hub %s: +%ss offline, %d wave(s), %d trade(s), paid %s, received %s",
            id, tostring(math.floor(elapsed)), report.waves, report.trades,
            tostring(math.floor(paid)), tostring(math.floor(received)))
    end

    report.paid, report.received = paid, received
    return report
end

function OmniHubDirector.update(timeStep)
    clock = clock + timeStep

    for id, e in pairs(registry) do
        if e.awake and clock - e.lastSeen > HEARTBEAT_TIMEOUT then
            e.awake  = false
            -- Offline credit starts at the snapshot's moment: live progress between the last
            -- heartbeat and the actual unload is re-simulated, never double-counted.
            e.lastSim = e.lastSeen
            dlog("hub %s fell asleep (last seen %ss ago)", id, tostring(math.floor(clock - e.lastSeen)))
        end
        if not e.awake and clock - e.lastSim >= SIM_INTERVAL then
            simulateHub(id, e)
        end
    end
end

-- ── Hub-facing surface (server-side Galaxy():invokeFunction; no network involved) ──

-- Heartbeat = registration + publish: refreshes the entry with a full compact snapshot.
function OmniHubDirector.heartbeat(entry)
    if not entry or not entry.id then return end
    local e = registry[entry.id] or {}
    registry[entry.id] = e
    e.x, e.y   = entry.x, entry.y
    e.owner    = entry.owner
    e.shadow   = entry.shadow
    e.awake    = true
    e.lastSeen = clock
    e.lastSim  = clock
end

-- Wake: called by a hub when its sector loads. Marks it awake (excluded from simulation) and
-- returns the shadow so the hub can write the offline result into real cargo. Money is NOT
-- returned/re-applied — it was settled live during simulation.
function OmniHubDirector.wake(id)
    local e = registry[id]
    if not e then return nil end
    e.awake    = true
    e.lastSeen = clock
    e.lastSim  = clock
    dlog("hub %s woke", tostring(id))
    return e.shadow
end

function OmniHubDirector.remove(id)
    if id and registry[id] then
        registry[id] = nil
        dlog("hub %s removed", tostring(id))
    end
end

-- Dev visibility helpers (server-side; e.g. via /run-style tooling or future dev UI).
function OmniHubDirector.getStats()
    local total, awake = 0, 0
    for _, e in pairs(registry) do
        total = total + 1
        if e.awake then awake = awake + 1 end
    end
    return { total = total, awake = awake, asleep = total - awake, clock = clock }
end

function OmniHubDirector.setDebug(enabled)
    debugEnabled = enabled and true or false
end

-- DEV/TEST hook (/omnihub-director simulate N): advance EVERY registered hub's shadow by N
-- seconds right now, regardless of awake state — exercises the whole offline path (sim, money,
-- relations) without needing the sector to actually unload (useful when aliveSectorsPerPlayer
-- keeps everything loaded). Money settles for real; an AWAKE hub's next heartbeat (<=30s)
-- re-snapshots its shadow, so for loaded hubs this is a transient probe. Dev-gated by the command.
function OmniHubDirector.debugSimulate(seconds)
    seconds = tonumber(seconds) or 300
    local hubs, waves, trades, paid, received = 0, 0, 0, 0, 0
    for id, e in pairs(registry) do
        e.lastSim = clock - seconds
        local r = simulateHub(id, e)
        if r then
            hubs     = hubs + 1
            waves    = waves + r.waves
            trades   = trades + r.trades
            paid     = paid + (r.paid or 0)
            received = received + (r.received or 0)
        end
    end
    return { hubs = hubs, waves = waves, trades = trades, paid = paid, received = received,
             seconds = seconds }
end

-- ── Persistence ──

function OmniHubDirector.secure()
    return { registry = registry, clock = clock, debugEnabled = debugEnabled }
end

function OmniHubDirector.restore(data)
    data = data or {}
    registry     = data.registry or {}
    clock        = data.clock or 0
    debugEnabled = data.debugEnabled or false
    -- All hubs start asleep after a restart; loaded hubs re-mark themselves via their first
    -- heartbeat (the controller pings on its first update tick after load).
    for _, e in pairs(registry) do
        e.awake = false
        -- Clamp stale stamps defensively (the clock only moves while the server runs).
        if e.lastSeen > clock then e.lastSeen = clock end
        if e.lastSim  > clock then e.lastSim  = clock end
    end
end

return OmniHubDirector
