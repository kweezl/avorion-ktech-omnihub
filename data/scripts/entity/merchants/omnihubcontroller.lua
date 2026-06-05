package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("faction")
include("randomext")
include("callable")
include("productions")
include("goods")
local TradingAPI = include("tradingmanager")  -- exposes TradingAPI global
local TradingUtility = include("tradingutility")
local OmniHubConfig = include("lib/omnihub/config")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubProduction = include("lib/omnihub/production")
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
-- Loot drops on destruction
-- ────────────────────────────────────────────────────────────────

function OmniHub.onDestroyed(lastDamageInflictor)
    if not onServer() then return end

    local dropChance = OmniHubConfig.get("dropChance")
    local rng        = random()
    local loot       = Loot(Entity().id)

    for key, count in pairs(installed) do
        for _ = 1, count do
            if rng:test(dropChance) then
                local item = UsableInventoryItem(
                    "data/scripts/items/omnihubmodule.lua",
                    Rarity(RarityType.Common),
                    key
                )
                loot:insert(item)
            end
        end
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
    data.tradingData        = OmniHub.secureTradingGoods()
    return data
end

function OmniHub.restore(data)
    if base_restore then base_restore(data) end
    installed              = data.installed          or {}
    productionProgress     = data.productionProgress or {}
    OmniHub.traderCooldown = data.traderCooldown     or 0
    if data.tradingData then OmniHub.restoreTradingGoods(data.tradingData) end
    if onServer() then OmniHub.rebuild() end
end

-- ────────────────────────────────────────────────────────────────
-- Update loop (production + trader spawning)
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
-- Module registry
-- ────────────────────────────────────────────────────────────────

