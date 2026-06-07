package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubRates
-- Pure, engine-independent tracker for ACTUAL per-good production/consumption throughput over a
-- trailing ~60s window, so the Goods tab can show "actual/max" rates per minute. The controller feeds
-- it produced/consumed events from the production tick and advances it with elapsed time; reading the
-- window sum gives units-per-minute (the window IS ~60s).
--
-- OPTIMIZE LATER (see docs/performance-notes.md): this stores BUCKETS counters PER GOOD and zeroes the
-- rolling bucket for every tracked good on each bucket roll — O(goods) per roll. Fine for the dozens of
-- goods a production hub handles; revisit if "all goods" / trading-station mode tracks hundreds, e.g.
-- lazy per-good windows, decay/EMA, or pruning goods with no recent activity.
OmniHubRates = {}

local BUCKETS        = 6    -- 6 x 10s = ~60s trailing window
local BUCKET_SECONDS = 10

-- Fresh state. produced/consumed map good name -> array(BUCKETS) of unit counts; cursor is the current
-- bucket; accum carries sub-bucket elapsed time.
function OmniHubRates.new()
    return { produced = {}, consumed = {}, cursor = 1, accum = 0 }
end

local function bump(map, name, cursor, amount)
    local b = map[name]
    if not b then
        b = {}
        for i = 1, BUCKETS do b[i] = 0 end
        map[name] = b
    end
    b[cursor] = b[cursor] + amount
end

function OmniHubRates.recordProduced(s, name, amount)
    if amount and amount > 0 then bump(s.produced, name, s.cursor, amount) end
end

function OmniHubRates.recordConsumed(s, name, amount)
    if amount and amount > 0 then bump(s.consumed, name, s.cursor, amount) end
end

-- Rolls the window forward by `seconds`, zeroing each new current bucket across all tracked goods.
function OmniHubRates.advance(s, seconds)
    if not seconds or seconds <= 0 then return end
    s.accum = s.accum + seconds
    while s.accum >= BUCKET_SECONDS do
        s.accum  = s.accum - BUCKET_SECONDS
        s.cursor = (s.cursor % BUCKETS) + 1
        for _, b in pairs(s.produced) do b[s.cursor] = 0 end
        for _, b in pairs(s.consumed) do b[s.cursor] = 0 end
    end
end

local function windowSum(map, name)
    local b = map[name]
    if not b then return 0 end
    local t = 0
    for i = 1, BUCKETS do t = t + b[i] end
    return t
end

-- Units produced/consumed in the trailing window = the actual per-minute rate (window is ~60s).
function OmniHubRates.producedPerMin(s, name) return windowSum(s.produced, name) end
function OmniHubRates.consumedPerMin(s, name) return windowSum(s.consumed, name) end

return OmniHubRates
