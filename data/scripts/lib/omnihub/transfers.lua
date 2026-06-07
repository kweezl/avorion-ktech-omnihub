package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
include("randomext")  -- shuffle, randomEntry
local TradingUtility = include("tradingutility")
local OmniHubTrading = include("trading")  -- pure partnerLabel formatter

-- namespace OmniHubTransfers
-- Server-side inter-station transfer logic: deliver the hub's products to neighbour stations that buy
-- them, and fetch the hub's resources from neighbour stations that sell them. Ported from
-- factory.lua (updateDeliveryToOtherStations / updateFetchingFromOtherStations / refreshConfigCombos)
-- but driven by OmniHub's aggregatedProduction and a FIXED transport volume (no shuttle upgrades).
-- Engine-coupled: only ever loaded in the server entity VM, where Entity()/Sector()/goods are ambient.
-- The `hub` argument is a thin interface onto the OmniHub namespace so this module needs no globals
-- of its own:  hub.getSoldGoodByName(name), hub.getStock(name) -> stock,maxStock,
-- hub.decreaseGoods(name, amount), and the optional hub.recordTxn(txn) statistics hook.
OmniHubTransfers = {}

-- Builds the display option list ({ {id=idString, name=...}, ... }, name-sorted) for a partner map.
function OmniHubTransfers.optionList(partners)
    local out = {}
    for id in pairs(partners) do
        local station = Sector():getEntity(id)
        if station then
            -- Pure, nil-guarded label builder (some stations have no translatedTitle and some
            -- factions a nil translatedName — concatenating nil here previously crashed sendHubConfig).
            local faction = Faction(station.factionIndex)
            local fname   = faction and (faction.translatedName or faction.name)
            local label   = OmniHubTrading.partnerLabel(station.translatedTitle or station.title, station.name, fname)
            out[#out + 1] = { id = id, name = label }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Scans the sector for stations that can trade the hub's goods. Returns:
--   delivered  = { [idString] = { {good=name, script=path}, ... } }  -- stations that BUY our products
--   delivering = { [idString] = { {good=name, script=path}, ... } }  -- stations that SELL our resources
--   deliveredOptions, deliveringOptions  -- display lists for the client combo boxes
-- `agg` is OmniHub's aggregatedProduction (nil-safe).
function OmniHubTransfers.collectPartners(agg)
    local delivered, delivering = {}, {}
    if not agg then return delivered, delivering, {}, {} end

    local self     = Entity()
    local stations = { Sector():getEntitiesByType(EntityType.Station) }

    for _, station in pairs(stations) do
        if station.id ~= self.id then
            -- stations that SELL our ingredients -> we can fetch from them
            for _, ing in ipairs(agg.ingredients) do
                local script = TradingUtility.getEntitySellsGood(station, ing.name)
                if script then
                    local t = delivering[station.id.string] or {}
                    t[#t + 1] = { good = ing.name, script = script }
                    delivering[station.id.string] = t
                end
            end
            -- stations that BUY our products/garbage -> we can deliver to them
            for _, list in ipairs({ agg.results, agg.garbages }) do
                for _, good in ipairs(list) do
                    local script = TradingUtility.getEntityBuysGood(station, good.name)
                    if script then
                        local t = delivered[station.id.string] or {}
                        t[#t + 1] = { good = good.name, script = script }
                        delivered[station.id.string] = t
                    end
                end
            end
        end
    end

    return delivered, delivering,
        OmniHubTransfers.optionList(delivered), OmniHubTransfers.optionList(delivering)
end

-- Delivers one batch of the hub's products to a chosen partner station that buys them.
-- `chosen` = { [idString] = { {good, script}, ... } } (the player's selected delivery targets).
-- Returns an errors map { [idString] = message } for the config tab. One successful transfer per call
-- (matches vanilla cadence).
function OmniHubTransfers.deliver(hub, chosen, transportVolume, dockedOnly)
    local errors = {}
    local sector = Sector()
    local self   = Entity()

    local ids = {}
    for id, trades in pairs(chosen) do
        if #trades > 0 then ids[#ids + 1] = id end
    end
    shuffle(random(), ids)

    for _, id in ipairs(ids) do
        local trade   = randomEntry(random(), chosen[id])
        local station = sector:getEntity(id)
        if not station then
            errors[id] = "Error with partner station!"%_t
            goto continue
        end
        if dockedOnly and station.dockingParent ~= self.id and self.dockingParent ~= station.id then
            goto continue
        end

        local ownStock = self:getCargoAmount(trade.good)
        if ownStock == 0 then
            errors[id] = "No more goods!"%_t
            goto continue
        end

        local good = hub.getSoldGoodByName(trade.good)
        if not good then
            errors[id] = "Partner station doesn't buy this!"%_t
            goto continue
        end

        local amount = math.max(1, math.floor(transportVolume / good.size))
        amount = math.min(ownStock, amount)

        local code1, code2, price = station:invokeFunction(trade.script, "buyGoods", good, amount, self.factionIndex, true)
        if code1 ~= 0 then
            errors[id] = "Error with partner station!"%_t
            goto continue
        end
        if code2 ~= 0 then
            errors[id] = "Partner can't accept goods right now."%_t
            goto continue
        end

        if hub.recordTxn then
            hub.recordTxn({ kind = "sell", good = trade.good, amount = amount, price = price, partner = station.translatedTitle })
        end

        station:addCargo(good, amount)
        hub.decreaseGoods(trade.good, amount)
        break
        ::continue::
    end

    return errors
end

-- Fetches one batch of a resource the hub needs from a chosen partner station that sells it.
-- `chosen` = { [idString] = { {good, script}, ... } }. Returns an errors map { [idString] = message }.
function OmniHubTransfers.fetch(hub, chosen, transportVolume, dockedOnly)
    local errors = {}
    local sector = Sector()
    local self   = Entity()

    local ids = {}
    for id, trades in pairs(chosen) do
        if #trades > 0 then ids[#ids + 1] = id end
    end
    shuffle(random(), ids)

    for _, id in ipairs(ids) do
        local trade   = randomEntry(random(), chosen[id])
        local station = sector:getEntity(id)
        if not station then goto continue end
        if dockedOnly and station.dockingParent ~= self.id and self.dockingParent ~= station.id then
            goto continue
        end

        local code, otherStock = station:invokeFunction(trade.script, "getStock", trade.good)
        if code ~= 0 then
            errors[id] = "Error with partner station!"%_t
            goto continue
        end
        if otherStock == 0 then
            errors[id] = "No more goods on partner station!"%_t
            goto continue
        end

        local ownStock, maxAmount = hub.getStock(trade.good)
        if ownStock >= maxAmount then
            errors[id] = "Station at full capacity!"%_t
            goto continue
        end

        local good = goods[trade.good] and goods[trade.good]:good()
        if not good then goto continue end
        if self.freeCargoSpace < good.size then
            errors[id] = "Station at full capacity!"%_t
            goto continue
        end

        local amount = math.max(1, math.floor(transportVolume / good.size))
        amount = math.min(amount, otherStock)

        local code1, code2, price = station:invokeFunction(trade.script, "sellGoods", good, amount, self.factionIndex)
        if code1 ~= 0 then
            errors[id] = "Error with partner station!"%_t
            goto continue
        end
        if code2 ~= 0 then
            errors[id] = "Partner can't provide goods right now."%_t
            goto continue
        end

        if hub.recordTxn then
            hub.recordTxn({ kind = "buy", good = trade.good, amount = amount, price = price, partner = station.translatedTitle })
        end

        self:addCargo(good, amount)
        break
        ::continue::
    end

    return errors
end

return OmniHubTransfers
