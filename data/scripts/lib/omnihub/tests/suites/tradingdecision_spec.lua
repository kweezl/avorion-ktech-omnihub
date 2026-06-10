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

local function rng(result)
    return { test = function(_, _) return result end }
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

    -- ── decideBuyer ─────────────────────────────────────────────────────────────
    runner:test("buyer: nil when good not externally sold (max==0) — A2 regression", function()
        local d = Decide.decideBuyer({name = "Steel", amount = 5}, query({["Steel"] = 9999}, {}), rng(true))
        nilq(d, "no buyer for a good the hub doesn't sell")
    end)

    runner:test("buyer: nil when the good has no price", function()
        local d = Decide.decideBuyer({name = "Mystery", amount = 5},
            query({}, {["Mystery"] = 1000}, {["Mystery"] = false}), rng(true))
        nilq(d)
    end)

    runner:test("buyer: spawns when stock exceeds 80% of max", function()
        local d = Decide.decideBuyer({name = "Steel", amount = 100},
            query({["Steel"] = 800}, {["Steel"] = 1000}), rng(false))
        notn(d); eq(d.name, "Steel")  -- newAmount 900 > 800
    end)

    runner:test("buyer: high-value path gated by rng (true -> spawn, false -> nil)", function()
        -- newAmount below 80% of max, but value > 100000: rng decides.
        local q = query({["Steel"] = 100}, {["Steel"] = 100000}, {["Steel"] = 100})
        local good = {name = "Steel", amount = 1100}  -- newAmount 1200, value 1200*100 = 120000 > 100000
        eq(Decide.decideBuyer(good, q, rng(true)).name, "Steel", "spawns when rng:test true")
        nilq(Decide.decideBuyer(good, q, rng(false)), "no spawn when rng:test false")
    end)
end
