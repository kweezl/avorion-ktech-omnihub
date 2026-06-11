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

    runner:test("secure/restore round-trips the assembly latch too", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.checkAssembly(s, 50, 200)
        drain(s, 1)
        local s2 = OmniHubEvents.new()
        OmniHubEvents.restore(s2, OmniHubEvents.secure(s))
        OmniHubEvents.checkAssembly(s2, 50, 200)
        eq(#drain(s2, 1), 0, "condition still held across load -> no duplicate event")
        OmniHubEvents.checkAssembly(s2, 200, 200)
        eq(#drain(s2, 1), 1, "resolve still fires after load")
    end)

    runner:test("digest window re-arms after a flush", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.recordTrade(s, "sell", "Steel", 10, 100)
        eq(#drain(s, 300), 1, "first digest")
        OmniHubEvents.recordTrade(s, "sell", "Steel", 5, 50)
        eq(#drain(s, 299), 0, "new window counts from the new first trade")
        eq(#drain(s, 1), 1, "second digest at +300s")
    end)

    -- ── production stalls ────────────────────────────────────────
    -- helper: tick `n` seconds in `step`-sized slices, re-feeding the same stall state each tick
    -- (mirrors the controller, which feeds tickRecipe's outcome every production tick).
    local function stallFor(s, key, product, reason, detail, n, step)
        local due = {}
        for _ = 1, math.floor(n / step) do
            OmniHubEvents.recordStallState(s, key, product, true, reason, detail)
            for _, p in ipairs(drain(s, step)) do due[#due + 1] = p end
        end
        return due
    end

    runner:test("stall below 600s stays silent; crossing it reports once, batched", function()
        local s = OmniHubEvents.new()
        eq(#stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 599, 1), 0, "silent below threshold")
        local due = stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 2, 1)
        eq(#due, 1, "reported once past threshold")
        eq(due[1].severity, "warning")
        tru(due[1].text:find("Steel Factory", 1, true) ~= nil, due[1].text)
        tru(due[1].text:find("missing: Coal", 1, true) ~= nil, due[1].text)
        eq(#stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 900, 10), 0, "no repeat while stalled")
    end)

    runner:test("40 modules stalling together produce ONE summary with +N more", function()
        local s = OmniHubEvents.new()
        local due = {}
        for t = 1, 610 do
            for i = 1, 40 do
                OmniHubEvents.recordStallState(s, "k" .. i, "Factory " .. i, true, "ingredient", "Coal")
            end
            for _, p in ipairs(drain(s, 1)) do due[#due + 1] = p end
        end
        eq(#due, 1, "one chat line, not 40")
        tru(due[1].text:find("+36 more", 1, true) ~= nil, "4 listed, 36 overflow: " .. due[1].text)
    end)

    runner:test("max-stock stalls are the buffer working — never reported", function()
        local s = OmniHubEvents.new()
        eq(#stallFor(s, "k1", "Steel Factory", "maxstock", "Steel", 1200, 10), 0)
    end)

    runner:test("reason change resets the stall timer", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 590, 10)
        eq(#stallFor(s, "k1", "Steel Factory", "space", nil, 590, 10), 0,
            "timer restarted on reason change — still silent")
        tru(#stallFor(s, "k1", "Steel Factory", "space", nil, 20, 10) >= 1, "new reason reports after its own 600s")
    end)

    runner:test("detail change within the same reason keeps the stall timer", function()
        -- The FIRST missing ingredient can oscillate (canStartCycle reports one at a time, and
        -- other modules may consume shared ingredients); the stall is still continuous.
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 590, 10)
        local due = stallFor(s, "k1", "Steel Factory", "ingredient", "Iron", 20, 10)
        tru(#due >= 1, "reported despite the blocking ingredient changing")
        tru(due[1].text:find("missing: Iron", 1, true) ~= nil, "names the current blocker: " .. due[1].text)
    end)

    runner:test("maxstock after a reported stall is not a resume; producing later is", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 610, 10)            -- reported
        OmniHubEvents.recordStallState(s, "k1", "Steel Factory", true, "maxstock", "Steel")
        eq(#drain(s, 300), 0, "full output buffer is not a recovery — no resume line")
        OmniHubEvents.recordStallState(s, "k1", "Steel Factory", false)
        local due = drain(s, 300)
        eq(#due, 1, "real resume once producing")
        tru(due[1].text:find("Steel Factory", 1, true) ~= nil, due[1].text)
    end)

    runner:test("maxstock clears an unreported stall timer", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 590, 10)
        OmniHubEvents.recordStallState(s, "k1", "Steel Factory", true, "maxstock", "Steel")
        eq(#stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 20, 10), 0,
            "timer restarted — the 590s did not count across the maxstock phase")
    end)

    runner:test("resume after a report emits one batched info line; unreported stalls resume silently", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 610, 10)  -- reported
        OmniHubEvents.recordStallState(s, "k1", "Steel Factory", false)
        OmniHubEvents.recordStallState(s, "k2", "Wire Factory", false)     -- never stalled/reported
        -- resume summaries share the stall cooldown; roll past it
        local due = drain(s, 300)
        eq(#due, 1, "one resume line")
        eq(due[1].severity, "info")
        tru(due[1].text:find("Steel Factory", 1, true) ~= nil, due[1].text)
        nilf(due[1].text:find("Wire Factory", 1, true), "unreported module not mentioned")
    end)

    runner:test("retainStalls drops uninstalled modules without a resume message", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", "Steel Factory", "ingredient", "Coal", 610, 10)  -- reported
        OmniHubEvents.retainStalls(s, {})                                  -- module uninstalled
        eq(#drain(s, 1000), 0, "no resume for removed module")
    end)

    runner:test("nil product never crashes stall tracking", function()
        local s = OmniHubEvents.new()
        stallFor(s, "k1", nil, "ingredient", "Coal", 610, 10)        -- reported with nil product
        OmniHubEvents.recordStallState(s, "k1", nil, false)          -- recovery must not error
        local due = drain(s, 300)
        -- a nil product can't be named; the resume line is simply absent
        eq(#due, 0)
    end)

    runner:test("advance(0) still drains queued failures; timers untouched", function()
        local s = OmniHubEvents.new()
        OmniHubEvents.tradeFailed(s, "cantpay", "Steel", 5)
        OmniHubEvents.recordTrade(s, "sell", "Steel", 10, 100)
        local due = OmniHubEvents.advance(s, 0) or {}
        eq(#due, 1, "queued failure drained at dt=0")
        eq(#drain(s, 299), 0, "digest clock did not advance at dt=0")
        eq(#drain(s, 1), 1, "digest still flushes at 300s of real time")
    end)

    runner:test("duplicate product names within a reason group are listed once", function()
        local s = OmniHubEvents.new()
        -- 59 × 10s = 590s: entries approach threshold but summary not yet due.
        -- drain(s, 300) pushes stalledFor past 600s AND triggers the stall flush in one call.
        for t = 1, 59 do
            OmniHubEvents.recordStallState(s, "kA", "Steel Factory", true, "ingredient", "Coal")
            OmniHubEvents.recordStallState(s, "kB", "Steel Factory", true, "ingredient", "Coal")
            drain(s, 10)
        end
        local due = drain(s, 300)
        -- both entries reported; the text names the product once
        local text = (due[1] or {}).text or ""
        local first = text:find("Steel Factory", 1, true)
        tru(first ~= nil, text)
        nilf(text:find("Steel Factory", first + 1, true), "name not repeated: " .. text)
    end)
end
