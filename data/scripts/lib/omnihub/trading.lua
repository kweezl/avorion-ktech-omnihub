package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubTrading
-- Pure, engine-independent helpers that turn the aggregated production (OmniHubProduction.aggregate)
-- plus the player's per-good sell/buy marks into the bought/sold name lists OmniHub.rebuild feeds to
-- initializeTrading, and classify a good as produced/consumed for the Production/Resources tabs.
-- No Entity()/goods/TradingAPI access here — every input is passed explicitly.
OmniHubTrading = {}

-- True if the good is produced (result or garbage) / consumed (ingredient) by the aggregate.
function OmniHubTrading.isProduced(agg, name)
    return (agg.resAmounts[name] ~= nil) or (agg.garAmounts[name] ~= nil)
end
function OmniHubTrading.isConsumed(agg, name)
    return agg.ingAmounts[name] ~= nil
end

-- Resolves the per-good Buy/Sell marks into the bought/sold name lists OmniHub.rebuild feeds to
-- initializeTrading. Marks are EXPLICIT: a good is traded only when the player has ticked it on
-- (sellEnabled[name] == true / buyEnabled[name] == true) in the Goods tab — there is NO role-based
-- default, so installing/uninstalling modules never changes what's bought or sold. Names are sorted
-- for stable UI.
function OmniHubTrading.buildTradeLists(sellEnabled, buyEnabled)
    local function onNames(map)
        local list = {}
        for name, v in pairs(map or {}) do
            if v == true then list[#list + 1] = name end
        end
        table.sort(list)
        return list
    end

    return {
        soldNames   = onNames(sellEnabled),
        boughtNames = onNames(buyEnabled),
    }
end

-- Classifies a good against an aggregate: isProduced if it appears as a result or garbage, isConsumed
-- if it appears as an ingredient. Both can be true (a good produced here AND used as an internal
-- ingredient).
function OmniHubTrading.classifyGood(name, agg)
    return {
        isProduced = OmniHubTrading.isProduced(agg, name),
        isConsumed = OmniHubTrading.isConsumed(agg, name),
    }
end

-- Stores the player's EXPLICIT Buy/Sell mark for a good (true or false). Absent = role default (see
-- buildTradeLists). Trading-station mode needs explicit true (to opt a non-produced/consumed good in),
-- so unlike the old sparse map we store the boolean as given.
function OmniHubTrading.setMark(map, name, enabled)
    map[name] = enabled
    return map
end

-- Builds the set of goods the hub may list/trade: every name appearing in any production's
-- ingredients, results, or garbages — i.e. goods that are part of a production chain. Pass the
-- ambient `productions` array (vanilla productionsindex; includes mines and modded productions).
-- This deliberately excludes catalog goods no production touches: ores, rift ores/loot, salvage
-- scrap (Scrap Iron..Avorion — NOT the produced good "Scrap Metal", which stays in) and illegal
-- goods. All three part lists matter: Diamond/Gem are ingredient-only, Toxic Waste is garbage-only.
function OmniHubTrading.buildTradeableSet(productions)
    local set = {}
    for _, prod in ipairs(productions or {}) do
        for _, part in ipairs({ prod.ingredients, prod.results, prod.garbages }) do
            for _, item in ipairs(part or {}) do
                set[item.name] = true
            end
        end
    end
    return set
end

-- Drops marks whose good is not in the tradeable set (e.g. an ore marked before the
-- production-chain filter existed): a stale mark would otherwise keep trading the good
-- invisibly via buildTradeLists. Returns a new map with only tradeable-good marks.
function OmniHubTrading.pruneMarks(map, tradeable)
    local out = {}
    for name, v in pairs(map or {}) do
        if tradeable[name] then out[name] = v end
    end
    return out
end

-- Resolves a goods-catalog KEY to the good's real (TradingGood) name. Vanilla goods.lua defines
-- backwards-compatibility alias keys whose key differs from the good's name (goods["Aluminium"] =
-- goods["Aluminum"], goods["Silicium"] = goods["Silicon"]). Marks — and everything derived from
-- them (trade lists, max-limit caps) — must be keyed by the real name, because every runtime
-- lookup (trader.getMaxStock, stock sync, UI rows) goes through TradingGood.name. A name not in
-- the catalog (or a nil catalog) passes through unchanged.
function OmniHubTrading.canonicalName(name, catalog)
    local g = catalog and catalog[name]
    return (type(g) == "table" and g.name) or name
end

return OmniHubTrading
