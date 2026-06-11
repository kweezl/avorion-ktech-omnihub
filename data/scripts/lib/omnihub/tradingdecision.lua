package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubTradingDecision
-- Pure NPC auto-trade decisions, shared by the ONLINE executor (omnihubcontroller's wave
-- requestTraders) and the OFFLINE executor (offlinesim via the galaxy director): per-good
-- seller/buyer gates, the wave planner/gate/size math, and the docked transaction order.
-- Engine reads are abstracted behind `query`:
--   query.getNumGoods(name) -> current stock (number)
--   query.getMaxGoods(name) -> the good's external-trade cap; 0 when the good is NOT in the hub's
--                              bought/sold lists (i.e. not externally tradeable)
--   query.goodPrice(name)   -> base price (number), or nil/false for an unknown good
-- `rng` exposes :random01() -> uniform [0,1) like the engine Random (buyer amounts, the 20%
-- high-value ship roll). Each decide function returns a decision table or nil ("do not spawn").
OmniHubTradingDecision = {}

local function round(x) return math.floor(x + 0.5) end

-- Whether/how to summon a SELLER to deliver an ingredient. Returns {name=, amount=} or nil.
-- Fixes the A2 bug: returns nil (NOT a negative amount) when the good isn't externally tradeable
-- (getMaxGoods == 0). The old inline code computed min(0,500)-have < 0 and still spawned a no-op
-- trader, burning the request cooldown.
function OmniHubTradingDecision.decideSeller(good, query, immediate, have)
    have = have or query.getNumGoods(good.name)  -- optional pre-read so planWave queries once
    if have >= good.amount then return nil end          -- already stocked enough
    local maximum = query.getMaxGoods(good.name)
    if maximum <= 0 then return nil end                  -- not externally tradeable (A2 fix)
    local amount = math.min(maximum, 500) - have
    if immediate then amount = round(amount * 0.3) end
    if amount <= 0 then return nil end
    return { name = good.name, amount = amount }
end

-- Tiered sell policy (replaces factory.lua-style decideBuyer): fill thresholds a sold good must
-- reach before NPC buyers are offered it. Tier 1 (neither result nor ingredient) sells at any
-- positive stock; tier 2 (product) waits for 30% fill; tier 3 (ingredient) is protected until 80%.
OmniHubTradingDecision.SELL_FILL_PRODUCT    = 0.30
OmniHubTradingDecision.SELL_FILL_INGREDIENT = 0.80

-- Whether a sold good (classified by OmniHubTrading.sellTier) may be offered to an NPC buyer.
-- max == 0 means not externally sold (A2 gate); stock == 0 would dock a buyer that leaves empty.
-- Thresholds are inclusive: "stock >= 30% of max".
function OmniHubTradingDecision.sellEligible(tier, stock, max)
    if max <= 0 or stock <= 0 then return false end
    if tier == 3 then return stock / max >= OmniHubTradingDecision.SELL_FILL_INGREDIENT end
    if tier == 2 then return stock / max >= OmniHubTradingDecision.SELL_FILL_PRODUCT end
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- Wave model (see docs/superpowers/specs/2026-06-10-npc-multi-trader-exploration.md)
-- One wave = a deterministic batch of mixed-trader manifests; a new wave starts only when no
-- trader is still serving the hub (with a forced-restart backstop against zombie ships).
-- ────────────────────────────────────────────────────────────────────────────

-- Wave size: how many traders to spawn = global config cap, further capped by free docks
-- (logical dock reservation — never more ships than docking positions minus live traders).
function OmniHubTradingDecision.waveSize(configMax, dockCount, liveTraders)
    local free = (dockCount or 0) - (liveTraders or 0)
    return math.max(0, math.min(configMax or 0, free))
end

