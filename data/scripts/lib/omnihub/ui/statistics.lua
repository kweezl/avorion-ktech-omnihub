package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
local OmniHubUICommon = include("ui/common")

-- namespace OmniHubUIStatistics
-- Client-only Statistics tab: lifetime profit, last-hour profit, and the last 10 trader transactions.
-- Pure presentation — the controller pushes already-computed numbers via :set(). No server calls.
OmniHubUIStatistics = {}
OmniHubUIStatistics.__index = OmniHubUIStatistics

function OmniHubUIStatistics.new(tab, size)
    local self = setmetatable({}, OmniHubUIStatistics)
    self.rows = {}

    local pad = 10
    local w   = size.x - 20
    local h   = size.y - 60

    tab:createFrame(Rect(vec2(0, 0), vec2(w + 10, 64)))

    local lt = tab:createLabel(vec2(pad, 8),  "Lifetime profit:"%_t, 14)
    lt.bold = true
    self.lifetimeLabel = tab:createLabel(Rect(vec2(pad, 8), vec2(pad + w - 10, 30)), "", 14)
    self.lifetimeLabel:setRightAligned()

    local hr = tab:createLabel(vec2(pad, 34), "Last hour profit:"%_t, 14)
    hr.bold = true
    self.hourLabel = tab:createLabel(Rect(vec2(pad, 34), vec2(pad + w - 10, 56)), "", 14)
    self.hourLabel:setRightAligned()

    -- Storage summary line (used / reserved volume vs capacity); turns red when reservations overflow.
    self.storageSummary = tab:createLabel(vec2(pad, 70), "", 13)
    self.storageSummary.bold = true

    -- Split the area below into storage (top) and transactions (bottom).
    local areaTop, mid = 92, math.floor(92 + (h - 92) * 0.5)
    self.storageRows = {}

    local sHdr = tab:createLabel(vec2(pad, areaTop), "Max Limit (units, volume)"%_t, 13)
    sHdr.bold = true
    self.storageFrame = tab:createScrollFrame(Rect(vec2(pad, areaTop + 20), vec2(pad + w, mid - 6)))
    self.storageFrame.scrollSpeed = 30

    local hdr = tab:createLabel(vec2(pad, mid), "Recent transactions"%_t, 13)
    hdr.bold = true
    self.frame = tab:createScrollFrame(Rect(vec2(pad, mid + 20), vec2(pad + w, h)))
    self.frame.scrollSpeed = 30

    return self
end

-- setStorage(storage) where storage = OmniHubStorage.summarize(...) result. Renders the summary line
-- and one row per reserving good (current/reserved units + volume).
function OmniHubUIStatistics:setStorage(storage)
    storage = storage or { goods = {}, totalCurrentVol = 0, totalLimitVol = 0, capacity = 0, over = false }

    self.storageSummary.caption = string.format("Storage: %d used / %d limit  (capacity %d)",
        math.floor(storage.totalCurrentVol or 0), math.floor(storage.totalLimitVol or 0),
        math.floor(storage.capacity or 0))
    self.storageSummary.color = storage.over and ColorRGB(1.0, 0.5, 0.5) or ColorRGB(0.8, 0.8, 0.8)

    self.storageRows = OmniHubUICommon.clearRows(self.storageRows)

    local rowH, pad = 18, 4
    local width = self.storageFrame.size.x - pad * 2
    local list = storage.goods or {}

    if storage.over then
        local warn = self.storageFrame:createLabel(vec2(pad, pad),
            "Cargo too small for all max limits — some production may stall. Add cargo space."%_t, 12)
        warn.size = vec2(width, rowH); warn.color = ColorRGB(1.0, 0.6, 0.6)
        self.storageRows[#self.storageRows + 1] = { warn }
    end

    if #list == 0 then
        local empty = self.storageFrame:createLabel(vec2(pad, pad + (storage.over and (rowH + 2) or 0)),
            "No goods have a max limit yet."%_t, 12)
        empty.size = vec2(width, rowH)
        self.storageRows[#self.storageRows + 1] = { empty }
        return
    end

    local base = storage.over and 1 or 0  -- shift rows down past the warning line
    for i, g in ipairs(list) do
        local y = pad + (base + i - 1) * (rowH + 2)
        local text = string.format("%s   %d / %d u   (%d / %d vol)",
            tostring(g.name or "?"), g.current or 0, g.limit or 0, g.currentVol or 0, g.limitVol or 0)
        local label = self.storageFrame:createLabel(vec2(pad, y), text, 12)
        label.size = vec2(width, rowH); label:setLeftAligned()
        self.storageRows[#self.storageRows + 1] = { label }
    end
end

-- set(lifetime, lastHour, txns) where txns = { {kind, good, amount, price, partner}, ... } newest-first.
function OmniHubUIStatistics:set(lifetime, lastHour, txns)
    self.lifetimeLabel.caption = OmniHubUICommon.formatProfit(lifetime)
    self.lifetimeLabel.color   = (lifetime or 0) < 0 and ColorRGB(1.0, 0.5, 0.5) or ColorRGB(0.5, 1.0, 0.5)
    self.hourLabel.caption     = OmniHubUICommon.formatProfit(lastHour)
    self.hourLabel.color       = (lastHour or 0) < 0 and ColorRGB(1.0, 0.5, 0.5) or ColorRGB(0.5, 1.0, 0.5)

    self.rows = OmniHubUICommon.clearRows(self.rows)

    local rowH  = 20
    local pad   = 4
    local width = self.frame.size.x - pad * 2
    txns = txns or {}

    if #txns == 0 then
        local empty = self.frame:createLabel(vec2(pad, pad), "No transactions yet."%_t, 12)
        empty.size = vec2(width, rowH)
        self.rows[#self.rows + 1] = { empty }
        return
    end

    for i, t in ipairs(txns) do
        local y = pad + (i - 1) * (rowH + 2)
        local verb = (t.kind == "sell") and "Sold"%_t or "Bought"%_t
        local text = string.format("%s %s \xC3\x97%s  \xC2\xA2%s  %s",
            verb, tostring(t.good or "?"), tostring(t.amount or 0),
            createMonetaryString(t.price or 0), tostring(t.partner or ""))
        local label = self.frame:createLabel(vec2(pad, y), text, 12)
        label.size  = vec2(width, rowH)
        label:setLeftAligned()
        label.color = (t.kind == "sell") and ColorRGB(0.7, 1.0, 0.7) or ColorRGB(1.0, 0.85, 0.7)
        self.rows[#self.rows + 1] = { label }
    end
end

return OmniHubUIStatistics
