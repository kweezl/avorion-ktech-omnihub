package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("faction")
include("callable")
local ShopAPI = include("shop")
local OmniHubConfig  = include("lib/omnihub/config")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHubSupplier
OmniHubSupplier = ShopAPI.CreateNamespace()

-- ────────────────────────────────────────────────────────────────
-- Station identity
-- ────────────────────────────────────────────────────────────────
function OmniHubSupplier.interactionPossible(playerIndex, option)
    return CheckFactionInteraction(playerIndex, -10000)
end

function OmniHubSupplier.getIcon()
    return "data/textures/icons/factory.png"
end

function OmniHubSupplier.initialize()
    local entity = Entity()
    if entity.title == "" then
        entity.title = "OmniHub Supplier"%_t
    end
    OmniHubSupplier.shop:initialize("OmniHub Supplier"%_t)
end

-- ────────────────────────────────────────────────────────────────
-- Module shop — ShopAPI calls this to populate the shop shelf
-- ────────────────────────────────────────────────────────────────

-- Build a Random-backed rng(hi) -> int in [1, hi]. A fresh random() each restock rotates the stock.
local function makeRng()
    local r = random()
    return function(hi)
        if hi < 1 then return 1 end
        return r:getInt(1, hi)
    end
end

function OmniHubSupplier.shop:addItems()
    local priceFactor = OmniHubConfig.get("modulePriceFactor")
    local count       = OmniHubConfig.get("sellingModuleCount")
    local catalog     = OmniHubModuleDefs.getCatalog()

    -- Catalog keys as an array, so the pure picker can sample distinct entries.
    local keys = {}
    for key in pairs(catalog) do keys[#keys + 1] = key end

    local rng     = makeRng()
    local subset  = OmniHubSupplierStock.pickRandomSubset(keys, count, rng)
    local offerKey = OmniHubSupplierStock.pickSpecialOffer(subset, rng)

    for _, key in ipairs(subset) do
        local def  = catalog[key]
        local item = UsableInventoryItem(
            "data/scripts/items/omnihubmodule.lua",
            Rarity(RarityType.Common),
            key
        )
        item.price = math.ceil(def.price * priceFactor)
        if key == offerKey then
            self:setSpecialOffer(item, 1)
        else
            self:add(item, 99)
        end
    end
end

-- ────────────────────────────────────────────────────────────────
-- Client UI — engine calls this on the client after initialize().
-- shop:initUI registers the interaction window (which creates the
-- interaction-menu option) and builds the Buy tab. Without it, no
-- menu entry appears when the player interacts with the station.
-- ────────────────────────────────────────────────────────────────
function OmniHubSupplier.initUI()
    OmniHubSupplier.shop:initUI(
        "Buy Modules"%_t,                    -- interaction-menu caption
        "OmniHub Supplier"%_t,               -- window caption
        "Modules"%_t,                        -- Buy tab caption
        "data/textures/icons/factory.png",   -- Buy tab icon
        {showAmountBoxes = true}
    )
    -- Supplier only sells modules to the player — hide the Sell/Buyback tabs.
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.sellTab)
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.buyBackTab)

    -- Dev-mode-only: a button to force a restock (re-roll subset + special offer) without waiting
    -- for the ~20-min special-offer timer. Created on the Buy tab; bound to a namespace callback.
    if GameSettings().devMode then
        local tab  = OmniHubSupplier.shop.buyTab
        local size = tab.size
        OmniHubSupplier.refreshButton = tab:createButton(
            Rect(size.x - 170, size.y - 40, size.x - 10, size.y - 12),
            "Refresh Stock"%_t, "onRefreshStockPressed")
        OmniHubSupplier.refreshButton.maxTextSize = 14
    end
end

-- ────────────────────────────────────────────────────────────────
-- Dev-only Refresh Stock (dev mode gated on BOTH sides)
-- ────────────────────────────────────────────────────────────────

-- Client: the Buy-tab button callback. Resolved by name on the OmniHubSupplier namespace.
function OmniHubSupplier.onRefreshStockPressed()
    if not GameSettings().devMode then return end
    invokeServerFunction("omniRefreshStock")
end

-- Server: re-roll the shop stock and broadcast it to clients.
function OmniHubSupplier.omniRefreshStock()
    if not onServer() then return end
    if not GameSettings().devMode then return end
    OmniHubSupplier.shop:restock()  -- restock() re-runs addItems + broadcasts the new items
end
callable(OmniHubSupplier, "omniRefreshStock")

return OmniHubSupplier
