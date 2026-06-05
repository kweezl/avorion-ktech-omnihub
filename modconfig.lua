-- MCM (Mod Configuration Menu) schema for KTech OmniHub.
-- Auto-discovered by MCM (workshop id 3674093144) at startup; returns a pages/options table.
-- DEFAULTS LIVE HERE. data/scripts/lib/omnihub/config.lua mirrors them as a fallback for when
-- MCM is not installed; the modconfig_spec test asserts the two stay in sync.
-- Percent options (modulePriceFactor, dropChance) are stored as INTEGER percents here (100, 50);
-- OmniHubConfig.get divides them by 100 so callers receive fractions (1.0, 0.5).
return {
    pages = {
        {
            title = "OmniHub",
            options = {
                {
                    key         = "sellingModuleCount",
                    type        = "number",
                    title       = "Modules for sale",
                    description = "How many factory modules the OmniHub Supplier stocks at once.",
                    default     = 10,
                    min         = 1,
                    max         = 50,
                },
                {
                    key         = "modulePriceFactor",
                    type        = "slider",
                    title       = "Module price",
                    description = "Multiplier on module shop price. 100% = vanilla factory cost.",
                    default     = 100,
                    min         = 10,
                    max         = 500,
                    step        = 10,
                    unit        = "%",
                },
                {
                    key         = "moduleCap",
                    type        = "number",
                    title       = "Installed module cap",
                    description = "Maximum installed module units per hub. -1 = unlimited.",
                    default     = -1,
                    min         = -1,
                    max         = 999,
                },
                {
                    key         = "dropChance",
                    type        = "slider",
                    title       = "Module drop chance",
                    description = "Chance each installed unit drops as loot when the hub is destroyed.",
                    default     = 50,
                    min         = 0,
                    max         = 100,
                    step        = 5,
                    unit        = "%",
                },
                {
                    key         = "traderRequestCooldown",
                    type        = "number",
                    title       = "Trader request cooldown",
                    description = "Seconds between auto-sell trader spawn attempts.",
                    default     = 90,
                    min         = 10,
                    max         = 600,
                },
            },
        },
    },
}
