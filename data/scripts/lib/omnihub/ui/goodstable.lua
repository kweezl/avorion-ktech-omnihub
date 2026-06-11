package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
local OmniHubUICommon      = include("ui/common")
local OmniHubSupplierStock = include("supplierstock")  -- tested pageSlice (clamp/bounds)

-- namespace OmniHubGoodsTable
-- Client-only unified Goods table (merges the old Products + Resources tabs). One row per good with:
-- NAME (icon+name) | STOCK | PRATE actual/max | CRATE actual/max | SP | BP | MARKET | BUY | SELL.
-- Styled like the vanilla Buy/Sell tables (header y=0, rows at y=30, 35px pitch, 29px icon, font 15),
-- full-width, vertically-centred cells, fixed reusable row pool, paged. Renders SERVER-computed values
-- only; the controller wires the checkbox/pager handler names and reads back via :goodForCheckbox().
OmniHubGoodsTable = {}
OmniHubGoodsTable.__index = OmniHubGoodsTable

local PER_PAGE  = 14
local FONT      = 15
local HEADER_Y  = 0
local ROWS_TOP  = 30
local ROW_PITCH = 35
local FRAME_H   = 30
local ICON_W    = 29

-- Colours are built lazily inside the helpers (ColorRGB is engine-only — calling it at module load
-- would break the off-engine test VM).

-- Adaptive precision so slow goods (long, expensive cycles -> tiny rates) don't collapse to "0.0".
local function fmtNum(v)
    v = v or 0
    if v <= 0   then return "0" end
    if v < 1    then return string.format("%.2f", v) end
    if v < 10   then return string.format("%.1f", v) end
    return string.format("%.0f", v)
end

-- "actual/max" per minute, or "-" when the good has no rate in that role.
local function fmtRate(actual, max)
    if (max or 0) <= 0 then return "-" end
    return fmtNum(actual) .. "/" .. fmtNum(max)
end

-- Green at/near capacity, amber partial, orange idle/starved, grey when not in this role.
local function rateColor(actual, max)
    if (max or 0) <= 0 then return ColorRGB(0.55, 0.55, 0.55) end
    if (actual or 0) >= max * 0.95 then return ColorRGB(0.5, 1.0, 0.5) end
    if (actual or 0) <= 0 then return ColorRGB(1.0, 0.6, 0.3) end
    return ColorRGB(1.0, 0.85, 0.45)
end

local function fmtPrice(p) return "\xC2\xA2" .. createMonetaryString(p or 0) end

-- Blue (+) = regional demand (prices up); green (-) = regional supply (prices down); grey = neutral.
local function marketColor(pct)
    pct = pct or 0
    if pct > 0 then return ColorRGB(0.45, 0.65, 1.0) end
    if pct < 0 then return ColorRGB(0.4, 1.0, 0.4) end
    return ColorRGB(0.55, 0.55, 0.55)
end

local function hideRow(r)
    r.frame:hide(); r.icon:hide(); r.name:hide(); r.stock:hide(); r.prate:hide(); r.crate:hide()
    r.sp:hide(); r.bp:hide(); r.market:hide(); r.buyCb:hide(); r.sellCb:hide()
end
local function showRow(r)
    r.frame:show(); r.icon:show(); r.name:show(); r.stock:show(); r.prate:show(); r.crate:show()
    r.sp:show(); r.bp:show(); r.market:show(); r.buyCb:show(); r.sellCb:show()
end

