package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest       = include("lib/omnihub/tests/framework")
local OmniHubGoodsTable = include("lib/omnihub/ui/goodstable")

local eq = OmniHubTest.assertEqual

-- Pure-ish suite for OmniHubGoodsTable's data-cache methods (setEnabled, patchLive). Both only
-- touch the data array, so they run off-engine without widgets (bare instance + metatable, no .new);
-- patchLive's trailing render() is stubbed out per instance.
return function(runner)
    runner:suite("goodstable")

    -- Mirror setData: a real instance carries a name index used by setEnabled/patchLive.
    local function newTable(data)
        local t = setmetatable({ data = data, byName = {} }, OmniHubGoodsTable)
        for _, d in ipairs(data) do t.byName[d.name] = d end
        t.render = function() end   -- widget repaint; engine-only
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

    runner:test("patchLive applies sent rows and zeroes omitted goods' live values", function()
        local t = newTable({
            { name = "Steel", stock = 50, prateActual = 5, prateMax = 10, crateActual = 0, crateMax = 0 },
            { name = "Ore",   stock = 99, prateActual = 0, prateMax = 0,  crateActual = 7, crateMax = 9 },
        })
        t:patchLive({ { name = "Steel", stock = 80, prate = 6, crate = 1 } })
        eq(t.data[1].stock, 80,      "Steel stock patched")
        eq(t.data[1].prateActual, 6, "Steel prate patched")
        eq(t.data[1].crateActual, 1, "Steel crate patched")
        eq(t.data[2].stock, 0,       "omitted Ore stock zeroed")
        eq(t.data[2].crateActual, 0, "omitted Ore crate zeroed")
    end)

    runner:test("patchLive never touches max rates", function()
        local t = newTable({
            { name = "Steel", stock = 1, prateActual = 5, prateMax = 10, crateActual = 2, crateMax = 4 },
        })
        t:patchLive({})
        eq(t.data[1].prateMax, 10, "prateMax kept")
        eq(t.data[1].crateMax, 4,  "crateMax kept")
        eq(t.data[1].prateActual, 0, "actual zeroed")
    end)

    runner:test("patchLive ignores unknown goods and a nil payload", function()
        local t = newTable({ { name = "Steel", stock = 3, prateActual = 1, crateActual = 1 } })
        t:patchLive({ { name = "Nonexistent", stock = 9, prate = 9, crate = 9 } })
        eq(t.data[1].stock, 0, "known good zeroed, unknown ignored")
        t:patchLive(nil)
        eq(t.data[1].stock, 0, "nil payload is a plain zeroing pass")
    end)
end
