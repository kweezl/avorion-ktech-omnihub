package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("faction")
include("randomext")
include("callable")
include("productions")
include("goods")
local TradingAPI = include("tradingmanager")  -- exposes TradingAPI global
local OmniHubConfig = include("lib/omnihub/config")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local Dialog = include("dialogutility")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHub
OmniHub = TradingAPI:CreateNamespace()

-- ────────────────────────────────────────────────────────────────
-- Constants
-- ────────────────────────────────────────────────────────────────
local MIN_CARGO_BAY = 25000
local MIN_TIME_TO_PRODUCE = 15.0  -- seconds, matches factory.lua

-- ────────────────────────────────────────────────────────────────
-- Server-side state (persisted through secure/restore)
-- ────────────────────────────────────────────────────────────────
local installed          = {}  -- { [moduleKey] = count }
local productionProgress = {}  -- { [moduleKey] = {progress=0..1, boosted=bool} } or nil if idle
local timeToProduce      = {}  -- { [moduleKey] = seconds } — derived, recomputed on restore/rebuild

-- Aggregated production table: single merged recipe across all installed factory modules,
-- with ingredient/result/garbage amounts summed and scaled by module count.
-- Mirrors factory.lua's file-local `production` variable so requestTraders can iterate it directly.
-- nil when no factory modules are installed.
local aggregatedProduction = nil

OmniHub.productionCapacity = 100  -- updated by onBlockPlanChanged
OmniHub.traderCooldown     = 0    -- countdown timer; decremented in update()

-- ────────────────────────────────────────────────────────────────
-- Cache TradingAPI base persistence methods BEFORE we override
-- ────────────────────────────────────────────────────────────────
local base_secure  = OmniHub.secure
local base_restore = OmniHub.restore

-- ────────────────────────────────────────────────────────────────
-- Interaction / initialization
-- ────────────────────────────────────────────────────────────────
function OmniHub.interactionPossible(playerIndex, option)
    return CheckFactionInteraction(playerIndex, -10000)
end

function OmniHub.getIcon()
    return "data/textures/icons/factory.png"
end

function OmniHub.initialize()
    local entity = Entity()

    if entity.title == "" then
        entity.title = "OmniHub"%_t
        InteractionText(entity.index).text = Dialog.generateStationInteractionText(entity, random())
    end

    if onServer() then
        local bay = CargoBay()
        if bay and bay.cargoHold < MIN_CARGO_BAY then
            bay.cargoHold = MIN_CARGO_BAY
        end

        entity:registerCallback("onBlockPlanChanged", "onBlockPlanChanged")
        entity:registerCallback("onDestroyed", "onDestroyed")

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
-- Persistence
-- ────────────────────────────────────────────────────────────────
function OmniHub.secure()
    local data = base_secure and base_secure() or {}
    data.installed          = installed
    data.productionProgress = productionProgress
    data.traderCooldown     = OmniHub.traderCooldown
    return data
end

function OmniHub.restore(data)
    if base_restore then base_restore(data) end
    installed              = data.installed          or {}
    productionProgress     = data.productionProgress or {}
    OmniHub.traderCooldown = data.traderCooldown     or 0
    if onServer() then
        OmniHub.rebuild()
    end
end

-- ────────────────────────────────────────────────────────────────
-- Update loop (production + trader spawning)
-- ────────────────────────────────────────────────────────────────
function OmniHub.getUpdateInterval()
    return Sector().numPlayers > 0 and 1 or 5
end

function OmniHub.update(timeStep)
    if not onServer() then return end
    OmniHub.runProductionCycles(timeStep)
    OmniHub.requestTraders(timeStep)
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

    -- Try to start a new cycle
    local entity     = Entity()
    local canProduce = true
    local boosted    = false

    for _, ing in pairs(prod.ingredients) do
        local need = ing.amount * count
        local have = OmniHub.getNumGoods(ing.name)
        if ing.optional == 0 and have < need then
            canProduce = false
            break
        end
        if ing.optional == 1 and have >= need then
            boosted = true
        end
    end

    if not canProduce then return end

    for _, res in pairs(prod.results) do
        local size     = OmniHub.getGoodSize(res.name)
        local newAmt   = OmniHub.getNumGoods(res.name) + res.amount * count
        local maxStock = OmniHub.getMaxStock({name = res.name, size = size})
        if newAmt > maxStock or entity.freeCargoSpace < res.amount * count * size then
            canProduce = false
            break
        end
    end

    if not canProduce then return end

    for _, ing in pairs(prod.ingredients) do
        local removed = OmniHub.decreaseGoods(ing.name, ing.amount * count)
        if ing.optional == 1 and removed then
            boosted = true
        end
    end

    productionProgress[key] = {progress = 0, boosted = boosted}