-- Wave gate: strict zero-count start with the forced-restart backstop. `blockedWindows` is the
-- consecutive-blocked counter BEFORE this window; the returned `blocked` is its new value (store
-- it back). A live-but-stuck ship (ours past its TTL self-despawn, or an ambient zombie we can't
-- give a TTL) would otherwise block trading forever — after `forceThreshold` consecutive blocked
-- windows the wave starts anyway.
function OmniHubTradingDecision.waveGate(liveCount, blockedWindows, forceThreshold)
    if (liveCount or 0) <= 0 then
        return { start = true, forced = false, blocked = 0 }
    end
    local blocked = (blockedWindows or 0) + 1
    if forceThreshold and forceThreshold > 0 and blocked >= forceThreshold then
        return { start = true, forced = true, blocked = 0 }
    end
    return { start = false, forced = false, blocked = blocked }
end

-- Partial-purchase retry amount when a docked delivery fails vanilla's all-or-nothing canPay:
-- HALF of what the balance covers — floor(floor(balance/unitCost) / 2) — deliberately leaving
-- budget open for the other deliveries of the same wave instead of letting one oversized load
-- drain the wallet. 0 for nil/non-positive inputs or when even half a unit isn't affordable
-- (callers skip the retry on 0).
function OmniHubTradingDecision.partialBuyAmount(balance, unitCost)
    if not balance or balance <= 0 then return 0 end
    if not unitCost or unitCost <= 0 then return 0 end
    return math.floor(math.floor(balance / unitCost) / 2)
end

-- Trader TTL watchdog decision: force the fly-out once the ship's lifetime clock reaches the TTL.
-- A nil/non-positive TTL disables the watchdog (never force).
function OmniHubTradingDecision.shouldFlyOut(age, ttl)
    if not ttl or ttl <= 0 then return false end
    return (age or 0) >= ttl
end

