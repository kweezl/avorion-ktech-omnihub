package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubConfig
-- Single source of truth for the mod's configuration. OmniHubConfig.schema below is BOTH the MCM
-- option schema (modconfig.lua returns it verbatim) AND the source of the built-in defaults used
-- when MCM is absent — so every default/range/label is declared in exactly one place.
-- Percent options (modulePriceFactor, dropChance) are declared in MCM UI units (integer percents);
-- get() and the derived `defaults` table convert them to the fractions callers expect.
OmniHubConfig = {}

-- Keys MCM stores as integer percents; converted to fractions on read.
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- THE schema. The only place options/defaults/ranges/labels are declared. modconfig.lua returns
-- this verbatim for MCM; the runtime defaults below are derived from it.
OmniHubConfig.schema = {
    {
        key         = "sellingModuleCount",
        type        = "number",
        title       = "Modules for sale",
        description = "How many factory modules the OmniHub Supplier stocks at once (clamped at runtime to the number of available factory recipes).",
        default     = 10,
        min         = 1,
        max         = 200,
    },
    {
        key         = "stockMin",
        type        = "number",
        title       = "Stock per module (min)",
        description = "Minimum units stocked per module. Each module rolls a random stock between min and max (swapped if min > max).",
        default     = 5,
        min         = 1,
        max         = 9999,
    },
    {
        key         = "stockMax",
        type        = "number",
        title       = "Stock per module (max)",
        description = "Maximum units stocked per module.",
        default     = 20,
        min         = 1,
        max         = 9999,
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
    {
        key         = "maxTradersPerWave",
        type        = "number",
        title       = "Max traders per wave",
        description = "Upper limit of NPC traders spawned per trade wave; additionally capped by the hub's free docking positions.",
        default     = 3,
        min         = 1,
        max         = 6,
    },
    {
        key         = "offlineWaveDelayMultiplier",
        type        = "number",
        title       = "Offline wave delay multiplier",
        description = "Offline trade waves run every (trader request cooldown x this) seconds, modelling the docking latency online traders pay. Higher = slower offline trading.",
        default     = 3,
        min         = 1,
        max         = 10,
    },
}

-- Append the allowed range + default to each option's description, so the MCM input fields make the
-- valid values obvious (a bare integer box doesn't communicate min/max). Derived from the schema so
-- the printed range can never disagree with the enforced one.
for _, opt in ipairs(OmniHubConfig.schema) do
    local unit = opt.unit or ""
    opt.description = string.format("%s  [range %s%s to %s%s, default %s%s]",
        opt.description, opt.min, unit, opt.max, unit, opt.default, unit)
end

-- Built-in defaults, DERIVED from the schema in the FRACTIONAL forms callers expect (percent options
-- divided by 100, e.g. dropChance 50 -> 0.5). Used as the fallback when MCM is not installed.
OmniHubConfig.defaults = {}
for _, opt in ipairs(OmniHubConfig.schema) do
    local v = opt.default
    if PERCENT_KEYS[opt.key] and type(v) == "number" then v = v / 100 end
    OmniHubConfig.defaults[opt.key] = v
end

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
