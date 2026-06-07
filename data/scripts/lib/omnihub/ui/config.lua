package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubUIConfig
-- Client-only Configuration tab: actively-buy / actively-sell checkboxes, two base-price sliders
-- (buy resources, sell products; ±20%), and the deliver-to / fetch-from station dropdowns. Holds its
-- own widget state and exposes read()/apply()/setOptions()/setErrors() for the controller; the single
-- change handler name (opts.changeCallback) is wired by the controller to push config to the server.
OmniHubUIConfig = {}
OmniHubUIConfig.__index = OmniHubUIConfig

local SLOTS = 3  -- deliver / fetch dropdown slots per direction (matches vanilla)

-- Maps a price factor (0.8..1.2) to slider units (-20..20) and back.
local function factorToSlider(f) return round(((f or 1.0) - 1.0) * 100) end
local function sliderToFactor(v) return 1.0 + (v or 0) / 100.0 end

function OmniHubUIConfig.new(tab, size, opts)
    local self = setmetatable({}, OmniHubUIConfig)
    self.opts            = opts
    self.deliveredCombos = {}
    self.deliveringCombos = {}

    local pad   = 10
    local vsplit = UIVerticalSplitter(Rect(vec2(pad, pad), vec2(size.x - pad, size.y - 60)), 10, 0, 0.5)

    -- ── Left: trade behaviour + pricing ──────────────────────────────────────
    local left = UIVerticalLister(vsplit.left, 8, 0)

    self.activeBuyCheck = tab:createCheckBox(Rect(), "Actively buy resources"%_t, opts.changeCallback)
    left:placeElementTop(self.activeBuyCheck)
    self.activeBuyCheck.tooltip = "If checked, the hub summons traders to deliver the resources it consumes when it runs low."%_t

    self.activeSellCheck = tab:createCheckBox(Rect(), "Actively sell products"%_t, opts.changeCallback)
    left:placeElementTop(self.activeSellCheck)
    self.activeSellCheck.tooltip = "If checked, the hub summons traders to buy its products when stocks get full."%_t

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

    -- ── Right: inter-station transfers ───────────────────────────────────────
    local right = UIVerticalLister(vsplit.right, 6, 0)

    local dlabel = tab:createLabel(Rect(), "Deliver products to stations:"%_t, 12)
    right:placeElementTop(dlabel); dlabel.centered = true
    for _ = 1, SLOTS do
        local combo = tab:createValueComboBox(Rect(), opts.changeCallback)
        right:placeElementTop(combo)
        self.deliveredCombos[#self.deliveredCombos + 1] = combo
    end
    self.deliveredError = tab:createLabel(Rect(), "", 12)
    right:placeElementTop(self.deliveredError)
    self.deliveredError.color = ColorRGB(1, 1, 0)

    right:nextRect(14)

    local flabel = tab:createLabel(Rect(), "Fetch resources from stations:"%_t, 12)
    right:placeElementTop(flabel); flabel.centered = true
    for _ = 1, SLOTS do
        local combo = tab:createValueComboBox(Rect(), opts.changeCallback)
        right:placeElementTop(combo)
        self.deliveringCombos[#self.deliveringCombos + 1] = combo
    end
    self.deliveringError = tab:createLabel(Rect(), "", 12)
    right:placeElementTop(self.deliveringError)
    self.deliveringError.color = ColorRGB(1, 1, 0)

    return self
end

-- Populates the combo option lists from server-supplied partner option arrays
-- ({ {id, name}, ... }). Preserves current selections where still valid.
function OmniHubUIConfig:setOptions(deliveredOptions, deliveringOptions)
    local function fill(combos, options)
        for _, combo in ipairs(combos) do
            local prev = combo.selectedValue
            combo:clear()
            combo:addEntry(nil, "- None -"%_t)
            for _, o in ipairs(options or {}) do
                combo:addEntry(o.id, o.name)
            end
            if prev then combo:setSelectedValueNoCallback(prev) end
        end
    end
    fill(self.deliveredCombos, deliveredOptions)
    fill(self.deliveringCombos, deliveringOptions)
end

-- Applies a server config table to the widgets (no callbacks fire).
function OmniHubUIConfig:apply(cfg)
    if not cfg then return end
    self.activeBuyCheck:setCheckedNoCallback(cfg.activelyRequest ~= false)
    self.activeSellCheck:setCheckedNoCallback(cfg.activelySell ~= false)

    self.buyPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorBuy))
    self.sellPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorSell))
    self:refreshPriceLabels()

    local function applySelection(combos, ids)
        ids = ids or {}
        for i, combo in ipairs(combos) do
            if ids[i] then combo:setSelectedValueNoCallback(ids[i])
            else combo:setSelectedIndexNoCallback(0) end
        end
    end
    applySelection(self.deliveredCombos, cfg.deliveredIds)
    applySelection(self.deliveringCombos, cfg.deliveringIds)
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
    local function selectedIds(combos)
        local ids = {}
        for _, combo in ipairs(combos) do
            ids[#ids + 1] = combo.selectedValue   -- nil for "- None -" is simply skipped
        end
        return ids
    end
    return {
        activelyRequest = self.activeBuyCheck.checked,
        activelySell    = self.activeSellCheck.checked,
        priceFactorBuy  = sliderToFactor(self.buyPriceSlider.value),
        priceFactorSell = sliderToFactor(self.sellPriceSlider.value),
        deliveredIds    = selectedIds(self.deliveredCombos),
        deliveringIds   = selectedIds(self.deliveringCombos),
    }
end

-- Shows the first delivery / fetch error string (if any) under each group.
function OmniHubUIConfig:setErrors(deliveredErrors, deliveringErrors)
    local function first(errs)
        for _, m in pairs(errs or {}) do if m and m ~= "" then return m end end
        return ""
    end
    self.deliveredError.caption  = first(deliveredErrors)
    self.deliveringError.caption = first(deliveringErrors)
end

return OmniHubUIConfig
