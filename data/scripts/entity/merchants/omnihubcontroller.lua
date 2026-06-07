package.path = package.path .. ";data/scripts/?.lua"
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
include("utility")
include("faction")
include("randomext")
include("callable")
include("productions")
include("goods")
local TradingAPI = include("tradingmanager")  -- exposes TradingAPI global
local TradingUtility = include("tradingutility")
local OmniHubConfig = include("config")
local OmniHubModuleDefs = include("moduledefs")
local OmniHubModuleItem = include("moduleitem")
local OmniHubProduction = include("production")
local OmniHubTrading = include("trading")
local OmniHubStats = include("stats")
local OmniHubRates = include("rates")
local OmniHubSupplierStock = include("supplierstock")  -- pure pageSlice (clamp/bounds) for buy/sell paging
local Dialog = include("dialogutility")

-- Server-only libraries (transfers touches Sector()/Entity(); FactoryMap drives supply-demand types).
local OmniHubTransfers, FactoryMap
if onServer() then
    OmniHubTransfers = include("transfers")
    FactoryMap       = include("factorymap")
end

-- Client-only UI tab modules (presentation; no server calls or domain math).
local OmniHubGoodsTable, OmniHubUIStatistics, OmniHubUIConfig, OmniHubUIModules
if onClient() then
    OmniHubGoodsTable   = include("ui/goodstable")
    OmniHubUIStatistics = include("ui/statistics")
    OmniHubUIConfig     = include("ui/config")
    OmniHubUIModules    = include("ui/modules")
end

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHub
OmniHub = TradingAPI:CreateNamespace()

-- ────────────────────────────────────────────────────────────────
-- Constants
-- ────────────────────────────────────────────────────────────────
local MIN_CARGO_BAY = 25000
local MIN_TIME_TO_PRODUCE = 15.0  -- seconds, matches factory.lua
local SECTOR_TRADE_INTERVAL = 6   -- seconds between non-docked inter-station transfers (factory.lua)
local PRICE_MIN, PRICE_MAX = 0.8, 1.2  -- ±20% base-price slider range

-- ────────────────────────────────────────────────────────────────
-- Server-side state (persisted through secure/restore)
-- ────────────────────────────────────────────────────────────────
local installed          = {}  -- { [moduleKey] = count }
local productionProgress = {}  -- { [moduleKey] = {progress=0..1, boosted=bool} } or nil if idle
local timeToProduce      = {}  -- { [moduleKey] = seconds } — derived, recomputed on restore/rebuild

-- Per-good external-trading marks (sparse: only DISABLED goods are stored, so new goods default ON).
-- sellEnabled[name] == false hides a product from the Buy tab + NPC buyers; buyEnabled[name] == false
-- hides a resource from the Sell tab + NPC sellers. Internal production/consumption is unaffected.
local sellEnabled = {}
local buyEnabled  = {}

-- Trade statistics (lifetime profit, last-hour ring, recent transaction log).
local stats = OmniHubStats.new()

-- Actual production/consumption throughput tracker (trailing ~60s window) for the Goods tab's
-- "actual/max" rates. Transient runtime state — not persisted; it re-fills as production runs.
local rates = OmniHubRates.new()

-- Inter-station transfer config + scratch. chosen* are the player's selected partner stations
-- ({ [idString] = { {good, script}, ... } }); candidate* are the full sector scan used to resolve a
-- combo selection back to its trades; *Errors are surfaced in the config tab.
local chosenDelivered     = {}
local chosenDelivering    = {}
local candidateDelivered  = {}
local candidateDelivering = {}
local deliveredErrors     = {}
local deliveringErrors    = {}

-- Aggregated production table: single merged recipe across all installed factory modules,
-- with ingredient/result/garbage amounts summed and scaled by module count.
-- Mirrors factory.lua's file-local `production` variable so requestTraders can iterate it directly.
-- nil when no factory modules are installed.
local aggregatedProduction = nil

OmniHub.productionCapacity = 100  -- updated by onBlockPlanChanged
OmniHub.traderCooldown     = 0    -- countdown timer; decremented in update()

-- ────────────────────────────────────────────────────────────────
-- Cache TradingAPI base methods BEFORE we override
-- ────────────────────────────────────────────────────────────────
local base_secure   = OmniHub.secure
local base_restore  = OmniHub.restore
local base_buyGoods  = OmniHub.buyGoods
local base_sellGoods = OmniHub.sellGoods
local base_receiveGoods = OmniHub.receiveGoods

-- ────────────────────────────────────────────────────────────────
-- Small helpers
-- ────────────────────────────────────────────────────────────────
-- Server-authoritative owner check used to gate every mutating RPC (marking, config, install/
-- uninstall). Delegates to the vanilla helper, which keys off callingPlayer, grants the direct owner,
-- requires the ManageStations alliance privilege for alliance-owned stations, and messages the player
-- on denial. Returns true only when the caller is permitted.
local function callerIsOwner()
    local owner = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageStations)
    return owner ~= nil
end

-- ────────────────────────────────────────────────────────────────
-- Interaction / initialization
-- ────────────────────────────────────────────────────────────────
function OmniHub.interactionPossible(playerIndex, option)
    return CheckFactionInteraction(playerIndex, -10000)
end

function OmniHub.getIcon()
    return OmniHubModuleDefs.ICON
end

function OmniHub.initialize()
    local entity = Entity()

    if entity.title == "" then
        entity.title = "OmniHub"%_t
        InteractionText(entity.index).text = Dialog.generateStationInteractionText(entity, random())
    end

    -- Floating icon in the 3D scene + on the map. This is the EntityIcon component (set client-side),
    -- distinct from getIcon() above which only feeds the interaction menu. Guard on "" so we don't
    -- stomp an icon another script already set. Matches the vanilla equipmentdock/factory pattern.
    if onClient() then
        if EntityIcon().icon == "" then
            EntityIcon().icon = OmniHubModuleDefs.MAP_ICON
        end
        -- Pre-fetch the buy/sell good lists so the Buy/Sell tabs can be gated correctly the FIRST
        -- time the window opens. The lists arrive asynchronously via receiveGoods (which re-gates the
        -- tabs); without this they'd still be empty when onShowWindow first runs and both tabs would
        -- stay hidden until a second open. Mirrors factory.lua's client initialize.
        OmniHub.requestGoods()
    end

    if onServer() then
        local bay = CargoBay()
        if bay and bay.cargoHold < MIN_CARGO_BAY then
            bay.cargoHold = MIN_CARGO_BAY
        end

        -- Fresh station defaults: trade with others and actively keep goods flowing out of the box.
        -- A loaded station overwrites these from saved tradingData in restore().
        OmniHub.trader.buyFromOthers   = true
        OmniHub.trader.sellToOthers    = true
        OmniHub.trader.activelyRequest = true
        OmniHub.trader.activelySell    = true

        entity:registerCallback("onBlockPlanChanged", "onBlockPlanChanged")
        entity:registerCallback("onDestroyed", "onDestroyed")

        -- Attach the dev-only "OmniHub Tests" interaction script. Done here (not only via the station
        -- founder) so OmniHubs founded before it existed pick it up on reload. addScriptOnce avoids
        -- double-attach for newly founded stations that already got it from the founder list. The
        -- option only appears in dev mode (gated in omnihubtests.lua:interactionPossible).
        entity:addScriptOnce("data/scripts/entity/merchants/omnihubtests.lua")

        OmniHub.productionCapacity = Plan():getStats().productionCapacity
    end
