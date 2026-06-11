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
local OmniHubTradingDecision = include("tradingdecision")
local OmniHubLog = include("log")
local OmniHubStats = include("stats")
local OmniHubRates = include("rates")
local OmniHubEvents = include("events")
local OmniHubMaxLimit = include("maxlimit")
local OmniHubStorage = include("storage")
local OmniHubSupplierStock = include("supplierstock")  -- pure pageSlice (clamp/bounds) for buy/sell paging
local Dialog = include("dialogutility")

-- Server-only libraries (FactoryMap drives supply-demand types; TraderFleet spawns/counts the
-- wave's NPC traders). Both touch Sector()/Entity(), so they are only included in the server VM.
local FactoryMap, OmniHubTraderFleet
if onServer() then
    FactoryMap         = include("factorymap")
    OmniHubTraderFleet = include("traderfleet")
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
local MIN_TIME_TO_PRODUCE = 15.0  -- seconds, matches factory.lua
local PRICE_MIN, PRICE_MAX = 0.8, 1.2  -- ±20% base-price slider range

-- Goods the hub may list/trade: only goods that are part of a production chain (any production's
-- ingredients/results/garbages — `productions` is the ambient productionsindex array). Keeps every
-- factory good incl. dangerous ones (Toxic Waste) and "Scrap Metal"; drops ores, rift ores/loot,
-- salvage scrap (Scrap Iron..Avorion) and illegal goods. Gates the Goods rows (buildGoodRow), the
-- mark RPCs, and restore-time mark pruning.
local tradeableGoods = OmniHubTrading.buildTradeableSet(productions)

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

-- A3 observation: consecutive requestTraders windows blocked by hasTraders. Transient, not
-- persisted. A count that climbs without ever resetting implicates an orphaned tradeship (its
-- trade_partner still set to us) wedging the request path — the suspected A3 failure mode.
local hasTradersBlocks = 0

-- Offline-director sync state (transient). needDirectorSync is raised in initialize so the FIRST
-- update tick after a (re)load wakes/reconciles with the director and sends an immediate
-- heartbeat — covering both fresh foundings (registration gap) and sector loads (offline result
-- write-back), after restore() has rebuilt installed/marks/limits.
local needDirectorSync      = false
local directorHeartbeatClock = 0

-- Aggregated production table: single merged recipe across all installed factory modules,
-- with ingredient/result/garbage amounts summed and scaled by module count.
-- Mirrors factory.lua's file-local `production` variable so requestTraders can iterate it directly.
-- nil when no factory modules are installed.
local aggregatedProduction = nil

-- Per-good max-limit cache (UNITS), recomputed only on module/config change via
-- OmniHub.recomputeMaxLimits (see lib/omnihub/maxlimit.lua) — never per tick. Reassigned
-- wholesale on recompute; the trader.getMaxStock closure below reads it through the upvalue, so the
-- reassignment is visible there.
local maxLimitByGood = {}
local recommendedCapacity = 0  -- assembly needed for max speed; recomputed in rebuild()

-- Per-hub reservation tuning, persisted via secure/restore and edited in the Configure tab.
-- buyLimit = flat reserve for buy-marked passthrough goods; produced/consumed goods reserve
-- prodBase * prodCycles * perCycleAmount. See maxlimit.lua for the role resolution.
local MAXLIMIT_DEFAULTS = { buyLimit = 1000, prodBase = 200, prodCycles = 1 }
-- Upper clamp bounds for the owner-set values above (applyHubConfig); guard against a tampered
-- client, far above any legitimate setting.
local MAXLIMIT_UNITS_CAP  = 1000000
local MAXLIMIT_CYCLES_CAP = 10000
local hubMaxLimit = { buyLimit = MAXLIMIT_DEFAULTS.buyLimit,
                     prodBase       = MAXLIMIT_DEFAULTS.prodBase,
                     prodCycles     = MAXLIMIT_DEFAULTS.prodCycles }

-- Reservation-based max stock for EVERY trade path: auto-buy caps, getInitialGoods, the
-- player->station sell cap, and production's result gate (via the OmniHub.getMaxStock wrapper). Mirrors
-- vanilla factory.lua:99, which likewise overrides trader.getMaxStock. We override the TRADER method
-- (not just the OmniHub.getMaxStock namespace wrapper) so tradingmanager's internal self:getMaxStock
-- calls also honor it. Goods the hub doesn't acquire reserve 0. Manual cargo transfers into the hub
-- bypass this entirely (they aren't trades), so owners can still overstock looted goods.
OmniHub.trader.getMaxStock = function(self, good)
    return maxLimitByGood[good.name] or 0
end

-- ── Server-authoritative stock display ──────────────────────────
-- The engine gives clients a correct CARGO SNAPSHOT on sector/save load but does NOT stream live
-- cargo changes for a station, so a client's getCargoAmount drifts behind the server while
-- production and NPC trades run (observed: server 564, client UI/manage-tab 452). The buy/sell
-- stock column must therefore come from the SERVER: a full per-good stock map rides along with
-- every goods pull (receiveStockSync), and a deduplicated (name, amount) delta is broadcast
-- whenever a trade-listed good's stock actually changes.
local serverStock   = {}  -- client: name -> server-sent amount (display cache)
local lastSentStock = {}  -- server: name -> last broadcast amount (dedup, saves bandwidth)

if onServer() then
    -- Wrap the TRADER methods (not the namespace wrappers) so tradingmanager's internal
    -- self:increaseGoods/decreaseGoods calls — production, buyFromShip/sellToShip, buyGoods/
    -- sellGoods — all emit the delta.
    local base_traderIncrease = OmniHub.trader.increaseGoods
    local base_traderDecrease = OmniHub.trader.decreaseGoods

    local function broadcastStockDelta(trader, name)
        local amount = trader:getNumGoods(name)
        if lastSentStock[name] == amount then return end
        lastSentStock[name] = amount
        broadcastInvokeClientFunction("receiveStockDelta", name, amount)
    end

    OmniHub.trader.increaseGoods = function(self, name, delta)
        base_traderIncrease(self, name, delta)
        broadcastStockDelta(self, name)
    end
    OmniHub.trader.decreaseGoods = function(self, name, amount)
        local removed = base_traderDecrease(self, name, amount)
        broadcastStockDelta(self, name)
        return removed
    end
else
    -- Client: every stock read the trade UI makes (row captions, buy/sell amount clamps, vanilla's
    -- updateSoldGoodAmount repaints) goes through trader:getNumGoods — serve it from the
    -- server-sent cache, falling back to (possibly stale) replicated cargo until the first sync.
    local base_traderGetNumGoods = OmniHub.trader.getNumGoods
    OmniHub.trader.getNumGoods = function(self, name)
        local cached = serverStock[name]
        if cached ~= nil then return cached end
        return base_traderGetNumGoods(self, name)
    end
end

-- Dev-only production debug. hubDebug is the owner-set toggle (persisted; only togglable from the
-- dev-mode-gated Configure checkbox); productionStatus[key] remembers each idle module's last
-- canStartCycle decision so the throttled logger can explain stalls without recomputing. The logger
-- is additionally gated on GameSettings().devMode, so a persisted flag never logs on a live server.
local hubDebug = false

-- Identity tag for every hub log line: "<title> (#<index>)". Passed as a %s ARGUMENT (never
-- concatenated into the format string) so a station title containing '%' can't break string.format.
local function hubTag()
    local entity = Entity()
    return string.format("%s (#%s)",
        tostring(entity.title ~= "" and entity.title or "OmniHub"), tostring(entity.index))
end

-- Gated, hub-identified debug line: "[OmniHub] <title> (#<index>) <message>". The single funnel for
-- ALL of this hub's debug output (production dump, requestTraders, A3 counter) so multi-hub server
-- logs share one prefix and stay greppable per station. Gated on the owner toggle AND devMode
-- (same rationale as above: a persisted flag must never spam a live server).
local function hubLog(fmt, ...)
    if not hubDebug then return end
    if not GameSettings().devMode then return end
    OmniHubLog.debug(true, "%s " .. fmt, hubTag(), ...)
end

-- UNGATED hub-identified line, same format as hubLog, for anomalies that must reach a live server's
-- log even with debug off (security rejections, validation failures). Not for routine flow.
local function hubWarn(fmt, ...)
    OmniHubLog.debug(true, "%s " .. fmt, hubTag(), ...)
end

-- ── Owner event notifications ────────────────────────────────────
-- All batching/latching/formatting is pure (lib/omnihub/events.lua); this is the single emission
-- funnel. eventsEnabled is the per-hub owner toggle (Config tab, persisted). The hub id is
-- appended only in dev mode — players don't need internal ids (the text carries name + sector +
-- coords).
local hubEvents     = OmniHubEvents.new()
local eventsEnabled = true

local function emitEvent(payload)
    if not eventsEnabled or not payload then return end
    local entity  = Entity()
    local faction = Faction(entity.factionIndex)
    if not faction then return end
    local x, y     = Sector():getCoordinates()
    local hubName  = (entity.name ~= nil and entity.name ~= "") and entity.name
                     or (entity.title ~= "" and entity.title or "OmniHub")
    local id       = GameSettings().devMode and string.format(" #%s", tostring(entity.index)) or ""
    -- ALL events go out as Economy with an empty sender — the vanilla economy-notification shape
    -- (supplycommand.lua:419). Economy lands in the chat's Economy tab with NO alert sound;
    -- Warning/Information ring the same chime as combat alerts, far too alarming for trade and
    -- production status. payload.severity stays in the contract (the texts and any future
    -- channel re-split use it) but deliberately does not pick the message type.
    faction:sendChatMessage("", ChatMessageType.Economy, string.format("%s [%s (%d:%d)]%s: %s",
        tostring(hubName), Sector().name, x, y, id, payload.text))
end

local productionStatus = {}      -- { [moduleKey] = last canStartCycle decision } (transient)
local DEBUG_LOG_INTERVAL = 10    -- seconds between production debug dumps

OmniHub.productionCapacity = 100  -- updated by onBlockPlanChanged
OmniHub.traderCooldown     = 0    -- countdown timer; decremented in update()

-- ────────────────────────────────────────────────────────────────
-- Cache TradingAPI base methods BEFORE we override
-- ────────────────────────────────────────────────────────────────
local base_secure   = OmniHub.secure
local base_restore  = OmniHub.restore
local base_buyGoods  = OmniHub.buyGoods
local base_sellGoods = OmniHub.sellGoods
local base_buyFromShip = OmniHub.buyFromShip
local base_sellToShip  = OmniHub.sellToShip
local base_receiveGoods = OmniHub.receiveGoods
local base_sendGoods    = OmniHub.sendGoods

-- ────────────────────────────────────────────────────────────────
-- Small helpers
-- ────────────────────────────────────────────────────────────────
-- Clamp v into [lo, hi] (nil v -> lo). Used to sanitize reservation values from the Configure tab.
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v or lo)) end

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
        -- Fresh station defaults: trade with others and actively keep goods flowing out of the box.
        -- A loaded station overwrites these from saved tradingData in restore().
        OmniHub.trader.buyFromOthers   = true
        OmniHub.trader.sellToOthers    = true
        OmniHub.trader.activelyRequest = true
        OmniHub.trader.activelySell    = true

        entity:registerCallback("onBlockPlanChanged", "onBlockPlanChanged")
        entity:registerCallback("onDestroyed", "onDestroyed")

        -- Docked trades (NPC tradeships delivering/fetching, and players trading at the UI) route
        -- through tradingmanager's buyFromShip/sellToShip — NOT the buyGoods/sellGoods we wrap for
        -- statistics — and announce themselves only via these entity callbacks. Without them, online
        -- NPC auto-trade works but profit/transactions stay at 0.
        entity:registerCallback("onTradingManagerBuyFromPlayer", "onDockedTradeBought")
        entity:registerCallback("onTradingManagerSellToPlayer", "onDockedTradeSold")

        -- Attach the dev-only "OmniHub Tests" interaction script (option shown in dev mode only,
        -- gated in omnihubtests.lua:interactionPossible). The controller is the ONLY attach point:
        -- do NOT also list it in the stationfounder template — this initialize (and its
        -- addScriptOnce) runs inside the founder's addScript loop BEFORE the founder reaches the
        -- tests entry, so addScriptOnce can't dedupe against it and the script attaches twice.
        entity:addScriptOnce("data/scripts/entity/merchants/omnihubtests.lua")

        -- Ensure the sector's ambient trader spawner is running (vanilla factories do the same in
        -- their initialize). Discovery itself is handled by our lib overlay of tradingutility.lua,
        -- which patches the tradeable-script allow-list in EVERY VM that includes it — a runtime
        -- insert here would only patch this VM's copy and stay invisible to sector/traders.lua.
        Sector():addScriptOnce("sector/traders.lua")

        -- Offline simulation host: one director galaxy-wide (addScriptOnce dedupes), and a sync
        -- with it on our first update tick (wake + reconcile + immediate heartbeat).
        Galaxy():addScriptOnce("data/scripts/galaxy/omnihubdirector.lua")
        needDirectorSync = true

        OmniHub.productionCapacity = Plan():getStats().productionCapacity
    end
