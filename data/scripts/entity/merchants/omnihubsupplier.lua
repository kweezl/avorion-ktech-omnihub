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

-- Buy-tab paging. With the special-offer header (headerY = 70) the tab fits ~14 rows above the pager
-- controls, so show up to that many without a pager; beyond it, paginate at this many per page so the
-- rows never reach (and swallow clicks on) the pager row at the bottom of the tab.
local BUY_NO_PAGER_LIMIT = 14
local BUY_PAGE_SIZE      = 12

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
    local stockMin    = OmniHubConfig.get("stockMin")
    local stockMax    = OmniHubConfig.get("stockMax")
    local catalog     = OmniHubModuleDefs.getCatalog()

    -- Catalog keys as an array, so the pure picker can sample distinct entries. pickRandomSubset
    -- clamps `count` to #keys, so the effective cap is the number of available factory recipes.
    local keys = {}
    for key in pairs(catalog) do keys[#keys + 1] = key end

    local rng      = makeRng()
    local subset   = OmniHubSupplierStock.pickRandomSubset(keys, count, rng)
    local offerKey = OmniHubSupplierStock.pickSpecialOffer(subset, rng)

    for _, key in ipairs(subset) do
        local def  = catalog[key]
        local item = UsableInventoryItem(
            "data/scripts/items/omnihubmodule.lua",
            Rarity(RarityType.Common),
            key
        )
        item.price = math.ceil(def.price * priceFactor)
        local stock = OmniHubSupplierStock.rollStock(stockMin, stockMax, rng)  -- random per module
        if key == offerKey then
            self:setSpecialOffer(item, stock)
        else
            self:add(item, stock)
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

    -- Buy-tab pagination controls. Shown only when stock exceeds one page (updated in updateSellGui).
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = 0
    local tab  = shop.buyTab
    local size = tab.size
    shop.prevPageButton = tab:createButton(Rect(10, size.y - 40, 70, size.y - 12), "<", "onPrevPagePressed")
    shop.nextPageButton = tab:createButton(Rect(80, size.y - 40, 140, size.y - 12), ">", "onNextPagePressed")
    shop.pageLabelBuy   = tab:createLabel(vec2(150, size.y - 38), "", 14)
    shop.prevPageButton:hide()
    shop.nextPageButton:hide()
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

-- ────────────────────────────────────────────────────────────────
-- Buy-tab pagination (override of the vanilla single-page sold-items render)
-- ────────────────────────────────────────────────────────────────

function OmniHubSupplier.onPrevPagePressed()
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = (shop.soldItemsPage or 0) - 1
    shop:updateSellGui()
end

function OmniHubSupplier.onNextPagePressed()
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = (shop.soldItemsPage or 0) + 1
    shop:updateSellGui()
end

-- Reset to the first page each time the shop window opens. Vanilla onShowWindow resets the Sell
-- tab's page but knows nothing about our Buy-tab pager, so reopening could land on a stale page.
local base_onShowWindow = OmniHubSupplier.shop.onShowWindow
function OmniHubSupplier.shop:onShowWindow(...)
    self.soldItemsPage = 0
    return base_onShowWindow(self, ...)
end

-- Reset to the first page whenever fresh stock arrives from the server (e.g. after a restock/Refresh
-- Stock), so the player isn't stranded on a now-out-of-range page.
local base_receiveSoldItems = OmniHubSupplier.shop.receiveSoldItems
function OmniHubSupplier.shop:receiveSoldItems(...)
    self.soldItemsPage = 0
    return base_receiveSoldItems(self, ...)
end

-- Resolve a module item's display name WITHOUT item:getName(). For UsableItems, the vanilla
-- SellableInventoryItem:getName reads the tooltip's first line on the client — but our module items'
-- tooltips don't survive the shop's network sync, so getName() throws ("Tooltip:getLine range_check")
-- and aborts the whole render. Resolve from the stored moduleKey via the catalog (reliable in this
-- entity VM), falling back to the plain name, then a constant.
local function moduleDisplayName(item)
    local inner = item and item.item
    if inner and inner.getValue then
        local ok, key = pcall(inner.getValue, inner, "moduleKey")
        if ok and key and key ~= "" then
            local def = OmniHubModuleDefs.get(key)
            if def and def.name then return def.name end
        end
    end
    local n = item and item.name
    if n ~= nil and n ~= "" then return n end
    return "OmniHub Module"
end

-- Paged replacement for Shop:updateSellGui. Renders only the current page of soldItems onto the
-- fixed soldItemLines, plus the pager controls. Mirrors the vanilla per-line population, but maps
-- the page slice onto lines 1..itemsPerPage. Special offer (specialOfferUI) is left to vanilla,
-- which our override calls through for everything except the sold-line loop.
function OmniHubSupplier.shop:updateSellGui()
    if not self.guiInitialized then return end

    for _, line in pairs(self.soldItemLines) do line:hide() end
    if self.specialOfferUI then self.specialOfferUI:toSoldOut() end

    local faction = Faction()
    local buyer   = Player()
    local craft   = buyer.craft
    if craft and craft.factionIndex == buyer.allianceIndex then buyer = buyer.alliance end

    local total = #self.soldItems
    if total == 0 then
        local topLine = self.soldItemLines[1]
        topLine.nameLabel:show()
        topLine.nameLabel.color = ColorRGB(1.0, 1.0, 1.0)
        topLine.nameLabel.bold = false
        topLine.nameLabel.caption = "We are completely sold out."%_t
    end

    local perPage = (total > BUY_NO_PAGER_LIMIT) and BUY_PAGE_SIZE or self.itemsPerPage
    local itemStart, itemEnd, page = OmniHubSupplierStock.pageSlice(total, perPage, self.soldItemsPage or 0)
    self.soldItemsPage = page

    local uiIndex = 1
    for index = itemStart, itemEnd do
        local item = self.soldItems[index]
        if item == nil then break end
        local line = self.soldItemLines[uiIndex]
        line:show()

        line.nameLabel.caption = moduleDisplayName(item)%_t
        line.nameLabel.color = item.rarity.color
        line.nameLabel.bold = false

        if item.material then
            line.materialLabel.caption = item.material.name
            line.materialLabel.color = item.material.color
        else
            line.materialLabel:hide()
        end

        if item.icon then
            line.icon.picture = item.icon
            line.icon.color = item.rarity.color
        end

        if item.displayedPrice then
            line.priceLabel.caption = item.displayedPrice
        else
            local price = self:getSellPriceAndTax(item.price, faction, buyer)
            line.priceLabel.caption = createMonetaryString(price)
        end
        line.priceReductionLabel:hide()

        line.stockLabel.caption = item.amount
        line.techLabel.caption = item.tech or ""

        local msg, args = self:canBeBought(item, craft, buyer)
        if msg then
            line.button.active = false
            line.button.tooltip = string.format(msg%_t, unpack(args or {}))
        else
            line.button.active = true
            line.button.tooltip = nil
        end

        uiIndex = uiIndex + 1
    end

    -- Pager visibility + label.
    local multiPage = total > BUY_NO_PAGER_LIMIT
    if self.prevPageButton then
        if multiPage then
            self.prevPageButton:show(); self.nextPageButton:show()
            self.prevPageButton.active = page > 0
            local maxPage = math.max(0, math.ceil(total / perPage) - 1)
            self.nextPageButton.active = page < maxPage
            self.pageLabelBuy.caption = string.format("%d - %d / %d", itemStart, itemEnd, total)
        else
            self.prevPageButton:hide(); self.nextPageButton:hide()
            self.pageLabelBuy.caption = ""
        end
    end

    -- Re-render the special offer exactly as vanilla does (kept identical to Shop:updateSellGui).
    local offer = self.specialOffer.item
    if offer and self.specialOfferUI then
        local specialUI = self.specialOfferUI
        specialUI:show()
        specialUI.nameLabel.caption = moduleDisplayName(offer)%_t
        specialUI.nameLabel.color = offer.rarity.color
        specialUI.nameLabel.bold = false
        if offer.material then
            specialUI.materialLabel.caption = offer.material.name
            specialUI.materialLabel.color = offer.material.color
        else
            specialUI.materialLabel:hide()
        end
        if offer.icon then
            specialUI.icon.picture = offer.icon
            specialUI.icon.color = offer.rarity.color
        end
        if offer.amount then specialUI.stockLabel.caption = offer.amount end
        specialUI.techLabel.caption = offer.tech or ""
        specialUI.timeLeftLabel.caption = "LIMITED TIME OFFER!"%_t
        specialUI.label.caption = "SPECIAL OFFER: -30% OFF"%_t
        local price = self:getSellPriceAndTax(offer.price, faction, buyer)
        specialUI.priceLabel.caption = createMonetaryString(price * 0.7)
        specialUI.priceReductionLabel.caption = "${percentage} OFF!"%_t % {percentage = "30%"}
        local msg, args = self:canBeBought(offer, craft, buyer)
        if msg then
            specialUI.button.active = false
            specialUI.button.tooltip = string.format(msg%_t, unpack(args or {}))
        else
            specialUI.button.active = true
            specialUI.button.tooltip = nil
        end
    end
end

return OmniHubSupplier
