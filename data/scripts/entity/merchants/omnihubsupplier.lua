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
end

return OmniHubSupplier
