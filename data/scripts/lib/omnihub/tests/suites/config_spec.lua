package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq  = OmniHubTest.assertEqual
local nilf = OmniHubTest.assertNil

-- Pure suite: OmniHubConfig.get returns documented defaults (no server override exists yet).
return function(runner)
    runner:suite("config")

    runner:test("get returns documented defaults", function()
        eq(OmniHubConfig.get("moduleCap"),             -1,   "moduleCap default")
        eq(OmniHubConfig.get("dropChance"),            0.5,  "dropChance default")
        eq(OmniHubConfig.get("modulePriceFactor"),     1.0,  "modulePriceFactor default")
        eq(OmniHubConfig.get("traderRequestCooldown"), 90,   "traderRequestCooldown default")
    end)

    runner:test("get returns nil for unknown key", function()
        nilf(OmniHubConfig.get("doesNotExist"), "unknown key should be nil")
    end)
end
