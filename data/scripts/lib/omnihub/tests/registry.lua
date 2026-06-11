package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubTestRegistry
-- Catalog of test suites, tagged pure (engine-independent) vs integration (needs the live engine).
-- The off-engine runner loads only "pure"; the in-game OmniHub Tests window can run any
-- category: "pure", "integration", or "all".
OmniHubTestRegistry = {}

-- Suite names map to data/scripts/lib/omnihub/tests/suites/<name>.lua, each returning
-- a function(runner) that registers its tests.
OmniHubTestRegistry.pure = {
    "config_spec",
    "events_spec",
    "goodstable_spec",
    "log_spec",
    "modconfig_spec",
    "moduledefs_spec",
    "moduleitem_spec",
    "maxlimit_spec",
    "offlinesim_spec",
    "production_spec",
    "rates_spec",
    "stats_spec",
    "storage_spec",
    "supplier_spec",
    "tradingdecision_spec",
    "trading_spec",
    "wave_spec",
}

OmniHubTestRegistry.integration = {
    "autotrade_spec",
    "integration_spec",
}

-- Returns the list of suite names for a category: "pure", "integration", or "all".
function OmniHubTestRegistry.names(category)
    if category == "pure" then
        return OmniHubTestRegistry.pure
    elseif category == "integration" then
        return OmniHubTestRegistry.integration
    end
    -- "all" (or anything else): pure first, then integration
    local all = {}
    for _, n in ipairs(OmniHubTestRegistry.pure) do all[#all + 1] = n end
    for _, n in ipairs(OmniHubTestRegistry.integration) do all[#all + 1] = n end
    return all
end

-- Includes each suite for the category and returns an array of register functions.
function OmniHubTestRegistry.load(category)
    local suites = {}
    for _, name in ipairs(OmniHubTestRegistry.names(category)) do
        suites[#suites + 1] = include("lib/omnihub/tests/suites/" .. name)
    end
    return suites
end

-- Convenience: load the category, run every suite against a fresh runner, return it.
function OmniHubTestRegistry.run(category)
    local OmniHubTest = include("lib/omnihub/tests/framework")
    local runner = OmniHubTest.newRunner()
    for _, register in ipairs(OmniHubTestRegistry.load(category)) do
        register(runner)
    end
    return runner
end

return OmniHubTestRegistry
