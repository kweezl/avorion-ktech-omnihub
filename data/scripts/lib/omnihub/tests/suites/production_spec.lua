package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubProduction = include("lib/omnihub/production")

local eq    = OmniHubTest.assertEqual
local near  = OmniHubTest.assertNear
local tru   = OmniHubTest.assertTrue
local fls   = OmniHubTest.assertFalse
local notn  = OmniHubTest.assertNotNil
local niln  = OmniHubTest.assertNil

-- Pure suite: drives OmniHubProduction directly with synthetic data. Fully deterministic.
return function(runner)
    runner:suite("production")

    -- ── timeToProduce ─────────────────────────────────────────────────────────
    local goodsTable = {
        A = { price = 100,   level = 0  },
        B = { price = 50,    level = 10 },
        C = { price = 10000, level = 0  },
    }

    runner:test("timeToProduce returns minTime for a nil recipe", function()
        eq(OmniHubProduction.timeToProduce(nil, goodsTable, 10, 15), 15)
    end)

    runner:test("timeToProduce applies value, level bonus and capacity", function()
        -- results 2xA + garbage 1xB: value=250, avgLevel=5 -> bonus 1.05, cap 10
        local recipe = { results = { { name = "A", amount = 2 } },
                         garbages = { { name = "B", amount = 1 } } }
        near(OmniHubProduction.timeToProduce(recipe, goodsTable, 10, 15), 250 / 10 / 1.05)
    end)

    runner:test("timeToProduce clamps to minTime", function()
        local recipe = { results = { { name = "A", amount = 2 } },
                         garbages = { { name = "B", amount = 1 } } }
        -- huge capacity drives raw time well below minTime
        eq(OmniHubProduction.timeToProduce(recipe, goodsTable, 100000, 15), 15)
    end)

    runner:test("timeToProduce scales inversely with capacity", function()
        local recipe = { results = { { name = "C", amount = 10 } } }  -- value 100000, bonus 1
        local t10 = OmniHubProduction.timeToProduce(recipe, goodsTable, 10, 15)
        local t20 = OmniHubProduction.timeToProduce(recipe, goodsTable, 20, 15)
        near(t10, 10000)
        near(t20, 5000)
    end)

    -- ── sellerProbability ─────────────────────────────────────────────────────
    runner:test("sellerProbability maps and clamps the lerp endpoints", function()
        near(OmniHubProduction.sellerProbability(0.8), 0.1)
        near(OmniHubProduction.sellerProbability(1.2), 0.9)
        near(OmniHubProduction.sellerProbability(1.0), 0.5)
        near(OmniHubProduction.sellerProbability(0.5), 0.1)  -- clamped low
        near(OmniHubProduction.sellerProbability(2.0), 0.9)  -- clamped high
    end)

    -- ── aggregate ─────────────────────────────────────────────────────────────
    local recipeA = {
        ingredients = { { name = "ore", amount = 5, optional = 0 },
                        { name = "water", amount = 2, optional = 1 } },
        results     = { { name = "plate", amount = 3 } },
        garbages    = { { name = "scrap", amount = 1 } },
    }
    local recipeB = {
        ingredients = { { name = "ore", amount = 4, optional = 0 } },
        results     = { { name = "plate", amount = 1 } },
    }
    local function resolve(key)
        return ({ A = recipeA, B = recipeB })[key]
    end

    runner:test("aggregate sums amounts x count across modules", function()
        local agg = OmniHubProduction.aggregate({ A = 2, B = 3 }, resolve)
        tru(agg.hasAny, "hasAny")
        eq(agg.ingAmounts.ore, 22,   "ore = 5*2 + 4*3")
        eq(agg.ingAmounts.water, 4,  "water = 2*2")
        eq(agg.ingOptional.ore, 0,   "ore required")
        eq(agg.ingOptional.water, 1, "water optional")
        eq(agg.resAmounts.plate, 9,  "plate = 3*2 + 1*3")
        eq(agg.garAmounts.scrap, 2,  "scrap = 1*2")
        notn(agg.aggregatedProduction, "aggregatedProduction built")
        eq(#agg.aggregatedProduction.ingredients, 2)
        eq(#agg.aggregatedProduction.results, 1)
        eq(#agg.aggregatedProduction.garbages, 1)
    end)

    runner:test("aggregate yields nil aggregatedProduction when empty", function()
        local agg = OmniHubProduction.aggregate({}, resolve)
        fls(agg.hasAny, "hasAny is false")
        niln(agg.aggregatedProduction, "aggregatedProduction nil")
    end)

    -- ── canStartCycle ─────────────────────────────────────────────────────────
    local cycleRecipe = {
        ingredients = { { name = "ore", amount = 5, optional = 0 },
                        { name = "water", amount = 2, optional = 1 } },
        results     = { { name = "plate", amount = 3 } },
    }
    local function makeQuery(stock, sizes, maxStocks, freeCargo)
        return {
            getNumGoods    = function(n) return stock[n] or 0 end,
            getGoodSize    = function(n) return sizes[n] or 1 end,
            getMaxStock    = function(n) return maxStocks[n] or 1e12 end,
            freeCargoSpace = freeCargo,
        }
    end

    runner:test("canStartCycle blocks on a missing required ingredient", function()
        local d = OmniHubProduction.canStartCycle(cycleRecipe, 1,
            makeQuery({ ore = 4 }, {}, {}, 1e12))
        fls(d.canProduce, "should not produce with too little ore")
    end)

    runner:test("canStartCycle sets boosted when optional ingredient present", function()
        local d = OmniHubProduction.canStartCycle(cycleRecipe, 1,
            makeQuery({ ore = 10, water = 5 }, {}, {}, 1e12))
        tru(d.canProduce, "should produce")
        tru(d.boosted, "boosted with water present")
    end)

    runner:test("canStartCycle not boosted when optional ingredient absent", function()
        local d = OmniHubProduction.canStartCycle(cycleRecipe, 1,
            makeQuery({ ore = 10 }, {}, {}, 1e12))
        tru(d.canProduce, "should produce")
        fls(d.boosted, "not boosted without water")
    end)

    runner:test("canStartCycle blocks on insufficient cargo space", function()
        local d = OmniHubProduction.canStartCycle(cycleRecipe, 1,
            makeQuery({ ore = 10 }, { plate = 10 }, {}, 5))  -- need 3*10=30 > 5 free
        fls(d.canProduce, "should not produce without cargo space")
    end)

    runner:test("canStartCycle blocks when result exceeds max stock", function()
        local d = OmniHubProduction.canStartCycle(cycleRecipe, 1,
            makeQuery({ ore = 10, plate = 100 }, {}, { plate = 101 }, 1e12))  -- 100+3 > 101
        fls(d.canProduce, "should not produce over max stock")
    end)

    -- ── rollDrops ─────────────────────────────────────────────────────────────
    -- Mock rng exposing :test(p); records the probabilities it was asked about.
    local function constRng(value)
        return {
            calls = {},
            test  = function(self, p) self.calls[#self.calls + 1] = p; return value end,
        }
    end
    -- Consumes a fixed boolean sequence, one per :test call.
    local function seqRng(results)
        local i = 0
        return { test = function(self, p) i = i + 1; return results[i] == true end }
    end
    local function countKeys(list)
        local c = {}
        for _, k in ipairs(list) do c[k] = (c[k] or 0) + 1 end
        return c
    end

    runner:test("rollDrops drops every installed unit when rng always passes", function()
        local drops = OmniHubProduction.rollDrops({ A = 2, B = 3 }, 0.5, constRng(true))
        eq(#drops, 5, "all 5 units drop")
        local c = countKeys(drops)
        eq(c.A, 2, "A dropped x2")
        eq(c.B, 3, "B dropped x3")
    end)

    runner:test("rollDrops drops nothing when rng always fails", function()
        eq(#OmniHubProduction.rollDrops({ A = 2, B = 3 }, 0.5, constRng(false)), 0, "no drops")
    end)

    runner:test("rollDrops rolls once per unit using the supplied dropChance", function()
        local rng = constRng(false)
        OmniHubProduction.rollDrops({ A = 2, B = 3 }, 0.42, rng)
        eq(#rng.calls, 5, "one roll per installed unit")
        for _, p in ipairs(rng.calls) do eq(p, 0.42, "rolls at dropChance") end
    end)

    runner:test("rollDrops honors per-unit rng outcomes", function()
        -- single key keeps the inner-loop consumption order deterministic
        local drops = OmniHubProduction.rollDrops({ A = 4 }, 0.5, seqRng({ true, false, true, false }))
        eq(#drops, 2, "two of four units drop")
        eq(drops[1], "A")
        eq(drops[2], "A")
    end)

    runner:test("rollDrops returns empty for no installed modules", function()
        eq(#OmniHubProduction.rollDrops({}, 1.0, constRng(true)), 0, "empty installed -> no drops")
    end)
end
