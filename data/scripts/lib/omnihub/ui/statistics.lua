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

    local hdr = tab:createLabel(vec2(pad, 74), "Recent transactions"%_t, 13)
    hdr.bold = true

    self.frame = tab:createScrollFrame(Rect(vec2(pad, 96), vec2(pad + w, h)))
    self.frame.scrollSpeed = 30

    return self
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
