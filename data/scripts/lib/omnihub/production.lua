package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubProduction
-- Pure, engine-independent production helpers extracted from omnihubcontroller.lua so they can be
-- unit-tested without loading the full attached entity script (which calls
-- TradingAPI:CreateNamespace()/callable() at file scope). Every function takes its inputs
-- explicitly — no Entity()/goods/TradingAPI access here.
OmniHubProduction = {}

-- Local copy of utility.lua:lerp (data/scripts/lib/utility.lua:4-22) so this module includes nothing.
local function lerp(factor, lowerBound, upperBound, lowerValue, upperValue, allowOverstepping)
    if lowerBound > upperBound then
        lowerBound, upperBound = upperBound, lowerBound
        lowerValue, upperValue = upperValue, lowerValue
    end

    if lowerBound == upperBound then
        return lowerValue
    end

    local value
    if allowOverstepping then
        value = (factor - lowerBound) / (upperBound - lowerBound)
    else
        value = math.min(1.0, math.max(0.0, (factor - lowerBound) / (upperBound - lowerBound)))
    end

    return lowerValue + (upperValue - lowerValue) * value
end

-- Shared by timeToProduce and recommendedCapacity: a recipe's total output value (results +
-- garbages, priced from goodsTable) and the level bonus derived from the same goods.
local function recipeValueAndBonus(recipe, goodsTable)
    local totalValue, totalLevel, samples = 0, 0, 0
    local function accumulate(name, amount)
        local g = goodsTable[name]
        if g then
            totalValue = totalValue + g.price * amount
            totalLevel = totalLevel + (g.level or 0)
            samples    = samples + 1
        end
    end
    for _, res in pairs(recipe.results) do accumulate(res.name, res.amount) end
    if recipe.garbages then
        for _, gar in pairs(recipe.garbages) do accumulate(gar.name, gar.amount) end
    end
    local avgLevel = samples > 0 and (totalLevel / samples) or 0
    return totalValue, 1 + avgLevel / 100
end

-- Seconds to complete one production cycle for a recipe.
-- Mirrors OmniHub.computeTimeToProduce; reads good prices/levels from the supplied goodsTable.
function OmniHubProduction.timeToProduce(recipe, goodsTable, capacity, minTime)
    if not recipe then return minTime end
    local totalValue, levelBonus = recipeValueAndBonus(recipe, goodsTable)
    local cap = math.max(1, capacity or 1)
    return math.max(minTime, totalValue / cap / levelBonus)
end

-- The production capacity above which timeToProduce bottoms out at minTime for EVERY installed
-- module — i.e. the smallest capacity that achieves max production speed. Per module that point
-- is totalValue / (minTime * levelBonus); the hub-wide recommendation is the max across modules
-- (each module ticks its own cycle, so capacity is not shared). Module count is irrelevant
-- (count scales amounts per cycle, not cycle time). Empty hub (or no resolvable recipe) -> 0.
function OmniHubProduction.recommendedCapacity(installed, resolveRecipe, goodsTable, minTime)
    local best = 0
    for key in pairs(installed) do
        local recipe = resolveRecipe(key)
        if recipe then
            local totalValue, levelBonus = recipeValueAndBonus(recipe, goodsTable)
            local needed = totalValue / (minTime * levelBonus)
            if needed > best then best = needed end
        end
    end
    return best
end

-- Probability that the next trader request spawns a seller (vs a buyer).
-- Mirrors factory.lua:1893 / OmniHub.getSellerProbability.
function OmniHubProduction.sellerProbability(buyPriceFactor)
    return lerp(buyPriceFactor, 0.8, 1.2, 0.1, 0.9)
end

