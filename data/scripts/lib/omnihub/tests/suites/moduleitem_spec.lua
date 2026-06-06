package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubModuleItem = include("lib/omnihub/moduleitem")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")

local assertTrue   = OmniHubTest.assertTrue
local assertEqual  = OmniHubTest.assertEqual
local assertNil    = OmniHubTest.assertNil
local assertNotNil = OmniHubTest.assertNotNil

-- Returns the first line whose role matches and whose text contains `needle` (or any matching-role
-- line when needle is nil); nil if none.
local function findLine(lines, role, needle)
    for _, l in ipairs(lines) do
        if l.role == role and (needle == nil or (l.text and l.text:find(needle, 1, true))) then
            return l
        end
    end
    return nil
end

-- Picks an arbitrary real catalog key so the describe() assertions run against whatever
-- productionsByGood data is present (mock off-engine, real in-game).
local function anyKey()
    for key in pairs(OmniHubModuleDefs.getCatalog()) do return key end
    return nil
end

-- Pure suite: exercises the engine-independent OmniHubModuleItem.describe / tooltipLines.
-- The engine-coupled build() (VanillaInventoryItem, Tooltip) is verified in-game, not here.
return function(runner)
    runner:suite("moduleitem")

    runner:test("describe(known key) carries name/price/icon and the module values", function()
        local key = anyKey()
        assertNotNil(key, "catalog should have at least one key to test")
        local def  = OmniHubModuleDefs.get(key)
        local spec = OmniHubModuleItem.describe(key)

        assertTrue(spec.known, "known key should be known")
        assertEqual(spec.name,  def.name,  "spec name matches def")
        assertEqual(spec.price, def.price, "spec price matches def")
        assertEqual(spec.icon,  def.icon,  "spec icon matches def")
        assertEqual(spec.values.subtype,   "OmniHubModule", "subtype value")
        assertEqual(spec.values.moduleKey, key,             "moduleKey value")
        assertEqual(spec.values.category,  "factory",       "category value")
    end)

    runner:test("describe(known key) opens with a head line and a Produces section", function()
        local key  = anyKey()
        local def  = OmniHubModuleDefs.get(key)
        local spec = OmniHubModuleItem.describe(key)

        assertEqual(spec.lines[1].role, "head",   "first line is the head")
        assertEqual(spec.lines[1].text, def.name, "head text is the module name")
        assertNotNil(findLine(spec.lines, "section", "Produces"), "has a Produces section")

        -- Every result good should appear as an item line with its amount.
        for _, res in ipairs(def.production.results) do
            local line = findLine(spec.lines, "item", res.name)
            assertNotNil(line, "result line present for " .. res.name)
            assertTrue(line.text:find(tostring(res.amount), 1, true) ~= nil,
                "result line shows amount for " .. res.name)
        end
    end)

    runner:test("describe(unknown key) is a labelled fallback with no recipe lines", function()
        local spec = OmniHubModuleItem.describe("no_such_good|999")
        assertEqual(spec.known, false, "unknown key is not known")
        assertEqual(spec.name, "Unknown OmniHub Module", "fallback name")
        assertEqual(spec.values.subtype,   "OmniHubModule",     "subtype still set")
        assertEqual(spec.values.moduleKey, "no_such_good|999",  "moduleKey preserved")
        assertNil(spec.values.category, "no category on unknown")
        assertEqual(#spec.lines, 0, "no tooltip lines for unknown key")
    end)

    runner:test("describe(nil key) does not error and preserves an empty moduleKey", function()
        local spec = OmniHubModuleItem.describe(nil)
        assertEqual(spec.known, false, "nil key is not known")
        assertEqual(spec.values.moduleKey, "", "moduleKey defaults to empty string")
    end)

    runner:test("tooltipLines renders byproducts and optional ingredients", function()
        local def = { name = "Test Factory", production = {
            results     = { { name = "Widget", amount = 3 } },
            garbages    = { { name = "Slag",   amount = 1 } },
            ingredients = { { name = "Wire", amount = 2, optional = 1 },
                            { name = "Bolt", amount = 4, optional = 0 } },
        } }
        local lines = OmniHubModuleItem.tooltipLines(def)

        assertNotNil(findLine(lines, "section", "Produces"),  "Produces section")
        assertNotNil(findLine(lines, "section", "Requires"),  "Requires section")

        local byproduct = findLine(lines, "item", "Slag")
        assertNotNil(byproduct, "byproduct line present")
        assertTrue(byproduct.text:find("byproduct", 1, true) ~= nil, "byproduct is labelled")

        local optional = findLine(lines, "item", "Wire")
        assertNotNil(optional, "optional ingredient line present")
        assertTrue(optional.text:find("optional", 1, true) ~= nil, "optional is labelled")

        local required = findLine(lines, "item", "Bolt")
        assertNotNil(required, "required ingredient line present")
        assertTrue(required.text:find("optional", 1, true) == nil, "required is not labelled optional")
    end)

    runner:test("tooltipLines ends with the install hint", function()
        local def  = OmniHubModuleDefs.get(anyKey())
        local lines = OmniHubModuleItem.tooltipLines(def)
        local last  = lines[#lines]
        assertEqual(last.role, "item", "last line is an item line")
        assertTrue(last.text:find("Manage", 1, true) ~= nil, "last line is the Manage-tab hint")
    end)
end