end

function OmniHub.computeTimeToProduce(key)
    local prod = OmniHubModuleDefs.resolveRecipe(key)
    if not prod then return MIN_TIME_TO_PRODUCE end

    local totalValue = 0
    local totalLevel = 0
    local samples    = 0

    local function accumulate(name, amount)
        local g = goods[name]
        if g then
            totalValue = totalValue + g.price * amount
            totalLevel = totalLevel + (g.level or 0)
            samples    = samples + 1
        end
    end

    for _, res in pairs(prod.results) do
        accumulate(res.name, res.amount)
    end
    if prod.garbages then
        for _, gar in pairs(prod.garbages) do
            accumulate(gar.name, gar.amount)
        end
    end

    local avgLevel   = samples > 0 and (totalLevel / samples) or 0
    local levelBonus = 1 + avgLevel / 100
    local cap        = math.max(1, OmniHub.productionCapacity or 1)
    return math.max(MIN_TIME_TO_PRODUCE, totalValue / cap / levelBonus)
end

-- ────────────────────────────────────────────────────────────────
-- Module registry
-- ────────────────────────────────────────────────────────────────

function OmniHub.rebuild()
    if not onServer() then return end

    local ingredientMap = {}
    local resultMap     = {}
    local garbageMap    = {}
    local hasAny        = false

    for key, count in pairs(installed) do
        local prod = OmniHubModuleDefs.resolveRecipe(key)
        if prod then
            hasAny = true

            for _, ing in pairs(prod.ingredients) do
                local entry = ingredientMap[ing.name]
                if not entry then
                    ingredientMap[ing.name] = {name = ing.name, amount = ing.amount * count, optional = ing.optional}
                else
                    entry.amount = entry.amount + ing.amount * count
                end
            end

            for _, res in pairs(prod.results) do
                local entry = resultMap[res.name]
                if not entry then
                    resultMap[res.name] = {name = res.name, amount = res.amount * count}
                else
                    entry.amount = entry.amount + res.amount * count
                end
            end

            if prod.garbages then
                for _, gar in pairs(prod.garbages) do
                    local entry = garbageMap[gar.name]
                    if not entry then
                        garbageMap[gar.name] = {name = gar.name, amount = gar.amount * count}
                    else
                        entry.amount = entry.amount + gar.amount * count
                    end
                end
            end
        end
    end

    local bought = {}
    local sold   = {}
    for _, v in pairs(ingredientMap) do bought[#bought + 1] = v end
    for _, v in pairs(resultMap)     do sold[#sold + 1]     = v end
    for _, v in pairs(garbageMap)    do sold[#sold + 1]     = v end

    OmniHub.initializeTrading(bought, sold)

    if hasAny then
        aggregatedProduction = {
            ingredients = bought,
            results     = {},
            garbages    = {},
        }
        for _, v in pairs(resultMap)  do aggregatedProduction.results[#aggregatedProduction.results + 1]   = v end
        for _, v in pairs(garbageMap) do aggregatedProduction.garbages[#aggregatedProduction.garbages + 1] = v end
    else
        aggregatedProduction = nil
    end

    for key in pairs(installed) do
        timeToProduce[key] = OmniHub.computeTimeToProduce(key)
    end
end

-- requestTraders: mirrors factory.lua:1828-1885.
-- Uses aggregatedProduction so it iterates a single merged table (like factory.lua's `production`).
-- Cooldown is configurable; skips if no free docking positions.
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
    return lerp(OmniHub.trader.buyPriceFactor, 0.8, 1.2, 0.1, 0.9)
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
-- Install / uninstall RPCs
-- ────────────────────────────────────────────────────────────────

function OmniHub.installModule(inventoryIndex)
    if not onServer() then return end
    local player    = Player(callingPlayer)
    local inventory = player:getInventory()

    local item = inventory:find(inventoryIndex)
    if not item then return end
    if item:getValue("subtype") ~= "OmniHubModule" then return end

    local key = item:getValue("moduleKey")
    if not key or key == "" then return end
    if not OmniHubModuleDefs.get(key) then return end

    local cap = OmniHubConfig.get("moduleCap")
    if cap >= 0 then
        local total = 0
        for _, c in pairs(installed) do total = total + c end
        if total >= cap then
            player:sendChatMessage("OmniHub"%_t, ChatMessageType.Error, "Module capacity reached (%1%)."%_t, cap)
            return
        end
    end

    inventory:take(inventoryIndex)
    installed[key] = (installed[key] or 0) + 1
    OmniHub.rebuild()
    OmniHub.sendModuleDataTo(player)
end
callable(OmniHub, "installModule")

function OmniHub.uninstallModule(key)
    if not onServer() then return end
    if not installed[key] or installed[key] <= 0 then return end

    local player    = Player(callingPlayer)
    local inventory = player:getInventory()

    installed[key] = installed[key] - 1
    if installed[key] == 0 then
        installed[key]          = nil
        productionProgress[key] = nil
        timeToProduce[key]      = nil
    end

    local item = UsableInventoryItem(
        "data/scripts/items/omnihubmodule.lua",
        Rarity(RarityType.Common),
        key
    )
    inventory:addOrDrop(item, true)

    OmniHub.rebuild()
    OmniHub.sendModuleDataTo(player)
end
callable(OmniHub, "uninstallModule")

-- ────────────────────────────────────────────────────────────────
-- Client data sync
-- ────────────────────────────────────────────────────────────────

function OmniHub.sendModuleData()
    if not onServer() then return end
    OmniHub.sendModuleDataTo(Player(callingPlayer))
end
callable(OmniHub, "sendModuleData")

function OmniHub.sendModuleDataTo(player)
    local installedList = {}
    for key, count in pairs(installed) do
        local def = OmniHubModuleDefs.get(key)
        if def then
            installedList[#installedList + 1] = {key = key, name = def.name, count = count}
        end
    end
    table.sort(installedList, function(a, b) return a.name < b.name end)

    local inventory     = player:getInventory()
    local inventoryList = {}
    for i = 0, inventory.maxSlots - 1 do
        if not inventory:slotEmpty(i) then
            local invItem = inventory:find(i)
            if invItem and invItem.itemType == InventoryItemType.UsableItem then
                if invItem:getValue("subtype") == "OmniHubModule" then
                    local ikey = invItem:getValue("moduleKey")
                    local def  = OmniHubModuleDefs.get(ikey)
                    inventoryList[#inventoryList + 1] = {
                        slotIndex = i,
                        key       = ikey,
                        name      = def and def.name or ikey,
                    }
                end
            end
        end
    end

    invokeClientFunction(player, "receiveModuleData", installedList, inventoryList)
end

-- ────────────────────────────────────────────────────────────────
-- Client-side UI handles (module-local, not persisted)
-- ────────────────────────────────────────────────────────────────
local window        = nil
local tabbedWindow  = nil
local manageTab     = nil
local productionTab = nil

-- Manage tab UI state
local manageInstalledFrame = nil
local manageInventoryFrame = nil
local manageInstalledRows  = {}
local manageInventoryRows  = {}

-- Production tab UI state
local prodFrame = nil
local prodRows  = {}

-- Cached server data (client-side)
OmniHub.lastInstalledList = {}
OmniHub.lastInventoryList = {}

-- ────────────────────────────────────────────────────────────────
-- UI
-- ────────────────────────────────────────────────────────────────
function OmniHub.initUI()
    local res  = getResolution()
    local size = vec2(700, 550)

    local menu = ScriptUI()
    window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    window.caption         = "OmniHub"%_t
    window.showCloseButton = 1
    window.moveable        = 1
    menu:registerWindow(window, "OmniHub"%_t)

    tabbedWindow  = window:createTabbedWindow(Rect(vec2(10, 10), size - 10))
    manageTab     = tabbedWindow:createTab("Manage"%_t,     "", "Install and uninstall modules"%_t)
    productionTab = tabbedWindow:createTab("Production"%_t, "", "Monitor production status"%_t)

    OmniHub.buildManageTab(manageTab, size)
    OmniHub.buildProductionTab(productionTab, size)
end

function OmniHub.onShowWindow()
    invokeServerFunction("sendModuleData")
end

function OmniHub.onCloseWindow()
end

-- Placeholder — replaced in Task 8
function OmniHub.buildManageTab(tab, size)
    local label = tab:createLabel(vec2(10, 10), "Install modules from your inventory below."%_t, 14)
    label.size  = vec2(size.x - 20, 20)
end

-- Placeholder — replaced in Task 9
function OmniHub.buildProductionTab(tab, size)
    local label = tab:createLabel(vec2(10, 10), "No factory modules installed."%_t, 14)
    label.size  = vec2(size.x - 20, 20)
end

-- Stubs — implemented in Tasks 8 & 9
function OmniHub.refreshManageUI() end
function OmniHub.refreshProductionUI() end

-- Called by server RPC response — stub until Task 6
function OmniHub.receiveModuleData(installedList, inventoryList)
    OmniHub.lastInstalledList = installedList or {}
    OmniHub.lastInventoryList = inventoryList or {}
    OmniHub.refreshManageUI()
    OmniHub.refreshProductionUI()
end

return OmniHub
