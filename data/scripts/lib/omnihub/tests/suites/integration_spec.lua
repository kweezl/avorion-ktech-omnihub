package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubProduction = include("lib/omnihub/production")

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
end
