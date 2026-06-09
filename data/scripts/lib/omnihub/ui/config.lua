package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubUIConfig
-- Client-only Configuration tab: actively-buy / actively-sell checkboxes, two base-price sliders
-- (buy resources, sell products; ±20%), and the per-good Max Limit fields. Holds its own widget state
-- and exposes read()/apply() for the controller; the single change handler name (opts.changeCallback)
-- is wired by the controller to push config to the server.
OmniHubUIConfig = {}
OmniHubUIConfig.__index = OmniHubUIConfig

-- Maps a price factor (0.8..1.2) to slider units (-20..20) and back.
local function factorToSlider(f) return round(((f or 1.0) - 1.0) * 100) end
local function sliderToFactor(v) return 1.0 + (v or 0) / 100.0 end

-- Adds a captioned numeric text box (digits only) to a vertical lister and returns the box. NO
-- per-keystroke callback: committing every character round-trips to the server, which clamps/floors the
-- partial value and echoes it back, overwriting what you're typing. Instead the box commits on
-- focus-out / Enter — pollLimitCommit (driven by the controller's updateClient) watches isTypingActive.
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

-- Sets a limit box's text without stomping it while the player is typing, and records the shown value
-- as the committed baseline so pollLimitCommit only fires on a real edit.
function OmniHubUIConfig:setLimitBox(box, idx, val)
    if not box or box.isTypingActive then return end
    local text = (val ~= nil) and tostring(val) or ""
    box.text = text
    self.limitCommitted[idx] = text
end

-- Called each client tick by the controller. Commits a limit field once it LOSES focus (isTypingActive
-- false) with a value different from what was last committed — i.e. on focus-out or Enter, not per
-- keystroke. Returns true if anything changed (the controller then pushes the full config).
function OmniHubUIConfig:pollLimitCommit()
    if not self.limitBoxes then return false end
    local changed = false
    for i, box in ipairs(self.limitBoxes) do
        if not box.isTypingActive and box.text ~= self.limitCommitted[i] then
            self.limitCommitted[i] = box.text
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

    self.activeBuyCheck = tab:createCheckBox(Rect(), "Actively buy resources"%_t, opts.changeCallback)
    left:placeElementTop(self.activeBuyCheck)
    self.activeBuyCheck.tooltip = "If checked, the hub summons traders to deliver the resources it consumes when it runs low."%_t

    self.activeSellCheck = tab:createCheckBox(Rect(), "Actively sell products"%_t, opts.changeCallback)
    left:placeElementTop(self.activeSellCheck)
    self.activeSellCheck.tooltip = "If checked, the hub summons traders to buy its products when stocks get full."%_t

    -- Dev-only: production debug logging. Only build the checkbox when dev mode is on (mirrors the
    -- dev-gated Tests tab); on a normal client the field simply doesn't exist and read() omits it.
    if GameSettings().devMode then
        self.debugCheck = tab:createCheckBox(Rect(), "Debug production logging (dev)"%_t, opts.changeCallback)
        left:placeElementTop(self.debugCheck)
        self.debugCheck.tooltip = "Dev only. Periodically prints each module's production state (active / stalled + reason) to the server log."%_t
    end

    left:nextRect(12)

    self.buyPriceLabel = tab:createLabel(Rect(), "Buy resources at 100%"%_t, 12)
    left:placeElementTop(self.buyPriceLabel)
    self.buyPriceLabel.centered = true
    -- Sliders update their % label live (priceMovedCallback) while dragging, but only commit to the
    -- server + recompute prices once, on mouse release (onMouseUpChangedFunction = priceCommitCallback).
    self.buyPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.buyPriceSlider)
    self.buyPriceSlider.unit = "%"
    self.buyPriceSlider:setValueNoCallback(0)
    self.buyPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.buyPriceSlider.tooltip = "Price the hub pays for resources. A higher price attracts more sellers."%_t

    left:nextRect(6)

    self.sellPriceLabel = tab:createLabel(Rect(), "Sell products at 100%"%_t, 12)
    left:placeElementTop(self.sellPriceLabel)
    self.sellPriceLabel.centered = true
    self.sellPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.sellPriceSlider)
    self.sellPriceSlider.unit = "%"
    self.sellPriceSlider:setValueNoCallback(0)
    self.sellPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.sellPriceSlider.tooltip = "Price the hub charges for products. A lower price attracts more buyers."%_t

    left:nextRect(12)

    -- ── Max Limit (per-good stock caps, in units) ────────────────────────────
    local rlabel = tab:createLabel(Rect(), "Max Limit (units)"%_t, 12)
    left:placeElementTop(rlabel); rlabel.centered = true

    self.limitBuyBox = self:numField(tab, left, "Buy goods max limit"%_t,
        "Max units stocked of each good you mark to Buy that the hub neither produces nor consumes (a passthrough trade good). 0 = don't stockpile it."%_t)
    self.limitBaseBox = self:numField(tab, left, "Production base"%_t,
        "Base multiplier for goods the hub produces or consumes. Max limit = base x cycles x the good's per-cycle amount across all modules."%_t)
    self.limitCyclesBox = self:numField(tab, left, "Production cycles"%_t,
        "How many production cycles of buffer to keep for produced/consumed goods. The hub stops a good's production once it reaches the max limit (or the cargo bay is full)."%_t)

    -- Ordered list + committed baseline for focus-out commits (see pollLimitCommit).
    self.limitBoxes     = { self.limitBuyBox, self.limitBaseBox, self.limitCyclesBox }
    self.limitCommitted = { self.limitBuyBox.text, self.limitBaseBox.text, self.limitCyclesBox.text }

    return self
