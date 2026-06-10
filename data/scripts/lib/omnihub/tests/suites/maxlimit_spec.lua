package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest         = include("lib/omnihub/tests/framework")
local OmniHubProduction   = include("lib/omnihub/production")
local OmniHubMaxLimit = include("lib/omnihub/maxlimit")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local niln = OmniHubTest.assertNil

-- Pure suite: drives OmniHubMaxLimit.compute with synthetic aggregates. Fully deterministic.
return function(runner)
    runner:suite("maxlimit")

    local params = { buyLimit = 1000, prodBase = 200, prodCycles = 1 }

    -- Two cattle ranches producing the SAME good from DIFFERENT resources (the alternative-recipe
    -- case): wheat variant (Bio Gas as garbage) + corn variant (Bio Gas as a second result).
    local wheatRanch = {
        ingredients = { { name = "Wheat", amount = 15, optional = 0 },
                        { name = "Oxygen", amount = 10, optional = 0 },
                        { name = "Water", amount = 15, optional = 0 } },
        results     = { { name = "Cattle", amount = 8 } },
        garbages    = { { name = "Bio Gas", amount = 1 } },
    }
    local cornRanch = {
        ingredients = { { name = "Corn", amount = 15, optional = 0 },
                        { name = "Oxygen", amount = 10, optional = 0 },
                        { name = "Water", amount = 15, optional = 0 } },
        results     = { { name = "Cattle", amount = 8 }, { name = "Bio Gas", amount = 2 } },
        garbages    = {},
    }
    local function resolve(key)
        return ({ wheat = wheatRanch, corn = cornRanch })[key]
    end

    runner:test("produced/consumed goods reserve prodBase * prodCycles * perCycleAmount", function()
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        local boughtNames = { "Wheat", "Oxygen", "Water" }  -- consumed -> bought by default
        local r = OmniHubMaxLimit.compute(agg, boughtNames, params)
        eq(r.Cattle, 200 * 1 * 8, "Cattle: 8/cycle")
        eq(r.Wheat,  200 * 1 * 15, "Wheat ingredient: 15/cycle")
        eq(r.Oxygen, 200 * 1 * 10, "Oxygen ingredient: 10/cycle")
        eq(r["Bio Gas"], 200 * 1 * 1, "Bio Gas garbage: 1/cycle")
    end)

    runner:test("alternative recipes sum the same good's per-cycle amount across modules", function()
        -- One of each ranch: Cattle = 8 + 8 = 16/cycle; Bio Gas = 1 (garbage) + 2 (result) = 3/cycle;
        -- Oxygen/Water shared = 20/30; Wheat only in wheat ranch, Corn only in corn ranch.
        local agg = OmniHubProduction.aggregate({ wheat = 1, corn = 1 }, resolve)
        local boughtNames = { "Wheat", "Corn", "Oxygen", "Water" }
        local r = OmniHubMaxLimit.compute(agg, boughtNames, params)
        eq(r.Cattle,    200 * 1 * 16, "Cattle summed across both recipes")
        eq(r["Bio Gas"], 200 * 1 * 3, "Bio Gas: garbage(1) + result(2)")
        eq(r.Oxygen,    200 * 1 * 20, "Oxygen shared by both")
        eq(r.Wheat,     200 * 1 * 15, "Wheat only in wheat ranch")
        eq(r.Corn,      200 * 1 * 15, "Corn only in corn ranch")
    end)

    runner:test("module count scales the per-cycle amount", function()
        local agg = OmniHubProduction.aggregate({ wheat = 3 }, resolve)
        local r = OmniHubMaxLimit.compute(agg, { "Wheat", "Oxygen", "Water" }, params)
        eq(r.Cattle, 200 * 1 * 8 * 3, "3 modules -> 3x Cattle reserve")
    end)

    runner:test("prodCycles multiplies the buffer", function()
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        local r = OmniHubMaxLimit.compute(agg, { "Wheat" }, { buyLimit = 1000, prodBase = 200, prodCycles = 5 })
        eq(r.Cattle, 200 * 5 * 8, "prodCycles=5 buffers 5 cycles of output")
    end)

    runner:test("buy-marked good that is neither produced nor consumed reserves buyLimit", function()
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        -- "Trinium" is a pure passthrough trade good: bought, but no module makes or uses it.
        local r = OmniHubMaxLimit.compute(agg, { "Wheat", "Oxygen", "Water", "Trinium" }, params)
        eq(r.Trinium, 1000, "flat buyLimit for passthrough buy good")
    end)

    runner:test("SELL-marked good that is neither produced nor consumed also reserves buyLimit", function()
        -- Regression: a sell-only non-production good previously got NO cap at all -> the UI
        -- rendered 0/0 and getMaxGoods()==0 blocked it from NPC trading entirely (the Aluminum
        -- case). Any EXPLICITLY traded good deserves the flat passthrough buffer.
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        local r = OmniHubMaxLimit.compute(agg, { "Wheat" }, params, { "Aluminum" })
        eq(r.Aluminum, 1000, "flat buyLimit for a sell-only passthrough good")
    end)

    runner:test("a produced good reserves on production role even if not bought", function()
        -- Cattle is a result, never an ingredient -> not in boughtNames, but still reserves.
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        local r = OmniHubMaxLimit.compute(agg, { "Wheat", "Oxygen", "Water" }, params)
        eq(r.Cattle, 200 * 1 * 8, "production role reserves regardless of buy mark")
    end)

    runner:test("a good neither produced/consumed nor bought does not reserve", function()
        local agg = OmniHubProduction.aggregate({ wheat = 1 }, resolve)
        local r = OmniHubMaxLimit.compute(agg, { "Wheat", "Oxygen", "Water" }, params)
        niln(r.Platinum, "unrelated good has no reserve entry")
    end)

    runner:test("empty install yields no reservations", function()
        local agg = OmniHubProduction.aggregate({}, resolve)
        local r = OmniHubMaxLimit.compute(agg, {}, params)
        niln(next(r), "no goods reserve when nothing is installed or bought")
    end)

    -- A good produced by one module AND consumed by another (an intermediate). Carbon Extractor
    -- (Corn -> Carbon) feeds a Steel Factory (Ore + Coal + Carbon -> Steel). Carbon is a result of the
    -- first and an ingredient of the second; the reserve is the MAX of the two role buffers (one shared
    -- stock pile), not their sum.
    local carbonExtractor = {
        ingredients = { { name = "Corn", amount = 52, optional = 0 } },
        results     = { { name = "Carbon", amount = 5 } },
        garbages    = {},
    }
    local steelFactory = {
        ingredients = { { name = "Ore", amount = 8, optional = 0 },
                        { name = "Coal", amount = 3, optional = 0 },
                        { name = "Carbon", amount = 1, optional = 0 } },
        results     = { { name = "Steel", amount = 8 } },
        garbages    = {},
    }
    local function resolveCarbon(key)
        return ({ carbon = carbonExtractor, steel = steelFactory })[key]
    end

    runner:test("an intermediate good reserves max(produced, consumed), not their sum (Carbon)", function()
        local agg = OmniHubProduction.aggregate({ carbon = 1, steel = 1 }, resolveCarbon)
        local r = OmniHubMaxLimit.compute(agg, {}, params)
        eq(r.Carbon, 200 * 1 * math.max(5, 1), "Carbon: max(produced 5, consumed 1) = 5/cycle -> 1000")
        eq(r.Corn,  200 * 1 * 52, "Corn: extractor ingredient")
        eq(r.Ore,   200 * 1 * 8,  "Ore: steel ingredient")
        eq(r.Coal,  200 * 1 * 3,  "Coal: steel ingredient")
        eq(r.Steel, 200 * 1 * 8,  "Steel: factory result")
    end)

    runner:test("intermediate-good reserve takes the dominant role as module counts change", function()
        -- 3 extractors (Carbon produced 15/cycle) + 2 steel factories (Carbon consumed 2/cycle):
        -- production dominates, so the reserve follows produced, not produced+consumed.
        local agg = OmniHubProduction.aggregate({ carbon = 3, steel = 2 }, resolveCarbon)
        local r = OmniHubMaxLimit.compute(agg, {}, params)
        eq(r.Carbon, 200 * 1 * math.max(5 * 3, 1 * 2), "Carbon: max(15 produced, 2 consumed) = 15 -> 3000")
        eq(r.Steel,  200 * 1 * (8 * 2), "Steel: 2 factories")
        eq(r.Corn,   200 * 1 * (52 * 3), "Corn: 3 extractors")
    end)

    runner:test("intermediate-good reserve follows consumption when it dominates", function()
        -- 1 extractor (Carbon produced 5/cycle) + 8 steel factories (Carbon consumed 8/cycle):
        -- consumption now dominates, so the reserve follows consumed.
        local agg = OmniHubProduction.aggregate({ carbon = 1, steel = 8 }, resolveCarbon)
        local r = OmniHubMaxLimit.compute(agg, {}, params)
        eq(r.Carbon, 200 * 1 * math.max(5, 1 * 8), "Carbon: max(5 produced, 8 consumed) = 8 -> 1600")
    end)
end
