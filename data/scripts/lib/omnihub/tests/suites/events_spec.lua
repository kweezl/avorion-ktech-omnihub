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

    -- ── trade failures (immediate, next advance) ─────────────────
    runner:test("tradeFailed queues an immediate warning with the fix", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.tradeFailed(s, "cantpay", "Steel", 50)
        local due = drain(s, 1)
        eq(#due, 1)
        eq(due[1].severity, "warning")
        tru(due[1].text:find("Steel x50", 1, true) ~= nil, due[1].text)
        tru(due[1].text:find("faction account", 1, true) ~= nil, "actionable fix: " .. due[1].text)
    end)

    runner:test("tradeFailed: every kind formats; unknown kind is dropped", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.tradeFailed(s, "nostock_in",  "Coal", 10)
        OmniHubEvents.tradeFailed(s, "nostock_out", "Coal", 10)
        OmniHubEvents.tradeFailed(s, "wave",        "Coal", 10, 3)
        OmniHubEvents.tradeFailed(s, "bogus",       "Coal", 10)
        eq(#drain(s, 1), 3, "three known kinds queued, bogus dropped")
    end)

    -- ── condition latches ────────────────────────────────────────
    runner:test("checkStorage: edge-triggered with one-time resolve", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.checkStorage(s, true)
        OmniHubEvents.checkStorage(s, true)   -- held: no repeat
        local due = drain(s, 1)
        eq(#due, 1, "fired once")
        eq(due[1].severity, "warning")
        tru(due[1].text:find("cargo", 1, true) ~= nil, due[1].text)

        OmniHubEvents.checkStorage(s, false)
        OmniHubEvents.checkStorage(s, false)
        due = drain(s, 1)
        eq(#due, 1, "resolved once")
        eq(due[1].severity, "info")
        eq(#drain(s, 1), 0, "silent after resolve")
    end)

    runner:test("checkAssembly: fires below recommended, resolves at/above; 0 recommended never fires", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.checkAssembly(s, 100, 0)     -- empty hub
        eq(#drain(s, 1), 0)
        OmniHubEvents.checkAssembly(s, 50, 200)
        local due = drain(s, 1)
        eq(#due, 1)
        tru(due[1].text:find("50", 1, true) ~= nil and due[1].text:find("200", 1, true) ~= nil,
            "carries both numbers: " .. due[1].text)
        OmniHubEvents.checkAssembly(s, 200, 200)   -- at recommended = ok
        eq(drain(s, 1)[1].severity, "info")
    end)

    -- ── latch persistence ────────────────────────────────────────
    runner:test("secure/restore round-trips latches (no re-fire after load)", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.checkStorage(s, true)
        drain(s, 1)
        local saved = OmniHubEvents.secure(s)

        local s2 = OmniHubEvents.new()
        OmniHubEvents.restore(s2, saved)
        OmniHubEvents.checkStorage(s2, true)
        eq(#drain(s2, 1), 0, "condition still held across load -> no duplicate event")
        OmniHubEvents.checkStorage(s2, false)
        eq(#drain(s2, 1), 1, "resolve still fires after load")
    end)

    runner:test("restore(nil) keeps fresh defaults", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.restore(s, nil)
        fls(s.latches.storage)
        fls(s.latches.assembly)
    end)
end