-- Merge every installed module's recipe into summed ingredient/result/garbage amounts and a single
-- aggregatedProduction table (mirrors factory.lua's `production`). Excludes the goods:good() /
-- initializeTrading wiring, which stays engine-side in OmniHub.rebuild.
-- `resolveRecipe(key)` returns the raw production table for a module key, or nil.
function OmniHubProduction.aggregate(installed, resolveRecipe)
    local ingAmounts  = {}  -- { [name] = totalAmount }
    local ingOptional = {}  -- { [name] = optional flag (0 or 1) }
    local resAmounts  = {}  -- { [name] = totalAmount }
    local garAmounts  = {}  -- { [name] = totalAmount }
    local hasAny      = false

    for key, count in pairs(installed) do
        local prod = resolveRecipe(key)
        if prod then
            hasAny = true
            for _, ing in pairs(prod.ingredients) do
                ingAmounts[ing.name] = (ingAmounts[ing.name] or 0) + ing.amount * count
                if ingOptional[ing.name] == nil then ingOptional[ing.name] = ing.optional end
            end
            for _, res in pairs(prod.results) do
                resAmounts[res.name] = (resAmounts[res.name] or 0) + res.amount * count
            end
            if prod.garbages then
                for _, gar in pairs(prod.garbages) do
                    garAmounts[gar.name] = (garAmounts[gar.name] or 0) + gar.amount * count
                end
            end
        end
    end

    local aggregatedProduction = nil
    if hasAny then
        local aggIngredients = {}
        local aggResults     = {}
        local aggGarbages    = {}
        for name, amount in pairs(ingAmounts) do
            aggIngredients[#aggIngredients + 1] = {name = name, amount = amount, optional = ingOptional[name] or 0}
        end
        for name, amount in pairs(resAmounts) do
            aggResults[#aggResults + 1] = {name = name, amount = amount}
        end
        for name, amount in pairs(garAmounts) do
            aggGarbages[#aggGarbages + 1] = {name = name, amount = amount}
        end
        aggregatedProduction = {
            ingredients = aggIngredients,
            results     = aggResults,
            garbages    = aggGarbages,
        }
    end

    return {
        ingAmounts           = ingAmounts,
        ingOptional          = ingOptional,
        resAmounts           = resAmounts,
        garAmounts           = garAmounts,
        aggregatedProduction = aggregatedProduction,
        hasAny               = hasAny,
    }
end

-- Decide whether a recipe can start a new cycle, mirroring the affordability checks in
-- OmniHub.tickRecipe. `query` abstracts the engine reads:
--   query.getNumGoods(name)        -> current stock of a good
--   query.getGoodSize(name)        -> cargo size per unit of a good (nil -> treated as 1)
--   query.getMaxStock(name, size)  -> max stock allowed for a good
--   query.freeCargoSpace           -> free cargo space (snapshot value)
-- Returns { canProduce = bool, boosted = bool }. Ingredient consumption is left to the caller.
--
-- Space accounting mirrors vanilla factory.lua (onRestoredFromDisk:269-290): a cycle's NET cargo
-- footprint is outputs (results + garbages) MINUS the non-optional ingredients it consumes (which
-- free their space). Checking the gross result volume alone wrongly blocks ingredient-heavy recipes
-- (e.g. 64 Wheat -> 5 Carbon) when the hold is near-full even though the cycle nets free space.
-- getGoodSize can return nil for a good that's neither bought nor sold (it only scans the trade
-- lists); we default such sizes to 1, matching vanilla's `size = 1` fallback, instead of letting nil
-- propagate into arithmetic and throw — a throw here would abort the whole update() tick.
--
-- On a block, the result also carries a machine-readable `reason` and the offending `good` (plus
-- `needed`/`free` for the space case) so the debug logger can explain WHY a recipe is stalled:
--   "ingredient" -> a required ingredient is below amount*count  (good = its name)
--   "maxstock"   -> a result is already at its reservation cap   (good = its name)
--   "space"      -> not enough free cargo for the net output     (needed/free = the volumes)
function OmniHubProduction.canStartCycle(recipe, count, query)
    local boosted  = false
    local netSpace = 0  -- positive = cycle needs this much free cargo; negative = nets free space

    for _, ing in pairs(recipe.ingredients) do
        local need = ing.amount * count
        local have = query.getNumGoods(ing.name)
        if ing.optional == 0 then
            if have < need then
                return {canProduce = false, boosted = false, reason = "ingredient", good = ing.name}
            end
            -- consumed non-optional ingredients free their space (vanilla counts only these)
            netSpace = netSpace - need * (query.getGoodSize(ing.name) or 1)
        elseif have >= need then
            boosted = true
        end
    end

    for _, res in pairs(recipe.results) do
        local size     = query.getGoodSize(res.name) or 1
        local newAmt   = query.getNumGoods(res.name) + res.amount * count
        local maxStock = query.getMaxStock(res.name, size)
        if newAmt > maxStock then
            return {canProduce = false, boosted = boosted, reason = "maxstock", good = res.name}
        end
        netSpace = netSpace + res.amount * count * size
    end

    if recipe.garbages then
        for _, gar in pairs(recipe.garbages) do
            netSpace = netSpace + gar.amount * count * (query.getGoodSize(gar.name) or 1)
        end
    end

    if netSpace > 0 and query.freeCargoSpace < netSpace then
        return {canProduce = false, boosted = boosted, reason = "space",
                needed = netSpace, free = query.freeCargoSpace}
    end

    return {canProduce = true, boosted = boosted}
end

-- Human-readable one-liner for a canStartCycle decision, used by the controller's debug logger.
-- `decision` is a canStartCycle result, or nil if the recipe hasn't been evaluated yet this run.
function OmniHubProduction.describeStall(decision)
    if not decision then return "idle (not yet evaluated)" end
    if decision.canProduce then return "ready" end
    local r = decision.reason
    if r == "ingredient" then
        return "waiting for ingredient: " .. tostring(decision.good)
    elseif r == "maxstock" then
        return "output at reservation cap: " .. tostring(decision.good)
    elseif r == "space" then
        return string.format("not enough cargo space (need %d, free %d)",
            math.floor(decision.needed or 0), math.floor(decision.free or 0))
    end
    return "blocked"
end

-- Theoretical MAX per-good throughput (units per minute) at full utilisation, for the Goods tab's
-- "actual/max" rates. For each installed module, rate = amount * count / cycleTime; summed per good
-- across all modules. `timeToProduce[key]` is the per-module cycle time (falls back to minTime).
-- Returns { produced = { [name] = perMin }, consumed = { [name] = perMin } }.
-- `boostedByKey` (optional): { [moduleKey] = true } for modules currently running boosted — a
-- boosted cycle advances at 2x (tickRecipe), so the achievable max doubles. Including it keeps the
-- displayed ceiling honest: without it a boosted module's measured rate sits at 200% of "max".
function OmniHubProduction.maxRates(installed, resolveRecipe, timeToProduce, minTime, boostedByKey)
    local produced, consumed = {}, {}
    minTime = minTime or 15

    for key, count in pairs(installed) do
        local prod = resolveRecipe(key)
        if prod then
            local tt = (timeToProduce and timeToProduce[key]) or minTime
            if tt <= 0 then tt = minTime end
            local perMin = 60 / tt
            if boostedByKey and boostedByKey[key] then perMin = perMin * 2 end

            for _, res in pairs(prod.results) do
                produced[res.name] = (produced[res.name] or 0) + res.amount * count * perMin
            end
            if prod.garbages then
                for _, gar in pairs(prod.garbages) do
                    produced[gar.name] = (produced[gar.name] or 0) + gar.amount * count * perMin
                end
            end
            for _, ing in pairs(prod.ingredients) do
                consumed[ing.name] = (consumed[ing.name] or 0) + ing.amount * count * perMin
            end
        end
    end

    return { produced = produced, consumed = consumed }
end

-- Clamps an install/uninstall request to what's actually available: the player's held/installed stock
-- and any remaining capacity (pass math.huge when uncapped). Returns the count to apply, an integer
-- >= 0 (0 means "skip"). This is the "do the requested amount, or fall back to the real amount" rule.
function OmniHubProduction.clampInstall(requested, available, capRemaining)
    local n = math.min(requested or 0, available or 0, capRemaining or math.huge)
    if n < 0 then n = 0 end
    return math.floor(n)
end

-- Roll which installed modules drop when the station is destroyed.
-- Pure: rolls once per installed unit at `dropChance` using `rng` (an object exposing
-- `:test(probability)`, like the engine's Random). Returns a flat list of module keys to drop
-- (one entry per surviving roll; repeats allowed). The caller turns each key into a
-- VanillaInventoryItem and hands it to Sector():dropVanillaItem — those engine calls stay out of here.
function OmniHubProduction.rollDrops(installed, dropChance, rng)
    local drops = {}
    for key, count in pairs(installed) do
        for _ = 1, count do
            if rng:test(dropChance) then
                drops[#drops + 1] = key
            end
        end
    end
    return drops
end

return OmniHubProduction
