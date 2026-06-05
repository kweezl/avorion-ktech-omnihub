package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest         = include("lib/omnihub/tests/framework")
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
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
end