end

function OmniHub.onBlockPlanChanged(delta)
    OmniHub.productionCapacity = Plan():getStats().productionCapacity
    for key in pairs(installed) do
        timeToProduce[key] = OmniHub.computeTimeToProduce(key)
    end
end

-- ────────────────────────────────────────────────────────────────
-- Loot drops on destruction
-- ────────────────────────────────────────────────────────────────

-- Signature is onDestroyed(index, lastDamageInflictor) per the engine (Entity Callbacks doc).
function OmniHub.onDestroyed(index, lastDamageInflictor)
    if not onServer() then return end

    -- Pure roll decides which installed units drop; engine calls (item construction + drop) stay here.
    local drops = OmniHubProduction.rollDrops(installed, OmniHubConfig.get("dropChance"), random())
    if #drops == 0 then return end

    -- Modules must be dropped via Sector():dropVanillaItem at destruction time — NOT inserted into
    -- the Loot component, which the engine only spawns from content populated *before* death (mirrors
    -- entity/utility/buildingknowledgeloot.lua). reservedFor is nil → free-for-all wreckage loot.
    local sector = Sector()
    local pos    = Entity().translationf

    for _, key in ipairs(drops) do
        local item = OmniHubModuleItem.build(key)
        sector:dropVanillaItem(pos, nil, nil, item)
    end
end

-- ────────────────────────────────────────────────────────────────
-- Persistence
-- ────────────────────────────────────────────────────────────────
function OmniHub.secure()
    local data = base_secure and base_secure() or {}
    data.installed          = installed
    data.productionProgress = productionProgress
    data.traderCooldown     = OmniHub.traderCooldown
    data.sellEnabled        = sellEnabled
    data.buyEnabled         = buyEnabled
    data.stats              = stats
    data.chosenDelivered    = chosenDelivered
    data.chosenDelivering   = chosenDelivering
    data.tradingData        = OmniHub.secureTradingGoods()
    return data
end

function OmniHub.restore(data)
    if base_restore then base_restore(data) end
    installed              = data.installed          or {}
    productionProgress     = data.productionProgress or {}
    OmniHub.traderCooldown = data.traderCooldown     or 0
    sellEnabled            = data.sellEnabled        or {}
    buyEnabled             = data.buyEnabled         or {}
    stats                  = data.stats              or OmniHubStats.new()
    chosenDelivered        = data.chosenDelivered    or {}
    chosenDelivering       = data.chosenDelivering   or {}
    if data.tradingData then OmniHub.restoreTradingGoods(data.tradingData) end
    if onServer() then OmniHub.rebuild() end
end

-- ────────────────────────────────────────────────────────────────
-- Update loop (production + trader spawning + transfers + stats)
-- ────────────────────────────────────────────────────────────────
function OmniHub.getUpdateInterval()
    -- numPlayers is a server-only Sector property; reading it on the client
    -- yields nil ("not readable") and crashes every tick. Gate the read.
    if onServer() and Sector().numPlayers > 0 then return 1 end
    return 5
end

function OmniHub.update(timeStep)
    if not onServer() then return end
    OmniHub.runProductionCycles(timeStep)
    OmniHub.requestTraders(timeStep)
    OmniHub.updateTransfers(timeStep)
    OmniHub.advanceStats(timeStep)
    OmniHubRates.advance(rates, timeStep)
end

-- ────────────────────────────────────────────────────────────────
-- Production engine
-- ────────────────────────────────────────────────────────────────

function OmniHub.runProductionCycles(timeStep)
    for key, count in pairs(installed) do
        OmniHub.tickRecipe(key, count, timeStep)
    end
end

function OmniHub.tickRecipe(key, count, timeStep)
    local prod = OmniHubModuleDefs.resolveRecipe(key)
    if not prod then return end

    local ttm      = timeToProduce[key] or MIN_TIME_TO_PRODUCE
    local progress = productionProgress[key]

    if progress then
        local advance = timeStep / ttm
        if progress.boosted then advance = advance * 2 end
        progress.progress = progress.progress + advance

        if progress.progress >= 1.0 then
            for _, res in pairs(prod.results) do
                OmniHub.increaseGoods(res.name, res.amount * count)
                OmniHubRates.recordProduced(rates, res.name, res.amount * count)
            end
            if prod.garbages then
                for _, gar in pairs(prod.garbages) do
                    OmniHub.increaseGoods(gar.name, gar.amount * count)
                    OmniHubRates.recordProduced(rates, gar.name, gar.amount * count)
                end
            end
            productionProgress[key] = nil
        end
        return
    end

    -- Try to start a new cycle. The affordability decision is pure (OmniHubProduction.canStartCycle);
    -- the engine reads are wired in through the query table, and ingredient consumption stays here.
    local entity = Entity()
    local query  = {
        getNumGoods    = function(name) return OmniHub.getNumGoods(name) end,
        getGoodSize    = function(name) return OmniHub.getGoodSize(name) end,
        getMaxStock    = function(name, size) return OmniHub.getMaxStock({name = name, size = size}) end,
        freeCargoSpace = entity.freeCargoSpace,
    }

    local decision = OmniHubProduction.canStartCycle(prod, count, query)
    if not decision.canProduce then return end

    for _, ing in pairs(prod.ingredients) do
        OmniHub.decreaseGoods(ing.name, ing.amount * count)
        OmniHubRates.recordConsumed(rates, ing.name, ing.amount * count)
    end

    productionProgress[key] = {progress = 0, boosted = decision.boosted}
end

function OmniHub.computeTimeToProduce(key)
    return OmniHubProduction.timeToProduce(
        OmniHubModuleDefs.resolveRecipe(key),
        goods,
        OmniHub.productionCapacity,
        MIN_TIME_TO_PRODUCE
    )
end

-- ────────────────────────────────────────────────────────────────
-- Module registry / trade-list rebuild
-- ────────────────────────────────────────────────────────────────

