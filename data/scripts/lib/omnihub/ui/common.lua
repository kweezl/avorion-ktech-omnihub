package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubUICommon
-- Small client-only presentation helpers shared by the OmniHub tab modules. Pure formatting / widget
-- bookkeeping — no server calls, no domain math. Loaded only in the client VM (the tab modules that
-- require it are themselves client-only).
OmniHubUICommon = {}

-- Hides every widget held on each row table and returns a fresh empty list. Rows store their widgets
-- under the array part and/or named fields; any value answering :hide() is hidden (Avorion has no
-- widget destroy, so refresh hides + rebuilds, matching the existing controller pattern).
function OmniHubUICommon.clearRows(rows)
    for _, row in ipairs(rows or {}) do
        for _, w in pairs(row) do
            if type(w) == "userdata" and w.hide then w:hide() end
        end
    end
    return {}
end

-- Formats a regional supply/demand percentage (e.g. 12 -> "+12%", -8 -> "-8%", 0 -> "0%").
function OmniHubUICommon.formatPct(pct)
    pct = pct or 0
    return string.format("%+d%%", pct)
end

-- Colour for a regional percentage label. For a SELL context (products) a higher regional price is
-- good (green); for a BUY context (resources) a lower regional price is good (green). `goodWhenHigh`
-- selects which way is favourable.
function OmniHubUICommon.pctColor(pct, goodWhenHigh)
    pct = pct or 0
    if pct == 0 then return ColorRGB(0.8, 0.8, 0.8) end
    local high = pct > 0
    local favourable = (high == goodWhenHigh)
    if favourable then return ColorRGB(0.0, 1.0, 0.0) end
    return ColorRGB(1.0, 0.6, 0.3)
end

-- Credits-formatted profit string with sign, e.g. 1500 -> "+¢1,500", -200 -> "-¢200".
function OmniHubUICommon.formatProfit(value)
    value = value or 0
    local sign = value < 0 and "-" or "+"
    return sign .. "\xC2\xA2" .. createMonetaryString(math.abs(value))
end

return OmniHubUICommon
