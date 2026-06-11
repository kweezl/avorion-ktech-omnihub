package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest    = include("lib/omnihub/tests/framework")
local OmniHubTrading = include("lib/omnihub/trading")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local fls  = OmniHubTest.assertFalse

-- Pure suite: drives OmniHubTrading directly with synthetic aggregates. Fully deterministic.
return function(runner)
    runner:suite("trading")

    -- An aggregate shaped like OmniHubProduction.aggregate output. "Steel" is dual-use: produced as
    -- a result AND consumed as an ingredient. "Scrap" is a garbage (sellable). "Iron Ore" is a pure
    -- resource (bought). "Plate" is a pure product (sold).
    local function makeAgg()
        return {
            ingAmounts = { ["Iron Ore"] = 10, ["Steel"] = 4 },
            resAmounts = { ["Steel"] = 6, ["Plate"] = 3 },
            garAmounts = { ["Scrap"] = 2 },
        }
    end

    -- Returns a set membership lookup over an array of names.
    local function asSet(list)
        local s = {}
        for _, n in ipairs(list) do s[n] = true end
        return s
    end

    runner:test("buildTradeLists is empty with no marks (explicit-only, default off)", function()
        local lists = OmniHubTrading.buildTradeLists(nil, nil)
        eq(#lists.soldNames, 0,   "nothing sold by default")
        eq(#lists.boughtNames, 0, "nothing bought by default")
    end)

    runner:test("buildTradeLists includes only goods marked true", function()
        local lists = OmniHubTrading.buildTradeLists({ Plate = true, Steel = true }, { ["Iron Ore"] = true })
        local sold, bought = asSet(lists.soldNames), asSet(lists.boughtNames)
        tru(sold.Plate, "Plate sold"); tru(sold.Steel, "Steel sold")
        tru(bought["Iron Ore"], "Iron Ore bought")
        eq(#lists.soldNames, 2, "two sold"); eq(#lists.boughtNames, 1, "one bought")
    end)

    runner:test("buildTradeLists treats false / absent the same (off)", function()
        local lists = OmniHubTrading.buildTradeLists({ Plate = true, Steel = false }, nil)
        tru(asSet(lists.soldNames).Plate, "Plate (true) sold")
        fls(asSet(lists.soldNames).Steel, "Steel (false) not sold")
    end)

    runner:test("buildTradeLists output is sorted", function()
        local lists = OmniHubTrading.buildTradeLists(
            { Steel = true, Plate = true, Scrap = true }, { ["Iron Ore"] = true, Steel = true })
        eq(lists.soldNames[1], "Plate")  -- Plate < Scrap < Steel
        eq(lists.soldNames[2], "Scrap")
        eq(lists.soldNames[3], "Steel")
        eq(lists.boughtNames[1], "Iron Ore")  -- Iron Ore < Steel
        eq(lists.boughtNames[2], "Steel")
    end)

    runner:test("a good is independent per direction (sell vs buy)", function()
        local lists = OmniHubTrading.buildTradeLists({ Steel = false }, { Steel = true })
        fls(asSet(lists.soldNames).Steel,   "Steel not sold")
        tru(asSet(lists.boughtNames).Steel, "Steel bought")
    end)

    runner:test("any good can be marked (trading-station), not just produced/consumed", function()
        local lists = OmniHubTrading.buildTradeLists({ Titanium = true }, { Xanion = true })
        tru(asSet(lists.soldNames).Titanium, "arbitrary good sellable")
        tru(asSet(lists.boughtNames).Xanion, "arbitrary good buyable")
    end)

    runner:test("classifyGood flags produced / consumed / dual-use", function()
        local agg = makeAgg()
        local steel = OmniHubTrading.classifyGood("Steel", agg)
        tru(steel.isProduced, "Steel produced")
        tru(steel.isConsumed, "Steel consumed (dual-use)")

        local ore = OmniHubTrading.classifyGood("Iron Ore", agg)
        fls(ore.isProduced, "Iron Ore not produced")
        tru(ore.isConsumed, "Iron Ore consumed")

        local plate = OmniHubTrading.classifyGood("Plate", agg)
        tru(plate.isProduced, "Plate produced")
        fls(plate.isConsumed, "Plate not consumed")

        local scrap = OmniHubTrading.classifyGood("Scrap", agg)
        tru(scrap.isProduced, "Scrap (garbage) counts as produced")
        fls(scrap.isConsumed, "Scrap not consumed")
    end)

    runner:test("classifyGood is false/false for an unknown good", function()
        local c = OmniHubTrading.classifyGood("Nonexistent", makeAgg())
        fls(c.isProduced, "unknown not produced")
        fls(c.isConsumed, "unknown not consumed")
    end)

    -- ── sellTier / buildSoldPickupList (tiered sell policy) ───────────────────
    runner:test("sellTier: ingredient -> 3, even when also produced (protect the chain)", function()
        local agg = makeAgg()
        eq(OmniHubTrading.sellTier("Iron Ore", agg), 3, "ingredient-only is tier 3")
        eq(OmniHubTrading.sellTier("Steel", agg), 3, "result AND ingredient: ingredient wins")
    end)

    runner:test("sellTier: result-only -> 2", function()
        eq(OmniHubTrading.sellTier("Plate", makeAgg()), 2)
    end)

    runner:test("sellTier: garbage-only and unknown goods -> 1 (dump ASAP)", function()
        local agg = makeAgg()
        eq(OmniHubTrading.sellTier("Scrap", agg), 1, "garbage is neither result nor ingredient")
        eq(OmniHubTrading.sellTier("Titanium", agg), 1, "pure trading-station good")
    end)

    runner:test("buildSoldPickupList maps every sold name to {name, tier}, preserving order", function()
        local list = OmniHubTrading.buildSoldPickupList(
            { "Iron Ore", "Plate", "Scrap", "Steel", "Titanium" }, makeAgg())
        eq(#list, 5)
        eq(list[1].name, "Iron Ore"); eq(list[1].tier, 3)
        eq(list[2].name, "Plate");    eq(list[2].tier, 2)
        eq(list[3].name, "Scrap");    eq(list[3].tier, 1)
        eq(list[4].name, "Steel");    eq(list[4].tier, 3)
        eq(list[5].name, "Titanium"); eq(list[5].tier, 1)
    end)

    runner:test("buildSoldPickupList is empty for empty/nil sold names", function()
        eq(#OmniHubTrading.buildSoldPickupList({}, makeAgg()), 0)
        eq(#OmniHubTrading.buildSoldPickupList(nil, makeAgg()), 0)
    end)

    -- ── canonicalName ──────────────────────────────────────────────────────────
    runner:test("canonicalName resolves a catalog alias key to the good's real name", function()
        local catalog = {}
        catalog["Aluminum"]  = { name = "Aluminum" }
        catalog["Aluminium"] = catalog["Aluminum"]  -- vanilla backwards-compat alias (goods.lua)
        eq(OmniHubTrading.canonicalName("Aluminium", catalog), "Aluminum", "alias key resolves")
        eq(OmniHubTrading.canonicalName("Aluminum", catalog), "Aluminum", "real name unchanged")
    end)

    runner:test("canonicalName passes through unknown names and a nil catalog", function()
        eq(OmniHubTrading.canonicalName("Unknown", { Steel = { name = "Steel" } }), "Unknown",
            "name absent from catalog unchanged")
        eq(OmniHubTrading.canonicalName("Steel", nil), "Steel", "nil catalog unchanged")
    end)

    -- ── buildTradeableSet ──────────────────────────────────────────────────────
    -- Productions array shaped like vanilla productionsindex entries. "Gem" is ingredient-only
    -- (consumed, never produced — the real Diamond/Gem case); "Toxic Waste" is garbage-only.
    local function makeProductions()
        return {
            { ingredients = { { name = "Scrap Metal", amount = 12 }, { name = "Coal", amount = 4 } },
              results     = { { name = "Steel", amount = 6 } },
              garbages    = {} },
            { ingredients = { { name = "Gem", amount = 1 } },
              results     = { { name = "Jewelry", amount = 2 } },
              garbages    = { { name = "Toxic Waste", amount = 1 } } },
            { ingredients = {},
              results     = { { name = "Scrap Metal", amount = 60 } } },  -- no garbages key (trader-style)
        }
    end

    runner:test("buildTradeableSet unions ingredients, results and garbages", function()
        local set = OmniHubTrading.buildTradeableSet(makeProductions())
        tru(set["Steel"], "result tradeable")
        tru(set["Scrap Metal"], "ingredient+result tradeable")
        tru(set["Coal"], "ingredient tradeable")
        tru(set["Gem"], "ingredient-only good tradeable (Diamond/Gem case)")
        tru(set["Toxic Waste"], "garbage-only good tradeable (Toxic Waste case)")
    end)

    runner:test("buildTradeableSet excludes goods in no production (ores, salvage, illegal)", function()
        local set = OmniHubTrading.buildTradeableSet(makeProductions())
        fls(set["Iron Ore"] == true, "ore not tradeable")
        fls(set["Scrap Iron"] == true, "salvage scrap not tradeable")
        fls(set["Acron Drug"] == true, "illegal good not tradeable")
    end)

    runner:test("buildTradeableSet is empty for an empty or nil productions array", function()
        eq(next(OmniHubTrading.buildTradeableSet({})), nil, "empty productions -> empty set")
        eq(next(OmniHubTrading.buildTradeableSet(nil)), nil, "nil productions -> empty set")
    end)

    -- ── pruneMarks ─────────────────────────────────────────────────────────────
    runner:test("pruneMarks drops marks for non-tradeable goods, keeps the rest", function()
        local tradeable = OmniHubTrading.buildTradeableSet(makeProductions())
        local marks = { ["Steel"] = true, ["Coal"] = false, ["Iron Ore"] = true, ["Scrap Iron"] = false }
        local out = OmniHubTrading.pruneMarks(marks, tradeable)
        eq(out["Steel"], true,  "tradeable true mark kept")
        eq(out["Coal"], false,  "tradeable false mark kept")
        eq(out["Iron Ore"], nil,   "stale ore mark removed")
        eq(out["Scrap Iron"], nil, "stale salvage mark removed")
    end)

    runner:test("pruneMarks returns an empty table for a nil map", function()
        local out = OmniHubTrading.pruneMarks(nil, { Steel = true })
        eq(next(out), nil, "nil map -> empty table")
    end)

    -- ── setMark ────────────────────────────────────────────────────────────────
    runner:test("setMark stores the explicit boolean (opt-in needs true)", function()
        local m = {}
        OmniHubTrading.setMark(m, "Steel", false)
        eq(m.Steel, false, "disable stores false")
        OmniHubTrading.setMark(m, "Steel", true)
        eq(m.Steel, true, "enable stores true (explicit opt-in)")
    end)

    runner:test("setMark round-trips through buildTradeLists", function()
        local sell = {}
        OmniHubTrading.setMark(sell, "Plate", true)
        tru(asSet(OmniHubTrading.buildTradeLists(sell, nil).soldNames)["Plate"], "Plate on")
        OmniHubTrading.setMark(sell, "Plate", false)
        fls(asSet(OmniHubTrading.buildTradeLists(sell, nil).soldNames)["Plate"], "Plate off")
    end)
end
