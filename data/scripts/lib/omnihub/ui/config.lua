package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubUIConfig
-- Client-only Configuration tab: actively-buy / actively-sell checkboxes, two price sliders
-- (buy/sell goods, ±20%), the per-good max-stock fields, and the dev-only debug checkbox (hidden
-- unless the server reports dev mode). Holds its own widget state and exposes read()/apply() for
-- the controller; the single change handler name (opts.changeCallback) is wired by the controller
-- to push config to the server.
OmniHubUIConfig = {}
OmniHubUIConfig.__index = OmniHubUIConfig

-- Maps a price factor (0.8..1.2) to slider units (-20..20) and back.
local function factorToSlider(f) return round(((f or 1.0) - 1.0) * 100) end
local function sliderToFactor(v) return 1.0 + (v or 0) / 100.0 end

-- Adds a captioned numeric text box (digits only) to a vertical lister and returns the box. NO
-- per-keystroke callback: committing every character round-trips to the server, which clamps/floors the
-- partial value and echoes it back, overwriting what you're typing. Instead the box commits on
-- focus-out / Enter — pollStockCommit (driven by the controller's updateClient) watches isTypingActive.
-- clearOnClick wipes the field on click so you can type a fresh value without deleting first.
function OmniHubUIConfig:numField(tab, lister, caption, tooltip)
    local lbl = tab:createLabel(Rect(), caption, 11)
    lbl.tooltip = tooltip
    lister:placeElementTop(lbl)

    local box = tab:createTextBox(Rect(), "")
    box.allowedCharacters = "0123456789"
    box.clearOnClick = 1
    box.tooltip = tooltip
    lister:placeElementTop(box)
    return box
end

-- Sets a stock box's text without stomping it while the player is typing, and records the shown value
-- as the committed baseline so pollStockCommit only fires on a real edit.
function OmniHubUIConfig:setStockBox(box, idx, val)
    if not box or box.isTypingActive then return end
    local text = (val ~= nil) and tostring(val) or ""
    box.text = text
    self.stockCommitted[idx] = text
end

-- Called each client tick by the controller. Commits a stock field once it LOSES focus (isTypingActive
-- false) with a value different from what was last committed — i.e. on focus-out or Enter, not per
-- keystroke. Returns true if anything changed (the controller then pushes the full config).
function OmniHubUIConfig:pollStockCommit()
    if not self.stockBoxes then return false end
    local changed = false
    for i, box in ipairs(self.stockBoxes) do
        if not box.isTypingActive and box.text ~= self.stockCommitted[i] then
            self.stockCommitted[i] = box.text
            changed = true
        end
    end
    return changed
end

function OmniHubUIConfig.new(tab, size, opts)
    local self = setmetatable({}, OmniHubUIConfig)
    self.opts            = opts

    local pad  = 10
    local left = UIVerticalLister(Rect(vec2(pad, pad), vec2(size.x - pad, size.y - 60)), 8, 0)

    self.activeBuyCheck = tab:createCheckBox(Rect(), "Actively buy goods"%_t, opts.changeCallback)
    left:placeElementTop(self.activeBuyCheck)
    self.activeBuyCheck.tooltip = "If checked, the hub summons traders to deliver the goods it needs when it runs low."%_t

    self.activeSellCheck = tab:createCheckBox(Rect(), "Actively sell goods"%_t, opts.changeCallback)
    left:placeElementTop(self.activeSellCheck)
    self.activeSellCheck.tooltip = "If checked, the hub summons traders to buy its goods when stocks get full."%_t

    self.eventsCheck = tab:createCheckBox(Rect(), "Send event notifications"%_t, opts.changeCallback)
    left:placeElementTop(self.eventsCheck)
    self.eventsCheck.tooltip = "If checked, the hub messages its owners in chat: a periodic trade summary, failed trades, and warnings when cargo, assembly, or ingredients hold production back."%_t

    left:nextRect(12)

    self.buyPriceLabel = tab:createLabel(Rect(), "Buy goods at 100%"%_t, 12)
    left:placeElementTop(self.buyPriceLabel)
    self.buyPriceLabel.centered = true
    -- Sliders update their % label live (priceMovedCallback) while dragging, but only commit to the
    -- server + recompute prices once, on mouse release (onMouseUpChangedFunction = priceCommitCallback).
    self.buyPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.buyPriceSlider)
    self.buyPriceSlider.unit = "%"
    self.buyPriceSlider:setValueNoCallback(0)
    self.buyPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.buyPriceSlider.tooltip = "Price the hub pays for goods it buys. A higher price attracts more sellers."%_t

    left:nextRect(6)

    self.sellPriceLabel = tab:createLabel(Rect(), "Sell goods at 100%"%_t, 12)
    left:placeElementTop(self.sellPriceLabel)
    self.sellPriceLabel.centered = true
    self.sellPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.sellPriceSlider)
    self.sellPriceSlider.unit = "%"
    self.sellPriceSlider:setValueNoCallback(0)
    self.sellPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.sellPriceSlider.tooltip = "Price the hub charges for goods it sells. A lower price attracts more buyers."%_t

    left:nextRect(12)

    -- ── Max goods stock (passthrough trade goods cap, in units) ──────────────
    local tradeHeader = tab:createLabel(Rect(), "Max goods stock (units)"%_t, 12)
    left:placeElementTop(tradeHeader); tradeHeader.centered = true

    self.tradeStockBox = self:numField(tab, left, "Max buy/sell goods stock"%_t,
        "Max units stocked of each good marked Buy or Sell that the hub neither produces nor consumes (a passthrough trade good). 0 = don't stockpile it."%_t)

    left:nextRect(6)

    -- ── Max production stock (produced/consumed goods cap) ───────────────────
    local prodHeader = tab:createLabel(Rect(), "Max production stock"%_t, 12)
    left:placeElementTop(prodHeader); prodHeader.centered = true

    self.prodBaseBox = self:numField(tab, left, "Production base"%_t,
        "Base multiplier for goods the hub produces or consumes. Max stock = base x cycles x the good's per-cycle amount across all modules."%_t)
    self.prodCyclesBox = self:numField(tab, left, "Production cycles"%_t,
        "How many production cycles of buffer to keep for produced/consumed goods. The hub stops a good's production once it reaches the max stock (or the cargo bay is full)."%_t)

    left:nextRect(12)

    -- Dev-only: production debug logging. ALWAYS built — at the bottom, so hiding it leaves no gap —
    -- but visible only when the SERVER reports dev mode in the config payload (see apply). The server
    -- stays authoritative: the client's own GameSettings().devMode reflects the locally persisted
    -- /devmode state, which can disagree with the server and goes stale (initUI runs once).
    self.debugCheck = tab:createCheckBox(Rect(), "Debug production logging (dev)"%_t, opts.changeCallback)
    left:placeElementTop(self.debugCheck)
    self.debugCheck.tooltip = "Dev only. Periodically prints each module's production state (active / stalled + reason) to the server log."%_t
    self.debugCheck.visible = false

    -- Ordered list + committed baseline for focus-out commits (see pollStockCommit).
    self.stockBoxes     = { self.tradeStockBox, self.prodBaseBox, self.prodCyclesBox }
    self.stockCommitted = { self.tradeStockBox.text, self.prodBaseBox.text, self.prodCyclesBox.text }

    return self
