package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubConfig
OmniHubConfig = {}

OmniHubConfig.defaults = {
    moduleCap             = -1,   -- -1 = unlimited; >= 0 = hard cap on total installed module units
    dropChance            = 0.5,  -- probability each installed module unit drops on hub destruction
    modulePriceFactor     = 1.0,  -- multiplier applied to getFactoryCost() for module shop prices
    traderRequestCooldown = 90,   -- seconds between trader spawn attempts (matches vanilla factory.lua)
}

-- Returns the config value for key, checking for a server-set override first.
-- Server overrides live in a world-local config file (future M3 feature); for now just returns defaults.
function OmniHubConfig.get(key)
    return OmniHubConfig.defaults[key]
end

return OmniHubConfig