function OmniHub.rebuild()
    if not onServer() then return end

    -- Pure aggregation of all installed recipes (summed amounts + merged aggregatedProduction).
    local agg = OmniHubProduction.aggregate(installed, OmniHubModuleDefs.resolveRecipe)

    -- Build TradingGood arrays for initializeTrading (engine-side: needs goods:good()).
    local bought = {}
    local sold   = {}
    for name in pairs(agg.ingAmounts) do
        local g = goods[name]
        if g then bought[#bought + 1] = g:good() end
    end
    for name in pairs(agg.resAmounts) do
        local g = goods[name]
        if g then sold[#sold + 1] = g:good() end
    end
    for name in pairs(agg.garAmounts) do
        local g = goods[name]
        if g then sold[#sold + 1] = g:good() end
    end

    OmniHub.initializeTrading(bought, sold)

    aggregatedProduction = agg.aggregatedProduction

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

    -- Build list of OmniHub modules in player inventory
    local inventory     = player:getInventory()
    local inventoryList = {}
    local invSlots = inventory:getItemsByType(InventoryItemType.UsableItem)
    for slotIndex, slot in pairs(invSlots) do
        local invItem = slot.item
        if invItem and invItem:getValue("subtype") == "OmniHubModule" then
            local ikey = invItem:getValue("moduleKey")
            local def  = OmniHubModuleDefs.get(ikey)
            inventoryList[#inventoryList + 1] = {
                slotIndex = slotIndex,
                key       = ikey,
                name      = def and def.name or ikey,
            }
        end
    end

    invokeClientFunction(player, "receiveModuleData", installedList, inventoryList)
end

-- ────────────────────────────────────────────────────────────────
-- Dev-mode test runner (server-side)
-- ────────────────────────────────────────────────────────────────

-- Runs a test category ("pure" | "integration" | "all") against this live station, echoes a
-- summary to the server log and the requesting player's chat, and ships the per-test results
-- back to the client for display in the Tests tab. Gated on dev mode.
function OmniHub.runTests(category)
    if not onServer() then return end
    if not GameSettings().devMode then return end

    category = category or "all"

    local registry = include("lib/omnihub/tests/registry")
    local runner   = registry.run(category)
    local summary  = runner:summary()

    -- Server log (full report).
    print("[OmniHub] tests (" .. category .. "): "
        .. summary.passed .. " passed, " .. summary.failed .. " failed of " .. summary.total)
    print(runner:format())

    local player = Player(callingPlayer)
    if player then
        local msgType = (summary.failed == 0) and ChatMessageType.Information or ChatMessageType.Error
        player:sendChatMessage("OmniHub"%_t, msgType,
            "Tests (%1%): %2% passed, %3% failed"%_t, category, summary.passed, summary.failed)
        invokeClientFunction(player, "receiveTestResults", summary.results, category)
    end
end
callable(OmniHub, "runTests")

-- ────────────────────────────────────────────────────────────────
-- Client-side UI handles (module-local, not persisted)
-- ────────────────────────────────────────────────────────────────
local window        = nil
local tabbedWindow  = nil
local manageTab     = nil
local productionTab = nil
local testsTab      = nil

-- Manage tab UI state
local manageInstalledFrame = nil
local manageInventoryFrame = nil
local manageInstalledRows  = {}
local manageInventoryRows  = {}

-- Production tab UI state
local prodFrame = nil
local prodRows  = {}

-- Tests tab UI state (dev mode only)
local testsResultFrame = nil
local testsRows        = {}

-- Cached server data (client-side)
OmniHub.lastInstalledList = {}
OmniHub.lastInventoryList = {}
OmniHub.lastTestResults   = {}

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

    -- Dev-mode-only Tests tab. (F4's entitydbg.lua can't be cleanly extended, so the test
    -- runner lives in our own window instead.)
    if GameSettings().devMode then
        testsTab = tabbedWindow:createTab("Tests"%_t, "", "Run dev-mode tests"%_t)
        OmniHub.buildTestsTab(testsTab, size)
    end
end

function OmniHub.onShowWindow()
    invokeServerFunction("sendModuleData")
end

function OmniHub.onCloseWindow()
end

function OmniHub.buildManageTab(tab, windowSize)
    local padding = 10
    local tabSize = vec2(windowSize.x - 20, windowSize.y - 60)
    local splitter = UIHorizontalSplitter(Rect(vec2(0, 0), tabSize), padding, padding, 0.5)

    tab:createFrame(splitter.top)
    local topLabel = tab:createLabel(splitter.top.lower + vec2(5, 2), "Installed Modules"%_t, 14)
    topLabel.bold  = true
    manageInstalledFrame = tab:createScrollFrame(
        Rect(splitter.top.lower + vec2(padding, 22), splitter.top.upper - vec2(padding, padding))
    )
    manageInstalledFrame.scrollSpeed = 30

    tab:createFrame(splitter.bottom)
    local botLabel = tab:createLabel(splitter.bottom.lower + vec2(5, 2), "Modules in Inventory"%_t, 14)
    botLabel.bold  = true
    manageInventoryFrame = tab:createScrollFrame(
        Rect(splitter.bottom.lower + vec2(padding, 22), splitter.bottom.upper - vec2(padding, padding))
    )
    manageInventoryFrame.scrollSpeed = 30
end

function OmniHub.buildProductionTab(tab, windowSize)
    local padding = 10
    local size    = vec2(windowSize.x - 20, windowSize.y - 60)
    tab:createFrame(Rect(vec2(0, 0), size))
    prodFrame = tab:createScrollFrame(
        Rect(vec2(padding, padding), size - vec2(padding, padding))
    )
    prodFrame.scrollSpeed = 30
end

function OmniHub.buildTestsTab(tab, windowSize)
    local padding = 10
    local size    = vec2(windowSize.x - 20, windowSize.y - 60)

    -- Three run buttons across the top.
    local btnH = 30
    local btnW = math.floor((size.x - padding * 2) / 3)
    local defs = {
        { caption = "Run All"%_t,         func = "onRunAllTestsPress" },
        { caption = "Run Pure"%_t,        func = "onRunPureTestsPress" },
        { caption = "Run Integration"%_t, func = "onRunIntegrationTestsPress" },
    }
    for i, d in ipairs(defs) do
        local x   = (i - 1) * btnW
        local btn = tab:createButton(Rect(vec2(x, 0), vec2(x + btnW, btnH)), d.caption, d.func)
        btn.uppercase = false
    end

    -- Results frame below the buttons.
    local top = btnH + padding
    tab:createFrame(Rect(vec2(0, top), size))
    testsResultFrame = tab:createScrollFrame(
        Rect(vec2(padding, top + padding), size - vec2(padding, padding))
    )
    testsResultFrame.scrollSpeed = 30
end

function OmniHub.refreshManageUI()
    OmniHub._btnKey = {}   -- clear stale button→key mappings
    if not manageInstalledFrame or not manageInventoryFrame then return end

    -- Hide and clear installed rows
    for _, row in ipairs(manageInstalledRows) do
        if row.label  then row.label:hide()  end
        if row.button then row.button:hide() end
    end
    manageInstalledRows = {}

    local rowH  = 28
    local pad   = 5
    local width = manageInstalledFrame.size.x - pad * 2
    local list  = OmniHub.lastInstalledList

    for i, entry in ipairs(list) do
        local y    = pad + (i - 1) * (rowH + pad)
        local rect = Rect(vec2(pad, y), vec2(pad + width, y + rowH))
        local vsplit = UIVerticalSplitter(rect, pad, 0, 0.75)
        vsplit.rightSize = 90

        local label = manageInstalledFrame:createLabel(
            vsplit.left.lower,
            entry.name .. " \xC3\x97" .. entry.count,
            13
        )
        label.size = vsplit.left.size
        label:setLeftAligned()

        local btn = manageInstalledFrame:createButton(vsplit.right, "Uninstall"%_t, "onUninstallButtonPress")
        OmniHub._btnKey[btn.index] = entry.key

        manageInstalledRows[#manageInstalledRows + 1] = {label = label, button = btn, key = entry.key}
    end

    -- Hide and clear inventory rows
    for _, row in ipairs(manageInventoryRows) do
        if row.label  then row.label:hide()  end
        if row.button then row.button:hide() end
    end
    manageInventoryRows = {}

    local invList = OmniHub.lastInventoryList

    for i, entry in ipairs(invList) do
        local y    = pad + (i - 1) * (rowH + pad)
        local rect = Rect(vec2(pad, y), vec2(pad + width, y + rowH))
        local vsplit = UIVerticalSplitter(rect, pad, 0, 0.75)
        vsplit.rightSize = 80

        local label = manageInventoryFrame:createLabel(
            vsplit.left.lower,
            entry.name,
            13
        )
        label.size = vsplit.left.size
        label:setLeftAligned()

        local btn = manageInventoryFrame:createButton(vsplit.right, "Install"%_t, "onInstallButtonPress")
        OmniHub._btnKey[btn.index] = tostring(entry.slotIndex)

        manageInventoryRows[#manageInventoryRows + 1] = {
            label     = label,
            button    = btn,
            slotIndex = entry.slotIndex,
            key       = entry.key,
        }
    end
end

function OmniHub.onInstallButtonPress(button)
    OmniHub._btnKey = OmniHub._btnKey or {}
    local val = OmniHub._btnKey[button.index]
    local slotIndex = tonumber(val)
    if slotIndex then
        invokeServerFunction("installModule", slotIndex)
    end
end

function OmniHub.onUninstallButtonPress(button)
    OmniHub._btnKey = OmniHub._btnKey or {}
    local key = OmniHub._btnKey[button.index]
    if key and key ~= "" then
        invokeServerFunction("uninstallModule", key)
    end
end

function OmniHub.refreshProductionUI()
    if not prodFrame then return end

    for _, row in ipairs(prodRows) do
        if row.label  then row.label:hide()  end
        if row.label2 then row.label2:hide() end
    end
    prodRows = {}

    local rowH  = 40
    local pad   = 5
    local width = prodFrame.size.x - pad * 2
    local list  = OmniHub.lastInstalledList

    for i, entry in ipairs(list) do
        local def  = OmniHubModuleDefs.get(entry.key)
        local prod = def and OmniHubModuleDefs.resolveRecipe(entry.key)
        if def and prod then
            local y     = pad + (i - 1) * (rowH + pad)
            local lower = vec2(pad, y)

            -- Line 1: "FactoryName ×count"
            local line1  = def.name .. " \xC3\x97" .. entry.count
            local label1 = prodFrame:createLabel(lower, line1, 13)
            label1.size  = vec2(width, 20)
            label1:setLeftAligned()

            -- Line 2: "Produces: Nx GoodName, ..."
            -- %_t is Avorion's string translation metamethod — EmmyLua can't model it.
            ---@diagnostic disable: undefined-global
            local parts = {}
            for _, res in pairs(prod.results) do
                parts[#parts + 1] = (res.amount * entry.count) .. "\xC3\x97 " .. res.name%_t
            end
            local line2  = "Produces: "%_t .. table.concat(parts, ", ")
            ---@diagnostic enable: undefined-global
            local label2 = prodFrame:createLabel(lower + vec2(0, 20), line2, 11)
            label2.size  = vec2(width, 18)
            label2:setLeftAligned()

            prodRows[#prodRows + 1] = {label = label1, label2 = label2}
        end
    end
end

-- Called by server RPC response — stub until Task 6
function OmniHub.receiveModuleData(installedList, inventoryList)
    OmniHub.lastInstalledList = installedList or {}
    OmniHub.lastInventoryList = inventoryList or {}
    OmniHub.refreshManageUI()
    OmniHub.refreshProductionUI()
end

-- ────────────────────────────────────────────────────────────────
-- Tests tab (client) — buttons request a server run; results render here
-- ────────────────────────────────────────────────────────────────

function OmniHub.onRunAllTestsPress(button)
    invokeServerFunction("runTests", "all")
end

function OmniHub.onRunPureTestsPress(button)
    invokeServerFunction("runTests", "pure")
end

function OmniHub.onRunIntegrationTestsPress(button)
    invokeServerFunction("runTests", "integration")
end

function OmniHub.refreshTestsUI()
    if not testsResultFrame then return end

    for _, row in ipairs(testsRows) do
        if row.label then row.label:hide() end
    end
    testsRows = {}

    local rowH   = 22
    local pad    = 4
    local width  = testsResultFrame.size.x - pad * 2
    local list   = OmniHub.lastTestResults or {}
    local passed, failed = 0, 0

    for i, r in ipairs(list) do
        local y      = pad + (i - 1) * (rowH + 2)
        local status = r.ok and "PASS" or "FAIL"
        local text   = status .. "  " .. (r.suite or "") .. " :: " .. (r.name or "")
        if not r.ok and r.err then text = text .. "  - " .. r.err end

        local label = testsResultFrame:createLabel(vec2(pad, y), text, 12)
        label.size  = vec2(width, rowH)
        label:setLeftAligned()
        if r.ok then
            label.color = ColorRGB(0.5, 1.0, 0.5)
            passed = passed + 1
        else
            label.color = ColorRGB(1.0, 0.5, 0.5)
            failed = failed + 1
        end
        testsRows[#testsRows + 1] = {label = label}
    end

    local y       = pad + #list * (rowH + 2)
    local sumText = passed .. " passed, " .. failed .. " failed, " .. #list .. " total"
    local sumLabel = testsResultFrame:createLabel(vec2(pad, y), sumText, 13)
    sumLabel.size = vec2(width, rowH)
    sumLabel:setLeftAligned()
    sumLabel.bold = true
    testsRows[#testsRows + 1] = {label = sumLabel}
end

-- Called by the server after a test run.
function OmniHub.receiveTestResults(results, category)
    OmniHub.lastTestResults = results or {}
    OmniHub.refreshTestsUI()
end

return OmniHub
