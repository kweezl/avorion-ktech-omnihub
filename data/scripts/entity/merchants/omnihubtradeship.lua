package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/entity/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("ai/trade")
include("randomext")
local OmniHubTradingDecision = include("lib/omnihub/tradingdecision")

-- OmniHub mixed trader (structure mirrors vanilla merchants/tradeship.lua, a thin shell over
-- ai/trade). One ship both DELIVERS ingredients and PICKS UP products in a single dock visit,
-- driven by a manifest planned by OmniHubTradingDecision.planWave. Two deliberate behaviors:
--   * transaction order is deliveries-then-pickups (selling our cargo first frees the hold);
--   * a TTL watchdog forces the fly-out of a stuck ship (failed dock loop, drifting), so a zombie
--     removes ITSELF from the hub's wave gate instead of wedging trading (the A3 failure mode).

local manifest
local age = 0
local TTL = 600  -- seconds; comfortably above a normal round-trip (fly in + dock queue + 40s wait + fly out)

local initializeAI   = initialize
local updateServerAI = updateServer
local restoreAI      = restore
local secureAI       = secure

function initialize(stationIndex_in, script_in, manifest_in)
    initializeAI(stationIndex_in, script_in)
    manifest = manifest_in or { deliveries = {}, pickups = {} }
end

-- Docked exchange. Each buyFromShip/sellToShip call fires the hub's onTradingManager* callbacks,
-- so statistics record one transaction per good with no extra wiring.
function doTransaction(ship, station, script)
    for _, op in ipairs(OmniHubTradingDecision.transactionList(manifest)) do
        if op.kind == "deliver" then
            station:invokeFunction(script, "buyFromShip", ship.index, op.name, op.amount, true)
        else
            station:invokeFunction(script, "sellToShip", ship.index, op.name, op.amount, true)
        end
    end
end

function onTradingFinished(ship)
    startFlyAway(ship)
end

function startFlyAway(ship)
    -- player crafts should NEVER fly away since this will DELETE the ship (vanilla guard)
    local faction = Faction()
    if faction and (faction.isPlayer or faction.isAlliance) then
        print("Warning: A player craft wanted to enter trader fly away stage")
        terminate()
        return
    end

    ship:addScript("ai/passsector.lua", random():getDirection() * 1500)
    terminate()
end

function updateServer(timeStep)
    age = age + timeStep
    if OmniHubTradingDecision.shouldFlyOut(age, TTL) then
        startFlyAway(Entity())
        return
    end
    updateServerAI(timeStep)
end

function restore(data)
    restoreAI(data.ai)
    manifest = data.manifest or { deliveries = {}, pickups = {} }
    age = data.age or 0
end

function secure()
    return { ai = secureAI(), manifest = manifest, age = age }
end
