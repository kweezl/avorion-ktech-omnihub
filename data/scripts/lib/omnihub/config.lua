package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubConfig
-- Single source of truth for the mod's configuration. OmniHubConfig.schema below is BOTH the MCM
-- option schema (modconfig.lua returns it verbatim) AND the source of the built-in defaults used
-- when MCM is absent — so every default/range/label is declared in exactly one place.
-- Percent options (modulePriceFactor, dropChance) are declared in MCM UI units (integer percents);
-- get() and the derived `defaults` table convert them to the fractions callers expect.
OmniHubConfig = {}

-- Unit conversion for foundingCostMillions: the schema declares the option in millions of
-- credits (a 15,000,000 text box is unusable); callers that need credits multiply by this.
OmniHubConfig.CREDITS_PER_MILLION = 1000000

-- Keys MCM stores as integer percents; converted to fractions on read.
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- THE schema. The only place options/defaults/ranges/labels are declared. modconfig.lua returns
-- this verbatim for MCM; the runtime defaults below are derived from it.
OmniHubConfig.schema = {
    {
        key         = "foundingCostMillions",
        type        = "number",
        title       = "Founding cost",
        description = "OmniHub founding price, in millions of credits. 0 = free (creative servers).",
        default     = 15,
        min         = 0,
        max         = 500,
    },
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

-- Resolve + bind MCM ONCE at load. MCM is an OPTIONAL dependency, so every step is guarded:
--
--   1) Gate the include on MCM actually being enabled. include() on an ABSENT module throws, and the
--      engine writes that failure to the log BEFORE Lua's pcall can swallow it — so a guarded include
--      still spams the log on every machine without MCM. We avoid that entirely by first checking the
--      active-mod list (Mods(), the same pattern vanilla factionpacks.lua / MCM's modconfigloader use)
--      and only include() when MCM is present. When it's absent we print our own one-line notice.
--
--   2) Still wrap include()+bind() in pcall. Even with MCM enabled, bind() can throw (e.g. MCM
--      resolved mid-load in a shared multi-script entity VM, where bind isn't defined yet). An
--      unguarded throw here would abort this chunk after `defaults` but BEFORE get() is defined, and
--      the engine would hand include("config") the partial namespace table — a config with no .get,
--      surfacing as "attempt to call field 'get' (a nil value)" at the first caller.
--
-- Any failure -> config nil -> built-in defaults. "ktech-omnihub" must match the `name` in
-- modinfo.lua; "3674093144" is MCM's Workshop id (its modinfo `id`).
local LOG_PREFIX      = "[OmniHub]"
local MCM_WORKSHOP_ID = "3674093144"

-- Is MCM active? "enabled" / "disabled" / "unknown" (Mods() unavailable in this context — e.g.
-- off-engine, where the global is absent). Detection-only: it never include()s "mcm", so callers can
-- decide whether to attempt the include WITHOUT tripping the engine's failed-include log on machines
-- that don't have MCM. On "unknown" the loader below still attempts the include so MCM users are
-- never silently dropped (cost: one engine log line). Exposed so the test suites share one detector.
function OmniHubConfig.mcmState()
    if Mods == nil then return "unknown" end
    local ok, found = pcall(function()
        for _, mod in pairs(Mods()) do
            if mod.id == MCM_WORKSHOP_ID then return true end
        end
        return false
    end)
    if not ok then return "unknown" end
    return found and "enabled" or "disabled"
end

-- Resolve the bound MCM instance ({ get = fn, ... }) once at load, or nil to fall back to built-in
-- defaults. Indirect pcall(include, ...) guards a missing/throwing include; a second pcall guards
-- bind() (which can throw even when MCM is present). Returning the value — rather than mutating an
-- upvalue inside a closure — means a binding failure can never leave config.lua half-loaded.
local function resolveMcmConfig()
    if OmniHubConfig.mcmState() == "disabled" then
        print(LOG_PREFIX .. " MCM (Mod Configuration Menu) is disabled — using built-in config defaults.")
        return nil
    end
    local incOk, mcm = pcall(include, "mcm")
    if not incOk or not mcm then return nil end
    ---@cast mcm table
    local bindOk, bound = pcall(mcm.bind, "ktech-omnihub")
    if not bindOk then
        print(LOG_PREFIX .. " MCM detected but could not be loaded — using built-in config defaults.")
        return nil
    end
    return bound
end

local config = resolveMcmConfig()

-- Returns the config value for key. Reads from MCM on-demand when present (so admin changes take
-- effect immediately), else from the built-in defaults.
function OmniHubConfig.get(key)
    if config then
        local raw = config.get(key)  -- MCM returns the schema default when unset, nil if unknown
        if raw == nil then
            -- A stale MCM registration (e.g. schema cached from an older mod version) doesn't
            -- know the key. Callers do arithmetic/comparisons on the result, so nil must never
            -- escape — fall back to the built-in default.
            return OmniHubConfig.defaults[key]
        end
        if PERCENT_KEYS[key] and type(raw) == "number" then
            raw = raw / 100
        end
        return raw
    end
    return OmniHubConfig.defaults[key]  -- already fractional; do NOT divide again
end

return OmniHubConfig
