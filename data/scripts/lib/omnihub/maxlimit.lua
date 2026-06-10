package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubMaxLimit
-- Pure max-limit math: the per-good UNIT cap the controller installs as OmniHub.trader.getMaxStock.
-- The limit governs:
--   * production output  — a cycle won't push a result past its limit (canStartCycle's result gate)
--   * auto-buying        — the hub won't buy resources / player-opted goods past their limit
-- It is NOT a hard cargo limit: owners may overstock by transferring goods into the hub manually
-- (a cargo transfer, not a trade — it never consults getMaxStock). Physical free cargo is the real
-- limiter for a single production cycle, so a hub whose cargo is too small to hold a full limit still
-- produces as long as THIS cycle's output fits (handled in OmniHubProduction.canStartCycle).
--
-- Roles, resolved per good (first match wins):
--   produced and/or consumed  -> L = prodBase * prodCycles * max(producedPerCycle, consumedPerCycle)
--       producedPerCycle = the good's aggregate result + garbage amount across all installed modules in
--       one cycle; consumedPerCycle = its aggregate ingredient amount. We take the MAX of the two role
--       needs, not the sum: a good that is both made and used here draws from ONE pile, so the larger
--       role's buffer dominates and summing would over-allot cargo (e.g. Carbon produced 5 + consumed 1
--       needs a 5-cycle buffer, not 6). For a pure producer or pure consumer the other term is 0, so
--       max() reduces to that single role. Scaling by throughput means a high-volume good gets a
--       proportionally larger limit, replacing the vanilla even-split that choked big producers (cargo /
--       numTradeSlots gave each good the same tiny cap regardless of output).
--   buy- OR sell-marked only (not produced/consumed) -> L = buyLimit  (flat passthrough buffer).
--       Sell-only goods need the cap too: with no entry, getMaxStock()==0 made the UI render 0/0
--       AND getMaxGoods()==0 excluded the good from NPC trading entirely (the Aluminum case).
--   anything else (unmarked, not produced/consumed)   -> L = 0 (no auto-acquisition, no limit)
--
-- O(n) over the union of relevant goods. The controller caches the result and recomputes ONLY on
-- module or configuration changes — never per getMaxStock call (that path is hot).
OmniHubMaxLimit = {}

-- agg         = OmniHubProduction.aggregate(...) result (ingAmounts / resAmounts / garAmounts).
-- boughtNames = good names the hub buys (explicit buy marks), from buildTradeLists.
-- params      = { buyLimit, prodBase, prodCycles } (units / multipliers; nil treated as 0).
-- soldNames   = good names the hub sells (explicit sell marks); optional for back-compat.
-- Returns { [name] = limitUnits } for every good that has a limit (others simply absent -> 0).
function OmniHubMaxLimit.compute(agg, boughtNames, params, soldNames)
    params = params or {}
    local buyLimit   = params.buyLimit or 0
    local prodBase   = params.prodBase or 0
    local prodCycles = params.prodCycles or 0

    local marked = {}
    for _, n in ipairs(boughtNames or {}) do marked[n] = true end
    for _, n in ipairs(soldNames or {})   do marked[n] = true end

    -- Every good that could have a limit: produced/consumed (from the aggregate) + explicitly
    -- traded (buy or sell marks).
    local names = {}
    for n in pairs(agg.ingAmounts) do names[n] = true end
    for n in pairs(agg.resAmounts) do names[n] = true end
    for n in pairs(agg.garAmounts) do names[n] = true end
    for n in pairs(marked)         do names[n] = true end

    local limits = {}
    for name in pairs(names) do
        local produced = (agg.resAmounts[name] or 0) + (agg.garAmounts[name] or 0)
        local consumed = (agg.ingAmounts[name] or 0)
        if produced > 0 or consumed > 0 then
            -- MAX of the two role buffers (not sum): an intermediate good shares one stock pile.
            limits[name] = prodBase * prodCycles * math.max(produced, consumed)
        elseif marked[name] then
            limits[name] = buyLimit
        else
            limits[name] = 0
        end
    end

    return limits
end

return OmniHubMaxLimit