end

function OmniHub.onBlockPlanChanged(delta)
    OmniHub.productionCapacity = Plan():getStats().productionCapacity
    for key in pairs(installed) do
        timeToProduce[key] = OmniHub.computeTimeToProduce(key)
    end
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
    OmniHubEvents.checkAssembly(hubEvents, OmniHub.productionCapacity, recommendedCapacity)
end

-- ────────────────────────────────────────────────────────────────
-- Loot drops on destruction
-- ────────────────────────────────────────────────────────────────

-- Signature is onDestroyed(index, lastDamageInflictor) per the engine (Entity Callbacks doc).
function OmniHub.onDestroyed(index, lastDamageInflictor)
    if not onServer() then return end

    -- Drop the offline-director registry entry — a destroyed hub must never be simulated again.
    Galaxy():invokeFunction("data/scripts/galaxy/omnihubdirector.lua", "remove", Entity().id.string)

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
    data.maxLimit           = hubMaxLimit
    data.debug              = hubDebug
    data.events        = eventsEnabled
    data.eventLatches  = OmniHubEvents.secure(hubEvents)
    data.tradingData        = OmniHub.secureTradingGoods()
    return data
end

function OmniHub.restore(data)
    if base_restore then base_restore(data) end
    installed              = data.installed          or {}
    productionProgress     = data.productionProgress or {}
    OmniHub.traderCooldown = data.traderCooldown     or 0
    -- Prune marks for goods outside the production-chain set (e.g. an ore marked before the
    -- tradeableGoods filter existed): a stale mark would otherwise keep trading the good
    -- invisibly via buildTradeLists, with no UI row left to untick it.
    sellEnabled            = OmniHubTrading.pruneMarks(data.sellEnabled, tradeableGoods)
    buyEnabled             = OmniHubTrading.pruneMarks(data.buyEnabled, tradeableGoods)
    stats                  = data.stats              or OmniHubStats.new()
    -- data.maxLimit is the current key; data.reserve (with legacy field names) is read for hubs saved
    -- before the rename so existing playtest stations keep their configured limits.
    local lim = data.maxLimit or {}
    local old = data.reserve or {}
    hubMaxLimit = {
        buyLimit   = lim.buyLimit   or old.tradeReserve or MAXLIMIT_DEFAULTS.buyLimit,
        prodBase   = lim.prodBase   or old.pcBase       or MAXLIMIT_DEFAULTS.prodBase,
        prodCycles = lim.prodCycles or old.pcCycles     or MAXLIMIT_DEFAULTS.prodCycles,
    }
    hubDebug = data.debug or false
    eventsEnabled = data.events ~= false   -- default ON for hubs saved before this feature
    OmniHubEvents.restore(hubEvents, data.eventLatches)
    if data.tradingData then OmniHub.restoreTradingGoods(data.tradingData) end
    -- Server builds the authoritative max-limit cache and pushes it to clients (sendGoods override);
    -- the client never has the inputs (installed/marks/hubMaxLimit arrive via RPC, not restore), so it
    -- relies on receiveStockSync instead of recomputing locally.
    if onServer() then OmniHub.rebuild() end
end

-- ────────────────────────────────────────────────────────────────
-- Update loop (production + trader spawning + stats)
-- ────────────────────────────────────────────────────────────────
function OmniHub.getUpdateInterval()
    -- numPlayers is a server-only Sector property; reading it on the client
    -- yields nil ("not readable") and crashes every tick. Gate the read.
    if onServer() and Sector().numPlayers > 0 then return 1 end
    -- Client: tick fast while our window is open so config fields commit promptly on focus-out.
    if OmniHub.windowOpen then return 0.1 end
    return 5
