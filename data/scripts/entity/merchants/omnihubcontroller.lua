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
-- Stubs called in update() — implemented in Tasks 6 & 7
-- ────────────────────────────────────────────────────────────────
function OmniHub.rebuild() end
function OmniHub.runProductionCycles(timeStep) end
function OmniHub.requestTraders(timeStep) end
function OmniHub.computeTimeToProduce(key) return MIN_TIME_TO_PRODUCE end

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
