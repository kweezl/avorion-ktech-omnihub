package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq  = OmniHubTest.assertEqual
local tru = OmniHubTest.assertTrue

-- Keys the MCM schema stores as integer percents (mirror of config.lua's PERCENT_KEYS).
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- Loads the mod-root modconfig.lua and returns { [key] = default } from its first page.
local function loadSchemaDefaults(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local schema = chunk()
    local defaults = {}
    for _, page in ipairs(schema.pages) do
        for _, opt in ipairs(page.options) do
            defaults[opt.key] = opt.default
        end
    end
    return defaults
end

-- Pure suite: every modconfig.lua option default, after percent->fraction conversion, must equal
-- OmniHubConfig.defaults[key]. Runs only where the mod-root file is reachable (off-engine; the
-- harness sets OMNIHUB_MODCONFIG_PATH). In-game it self-skips, since the mod root isn't on the
-- script path.
return function(runner)
    runner:suite("modconfig")

    local path = _G.OMNIHUB_MODCONFIG_PATH
    local schemaDefaults = path and loadSchemaDefaults(path) or nil

    if not schemaDefaults then
        runner:test("schema/defaults consistency (off-engine only)", function()
            tru(true, "skipped: modconfig.lua not reachable in this environment")
        end)
        return
    end

    runner:test("every code default has a schema option", function()
        for key in pairs(OmniHubConfig.defaults) do
            tru(schemaDefaults[key] ~= nil, "schema is missing option: " .. key)
        end
    end)

    runner:test("every schema default matches the code default", function()
        for key, schemaDefault in pairs(schemaDefaults) do
            local expected = OmniHubConfig.defaults[key]
            tru(expected ~= nil, "code defaults missing key: " .. key)
            if PERCENT_KEYS[key] then
                eq(schemaDefault / 100, expected, "percent default mismatch for " .. key)
            else
                eq(schemaDefault, expected, "default mismatch for " .. key)
            end
        end
    end)
end
