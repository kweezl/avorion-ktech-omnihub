package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest = include("lib/omnihub/tests/framework")
local Decide      = include("lib/omnihub/tradingdecision")

local eq   = OmniHubTest.assertEqual
local near = OmniHubTest.assertNear
local tru  = OmniHubTest.assertTrue
local fls  = OmniHubTest.assertFalse
local nilq = OmniHubTest.assertNil
local notn = OmniHubTest.assertNotNil

-- Query stub: per-good stock/max/price/size maps (price defaults 100, size defaults 1).
local function query(stock, max, price, size)
    return {
        getNumGoods = function(n) return stock[n] or 0 end,
        getMaxGoods = function(n) return max[n] or 0 end,
        goodPrice   = function(n) if price and price[n] ~= nil then return price[n] end return 100 end,
        getGoodSize = function(n) return (size and size[n]) or 1 end,
    }
end

-- Deterministic rng stub: test() returns `testResult`; random01() returns 0.5 (no 20% high-value
-- budget roll; buyer amounts become floor(100 + 0.5*1000 + 0.5) = 600).
local function rng(testResult)
    return {
        test     = function(_, _) return testResult end,
        random01 = function() return 0.5 end,
    }
end

-- agg fixture: one ingredient to deliver, one sell-marked product (tier 2) to pick up.
local AGG = {
    ingredients = { { name = "ore",   amount = 10 } },
    sold        = { { name = "plate", tier = 2 } },
}