end

function OmniHub.update(timeStep)
    if not onServer() then return end
    OmniHub.runProductionCycles(timeStep)
    OmniHub.requestTraders(timeStep)
    OmniHub.directorTick(timeStep)
    OmniHub.advanceStats(timeStep)
    OmniHubRates.advance(rates, timeStep)
    OmniHub.eventsTick(timeStep)
    OmniHub.debugTick(timeStep)
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
        OmniHubEvents.recordStallState(hubEvents, key, nil, false)
        local advance = timeStep / ttm
        if progress.boosted then advance = advance * 2 end
        -- Smooth rate accrual: record exactly the progress made this tick (clamped at the cycle end
        -- so fractions sum to 1.0 per cycle). Cargo still moves in lumps — ingredients at start,
        -- results at completion — only the RATE measurement smooths, which removes the C>L window
        -- aliasing the old lump-at-completion recording produced.
        OmniHubRates.recordCycle(rates, prod, count, math.min(advance, 1.0 - progress.progress))
        progress.progress = progress.progress + advance

        if progress.progress >= 1.0 then
            for _, res in pairs(prod.results) do
                OmniHub.increaseGoods(res.name, res.amount * count)
            end
            if prod.garbages then
                for _, gar in pairs(prod.garbages) do
                    OmniHub.increaseGoods(gar.name, gar.amount * count)
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
        -- Read size from the goods index, NOT OmniHub.getGoodSize: the latter (TradingManager) prints
        -- "X is neither bought nor sold" every tick for any produced/ingredient/garbage good that isn't
        -- in the trade lists, spamming the server log. goods[name].size is defined for every good.
        getGoodSize    = function(name) local g = goods[name]; return g and g.size or 1 end,
        getMaxStock    = function(name, size) return OmniHub.getMaxStock({name = name, size = size}) end,
        freeCargoSpace = entity.freeCargoSpace,
    }

    local decision = OmniHubProduction.canStartCycle(prod, count, query)
    productionStatus[key] = decision  -- remembered for the debug logger (reason it could/couldn't start)
    -- The display name is only read when a stall entry is created — skip the lookup otherwise.
    local stalled = not decision.canProduce
    OmniHubEvents.recordStallState(hubEvents, key,
        stalled and OmniHubModuleDefs.displayName(key) or nil,
        stalled, decision.reason, decision.good)
    if not decision.canProduce then return end

    -- Ingredients leave cargo up-front (vanilla behavior); their RATE is accrued smoothly over the
    -- cycle by recordCycle above, not lumped here.
    for _, ing in pairs(prod.ingredients) do
        OmniHub.decreaseGoods(ing.name, ing.amount * count)
    end

    productionProgress[key] = {progress = 0, boosted = decision.boosted}
end

-- Dev-mode production debug: throttled dump of each installed module's state — ACTIVE (mid-cycle, with
-- progress%) or STALLED (idle, with the reason from its last canStartCycle). Gated on the owner toggle
-- AND GameSettings().devMode (hubLog re-checks both, but the early returns here skip building the
-- dump strings at all), and rate-limited to one dump per DEBUG_LOG_INTERVAL seconds. Every line goes
-- through hubLog, so it shares the one "[OmniHub] <title> (#<index>)" format with all other debug output.
function OmniHub.debugTick(timeStep)
    if not onServer() then return end
    if not hubDebug then return end
    if not GameSettings().devMode then return end

    OmniHub.debugClock = (OmniHub.debugClock or 0) + timeStep
    if OmniHub.debugClock < DEBUG_LOG_INTERVAL then return end
    OmniHub.debugClock = 0

    hubLog("production:")

    if not next(installed) then
        hubLog("  (no modules installed)")
    end
    for key, count in pairs(installed) do
        local label    = OmniHubModuleDefs.displayName(key)
        local progress = productionProgress[key]
        if progress then
            hubLog("  ACTIVE  %s x%d  %d%%%s",
                tostring(label), count, math.floor((progress.progress or 0) * 100),
                progress.boosted and " (boosted)" or "")
        else
            hubLog("  STALLED %s x%d  %s",
                tostring(label), count, OmniHubProduction.describeStall(productionStatus[key]))
        end
    end

    -- Reservation caps (the SERVER's authoritative getMaxStock). A buy-marked good's cap is what gates
    -- how much the hub will buy (buyable = cap - stock); this is the number the client tries to show as
    -- "stock / cap". Lets you confirm a buy-marked good (e.g. Beer) really has cap = "Buy goods reserve"
    -- server-side, independent of any client display glitch.
    local anyRes = false
    for name, cap in pairs(maxLimitByGood) do
        if cap and cap > 0 then
            if not anyRes then
                hubLog("  max limits (stock / cap):"); anyRes = true
            end
            hubLog("    %s  %d / %d", tostring(name), OmniHub.getNumGoods(name), cap)
        end
    end
    if not anyRes then hubLog("  max limits: none (no produced/consumed/buy-marked goods)") end
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

    -- Reservation cache: produced/consumed goods (from agg) + EXPLICITLY traded goods (buy or
    -- sell marks — sell-only passthrough goods need a cap too or they render 0/0 and fail the
    -- getMaxGoods trade gate). Reuses the agg/lists already built here.
    maxLimitByGood = OmniHubMaxLimit.compute(agg, lists.boughtNames, hubMaxLimit, lists.soldNames)

    local nCaps = 0
    for _, cap in pairs(maxLimitByGood) do if cap > 0 then nCaps = nCaps + 1 end end
    hubLog("rebuild: %d sold / %d bought mark(s) -> %d positive cap(s)",
        #lists.soldNames, #lists.boughtNames, nCaps)

    for key in pairs(installed) do
        timeToProduce[key] = OmniHub.computeTimeToProduce(key)
    end

    -- Owner notifications: condition inputs (limits, capacity, install set) only change through
    -- here, onBlockPlanChanged, or recomputeMaxLimits — evaluate the latches at each.
    -- ceil: the raw recommendation is fractional, but the UI floors what it shows — an exact
    -- compare would latch "capacity 1000 below recommended 1000" with no visible way to clear it.
    recommendedCapacity = math.ceil(OmniHubProduction.recommendedCapacity(
        installed, OmniHubModuleDefs.resolveRecipe, goods, MIN_TIME_TO_PRODUCE))
    OmniHubEvents.retainStalls(hubEvents, installed)
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
    OmniHubEvents.checkAssembly(hubEvents, OmniHub.productionCapacity, recommendedCapacity)
end

-- Recompute the SERVER's authoritative max-limit cache from installed + marks + hubMaxLimit, for when
-- tuning changes but rebuild() isn't otherwise run (the Configure tab). rebuild() does the same inline.
-- Server-only: the client gets the cache via the sendGoods push below, not by recomputing (it lacks the
-- inputs — they arrive over RPC, not restore).
function OmniHub.recomputeMaxLimits()
    if not onServer() then return end
    local agg   = OmniHubProduction.aggregate(installed, OmniHubModuleDefs.resolveRecipe)
    local lists = OmniHubTrading.buildTradeLists(sellEnabled, buyEnabled)
    maxLimitByGood = OmniHubMaxLimit.compute(agg, lists.boughtNames, hubMaxLimit, lists.soldNames)
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
end

-- Push the authoritative stock view to one client in a single RPC: per-good max-limit caps AND
-- per-good amounts. The client renders the stock column as amount/cap from exactly these two maps
-- (its replicated cargo drifts behind the server — see the trader.getNumGoods override above).
function OmniHub.sendStockSyncTo(player)
    if not (onServer() and player) then return end
    local t = OmniHub.trader
    local stocks = {}
    for _, good in pairs(t.soldGoods or {}) do
        stocks[good.name] = t:getNumGoods(good.name)
    end
    for _, good in pairs(t.boughtGoods or {}) do
        if stocks[good.name] == nil then stocks[good.name] = t:getNumGoods(good.name) end
    end
    invokeClientFunction(player, "receiveStockSync", maxLimitByGood, stocks)
end

-- The vanilla buy/sell GUI renders each row's stock as amount/getMaxStock(good) ON THE CLIENT, and our
-- getMaxStock reads maxLimitByGood — which only the server computes. So when the client pulls the goods
-- (requestGoods -> server sendGoods -> client receiveGoods), piggyback the map onto the same response.
-- Wrapping sendGoods covers window open, tab refresh, and post-change pulls without a separate RPC.
function OmniHub.sendGoods(...)
    if base_sendGoods then base_sendGoods(...) end
    if callingPlayer then OmniHub.sendStockSyncTo(Player(callingPlayer)) end

    -- Stale-stock diagnostic (server side of the sync boundary): what the server believes at the
    -- moment it answers a goods pull. Compare with the client's receiveGoods line — if these stocks
    -- differ, the divergence is between server cargo and client cargo replication; if they match
    -- but the UI shows something else, the divergence is in the repaint path.
    local t = OmniHub.trader
    local sample = t.soldGoods and t.soldGoods[1] or (t.boughtGoods and t.boughtGoods[1])
    if sample then
        hubLog("sendGoods -> player %s: %s sold / %s bought; sample %s server stock=%s cap=%s",
            tostring(callingPlayer), tostring(t.numSold), tostring(t.numBought),
            tostring(sample.name), tostring(OmniHub.getNumGoods(sample.name)),
            tostring(maxLimitByGood[sample.name]))
    end
end
callable(OmniHub, "sendGoods")

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

-- ────────────────────────────────────────────────────────────────
-- Dev-mode test hooks (in-game suite host)
-- ────────────────────────────────────────────────────────────────

-- Runs the in-game test suites INSIDE THIS SCRIPT'S VM. Each Avorion namespace is its own Lua VM:
-- a suite hosted in the OmniHubTests VM would see neither _G.OmniHub nor this script's included-lib
-- instances. omnihubtests.lua therefore calls this via Entity():invokeFunction (server-side,
-- cross-VM, returns plain tables) and only renders the result.
function OmniHub.runDevTests(category)
    if not onServer() then return end
    if not GameSettings().devMode then return end
    local registry = include("lib/omnihub/tests/registry")
    local runner   = registry.run(category or "all")
    print(runner:format())
    return runner:summary()
end

-- Dev-only seam: the exact TradingUtility table this script uses (allow-list assertions). A suite
-- inspecting its own include("tradingutility") copy would see a different instance.
function OmniHub.getTradingUtilityForTests()
    if not GameSettings().devMode then return end
    return TradingUtility
end

-- Dev-only seam: the exact instances requestTraders drives, so the in-game suite can patch
-- spawnWave/countTraders (fleet) and waveSize (decision) on the tables the controller calls.
function OmniHub.getWaveSeamsForTests()
    if not GameSettings().devMode then return end
    return { fleet = OmniHubTraderFleet, decision = OmniHubTradingDecision }
end

-- Forced wave restart: consecutive blocked request windows before starting a wave despite
-- lingering traders. Our own zombies self-despawn via the ship TTL; this backstop exists mainly
-- for ambient vanilla ships we can't give a TTL. 4 windows at the 90s cooldown ≈ 6 minutes.
local FORCE_WAVE_AFTER_BLOCKED = 4

-- Engine-read query the pure trade decisions read hub state through.
local function tradeQuery()
    return {
        getNumGoods = function(name) return OmniHub.getNumGoods(name) end,
        getMaxGoods = function(name) return OmniHub.getMaxGoods(name) end,
        goodPrice   = function(name) local g = goods[name]; return g and g.price end,
        getGoodSize = function(name) local g = goods[name]; return g and g.size or 1 end,
    }
end

-- rng adapter for the pure wave planner: engine Random for the buyer value gate, math.random for
-- the uniform rolls (vanilla spawnTrader uses math.random for the same purposes).
local function waveRng()
    local r = random()
    return {
        test     = function(_, p) return r:test(p) end,
        random01 = function() return math.random() end,
    }
end

-- buyGoods/sellGoods error codes (tradingmanager.lua:1168/1215), mapped per trade direction to
-- owner-readable phrases for the "wave" failure event; unmapped codes fall back to the raw
-- "error code N". deliver = hub buys (buyGoods), pickup = hub sells (sellGoods).
local WAVE_FAIL_REASON = {
    deliver = {
        [2] = "stock cap reached",
        [3] = "the faction can't afford it — deposit credits into the faction account",
        [4] = "buying from other factions is disabled",
    },
    pickup = {
        [1] = "nothing in stock",
        [2] = "the buyer can't pay",
        [4] = "selling to other factions is disabled",
    },
}

-- Immediate-mode wave (sector loaded, no players): vanilla shape — instant buyGoods/sellGoods
-- against the nearest faction, no ships. The wrappers below record statistics as usual.
local function applyWaveImmediate(manifests, tradingFactionIndex)
    for _, manifest in ipairs(manifests) do
        for _, op in ipairs(OmniHubTradingDecision.transactionList(manifest)) do
            local g    = goods[op.name]
            local good = g and g:good()
            if good then
                local err
                if op.kind == "deliver" then
                    err = OmniHub.buyGoods(good, op.amount, tradingFactionIndex)
                else
                    err = OmniHub.sellGoods(good, op.amount, tradingFactionIndex)
                end
                if err ~= 0 then
                    local reasons = WAVE_FAIL_REASON[op.kind]
                    OmniHubEvents.tradeFailed(hubEvents, "wave", op.name, op.amount,
                        (reasons and reasons[err]) or ("error code " .. tostring(err)))
                end
            end
        end
    end
end

-- requestTraders, wave model (multi-trader design doc): on the vanilla 90s cooldown cadence, plan
-- ALL eligible trades into mixed-trader manifests and spawn them as one wave. A new wave starts
-- only when no trader (ours or ambient) is still serving the hub — strict zero-count gate with
-- the forced-restart backstop. Composition is deterministic (no pSeller roll); ship count is
-- capped by the maxTradersPerWave config and the hub's free docking positions.
function OmniHub.requestTraders(timeStep)
    if not onServer() then return end
    if not aggregatedProduction then return end

    OmniHub.traderCooldown = OmniHub.traderCooldown - timeStep
    if OmniHub.traderCooldown > 0 then return end
    OmniHub.traderCooldown = OmniHubConfig.get("traderRequestCooldown")

    local sector = Sector()
    if sector:getValue("war_zone") then return end

    local entity = Entity()

    local liveCount = OmniHubTraderFleet.countTraders(entity)
    local gate = OmniHubTradingDecision.waveGate(liveCount, hasTradersBlocks, FORCE_WAVE_AFTER_BLOCKED)
    hasTradersBlocks = gate.blocked
    if not gate.start then
        hubLog("requestTraders: wave blocked by %d live trader(s) (%d consecutive windows)",
            liveCount, gate.blocked)
        return
    end
    if gate.forced then
        hubWarn("requestTraders: FORCED wave start (%d trader(s) still lingering after %d blocked windows)",
            liveCount, FORCE_WAVE_AFTER_BLOCKED)
    end

    local immediate = (sector.numPlayers == 0)

    -- Owner trade-direction gates (vanilla activelyRequest/activelySell) filter the wave's sides.
    local agg = {
        ingredients = OmniHub.trader.activelyRequest and aggregatedProduction.ingredients or {},
        results     = OmniHub.trader.activelySell    and aggregatedProduction.results     or {},
        garbages    = OmniHub.trader.activelySell    and aggregatedProduction.garbages    or {},
    }

    local docks     = DockingPositions(entity)
    local dockCount = (docks and docks.numDockingPositions) or 0
    local ships     = OmniHubTradingDecision.waveSize(
        OmniHubConfig.get("maxTradersPerWave"), dockCount, liveCount)
    -- Immediate mode trades without ships, so dock capacity doesn't constrain the budget.
    if immediate then ships = OmniHubConfig.get("maxTradersPerWave") end
    if ships <= 0 then
        hubLog("requestTraders: no wave capacity (docks=%d, live=%d)", dockCount, liveCount)
        return
    end

    local shipValue = OmniHubTraderFleet.shipValueCap()
    local manifests = OmniHubTradingDecision.planWave(agg, tradeQuery(), waveRng(), {
        maxShips  = ships,
        shipValue = shipValue,
        -- shipVolume: unknown before the freighter is generated (vanilla never checks either);
        -- planWave supports it for when a volume source exists.
        immediate = immediate,
        -- Owner affordability: never request deliveries the station faction can't pay for —
        -- buyFromShip would fail its canPay check silently (the error goes to the NPC's faction)
        -- and the trader would dock and leave empty.
        budget    = Faction().money,
        buyFactor = OmniHub.trader.buyPriceFactor,
    })
    -- Which limiter shaped this wave: manifests < ships means everything fit fewer hulls (value
    -- below the per-ship cap); ships < config means dock capacity clamped the budget; zero
    -- deliveries despite unmet ingredients usually means the money budget ate them.
    local nDel, nPick = 0, 0
    for _, manifest in ipairs(manifests) do
        nDel  = nDel + #manifest.deliveries
        nPick = nPick + #manifest.pickups
    end
    hubLog("requestTraders: wave planned — %d manifest(s): %d delivery item(s), %d pickup item(s) "
        .. "(budget %d ships, docks %d, live %d, shipValueCap %s, money %s)",
        #manifests, nDel, nPick, ships, dockCount, liveCount,
        tostring(math.floor(shipValue)), tostring(Faction().money))
    if #manifests == 0 then
        hubLog("requestTraders: nothing eligible this wave")
        return
    end

    if immediate then
        local faction = Galaxy():getNearestFaction(sector:getCoordinates())
        applyWaveImmediate(manifests, faction.index)
        hubLog("requestTraders: immediate wave applied (%d manifest(s))", #manifests)
    else
        local n = OmniHubTraderFleet.spawnWave(entity, manifests, getScriptPath(), OmniHub)
        hubLog("requestTraders: wave spawned (%d trader(s))", n)
    end
end

-- ────────────────────────────────────────────────────────────────
-- Offline director sync (heartbeat publish + wake reconcile)
-- ────────────────────────────────────────────────────────────────
local DIRECTOR_SCRIPT    = "data/scripts/galaxy/omnihubdirector.lua"
local HEARTBEAT_INTERVAL = 30  -- seconds between publishes while loaded (NOT per tick)

-- Compact shadow snapshot: everything the pure offline sim needs and cannot read itself. Captured
-- at heartbeat because the inputs (ttm from production capacity, caps from marks/limits, the
-- sector's value cap) are unavailable while the sector is unloaded.
local function buildShadowSnapshot()
    local entity = Entity()
    local q = tradeQuery()
    local inventory, tradeCaps = {}, {}
    if aggregatedProduction then
        local function snap(list)
            for _, g in pairs(list or {}) do
                inventory[g.name] = q.getNumGoods(g.name)
                tradeCaps[g.name] = q.getMaxGoods(g.name)
            end
        end
        snap(aggregatedProduction.ingredients)
        snap(aggregatedProduction.results)
        snap(aggregatedProduction.garbages)
    end

    local sector = Sector()
    local docks  = DockingPositions(entity)
    return {
        installed = installed,
        ttm       = timeToProduce,
        progress  = productionProgress,
        inventory = inventory,
        tradeCaps = tradeCaps,
        stockCaps = maxLimitByGood,
        freeSpace = entity.freeCargoSpace,
        buyFactor  = OmniHub.trader.buyPriceFactor,
        sellFactor = OmniHub.trader.sellPriceFactor,
        activelyRequest = OmniHub.trader.activelyRequest and true or false,
        activelySell    = OmniHub.trader.activelySell and true or false,
        flags = {
            war     = sector:getValue("war_zone") and true or false,
            noTrade = sector:getValue("no_trade_zone") and true or false,
        },
        cfg = {
            -- The offline wave period = online cooldown x multiplier: the slower cadence models
            -- the docking latency (fly-in + queue + 40s wait + fly-out) online waves pay.
            wavePeriod = OmniHubConfig.get("traderRequestCooldown")
                       * OmniHubConfig.get("offlineWaveDelayMultiplier"),
            maxShips   = math.min(OmniHubConfig.get("maxTradersPerWave"),
                                  (docks and docks.numDockingPositions) or 0),
            shipValue  = OmniHubTraderFleet.shipValueCap(),
        },
        waveTimer = 0,
    }
end

local function sendHeartbeat()
    local x, y = Sector():getCoordinates()
    Galaxy():invokeFunction(DIRECTOR_SCRIPT, "heartbeat", {
        id     = Entity().id.string,
        x      = x,
        y      = y,
        owner  = Faction().index,
        shadow = buildShadowSnapshot(),
    })
end

-- Wake reconcile: pull the director's shadow and write its inventory into REAL cargo (absolute
-- amounts; the shadow is the sole authority for the offline period). Money is NOT touched here —
-- it was settled live during offline simulation; re-applying would double-pay (the offline spec's
-- loudest invariant).
local function reconcileWithDirector()
    local err, shadow = Galaxy():invokeFunction(DIRECTOR_SCRIPT, "wake", Entity().id.string)
    if err ~= 0 or not shadow then return end  -- not registered yet: nothing happened offline

    local entity = Entity()
    for name, amount in pairs(shadow.inventory or {}) do
        local g    = goods[name]
        local good = g and g:good()
        if good then
            local current = entity:getCargoAmount(good)
            local delta   = amount - current
            if delta > 0 then
                entity:addCargo(good, delta)
            elseif delta < 0 then
                entity:removeCargo(good, -delta)
            end
        end
    end

    -- Continue mid-cycle production where the offline sim left it (keys may have changed if the
    -- owner never could offline — guard on still-installed).
    for key, p in pairs(shadow.progress or {}) do
        if installed[key] then productionProgress[key] = p end
    end

    hubLog("director: reconciled offline result into cargo")
end

function OmniHub.directorTick(timeStep)
    if needDirectorSync then
        needDirectorSync = false
        reconcileWithDirector()
        sendHeartbeat()
        directorHeartbeatClock = 0
        return
    end

    directorHeartbeatClock = directorHeartbeatClock + timeStep
    if directorHeartbeatClock >= HEARTBEAT_INTERVAL then
        directorHeartbeatClock = 0
        sendHeartbeat()
    end
end

-- Mirrors factory.lua:1893
function OmniHub.getSellerProbability()
    return OmniHubProduction.sellerProbability(OmniHub.trader.buyPriceFactor)
end


-- ────────────────────────────────────────────────────────────────
-- Statistics (transaction logging + last-hour ring)
-- ────────────────────────────────────────────────────────────────

-- Docked-trade failure visibility: vanilla buyFromShip/sellToShip report failures only to the
-- VISITING ship's faction (an NPC — the owner never sees the message) and return nothing, so a
-- trader that docks and leaves without trading is otherwise invisible. Wrap both to raise an owner
-- event whenever a docked exchange moved no stock, with the likely reason.
function OmniHub.buyFromShip(shipIndex, goodName, amount, noDockCheck)
    local before = onServer() and OmniHub.getNumGoods(goodName) or 0
    local r = base_buyFromShip(shipIndex, goodName, amount, noDockCheck)
    if onServer() and OmniHub.getNumGoods(goodName) == before then
        -- Partial-purchase retry: vanilla canPay is all-or-nothing, and AMBIENT traders (invited
        -- via the A1 allow-list) size their loads without knowing our balance — a too-big delivery
        -- would otherwise dock and leave with everything. Buy HALF of what the money covers,
        -- keeping the window open for the wave's other deliveries.
        local faction = Faction()
        local ship    = Entity(shipIndex)
        local unit    = ship and OmniHub.getBuyPrice(goodName, ship.factionIndex) or 0
        local payFactor = OmniHub.trader.factionPaymentFactor or 1.0
        local fullCost  = unit * (tonumber(amount) or 0) * payFactor
        local partial   = OmniHubTradingDecision.partialBuyAmount(faction.money, unit * payFactor)

        if unit > 0 and fullCost > 0 and not faction:canPayMoney(fullCost)
                and partial > 0 and partial < (tonumber(amount) or 0) then
            base_buyFromShip(shipIndex, goodName, partial, noDockCheck)
            -- Partial retry succeeded: the digest records the (smaller) buy; a failure warning
            -- here would contradict it. If it also moved nothing, money is the KNOWN cause —
            -- one specific event, not cantpay + nostock for the same docking.
            if OmniHub.getNumGoods(goodName) > before then return r end
            OmniHubEvents.tradeFailed(hubEvents, "cantpay", goodName, amount)
            return r
        end

        OmniHubEvents.tradeFailed(hubEvents, "nostock_in", goodName, amount)
    end
    return r
end

function OmniHub.sellToShip(shipIndex, goodName, amount, noDockCheck)
    local before = onServer() and OmniHub.getNumGoods(goodName) or 0
    local r = base_sellToShip(shipIndex, goodName, amount, noDockCheck)
    if onServer() and OmniHub.getNumGoods(goodName) == before then
        OmniHubEvents.tradeFailed(hubEvents, "nostock_out", goodName, amount)
    end
    return r
end

-- Partner label for a docked trade: the calling player's name at the trade UI, or a generic tag for
-- an NPC tradeship (the callbacks don't carry the counterparty faction).
local function dockedTradePartner()
    if callingPlayer then
        local p = Player(callingPlayer)
        if p then return p.name end
    end
    return "NPC trader"%_t
end

-- Docked-trade callbacks, fired by tradingmanager's buyFromShip/sellToShip (see initialize). `price`
-- is the TOTAL transaction value — the same convention the buyGoods/sellGoods wrappers below record,
-- and the two paths are disjoint (buyGoods/sellGoods fire no callbacks), so nothing double-counts.
function OmniHub.onDockedTradeBought(goodName, amount, price)
    if not onServer() then return end
    OmniHubStats.record(stats, {kind = "buy", good = goodName, amount = amount, price = price,
                                partner = dockedTradePartner()})
    OmniHubEvents.recordTrade(hubEvents, "buy", goodName, amount, price)
end

function OmniHub.onDockedTradeSold(goodName, amount, price)
    if not onServer() then return end
    OmniHubStats.record(stats, {kind = "sell", good = goodName, amount = amount, price = price,
                                partner = dockedTradePartner()})
    OmniHubEvents.recordTrade(hubEvents, "sell", goodName, amount, price)
end

-- Wrap the inherited buy/sell so every successful trader transaction is recorded. buyGoods/sellGoods
-- return (0, price) on success (tradingmanager.lua); a bare error code otherwise.
-- NOTE: partner uses the RAW faction name — Faction.translatedName is CLIENT-ONLY; reading it on
-- the server throws "Property not found or not readable" with a full traceback in the log (and
-- aborted the stats recording). NPC faction names are generated words, so the raw name reads fine.
function OmniHub.buyGoods(good, amount, otherFactionIndex, monetaryOnly)
    local code, price = base_buyGoods(good, amount, otherFactionIndex, monetaryOnly)
    if onServer() and code == 0 then
        local f = Faction(otherFactionIndex)
        OmniHubStats.record(stats, {kind = "buy", good = good.name, amount = amount, price = price,
                                    partner = f and f.name or ""})
        OmniHubEvents.recordTrade(hubEvents, "buy", good.name, amount, price)
    end
    return code, price
end

function OmniHub.sellGoods(good, amount, otherFactionIndex, monetaryOnly)
    local code, price = base_sellGoods(good, amount, otherFactionIndex, monetaryOnly)
    if onServer() and code == 0 then
        local f = Faction(otherFactionIndex)
        OmniHubStats.record(stats, {kind = "sell", good = good.name, amount = amount, price = price,
                                    partner = f and f.name or ""})
        OmniHubEvents.recordTrade(hubEvents, "sell", good.name, amount, price)
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

-- Rolls the event engine and emits whatever came due (digest, failures, condition edges, stall
-- summaries). Runs even with eventsEnabled off so timers/latches stay current — the gate is at
-- emit time, so re-enabling mid-flight doesn't replay stale state.
function OmniHub.eventsTick(timeStep)
    local due = OmniHubEvents.advance(hubEvents, timeStep)
    if not due then return end
    for _, payload in ipairs(due) do emitEvent(payload) end
end

function OmniHub.sendStats()
    if not onServer() then return end
    if not callerIsOwner() then return end  -- profit/trades/storage are owner-only
    invokeClientFunction(Player(callingPlayer), "receiveStats",
        OmniHubStats.lifetimeProfit(stats), OmniHubStats.lastHourProfit(stats), OmniHubStats.recent(stats, 10),
        OmniHub.collectStorage(), OmniHub.productionCapacity, recommendedCapacity)
end
callable(OmniHub, "sendStats")

-- Gathers the per-good storage readout (only goods that have a max limit) for the Statistics tab. Reads
-- current stock + good size here (engine), defers volume/total math to the pure OmniHubStorage.
function OmniHub.collectStorage()
    local rows = {}
    for name, limit in pairs(maxLimitByGood) do
        if limit and limit > 0 then
            local g = goods[name]
            rows[#rows + 1] = {
                name    = name,
                current = OmniHub.getNumGoods(name),
                size    = (g and g.size) or 1,
                limit   = limit,
            }
        end
    end
    return OmniHubStorage.summarize(rows, Entity().maxCargoSpace)
end

-- ────────────────────────────────────────────────────────────────
-- Per-good sell/buy marks (owner-gated)
-- ────────────────────────────────────────────────────────────────

-- NOTE: these do NOT push the Buy/Sell lists. The client flips its Goods checkbox optimistically and
-- marks the Buy/Sell tabs dirty; those refresh lazily when the player selects them (saves a full
-- buy/sell payload per toggle).
-- Rejects a mark request for a good outside the production-chain set. The Goods tab never shows
-- such a row, so the request means a tampered or outdated client — reject + log (no kick API).
local function rejectNonTradeableMark(name)
    if tradeableGoods[name] then return false end
    local player = Player(callingPlayer)
    local who = (player and player.name or "?") .. " (#" .. tostring(callingPlayer) .. ")"
    hubWarn("SECURITY: %s tried to mark non-tradeable good %s — rejected.", who, tostring(name))
    return true
end

function OmniHub.setGoodSell(name, enabled)
    if not onServer() then return end
    if not callerIsOwner() then return end
    -- Store marks under the good's REAL name: a vanilla alias key (goods["Aluminium"]) would put the
    -- cap under a key no TradingGood.name lookup ever hits, rendering 0/0 and blocking NPC trades.
    name = OmniHubTrading.canonicalName(name, goods)
    if rejectNonTradeableMark(name) then return end
    OmniHubTrading.setMark(sellEnabled, name, enabled)  -- explicit true/false
    OmniHub.rebuild()
    -- Push the refreshed caps/amounts immediately: a freshly marked good is already visible in
    -- the Buy/Sell rows, and without this its cap renders 0/0 until the next full goods pull.
    OmniHub.sendStockSyncTo(Player(callingPlayer))
end
callable(OmniHub, "setGoodSell")

function OmniHub.setGoodBuy(name, enabled)
    if not onServer() then return end
    if not callerIsOwner() then return end
    name = OmniHubTrading.canonicalName(name, goods)  -- see setGoodSell
    if rejectNonTradeableMark(name) then return end
    OmniHubTrading.setMark(buyEnabled, name, enabled)
    OmniHub.rebuild()
    OmniHub.sendStockSyncTo(Player(callingPlayer))
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
        hubWarn("SECURITY: %s sent out-of-range price factors (buy=%s, sell=%s) — rejected.",
            who, tostring(buyFactor), tostring(sellFactor))
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
    if not callerIsOwner() then return end  -- config is owner-only; never leak it to a customer
    OmniHub.sendHubConfigTo(Player(callingPlayer))
end
callable(OmniHub, "sendHubConfig")

function OmniHub.sendHubConfigTo(player)
    local cfg = {
        activelyRequest = OmniHub.trader.activelyRequest,
        activelySell    = OmniHub.trader.activelySell,
        priceFactorBuy  = OmniHub.trader.buyPriceFactor,
        priceFactorSell = OmniHub.trader.sellPriceFactor,
        tradeStock      = hubMaxLimit.buyLimit,
        prodBase        = hubMaxLimit.prodBase,
        prodCycles      = hubMaxLimit.prodCycles,
        debug           = hubDebug,
        events          = eventsEnabled,
        -- Server-authoritative dev gate for the client's debug checkbox: the client's own
        -- GameSettings().devMode can disagree (locally persisted /devmode) and goes stale.
        devMode         = GameSettings().devMode == true,
    }
    invokeClientFunction(player, "receiveHubConfig", cfg)
end

function OmniHub.applyHubConfig(cfg)
    if not onServer() then return end
    if not callerIsOwner() then return end
    if not cfg then return end

    -- Price factors are owned by the sliders (setPriceFactors); applyHubConfig only handles the
    -- active-trade flags.
    OmniHub.trader.buyFromOthers   = true
    OmniHub.trader.sellToOthers    = true
    OmniHub.trader.activelyRequest = cfg.activelyRequest and true or false
    OmniHub.trader.activelySell    = cfg.activelySell and true or false

    -- Max-limit tuning (nil-safe: a client that doesn't send these keeps the current values). floor()
    -- keeps limits whole; clamps guard against a tampered client. buyLimit may be 0 ("don't stockpile
    -- passthrough goods"); prodBase/prodCycles are floored at 1 because 0 would zero out every produced
    -- good's limit and silently halt all production.
    local limitsChanged =
            cfg.tradeStock ~= nil or cfg.prodBase ~= nil or cfg.prodCycles ~= nil
    hubMaxLimit.buyLimit   = math.floor(clamp(cfg.tradeStock or hubMaxLimit.buyLimit,   0, MAXLIMIT_UNITS_CAP))
    hubMaxLimit.prodBase   = math.floor(clamp(cfg.prodBase   or hubMaxLimit.prodBase,   1, MAXLIMIT_UNITS_CAP))
    hubMaxLimit.prodCycles = math.floor(clamp(cfg.prodCycles or hubMaxLimit.prodCycles, 1, MAXLIMIT_CYCLES_CAP))
    if limitsChanged then
        OmniHub.recomputeMaxLimits()
        -- Push only the stock-view maps so the open buy/sell stock column updates in place — no full
        -- goods re-pull. (Without this, caps only refreshed on a full window reopen.)
        OmniHub.sendStockSyncTo(Player(callingPlayer))
    end

    -- Debug toggle (dev-only checkbox). Only update when the client actually sent it, so config pushes
    -- from a non-dev client (no checkbox) don't silently clear a debug session a dev started.
    if cfg.debug ~= nil then hubDebug = cfg.debug and true or false end

    -- Owner notifications toggle. nil-safe like debug: only update when the client sent it.
    if cfg.events ~= nil then eventsEnabled = cfg.events and true or false end

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
    if not callerIsOwner() then return end  -- Goods tab (rates/marks) is owner-only
    OmniHub.sendHubGoodsTo(Player(callingPlayer))
end
callable(OmniHub, "sendHubGoods")

-- Live per-module boost states for boost-aware max rates: a boosted cycle advances at 2x
-- (tickRecipe), so the achievable ceiling doubles while the boost lasts — without this, a boosted
-- module's measured rate reads as 200% of "max" in the Goods tab.
local function currentBoostMap()
    local boosted = {}
    for key, p in pairs(productionProgress) do boosted[key] = p.boosted or false end
    return boosted
end

-- Builds one Goods-table row for `name` (nil if the good is not production-chain tradeable or has
-- no positive price). `maxR` is a
-- precomputed maxRates result. Checkbox state = the EXPLICIT mark (unticked by default; installing a
-- module never auto-enables trading). Prices come straight from goods[] (correct regardless of mark).
function OmniHub.buildGoodRow(name, maxR, sellF, buyF)
    if not tradeableGoods[name] then return nil end  -- production-chain goods only
    local g = goods[name]
    if type(g) ~= "table" or not g.price or g.price <= 0 then return nil end
    local sdf, pct = OmniHub.regionalInfo(name)
    return {
        name        = name,
        icon        = g.icon or "",
        stock       = OmniHub.getNumGoods(name),
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
    local maxR  = OmniHubProduction.maxRates(installed, OmniHubModuleDefs.resolveRecipe, timeToProduce, MIN_TIME_TO_PRODUCE, currentBoostMap())
    local sellF = OmniHub.trader.sellPriceFactor
    local buyF  = OmniHub.trader.buyPriceFactor

    -- Trading-station mode: list every production-chain good (tradeableGoods gate in buildGoodRow)
    -- so the player can opt any of them into Buy/Sell.
    -- OPTIMIZE LATER (docs/performance-notes.md): regionalInfo (economyupdater) once PER GOOD (~200)
    -- per window open. Acceptable as a once-per-open cost for now; cache if it hitches.
    local list = {}
    for name, g in pairs(goods) do
        -- Skip vanilla backwards-compatibility alias keys (goods["Aluminium"] = goods["Aluminum"]):
        -- they'd render duplicate rows whose marks land under a key no TradingGood.name lookup uses.
        if type(g) == "table" and g.name == name then
            local row = OmniHub.buildGoodRow(name, maxR, sellF, buyF)
            if row then list[#list + 1] = row end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    invokeClientFunction(player, "receiveHubGoods", list)
end

-- Periodic Goods-tab tick (the client pulls every 30s while the tab is visible): minimal live
-- values only — stock + measured rate actuals. Goods with nothing to report (no stock, no measured
-- production/consumption) are omitted; the client zeroes everything first (patchLive), so an
-- omitted good correctly renders empty/idle. No prices/market (regionalInfo is the expensive
-- per-good call) and no max rates (those change only on install/uninstall, which has its own delta).
function OmniHub.sendGoodsTick()
    if not onServer() then return end
    if not callerIsOwner() then return end  -- Goods tab (stock/rates) is owner-only
    local rows = {}
    for name in pairs(tradeableGoods) do
        local stock = OmniHub.getNumGoods(name)
        local prate = OmniHubRates.producedPerMin(rates, name)
        local crate = OmniHubRates.consumedPerMin(rates, name)
        if stock > 0 or prate > 0 or crate > 0 then
            rows[#rows + 1] = { name = name, stock = stock, prate = prate, crate = crate }
        end
    end
    invokeClientFunction(Player(callingPlayer), "receiveGoodsTick", rows)
end
callable(OmniHub, "sendGoodsTick")

-- Goods rows whose rates change when a module is installed/uninstalled = the module recipe's
-- ingredients + results + garbages (deduped). Sent in the install/uninstall delta to patch the Goods
-- tab without re-sending all ~200 goods.
function OmniHub.changedGoodRows(key)
    local prod = OmniHubModuleDefs.resolveRecipe(key)
    if not prod then return {} end
    local maxR  = OmniHubProduction.maxRates(installed, OmniHubModuleDefs.resolveRecipe, timeToProduce, MIN_TIME_TO_PRODUCE, currentBoostMap())
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

-- Goods-tab live tick: while that tab is visible, updateClient pulls a minimal stock/rates refresh
-- (sendGoodsTick) every GOODS_TICK_INTERVAL seconds. Selecting the tab pulls immediately and
-- restarts the countdown; opening the window restarts it too (the full sync just ran).
local GOODS_TICK_INTERVAL = 30
local goodsTickTimer = 0

-- Owner = the station's faction or its alliance; gates the owner-only tabs and their data pulls.
local function clientIsOwner()
    local player, faction = Player(), Faction()
    return (player.index == faction.index)
        or (player.allianceIndex and player.allianceIndex == faction.index) or false
end

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
        stockHeader  = "Stock"%_t,
        stockTip     = "Current amount in the station's cargo bay (server value). Refreshes every 30 seconds while this tab is visible. \"-\" = none in stock."%_t,
        prateHeader  = "PRate"%_t,
        prateTip     = "Production rate, units per minute: actual (measured over the last ~60s) / max (theoretical at full utilisation; doubles while a module runs boosted on a stocked optional ingredient). \"-\" = not produced here.\n\nGreen = at capacity, amber = below, orange = idle/starved."%_t,
        crateHeader  = "CRate"%_t,
        crateTip     = "Consumption rate, units per minute: actual (last ~60s) / max (full utilisation; doubles while a module runs boosted). \"-\" = not consumed here.\n\nGreen = at capacity, amber = below, orange = idle/starved."%_t,
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
    -- Live stock/rates refresh: immediate on select, then every GOODS_TICK_INTERVAL via updateClient.
    goodsTab.onSelectedFunction = "onGoodsTabSelected"

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

    -- 0/0 diagnostic: dump exactly what the row captions were computed FROM (same trader instance,
    -- same overridden getters). If this shows N/100 while the visible row says 0/0, the painted
    -- line objects aren't these; if it shows 0/0, the client-side caps cache is the problem.
    local dump = {}
    for i = 1, math.min(6, #(t.soldGoods or {})) do
        local g = t.soldGoods[i]
        dump[#dump + 1] = string.format("%s=%s/%s", g.name,
            tostring(t:getNumGoods(g.name)), tostring(t:getMaxStock(g)))
    end
    for i = 1, math.min(6, #(t.boughtGoods or {})) do
        local g = t.boughtGoods[i]
        dump[#dump + 1] = string.format("%s=%s/%s", g.name,
            tostring(t:getNumGoods(g.name)), tostring(t:getMaxStock(g)))
    end
    if #dump > 0 then hubLog("repaint rows: %s", table.concat(dump, " | ")) end
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

    -- Goods-pull diagnostic (client side, lands in the CLIENT log). Stock values are NOT logged
    -- here: the authoritative amounts arrive in the FOLLOWING receiveStockSync message (same pull,
    -- ordered after this one), which logs its own sample.
    hubLog("receiveGoods: %s sold / %s bought", tostring(#allSold), tostring(#allBought))
end

function OmniHub.onBuyPrevPage()  buyPage  = buyPage  - 1; OmniHub.applyPageSlices() end
function OmniHub.onBuyNextPage()  buyPage  = buyPage  + 1; OmniHub.applyPageSlices() end
function OmniHub.onSellPrevPage() sellPage = sellPage - 1; OmniHub.applyPageSlices() end
function OmniHub.onSellNextPage() sellPage = sellPage + 1; OmniHub.applyPageSlices() end

-- Client-only tick (engine calls updateClient after update). While the window is open, commit max-stock
-- fields that lost focus / took an Enter (pollStockCommit), pushing the full config once per edit — no
-- per-keystroke RPC. Defined here so it can see the client-local configUI upvalue.
function OmniHub.updateClient(timeStep)
    if OmniHub.windowOpen and configUI and configUI:pollStockCommit() then
        OmniHub.onConfigChanged()
    end
    -- Goods-tab live tick: only while the tab is actually visible (no data for tabs nobody watches).
    if OmniHub.windowOpen and goodsTab and goodsTab.isActiveTab then
        goodsTickTimer = goodsTickTimer + timeStep
        if goodsTickTimer >= GOODS_TICK_INTERVAL then
            goodsTickTimer = 0
            if clientIsOwner() then invokeServerFunction("sendGoodsTick") end
        end
    end
end

function OmniHub.onShowWindow()
    OmniHub.windowOpen = true
    goodsTickTimer = 0   -- the full sendHubGoods sync below covers the Goods tab right now

    local isOwner = clientIsOwner()

    OmniHub.updateTradeTabs()

    -- Everything except Buy/Sell is owner-only — a customer sees only the trade tables.
    for _, t in ipairs({goodsTab, statsTab, configTab, modulesTab}) do
        if isOwner then tabbedWindow:activateTab(t) else tabbedWindow:deactivateTab(t) end
    end

    OmniHub.requestGoods()  -- inherited: refreshes the buy/sell tables (re-gates via receiveGoods)
    goodsDirty = false      -- just synced
    -- Owner-only data (Goods/Statistics/Modules/Config tabs). Non-owners get only the Buy/Sell tables.
    if isOwner then
        invokeServerFunction("sendHubGoods")
        invokeServerFunction("sendStats")
        invokeServerFunction("sendModuleData")
        invokeServerFunction("sendHubConfig")
    end
end

function OmniHub.onCloseWindow()
    OmniHub.windowOpen = false
end

-- ── Client RPC handlers ──────────────────────────────────────────
-- Full module sync: per-key installed + inventory counts (the UI merges them with the catalog).
function OmniHub.receiveModuleData(installedCounts, inventoryCounts)
    if modulesUI then modulesUI:setCounts(installedCounts or {}, inventoryCounts or {}) end
    -- Install/uninstall changed which goods are produced/consumed (and thus their reserve caps), so pull
    -- fresh buy/sell goods; the sendGoods response carries the updated max-limit map.
    OmniHub.requestGoods()
end

-- Targeted delta after install/uninstall: patch the one module row + the changed Goods rows, and mark
-- the Buy/Sell tabs stale so they re-pull (with the new max-limit caps) on next select.
function OmniHub.receiveModuleDelta(key, installedCount, inventory, changedGoods)
    if modulesUI then modulesUI:patch(key, installedCount or 0, inventory or 0) end
    if goodsUI then goodsUI:patch(changedGoods) end
    goodsDirty = true
end

function OmniHub.receiveHubGoods(list)
    OmniHub.lastGoods = list or {}
    if goodsUI then goodsUI:setData(OmniHub.lastGoods) end
end

-- Periodic Goods-tab tick: minimal {name, stock, prate, crate} rows for goods with anything to
-- report. patchLive zeroes everything else, so omitted goods render empty/idle.
function OmniHub.receiveGoodsTick(rows)
    if goodsUI then goodsUI:patchLive(rows) end
end

-- Authoritative per-good max-limit caps pushed by the server alongside every goods sync (sendGoods
-- override). Store them and repaint so the buy/sell stock column shows amount/cap instead of N/0.
-- Full stock-view sync (caps + amounts) arriving with every goods pull / limit change / mark
-- change. From here on the trade UI renders from server truth; the (drifting) client cargo is
-- only a pre-sync fallback.
function OmniHub.receiveStockSync(limits, stocks)
    maxLimitByGood = limits or {}
    serverStock    = stocks or {}
    local nCaps, nStocks = 0, 0
    for _, cap in pairs(maxLimitByGood) do if cap and cap > 0 then nCaps = nCaps + 1 end end
    for _ in pairs(serverStock) do nStocks = nStocks + 1 end
    hubLog("receiveStockSync: %d positive cap(s), %d stock row(s)", nCaps, nStocks)
    OmniHub.repaintTradeLines()
end

-- Targeted per-good stock delta, broadcast by the server whenever a trade-listed good's amount
-- actually changes. Updates the cache and repaints just that row via the vanilla per-good path
-- (which reads trader:getNumGoods — i.e. the cache).
function OmniHub.receiveStockDelta(name, amount)
    if onServer() then return end
    serverStock[name] = amount
    OmniHub.updateSoldGoodAmount(name)
    OmniHub.updateBoughtGoodAmount(name)
end

function OmniHub.receiveStats(lifetime, lastHour, txns, storage, capacity, recommended)
    if statisticsUI then
        statisticsUI:set(lifetime, lastHour, txns)
        statisticsUI:setStorage(storage)
        statisticsUI:setCapacity(capacity, recommended)
    end
end

function OmniHub.receiveHubConfig(cfg)
    -- Mirror the owner's debug toggle into THIS (client) VM, so client-side hubLog lines (e.g. the
    -- receiveGoods diagnostics) obey the same gate as the server's. Without this the client copy of
    -- hubDebug stays false forever and client debug output is impossible.
    if cfg and cfg.debug ~= nil then hubDebug = cfg.debug and true or false end
    -- Same mirror for the events toggle: keeps the client copy equal to the server's so any
    -- future client-side gating reads the real value, never the constructor default.
    if cfg and cfg.events ~= nil then eventsEnabled = cfg.events and true or false end
    if not configUI then return end
    configUI:apply(cfg)
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
        -- Sell tab (boughtGoods) + its reserve caps now stale; the next select re-pulls goods, and the
        -- server's sendGoods response carries the refreshed stock-view maps (receiveStockSync).
        goodsDirty = true
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
    if not configUI or not configUI.synced then return end  -- pre-sync guard, see onConfigChanged
    local buyF, sellF = configUI:readPrices()
    if goodsUI then goodsUI:setPriceFactors(sellF, buyF) end   -- client-side price prediction
    invokeServerFunction("setPriceFactors", buyF, sellF)
    goodsDirty = true
end

-- Selecting the Goods tab pulls a live stock/rates tick immediately (the last one may be up to
-- 30s stale) and restarts the periodic countdown. Non-owners never see this tab, but guard anyway
-- (don't request owner-only data the server would refuse).
function OmniHub.onGoodsTabSelected()
    if not clientIsOwner() then return end
    goodsTickTimer = 0
    invokeServerFunction("sendGoodsTick")
end

-- Selecting the Buy or Sell tab pulls fresh data only if something changed since the last sync.
function OmniHub.onTradeTabSelected()
    if goodsDirty then
        OmniHub.requestGoods()  -- receiveGoods re-slices + repaints both tables
        goodsDirty = false
    end
end

function OmniHub.onConfigChanged()
    -- Pre-sync guard: before the first receiveHubConfig the widgets still show constructor
    -- defaults (checkboxes unchecked), so pushing read() would persist settings the player never
    -- touched. The dropped click is harmless — the imminent sync repaints the real state.
    if configUI and configUI.synced then invokeServerFunction("applyHubConfig", configUI:read()) end
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
