package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq   = OmniHubTest.assertEqual
local nilf = OmniHubTest.assertNil

-- Pure suite: with MCM absent (the off-engine harness has no "mcm" module), OmniHubConfig.get
-- returns the built-in fractional defaults. Percent keys must come back as fractions, not percents.
return function(runner)
    runner:suite("config")

    runner:test("module contract: get + defaults exist", function()
        eq(type(OmniHubConfig.get),      "function", "OmniHubConfig.get is a function")
        eq(type(OmniHubConfig.defaults), "table",    "OmniHubConfig.defaults is a table")
        for _, key in ipairs({"moduleCap", "dropChance", "modulePriceFactor",
                              "traderRequestCooldown", "sellingModuleCount"}) do
            OmniHubTest.assertNotNil(OmniHubConfig.defaults[key], "defaults has key: " .. key)
        end
    end)

    runner:test("get returns documented defaults", function()
        eq(OmniHubConfig.get("moduleCap"),             -1,   "moduleCap default")
        eq(OmniHubConfig.get("dropChance"),            0.5,  "dropChance default (fraction)")
        eq(OmniHubConfig.get("modulePriceFactor"),     1.0,  "modulePriceFactor default (fraction)")
        eq(OmniHubConfig.get("traderRequestCooldown"), 90,   "traderRequestCooldown default")
        eq(OmniHubConfig.get("sellingModuleCount"),    10,   "sellingModuleCount default")
    end)

    runner:test("get returns nil for unknown key", function()
        nilf(OmniHubConfig.get("doesNotExist"), "unknown key should be nil")
    end)
end
