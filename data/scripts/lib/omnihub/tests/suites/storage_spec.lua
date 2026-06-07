package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest    = include("lib/omnihub/tests/framework")
local OmniHubStorage = include("lib/omnihub/storage")

local eq  = OmniHubTest.assertEqual
local tru = OmniHubTest.assertTrue
local fls = OmniHubTest.assertFalse

return function(runner)
    runner:suite("storage")

    runner:test("summarize computes per-good and total volumes", function()
        local s = OmniHubStorage.summarize({
            { name = "Cattle", current = 100, size = 2, limit = 400 },
            { name = "Wheat",  current = 50,  size = 1, limit = 300 },
        }, 100000)
        eq(#s.goods, 2)
        eq(s.goods[1].name, "Cattle", "sorted by name")
        eq(s.goods[1].currentVol, 200,  "Cattle 100u x size 2")
        eq(s.goods[1].limitVol, 800, "Cattle 400u x size 2")
        eq(s.goods[2].currentVol, 50,   "Wheat 50u x size 1")
        eq(s.totalCurrentVol, 250,  "200 + 50")
        eq(s.totalLimitVol, 1100, "800 + 300")
        eq(s.capacity, 100000)
        fls(s.over, "capacity comfortably covers reservations")
    end)

    runner:test("summarize flags over-capacity when reservations exceed the hold", function()
        local s = OmniHubStorage.summarize({
            { name = "Cattle", current = 0, size = 10, limit = 1000 },  -- 10000 vol
        }, 5000)
        tru(s.over, "10000 limit volume > 5000 capacity")
    end)

    runner:test("summarize defaults missing size to 1 and handles empty", function()
        local s = OmniHubStorage.summarize({ { name = "X", current = 3, limit = 7 } }, 0)
        eq(s.goods[1].currentVol, 3,  "size defaults to 1")
        eq(s.goods[1].limitVol, 7)
        tru(s.over, "any reservation over a 0 capacity is over")

        local e = OmniHubStorage.summarize({}, 1000)
        eq(#e.goods, 0)
        eq(e.totalLimitVol, 0)
        fls(e.over, "nothing limit -> not over")
    end)
end
