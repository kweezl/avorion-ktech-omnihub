package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest  = include("lib/omnihub/tests/framework")
local OmniHubRates = include("lib/omnihub/rates")

local eq  = OmniHubTest.assertEqual
local near = OmniHubTest.assertNear

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
end
