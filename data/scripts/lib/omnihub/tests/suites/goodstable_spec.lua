package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubGoodsTable = include("lib/omnihub/ui/goodstable")

local eq = OmniHubTest.assertEqual

-- Pure-ish suite for OmniHubGoodsTable.setEnabled. The cached buy/sell flags must follow checkbox
-- toggles so paging (which rebuilds rows from the cache) doesn't snap them back. setEnabled only
-- touches the data array, so it runs off-engine without widgets (bare instance + metatable, no .new).
return function(runner)
    runner:suite("goodstable")

    -- Mirror setData: a real instance carries a name index used by setEnabled.
    local function newTable(data)
        local t = setmetatable({ data = data, byName = {} }, OmniHubGoodsTable)
        for _, d in ipairs(data) do t.byName[d.name] = d end
        return t
    end

    runner:test("setEnabled updates the correct side for the matching good", function()
        local t = newTable({ { name = "Steel", sellEnabled = true, buyEnabled = true } })
        t:setEnabled("Steel", "sell", false)
        eq(t.data[1].sellEnabled, false, "sell disabled")
        eq(t.data[1].buyEnabled,  true,  "buy untouched")
        t:setEnabled("Steel", "buy", false)
        eq(t.data[1].buyEnabled, false, "buy disabled")
        t:setEnabled("Steel", "sell", true)
        eq(t.data[1].sellEnabled, true, "sell re-enabled")
    end)

    runner:test("setEnabled only touches the matching good", function()
        local t = newTable({
            { name = "Steel", sellEnabled = true, buyEnabled = true },
            { name = "Ore",   sellEnabled = true, buyEnabled = true },
        })
        t:setEnabled("Ore", "buy", false)
        eq(t.data[1].buyEnabled, true,  "Steel untouched")
        eq(t.data[2].buyEnabled, false, "Ore updated")
    end)

    runner:test("setEnabled is a no-op for an unknown good (no error)", function()
        local t = newTable({ { name = "Steel", sellEnabled = true, buyEnabled = true } })
        t:setEnabled("Nonexistent", "sell", false)
        eq(t.data[1].sellEnabled, true, "existing good untouched")
    end)
end