end

-- Applies a server config table to the widgets (no callbacks fire).
function OmniHubUIConfig:apply(cfg)
    if not cfg then return end
    self.activeBuyCheck:setCheckedNoCallback(cfg.activelyRequest ~= false)
    self.activeSellCheck:setCheckedNoCallback(cfg.activelySell ~= false)
    self.eventsCheck:setCheckedNoCallback(cfg.events ~= false)

    -- Server-authoritative dev gate, re-evaluated on every config sync. nil (older server build /
    -- missing key) fails closed: the checkbox stays hidden.
    self.debugCheck.visible = cfg.devMode == true
    self.debugCheck:setCheckedNoCallback(cfg.debug == true)

    self.buyPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorBuy))
    self.sellPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorSell))
    self:refreshPriceLabels()

    if self.stockBoxes then
        -- Skips any field currently being typed in (setStockBox), so the server echo never stomps it.
        self:setStockBox(self.tradeStockBox, 1, cfg.tradeStock)
        self:setStockBox(self.prodBaseBox,   2, cfg.prodBase)
        self:setStockBox(self.prodCyclesBox, 3, cfg.prodCycles)
    end
end

function OmniHubUIConfig:refreshPriceLabels()
    self.buyPriceLabel.caption  = "Buy goods at ${p}%"%_t  % { p = round(sliderToFactor(self.buyPriceSlider.value) * 100) }
    self.sellPriceLabel.caption = "Sell goods at ${p}%"%_t % { p = round(sliderToFactor(self.sellPriceSlider.value) * 100) }
end

-- Current price factors from the sliders: buyFactor, sellFactor (0.8..1.2).
function OmniHubUIConfig:readPrices()
    return sliderToFactor(self.buyPriceSlider.value), sliderToFactor(self.sellPriceSlider.value)
end

-- Reads the current widget state into a config table for the server.
function OmniHubUIConfig:read()
    self:refreshPriceLabels()
    -- Explicit boolean (NOT `check and check.checked or nil`): when the box is UNchecked, `checked` is
    -- false and the `and/or` trick collapses to nil, which the server reads as "keep current" — so the
    -- toggle could never be turned off. nil while the checkbox is hidden (non-dev), so a non-dev
    -- client can never clear a debug session a dev started.
    local debug = nil
    if self.debugCheck.visible then debug = self.debugCheck.checked == true end
    return {
        activelyRequest = self.activeBuyCheck.checked,
        activelySell    = self.activeSellCheck.checked,
        events          = self.eventsCheck.checked == true,
        priceFactorBuy  = sliderToFactor(self.buyPriceSlider.value),
        priceFactorSell = sliderToFactor(self.sellPriceSlider.value),
        -- tonumber("") -> nil; the server treats nil as "keep current" (nil-safe clamp).
        tradeStock = tonumber(self.tradeStockBox.text),
        prodBase   = tonumber(self.prodBaseBox.text),
        prodCycles = tonumber(self.prodCyclesBox.text),
        debug      = debug,
    }
end

return OmniHubUIConfig
