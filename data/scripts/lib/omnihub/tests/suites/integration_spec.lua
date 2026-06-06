package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubProduction = include("lib/omnihub/production")
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
