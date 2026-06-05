package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubConfig
OmniHubConfig = {}

-- Built-in defaults, used when MCM is not installed. These are the FRACTIONAL forms callers expect
-- (dropChance/modulePriceFactor as 0.5/1.0). The MCM schema in modconfig.lua stores those two as
-- integer percents (50/100); get() divides the MCM-returned value by 100. modconfig_spec asserts
-- the two stay consistent.
OmniHubConfig.defaults = {
    moduleCap             = -1,   -- -1 = unlimited; >= 0 = hard cap on total installed module units
    dropChance            = 0.5,  -- probability each installed module unit drops on hub destruction
    modulePriceFactor     = 1.0,  -- multiplier applied to getFactoryCost() for module shop prices
    traderRequestCooldown = 90,   -- seconds between trader spawn attempts (matches vanilla factory.lua)
    sellingModuleCount    = 10,   -- how many modules the OmniHub Supplier stocks at once
}

-- Keys MCM stores as integer percents; converted to fractions on read.
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- Resolve + bind MCM ONCE at load. include() throws on a missing module and MCM is an OPTIONAL
-- dependency, so guard with pcall: absent MCM -> config nil -> built-in defaults are used.
-- "ktech-omnihub" must match the `name` field in modinfo.lua (MCM keys mods by that name).
local ok, mcm = pcall(include, "mcm")
local config  = (ok and mcm) and mcm.bind("ktech-omnihub") or nil

-- Returns the config value for key. Reads from MCM on-demand when present (so admin changes take
-- effect immediately), else from the built-in defaults.
function OmniHubConfig.get(key)
    if config then
        local raw = config.get(key)  -- MCM returns the schema default when unset, nil if unknown
        if PERCENT_KEYS[key] and type(raw) == "number" then
            raw = raw / 100
        end
        return raw
    end
    return OmniHubConfig.defaults[key]  -- already fractional; do NOT divide again
end

return OmniHubConfig
