package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("utility")
include("randomext")
include("goods")
include("galaxy")
local AsyncShipGenerator = include("asyncshipgenerator")

-- namespace OmniHubTraderFleet
-- SERVER-ONLY engine glue for the wave model (multi-good mixed traders; see
-- docs/superpowers/specs/2026-06-10-npc-multi-trader-exploration.md). Spawning is modeled on
-- vanilla TradingUtility.spawnTrader's ship branch; counting is the wave gate's live scan. All
-- decisions (what to trade, how to pack ships, when to gate) live in the pure
-- OmniHubTradingDecision module — this file only touches the engine.
OmniHubTraderFleet = {}

-- Our mixed-trader ship script (entry style matches vanilla's "merchants/tradeship.lua").
OmniHubTraderFleet.SHIP_SCRIPT = "merchants/omnihubtradeship.lua"

-- Live count of traders currently serving `station`: vanilla ambient tradeships AND our mixed
-- traders, both matched by the engine-standard trade_partner entity value. Derived every call —
-- never a stored counter — so destroyed ships can't leak the wave gate.
function OmniHubTraderFleet.countTraders(station)
    local sector = Sector()
    local target = station.index.string
    local count  = 0
    for _, script in pairs({ "merchants/tradeship.lua", OmniHubTraderFleet.SHIP_SCRIPT }) do
        for _, ship in pairs({ sector:getEntitiesByScript(script) }) do
            if ship:getValue("trade_partner") == target then count = count + 1 end
        end
    end
    return count
end

-- Vanilla per-ship value cap (sector richness x 750k). The 20% chance of a 1-5x high-value ship
-- is rolled per ship inside planWave, mirroring spawnTrader's maxValue boost.
function OmniHubTraderFleet.shipValueCap()
    local x, y = Sector():getCoordinates()
    return Balancing_GetSectorRichnessFactor(x, y, 50) * 750000
end

-- Spawns one mixed trader per manifest (vanilla spawnTrader's guards, faction choice and ~1500m
-- spawn distance). Sellers' cargo is loaded from the manifest's deliveries; the ship script gets
-- (stationId, tradeScriptPath, manifest). Returns the number of ships actually requested.
function OmniHubTraderFleet.spawnWave(station, manifests, scriptPath, namespace)
    local sector = Sector()
    if sector:getValue("war_zone") then return 0 end
    if sector:getValue("no_trade_zone") then return 0 end

    local tradingFaction = Galaxy():getNearestFaction(sector:getCoordinates())
    local eradicated = getGlobal("eradicated_factions") or {}
    if eradicated[tradingFaction.index] == true then return 0 end
    if tradingFaction:getRelations(station.factionIndex) < -40000 then return 0 end

    local stationId = station.id
    local spawned   = 0

    for _, manifest in ipairs(manifests) do
        local pos    = random():getDirection() * 1500
        local matrix = MatrixLookUpPosition(normalize(-pos), vec3(0, 1, 0), pos)

        local onGenerated = function(ship)
            -- The generation is async: the hub may be gone by the time the ship exists.
            local liveStation = Sector():getEntity(stationId)
            if not liveStation then
                Sector():deleteEntity(ship)
                return
            end

            ship:setValue("trade_partner", stationId.string)

            for _, d in ipairs(manifest.deliveries or {}) do
                local g    = goods[d.name]
                local good = g and g:good()
                if good then ship:addCargo(good, d.amount) end
            end

            ship:addScript(OmniHubTraderFleet.SHIP_SCRIPT, stationId, scriptPath, manifest)
        end

        AsyncShipGenerator(namespace, onGenerated):createFreighterShip(tradingFaction, matrix)
        spawned = spawned + 1
    end

    return spawned
end

return OmniHubTraderFleet
