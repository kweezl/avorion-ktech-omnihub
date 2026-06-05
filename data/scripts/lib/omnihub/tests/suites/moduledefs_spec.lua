package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")

local assertTrue    = OmniHubTest.assertTrue
local assertNotNil  = OmniHubTest.assertNotNil
local assertNil     = OmniHubTest.assertNil
local assertEqual   = OmniHubTest.assertEqual

-- Pure suite: exercises OmniHubModuleDefs through its public API. Assertions are written to hold
-- for both the off-engine mock catalog and the real in-game productionsByGood data.
return function(runner)
    runner:suite("moduledefs")

    runner:test("catalog is non-empty", function()
        local cat = OmniHubModuleDefs.getCatalog()
        assertNotNil(cat, "catalog should not be nil")
        local n = 0
        for _ in pairs(cat) do n = n + 1 end
        assertTrue(n > 0, "catalog should have at least one entry")
    end)

    runner:test("keys are stable 'good|idx' strings and self-consistent defs", function()
        for key, def in pairs(OmniHubModuleDefs.getCatalog()) do
            assertTrue(type(key) == "string" and key:match("^.+|%d+$") ~= nil,
                "key should look like 'good|idx': " .. tostring(key))
            assertEqual(def.key, key, "def.key matches table key")
            assertTrue(type(def.name) == "string", "def.name is a string for " .. key)
            assertTrue(type(def.price) == "number", "def.price is a number for " .. key)
        end
    end)

    runner:test("resolveRecipe returns the recipe and excludes mines", function()
        for key, def in pairs(OmniHubModuleDefs.getCatalog()) do
            local recipe = OmniHubModuleDefs.resolveRecipe(key)
            assertNotNil(recipe, "resolveRecipe non-nil for " .. key)
            assertEqual(recipe, def.production, "resolveRecipe matches def.production for " .. key)
            assertTrue(not recipe.mine, "mine recipes must be excluded: " .. key)
        end
    end)

    runner:test("catalog deduplicates by production identity", function()
        local seen = {}
        for key, def in pairs(OmniHubModuleDefs.getCatalog()) do
            assertNil(seen[def.production],
                "duplicate production table for keys " .. tostring(seen[def.production]) .. " and " .. key)
            seen[def.production] = key
        end
    end)

    runner:test("multi-good production keyed deterministically under its first good", function()
        -- The mock's gas production yields Helium + Neon. Its key MUST be under "Helium" (sorted
        -- first) in every VM, never "Neon" — otherwise the same production gets different keys in the
        -- entity/item/client VMs and resolution breaks. Guarded so it's a no-op in-game.
        local cat = OmniHubModuleDefs.getCatalog()
        if cat["Helium|1"] or cat["Neon|1"] then
            assertNotNil(cat["Helium|1"], "gas production keyed under Helium (alphabetically first)")
            assertNil(cat["Neon|1"], "gas production NOT also keyed under Neon (deduped to first good)")
        end
    end)

    runner:test("getSortedList is ordered by name", function()
        local list = OmniHubModuleDefs.getSortedList()
        for i = 2, #list do
            assertTrue(list[i - 1].name <= list[i].name,
                "list not sorted at index " .. i)
        end
    end)

    runner:test("get returns nil for an unknown key", function()
        assertNil(OmniHubModuleDefs.get("no_such_good|999"), "unknown key should be nil")
    end)
end