-- new(tab, size, opts). opts carries per-column header text + tooltips (nameHeader/nameTip,
-- prate*, crate*, sp*, bp*, market*, buy*, sell*), per-row checkbox tooltips (buyTooltip/sellTooltip),
-- and handler NAME strings (sellCallback, buyCallback, prevCallback, nextCallback).
function OmniHubGoodsTable.new(tab, size, opts)
    local self = setmetatable({}, OmniHubGoodsTable)
    self.opts    = opts
    self.data    = {}
    self.page    = 0
    self.rows    = {}
    self.sellCb  = {}   -- checkbox.index -> good name (sell)
    self.buyCb   = {}   -- checkbox.index -> good name (buy)

    -- Column geometry across the full tab width; numeric columns + checkboxes hug the right.
    local W = (tab.size and tab.size.x) or (size.x - 30)
    local ICON_X   = 10
    local NAME_X   = ICON_X + ICON_W + 9
    local CB_W     = 24
    local SELL_X   = W - 16 - CB_W
    local BUY_X    = SELL_X - 52
    local MARKET_R = BUY_X - 22
    local MARKET_L = MARKET_R - 56
    local BP_R     = MARKET_L - 14
    local BP_L     = BP_R - 74
    local SP_R     = BP_L - 14
    local SP_L     = SP_R - 74
    local CRATE_R  = SP_L - 14
    local CRATE_L  = CRATE_R - 82
    local PRATE_R  = CRATE_L - 14
    local PRATE_L  = PRATE_R - 82
    local STOCK_R  = PRATE_L - 14
    local STOCK_L  = STOCK_R - 70
    local NAME_RIGHT = STOCK_L - 12
    local ROW_RIGHT  = W - 2

    self.cols = {
        ICON_X = ICON_X, NAME_X = NAME_X, NAME_RIGHT = NAME_RIGHT,
        STOCK_L = STOCK_L, STOCK_R = STOCK_R,
        PRATE_L = PRATE_L, PRATE_R = PRATE_R, CRATE_L = CRATE_L, CRATE_R = CRATE_R,
        SP_L = SP_L, SP_R = SP_R, BP_L = BP_L, BP_R = BP_R,
        MARKET_L = MARKET_L, MARKET_R = MARKET_R, BUY_X = BUY_X, SELL_X = SELL_X, CB_W = CB_W,
        ROW_RIGHT = ROW_RIGHT,
    }

    -- Header row (uppercase, tooltipped).
    local nameH = tab:createLabel(vec2(NAME_X, HEADER_Y), string.upper(opts.nameHeader or "Name"), FONT)
    nameH.tooltip = opts.nameTip
    local function rh(x1, x2, caption, tip)
        local l = tab:createLabel(Rect(x1, HEADER_Y, x2, HEADER_Y + 30), string.upper(caption or ""), FONT)
        l:setTopRightAligned()
        l.tooltip = tip
    end
    rh(STOCK_L,  STOCK_R,  opts.stockHeader,  opts.stockTip)
    rh(PRATE_L,  PRATE_R,  opts.prateHeader,  opts.prateTip)
    rh(CRATE_L,  CRATE_R,  opts.crateHeader,  opts.crateTip)
    rh(SP_L,     SP_R,     opts.spHeader,     opts.spTip)
    rh(BP_L,     BP_R,     opts.bpHeader,     opts.bpTip)
    rh(MARKET_L, MARKET_R, opts.marketHeader, opts.marketTip)
    rh(BUY_X - 40,  BUY_X + CB_W,  opts.buyHeader,  opts.buyTip)
    rh(SELL_X - 44, SELL_X + CB_W, opts.sellHeader, opts.sellTip)

    -- Fixed reusable row pool. Every cell is a full-row-height Rect with a vertically-centring
    -- alignment so text lines up with the icon.
    for i = 1, PER_PAGE do
        local top = ROWS_TOP + (i - 1) * ROW_PITCH
        local bot = top + FRAME_H

        local frame = tab:createFrame(Rect(vec2(0, top), vec2(ROW_RIGHT, bot)))

        local iconTop = top + math.floor((FRAME_H - ICON_W) / 2)
        local icon = tab:createPicture(Rect(vec2(ICON_X, iconTop), vec2(ICON_X + ICON_W, iconTop + ICON_W)), "")
        icon.isIcon = true

        local name = tab:createLabel(Rect(vec2(NAME_X, top), vec2(NAME_RIGHT, bot)), "", FONT)
        name:setLeftAligned(); name.shortenText = true

        local function num(x1, x2)
            local l = tab:createLabel(Rect(vec2(x1, top), vec2(x2, bot)), "", FONT)
            l:setRightAligned()
            return l
        end
        local stock  = num(STOCK_L, STOCK_R)
        local prate  = num(PRATE_L, PRATE_R)
        local crate  = num(CRATE_L, CRATE_R)
        local sp     = num(SP_L, SP_R)
        local bp     = num(BP_L, BP_R)
        local market = num(MARKET_L, MARKET_R)

        local cbTop = top + math.floor((FRAME_H - CB_W) / 2)
        local buyCb = tab:createCheckBox(Rect(vec2(BUY_X, cbTop), vec2(BUY_X + CB_W, cbTop + CB_W)), "", opts.buyCallback)
        buyCb.tooltip = opts.buyTooltip
        local sellCb = tab:createCheckBox(Rect(vec2(SELL_X, cbTop), vec2(SELL_X + CB_W, cbTop + CB_W)), "", opts.sellCallback)
        sellCb.tooltip = opts.sellTooltip

        local row = { frame = frame, icon = icon, name = name, stock = stock, prate = prate,
                      crate = crate, sp = sp, bp = bp, market = market, buyCb = buyCb, sellCb = sellCb }
        hideRow(row)
        self.rows[i] = row
    end

    -- Pager. Prev and Next are the same width (60), Next right-aligned to the table edge.
    local py    = ROWS_TOP + PER_PAGE * ROW_PITCH + 8
    local right = SELL_X + CB_W
    self.prevBtn   = tab:createButton(Rect(vec2(10, py), vec2(70, py + 26)), "<", opts.prevCallback)
    self.nextBtn   = tab:createButton(Rect(vec2(right - 60, py), vec2(right, py + 26)), ">", opts.nextCallback)
    self.pageLabel = tab:createLabel(Rect(vec2(80, py), vec2(right - 70, py + 26)), "", 14)
    self.pageLabel:setCenterAligned()
    self.prevBtn.uppercase = false
    self.nextBtn.uppercase = false

    return self
end

function OmniHubGoodsTable:setData(rows)
    self.data   = rows or {}
    self.byName = {}                       -- name -> entry, for O(1) patch / setEnabled
    for _, d in ipairs(self.data) do self.byName[d.name] = d end
    self:render()
