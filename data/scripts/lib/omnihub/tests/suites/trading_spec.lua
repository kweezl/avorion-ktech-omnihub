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

    -- ── partnerLabel (regression: nil translatedName crash) ────────────────────
    runner:test("partnerLabel composes title, name and faction", function()
        eq(OmniHubTrading.partnerLabel("Mine", "Station 7", "The Syndicate"),
           "Mine Station 7 (The Syndicate)")
    end)

    runner:test("partnerLabel tolerates a nil faction name (no crash, no suffix)", function()
        eq(OmniHubTrading.partnerLabel("Mine", "Station 7", nil), "Mine Station 7")
        eq(OmniHubTrading.partnerLabel("Mine", "Station 7", ""),  "Mine Station 7")
    end)

    runner:test("partnerLabel tolerates nil title and station name", function()
        eq(OmniHubTrading.partnerLabel(nil, nil, nil), " ")
        eq(OmniHubTrading.partnerLabel(nil, "Station 7", "Faction"), " Station 7 (Faction)")
    end)
end
