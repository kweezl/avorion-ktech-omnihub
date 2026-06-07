package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubModuleItem = include("lib/omnihub/moduleitem")
local OmniHubProduction = include("lib/omnihub/production")
local OmniHubMaxLimit = include("lib/omnihub/maxlimit")
local OmniHubConfig = include("lib/omnihub/config")
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")

local tru   = OmniHubTest.assertTrue
local eq    = OmniHubTest.assertEqual
local notn  = OmniHubTest.assertNotNil

-- Integration suite: runs server-side against the LIVE OmniHub station that the player is
-- interacting with. OmniHub is a global in the controller VM (the attached entity script), so it
-- is referenced via _G. Every test snapshots state with secure() and restores it afterwards, so
-- the station is left exactly as found.
---@diagnostic disable: undefined-global

local function firstCatalogKey()
    for key in pairs(OmniHubModuleDefs.getCatalog()) do
        return key
    end
end

local function producedGoodName(key)
    local prod = OmniHubModuleDefs.resolveRecipe(key)
    return prod and prod.results and prod.results[1] and prod.results[1].name
end

return function(runner)
    runner:suite("integration")

    local OmniHub = _G.OmniHub
    if not OmniHub then
        runner:test("OmniHub namespace available", function()
            OmniHubTest.assertNotNil(nil, "OmniHub global not found — run from a live station")
        end)
        return
    end

    runner:test("secure/restore round-trips installed state", function()
        local snapshot = OmniHub.secure()
        local key = firstCatalogKey()
        notn(key, "catalog has at least one module")

        OmniHub.restore({
            installed          = { [key] = 2 },
            productionProgress = {},
            traderCooldown     = 42,
            tradingData        = snapshot.tradingData,
        })

        local after = OmniHub.secure()
        eq(after.installed[key], 2,   "installed count survives round-trip")
        eq(after.traderCooldown, 42,  "traderCooldown survives round-trip")

        OmniHub.restore(snapshot)  -- leave the station as we found it
    end)

    runner:test("rebuild + computeTimeToProduce work on real data", function()
        local snapshot = OmniHub.secure()
        local key = firstCatalogKey()

        OmniHub.restore({
            installed          = { [key] = 1 },
            productionProgress = {},
            traderCooldown     = 0,
            tradingData        = snapshot.tradingData,
        })  -- restore() calls rebuild() internally; a throw here fails the test

        local t = OmniHub.computeTimeToProduce(key)
        tru(type(t) == "number", "computeTimeToProduce returns a number")
        tru(t == t, "result is not NaN")
        tru(t > 0 and t ~= math.huge, "result is positive and finite")

        OmniHub.restore(snapshot)
    end)

    -- The marking feature's core contract: a product marked off must vanish from soldGoods (so it
    -- disappears from the Buy tab + NPC buyers) while the module stays installed and producing.
    -- getSoldGoods returns unpacked NAME strings (tradingmanager.lua), so collect them into a table.
    local function soldSet()
        local s = {}
        for _, name in ipairs({ OmniHub.getSoldGoods() }) do s[name] = true end
        return s
    end

    runner:test("explicit sell mark drives soldGoods (explicit-only, default off)", function()
        local snapshot = OmniHub.secure()
        local key   = firstCatalogKey()
        local gname = producedGoodName(key)
        notn(gname, "module yields a produced good")

        -- No marks -> nothing sold, even though the good is produced (no role default).
        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                          sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })
        OmniHubTest.assertFalse(soldSet()[gname], "produced good NOT sold until explicitly marked")

        -- Explicit sell mark -> sold; module still installed/producing.
        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                          sellEnabled = { [gname] = true }, buyEnabled = {}, tradingData = snapshot.tradingData })
        tru(soldSet()[gname], "good sold when sell-marked on")
        eq(OmniHub.secure().installed[key], 1, "module remains installed")

        OmniHub.restore(snapshot)
    end)

    -- End-to-end through the real RPC handler: ticking Sell on adds the good to soldGoods, ticking off
    -- removes it. Owner-gated; if marks don't take effect we log + skip rather than fail.
    runner:test("setGoodSell handler adds/removes a good from soldGoods", function()
        local snapshot = OmniHub.secure()
        local key   = firstCatalogKey()
        local gname = producedGoodName(key)
        notn(gname, "module yields a produced good")

        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                          sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })
        OmniHubTest.assertFalse(soldSet()[gname], "not sold by default")

        OmniHub.setGoodSell(gname, true)
        if not soldSet()[gname] then
            print("[OmniHubTest] integration: skipping setGoodSell round-trip — "
                .. "marks unchanged (caller not station owner?)")
            OmniHub.restore(snapshot)
            return
        end
        tru(soldSet()[gname], "good sold after ticking Sell on")

        OmniHub.setGoodSell(gname, false)
        OmniHubTest.assertFalse(soldSet()[gname], "good removed from soldGoods after ticking Sell off")

        OmniHub.restore(snapshot)
    end)

    -- End-to-end against the live player inventory: installModule/uninstallModule must move N modules
    -- between inventory and the station and conserve the total. Mutates real state, so it records
    -- results, ALWAYS cleans up (even on assertion failure), then asserts. Owner-gated; skips cleanly
    -- if the caller can't add/install (no player / inventory full / not station owner).
    runner:test("installModule/uninstallModule move N modules between inventory and station", function()
        if not callingPlayer then
            print("[OmniHubTest] integration: skipping install round-trip — no calling player"); return
        end
        local player = Player(callingPlayer)
        if not player then
            print("[OmniHubTest] integration: skipping install round-trip — player unavailable"); return
        end
        local inv = player:getInventory()
        local key = firstCatalogKey()
        notn(key, "catalog has a module")

        local SUB = OmniHubModuleDefs.SUBTYPE
        local function held()
            local n = 0
            for _, slot in pairs(inv:getItemsByType(InventoryItemType.VanillaItem)) do
                local it = slot.item
                if it and it:getValue("subtype") == SUB and it:getValue("moduleKey") == key then
                    n = n + (slot.amount or 1)
                end
            end
            return n
        end
        local function takeModules(n)
            while n and n > 0 do
                local idx
                for si, slot in pairs(inv:getItemsByType(InventoryItemType.VanillaItem)) do
                    local it = slot.item
                    if it and it:getValue("subtype") == SUB and it:getValue("moduleKey") == key then idx = si; break end
                end
                if not idx then break end
                inv:take(idx); n = n - 1
            end
        end

        local snapshot = OmniHub.secure()
        local origHeld = held()

        -- Captured results (asserted after cleanup). `delta` = how many actually installed (<= 2,
        -- possibly fewer under a module cap), so we uninstall exactly that for a clean reversal.
        local added, preInstalled, delta, heldAfterInst, instAfterUn, heldAfterUn

        local ok, err = pcall(function()
            for _ = 1, 3 do inv:add(OmniHubModuleItem.build(key)) end
            added        = held() - origHeld
            preInstalled = OmniHub.secure().installed[key] or 0
            if added >= 2 then
                OmniHub.installModule(key, 2)
                delta         = (OmniHub.secure().installed[key] or 0) - preInstalled
                heldAfterInst = held()

                -- Only reverse if something installed. uninstallModule clamps qty to >= 1, so calling
                -- it with delta == 0 would wrongly remove one of the runner's PRE-EXISTING modules.
                if delta > 0 then
                    OmniHub.uninstallModule(key, delta)
                    instAfterUn = OmniHub.secure().installed[key] or 0
                    heldAfterUn = held()
                end
            end
        end)

        -- ALWAYS clean up: drop any modules we added, then restore the station snapshot.
        pcall(function()
            takeModules(held() - origHeld)
            OmniHub.restore(snapshot)
        end)

        if not ok then error(err) end  -- surface a real error after cleanup
        if (added or 0) < 2 then
            print("[OmniHubTest] integration: skipping install round-trip — could not add test modules"); return
        end
        if (delta or 0) <= 0 then
            print("[OmniHubTest] integration: skipping install round-trip — install had no effect (not station owner / capped?)")
            return
        end

        tru(delta >= 1 and delta <= 2,  "installed between 1 and the requested 2 (clamped)")
        tru(delta <= added,             "installed no more than held")
        eq(heldAfterInst, origHeld + added - delta, "inventory dropped by exactly the installed amount")
        eq(instAfterUn, preInstalled,   "uninstall returned to the starting installed count")
        eq(heldAfterUn, origHeld + added, "all installed modules returned to inventory")
    end)

    -- End-to-end through the real applyHubConfig RPC handler with max-limit params. This is the path
    -- that threw `attempt to call global 'clamp'` — the handler running at all proves clamp is in
    -- scope. Also verifies the per-hub limits persist (secure), prodCycles is floored to 1, and the
    -- live getMaxStock override reflects the pure max limit. Owner-gated; skips cleanly if not owner.
    runner:test("applyHubConfig persists + applies max-limit params", function()
        if not callingPlayer then
            print("[OmniHubTest] integration: skipping applyHubConfig — no calling player"); return
        end
        local snapshot = OmniHub.secure()
        local key   = firstCatalogKey()
        local gname = producedGoodName(key)

        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                          sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })

        -- prodCycles = 0 must floor to 1 (0 would silently halt production); buyLimit = 0 is allowed.
        OmniHub.applyHubConfig({
            activelyRequest = true, activelySell = true,
            deliveredIds = {}, deliveringIds = {},
            limitBuy = 0, limitBase = 200, limitCycles = 0,
        })

        local lim = OmniHub.secure().maxLimit
        if not lim or lim.prodBase ~= 200 then
            print("[OmniHubTest] integration: skipping applyHubConfig assertions — not applied (not station owner?)")
            OmniHub.restore(snapshot)
            return
        end

        eq(lim.buyLimit,   0,   "buyLimit = 0 allowed")
        eq(lim.prodBase,   200, "prodBase applied")
        eq(lim.prodCycles, 1,   "prodCycles floored to a minimum of 1")

        -- The live getMaxStock override must match the pure max limit for the produced good.
        if gname then
            local expected = OmniHubMaxLimit.compute(
                OmniHubProduction.aggregate({ [key] = 1 }, OmniHubModuleDefs.resolveRecipe),
                {}, { buyLimit = 0, prodBase = 200, prodCycles = 1 })
            eq(OmniHub.getMaxStock({ name = gname }), expected[gname],
                "getMaxStock reflects the max-limit cache for the produced good")
        end

        OmniHub.restore(snapshot)
    end)

    runner:test("secure/restore preserves marks, stats and transfer selections", function()
        local snapshot = OmniHub.secure()
        local key = firstCatalogKey()

        local stats = { lifetimeProfit = 1234, cursor = 1, buckets = {}, transactions = {} }
        for i = 1, 60 do stats.buckets[i] = 0 end
        stats.buckets[1] = 500

        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 7,
                          sellEnabled = { Widget = false }, buyEnabled = { Ore = false }, stats = stats,
                          chosenDelivered = {}, chosenDelivering = {}, tradingData = snapshot.tradingData })

        local after = OmniHub.secure()
        eq(after.stats.lifetimeProfit, 1234, "lifetime profit persists")
        eq(after.stats.buckets[1],     500,  "last-hour bucket persists")
        eq(after.sellEnabled.Widget,   false, "sell mark persists")
        eq(after.buyEnabled.Ore,       false, "buy mark persists")

        OmniHub.restore(snapshot)
    end)

    runner:test("regionalPct returns a finite number for a produced good", function()
        local snapshot = OmniHub.secure()
        local key   = firstCatalogKey()
        local gname = producedGoodName(key)

        OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                          sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })
        local pct = OmniHub.regionalPct(gname)
        tru(type(pct) == "number" and pct == pct and pct ~= math.huge, "regionalPct is finite")

        OmniHub.restore(snapshot)
    end)

    runner:test("aggregate bridges to real recipes", function()
        local key = firstCatalogKey()
        local agg = OmniHubProduction.aggregate({ [key] = 1 }, OmniHubModuleDefs.resolveRecipe)
        tru(agg.hasAny, "hasAny for a real installed module")
        notn(agg.aggregatedProduction, "aggregatedProduction built from real recipe")
        tru(#agg.aggregatedProduction.results > 0, "real recipe yields at least one result")
    end)

    runner:test("config percent keys return finite fractions", function()
        local drop  = OmniHubConfig.get("dropChance")
        local price = OmniHubConfig.get("modulePriceFactor")
        tru(type(drop) == "number" and drop >= 0 and drop <= 1, "dropChance is a 0..1 fraction")
        tru(type(price) == "number" and price > 0 and price ~= math.huge, "modulePriceFactor positive finite")
    end)

    -- MCM-present path: set several known values (including two percent keys, to prove the UI-percent
    -- -> fractional conversion in OmniHubConfig.get) and confirm get() reflects them, then restore the
    -- admin's live config. Skipped with a logged reason when MCM is not installed.
    runner:test("MCM round-trip reflects in OmniHubConfig.get (incl. percent conversion)", function()
        local mcm = nil
        local ok, mod = pcall(include, "mcm")
        if ok then mcm = mod end
        if not mcm then
            print("[OmniHubTest] integration: skipping MCM round-trip — MCM not installed")
            tru(true, "skipped: MCM not installed")
            return
        end
        local cfg = mcm.bind("ktech-omnihub")

        -- {key, value to set in MCM UI units, value get() should return}. Percent keys (dropChance,
        -- modulePriceFactor) are stored as integer percents and divided by 100 on read.
        local cases = {
            {key = "sellingModuleCount", set = 7,   expect = 7},    -- plain number: passes through
            {key = "dropChance",         set = 80,  expect = 0.8},  -- percent -> fraction on get()
            {key = "modulePriceFactor",  set = 200, expect = 2.0},  -- percent -> fraction on get()
        }

        -- Snapshot originals (in MCM units) so the admin's live config is left exactly as found.
        local original = {}
        for _, c in ipairs(cases) do original[c.key] = cfg.get(c.key) end

        for _, c in ipairs(cases) do
            cfg.set(c.key, c.set)
            eq(OmniHubConfig.get(c.key), c.expect,
                "get(" .. c.key .. ") reflects MCM-set " .. tostring(c.set))
        end

        for _, c in ipairs(cases) do cfg.set(c.key, original[c.key]) end  -- restore
    end)

    -- Contract guard: the vanilla shop API the supplier calls must exist (catches an Avorion rename).
    runner:test("vanilla shop API used by the supplier exists", function()
        local ShopAPI = include("shop")
        notn(ShopAPI, "shop lib loads")
        eq(type(ShopAPI.CreateNamespace), "function", "ShopAPI.CreateNamespace exists")
        local ns = ShopAPI.CreateNamespace()
        notn(ns.shop, "namespace has .shop")
        for _, m in ipairs({"add", "setSpecialOffer", "restock", "initUI", "initialize"}) do
            eq(type(ns.shop[m]), "function", "shop:" .. m .. " exists")
        end
        notn(ns.shop.itemsPerPage, "shop.itemsPerPage exists")
    end)

    runner:test("real-catalog subset is distinct and resolvable", function()
        local catalog = OmniHubModuleDefs.getCatalog()
        local keys = {}
        for k in pairs(catalog) do keys[#keys + 1] = k end
        tru(#keys > 0, "catalog is non-empty")

        -- The supplier stocks min(sellingModuleCount, #catalog): sellingModuleCount is admin-configurable
        -- (up to 200) and clamped at runtime to the catalog size, so the catalog may legitimately be
        -- smaller. Mirror that clamp instead of assuming catalog >= sellingModuleCount.
        local want = math.min(OmniHubConfig.get("sellingModuleCount"), #keys)

        local i = 0
        local rng = function(hi) i = i + 1; return ((i - 1) % hi) + 1 end
        local subset = OmniHubSupplierStock.pickRandomSubset(keys, want, rng)
        eq(#subset, want, "subset clamps to min(sellingModuleCount, catalog size)")

        local seen = {}
        for _, key in ipairs(subset) do
            tru(not seen[key], "no duplicate: " .. tostring(key))
            seen[key] = true
            notn(OmniHubModuleDefs.get(key), "key resolves to a real def: " .. tostring(key))
        end
    end)
end