-- Flattens a manifest into the docked transaction order: deliveries FIRST (selling the cargo
-- frees the trader's hold), then pickups. The ship script iterates this list verbatim.
function OmniHubTradingDecision.transactionList(manifest)
    local ops = {}
    for _, d in ipairs(manifest.deliveries or {}) do
        ops[#ops + 1] = { kind = "deliver", name = d.name, amount = d.amount }
    end
    for _, p in ipairs(manifest.pickups or {}) do
        ops[#ops + 1] = { kind = "pickup", name = p.name, amount = p.amount }
    end
    return ops
end

-- Plans one wave: runs every ingredient through decideSeller and every sold good (agg.sold, the
-- {name, tier} array from OmniHubTrading.buildSoldPickupList) through sellEligible (A2 gates hold
-- by construction — non-tradeable goods never enter a manifest), then packs the eligible trades
-- into up to caps.maxShips mixed manifests:
--   caps.maxShips    REQUIRED ship budget (waveSize result)
--   caps.shipValue   per-ship TOTAL value cap (vanilla richness formula; each ship also gets
--                    vanilla's 20% chance of a 1-5x high-value budget via rng:random01())
--   caps.shipVolume  optional per-ship cargo volume cap (needs query.getGoodSize)
--   caps.immediate   vanilla's x0.3 delivery scaling for the loaded-but-empty regime
--   caps.budget      optional TOTAL delivery spend cap (the owner faction's money): deliveries
--                    the owner can't pay for are never requested (a docked buyFromShip would
--                    silently fail its canPay check and the trader would leave empty). Pickups
--                    earn money and are never budget-limited. Estimated at price x caps.buyFactor.
-- Deliveries are packed MOST-STARVED FIRST (lowest have/need ratio), so a tight wave or budget
-- feeds the production bottleneck instead of whichever ingredient the recipe lists first.
-- Pickups are packed TIER-ASCENDING (sell non-chain goods before products before ingredients),
-- fill-descending within a tier (fullest storage first), name as the deterministic tiebreak.
-- Items that overflow a ship spill into the next; whatever exceeds the wave waits for the next
-- one. An item whose single unit exceeds a FRESH ship's budget is unshippable and skipped.
function OmniHubTradingDecision.planWave(agg, query, rng, caps)
    local maxShips = caps.maxShips or 0
    if maxShips <= 0 then return {} end

    local deliveries = {}
    for _, ing in pairs(agg.ingredients or {}) do
        local have = query.getNumGoods(ing.name)
        local d = OmniHubTradingDecision.decideSeller(ing, query, caps.immediate, have)
        if d then
            local need = (ing.amount and ing.amount > 0) and ing.amount or 1
            deliveries[#deliveries + 1] = {
                kind = "deliver", name = d.name, amount = d.amount,
                scarcity = have / need,
            }
        end
    end
    table.sort(deliveries, function(a, b) return a.scarcity < b.scarcity end)

    -- One pass over the sold goods: a single getNumGoods/getMaxGoods read each, the eligibility
    -- gate, then ONE composite sort. A good without a catalog price can't be value-packed; skip.
    local pickups = {}
    for _, s in ipairs(agg.sold or {}) do
        local stock = query.getNumGoods(s.name)
        local max   = query.getMaxGoods(s.name)
        if query.goodPrice(s.name) and OmniHubTradingDecision.sellEligible(s.tier, stock, max) then
            -- vanilla buyer amount: 100 + random(0..1000); sellToShip clamps to real stock at dock.
            -- Immediate mode sells INSTANTLY against current stock (no fly-in time for production
            -- to accrue), so clamp to it — an optimistic amount comes back as sellGoods error 1.
            local amount = math.floor(100 + rng:random01() * 1000 + 0.5)
            if caps.immediate then amount = math.min(amount, stock) end
            if amount > 0 then
                pickups[#pickups + 1] = {
                    kind = "pickup", name = s.name, amount = amount,
                    tier = s.tier, fill = stock / max,
                }
            end
        end
    end
    table.sort(pickups, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.fill ~= b.fill then return a.fill > b.fill end
        return a.name < b.name
    end)

    local items = {}
    for _, d in ipairs(deliveries) do items[#items + 1] = d end
    for _, p in ipairs(pickups)    do items[#items + 1] = p end
    if #items == 0 then return {} end

    local manifests = {}
    local ship, valueLeft, volumeLeft, shipEmpty

    local function openShip()
        if #manifests >= maxShips then return false end
        ship      = { deliveries = {}, pickups = {} }
        shipEmpty = true
        manifests[#manifests + 1] = ship
        valueLeft = caps.shipValue or math.huge
        if rng:random01() < 0.2 then valueLeft = valueLeft * (1 + rng:random01() * 4) end
        volumeLeft = caps.shipVolume or math.huge
        return true
    end
    openShip()

    local budgetLeft = caps.budget  -- nil = unlimited; deliveries only
    local buyFactor  = caps.buyFactor or 1.0

    for _, item in ipairs(items) do
        local price     = query.goodPrice(item.name) or 0
        local size      = (query.getGoodSize and query.getGoodSize(item.name)) or 1
        local remaining = item.amount

        -- Owner affordability: never request more than the remaining buy budget covers.
        if item.kind == "deliver" and budgetLeft and price > 0 then
            local unitCost   = price * buyFactor
            local affordable = (unitCost > 0) and math.floor(budgetLeft / unitCost) or remaining
            remaining = math.min(remaining, affordable)
        end

        while remaining > 0 do
            local fit = remaining
            if price > 0 then fit = math.min(fit, math.floor(valueLeft / price)) end
            if size  > 0 then fit = math.min(fit, math.floor(volumeLeft / size)) end
            if fit > 0 then
                local list = (item.kind == "deliver") and ship.deliveries or ship.pickups
                list[#list + 1] = { name = item.name, amount = fit }
                valueLeft  = valueLeft  - fit * price
                volumeLeft = volumeLeft - fit * size
                remaining  = remaining - fit
                shipEmpty  = false
                if item.kind == "deliver" and budgetLeft then
                    budgetLeft = budgetLeft - fit * price * buyFactor
                end
            elseif shipEmpty then
                break                                -- one unit over a fresh budget: unshippable
            elseif not openShip() then
                remaining = 0                        -- wave full: surplus waits for the next wave
            end
        end
    end

    -- Drop a trailing empty ship (opened but nothing fit it).
    if shipEmpty then manifests[#manifests] = nil end
    return manifests
end

return OmniHubTradingDecision
