package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubEvents
-- Pure, engine-independent owner-notification engine: batches completed trades into a periodic
-- digest, queues immediate trade-failure messages, edge-triggers the storage/assembly condition
-- latches, and turns persistent production stalls into batched summaries. The controller feeds it
-- events + elapsed time and emits whatever advance() returns as faction chat; this module never
-- touches Entity()/Faction()/chat, so the off-engine suite covers all timing/format logic.
OmniHubEvents = {}

local DIGEST_INTERVAL = 300  -- seconds between trade digests (counted from the first pending trade)
local STALL_THRESHOLD = 600  -- a module must stall this long (actionable reason) to be reported
local STALL_INTERVAL  = 300  -- min seconds between stall/resume summary lines
local MAX_LISTED      = 4    -- goods/products listed per summary before "+N more"

-- Appends " +N more" when a summary truncated N entries; identity when nothing was dropped.
local function plusMore(text, extra)
    if extra > 0 then return text .. string.format(" +%d more", extra) end
    return text
end

-- "1234567" -> "1,234,567" (sign preserved). Pure-Lua stand-in for createMonetaryString (engine).
local function formatMoney(n)
    local s = tostring(math.floor(math.abs(n)))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "+") .. s
end

function OmniHubEvents.new()
    return {
        queue      = {},   -- already-due payloads {text, severity} (failures, condition edges)
        trades     = {},   -- pending digest: { [kind.."\0"..name] = {kind, name, units, value} }
        tradeClock = nil,  -- seconds since first pending trade; nil = nothing pending
        stalls     = {},   -- { [moduleKey] = {product, reason, detail, stalledFor, reported} }
        stallClock = STALL_INTERVAL,  -- starts elapsed so the first eligible batch flushes promptly
        resumed    = {},   -- { [product] = true } resumed since last flush (reported keys only)
        latches    = { storage = false, assembly = false },
    }
end

-- ── trade digest ─────────────────────────────────────────────────
function OmniHubEvents.recordTrade(s, kind, name, amount, price)
    if not name or not amount or amount <= 0 then return end
    local k = kind .. "\0" .. name
    local e = s.trades[k]
    if not e then
        e = { kind = kind, name = name, units = 0, value = 0 }
        s.trades[k] = e
    end
    e.units = e.units + amount
    e.value = e.value + (price or 0)
    if s.tradeClock == nil then s.tradeClock = 0 end
end

