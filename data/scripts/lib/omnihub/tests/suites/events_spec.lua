package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubEvents = include("lib/omnihub/events")

local eq  = OmniHubTest.assertEqual
local tru = OmniHubTest.assertTrue
local fls = OmniHubTest.assertFalse
local nilf = OmniHubTest.assertNil

-- advance() returns nil or an array of {text, severity}; helper drains it into a flat list.
local function drain(s, dt)
    return OmniHubEvents.advance(s, dt) or {}
end

return function(runner)
    runner:suite("events")

    -- ── trade digest ─────────────────────────────────────────────
    runner:test("no trades -> no digest ever", function()
        local s = OmniHubEvents.new()
        eq(#drain(s, 1000), 0)
    end)

    runner:test("digest flushes once after 300s, not before", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.recordTrade(s, "sell", "Steel", 120, 45000)
        eq(#drain(s, 299), 0, "not due yet")
        local due = drain(s, 1)
        eq(#due, 1, "due at 300s")
        eq(due[1].severity, "info")
        tru(due[1].text:find("Steel x120", 1, true) ~= nil, "lists the good: " .. due[1].text)
        tru(due[1].text:find("+45,000", 1, true) ~= nil, "net credits: " .. due[1].text)
        eq(#drain(s, 1000), 0, "flushed — nothing pending")
    end)

    runner:test("digest aggregates per good and computes net (sell - buy)", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.recordTrade(s, "sell", "Steel", 100, 30000)
        OmniHubEvents.recordTrade(s, "sell", "Steel",  20, 15000)
        OmniHubEvents.recordTrade(s, "buy",  "Coal",   80, 20000)
        local due = drain(s, 300)
        eq(#due, 1)
        tru(due[1].text:find("Steel x120", 1, true) ~= nil, "merged units: " .. due[1].text)
        tru(due[1].text:find("Coal x80", 1, true) ~= nil, "bought listed: " .. due[1].text)
        tru(due[1].text:find("+25,000", 1, true) ~= nil, "45000 - 20000: " .. due[1].text)
    end)

    runner:test("digest lists at most 4 goods by value, then +N more", function()
        local s = OmniHubEvents.new()
        for i = 1, 6 do
            OmniHubEvents.recordTrade(s, "sell", "Good" .. i, 10, i * 1000)  -- Good6 most valuable
        end
        local due = drain(s, 300)
        eq(#due, 1)
        tru(due[1].text:find("Good6", 1, true) ~= nil, "highest value listed")
        nilf(due[1].text:find("Good1", 1, true), "lowest value not listed")
        tru(due[1].text:find("+2 more", 1, true) ~= nil, "overflow counted: " .. due[1].text)
    end)

    runner:test("negative net formats with minus", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.recordTrade(s, "buy", "Coal", 80, 1234567)
        local due = drain(s, 300)
        tru(due[1].text:find("-1,234,567", 1, true) ~= nil, due[1].text)
    end)

    runner:test("recordTrade ignores nil/zero amounts", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.recordTrade(s, "sell", nil, 10, 100)
        OmniHubEvents.recordTrade(s, "sell", "Steel", 0, 100)
        eq(#drain(s, 1000), 0)
    end)
end
