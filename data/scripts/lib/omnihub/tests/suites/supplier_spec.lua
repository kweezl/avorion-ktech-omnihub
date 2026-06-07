package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest         = include("lib/omnihub/tests/framework")
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local niln = OmniHubTest.assertNil
local notn = OmniHubTest.assertNotNil

-- A deterministic rng(hi) that walks a fixed sequence (values clamped into [1, hi]).
local function seqRng(seq)
    local i = 0
    return function(hi)
        i = i + 1
        local v = seq[((i - 1) % #seq) + 1]
        if v > hi then v = ((v - 1) % hi) + 1 end
        if v < 1 then v = 1 end
        return v
    end
end

local KEYS = {"a", "b", "c", "d", "e"}

return function(runner)
    runner:suite("supplier")

    runner:test("module contract: helpers exist and are functions", function()
        eq(type(OmniHubSupplierStock.pickRandomSubset), "function", "pickRandomSubset exists")
        eq(type(OmniHubSupplierStock.pickSpecialOffer), "function", "pickSpecialOffer exists")
        eq(type(OmniHubSupplierStock.pageSlice),        "function", "pageSlice exists")
        eq(type(OmniHubSupplierStock.rollStock),        "function", "rollStock exists")
    end)

    runner:test("pickRandomSubset returns n distinct keys", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 3, seqRng({1, 1, 1}))
        eq(#sub, 3, "subset size is n")
        local seen = {}
        for _, k in ipairs(sub) do
            tru(not seen[k], "no duplicate key: " .. tostring(k))
            seen[k] = true
        end
    end)

    runner:test("pickRandomSubset clamps n to pool size", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 99, seqRng({1}))
        eq(#sub, #KEYS, "clamped to pool size")
    end)

    runner:test("pickRandomSubset handles n=0 and empty pool", function()
        eq(#OmniHubSupplierStock.pickRandomSubset(KEYS, 0, seqRng({1})), 0, "n=0 -> empty")
        eq(#OmniHubSupplierStock.pickRandomSubset({}, 3, seqRng({1})), 0, "empty pool -> empty")
    end)

    runner:test("pickRandomSubset only returns keys from the pool", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 4, seqRng({2, 1, 3, 1}))
        local pool = {}
        for _, k in ipairs(KEYS) do pool[k] = true end
        for _, k in ipairs(sub) do tru(pool[k], "key came from pool: " .. tostring(k)) end
    end)

    runner:test("pickSpecialOffer returns a member of the subset", function()
        local sub = {"x", "y", "z"}
        local pick = OmniHubSupplierStock.pickSpecialOffer(sub, seqRng({2}))
        notn(pick, "special offer chosen")
        local inSub = false
        for _, k in ipairs(sub) do if k == pick then inSub = true end end
        tru(inSub, "special offer is in the subset")
    end)

    runner:test("pickSpecialOffer returns nil for empty subset", function()
        eq(OmniHubSupplierStock.pickSpecialOffer({}, seqRng({1})), nil, "empty -> nil")
    end)

    runner:test("pageSlice computes 1-based inclusive bounds", function()
        local s, e = OmniHubSupplierStock.pageSlice(23, 15, 0)
        eq(s, 1, "page 0 start"); eq(e, 15, "page 0 end")
        s, e = OmniHubSupplierStock.pageSlice(23, 15, 1)
        eq(s, 16, "page 1 start"); eq(e, 23, "page 1 end (clamped to total)")
    end)

    runner:test("pageSlice clamps out-of-range pages and handles empty", function()
        local s, e, page = OmniHubSupplierStock.pageSlice(23, 15, 99)
        eq(page, 1, "clamped to last page"); eq(s, 16, "last-page start"); eq(e, 23, "last-page end")
        s, e = OmniHubSupplierStock.pageSlice(0, 15, 0)
        eq(s, 0, "empty start"); eq(e, 0, "empty end")
    end)

    runner:test("lineToItemIndex maps a Buy-tab line to the paged soldItems index", function()
        -- 23 items, 12/page. Page 0 line 1 -> item 1; page 1 line 1 -> item 13 (the real bug: the
        -- vanilla handler would have bought item 1 here).
        eq(OmniHubSupplierStock.lineToItemIndex(23, 12, 0, 1), 1,  "page 0, line 1 -> item 1")
        eq(OmniHubSupplierStock.lineToItemIndex(23, 12, 0, 12), 12, "page 0, line 12 -> item 12")
        eq(OmniHubSupplierStock.lineToItemIndex(23, 12, 1, 1), 13, "page 1, line 1 -> item 13")
        eq(OmniHubSupplierStock.lineToItemIndex(23, 12, 1, 11), 23, "page 1, line 11 -> item 23 (last)")
    end)

    runner:test("lineToItemIndex returns nil for lines past the stock or invalid input", function()
        niln(OmniHubSupplierStock.lineToItemIndex(23, 12, 1, 12), "page 1 line 12 -> item 24 > 23")
        niln(OmniHubSupplierStock.lineToItemIndex(0, 12, 0, 1),  "no stock -> nil")
        niln(OmniHubSupplierStock.lineToItemIndex(23, 12, 0, 0),  "line 0 invalid")
        niln(OmniHubSupplierStock.lineToItemIndex(23, 12, 0, nil), "nil line")
        -- out-of-range page is clamped (mirrors pageSlice), so a valid line still resolves.
        eq(OmniHubSupplierStock.lineToItemIndex(23, 12, 99, 1), 13, "page clamped to last -> item 13")
    end)

    runner:test("rollStock returns a value within [min, max]", function()
        -- rng returns 1 -> lo; sequence covers the range endpoints.
        eq(OmniHubSupplierStock.rollStock(5, 20, seqRng({1})), 5,  "rng=1 -> min")
        -- rng returns hi (=max-min+1=16) -> max.
        eq(OmniHubSupplierStock.rollStock(5, 20, function() return 16 end), 20, "rng=range -> max")
        for v = 1, 16 do
            local s = OmniHubSupplierStock.rollStock(5, 20, function() return v end)
            tru(s >= 5 and s <= 20, "in range for rng=" .. v .. " (got " .. s .. ")")
        end
    end)

    runner:test("rollStock handles min==max and swaps min>max", function()
        eq(OmniHubSupplierStock.rollStock(7, 7, function() return 1 end), 7, "min==max -> that value")
        -- min > max is swapped, so range is [3,9]; rng=1 -> 3.
        eq(OmniHubSupplierStock.rollStock(9, 3, function() return 1 end), 3, "swapped min/max -> low end")
        eq(OmniHubSupplierStock.rollStock(9, 3, function() return 7 end), 9, "swapped min/max -> high end")
    end)
end
