package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubProduction      = include("lib/omnihub/production")
local OmniHubTradingDecision = include("lib/omnihub/tradingdecision")

-- namespace OmniHubOfflineSim
-- PURE offline hub simulator (no engine reads): the galaxy director feeds it a hub's SHADOW state
-- and an elapsed server-uptime span; it advances production and runs offline trade WAVES against
-- the shadow, mutating it in place. Decisions are the SAME pure functions the online executor
-- uses (OmniHubProduction.canStartCycle, OmniHubTradingDecision.planWave) — nothing about
-- trade/production decisions is written twice.
--
-- shadow = {
--   installed   = { key -> count },            ttm      = { key -> seconds (heartbeat snapshot) },
--   progress    = { key -> {progress,boosted} },
--   inventory   = { name -> amount },          freeSpace = number (cargo volume budget),
--   tradeCaps   = { name -> getMaxGoods },     stockCaps = { name -> getMaxStock },
--   sold        = { {name, tier}, ... },       -- sell-marked pickup list (buildSoldPickupList)
--   buyFactor / sellFactor, activelyRequest / activelySell,
--   flags = { war, noTrade },                  -- last-known sector flags (Case D)
--   cfg   = { wavePeriod, maxShips, shipValue }, -- snapshotted at heartbeat; wavePeriod =
--                                                -- online cooldown x offline multiplier (covers
--                                                -- the docking latency online waves pay)
--   waveTimer = number,
-- }
-- catalog = { name -> {price, size} } ; env = { tryPay(cost)->bool, receive(amount) }.
--
-- Offline waves use the SHIP regime's amounts (full deliveries, optimistic pickups clamped to
-- stock at APPLY time, like sellToShip clamps at dock time) — not immediate mode's x0.3 — because
-- the slower wavePeriod already models the ship round-trip.
OmniHubOfflineSim = {}

local BASE_DT   = 30   -- target sub-step; elapsed is split into n <= MAX_STEPS steps of >= this
local MAX_STEPS = 240  -- per-visit ceiling: very long sleeps coarsen dt instead of unbounded work

-- Query over the shadow, same interface the online decisions read through.
local function shadowQuery(shadow, catalog)
    return {
        getNumGoods = function(name) return shadow.inventory[name] or 0 end,
        getMaxGoods = function(name) return shadow.tradeCaps[name] or 0 end,
        getMaxStock = function(name) return shadow.stockCaps[name] or 0 end,
        goodPrice   = function(name) local c = catalog[name]; return c and c.price end,
        getGoodSize = function(name) local c = catalog[name]; return (c and c.size) or 1 end,
    }
end

local function addStock(shadow, catalog, name, amount)
    local size  = (catalog[name] and catalog[name].size) or 1
    local cap   = shadow.stockCaps[name] or 0
    local have  = shadow.inventory[name] or 0
    amount = math.min(amount, math.max(0, cap - have))
    if size > 0 then amount = math.min(amount, math.floor(shadow.freeSpace / size)) end
    if amount <= 0 then return 0 end
    shadow.inventory[name] = have + amount
    shadow.freeSpace = shadow.freeSpace - amount * size
    return amount
end

local function removeStock(shadow, catalog, name, amount)
    local size = (catalog[name] and catalog[name].size) or 1
    local have = shadow.inventory[name] or 0
    amount = math.min(amount, have)
    if amount <= 0 then return 0 end
    shadow.inventory[name] = have - amount
    shadow.freeSpace = shadow.freeSpace + amount * size
    return amount
end