local function buildDigest(s)
    local list, net = {}, 0
    for _, e in pairs(s.trades) do
        list[#list + 1] = e
        net = net + (e.kind == "sell" and e.value or -e.value)
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.value > b.value end)

    local sold, bought, extra = {}, {}, 0
    for i, e in ipairs(list) do
        if i <= MAX_LISTED then
            local part = string.format("%s x%d", e.name, math.floor(e.units))
            if e.kind == "sell" then sold[#sold + 1] = part else bought[#bought + 1] = part end
        else
            extra = extra + 1
        end
    end
    local parts = {}
    if #sold   > 0 then parts[#parts + 1] = "sold "   .. table.concat(sold, ", ")   end
    if #bought > 0 then parts[#parts + 1] = "bought " .. table.concat(bought, ", ") end
    local text = plusMore("Trade summary: " .. table.concat(parts, "; "), extra)
    text = text .. string.format(" — net %s cr", formatMoney(net))
    return { text = text, severity = "info" }
end

-- ── trade failures ───────────────────────────────────────────────
-- Immediate (next advance) per-failure messages. Kinds map 1:1 to the controller's existing
-- failure branches; each text names the fault AND the likely fix. NOTE: deliberately no repeat
-- cooldown (design decision) — a persistent fault re-reports every trade wave.
local FAIL_TEXT = {
    cantpay     = "Trade failed: can't afford %s x%d — deposit credits into the faction account.",
    nostock_in  = "Trade failed: delivery of %s x%d moved no goods (stock cap reached or the faction can't pay).",
    nostock_out = "Trade failed: pickup of %s x%d moved no goods (nothing in stock, buyer can't pay, or the ship's hold is full).",
    wave        = "Trade failed: immediate trade of %s x%d (%s).",
}

function OmniHubEvents.tradeFailed(s, kind, goodName, amount, extra)
    local fmt = FAIL_TEXT[kind]
    if not fmt then return end
    s.queue[#s.queue + 1] = {
        text     = string.format(fmt, tostring(goodName), math.floor(tonumber(amount) or 0), tostring(extra)),
        severity = "warning",
    }
end

-- ── condition latches (storage / assembly) ───────────────────────
-- Edge-triggered: one event entering the bad state, one "resolved" leaving it, silence while held.
function OmniHubEvents.checkStorage(s, over)
    over = over == true
    if over == s.latches.storage then return end
    s.latches.storage = over
    if over then
        s.queue[#s.queue + 1] = { severity = "warning", text =
            "Cargo bay too small to hold every good's max stock — some production may stall. Add cargo space." }
    else
        s.queue[#s.queue + 1] = { severity = "info", text =
            "Cargo bay can hold every good's max stock again." }
    end
end

function OmniHubEvents.checkAssembly(s, capacity, recommended)
    local low = (recommended or 0) > 0 and (capacity or 0) < recommended
    if low == s.latches.assembly then return end
    s.latches.assembly = low
    if low then
        s.queue[#s.queue + 1] = { severity = "warning", text = string.format(
            "Production capacity %d is below the recommended %d — cycles run slower than possible. Add assembly blocks.",
            math.floor(capacity or 0), math.floor(recommended or 0)) }
    else
        s.queue[#s.queue + 1] = { severity = "info", text =
            "Production capacity now meets the recommended value." }
    end
end

-- ── persistence ──────────────────────────────────────────────────
-- Only the latches persist: without them, a condition held across save/load would re-fire on
-- every sector load. Stall timers re-accumulate after load (10 min); pending digests are dropped.
function OmniHubEvents.secure(s)
    return { storage = s.latches.storage, assembly = s.latches.assembly }
end

function OmniHubEvents.restore(s, data)
    if not data then return end
    s.latches.storage  = data.storage == true
    s.latches.assembly = data.assembly == true
end

-- ── production stalls ────────────────────────────────────────────
-- A module key is tracked while stalled on an ACTIONABLE reason ("ingredient", "space" — a
-- "maxstock" stall is the buffer working as intended). Crossing STALL_THRESHOLD marks it
-- report-pending; advance() batches all pending keys into ONE summary per STALL_INTERVAL. A
-- reason change restarts the timer (it is a different problem); a DETAIL change within the same
-- reason (the first missing ingredient shifting, e.g. Coal -> Iron) keeps the timer and the
-- reported latch — it is one continuous stall, and resetting would let oscillating shortages
-- dodge the threshold forever. The "resumed" line is queued only when the module is genuinely
-- not stalled; a reported stall drifting into "maxstock" stays latched silently until it
-- actually produces (a full output buffer is not a recovery).
-- Call with `stalled = false` on every tick a module is NOT stalled (including while a cycle is
-- in progress) so recovery is detected promptly; retainStalls covers uninstall, not recovery.
function OmniHubEvents.recordStallState(s, key, product, stalled, reason, detail)
    local actionable = stalled and (reason == "ingredient" or reason == "space")
    local e = s.stalls[key]
    if actionable then
        if not e or e.reason ~= reason then
            s.stalls[key] = { product = product, reason = reason, detail = detail,
                              stalledFor = 0, reported = false }
        elseif e.detail ~= detail then
            e.detail = detail
        end
    elseif stalled then
        -- Non-actionable stall (output at max stock). Keep a REPORTED entry so the eventual real
        -- resume still fires; drop an unreported one — its timer must not keep accruing against
        -- a reason that no longer holds.
        if e and not e.reported then s.stalls[key] = nil end
    else
        if e then
            if e.reported and e.product ~= nil then s.resumed[e.product] = true end
            s.stalls[key] = nil
        end
    end
