package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest = include("lib/omnihub/tests/framework")
local Decide      = include("lib/omnihub/tradingdecision")

local eq    = OmniHubTest.assertEqual
local tru   = OmniHubTest.assertTrue
local nilq  = OmniHubTest.assertNil
local notn  = OmniHubTest.assertNotNil

-- Builds a query stub. stock/max are per-good maps; price defaults to 100 unless overridden.
local function query(stock, max, price)
    return {
        getNumGoods = function(n) return stock[n] or 0 end,
        getMaxGoods = function(n) return max[n] or 0 end,
        goodPrice   = function(n) if price and price[n] ~= nil then return price[n] end return 100 end,
    }
end

return function(runner)
    runner:suite("tradingdecision")

    -- ── decideSeller ────────────────────────────────────────────────────────────
    runner:test("seller: nil when good not externally tradeable (max==0) — A2 regression", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 10}, query({}, {}), false)
        nilq(d, "no decision (NOT a negative amount) when getMaxGoods is 0")
    end)

    runner:test("seller: nil when already stocked at/above requested amount", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 10},
            query({["Iron Ore"] = 10}, {["Iron Ore"] = 500}), false)
        nilq(d)
    end)

    runner:test("seller: requests up to min(max,500)-have when low", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 10},
            query({["Iron Ore"] = 0}, {["Iron Ore"] = 300}), false)
        notn(d); eq(d.name, "Iron Ore"); eq(d.amount, 300)
    end)

    runner:test("seller: caps the request at 500", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 10},
            query({["Iron Ore"] = 0}, {["Iron Ore"] = 9000}), false)
        eq(d.amount, 500)
    end)

    runner:test("seller: immediate scales the amount by 0.3 (rounded)", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 10},
            query({["Iron Ore"] = 0}, {["Iron Ore"] = 300}), true)
        eq(d.amount, 90)  -- round(300 * 0.3)
    end)

    runner:test("seller: nil when computed amount is <= 0 (have == max)", function()
        local d = Decide.decideSeller({name = "Iron Ore", amount = 600},
            query({["Iron Ore"] = 500}, {["Iron Ore"] = 500}), false)
        nilq(d)  -- have(500) < amount(600) so we proceed, but min(500,500)-500 = 0 -> nil
    end)

    -- ── sellEligible (tiered sell policy gate; replaced decideBuyer) ────────────
    runner:test("sellEligible: false when good not externally sold (max==0) — A2 regression", function()
        tru(not Decide.sellEligible(1, 9999, 0), "no pickup for a good the hub doesn't sell")
    end)

    runner:test("sellEligible: false at zero stock, every tier (empty-buyer regression)", function()
        tru(not Decide.sellEligible(1, 0, 1000))
        tru(not Decide.sellEligible(2, 0, 1000))
        tru(not Decide.sellEligible(3, 0, 1000))
    end)

    runner:test("sellEligible: tier 1 sells at any positive stock", function()
        tru(Decide.sellEligible(1, 1, 1000), "1/1000 is enough for tier 1")
    end)

    runner:test("sellEligible: tier 2 needs fill >= 30% (inclusive boundary)", function()
        tru(not Decide.sellEligible(2, 299, 1000), "29.9% below the product threshold")
        tru(Decide.sellEligible(2, 300, 1000), "exactly 30% qualifies")
        tru(Decide.sellEligible(2, 900, 1000))
    end)

    runner:test("sellEligible: tier 3 needs fill >= 80% (inclusive boundary)", function()
        tru(not Decide.sellEligible(3, 799, 1000), "79.9% below the ingredient threshold")
        tru(Decide.sellEligible(3, 800, 1000), "exactly 80% qualifies")
    end)

    runner:test("sellEligible thresholds are the exported constants", function()
        eq(Decide.SELL_FILL_PRODUCT, 0.30)
        eq(Decide.SELL_FILL_INGREDIENT, 0.80)
    end)
end