end

function OmniHubGoodsTable:nextPage() self.page = self.page + 1; self:render() end
function OmniHubGoodsTable:prevPage() self.page = self.page - 1; self:render() end

function OmniHubGoodsTable:render()
    self.sellCb = {}
    self.buyCb  = {}
    local total = #self.data
    local s, e, page = OmniHubSupplierStock.pageSlice(total, PER_PAGE, self.page)
    self.page = page

    for i = 1, PER_PAGE do
        local row = self.rows[i]
        local idx = s + i - 1
        local d   = (s > 0 and idx <= e) and self.data[idx] or nil
        if d then
            row.icon.picture = d.icon or ""
            row.name.caption = d.name or "?"

            -- Dim "-" when empty so the goods actually held in cargo pop out while scanning.
            if (d.stock or 0) > 0 then
                row.stock.caption = createMonetaryString(d.stock)
                row.stock.color   = ColorRGB(1.0, 1.0, 1.0)
            else
                row.stock.caption = "-"
                row.stock.color   = ColorRGB(0.55, 0.55, 0.55)
            end

            row.prate.caption = fmtRate(d.prateActual, d.prateMax)
            row.prate.color   = rateColor(d.prateActual, d.prateMax)
            row.crate.caption = fmtRate(d.crateActual, d.crateMax)
            row.crate.color   = rateColor(d.crateActual, d.crateMax)

            row.sp.caption = fmtPrice(d.sellPrice)
            row.bp.caption = fmtPrice(d.buyPrice)

            row.market.caption = OmniHubUICommon.formatPct(d.marketPct)
            row.market.color   = marketColor(d.marketPct)

            row.buyCb:setCheckedNoCallback(d.buyEnabled ~= false)
            row.sellCb:setCheckedNoCallback(d.sellEnabled ~= false)
            self.buyCb[row.buyCb.index]   = d.name
            self.sellCb[row.sellCb.index] = d.name

            showRow(row)
        else
            hideRow(row)
        end
    end

    local pages = math.max(1, math.ceil(math.max(0, total) / PER_PAGE))
    self.pageLabel.caption = (total == 0) and "(none)"%_t
        or string.format("Page %d / %d (%d)", page + 1, pages, total)
    self.prevBtn.active = page > 0
    self.nextBtn.active = e < total
end

-- Resolve a toggled checkbox back to its good + side. The controller calls one of these from its
-- buy/sell change handlers.
function OmniHubGoodsTable:goodForBuy(cb)  return self.buyCb[cb.index]  end
function OmniHubGoodsTable:goodForSell(cb) return self.sellCb[cb.index] end

-- Patches the rate fields of specific good rows (from an install/uninstall delta) and re-renders the
-- current page. O(#rows) via the name index. Install changes only rates (prices/market/marks are
-- unaffected), so we touch just those.
function OmniHubGoodsTable:patch(rows)
    local byName = self.byName or {}
    for _, r in ipairs(rows or {}) do
        local d = byName[r.name]
        if d then
            d.prateActual = r.prateActual
            d.prateMax    = r.prateMax
            d.crateActual = r.crateActual
            d.crateMax    = r.crateMax
        end
    end
    self:render()
end

-- Applies a periodic live tick (the 30s Goods-tab refresh): the server sends only goods with
-- nonzero stock or measured rates, so zero stock + rate ACTUALS everywhere first, then patch the
-- sent rows — an omitted good correctly renders empty/idle. Maxes are untouched (they change only
-- with installs, which go through :patch). Re-renders the current page.
function OmniHubGoodsTable:patchLive(rows)
    for _, d in ipairs(self.data) do
        d.stock, d.prateActual, d.crateActual = 0, 0, 0
    end
    local byName = self.byName or {}
    for _, r in ipairs(rows or {}) do
        local d = byName[r.name]
        if d then
            d.stock       = r.stock
            d.prateActual = r.prate
            d.crateActual = r.crate
        end
    end
    self:render()
end

-- Recomputes every row's SP/BP from base price x factor x regional market (client-side prediction
-- after a price-slider change), then re-renders. Display-only: it can differ by ~±1 credit from the
-- server's exact value (the Market % is rounded); the authoritative trade price stays server-side.
function OmniHubGoodsTable:setPriceFactors(sellFactor, buyFactor)
    local function r(x) return math.floor(x + 0.5) end
    for _, d in ipairs(self.data) do
        local g    = goods[d.name]
        local base = (g and g.price) or 0
        local sdf  = 1 + (d.marketPct or 0) / 100
        d.sellPrice = r(base * sellFactor * sdf)
        d.buyPrice  = r(base * buyFactor * sdf)
    end
    self:render()
end

-- Keep the cached enable state in sync with a toggle so paging doesn't snap the checkbox back. O(1).
function OmniHubGoodsTable:setEnabled(name, side, enabled)
    local d = self.byName and self.byName[name]
    if d then
        if side == "buy" then d.buyEnabled = enabled else d.sellEnabled = enabled end
    end
end

return OmniHubGoodsTable