end

-- Applies a server config table to the widgets (no callbacks fire).
function OmniHubUIConfig:apply(cfg)
    if not cfg then return end
    self.activeBuyCheck:setCheckedNoCallback(cfg.activelyRequest ~= false)
    self.activeSellCheck:setCheckedNoCallback(cfg.activelySell ~= false)
    if self.debugCheck then self.debugCheck:setCheckedNoCallback(cfg.debug == true) end

    self.buyPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorBuy))
    self.sellPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorSell))
    self:refreshPriceLabels()

    if self.limitBoxes then
        -- Skips any field currently being typed in (setLimitBox), so the server echo never stomps it.
        self:setLimitBox(self.limitBuyBox,    1, cfg.limitBuy)
        self:setLimitBox(self.limitBaseBox,   2, cfg.limitBase)
        self:setLimitBox(self.limitCyclesBox, 3, cfg.limitCycles)
    end
end

function OmniHubUIConfig:refreshPriceLabels()
    self.buyPriceLabel.caption  = "Buy resources at ${p}%"%_t  % { p = round(sliderToFactor(self.buyPriceSlider.value) * 100) }
    self.sellPriceLabel.caption = "Sell products at ${p}%"%_t % { p = round(sliderToFactor(self.sellPriceSlider.value) * 100) }
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
    -- toggle could never be turned off. nil only when there's no checkbox (non-dev client).
    local debug = nil
    if self.debugCheck then debug = self.debugCheck.checked == true end
    return {
        activelyRequest = self.activeBuyCheck.checked,
        activelySell    = self.activeSellCheck.checked,
        priceFactorBuy  = sliderToFactor(self.buyPriceSlider.value),
        priceFactorSell = sliderToFactor(self.sellPriceSlider.value),
        -- tonumber("") -> nil; the server treats nil as "keep current" (nil-safe clamp).
        limitBuy    = tonumber(self.limitBuyBox.text),
        limitBase   = tonumber(self.limitBaseBox.text),
        limitCycles = tonumber(self.limitCyclesBox.text),
        debug       = debug,
    }
end

return OmniHubUIConfig