function OmniHub.rebuild()
    if not onServer() then return end

    -- Pure aggregation of all installed recipes (summed amounts + merged aggregatedProduction).
    local agg = OmniHubProduction.aggregate(installed, OmniHubModuleDefs.resolveRecipe)

    -- Pure: the EXPLICITLY ticked Buy/Sell goods -> bought/sold NAME lists (no role default, so
    -- install/uninstall never changes what's traded).
    local lists = OmniHubTrading.buildTradeLists(sellEnabled, buyEnabled)

    -- Build TradingGood arrays for initializeTrading (engine-side: needs goods:good()).
    local bought = {}
    local sold   = {}
    for _, name in ipairs(lists.boughtNames) do
        local g = goods[name]
        if g then bought[#bought + 1] = g:good() end
    end
    for _, name in ipairs(lists.soldNames) do
        local g = goods[name]
        if g then sold[#sold + 1] = g:good() end
    end

    OmniHub.initializeTrading(bought, sold)

    aggregatedProduction = agg.aggregatedProduction
    OmniHub.updateOwnSupply()

    for key in pairs(installed) do
        timeToProduce[key] = OmniHub.computeTimeToProduce(key)
    end
end

-- Tags each traded good with its regional supply/demand role so getBuyPrice/getSellPrice and the
-- economy simulation price it correctly. Mirrors factory.lua:485-499.
function OmniHub.updateOwnSupply()
    OmniHub.trader.ownSupplyTypes = {}
    if not aggregatedProduction then return end

    local fm = FactoryMap()
    for _, ing in pairs(aggregatedProduction.ingredients) do
        OmniHub.trader.ownSupplyTypes[ing.name] = fm.SupplyType.FactoryDemand
    end
    for _, res in pairs(aggregatedProduction.results) do
        OmniHub.trader.ownSupplyTypes[res.name] = fm.SupplyType.FactorySupply
    end
    for _, gar in pairs(aggregatedProduction.garbages) do
        OmniHub.trader.ownSupplyTypes[gar.name] = fm.SupplyType.FactoryGarbage
    end
end

-- Regional price change percentage for a good (e.g. +12 / -8), via the sector economy simulation.
-- Returns 0 when unavailable.
-- Regional supply/demand for a good: returns (supplyDemandFactor, pct) where the factor multiplies the
-- base price (1.0 = neutral) and pct is the signed percentage shown in the Demand/Supply column.
function OmniHub.regionalInfo(name)
    local supplyType = OmniHub.trader.ownSupplyTypes and OmniHub.trader.ownSupplyTypes[name]
    local ok, factor = Sector():invokeFunction("economyupdater.lua", "getSupplyDemandPriceChange", name, supplyType)
    if ok ~= 0 or not factor then return 1, 0 end
    local influence = OmniHub.trader.supplyDemandInfluence or 0
    return 1 + factor * influence, round(factor * influence * 100)
end

function OmniHub.regionalPct(name)
    local _, pct = OmniHub.regionalInfo(name)
    return pct
end

-- requestTraders: mirrors factory.lua:1828-1885.
function OmniHub.requestTraders(timeStep)
    if not onServer() then return end
    if not aggregatedProduction then return end

    OmniHub.traderCooldown = OmniHub.traderCooldown - timeStep
    if OmniHub.traderCooldown > 0 then return end
    OmniHub.traderCooldown = OmniHubConfig.get("traderRequestCooldown")

    local sector = Sector()
    if sector:getValue("war_zone") then return end

    local entity = Entity()

    if TradingUtility.hasTraders(entity) then return end

    local immediate  = (sector.numPlayers == 0)
    local pSeller    = OmniHub.getSellerProbability()
    local wantSeller = random():test(pSeller)

    if not wantSeller and OmniHub.trader.activelySell then
        for _, result in pairs(aggregatedProduction.results) do
            if OmniHub.trySpawnBuyer(entity, result, immediate) then return end
        end
    end

    if wantSeller and OmniHub.trader.activelyRequest then
        for _, ing in pairs(aggregatedProduction.ingredients) do
            if OmniHub.trySpawnSeller(entity, ing, immediate) then return end
        end
    end

    if not wantSeller and OmniHub.trader.activelySell then
        for _, gar in pairs(aggregatedProduction.garbages) do
            if OmniHub.trySpawnBuyer(entity, gar, immediate) then return end
        end
    end
end

-- Mirrors factory.lua:1893
function OmniHub.getSellerProbability()
    return OmniHubProduction.sellerProbability(OmniHub.trader.buyPriceFactor)
end

-- Mirrors factory.lua:1898
function OmniHub.trySpawnSeller(entity, good, immediate)
    local have    = OmniHub.getNumGoods(good.name)
    local maximum = OmniHub.getMaxGoods(good.name)
    if have < good.amount then
        local amount = math.min(maximum, 500) - have
        if immediate then amount = round(amount * 0.3) end
        TradingUtility.spawnSeller(entity.id, getScriptPath(), good.name, amount, OmniHub, immediate)
        return true
    end
end

-- Mirrors factory.lua:1913
function OmniHub.trySpawnBuyer(entity, good, immediate)
    if not goods[good.name] then return end
    local newAmount = OmniHub.getNumGoods(good.name) + good.amount
    local maxGoods  = OmniHub.getMaxGoods(good.name)
    local value     = newAmount * goods[good.name].price
    if newAmount > maxGoods * 0.8 or (value > 100000 and random():test(0.3)) then
        TradingUtility.spawnBuyer(entity.id, getScriptPath(), good.name, OmniHub, immediate)
        return true
    end
end

-- ────────────────────────────────────────────────────────────────
-- Statistics (transaction logging + last-hour ring)
-- ────────────────────────────────────────────────────────────────

-- Wrap the inherited buy/sell so every successful trader transaction is recorded. buyGoods/sellGoods
-- return (0, price) on success (tradingmanager.lua); a bare error code otherwise.
function OmniHub.buyGoods(good, amount, otherFactionIndex, monetaryOnly)
    local code, price = base_buyGoods(good, amount, otherFactionIndex, monetaryOnly)
    if onServer() and code == 0 then
        local f = Faction(otherFactionIndex)
        OmniHubStats.record(stats, {kind = "buy", good = good.name, amount = amount, price = price,
                                    partner = f and f.translatedName or ""})
    end
    return code, price
end

function OmniHub.sellGoods(good, amount, otherFactionIndex, monetaryOnly)
    local code, price = base_sellGoods(good, amount, otherFactionIndex, monetaryOnly)
    if onServer() and code == 0 then
        local f = Faction(otherFactionIndex)
        OmniHubStats.record(stats, {kind = "sell", good = good.name, amount = amount, price = price,
                                    partner = f and f.translatedName or ""})
    end
    return code, price
end

function OmniHub.advanceStats(timeStep)
    OmniHub.statsClock = (OmniHub.statsClock or 0) + timeStep
    if OmniHub.statsClock >= 60 then
        local mins = math.floor(OmniHub.statsClock / 60)
        OmniHubStats.advance(stats, mins)
        OmniHub.statsClock = OmniHub.statsClock - mins * 60
    end
end

function OmniHub.sendStats()
    if not onServer() then return end
    invokeClientFunction(Player(callingPlayer), "receiveStats",
        OmniHubStats.lifetimeProfit(stats), OmniHubStats.lastHourProfit(stats), OmniHubStats.recent(stats, 10))
end
callable(OmniHub, "sendStats")

-- ────────────────────────────────────────────────────────────────
-- Inter-station transfers
-- ────────────────────────────────────────────────────────────────

function OmniHub.updateTransfers(timeStep)
    if not aggregatedProduction then return end
    if not (next(chosenDelivered) or next(chosenDelivering)) then return end

    OmniHub.tradeClock = (OmniHub.tradeClock or 0) + timeStep
    local dockedOnly = true
    if OmniHub.tradeClock >= SECTOR_TRADE_INTERVAL then
        OmniHub.tradeClock = OmniHub.tradeClock - SECTOR_TRADE_INTERVAL
        dockedOnly = false
    end

    local volume = OmniHubConfig.get("transportVolume")
    local hub = {
        getSoldGoodByName = OmniHub.getSoldGoodByName,
        getStock          = OmniHub.getStock,
        decreaseGoods     = OmniHub.decreaseGoods,
        recordTxn         = function(t) OmniHubStats.record(stats, t) end,
    }
    deliveredErrors  = OmniHubTransfers.deliver(hub, chosenDelivered, volume, dockedOnly)
    deliveringErrors = OmniHubTransfers.fetch(hub, chosenDelivering, volume, dockedOnly)
end

-- Resolves a list of selected partner ids back to their trade lists from the last sector scan.
function OmniHub.resolveChosen(ids, candidates)
    local chosen = {}
    for _, id in ipairs(ids or {}) do
        if id and candidates[id] then chosen[id] = candidates[id] end
    end
    return chosen
end

-- ────────────────────────────────────────────────────────────────
-- Per-good sell/buy marks (owner-gated)
-- ────────────────────────────────────────────────────────────────

-- NOTE: these do NOT push the Buy/Sell lists. The client flips its Goods checkbox optimistically and
-- marks the Buy/Sell tabs dirty; those refresh lazily when the player selects them (saves a full
-- buy/sell payload per toggle).
function OmniHub.setGoodSell(name, enabled)
    if not onServer() then return end
    if not callerIsOwner() then return end
    OmniHubTrading.setMark(sellEnabled, name, enabled)  -- explicit true/false
    OmniHub.rebuild()
end
callable(OmniHub, "setGoodSell")

function OmniHub.setGoodBuy(name, enabled)
    if not onServer() then return end
    if not callerIsOwner() then return end
    OmniHubTrading.setMark(buyEnabled, name, enabled)
    OmniHub.rebuild()
end
callable(OmniHub, "setGoodBuy")

-- Slider price change: set the two factors only (read at trade time — no rebuild, no partner scan).
-- The slider is clamped client-side to ±20% (0.8..1.2), so an out-of-range value means a tampered
-- client: reject it (server stays authoritative) and log the incident. Avorion exposes no kick API to
-- mods, so reject+log is the strongest available response (matches vanilla's reject-don't-kick).
function OmniHub.setPriceFactors(buyFactor, sellFactor)
    if not onServer() then return end
    if not callerIsOwner() then return end

    local function valid(f)
        return type(f) == "number" and f == f
            and f >= PRICE_MIN - 1e-6 and f <= PRICE_MAX + 1e-6
    end
    if not valid(buyFactor) or not valid(sellFactor) then
        local player = Player(callingPlayer)
        local who = (player and player.name or "?") .. " (#" .. tostring(callingPlayer) .. ")"
        print("[OmniHub] SECURITY: " .. who .. " sent out-of-range price factors (buy="
            .. tostring(buyFactor) .. ", sell=" .. tostring(sellFactor) .. ") — rejected.")
        if player then
            player:sendChatMessage("OmniHub"%_t, ChatMessageType.Error, "Invalid price value rejected."%_t)
        end
        return
    end

    OmniHub.setBuyPriceFactor(buyFactor)
    OmniHub.setSellPriceFactor(sellFactor)
end
callable(OmniHub, "setPriceFactors")

-- ────────────────────────────────────────────────────────────────
-- Configuration (owner-gated)
-- ────────────────────────────────────────────────────────────────

function OmniHub.sendHubConfig()
    if not onServer() then return end
    OmniHub.sendHubConfigTo(Player(callingPlayer))
end
callable(OmniHub, "sendHubConfig")

function OmniHub.sendHubConfigTo(player)
    -- Refresh the candidate partner scan so the combos list reachable stations and a later selection
    -- resolves to real trades.
    local del, fetch, delOpts, fetchOpts = OmniHubTransfers.collectPartners(aggregatedProduction)
    candidateDelivered  = del
    candidateDelivering = fetch

    local function keysOf(map)
        local out = {}
        for id in pairs(map) do out[#out + 1] = id end
        return out
    end

    local cfg = {
        activelyRequest   = OmniHub.trader.activelyRequest,
        activelySell      = OmniHub.trader.activelySell,
        priceFactorBuy    = OmniHub.trader.buyPriceFactor,
        priceFactorSell   = OmniHub.trader.sellPriceFactor,
        deliveredIds      = keysOf(chosenDelivered),
        deliveringIds     = keysOf(chosenDelivering),
        deliveredOptions  = delOpts,
        deliveringOptions = fetchOpts,
    }
    invokeClientFunction(player, "receiveHubConfig", cfg, deliveredErrors, deliveringErrors)
end

function OmniHub.applyHubConfig(cfg)
    if not onServer() then return end
    if not callerIsOwner() then return end
    if not cfg then return end

    -- Price factors are owned by the sliders (setPriceFactors); applyHubConfig only handles the
    -- active-trade flags and the inter-station transfers.
    OmniHub.trader.buyFromOthers   = true
    OmniHub.trader.sellToOthers    = true
    OmniHub.trader.activelyRequest = cfg.activelyRequest and true or false
    OmniHub.trader.activelySell    = cfg.activelySell and true or false

    chosenDelivered  = OmniHub.resolveChosen(cfg.deliveredIds, candidateDelivered)
    chosenDelivering = OmniHub.resolveChosen(cfg.deliveringIds, candidateDelivering)

    OmniHub.sendHubConfigTo(Player(callingPlayer))
end
callable(OmniHub, "applyHubConfig")

-- ────────────────────────────────────────────────────────────────
-- Install / uninstall RPCs
-- ────────────────────────────────────────────────────────────────

-- Finds the player's inventory slot holding `key` (an OmniHub module). Returns slotIndex, stackAmount.
local function findModuleSlot(inventory, key)
    for slotIndex, slot in pairs(inventory:getItemsByType(InventoryItemType.VanillaItem)) do
        local item = slot.item
        if item and item:getValue("subtype") == OmniHubModuleDefs.SUBTYPE
                and item:getValue("moduleKey") == key then
            return slotIndex, (slot.amount or 1)
        end
    end
end

-- Per-key map of how many OmniHub modules the player holds in inventory.
local function inventoryCounts(inventory)
    local counts = {}
    for _, slot in pairs(inventory:getItemsByType(InventoryItemType.VanillaItem)) do
        local item = slot.item
        if item and item:getValue("subtype") == OmniHubModuleDefs.SUBTYPE then
            local k = item:getValue("moduleKey")
            counts[k] = (counts[k] or 0) + (slot.amount or 1)
        end
    end
    return counts
end

-- Remaining install capacity (math.huge when uncapped).
local function capRemaining()
    local cap = OmniHubConfig.get("moduleCap")
    if cap < 0 then return math.huge end
    local total = 0
    for _, c in pairs(installed) do total = total + c end
    return cap - total
end

-- Installs up to `qty` of `key` from the player's inventory (clamped to held + capacity); 0 -> no-op.
function OmniHub.installModule(key, qty)
    if not onServer() then return end
    if not callerIsOwner() then return end
    if not key or not OmniHubModuleDefs.get(key) then return end
    qty = math.max(1, math.floor(tonumber(qty) or 1))

    local player    = Player(callingPlayer)
    local inventory = player:getInventory()
    local slotIndex, held = findModuleSlot(inventory, key)
    if not slotIndex or held <= 0 then return end

    local room = capRemaining()
    local n = OmniHubProduction.clampInstall(qty, held, room)
    if n <= 0 then
        if room <= 0 then
            player:sendChatMessage("OmniHub"%_t, ChatMessageType.Error,
                "Module capacity reached (%1%)."%_t, OmniHubConfig.get("moduleCap"))
        end
        return
    end

    for _ = 1, n do inventory:take(slotIndex) end
    installed[key] = (installed[key] or 0) + n
    OmniHub.rebuild()
    OmniHub.sendModuleDeltaTo(player, key)
end
callable(OmniHub, "installModule")

-- Uninstalls up to `qty` of `key` (clamped to installed); returns them to the player's inventory.
function OmniHub.uninstallModule(key, qty)
    if not onServer() then return end
    if not callerIsOwner() then return end
    local have = installed[key] or 0
    if have <= 0 then return end
    qty = math.max(1, math.floor(tonumber(qty) or 1))
    local n = OmniHubProduction.clampInstall(qty, have, math.huge)

    installed[key] = have - n
    if installed[key] <= 0 then
        installed[key]          = nil
        productionProgress[key] = nil
        timeToProduce[key]      = nil
    end

    local player    = Player(callingPlayer)
    local inventory = player:getInventory()
    for _ = 1, n do inventory:addOrDrop(OmniHubModuleItem.build(key), true) end

    OmniHub.rebuild()
    OmniHub.sendModuleDeltaTo(player, key)
end
callable(OmniHub, "uninstallModule")

-- ────────────────────────────────────────────────────────────────
-- Client data sync (server side)
-- ────────────────────────────────────────────────────────────────

-- Full module sync (owner only): per-key installed + inventory counts. The client merges these with
-- the module catalog (names/icons) it already has, so we send only the numbers.
function OmniHub.sendModuleData()
    if not onServer() then return end
    if not callerIsOwner() then return end
    local player = Player(callingPlayer)
    local installedCounts = {}
    for key, count in pairs(installed) do installedCounts[key] = count end
    invokeClientFunction(player, "receiveModuleData", installedCounts, inventoryCounts(player:getInventory()))
end
callable(OmniHub, "sendModuleData")

-- Targeted delta after an install/uninstall: the one module's new installed + held counts, plus the
-- Goods rows whose rates changed (the module's recipe goods). Buy/Sell is untouched.
function OmniHub.sendModuleDeltaTo(player, key)
    local _, held = findModuleSlot(player:getInventory(), key)
    invokeClientFunction(player, "receiveModuleDelta", key, installed[key] or 0, held or 0,
        OmniHub.changedGoodRows(key))
end

-- Builds the unified Goods table: one row per good the hub produces or consumes, carrying actual/max
-- production & consumption rates (per minute), per-unit sell & buy prices, the regional market %, and
-- the current Buy/Sell marks. Sent once per window open (rates are NOT live-pushed — they refresh on
-- reopen; see docs/performance-notes.md).
function OmniHub.sendHubGoods()
    if not onServer() then return end
    OmniHub.sendHubGoodsTo(Player(callingPlayer))
end
callable(OmniHub, "sendHubGoods")

-- Builds one Goods-table row for `name` (nil if the good has no positive price). `maxR` is a
-- precomputed maxRates result. Checkbox state = the EXPLICIT mark (unticked by default; installing a
-- module never auto-enables trading). Prices come straight from goods[] (correct regardless of mark).
function OmniHub.buildGoodRow(name, maxR, sellF, buyF)
    local g = goods[name]
    if type(g) ~= "table" or not g.price or g.price <= 0 then return nil end
    local sdf, pct = OmniHub.regionalInfo(name)
    return {
        name        = name,
        icon        = g.icon or "",
        prateActual = OmniHubRates.producedPerMin(rates, name),
        prateMax    = maxR.produced[name] or 0,
        crateActual = OmniHubRates.consumedPerMin(rates, name),
        crateMax    = maxR.consumed[name] or 0,
        sellPrice   = round(g.price * sellF * sdf),
        buyPrice    = round(g.price * buyF * sdf),
        marketPct   = pct,
        sellEnabled = sellEnabled[name] == true,
        buyEnabled  = buyEnabled[name] == true,
    }
end

function OmniHub.sendHubGoodsTo(player)
    local maxR  = OmniHubProduction.maxRates(installed, OmniHubModuleDefs.resolveRecipe, timeToProduce, MIN_TIME_TO_PRODUCE)
    local sellF = OmniHub.trader.sellPriceFactor
    local buyF  = OmniHub.trader.buyPriceFactor

    -- Trading-station mode: list EVERY good so the player can opt any good into Buy/Sell.
    -- OPTIMIZE LATER (docs/performance-notes.md): regionalInfo (economyupdater) once PER GOOD (~200)
    -- per window open. Acceptable as a once-per-open cost for now; cache if it hitches.
    local list = {}
    for name in pairs(goods) do
        local row = OmniHub.buildGoodRow(name, maxR, sellF, buyF)
        if row then list[#list + 1] = row end
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    invokeClientFunction(player, "receiveHubGoods", list)
end

-- Goods rows whose rates change when a module is installed/uninstalled = the module recipe's
-- ingredients + results + garbages (deduped). Sent in the install/uninstall delta to patch the Goods
-- tab without re-sending all ~200 goods.
function OmniHub.changedGoodRows(key)
    local prod = OmniHubModuleDefs.resolveRecipe(key)
    if not prod then return {} end
    local maxR  = OmniHubProduction.maxRates(installed, OmniHubModuleDefs.resolveRecipe, timeToProduce, MIN_TIME_TO_PRODUCE)
    local sellF = OmniHub.trader.sellPriceFactor
    local buyF  = OmniHub.trader.buyPriceFactor

    local seen, rows = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            local row = OmniHub.buildGoodRow(name, maxR, sellF, buyF)
            if row then rows[#rows + 1] = row end
        end
    end
    for _, ing in pairs(prod.ingredients) do add(ing.name) end
    for _, res in pairs(prod.results) do add(res.name) end
    if prod.garbages then for _, gar in pairs(prod.garbages) do add(gar.name) end end
    return rows
end

-- ════════════════════════════════════════════════════════════════
-- CLIENT UI
-- The controller's client block only creates the tabs and wires handler names; all widget
-- construction/refresh lives in the lib/omnihub/ui/* modules.
-- ════════════════════════════════════════════════════════════════
local window       = nil
local tabbedWindow = nil
local buyTab, sellTab, goodsTab, statsTab, configTab, modulesTab

local goodsUI, statisticsUI, configUI, modulesUI

-- Buy/Sell tables are refreshed lazily: a price-slider or Goods-mark change sets this, and selecting
-- the Buy or Sell tab pulls fresh data only when set.
local goodsDirty = false

-- Cached server data (client-side)
OmniHub.lastGoods = {}

-- ── Buy/Sell pagination ──────────────────────────────────────────
-- The vanilla buy/sell GUI is a fixed 15-row pool drawn straight on the tab (no scroll), and BOTH
-- its inner update loop and its Buy/Sell buttons assume row index == good index. So we hold the full
-- good lists here and keep trader.soldGoods/boughtGoods equal to the CURRENT PAGE's slice (<=15) —
-- every vanilla mechanism (rendering, buttons that resolve a row to soldGoods[i].name) then works
-- unchanged, and large hubs paginate instead of truncating at 15.
local BUY_PER_PAGE = 15  -- must match buildGui's row count
local allSold, allBought = {}, {}
local buyPage, sellPage  = 0, 0
local buyPrevBtn, buyNextBtn, buyPageLabel
local sellPrevBtn, sellNextBtn, sellPageLabel

local function pageCount(total)
    return math.max(1, math.ceil(math.max(0, total) / BUY_PER_PAGE))
end

-- Returns the goods on `page` plus the clamped page index, delegating the (tested) clamp + 1-based
-- bounds to OmniHubSupplierStock.pageSlice.
local function pageSlice(list, page)
    local s, e, clamped = OmniHubSupplierStock.pageSlice(#list, BUY_PER_PAGE, page)
    local out = {}
    if s > 0 then
        for i = s, e do out[#out + 1] = list[i] end
    end
    return out, clamped
end

-- Adds a prev/page-label/next row at the bottom of a buy/sell tab, below the 15 rows.
local function buildPager(tab, prevCb, nextCb)
    local y    = 560
    local prev = tab:createButton(Rect(vec2(10, y),  vec2(70, y + 26)),  "<", prevCb)
    local lbl  = tab:createLabel(Rect(vec2(80, y),   vec2(770, y + 26)), "", 14)
    local nxt  = tab:createButton(Rect(vec2(790, y), vec2(860, y + 26)), ">", nextCb)
    lbl:setCenterAligned()
    prev.uppercase = false
    nxt.uppercase  = false
    return prev, nxt, lbl
end

function OmniHub.initUI()
    local res  = getResolution()
    local size = vec2(950, 650)

    local menu = ScriptUI()
    window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    window.caption         = "OmniHub"%_t
    window.showCloseButton = 1
    window.moveable        = 1
    menu:registerWindow(window, "OmniHub"%_t)

    -- TradingManager's receiveGoods only repaints the buy/sell rows when PublicNamespace.window is
    -- visible. We build our OWN window instead of TradingAPI.CreateTabbedWindow, so point that field
    -- at our window or the buy/sell tables would never populate. (TradingAPI IS the PublicNamespace.)
    TradingAPI.window = window

    tabbedWindow = window:createTabbedWindow(Rect(vec2(10, 10), size - 10))

    -- 1 & 2: vanilla buy/sell tables (reused from TradingManager) + a pager for >15 goods.
    buyTab = tabbedWindow:createTab("Buy"%_t, "data/textures/icons/bag.png", "Buy from the hub"%_t)
    OmniHub.buildBuyGui(buyTab)
    buyPrevBtn, buyNextBtn, buyPageLabel = buildPager(buyTab, "onBuyPrevPage", "onBuyNextPage")
    sellTab = tabbedWindow:createTab("Sell"%_t, "data/textures/icons/sell.png", "Sell to the hub"%_t)
    OmniHub.buildSellGui(sellTab)
    sellPrevBtn, sellNextBtn, sellPageLabel = buildPager(sellTab, "onSellPrevPage", "onSellNextPage")

    -- Refresh the Buy/Sell tables lazily: a price-slider or mark change marks them dirty; selecting
    -- either tab pulls fresh data (requestGoods) only if dirty.
    buyTab.onSelectedFunction  = "onTradeTabSelected"
    sellTab.onSelectedFunction = "onTradeTabSelected"

    -- Mark the trader GUI as built, or updateBought/SoldGoodGui early-return and the rows stay blank
    -- (factory.lua:563 does the same after building its buy/sell tabs).
    OmniHub.trader.guiInitialized = true

    -- 3: Goods (unified table — production/consumption rates, prices, market, Buy/Sell marks).
    goodsTab = tabbedWindow:createTab("Goods"%_t, "data/textures/icons/production.png", "Goods"%_t)
    goodsUI = OmniHubGoodsTable.new(goodsTab, size, {
        nameHeader   = "Name"%_t,
        nameTip      = "A good your installed modules produce and/or consume."%_t,
        prateHeader  = "PRate"%_t,
        prateTip     = "Production rate, units per minute: actual (measured over the last ~60s) / max (theoretical at full utilisation). \"-\" = not produced here.\n\nGreen = at capacity, amber = below, orange = idle/starved."%_t,
        crateHeader  = "CRate"%_t,
        crateTip     = "Consumption rate, units per minute: actual (last ~60s) / max (full utilisation). \"-\" = not consumed here.\n\nGreen = at capacity, amber = below, orange = idle/starved."%_t,
        spHeader     = "SP"%_t,
        spTip        = "Sell price per unit = base price x your sell modifier x regional market. The price this hub sells one unit for."%_t,
        bpHeader     = "BP"%_t,
        bpTip        = "Buy price per unit = base price x your buy modifier x regional market. The price this hub pays to buy one unit."%_t,
        marketHeader = "Mar"%_t,
        marketTip    = "Regional supply/demand price change. Blue (+%) = high demand, raising both buy and sell prices here; green (-%) = high supply, lowering them. Informational; it does not change how many traders visit."%_t,
        buyHeader    = "Buy"%_t,
        buyTip       = "Whether this good is bought from others (appears in the Sell tab)."%_t,
        sellHeader   = "Sell"%_t,
        sellTip      = "Whether this good is offered for sale (appears in the Buy tab)."%_t,
        buyTooltip   = "When checked, this good is bought from traders and players. Unchecking only stops external purchases — internal consumption is unaffected."%_t,
        sellTooltip  = "When checked, this good is sold to traders and players. Unchecking only stops external sales — internal production is unaffected."%_t,
        sellCallback = "onGoodsSellChanged", buyCallback = "onGoodsBuyChanged",
        prevCallback = "onGoodsPrevPage",    nextCallback = "onGoodsNextPage",
    })

    -- 5: Statistics.
    statsTab = tabbedWindow:createTab("Statistics"%_t, "data/textures/icons/chart.png", "Profit and recent trades"%_t)
    statisticsUI = OmniHubUIStatistics.new(statsTab, size)

    -- 6: Configuration.
    configTab = tabbedWindow:createTab("Configure"%_t, "data/textures/icons/cog.png", "Trade configuration"%_t)
    configUI = OmniHubUIConfig.new(configTab, size, {
        changeCallback     = "onConfigChanged",
        priceMovedCallback = "onPriceSliderMoved",
        priceCommitCallback = "onPriceSliderCommit",
    })

    -- 7: Modules.
    modulesTab = tabbedWindow:createTab("Modules"%_t, "data/textures/icons/gears.png", "Install and uninstall modules"%_t)
    modulesUI = OmniHubUIModules.new(modulesTab, size, {
        filterCallback    = "onModuleFilterChanged",
        installCallback   = "onModuleInstall",
        uninstallCallback = "onModuleUninstall",
        qtyCallback       = "onModuleQty",
        prevCallback      = "onModulesPrevPage",
        nextCallback      = "onModulesNextPage",
    })
end

-- Activates/deactivates the Buy & Sell tabs based on whether the hub has anything to trade and
-- whether the window was opened from the station's own ship. Re-runnable: called from onShowWindow
-- AND from receiveGoods, because the trader's soldGoods/boughtGoods arrive asynchronously and the
-- window may already be open when they do. (getSoldGoods/getBoughtGoods return unpacked NAMES, so we
-- count via the trader's arrays like vanilla.)
function OmniHub.updateTradeTabs()
    if not tabbedWindow then return end
    local fromShip = (Player().craftIndex == Entity().index)

    -- Gate on the FULL good counts (trader.soldGoods/boughtGoods hold only the current page slice).
    if buyTab then
        if (#allSold == 0) or fromShip then tabbedWindow:deactivateTab(buyTab)
        else tabbedWindow:activateTab(buyTab) end
    end
    if sellTab then
        if (#allBought == 0) or fromShip then tabbedWindow:deactivateTab(sellTab)
        else tabbedWindow:activateTab(sellTab) end
    end
end

-- Repaints every buy/sell row from the current good lists: updates the rows backed by a good and
-- HIDES the rest. Vanilla's refreshUI only ever shows/updates rows for present goods and never hides
-- stragglers (factory good lists are static); OmniHub's lists shrink when goods are marked off /
-- modules removed, leaving stale "duplicate" rows. Driven via the per-good update calls, which gate
-- only on guiInitialized (not window.visible), so a live sendGoods push repaints immediately too.
function OmniHub.repaintTradeLines()
    local t = OmniHub.trader
    if not t.guiInitialized then return end

    -- Price the goods from the player's (or their alliance's) perspective, like refreshUI does.
    local player = Player()
    local craft  = player.craft
    if craft and craft.factionIndex == player.allianceIndex then player = player.alliance end
    local pIndex = player.index

    if t.soldLines then
        for i = 1, #t.soldLines do
            local good = t.soldGoods[i]
            if good then t:updateSoldGoodGui(i, good, t:getSellPrice(good.name, pIndex))
            else t.soldLines[i]:hide() end
        end
    end
    if t.boughtLines then
        for i = 1, #t.boughtLines do
            local good = t.boughtGoods[i]
            if good then t:updateBoughtGoodGui(i, good, t:getBuyPrice(good.name, pIndex))
            else t.boughtLines[i]:hide() end
        end
    end
end

-- Re-slices trader.soldGoods/boughtGoods to the current page (clamped), repaints the rows, and
-- refreshes the pager labels/buttons. Called after a goods sync and on every page change.
function OmniHub.applyPageSlices()
    local t = OmniHub.trader
    local soldSlice,   newBuy  = pageSlice(allSold,   buyPage)
    local boughtSlice, newSell = pageSlice(allBought, sellPage)
    buyPage, sellPage   = newBuy, newSell        -- pageSlice clamped them to valid ranges
    t.soldGoods         = soldSlice
    t.boughtGoods       = boughtSlice
    t.numSold           = #soldSlice
    t.numBought         = #boughtSlice
    OmniHub.repaintTradeLines()
    OmniHub.refreshPagers()
end

function OmniHub.refreshPagers()
    local function set(prev, nxt, label, page, total)
        if not label then return end
        local pages = pageCount(total)
        label.caption = (total == 0) and "" or string.format("Page %d / %d (%d goods)", page + 1, pages, total)
        if prev then prev.active = page > 0 end
        if nxt then nxt.active = page < pages - 1 end
    end
    set(buyPrevBtn,  buyNextBtn,  buyPageLabel,  buyPage,  #allSold)
    set(sellPrevBtn, sellNextBtn, sellPageLabel, sellPage, #allBought)
end

-- Wrap the inherited receiveGoods: let base store/sort the FULL lists + price factors, but SUPPRESS
-- its refreshUI (it iterates the full list and would index past the 15-row pool — crash — for >15
-- goods). We then capture the full lists and repaint only the current page.
function OmniHub.receiveGoods(...)
    local w = TradingAPI.window
    TradingAPI.window = nil
    if base_receiveGoods then base_receiveGoods(...) end
    TradingAPI.window = w

    local t = OmniHub.trader
    allSold   = t.soldGoods   or {}
    allBought = t.boughtGoods or {}
    OmniHub.applyPageSlices()
    OmniHub.updateTradeTabs()
end

function OmniHub.onBuyPrevPage()  buyPage  = buyPage  - 1; OmniHub.applyPageSlices() end
function OmniHub.onBuyNextPage()  buyPage  = buyPage  + 1; OmniHub.applyPageSlices() end
function OmniHub.onSellPrevPage() sellPage = sellPage - 1; OmniHub.applyPageSlices() end
function OmniHub.onSellNextPage() sellPage = sellPage + 1; OmniHub.applyPageSlices() end

function OmniHub.onShowWindow()
    local station = Entity()
    local player  = Player()
    local faction = Faction()

    local isOwner  = (player.index == faction.index)
                  or (player.allianceIndex and player.allianceIndex == faction.index) or false

    OmniHub.updateTradeTabs()

    -- Mutating tabs are owner-only.
    for _, t in ipairs({goodsTab, configTab, modulesTab}) do
        if isOwner then tabbedWindow:activateTab(t) else tabbedWindow:deactivateTab(t) end
    end
    -- Statistics is visible to everyone.

    OmniHub.requestGoods()  -- inherited: refreshes the buy/sell tables (re-gates via receiveGoods)
    goodsDirty = false      -- just synced
    invokeServerFunction("sendHubGoods")
    invokeServerFunction("sendStats")
    if isOwner then
        invokeServerFunction("sendModuleData")
        invokeServerFunction("sendHubConfig")
    end
end

function OmniHub.onCloseWindow()
end

-- ── Client RPC handlers ──────────────────────────────────────────
-- Full module sync: per-key installed + inventory counts (the UI merges them with the catalog).
function OmniHub.receiveModuleData(installedCounts, inventoryCounts)
    if modulesUI then modulesUI:setCounts(installedCounts or {}, inventoryCounts or {}) end
end

-- Targeted delta after install/uninstall: patch the one module row + the changed Goods rows. Buy/Sell
-- is untouched (marks are explicit), and the module row set is stable, so nothing rebuilds.
function OmniHub.receiveModuleDelta(key, installed, inventory, changedGoods)
    if modulesUI then modulesUI:patch(key, installed or 0, inventory or 0) end
    if goodsUI then goodsUI:patch(changedGoods) end
end

function OmniHub.receiveHubGoods(list)
    OmniHub.lastGoods = list or {}
    if goodsUI then goodsUI:setData(OmniHub.lastGoods) end
end

function OmniHub.receiveStats(lifetime, lastHour, txns)
    if statisticsUI then statisticsUI:set(lifetime, lastHour, txns) end
end

function OmniHub.receiveHubConfig(cfg, dErrors, fErrors)
    if not configUI then return end
    configUI:setOptions(cfg.deliveredOptions, cfg.deliveringOptions)
    configUI:apply(cfg)
    configUI:setErrors(dErrors, fErrors)
end

-- ── Client event handlers (engine resolves these by name) ────────
-- Toggling Sell changes soldGoods (the Buy tab); toggling Buy changes boughtGoods (the Sell tab). We
-- update the cached Goods-table state optimistically (so paging is stable) and let setGoodSell/Buy
-- re-sync the affected vanilla buy/sell list. The Goods table itself is NOT re-sent (rates refresh on
-- reopen only — see docs/performance-notes.md).
function OmniHub.onGoodsSellChanged(checkbox)
    local name = goodsUI and goodsUI:goodForSell(checkbox)
    if name then
        goodsUI:setEnabled(name, "sell", checkbox.checked)
        invokeServerFunction("setGoodSell", name, checkbox.checked)
        goodsDirty = true   -- Buy tab (soldGoods) now stale; refreshes on tab select
    end
end

function OmniHub.onGoodsBuyChanged(checkbox)
    local name = goodsUI and goodsUI:goodForBuy(checkbox)
    if name then
        goodsUI:setEnabled(name, "buy", checkbox.checked)
        invokeServerFunction("setGoodBuy", name, checkbox.checked)
        goodsDirty = true   -- Sell tab (boughtGoods) now stale; refreshes on tab select
    end
end

function OmniHub.onGoodsPrevPage() if goodsUI then goodsUI:prevPage() end end
function OmniHub.onGoodsNextPage() if goodsUI then goodsUI:nextPage() end end

-- Price sliders: live % label while dragging; on release, predict the Goods prices client-side,
-- send the (fire-and-forget) factor RPC, and mark the Buy/Sell tabs dirty.
function OmniHub.onPriceSliderMoved()
    if configUI then configUI:refreshPriceLabels() end
end

function OmniHub.onPriceSliderCommit()
    if not configUI then return end
    local buyF, sellF = configUI:readPrices()
    if goodsUI then goodsUI:setPriceFactors(sellF, buyF) end   -- client-side price prediction
    invokeServerFunction("setPriceFactors", buyF, sellF)
    goodsDirty = true
end

-- Selecting the Buy or Sell tab pulls fresh data only if something changed since the last sync.
function OmniHub.onTradeTabSelected()
    if goodsDirty then
        OmniHub.requestGoods()  -- receiveGoods re-slices + repaints both tables
        goodsDirty = false
    end
end

function OmniHub.onConfigChanged()
    if configUI then invokeServerFunction("applyHubConfig", configUI:read()) end
end

-- Modules tab: Install/Uninstall send (key, qty) from the row's shared quantity field; the server
-- clamps to what's actually available and replies with a delta we patch in. Filter + paging are
-- client-side.
function OmniHub.onModuleInstall(button)
    if not modulesUI then return end
    local key, qty = modulesUI:installTarget(button)
    if key then invokeServerFunction("installModule", key, qty) end
end

function OmniHub.onModuleUninstall(button)
    if not modulesUI then return end
    local key, qty = modulesUI:uninstallTarget(button)
    if key then invokeServerFunction("uninstallModule", key, qty) end
end

function OmniHub.onModuleFilterChanged(checkbox)
    if modulesUI then modulesUI:setFilter(checkbox.checked) end
end

function OmniHub.onModuleQty(textBox) end  -- no-op; qty is read on button press

function OmniHub.onModulesPrevPage() if modulesUI then modulesUI:prevPage() end end
function OmniHub.onModulesNextPage() if modulesUI then modulesUI:nextPage() end end

return OmniHub
