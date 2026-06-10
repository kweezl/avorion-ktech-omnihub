package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest  = include("lib/omnihub/tests/framework")
local OmniHubRates = include("lib/omnihub/rates")

local eq   = OmniHubTest.assertEqual
local near = OmniHubTest.assertNear
local tru  = OmniHubTest.assertTrue

-- Pure suite: drives OmniHubRates directly. Deterministic (advance takes explicit seconds).
return function(runner)
    runner:suite("rates")

    runner:test("new starts empty", function()
        local s = OmniHubRates.new()
        eq(OmniHubRates.producedPerMin(s, "Steel"), 0)
        eq(OmniHubRates.consumedPerMin(s, "Iron Ore"), 0)
    end)

    runner:test("records accumulate within the window", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordProduced(s, "Steel", 5)
        OmniHubRates.recordProduced(s, "Steel", 3)
        OmniHubRates.recordConsumed(s, "Iron Ore", 10)
        eq(OmniHubRates.producedPerMin(s, "Steel"), 8, "5 + 3 produced")
        eq(OmniHubRates.consumedPerMin(s, "Iron Ore"), 10)
    end)

    runner:test("ignores non-positive amounts", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordProduced(s, "Steel", 0)
        OmniHubRates.recordProduced(s, "Steel", -4)
        eq(OmniHubRates.producedPerMin(s, "Steel"), 0)
    end)

    runner:test("events stay in the window across partial advance", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordProduced(s, "Steel", 6)
        OmniHubRates.advance(s, 30)   -- still within the ~60s window
        OmniHubRates.recordProduced(s, "Steel", 4)
        eq(OmniHubRates.producedPerMin(s, "Steel"), 10, "both within the minute")
    end)

    runner:test("old events fall out after a full window", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordProduced(s, "Steel", 6)
        OmniHubRates.advance(s, 60)   -- roll the whole 60s window past the event
        eq(OmniHubRates.producedPerMin(s, "Steel"), 0, "event aged out")
    end)

    runner:test("advance rolls in whole buckets; sub-bucket time is retained", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordProduced(s, "Steel", 5)   -- bucket 1
        OmniHubRates.advance(s, 5)                    -- < one bucket: no roll yet
        eq(OmniHubRates.producedPerMin(s, "Steel"), 5, "no bucket rolled")
        OmniHubRates.advance(s, 5)                    -- now 10s total -> one roll, still in window
        eq(OmniHubRates.producedPerMin(s, "Steel"), 5, "still within window after one roll")
        OmniHubRates.advance(s, 50)                   -- total 60s -> event aged out
        eq(OmniHubRates.producedPerMin(s, "Steel"), 0)
    end)

    runner:test("advance ignores zero / negative", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordConsumed(s, "Water", 2)
        OmniHubRates.advance(s, 0)
        OmniHubRates.advance(s, -10)
        eq(OmniHubRates.consumedPerMin(s, "Water"), 2)
    end)

    -- ── recordCycle (smooth per-tick accrual; replaces lump-at-completion recording) ──
    local cycleRecipe = {
        ingredients = { { name = "ore",   amount = 5 } },
        results     = { { name = "plate", amount = 3 } },
        garbages    = { { name = "scrap", amount = 1 } },
    }

    runner:test("recordCycle accrues recipe amounts by fraction and module count", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordCycle(s, cycleRecipe, 2, 0.5)
        near(OmniHubRates.producedPerMin(s, "plate"), 3, nil, "3 * 2 modules * 0.5")
        near(OmniHubRates.producedPerMin(s, "scrap"), 1, nil, "garbage accrues too")
        near(OmniHubRates.consumedPerMin(s, "ore"),   5, nil, "5 * 2 * 0.5")
    end)

    runner:test("recordCycle fractions over one full cycle sum to exactly one cycle's amounts", function()
        local s = OmniHubRates.new()
        for _ = 1, 10 do OmniHubRates.recordCycle(s, cycleRecipe, 1, 0.1) end
        near(OmniHubRates.producedPerMin(s, "plate"), 3)
        near(OmniHubRates.consumedPerMin(s, "ore"),   5)
    end)

    runner:test("recordCycle ignores nil recipe and non-positive fractions", function()
        local s = OmniHubRates.new()
        OmniHubRates.recordCycle(s, nil, 1, 0.5)
        OmniHubRates.recordCycle(s, cycleRecipe, 1, 0)
        OmniHubRates.recordCycle(s, cycleRecipe, 1, -0.2)
        eq(OmniHubRates.producedPerMin(s, "plate"), 0)
        eq(OmniHubRates.consumedPerMin(s, "ore"),   0)
    end)

    runner:test("smooth accrual never exceeds the steady per-minute max (C>L aliasing regression)", function()
        -- ttm = 45s, one module producing 3 plate per cycle -> steady max = 3*60/45 = 4/min.
        -- The old lump-at-completion recording let a 60s window catch TWO completions and read
        -- ~6/min (150% of max). Per-tick fractional accrual must stay <= max at every tick.
        local s = OmniHubRates.new()
        local recipe = { ingredients = {}, results = { { name = "plate", amount = 3 } } }
        local steadyMax = 3 * 60 / 45
        for _ = 1, 120 do  -- two full cycles' worth of 1s ticks
            OmniHubRates.recordCycle(s, recipe, 1, 1 / 45)
            OmniHubRates.advance(s, 1)
            tru(OmniHubRates.producedPerMin(s, "plate") <= steadyMax + 1e-6,
                "windowed actual stays at/below the steady max")
        end
    end)
end
