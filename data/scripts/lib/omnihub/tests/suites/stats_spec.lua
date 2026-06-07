package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest  = include("lib/omnihub/tests/framework")
local OmniHubStats = include("lib/omnihub/stats")

local eq  = OmniHubTest.assertEqual
local tru = OmniHubTest.assertTrue

-- Pure suite: drives OmniHubStats directly. Fully deterministic (no wall-clock).
return function(runner)
    runner:suite("stats")

    local function sell(good, amount, price, partner)
        return { kind = "sell", good = good, amount = amount, price = price, partner = partner }
    end
    local function buy(good, amount, price, partner)
        return { kind = "buy", good = good, amount = amount, price = price, partner = partner }
    end

    runner:test("new starts empty", function()
        local s = OmniHubStats.new()
        eq(OmniHubStats.lifetimeProfit(s), 0, "lifetime 0")
        eq(OmniHubStats.lastHourProfit(s), 0, "last hour 0")
        eq(#OmniHubStats.recent(s, 10), 0, "no transactions")
        eq(#s.buckets, 60, "60 minute buckets")
    end)

    runner:test("record adds sells and subtracts buys from lifetime profit", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("Plate", 5, 1000))
        OmniHubStats.record(s, buy("Iron Ore", 10, 300))
        eq(OmniHubStats.lifetimeProfit(s), 700, "1000 - 300")
        eq(OmniHubStats.lastHourProfit(s), 700, "same window, no advance")
    end)

    runner:test("recent returns transactions newest-first, capped at 10", function()
        local s = OmniHubStats.new()
        for i = 1, 13 do
            OmniHubStats.record(s, sell("G" .. i, 1, i))
        end
        local r = OmniHubStats.recent(s, 10)
        eq(#r, 10, "capped at 10")
        eq(r[1].good, "G13", "newest first")
        eq(r[10].good, "G4", "oldest kept is the 4th (1..3 dropped)")
        -- internal log also capped
        eq(#s.transactions, 10, "log capped at 10")
    end)

    runner:test("recent honours a smaller n", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("A", 1, 10))
        OmniHubStats.record(s, sell("B", 1, 20))
        OmniHubStats.record(s, sell("C", 1, 30))
        local r = OmniHubStats.recent(s, 2)
        eq(#r, 2, "only 2 returned")
        eq(r[1].good, "C")
        eq(r[2].good, "B")
    end)

    runner:test("advance rolls the window; profit older than an hour falls off last-hour", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("Old", 1, 500))   -- bucket at cursor
        eq(OmniHubStats.lastHourProfit(s), 500, "in window now")
        OmniHubStats.advance(s, 60)                    -- roll a full hour
        eq(OmniHubStats.lastHourProfit(s), 0, "fell out of the last-hour window")
        eq(OmniHubStats.lifetimeProfit(s), 500, "lifetime is unaffected by advance")
    end)

    runner:test("advance keeps profit inside the hour and bins new profit separately", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("A", 1, 100))
        OmniHubStats.advance(s, 30)                    -- still within the 60-minute window
        OmniHubStats.record(s, sell("B", 1, 50))
        eq(OmniHubStats.lastHourProfit(s), 150, "both within the hour")
        OmniHubStats.advance(s, 31)                    -- A now older than 60 min, B still inside
        eq(OmniHubStats.lastHourProfit(s), 50, "only B remains in window")
    end)

    runner:test("advance ignores zero / negative / fractional-down steps", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("A", 1, 100))
        OmniHubStats.advance(s, 0)
        OmniHubStats.advance(s, -5)
        OmniHubStats.advance(s, 0.4)  -- floors to 0
        eq(OmniHubStats.lastHourProfit(s), 100, "no roll occurred")
    end)

    runner:test("state survives a plain table copy (secure/restore shape)", function()
        local s = OmniHubStats.new()
        OmniHubStats.record(s, sell("A", 2, 200, "Trader Co"))
        OmniHubStats.advance(s, 3)
        -- Simulate secure->restore: deep-ish copy of the persisted shape.
        local copy = { lifetimeProfit = s.lifetimeProfit, cursor = s.cursor, buckets = {}, transactions = {} }
        for i, v in ipairs(s.buckets) do copy.buckets[i] = v end
        for i, t in ipairs(s.transactions) do copy.transactions[i] = t end
        eq(OmniHubStats.lifetimeProfit(copy), 200, "lifetime preserved")
        eq(OmniHubStats.lastHourProfit(copy), 200, "window preserved")
        local r = OmniHubStats.recent(copy, 1)
        eq(r[1].partner, "Trader Co", "transaction detail preserved")
    end)
end
