package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq   = OmniHubTest.assertEqual
local nilf = OmniHubTest.assertNil

-- Is MCM installed in this VM? config.lua binds it the same way (pcall include "mcm"). When MCM is
-- absent, OmniHubConfig.get returns the built-in fractional defaults; when present it returns the
-- admin's live (possibly customized) values — so the default-equality checks below only hold without
-- MCM. The MCM-present behavior is exercised by the integration suite's MCM round-trip instead.
local function mcmInstalled()
    local ok, mcm = pcall(include, "mcm")
    return ok and mcm ~= nil
end

-- The documented fractional defaults (percent keys already divided by 100). Reused by both the
-- static-table check and the MCM-absent get() check so the two can never drift apart.
local DOCUMENTED = {
    {key = "moduleCap",             value = -1},
    {key = "dropChance",            value = 0.5},
    {key = "modulePriceFactor",     value = 1.0},
    {key = "traderRequestCooldown", value = 90},
    {key = "sellingModuleCount",    value = 10},
    {key = "stockMin",              value = 5},
    {key = "stockMax",              value = 20},
    {key = "foundingCostMillions",  value = 15},
}

return function(runner)
    runner:suite("config")

    runner:test("module contract: get + defaults exist", function()
        eq(type(OmniHubConfig.get),      "function", "OmniHubConfig.get is a function")
        eq(type(OmniHubConfig.defaults), "table",    "OmniHubConfig.defaults is a table")
        for _, key in ipairs({"moduleCap", "dropChance", "modulePriceFactor",
                              "traderRequestCooldown", "sellingModuleCount", "stockMin", "stockMax",
                              "foundingCostMillions"}) do
            OmniHubTest.assertNotNil(OmniHubConfig.defaults[key], "defaults has key: " .. key)
        end
    end)

    -- The defaults table is derived from the schema and is NEVER affected by MCM, so its documented
    -- fractional values can be asserted in any environment (engine or off-engine, MCM or not).
    runner:test("defaults table holds documented fractional defaults", function()
        for _, d in ipairs(DOCUMENTED) do
            eq(OmniHubConfig.defaults[d.key], d.value, d.key .. " default (fraction)")
        end
    end)

    -- get() mirrors the documented defaults ONLY when MCM is absent. With MCM installed it returns
    -- the admin's live values — covered by the integration MCM round-trip — so this path is skipped,
    -- with the reason printed to the log.
    runner:test("get returns documented defaults (no MCM)", function()
        if mcmInstalled() then
            print("[OmniHubTest] config: skipping get()==default checks — MCM is installed; "
                .. "live values are admin-controlled (covered by integration MCM round-trip)")
            return
        end
        for _, d in ipairs(DOCUMENTED) do
            eq(OmniHubConfig.get(d.key), d.value, d.key .. " via get()")
        end
    end)

    runner:test("get returns nil for unknown key", function()
        nilf(OmniHubConfig.get("doesNotExist"), "unknown key should be nil")
    end)
end
