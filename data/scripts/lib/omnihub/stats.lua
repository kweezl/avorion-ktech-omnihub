package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubStats
-- Pure, engine-independent trade statistics: lifetime profit, a rolling 60-minute profit ring for
-- "last hour", and a capped log of the most recent transactions with traders. No engine access — the
-- controller feeds it transaction records and advances the ring with elapsed time. Using a minute
-- ring instead of wall-clock timestamps keeps "last hour" correct across save/load and game restarts
-- (engine Lua has no usable Date.now anyway) and keeps the whole module unit-testable off-engine.
OmniHubStats = {}

local BUCKETS  = 60   -- one bucket per minute -> last hour
local MAX_TXNS = 10   -- recent-transaction log size

-- Fresh stats state. `buckets` is a fixed-size ring; `cursor` indexes the current (most recent)
-- minute bucket. Profit convention: selling products earns (+price), buying resources costs (-price).
function OmniHubStats.new()
    local buckets = {}
    for i = 1, BUCKETS do buckets[i] = 0 end
    return {
        lifetimeProfit = 0,
        buckets        = buckets,
        cursor         = 1,
        transactions   = {},
    }
end

local function profitDelta(txn)
    local p = txn.price or 0
    if txn.kind == "sell" then return p end
    if txn.kind == "buy"  then return -p end
    return 0
end

-- Records one transaction: updates lifetime profit, the current minute bucket, and the capped log
-- (oldest dropped past MAX_TXNS). `txn` = {kind="buy"|"sell", good, amount, price, partner}.
function OmniHubStats.record(stats, txn)
    local delta = profitDelta(txn)
    stats.lifetimeProfit = stats.lifetimeProfit + delta
    stats.buckets[stats.cursor] = stats.buckets[stats.cursor] + delta

    stats.transactions[#stats.transactions + 1] = {
        kind = txn.kind, good = txn.good, amount = txn.amount,
        price = txn.price, partner = txn.partner,
    }
    while #stats.transactions > MAX_TXNS do
        table.remove(stats.transactions, 1)
    end
end

-- Rolls the ring forward by `steps` whole minutes, zeroing each new current bucket so it only holds
-- that minute's profit. Clamped to BUCKETS (rolling a full hour clears the whole window).
function OmniHubStats.advance(stats, steps)
    if not steps or steps <= 0 then return end
    steps = math.min(math.floor(steps), BUCKETS)
    for _ = 1, steps do
        stats.cursor = (stats.cursor % BUCKETS) + 1
        stats.buckets[stats.cursor] = 0
    end
end

function OmniHubStats.lifetimeProfit(stats)
    return stats.lifetimeProfit
end

function OmniHubStats.lastHourProfit(stats)
    local sum = 0
    for i = 1, BUCKETS do sum = sum + stats.buckets[i] end
    return sum
end

-- Returns up to n recent transactions, newest first.
function OmniHubStats.recent(stats, n)
    n = n or MAX_TXNS
    local out  = {}
    local txns = stats.transactions
    for i = #txns, math.max(1, #txns - n + 1), -1 do
        out[#out + 1] = txns[i]
    end
    return out
end

return OmniHubStats