end

-- Drop tracked stalls for module keys no longer installed (uninstall is not a "resume").
function OmniHubEvents.retainStalls(s, installedSet)
    for key in pairs(s.stalls) do
        if not installedSet[key] then s.stalls[key] = nil end
    end
end

local STALL_REASON_TEXT = {
    ingredient = function(e) return "missing: " .. tostring(e.detail) end,
    space      = function() return "no cargo space" end,
}

local function buildStallSummary(s)
    local pending = {}
    for _, e in pairs(s.stalls) do
        if not e.reported and e.stalledFor >= STALL_THRESHOLD then pending[#pending + 1] = e end
    end
    if #pending == 0 then return nil end
    table.sort(pending, function(a, b) return a.stalledFor > b.stalledFor end)

    local groups, order, extra = {}, {}, 0
    local seen = {}  -- { [rtext] = { [name] = true } } — dedup names per reason group
    for i, e in ipairs(pending) do
        e.reported = true
        if i <= MAX_LISTED then
            local rtext = STALL_REASON_TEXT[e.reason](e)
            if not groups[rtext] then groups[rtext] = {}; seen[rtext] = {}; order[#order + 1] = rtext end
            if e.product ~= nil and not seen[rtext][e.product] then
                seen[rtext][e.product] = true
                table.insert(groups[rtext], e.product)
            end
        else
            extra = extra + 1
        end
    end
    local parts = {}
    for _, rtext in ipairs(order) do
        parts[#parts + 1] = string.format("%s (%s)", table.concat(groups[rtext], ", "), rtext)
    end
    local text = plusMore("Production stalled for 10+ minutes: " .. table.concat(parts, "; "), extra)
    return { text = text .. ". Deliver the missing goods or add cargo space.", severity = "warning" }
end

local function buildResumeSummary(s)
    local names, extra, n = {}, 0, 0
    for product in pairs(s.resumed) do
        n = n + 1
        if n <= MAX_LISTED then names[#names + 1] = product else extra = extra + 1 end
    end
    if n == 0 then return nil end
    s.resumed = {}
    table.sort(names)
    return { text = plusMore("Production resumed: " .. table.concat(names, ", "), extra),
             severity = "info" }
end

-- ── clock ────────────────────────────────────────────────────────
-- Rolls all timers forward and returns the payloads now due (nil if none): drained queue entries
-- first, then a due trade digest, then a due stall/resume summary.
function OmniHubEvents.advance(s, dt)
    -- Immediate payloads drain regardless of dt — tradeFailed/check* are "next advance", period.
    -- The queue TABLE becomes the output (no copy); this runs every server tick, so no closures
    -- or avoidable allocations here.
    local out = nil
    if #s.queue > 0 then
        out = s.queue
        s.queue = {}
    end

    if not dt or dt <= 0 then return out end

    if s.tradeClock ~= nil then
        s.tradeClock = s.tradeClock + dt
        if s.tradeClock >= DIGEST_INTERVAL then
            local digest = buildDigest(s)
            s.trades, s.tradeClock = {}, nil
            if digest then
                out = out or {}
                out[#out + 1] = digest
            end
        end
    end

    for _, e in pairs(s.stalls) do
        e.stalledFor = e.stalledFor + dt
    end
    s.stallClock = s.stallClock + dt
    if s.stallClock >= STALL_INTERVAL then
        local stallSummary  = buildStallSummary(s)
        local resumeSummary = buildResumeSummary(s)
        if stallSummary or resumeSummary then
            s.stallClock = 0
            out = out or {}
            if stallSummary  then out[#out + 1] = stallSummary  end
            if resumeSummary then out[#out + 1] = resumeSummary end
        end
    end

    return out
end

return OmniHubEvents
