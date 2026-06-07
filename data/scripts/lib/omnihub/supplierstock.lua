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

-- Returns a random integer stock count in [min, max] (inclusive). Swaps the bounds if min > max so
-- the caller never has to pre-validate, and floors min at 0. rng(hi) returns an integer in [1, hi].
function OmniHubSupplierStock.rollStock(minStock, maxStock, rng)
    local lo, hi = minStock, maxStock
    if lo > hi then lo, hi = hi, lo end
    if lo < 0 then lo = 0 end
    return lo - 1 + rng(hi - lo + 1)
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

-- Maps a clicked Buy-tab LINE (1-based, within the current page) to its index in the FULL soldItems
-- list, or nil if it lands outside the stock. The vanilla Buy button only knows the line it sits on;
-- with pagination the real item is soldItems[page*perPage + line - 1]. Shares pageSlice's clamping so
-- it always agrees with what updateSellGui rendered. nil = empty/out-of-range line (buy nothing).
function OmniHubSupplierStock.lineToItemIndex(total, perPage, page, lineIndex)
    if not lineIndex or lineIndex < 1 or total <= 0 then return nil end
    local itemStart = OmniHubSupplierStock.pageSlice(total, perPage, page)
    local idx = itemStart + lineIndex - 1
    if idx < 1 or idx > total then return nil end
    return idx
end

return OmniHubSupplierStock