return function(runner)
    runner:suite("wave")

    -- ── transactionList ─────────────────────────────────────────────────────
    runner:test("transactionList orders deliveries before pickups (frees hold for pickups)", function()
        local ops = Decide.transactionList({
            deliveries = { { name = "ore", amount = 7 } },
            pickups    = { { name = "plate", amount = 3 }, { name = "scrap", amount = 1 } },
        })
        eq(#ops, 3)
        eq(ops[1].kind, "deliver"); eq(ops[1].name, "ore");   eq(ops[1].amount, 7)
        eq(ops[2].kind, "pickup");  eq(ops[2].name, "plate"); eq(ops[2].amount, 3)
        eq(ops[3].kind, "pickup");  eq(ops[3].name, "scrap")
    end)

    -- ── partialBuyAmount (partial-purchase retry for docked deliveries) ─────
    runner:test("partialBuyAmount buys HALF of what the balance covers (reserves budget for other deliveries)", function()
        eq(Decide.partialBuyAmount(12510375, 50775), 123, "floor(floor(balance/unit) / 2)")
        eq(Decide.partialBuyAmount(200000, 50000), 2)
        eq(Decide.partialBuyAmount(100000, 50000), 1)
        eq(Decide.partialBuyAmount(99999, 50000), 0, "half of 1 affordable unit floors to 0 -> skip")
        eq(Decide.partialBuyAmount(49999, 50000), 0, "can't afford one unit")
        eq(Decide.partialBuyAmount(0, 50000), 0)
        eq(Decide.partialBuyAmount(100000, 0), 0, "free/unknown unit price -> no retry math")
        eq(Decide.partialBuyAmount(nil, 50000), 0)
    end)

    -- ── shouldFlyOut (trader TTL) ───────────────────────────────────────────
    runner:test("shouldFlyOut triggers at/after the TTL, never for invalid TTLs", function()
        fls(Decide.shouldFlyOut(599, 600))
        tru(Decide.shouldFlyOut(600, 600))
        tru(Decide.shouldFlyOut(9999, 600))
        fls(Decide.shouldFlyOut(9999, 0),   "ttl 0 disables the watchdog")
        fls(Decide.shouldFlyOut(9999, nil), "nil ttl disables the watchdog")
    end)

    -- ── waveSize ────────────────────────────────────────────────────────────
    runner:test("waveSize = min(config, docks - live traders), floored at 0", function()
        eq(Decide.waveSize(3, 10, 0), 3,  "config caps")
        eq(Decide.waveSize(6, 4, 2),  2,  "free docks cap")
        eq(Decide.waveSize(3, 2, 5),  0,  "more traders than docks -> 0")
        eq(Decide.waveSize(3, 0, 0),  0,  "no docks -> 0")
        eq(Decide.waveSize(0, 9, 0),  0,  "config 0 -> 0")
    end)

    -- ── waveGate ────────────────────────────────────────────────────────────
    runner:test("waveGate starts on zero live traders and resets the block counter", function()
        local g = Decide.waveGate(0, 3, 4)
        tru(g.start); fls(g.forced); eq(g.blocked, 0)
    end)

    runner:test("waveGate blocks and counts while traders linger", function()
        local g = Decide.waveGate(2, 0, 4)
        fls(g.start); fls(g.forced); eq(g.blocked, 1)
        g = Decide.waveGate(2, g.blocked, 4)
        fls(g.start); eq(g.blocked, 2)
    end)

    runner:test("waveGate forces a start after the threshold and resets", function()
        local g = Decide.waveGate(1, 3, 4)  -- 4th consecutive blocked window
        tru(g.start); tru(g.forced); eq(g.blocked, 0)
    end)

    -- ── planWave ────────────────────────────────────────────────────────────
    runner:test("planWave returns no manifests when nothing is eligible (A2 exclusion)", function()
        -- Neither good externally tradeable (getMaxGoods == 0 everywhere).
        local m = Decide.planWave(AGG, query({}, {}), rng(true), { maxShips = 3 })
        eq(#m, 0)
    end)

    runner:test("planWave returns no manifests for maxShips <= 0", function()
        local q = query({ ore = 0 }, { ore = 9000 })
        eq(#Decide.planWave(AGG, q, rng(true), { maxShips = 0 }), 0)
    end)

    runner:test("planWave packs a mixed manifest (delivery + pickup) into one ship", function()
        -- ore buy-marked, empty -> delivery min(9000,500)-0 = 500.
        -- plate sell-marked, tier 2 at 900/1000 fill (>=30%) -> pickup, amount 600 (rng stub).
        local q = query({ ore = 0, plate = 900 }, { ore = 9000, plate = 1000 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 3 })
        eq(#m, 1, "one mixed ship")
        eq(#m[1].deliveries, 1); eq(m[1].deliveries[1].name, "ore");   eq(m[1].deliveries[1].amount, 500)
        eq(#m[1].pickups, 1);    eq(m[1].pickups[1].name, "plate");    eq(m[1].pickups[1].amount, 600)
    end)

    runner:test("planWave immediate mode scales deliveries by 0.3 (vanilla)", function()
        local q = query({ ore = 0 }, { ore = 9000 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 1, immediate = true })
        eq(m[1].deliveries[1].amount, 150, "round(500 * 0.3)")
    end)

    runner:test("planWave splits an overflowing item across ships at the per-ship value cap", function()
        -- delivery 500 units @ price 100 = 50000 value; cap 30000/ship -> 300 + 200.
        local q = query({ ore = 0 }, { ore = 9000 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 3, shipValue = 30000 })
        eq(#m, 2)
        eq(m[1].deliveries[1].amount, 300)
        eq(m[2].deliveries[1].amount, 200)
    end)

    runner:test("planWave drops the surplus when maxShips truncates the wave", function()
        local q = query({ ore = 0 }, { ore = 9000 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 1, shipValue = 30000 })
        eq(#m, 1)
        eq(m[1].deliveries[1].amount, 300, "second ship's 200 wait for the next wave")
    end)

    runner:test("planWave skips an unshippable item (one unit over a fresh budget) without hanging", function()
        -- gold price 50000 > cap 30000: even one unit never fits; ore still ships.
        local agg = {
            ingredients = { { name = "gold", amount = 5 }, { name = "ore", amount = 10 } },
            sold = {},
        }
        local q = query({ gold = 0, ore = 0 }, { gold = 100, ore = 9000 }, { gold = 50000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 3, shipValue = 30000 })
        eq(#m, 2, "ore alone still value-splits into two ships")
        for _, ship in ipairs(m) do
            for _, d in ipairs(ship.deliveries) do
                tru(d.name ~= "gold", "gold never shipped")
            end
        end
        eq(m[1].deliveries[1].name, "ore"); eq(m[1].deliveries[1].amount, 300)
        eq(m[2].deliveries[1].amount, 200)
    end)

    runner:test("planWave immediate mode clamps pickups to current stock (code-1 regression)", function()
        -- Tier 1 is eligible at ANY positive stock: ship mode plans optimistically (production
        -- accrues during the fly-in; sellToShip clamps at dock), but immediate mode sells
        -- INSTANTLY — an optimistic amount comes back as vanilla error 1. No stock -> no pickup.
        local agg = { ingredients = AGG.ingredients, sold = { { name = "plate", tier = 1 } } }
        local q = query({ ore = 0, plate = 0 }, { ore = 9000, plate = 1000 }, { plate = 30000 })
        local m = Decide.planWave(agg, q, rng(true), { maxShips = 3, immediate = true })
        for _, ship in ipairs(m) do
            eq(#ship.pickups, 0, "no pickup planned against zero stock in immediate mode")
        end

        -- Partial stock clamps the amount (the rng stub would otherwise plan 600).
        q = query({ ore = 0, plate = 150 }, { ore = 9000, plate = 1000 }, { plate = 30000 })
        m = Decide.planWave(agg, q, rng(true), { maxShips = 3, immediate = true })
        local found
        for _, ship in ipairs(m) do
            for _, p in ipairs(ship.pickups) do
                if p.name == "plate" then found = p end
            end
        end
        notn(found, "pickup planned against real stock")
        eq(found.amount, 150, "clamped to current stock")
    end)

    runner:test("planWave never plans a pickup for a good with ZERO stock (any mode)", function()
        -- Even tier 1 ("sell ASAP") needs stock > 0; without this rule a buyer flies in, docks,
        -- and leaves empty ("docked pickup ... moved NO stock").
        local q = query({ plate = 0 }, { plate = 1000 }, { plate = 30000 })
        local m = Decide.planWave({ ingredients = {}, sold = { { name = "plate", tier = 1 } } },
            q, rng(true), { maxShips = 1 })
        eq(#m, 0, "no manifests at all — nothing else was eligible")
    end)

    runner:test("planWave ship mode keeps optimistic pickup amounts once stock exists", function()
        -- Stock 5 (>0): the pickup is planned with the vanilla optimistic amount — production
        -- accrues during the fly-in and sellToShip clamps to the real stock at dock time.
        local q = query({ plate = 5 }, { plate = 1000 }, { plate = 30000 })
        local m = Decide.planWave({ ingredients = {}, sold = { { name = "plate", tier = 1 } } },
            q, rng(true), { maxShips = 1 })
        eq(#m, 1)
        eq(m[1].pickups[1].amount, 600, "optimistic amount; dock-time clamp handles the rest")
    end)

    -- ── tiered pickup ordering ──────────────────────────────────────────────
    runner:test("planWave orders pickups tier-ascending (non-chain, then products, then ingredients)", function()
        -- All three eligible: scrap t1 at any stock, plate t2 at 50% (>=30%), wire t3 at 90% (>=80%).
        -- Listed in reverse order to prove the sort, not the input order, decides.
        local agg = { ingredients = {}, sold = {
            { name = "wire",  tier = 3 },
            { name = "plate", tier = 2 },
            { name = "scrap", tier = 1 },
        } }
        local q = query({ scrap = 100, plate = 500, wire = 900 },
            { scrap = 1000, plate = 1000, wire = 1000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 1 })
        eq(#m, 1)
        eq(#m[1].pickups, 3)
        eq(m[1].pickups[1].name, "scrap", "tier 1 first despite lowest fill")
        eq(m[1].pickups[2].name, "plate", "tier 2 second")
        eq(m[1].pickups[3].name, "wire",  "tier 3 last")
    end)

    runner:test("planWave orders same-tier pickups by fill ratio descending (most stock first)", function()
        -- Both tier 1; bolts 70% fill must beat nuts 20% even though nuts has more units.
        local agg = { ingredients = {}, sold = {
            { name = "nuts",  tier = 1 },
            { name = "bolts", tier = 1 },
        } }
        local q = query({ nuts = 2000, bolts = 700 }, { nuts = 10000, bolts = 1000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 1 })
        eq(m[1].pickups[1].name, "bolts", "70% fill before 20% fill")
        eq(m[1].pickups[2].name, "nuts")
    end)

    runner:test("planWave breaks equal tier+fill ties by name (deterministic)", function()
        local agg = { ingredients = {}, sold = {
            { name = "zinc", tier = 1 },
            { name = "coal", tier = 1 },
        } }
        local q = query({ zinc = 500, coal = 500 }, { zinc = 1000, coal = 1000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 1 })
        eq(m[1].pickups[1].name, "coal")
        eq(m[1].pickups[2].name, "zinc")
    end)

    runner:test("planWave filters each tier by its own threshold in one wave", function()
        -- plate t2 at 29% is OUT; wire t3 at 79% is OUT; scrap t1 at 1% is IN.
        local agg = { ingredients = {}, sold = {
            { name = "scrap", tier = 1 },
            { name = "plate", tier = 2 },
            { name = "wire",  tier = 3 },
        } }
        local q = query({ scrap = 10, plate = 290, wire = 790 },
            { scrap = 1000, plate = 1000, wire = 1000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 1 })
        eq(#m, 1)
        eq(#m[1].pickups, 1, "only the tier-1 good qualifies")
        eq(m[1].pickups[1].name, "scrap")
    end)

    runner:test("planWave skips a sold good with no price (unknown catalog entry)", function()
        local agg = { ingredients = {}, sold = { { name = "mystery", tier = 1 } } }
        local q = query({ mystery = 500 }, { mystery = 1000 }, { mystery = false })
        eq(#Decide.planWave(agg, q, rng(false), { maxShips = 1 }), 0)
    end)

    runner:test("planWave orders deliveries by scarcity (lowest have/need first)", function()
        -- BOTH eligible, but "fuel" (listed after "ore" in the agg) is more starved
        -- (0/4 = ratio 0 vs ore 1/2 = ratio 0.5): it must be packed first so a tight
        -- wave/budget feeds the production bottleneck instead of first-listed-wins.
        local agg = {
            ingredients = { { name = "ore", amount = 2 }, { name = "fuel", amount = 4 } },
            sold = {},
        }
        local q = query({ ore = 1, fuel = 0 }, { ore = 9000, fuel = 9000 })
        local m = Decide.planWave(agg, q, rng(false), { maxShips = 1, shipValue = 10000 })
        -- budget 10000 @ price 100 = 100 units total; fuel (scarcity 0) must get them all
        eq(#m, 1)
        eq(m[1].deliveries[1].name, "fuel", "most-starved ingredient packed first")
        eq(m[1].deliveries[1].amount, 100)
    end)

    runner:test("planWave clamps total delivery spend to the owner's budget", function()
        -- ore delivery would be 500 units @ 100 = 50000, but the owner only has 12000:
        -- deliveries cap at 120 units; pickups are NOT budget-limited (they earn money).
        local q = query({ ore = 0, plate = 900 }, { ore = 9000, plate = 1000 })
        local m = Decide.planWave(AGG, q, rng(false),
            { maxShips = 3, budget = 12000, buyFactor = 1.0 })
        local delivered = 0
        local pickedUp  = false
        for _, ship in ipairs(m) do
            for _, d in ipairs(ship.deliveries) do delivered = delivered + d.amount end
            if #ship.pickups > 0 then pickedUp = true end
        end
        eq(delivered, 120, "deliveries clamped to budget/price")
        tru(pickedUp, "pickups unaffected by the buy budget")
    end)

    runner:test("planWave with zero budget plans no deliveries at all", function()
        local q = query({ ore = 0 }, { ore = 9000 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 3, budget = 0 })
        for _, ship in ipairs(m) do
            eq(#ship.deliveries, 0, "no deliveries the owner can't pay for")
        end
    end)

    runner:test("planWave honours the per-ship volume cap when sizes are known", function()
        -- ore size 2, shipVolume 400 -> 200 units per ship; 500 units -> 200 + 200 + 100.
        local q = query({ ore = 0 }, { ore = 9000 }, nil, { ore = 2 })
        local m = Decide.planWave(AGG, q, rng(false), { maxShips = 3, shipVolume = 400 })
        eq(#m, 3)
        eq(m[1].deliveries[1].amount, 200)
        eq(m[2].deliveries[1].amount, 200)
        eq(m[3].deliveries[1].amount, 100)
    end)
end
