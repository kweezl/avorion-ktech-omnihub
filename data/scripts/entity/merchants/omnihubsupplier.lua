package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("faction")
include("callable")
local ShopAPI = include("shop")
local OmniHubConfig  = include("lib/omnihub/config")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")
local Dialog = include("dialogutility")

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
        InteractionText(entity.index).text = Dialog.generateStationInteractionText(entity, random())
    end
    if onServer() then
        OmniHubSupplier.shop:initialize("OmniHub Supplier"%_t)
    end
end

-- ────────────────────────────────────────────────────────────────
-- Module shop — ShopAPI calls this to populate the shop shelf
-- ────────────────────────────────────────────────────────────────
function OmniHubSupplier.shop:addItems()
    local priceFactor = OmniHubConfig.get("modulePriceFactor")
    local catalog     = OmniHubModuleDefs.getCatalog()

    for key, def in pairs(catalog) do
        local item = UsableInventoryItem(
            "data/scripts/items/omnihubmodule.lua",
            Rarity(RarityType.Common),
            key
        )
        item.price = math.ceil(def.price * priceFactor)
        self:add(item, 99)
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
        {showSpecialOffer = false, showAmountBoxes = true}
    )
    -- Supplier only sells modules to the player — hide the Sell/Buyback tabs.
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.sellTab)
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.buyBackTab)
end

return OmniHubSupplier
