package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest = include("lib/omnihub/tests/framework")
local Sim         = include("lib/omnihub/offlinesim")

local eq   = OmniHubTest.assertEqual
local near = OmniHubTest.assertNear
local tru  = OmniHubTest.assertTrue
local notn = OmniHubTest.assertNotNil

-- One module: 2 ore (+1 optional catalyst for boost) -> 1 plate.
local RECIPES = {
    mod = {
        ingredients = { { name = "ore", amount = 2, optional = 0 },
                        { name = "cat", amount = 1, optional = 1 } },
        results     = { { name = "plate", amount = 1 } },
        garbages    = {},
    },
}
local function resolveRecipe(key) return RECIPES[key] end

local CATALOG = {
    ore   = { price = 50,   size = 1 },
    cat   = { price = 10,   size = 1 },
    plate = { price = 200,  size = 1 },
}

-- Deterministic rng (same contract as wave_spec): test() fixed, random01() = 0.5.
local function rng(testResult)
    return {
        test     = function(_, _) return testResult end,
        random01 = function() return 0.5 end,
    }
end

-- env stub with a ledger; afford = false simulates a broke owner.
local function env(afford)
    local e = { paid = 0, received = 0 }
    e.tryPay = function(cost)
        if afford == false then return false end
        e.paid = e.paid + cost
        return true
    end
    e.receive = function(amount) e.received = e.received + amount end
    return e
end

-- Fresh shadow; override fields via `o`.
local function shadow(o)
    o = o or {}
    return {
        installed  = o.installed or { mod = 1 },
        ttm        = o.ttm or { mod = 30 },
        progress   = o.progress or {},
        inventory  = o.inventory or {},
        tradeCaps  = o.tradeCaps or {},
        stockCaps  = o.stockCaps or { plate = 1000000, ore = 1000000, cat = 1000000 },
        freeSpace  = o.freeSpace or 1000000,
        buyFactor  = o.buyFactor or 1.0,
        sellFactor = o.sellFactor or 1.0,
        activelyRequest = (o.activelyRequest ~= false),
        activelySell    = (o.activelySell ~= false),
        flags      = o.flags or {},
        cfg        = o.cfg or { wavePeriod = 100000, maxShips = 3, shipValue = 1e12 },
        waveTimer  = 0,
    }
end