-- Advances one module key by `dt`, allowing multiple cycle completions and restarts within the
-- step (mirrors tickRecipe's math without its one-cycle-per-tick granularity, so throughput is
-- step-size invariant). The production query is shared with canStartCycle.
local function produceStep(shadow, key, count, dt, resolveRecipe, catalog, query)
    local recipe = resolveRecipe(key)
    if not recipe then return end
    local ttm = shadow.ttm[key] or 15
    if ttm <= 0 then ttm = 15 end

    local remaining = dt
    while remaining > 0 do
        local progress = shadow.progress[key]
        if progress then
            local speed    = progress.boosted and 2 or 1
            local needTime = (1.0 - (progress.progress or 0)) * ttm / speed
            if needTime > remaining then
                progress.progress = (progress.progress or 0) + remaining * speed / ttm
                return
            end
            remaining = remaining - needTime
            for _, res in pairs(recipe.results) do
                addStock(shadow, catalog, res.name, res.amount * count)
            end
            for _, gar in pairs(recipe.garbages or {}) do
                addStock(shadow, catalog, gar.name, gar.amount * count)
            end
            shadow.progress[key] = nil
        else
            local decision = OmniHubProduction.canStartCycle(recipe, count, {
                getNumGoods    = query.getNumGoods,
                getGoodSize    = query.getGoodSize,
                getMaxStock    = function(name, size) return query.getMaxStock(name) end,
                freeCargoSpace = shadow.freeSpace,
            })
            if not decision.canProduce then return end
            for _, ing in pairs(recipe.ingredients) do
                removeStock(shadow, catalog, ing.name, ing.amount * count)
            end
            shadow.progress[key] = { progress = 0, boosted = decision.boosted }
        end
    end
end

-- One offline wave: plan with the shared planner against the evolving shadow, then apply each
-- manifest's ops with the same clamps the online docked path enforces (buyFromShip's room check,
-- sellToShip's stock clamp) and the owner's affordability via env.tryPay.
local function runWave(shadow, resolveRecipe, catalog, rng, env, query, report)
    if shadow.flags.war or shadow.flags.noTrade then return end

    local agg = OmniHubProduction.aggregate(shadow.installed, resolveRecipe)
    local production = agg.aggregatedProduction

    local sides = {
        ingredients = (shadow.activelyRequest and production) and production.ingredients or {},
        -- {name, tier} pickup list snapshotted at heartbeat (a pre-update shadow lacks it:
        -- no offline pickups for that hub until its next heartbeat — harmless, no migration).
        -- A module-less trading hub has no production but still sells its tier-1 goods
        -- (parity with the online requestTraders gate).
        sold        = shadow.activelySell and shadow.sold or {},
    }

    local manifests = OmniHubTradingDecision.planWave(sides, query, rng, {
        maxShips  = shadow.cfg.maxShips,
        shipValue = shadow.cfg.shipValue,
        immediate = false,  -- ship-regime amounts; the wavePeriod models the round-trip
    })

    for _, manifest in ipairs(manifests) do
        for _, op in ipairs(OmniHubTradingDecision.transactionList(manifest)) do
            local price = (catalog[op.name] and catalog[op.name].price) or 0
            if op.kind == "deliver" then
                local room = math.max(0, (shadow.tradeCaps[op.name] or 0) - (shadow.inventory[op.name] or 0))
                local size = (catalog[op.name] and catalog[op.name].size) or 1
                local amount = math.min(op.amount, room)
                if size > 0 then amount = math.min(amount, math.floor(shadow.freeSpace / size)) end
                local cost = amount * price * shadow.buyFactor
                if amount > 0 and env.tryPay(cost) then
                    addStock(shadow, catalog, op.name, amount)
                    report.trades = report.trades + 1
                end
            else
                local amount = removeStock(shadow, catalog, op.name, op.amount)
                if amount > 0 then
                    env.receive(amount * price * shadow.sellFactor)
                    report.trades = report.trades + 1
                end
            end
        end
    end
end

-- Advances the shadow by `elapsed` seconds of server uptime. Returns a report
-- {steps, waves, trades}; money flows through env so the caller settles it live (which keeps
-- env.tryPay truthful as the owner's balance moves).
function OmniHubOfflineSim.simulate(shadow, elapsed, resolveRecipe, catalog, rng, env)
    local report = { steps = 0, waves = 0, trades = 0 }
    if not elapsed or elapsed <= 0 then return report end

    local n  = math.max(1, math.min(MAX_STEPS, math.ceil(elapsed / BASE_DT)))
    local dt = elapsed / n
    report.steps = n

    local query = shadowQuery(shadow, catalog)

    for _ = 1, n do
        for key, count in pairs(shadow.installed) do
            produceStep(shadow, key, count, dt, resolveRecipe, catalog, query)
        end

        shadow.waveTimer = (shadow.waveTimer or 0) + dt
        while shadow.waveTimer >= shadow.cfg.wavePeriod do
            shadow.waveTimer = shadow.waveTimer - shadow.cfg.wavePeriod
            report.waves = report.waves + 1
            runWave(shadow, resolveRecipe, catalog, rng, env, query, report)
        end
    end

    return report
end

return OmniHubOfflineSim
