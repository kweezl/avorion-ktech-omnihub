package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest = include("lib/omnihub/tests/framework")

-- Regression for: omnihubsupplier.lua:74 "attempt to call field 'get' (a nil value)".
--
-- MCM is an OPTIONAL dependency. config.lua pcall-guards include("mcm"), but the *use* of the
-- result — mcm.bind(...) — must be guarded too. If bind throws (e.g. MCM resolved mid-load in a
-- shared multi-script entity VM, where bind isn't defined yet), an unguarded call aborts config.lua's
-- chunk AFTER building `defaults` but BEFORE defining get(). In-game, include() then hands callers
-- the partially-built namespace table — a config with no .get — which is exactly the supplier crash.
--
-- This loads config.lua's chunk fresh with the optional dependency poisoned (MCM present, bind
-- raises) and asserts the module still loads and exposes a working get() that falls back to defaults.

return function(runner)
    runner:suite("config_mcm")

    runner:test("get() survives a throwing mcm.bind (optional dep fully guarded)", function()
        local repoRoot = (_G.OMNIHUB_MODCONFIG_PATH or ""):gsub("[/\\]modconfig%.lua$", "")
        local path = repoRoot .. "/data/scripts/lib/omnihub/config.lua"
        local chunk, err = loadfile(path)
        OmniHubTest.assertNotNil(chunk, "loadfile config.lua: " .. tostring(err))

        -- Poison the optional dependency: MCM detected as ENABLED, present via include(), but bind()
        -- raises (mimics MCM resolved mid-load in a shared multi-script VM, where bind isn't ready).
        local savedInclude = include
        local savedGlobal  = OmniHubConfig
        local savedMods    = Mods
        Mods = function()
            return { { id = "3674093144" } }   -- MCM's Workshop id -> mcmState() == "enabled"
        end
        include = function(name)
            if name == "mcm" then
                return { bind = function() error("mcm not ready") end }
            end
            return savedInclude(name)
        end

        local ok, result = pcall(chunk)

        -- Restore globals before asserting, so a failure can't leave the harness poisoned.
        include       = savedInclude
        OmniHubConfig = savedGlobal
        Mods          = savedMods

        OmniHubTest.assertEqual(ok, true,
            "config.lua must load without error when the optional mcm.bind throws")
        OmniHubTest.assertEqual(type(result), "table", "config.lua returns its module table")
        OmniHubTest.assertEqual(type(result.get), "function",
            "get() is defined even though mcm.bind threw")
        -- The binding failed, so config behaves as if MCM were absent: built-in defaults.
        OmniHubTest.assertEqual(result.get("stockMin"), 5, "get() returns the built-in default")
    end)
end