return function(runner)
    runner:suite("offlinesim")

    runner:test("production accrues offline, consuming ingredients (exact cycle count)", function()
        local s = shadow({ inventory = { ore = 20 } })
        Sim.simulate(s, 300, resolveRecipe, CATALOG, rng(false), env())
        -- ttm 30, 300s elapsed, ore for exactly 10 cycles
        eq(s.inventory.plate, 10, "10 cycles produced")
        eq(s.inventory.ore, 0, "all ore consumed")
    end)

    runner:test("production stalls without ingredients", function()
        local s = shadow({ inventory = {} })
        Sim.simulate(s, 300, resolveRecipe, CATALOG, rng(false), env())
        eq(s.inventory.plate or 0, 0)
    end)

    runner:test("production respects the stock cap (canStartCycle maxstock gate)", function()
        local s = shadow({ inventory = { ore = 20 }, stockCaps = { plate = 5, ore = 1000000, cat = 1000000 } })
        Sim.simulate(s, 600, resolveRecipe, CATALOG, rng(false), env())
        eq(s.inventory.plate, 5, "stops at the cap")
        eq(s.inventory.ore, 10, "only 5 cycles' ore consumed")
    end)

    runner:test("optional ingredient boosts cycles (2x), mirroring online", function()
        local s = shadow({ inventory = { ore = 100, cat = 100 } })
        Sim.simulate(s, 300, resolveRecipe, CATALOG, rng(false), env())
        eq(s.inventory.plate, 20, "boosted: 20 cycles in 300s at ttm 30")
    end)

    runner:test("splitting elapsed across calls equals one call (sub-step invariance)", function()
        local a = shadow({ inventory = { ore = 40 } })
        local b = shadow({ inventory = { ore = 40 } })
        Sim.simulate(a, 150, resolveRecipe, CATALOG, rng(false), env())
        Sim.simulate(a, 150, resolveRecipe, CATALOG, rng(false), env())
        Sim.simulate(b, 300, resolveRecipe, CATALOG, rng(false), env())
        eq(a.inventory.plate, b.inventory.plate, "same production either way")
        eq(a.inventory.ore, b.inventory.ore)
    end)

    runner:test("waves fire once per wavePeriod (the online cooldown x offline multiplier)", function()
        -- production effectively idle (no ore, nothing to sell below gates) — count waves only
        local s = shadow({ inventory = {}, cfg = { wavePeriod = 270, maxShips = 3, shipValue = 1e12 } })
        local r = Sim.simulate(s, 540, resolveRecipe, CATALOG, rng(false), env())
        eq(r.waves, 2, "two wave windows in 540s at period 270")
    end)

    runner:test("offline wave sells stock and credits the owner (apply-time clamp)", function()
        -- plate 90/100 (>80% gate) sell-marked; deliveries disabled. Planner would ask for 600
        -- (rng stub); the apply clamps to the 90 actually in stock.
        local s = shadow({
            inventory = { plate = 90 }, tradeCaps = { plate = 100 },
            activelyRequest = false,
            cfg = { wavePeriod = 270, maxShips = 3, shipValue = 1e12 },
        })
        local e = env()
        Sim.simulate(s, 270, resolveRecipe, CATALOG, rng(false), e)
        eq(s.inventory.plate, 0, "sold everything in stock")
        near(e.received, 90 * 200 * 1.0, nil, "credited at base price x sellFactor")
    end)

    runner:test("offline wave buys ingredients when the owner can pay", function()
        -- ore buy-marked (cap 500), empty -> delivery 500 (full ship-regime amount, NOT x0.3)
        local s = shadow({
            inventory = {}, tradeCaps = { ore = 500 },
            activelySell = false,
            cfg = { wavePeriod = 270, maxShips = 3, shipValue = 1e12 },
        })
        local e = env()
        Sim.simulate(s, 270, resolveRecipe, CATALOG, rng(false), e)
        eq(s.inventory.ore, 500, "delivered up to the vanilla 500 cap")
        near(e.paid, 500 * 50 * 1.0, nil, "owner paid base price x buyFactor")
    end)

    runner:test("unaffordable buys are skipped (production naturally stalls)", function()
        local s = shadow({
            inventory = {}, tradeCaps = { ore = 500 },
            activelySell = false,
            cfg = { wavePeriod = 270, maxShips = 3, shipValue = 1e12 },
        })
        local e = env(false)  -- owner can't pay
        Sim.simulate(s, 270, resolveRecipe, CATALOG, rng(false), e)
        eq(s.inventory.ore or 0, 0, "nothing delivered")
        eq(e.paid, 0)
    end)

    runner:test("war / no-trade flags suppress offline waves (Case D)", function()
        local s = shadow({
            inventory = { plate = 90 }, tradeCaps = { plate = 100 },
            flags = { war = true },
            cfg = { wavePeriod = 270, maxShips = 3, shipValue = 1e12 },
        })
        local e = env()
        local r = Sim.simulate(s, 540, resolveRecipe, CATALOG, rng(false), e)
        eq(r.trades, 0, "no trades in a war zone")
        eq(s.inventory.plate, 90, "stock untouched")
    end)

    runner:test("trade and production couple: delivered ore feeds later cycles", function()
        -- One wave delivers ore early; remaining elapsed produces from it.
        local s = shadow({
            inventory = {}, tradeCaps = { ore = 500 },
            activelySell = false,
            cfg = { wavePeriod = 60, maxShips = 3, shipValue = 1e12 },
        })
        Sim.simulate(s, 600, resolveRecipe, CATALOG, rng(false), env())
        tru((s.inventory.plate or 0) > 0, "production ran on offline-bought ingredients: " ..
            tostring(s.inventory.plate))
    end)
end
