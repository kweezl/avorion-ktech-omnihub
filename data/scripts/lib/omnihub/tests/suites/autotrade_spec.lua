package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubStats      = include("lib/omnihub/stats")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local notn = OmniHubTest.assertNotNil
local nilq = OmniHubTest.assertNil

---@diagnostic disable: undefined-global

local function firstCatalogKey()
    for key in pairs(OmniHubModuleDefs.getCatalog()) do return key end
end
local function recipeOf(key) return OmniHubModuleDefs.resolveRecipe(key) end

-- Integration suite hosted in the CONTROLLER's VM (via OmniHub.runDevTests): _G.OmniHub is the
-- live namespace, and the dev seams (getTradingUtilityForTests / getWaveSeamsForTests) expose the
-- exact lib instances the controller calls — patching any other copy would intercept nothing.
return function(runner)
    runner:suite("autotrade")

    local OmniHub = _G.OmniHub
    if not OmniHub then
        runner:test("OmniHub namespace available", function()
            notn(nil, "OmniHub global not found — suite must run in the controller VM (runDevTests)")
        end)
        return
    end

    -- A1: the lib-overlay registration. Because the VFS merges our fragment into tradingutility.lua
    -- itself, EVERY VM's copy of the lib carries the entry — asserting on the controller's instance
    -- therefore proves what sector/traders.lua will see too.
    runner:test("controller is in the tradeable-script allow-list (A1: lib overlay)", function()
        local TU = OmniHub.getTradingUtilityForTests()
        notn(TU, "controller exposes its TradingUtility instance in dev mode")
        local present = false
        for _, s in ipairs(TU.getTradeableScripts()) do
            if s == "/omnihubcontroller.lua" then present = true break end
        end
        tru(present, "/omnihubcontroller.lua is in the tradeable-script allow-list")
    end)

    -- A1 spike: the ambient systems call station:invokeFunction(<allow-list entry>, ...) — assert
    -- the engine resolves our "/basename.lua" suffix to the deployed mod script on a live station.
    runner:test("invokeFunction resolves the /basename.lua entry on the live station (A1 spike)", function()
        local err, sells = Entity():invokeFunction("/omnihubcontroller.lua", "getSellsToOthers")
        eq(err, 0, "invokeFunction resolved /omnihubcontroller.lua (0 = ok)")
        notn(sells, "getSellsToOthers answered through the suffix path")
    end)

    -- A2 + wave model: drive the real requestTraders with the fleet seam patched to capture the
    -- wave instead of spawning ships (and the dock cap stubbed — a test station may have 0 docks).
    runner:test("requestTraders plans a wave honouring the pure decisions (A2 + wave)", function()
        local seams = OmniHub.getWaveSeamsForTests()
        notn(seams, "controller exposes its wave seams in dev mode")
        local Fleet, Decision = seams.fleet, seams.decision

        local snapshot = OmniHub.secure()
        local key  = firstCatalogKey()
        local prod = recipeOf(key)
        notn(prod, "module resolves to a recipe")
        local ingName = prod.ingredients[1] and prod.ingredients[1].name
        notn(ingName, "recipe has an ingredient")

        local origSpawn, origCount, origSize = Fleet.spawnWave, Fleet.countTraders, Decision.waveSize
        local captured
        Fleet.spawnWave    = function(_, manifests) captured = manifests; return #manifests end
        Fleet.countTraders = function() return 0 end
        Decision.waveSize  = function() return 3 end

        local ok, err = pcall(function()
            -- Case 1 (A2): nothing marked -> nothing externally tradeable -> NO wave spawned.
            OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                              sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })
            captured = nil
            OmniHub.requestTraders(1)
            nilq(captured, "no wave for a hub with nothing externally tradeable")

            -- Case 2: ingredient marked Buy -> the wave delivers it with a positive vanilla-capped
            -- amount (the pre-fix A2 bug produced a NEGATIVE amount on this path).
            OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                              sellEnabled = {}, buyEnabled = { [ingName] = true },
                              tradingData = snapshot.tradingData })
            captured = nil
            OmniHub.requestTraders(1)
            if captured then
                local found
                for _, manifest in ipairs(captured) do
                    for _, d in ipairs(manifest.deliveries) do
                        if d.name == ingName then found = d end
                    end
                end
                notn(found, "wave delivers the buy-marked ingredient")
                tru(found.amount > 0,    "delivery amount positive (A2 fix): " .. tostring(found.amount))
                tru(found.amount <= 500, "delivery amount within the vanilla 500 cap")
            else
                -- Acceptable: the live station already holds the ingredient at/above need -> the
                -- pure decision correctly declines. Still no crash, still no wave.
                tru(true)
            end
        end)

        -- Always restore patches + station, even on assertion failure.
        Fleet.spawnWave, Fleet.countTraders, Decision.waveSize = origSpawn, origCount, origSize
        pcall(function() OmniHub.restore(snapshot) end)
        if not ok then error(err) end
    end)

    -- Docked trades (NPC tradeships, players at the trade UI) reach the stats only through the
    -- onTradingManager* entity callbacks — regression for "traders dock but profit stays 0".
    runner:test("docked-trade callbacks record statistics (profit-gap fix)", function()
        local snapshot = OmniHub.secure()
        local ok, err = pcall(function()
            -- Swap in a FRESH stats table first: secure() returns the live stats by reference, so
            -- mutating it before the swap would leak the fake transactions into the snapshot.
            OmniHub.restore({ installed = {}, productionProgress = {}, traderCooldown = 0,
                              sellEnabled = {}, buyEnabled = {}, stats = OmniHubStats.new(),
                              tradingData = snapshot.tradingData })

            OmniHub.onDockedTradeSold("Steel", 3, 4500)    -- station sold -> +4500
            OmniHub.onDockedTradeBought("Ore", 2, 1500)    -- station bought -> -1500

            local s = OmniHub.secure().stats
            eq(s.lifetimeProfit, 3000, "sell adds, buy subtracts (total prices)")
            eq(#s.transactions, 2, "both docked trades logged")
            eq(s.transactions[2].kind, "buy", "latest transaction is the buy")
            eq(s.transactions[1].good, "Steel", "sell row carries the good name")
        end)
        pcall(function() OmniHub.restore(snapshot) end)
        if not ok then error(err) end
    end)
end