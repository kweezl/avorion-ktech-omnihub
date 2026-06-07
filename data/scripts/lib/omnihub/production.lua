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

-- Seconds to complete one production cycle for a recipe.
-- Mirrors OmniHub.computeTimeToProduce; reads good prices/levels from the supplied goodsTable.
function OmniHubProduction.timeToProduce(recipe, goodsTable, capacity, minTime)
    if not recipe then return minTime end

    local totalValue = 0
    local totalLevel = 0
    local samples    = 0

    local function accumulate(name, amount)
        local g = goodsTable[name]
        if g then
            totalValue = totalValue + g.price * amount
            totalLevel = totalLevel + (g.level or 0)
            samples    = samples + 1
        end
    end

    for _, res in pairs(recipe.results) do
        accumulate(res.name, res.amount)
    end
    if recipe.garbages then
        for _, gar in pairs(recipe.garbages) do
            accumulate(gar.name, gar.amount)
        end
    end

    local avgLevel   = samples > 0 and (totalLevel / samples) or 0
    local levelBonus = 1 + avgLevel / 100
    local cap        = math.max(1, capacity or 1)
    return math.max(minTime, totalValue / cap / levelBonus)
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
--   query.getGoodSize(name)        -> cargo size per unit of a good
--   query.getMaxStock(name, size)  -> max stock allowed for a good
--   query.freeCargoSpace           -> free cargo space (snapshot value)
-- Returns { canProduce = bool, boosted = bool }. Ingredient consumption is left to the caller.
function OmniHubProduction.canStartCycle(recipe, count, query)
    local boosted = false

    for _, ing in pairs(recipe.ingredients) do
        local need = ing.amount * count
        local have = query.getNumGoods(ing.name)
        if ing.optional == 0 and have < need then
            return {canProduce = false, boosted = false}
        end
        if ing.optional == 1 and have >= need then
            boosted = true
        end
    end

    for _, res in pairs(recipe.results) do
        local size     = query.getGoodSize(res.name)
        local newAmt   = query.getNumGoods(res.name) + res.amount * count
        local maxStock = query.getMaxStock(res.name, size)
        if newAmt > maxStock or query.freeCargoSpace < res.amount * count * size then
            return {canProduce = false, boosted = boosted}
        end
    end

    return {canProduce = true, boosted = boosted}
end

-- Theoretical MAX per-good throughput (units per minute) at full utilisation, for the Goods tab's
-- "actual/max" rates. For each installed module, rate = amount * count / cycleTime; summed per good
-- across all modules. `timeToProduce[key]` is the per-module cycle time (falls back to minTime).
-- Returns { produced = { [name] = perMin }, consumed = { [name] = perMin } }.
function OmniHubProduction.maxRates(installed, resolveRecipe, timeToProduce, minTime)
    local produced, consumed = {}, {}
    minTime = minTime or 15

    for key, count in pairs(installed) do
        local prod = resolveRecipe(key)
        if prod then
            local tt = (timeToProduce and timeToProduce[key]) or minTime
            if tt <= 0 then tt = minTime end
            local perMin = 60 / tt

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
