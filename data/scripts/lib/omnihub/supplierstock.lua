package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubSupplierStock
-- Pure, engine-independent helpers for the OmniHub Supplier shop: choosing which modules to stock,
-- which one is the special offer, and how to slice a list into Buy-tab pages. No Entity()/random()
-- access here — randomness is injected as rng(hi) -> integer in [1, hi].
OmniHubSupplierStock = {}

-- Partial Fisher-Yates: returns up to n DISTINCT entries from `keys` (order randomized).
-- rng(hi) must return an integer in [1, hi]. n is clamped to #keys; n<=0 or empty pool -> {}.
function OmniHubSupplierStock.pickRandomSubset(keys, n, rng)
    local pool = {}
    for i = 1, #keys do pool[i] = keys[i] end

    local count = #pool
    if n > count then n = count end
    if n < 0 then n = 0 end

    local result = {}
    for i = 1, n do
        local pick = rng(count - i + 1)        -- 1 .. (count - i + 1)
        local idx  = i - 1 + pick              -- maps into the unpicked tail [i .. count]
        pool[i], pool[idx] = pool[idx], pool[i]
        result[i] = pool[i]
    end
    return result
end

-- Returns one key from `subset` (the special offer), or nil if the subset is empty.
function OmniHubSupplierStock.pickSpecialOffer(subset, rng)
    local count = #subset
    if count == 0 then return nil end
    return subset[rng(count)]
end

-- Computes the 1-based inclusive item bounds for a 0-based page over `total` items at `perPage`
-- per page. Returns itemStart, itemEnd, clampedPage. total==0 returns 0, 0, 0.
function OmniHubSupplierStock.pageSlice(total, perPage, page)
    if total <= 0 then return 0, 0, 0 end
    if page < 0 then page = 0 end
    local maxPage = math.max(0, math.ceil(total / perPage) - 1)
    if page > maxPage then page = maxPage end
    local itemStart = page * perPage + 1
    local itemEnd   = math.min(total, itemStart + perPage - 1)
    return itemStart, itemEnd, page
end

return OmniHubSupplierStock
