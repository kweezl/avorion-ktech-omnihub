package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubTradingDecision
-- Pure auto-trade spawn decisions extracted from omnihubcontroller's trySpawnSeller/trySpawnBuyer, so
-- they are unit-testable and (Phase 2/3) reusable by the offline director. Engine reads are abstracted
-- behind `query`:
--   query.getNumGoods(name) -> current stock (number)
--   query.getMaxGoods(name) -> the good's external-trade cap; 0 when the good is NOT in the hub's
--                              bought/sold lists (i.e. not externally tradeable)
--   query.goodPrice(name)   -> base price (number), or nil/false for an unknown good
-- `rng` exposes :test(probability) like the engine Random. Each function returns a decision table or
-- nil ("do not spawn").
OmniHubTradingDecision = {}

local function round(x) return math.floor(x + 0.5) end

-- Whether/how to summon a SELLER to deliver an ingredient. Returns {name=, amount=} or nil.
-- Fixes the A2 bug: returns nil (NOT a negative amount) when the good isn't externally tradeable
-- (getMaxGoods == 0). The old inline code computed min(0,500)-have < 0 and still spawned a no-op
-- trader, burning the request cooldown.
function OmniHubTradingDecision.decideSeller(good, query, immediate)
    local have = query.getNumGoods(good.name)
    if have >= good.amount then return nil end          -- already stocked enough
    local maximum = query.getMaxGoods(good.name)
    if maximum <= 0 then return nil end                  -- not externally tradeable (A2 fix)
    local amount = math.min(maximum, 500) - have
    if immediate then amount = round(amount * 0.3) end
    if amount <= 0 then return nil end
    return { name = good.name, amount = amount }
end

-- Whether to summon a BUYER to take a product/garbage. Returns {name=} or nil.
-- Returns nil when the good is unknown OR not externally sold (getMaxGoods == 0): a buyer for a good
-- the hub doesn't sell can never complete (sellToShip requires it in soldGoods), so spawning one only
-- burns the cooldown. Otherwise mirrors factory.lua's trySpawnBuyer thresholds.
function OmniHubTradingDecision.decideBuyer(good, query, rng)
    local price = query.goodPrice(good.name)
    if not price then return nil end
    local maxGoods = query.getMaxGoods(good.name)
    if maxGoods <= 0 then return nil end                 -- not externally sold (A2 fix)
    local newAmount = query.getNumGoods(good.name) + good.amount
    local value     = newAmount * price
    if newAmount > maxGoods * 0.8 or (value > 100000 and rng:test(0.3)) then
        return { name = good.name }
    end
    return nil
end

return OmniHubTradingDecision
