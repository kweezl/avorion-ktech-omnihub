package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local TradingUtility    = include("tradingutility")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local fls  = OmniHubTest.assertFalse
local notn = OmniHubTest.assertNotNil

---@diagnostic disable: undefined-global

local function firstCatalogKey()
    for key in pairs(OmniHubModuleDefs.getCatalog()) do return key end
end
local function recipeOf(key) return OmniHubModuleDefs.resolveRecipe(key) end

return function(runner)
    runner:suite("autotrade")

    local OmniHub = _G.OmniHub
    if not OmniHub then
        runner:test("OmniHub namespace available", function()
            notn(nil, "OmniHub global not found — run from a live station")
        end)
        return
    end

    -- A1: our controller is registered with the ambient trader allow-list, and the live station
    -- resolves the trade-API methods through that "/basename.lua" entry (the spike).
    runner:test("controller is registered as a tradeable script (A1)", function()
        local present = false
        for _, s in ipairs(TradingUtility.getTradeableScripts()) do
            if s == "/omnihubcontroller.lua" then present = true break end
        end
        tru(present, "/omnihubcontroller.lua is in the tradeable-script allow-list")
    end)

    -- A2: drive the real spawn helpers with the spawner monkey-patched to capture calls.
    runner:test("trySpawn* honours the pure decision (A2: no spawn for non-tradeable goods)", function()
        local snapshot = OmniHub.secure()
        local key   = firstCatalogKey()
        local prod  = recipeOf(key)
        notn(prod, "module resolves to a recipe")
        local resultName = prod.results[1].name

        -- Capture spawner calls instead of spawning ships.
        local origSeller, origBuyer = TradingUtility.spawnSeller, TradingUtility.spawnBuyer
        local calls = {}
        TradingUtility.spawnSeller = function(_, _, name, amount) calls[#calls+1] = {kind="seller", name=name, amount=amount} end
        TradingUtility.spawnBuyer  = function(_, _, name)         calls[#calls+1] = {kind="buyer",  name=name} end

        local ok, err = pcall(function()
            local entity = Entity()

            -- Case 1 (A2): result NOT marked Sell -> getMaxGoods 0 -> NO buyer, NO crash, NO negative.
            OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                              sellEnabled = {}, buyEnabled = {}, tradingData = snapshot.tradingData })
            calls = {}
            OmniHub.trySpawnSeller(entity, { name = resultName, amount = 999999 }, false)
            OmniHub.trySpawnBuyer(entity, { name = resultName, amount = 1 }, false)
            eq(#calls, 0, "no spawn for a good that isn't externally tradeable")

            -- Case 2: result marked Sell -> tradeable. A low-stock SELLER request yields a
            -- NON-NEGATIVE amount (the pre-fix bug produced a negative amount here).
            OmniHub.restore({ installed = { [key] = 1 }, productionProgress = {}, traderCooldown = 0,
                              sellEnabled = { [resultName] = true }, buyEnabled = {}, tradingData = snapshot.tradingData })
            calls = {}
            local spawned = OmniHub.trySpawnSeller(entity, { name = resultName, amount = 999999 }, false)
            if spawned then
                eq(#calls, 1, "exactly one seller spawn recorded")
                eq(calls[1].kind, "seller", "it was a seller")
                tru(calls[1].amount >= 0, "seller amount is non-negative (A2 fix): " .. tostring(calls[1].amount))
            else
                -- Acceptable: hub already full of the good (maxstock reached) -> no request. Still no crash.
                eq(#calls, 0, "no spawn when nothing to request")
            end
        end)

        -- Always restore patches + station, even on assertion failure.
        TradingUtility.spawnSeller, TradingUtility.spawnBuyer = origSeller, origBuyer
        pcall(function() OmniHub.restore(snapshot) end)
        if not ok then error(err) end
    end)
end
