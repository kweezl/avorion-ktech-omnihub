# Founding Config & Owner Event Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configurable founding cost, removal of the phantom 25k cargo floor, and a per-hub owner
event-notification system (trade digest, failures, storage/assembly conditions, production-stall
summaries) per `docs/2026-06-11-founding-config-and-events-design.md`.

**Architecture:** New pure module `lib/omnihub/events.lua` does all batching/latching/formatting
(off-engine tested); the controller adds a single server-side emit funnel
(`Faction:sendChatMessage`) plus hook calls at existing sites. Pure math for the assembly
recommendation goes in `production.lua`. Config option + UI checkbox follow the existing
schema/RPC patterns exactly.

**Tech Stack:** Lua 5.4 (Avorion sandbox), off-engine test runner (`tests/run.lua` via
`$LUA_DIR/lua54.exe`), MCM optional dependency.

**Conventions that apply to every task** (from CLAUDE.md / the avorion-modding skill):
- `include()`, never `require()`. Namespace comment (`-- namespace X`) is load-bearing. Trailing
  `return X` stays unconditional.
- Run the pure suite after every lib change: `"$LUA_DIR/lua54.exe" tests/run.lua` from repo root
  (exit 0 = pass).
- Event texts are plain pre-formatted English strings (the pure module cannot use `%_t`, and
  vanilla also sends server-locale text for faction messages).
- Commit after each task.

---

### Task 1: `foundingCostMillions` config option

**Files:**
- Modify: `data/scripts/lib/omnihub/config.lua` (schema, ~line 16)
- Test: `data/scripts/lib/omnihub/tests/suites/config_spec.lua`

- [ ] **Step 1: Write the failing test**

In `config_spec.lua`, add to the `DOCUMENTED` table (line 20-28):

```lua
    {key = "foundingCostMillions",  value = 15},
```

and add `"foundingCostMillions"` to the key list in the "module contract" test (line 36-37):

```lua
        for _, key in ipairs({"moduleCap", "dropChance", "modulePriceFactor",
                              "traderRequestCooldown", "sellingModuleCount", "stockMin", "stockMax",
                              "foundingCostMillions"}) do
```

- [ ] **Step 2: Run test to verify it fails**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: FAIL in suite `config` — `defaults has key: foundingCostMillions` (nil).

- [ ] **Step 3: Add the schema entry**

In `config.lua`, insert as the FIRST entry of `OmniHubConfig.schema` (before `sellingModuleCount`,
line 17). It is a plain number key — do NOT add it to `PERCENT_KEYS`:

```lua
    {
        key         = "foundingCostMillions",
        type        = "number",
        title       = "Founding cost",
        description = "OmniHub founding price, in millions of credits. 0 = free (creative servers).",
        default     = 15,
        min         = 0,
        max         = 500,
    },
```

- [ ] **Step 4: Run tests to verify pass**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: all pass (the `modconfig` suite validates the schema shape automatically).

- [ ] **Step 5: Commit**

```bash
git add data/scripts/lib/omnihub/config.lua data/scripts/lib/omnihub/tests/suites/config_spec.lua
git commit -m "feat(omnihub): add foundingCostMillions config option (default 15M)"
```

---

### Task 2: Station founder reads the configured price

**Files:**
- Modify: `data/scripts/entity/stationfounder.lua`

No pure test exists for this file (engine-loaded fragment); verification is in-game (Task 12).

- [ ] **Step 1: Replace the hardcoded price**

Replace the entire file content with:

```lua
-- OmniHub mod: appends OmniHub to the Found Station > Other Stations list.
-- This file is concatenated by the engine after the vanilla stationfounder.lua.
-- StationFounder and StationFounder.stations are already defined above.

-- Founding price comes from the mod config (MCM-backed when installed, built-in default
-- otherwise). Evaluated when this script loads — i.e. fresh on each founder interaction.
package.path = package.path .. ";data/scripts/lib/?.lua"
local OmniHubConfig = include("lib/omnihub/config")

table.insert(StationFounder.stations, {
    name    = "OmniHub"%_t,
    tooltip = "A modular production station. Install factory modules to produce goods. Modules can be bought from an OmniHub Supplier."%_t,
    scripts = {
        { script = "data/scripts/entity/merchants/omnihubcontroller.lua" },
        { script = "data/scripts/entity/merchants/omnihubsupplier.lua" },
        -- omnihubtests.lua is deliberately NOT listed here: the controller attaches it in its
        -- initialize, which runs inside the founder's addScript loop — i.e. BEFORE the founder
        -- would reach a tests entry, so listing it here double-attaches it (two interaction
        -- options). The controller is the single attach point.
    },
    price = OmniHubConfig.get("foundingCostMillions") * 1000000,
})
```

(The include pattern — `package.path` extension + `include("lib/omnihub/config")` — is the same
one `modconfig.lua` uses and is proven to work.)

- [ ] **Step 2: Run the pure suite (regression only)**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: all pass (unchanged).

- [ ] **Step 3: Commit**

```bash
git add data/scripts/entity/stationfounder.lua
git commit -m "feat(omnihub): founding price from config instead of hardcoded 15M"
```

---

### Task 3: Remove the 25k cargo floor + README founding paragraph

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua:50` and `:263-267`
- Modify: `README.md:17`

- [ ] **Step 1: Delete the constant**

Remove line 50:

```lua
local MIN_CARGO_BAY = 25000
```

- [ ] **Step 2: Delete the floor write in `initialize()`**

In the `if onServer() then` block of `OmniHub.initialize()` (~line 263), remove:

```lua
        local bay = CargoBay()
        if bay and bay.cargoHold < MIN_CARGO_BAY then
            bay.cargoHold = MIN_CARGO_BAY
        end
```

(The next statement, `-- Fresh station defaults: ...`, becomes the first thing in the block.)

- [ ] **Step 3: Verify no references remain**

Run: `grep -rn "MIN_CARGO_BAY" data/`
Expected: no output.

- [ ] **Step 4: Update the README founding paragraph**

In `README.md`, replace the paragraph (line 17):

> The OmniHub appears in the station founder under *Other Stations* and costs **15,000,000
> credits** to found. A freshly founded hub is an empty shell: it produces nothing until modules
> are installed. Founding guarantees a minimum cargo hold of **25,000** so the station can
> operate at all; real throughput wants far more.

with:

> The OmniHub appears in the station founder under *Other Stations*. The founding cost is
> configurable (default **15,000,000 credits**, `Founding cost` in the mod config). A freshly
> founded hub is an empty shell: it produces nothing until modules are installed, and its cargo
> hold is whatever its blocks provide — build cargo bays before installing production.
> *(Migration note: hubs founded before this version relied on a forced 25,000 minimum hold that
> is no longer applied; if such a hub stalls after updating, add real cargo blocks.)*

- [ ] **Step 5: Run the pure suite, then commit**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.

```bash
git add data/scripts/entity/merchants/omnihubcontroller.lua README.md
git commit -m "feat(omnihub): drop forced 25k cargo floor — phantom capacity dropped goods on plan change"
```

---

### Task 4: `OmniHubProduction.recommendedCapacity` (pure)

**Files:**
- Modify: `data/scripts/lib/omnihub/production.lua` (refactor `timeToProduce`, add function)
- Test: `data/scripts/lib/omnihub/tests/suites/production_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the suite function of `production_spec.lua` (before its final `end`). The tests use
the aliases `eq`, `near`, `tru`; check the file head — if any is missing, add it there in the
existing style (e.g. `local near = OmniHubTest.assertNear`):

```lua
    -- ── recommendedCapacity ──────────────────────────────────────
    -- goodsTable fixture: price/level shapes mirror the timeToProduce tests.
    local rcGoods = {
        plate = { price = 300, level = 0 },   -- value 300/unit, no level bonus
        gem   = { price = 600, level = 50 },  -- value 600/unit, levelBonus 1.5
        scrap = { price = 30,  level = 0 },
    }

    runner:test("recommendedCapacity: empty hub -> 0", function()
        eq(OmniHubProduction.recommendedCapacity({}, function() return nil end, rcGoods, 15), 0)
    end)

    runner:test("recommendedCapacity: capacity where cycle time bottoms out at minTime", function()
        -- one module: 2 plate/cycle -> totalValue 600, levelBonus 1 -> 600 / 15 = 40
        local recipes = { mPlate = { ingredients = {}, results = { {name = "plate", amount = 2} } } }
        local resolve = function(key) return recipes[key] end
        near(OmniHubProduction.recommendedCapacity({mPlate = 1}, resolve, rcGoods, 15), 40)
        -- cross-check: AT the recommended capacity, timeToProduce == minTime exactly
        near(OmniHubProduction.timeToProduce(recipes.mPlate, rcGoods, 40, 15), 15)
        -- and BELOW it, the cycle is slower
        tru(OmniHubProduction.timeToProduce(recipes.mPlate, rcGoods, 39, 15) > 15,
            "below recommended -> slower than minTime")
    end)

    runner:test("recommendedCapacity: max across modules; level bonus and garbages count", function()
        local recipes = {
            mPlate = { ingredients = {}, results = { {name = "plate", amount = 2} } },          -- needs 40
            mGem   = { ingredients = {}, results = { {name = "gem",   amount = 3} },            -- value 1800
                       garbages    = { {name = "scrap", amount = 10} } },                       -- + 300
        }
        -- mGem: totalValue 2100, avgLevel (50+0)/2=25, bonus 1.25 -> 2100 / (15*1.25) = 112
        local resolve = function(key) return recipes[key] end
        near(OmniHubProduction.recommendedCapacity({mPlate = 1, mGem = 1}, resolve, rcGoods, 15), 112)
    end)

    runner:test("recommendedCapacity: module count does not change it (parallel lines, same cycle)", function()
        local recipes = { mPlate = { ingredients = {}, results = { {name = "plate", amount = 2} } } }
        local resolve = function(key) return recipes[key] end
        near(OmniHubProduction.recommendedCapacity({mPlate = 5}, resolve, rcGoods, 15), 40)
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: FAIL in suite `production` — `recommendedCapacity` is nil (attempt to call a nil value).

- [ ] **Step 3: Implement — extract the shared accumulation, add the function**

In `production.lua`, add a local helper above `timeToProduce` (after the `lerp` local):

```lua
-- Shared by timeToProduce and recommendedCapacity: a recipe's total output value (results +
-- garbages, priced from goodsTable) and the level bonus derived from the same goods.
local function recipeValueAndBonus(recipe, goodsTable)
    local totalValue, totalLevel, samples = 0, 0, 0
    local function accumulate(name, amount)
        local g = goodsTable[name]
        if g then
            totalValue = totalValue + g.price * amount
            totalLevel = totalLevel + (g.level or 0)
            samples    = samples + 1
        end
    end
    for _, res in pairs(recipe.results) do accumulate(res.name, res.amount) end
    if recipe.garbages then
        for _, gar in pairs(recipe.garbages) do accumulate(gar.name, gar.amount) end
    end
    local avgLevel = samples > 0 and (totalLevel / samples) or 0
    return totalValue, 1 + avgLevel / 100
end
```

Rewrite the body of `timeToProduce` (keep its signature and doc comment) to use it:

```lua
function OmniHubProduction.timeToProduce(recipe, goodsTable, capacity, minTime)
    if not recipe then return minTime end
    local totalValue, levelBonus = recipeValueAndBonus(recipe, goodsTable)
    local cap = math.max(1, capacity or 1)
    return math.max(minTime, totalValue / cap / levelBonus)
end
```

Add the new function directly after `timeToProduce`:

```lua
-- The production capacity above which timeToProduce bottoms out at minTime for EVERY installed
-- module — i.e. the smallest capacity that achieves max production speed. Per module that point
-- is totalValue / (minTime * levelBonus); the hub-wide recommendation is the max across modules
-- (each module ticks its own cycle, so capacity is not shared). Module count is irrelevant
-- (count scales amounts per cycle, not cycle time). Empty hub (or no resolvable recipe) -> 0.
function OmniHubProduction.recommendedCapacity(installed, resolveRecipe, goodsTable, minTime)
    local best = 0
    for key in pairs(installed) do
        local recipe = resolveRecipe(key)
        if recipe then
            local totalValue, levelBonus = recipeValueAndBonus(recipe, goodsTable)
            local needed = totalValue / (minTime * levelBonus)
            if needed > best then best = needed end
        end
    end
    return best
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: all pass — including the pre-existing `timeToProduce` tests (they protect the refactor).

- [ ] **Step 5: Commit**

```bash
git add data/scripts/lib/omnihub/production.lua data/scripts/lib/omnihub/tests/suites/production_spec.lua
git commit -m "feat(omnihub): recommendedCapacity — assembly needed for max production speed"
```

---

### Task 5: `events.lua` — module skeleton + trade digest

**Files:**
- Create: `data/scripts/lib/omnihub/events.lua`
- Create: `data/scripts/lib/omnihub/tests/suites/events_spec.lua`
- Modify: `data/scripts/lib/omnihub/tests/registry.lua` (add `"events_spec"` to `pure`)

- [ ] **Step 1: Write the failing tests**

Create `events_spec.lua`:

```lua
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
```

Register it in `registry.lua` — add to `OmniHubTestRegistry.pure` (alphabetical, after
`"config_spec"`):

```lua
    "events_spec",
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: FAIL — `lib/omnihub/events` not found / nil module.

- [ ] **Step 3: Implement the module with the digest**

Create `data/scripts/lib/omnihub/events.lua`:

```lua
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
    local text = "Trade summary: " .. table.concat(parts, "; ")
    if extra > 0 then text = text .. string.format(" +%d more", extra) end
    text = text .. string.format(" — net %s cr", formatMoney(net))
    return { text = text, severity = "info" }
end

-- ── clock ────────────────────────────────────────────────────────
-- Rolls all timers forward and returns the payloads now due (nil if none): drained queue entries
-- first, then a due trade digest, then a due stall/resume summary.
function OmniHubEvents.advance(s, dt)
    if not dt or dt <= 0 then return nil end
    local out = nil
    local function push(p)
        if not p then return end
        out = out or {}
        out[#out + 1] = p
    end

    if #s.queue > 0 then
        for _, p in ipairs(s.queue) do push(p) end
        s.queue = {}
    end

    if s.tradeClock ~= nil then
        s.tradeClock = s.tradeClock + dt
        if s.tradeClock >= DIGEST_INTERVAL then
            push(buildDigest(s))
            s.trades, s.tradeClock = {}, nil
        end
    end

    return out
end

return OmniHubEvents
```

(`stalls`/`stallClock`/`resumed`/`latches` are wired in Tasks 6-7; declared now so `new()` is
stable across tasks.)

- [ ] **Step 4: Run tests to verify pass**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: all pass, suite `events` green.

- [ ] **Step 5: Commit**

```bash
git add data/scripts/lib/omnihub/events.lua data/scripts/lib/omnihub/tests/suites/events_spec.lua data/scripts/lib/omnihub/tests/registry.lua
git commit -m "feat(omnihub): events module — 5-min trade digest (pure, tested)"
```

---

### Task 6: `events.lua` — trade failures + condition latches + persistence

**Files:**
- Modify: `data/scripts/lib/omnihub/events.lua`
- Test: `data/scripts/lib/omnihub/tests/suites/events_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the suite function of `events_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: FAIL — `tradeFailed` / `checkStorage` / `checkAssembly` / `secure` are nil.

- [ ] **Step 3: Implement**

Append to `events.lua` (between `buildDigest` and `advance`):

```lua
-- ── trade failures ───────────────────────────────────────────────
-- Immediate (next advance) per-failure messages. Kinds map 1:1 to the controller's existing
-- failure branches; each text names the fault AND the likely fix. NOTE: deliberately no repeat
-- cooldown (design decision) — a persistent fault re-reports every trade wave.
local FAIL_TEXT = {
    cantpay     = "Trade failed: can't afford %s x%d — deposit credits into the faction account.",
    nostock_in  = "Trade failed: delivery of %s x%d moved no goods (stock cap reached or the faction can't pay).",
    nostock_out = "Trade failed: pickup of %s x%d moved no goods (nothing in stock, buyer can't pay, or the ship's hold is full).",
    wave        = "Trade failed: immediate trade of %s x%d (error code %s).",
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add data/scripts/lib/omnihub/events.lua data/scripts/lib/omnihub/tests/suites/events_spec.lua
git commit -m "feat(omnihub): events — trade failures, storage/assembly latches, latch persistence"
```

---

### Task 7: `events.lua` — production-stall summaries

**Files:**
- Modify: `data/scripts/lib/omnihub/events.lua`
- Test: `data/scripts/lib/omnihub/tests/suites/events_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the suite function of `events_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: FAIL — `recordStallState` / `retainStalls` are nil.

- [ ] **Step 3: Implement**

Append to `events.lua` (after the persistence block, before `advance`):

```lua
-- ── production stalls ────────────────────────────────────────────
-- A module key is tracked while stalled on an ACTIONABLE reason ("ingredient", "space" — a
-- "maxstock" stall is the buffer working as intended). Crossing STALL_THRESHOLD marks it
-- report-pending; advance() batches all pending keys into ONE summary per STALL_INTERVAL. A
-- reason change restarts the timer (it is a different problem). Going un-stalled after having
-- been reported queues the product for a batched "resumed" line on the same cadence.
function OmniHubEvents.recordStallState(s, key, product, stalled, reason, detail)
    local actionable = stalled and (reason == "ingredient" or reason == "space")
    local e = s.stalls[key]
    if actionable then
        if not e or e.reason ~= reason or e.detail ~= detail then
            s.stalls[key] = { product = product, reason = reason, detail = detail,
                              stalledFor = 0, reported = false }
        end
    else
        if e then
            if e.reported then s.resumed[e.product] = true end
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
    for i, e in ipairs(pending) do
        e.reported = true
        if i <= MAX_LISTED then
            local rtext = STALL_REASON_TEXT[e.reason](e)
            if not groups[rtext] then groups[rtext] = {}; order[#order + 1] = rtext end
            table.insert(groups[rtext], e.product)
        else
            extra = extra + 1
        end
    end
    local parts = {}
    for _, rtext in ipairs(order) do
        parts[#parts + 1] = string.format("%s (%s)", table.concat(groups[rtext], ", "), rtext)
    end
    local text = "Production stalled for 10+ minutes: " .. table.concat(parts, "; ")
    if extra > 0 then text = text .. string.format(" +%d more", extra) end
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
    local text = "Production resumed: " .. table.concat(names, ", ")
    if extra > 0 then text = text .. string.format(" +%d more", extra) end
    return { text = text, severity = "info" }
end
```

Extend `advance` — insert before its final `return out`:

```lua
    for _, e in pairs(s.stalls) do
        e.stalledFor = e.stalledFor + dt
    end
    s.stallClock = s.stallClock + dt
    if s.stallClock >= STALL_INTERVAL then
        local stallSummary  = buildStallSummary(s)
        local resumeSummary = buildResumeSummary(s)
        if stallSummary or resumeSummary then
            s.stallClock = 0
            push(stallSummary)
            push(resumeSummary)
        end
    end
```

(`stallClock` only resets when something flushed, so a batch that becomes pending right after an
empty check still goes out on the next tick rather than waiting another full interval.)

- [ ] **Step 4: Run tests to verify pass**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add data/scripts/lib/omnihub/events.lua data/scripts/lib/omnihub/tests/suites/events_spec.lua
git commit -m "feat(omnihub): events — batched production-stall and resume summaries"
```

---

### Task 8: Controller — events state, emit funnel, tick, persistence, config RPC

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua`

All edits are in the server path; no pure tests apply (engine glue). The pure suite must still
pass (regression).

- [ ] **Step 1: Include the module**

After `local OmniHubRates = include("rates")` (line 20):

```lua
local OmniHubEvents = include("events")
```

- [ ] **Step 2: Add state + emit funnel**

Directly after the `hubWarn` function (line ~196), add:

```lua
-- ── Owner event notifications ────────────────────────────────────
-- All batching/latching/formatting is pure (lib/omnihub/events.lua); this is the single emission
-- funnel. eventsEnabled is the per-hub owner toggle (Config tab, persisted). The hub id is
-- appended only in dev mode — players don't need internal ids (the hub is the chat sender, and
-- the text carries name + sector + coords).
local hubEvents     = OmniHubEvents.new()
local eventsEnabled = true

local function emitEvent(payload)
    if not eventsEnabled or not payload then return end
    local entity  = Entity()
    local faction = Faction(entity.factionIndex)
    if not faction then return end
    local x, y     = Sector():getCoordinates()
    local hubName  = (entity.name ~= nil and entity.name ~= "") and entity.name
                     or (entity.title ~= "" and entity.title or "OmniHub")
    local id       = GameSettings().devMode and string.format(" #%s", tostring(entity.index)) or ""
    local msgType  = (payload.severity == "warning") and ChatMessageType.Warning
                     or ChatMessageType.Information
    faction:sendChatMessage(entity, msgType, string.format("%s (%d:%d)%s: %s",
        tostring(hubName), x, y, id, payload.text))
end
```

**Implementation check at this step:** vanilla precedent for the message style is
`tradingmanager.lua:889` (`faction:sendChatMessage(Entity(), 1, msg, ...)`). If the design's
sector *name* is wanted in addition to coords, verify `Sector().name` is server-readable in the
stubs (`grep -n "name" stubs/generated/sector.lua`); if it is, use
`string.format("%s [%s (%d:%d)]%s: %s", tostring(hubName), Sector().name, x, y, id, payload.text)`
instead. If the stub marks it client-only, ship coords-only (above) — do NOT guess.

- [ ] **Step 3: Drive the module from the update tick**

In `OmniHub.update` (line ~399), add after `OmniHubRates.advance(rates, timeStep)`:

```lua
    OmniHub.eventsTick(timeStep)
```

and add the function after `OmniHub.advanceStats` (line ~1062):

```lua
-- Rolls the event engine and emits whatever came due (digest, failures, condition edges, stall
-- summaries). Runs even with eventsEnabled off so timers/latches stay current — the gate is at
-- emit time, so re-enabling mid-flight doesn't replay stale state.
function OmniHub.eventsTick(timeStep)
    local due = OmniHubEvents.advance(hubEvents, timeStep)
    if not due then return end
    for _, payload in ipairs(due) do emitEvent(payload) end
end
```

- [ ] **Step 4: Persist the toggle + latches**

In `OmniHub.secure()` (line ~345), after `data.debug = hubDebug`:

```lua
    data.events        = eventsEnabled
    data.eventLatches  = OmniHubEvents.secure(hubEvents)
```

In `OmniHub.restore(data)` (line ~359), after `hubDebug = data.debug or false` and BEFORE the
`if onServer() then OmniHub.rebuild() end` line (rebuild evaluates conditions — Task 9 — and must
see the restored latches):

```lua
    eventsEnabled = data.events ~= false   -- default ON for hubs saved before this feature
    OmniHubEvents.restore(hubEvents, data.eventLatches)
```

- [ ] **Step 5: Config RPC round-trip**

In `OmniHub.sendHubConfigTo` (line ~1173), add to the `cfg` table after `debug = hubDebug,`:

```lua
        events          = eventsEnabled,
```

In `OmniHub.applyHubConfig` (line ~1190), after the `if cfg.debug ~= nil ...` line:

```lua
    -- Owner notifications toggle. nil-safe like debug: only update when the client sent it.
    if cfg.events ~= nil then eventsEnabled = cfg.events and true or false end
```

- [ ] **Step 6: Regression + commit**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.

```bash
git add data/scripts/entity/merchants/omnihubcontroller.lua
git commit -m "feat(omnihub): controller event funnel — emit, tick, persistence, config RPC"
```

---

### Task 9: Controller — hooks + log cleanup + recommended-capacity cache

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua`

- [ ] **Step 1: Cache the recommendation; evaluate conditions in `rebuild()`**

Add a file-local next to `maxLimitByGood` (line ~103):

```lua
local recommendedCapacity = 0  -- assembly needed for max speed; recomputed in rebuild()
```

At the END of `OmniHub.rebuild()` (line ~538, after the `timeToProduce` loop), add:

```lua
    -- Owner notifications: condition inputs (limits, capacity, install set) only change through
    -- here, onBlockPlanChanged, or recomputeMaxLimits — evaluate the latches at each.
    recommendedCapacity = OmniHubProduction.recommendedCapacity(
        installed, OmniHubModuleDefs.resolveRecipe, goods, MIN_TIME_TO_PRODUCE)
    OmniHubEvents.retainStalls(hubEvents, installed)
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
    OmniHubEvents.checkAssembly(hubEvents, OmniHub.productionCapacity, recommendedCapacity)
```

NOTE: `OmniHub.collectStorage` is defined later in the file (line ~1075) — that is fine, `rebuild`
only runs at call time. `goods` is the ambient goods index global.

- [ ] **Step 2: Evaluate conditions on plan change**

In `OmniHub.onBlockPlanChanged` (line ~308), append after the `timeToProduce` loop:

```lua
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
    OmniHubEvents.checkAssembly(hubEvents, OmniHub.productionCapacity, recommendedCapacity)
```

- [ ] **Step 3: Evaluate storage on config change**

At the end of `OmniHub.recomputeMaxLimits` (line ~584, after `maxLimitByGood = ...`):

```lua
    OmniHubEvents.checkStorage(hubEvents, OmniHub.collectStorage().over)
```

- [ ] **Step 4: Feed stall state from the production tick**

Add a helper above `OmniHub.tickRecipe` (line ~419):

```lua
-- Display name for stall messages: the module's catalog name ("Steel Factory"), key as fallback.
local function moduleDisplayName(key)
    local def = OmniHubModuleDefs.get(key)
    return (def and def.name) or tostring(key)
end
```

In `OmniHub.tickRecipe`:
- In the `if progress then` branch, add as the FIRST line inside the branch:

```lua
        OmniHubEvents.recordStallState(hubEvents, key, moduleDisplayName(key), false)
```

- After `productionStatus[key] = decision` (line ~464), add:

```lua
    OmniHubEvents.recordStallState(hubEvents, key, moduleDisplayName(key),
        not decision.canProduce, decision.reason, decision.good)
```

- [ ] **Step 5: Trade digest hooks (all four stats-recording sites)**

In `OmniHub.onDockedTradeBought` (line ~1016): DELETE the `hubLog("docked trade: bought ...")`
line and add after the `OmniHubStats.record` call:

```lua
    OmniHubEvents.recordTrade(hubEvents, "buy", goodName, amount, price)
```

In `OmniHub.onDockedTradeSold` (line ~1023): DELETE the `hubLog("docked trade: sold ...")` line
and add after the `OmniHubStats.record` call:

```lua
    OmniHubEvents.recordTrade(hubEvents, "sell", goodName, amount, price)
```

In `OmniHub.buyGoods` (line ~1035), inside `if onServer() and code == 0 then`, add after the
`OmniHubStats.record` call:

```lua
        OmniHubEvents.recordTrade(hubEvents, "buy", good.name, amount, price)
```

In `OmniHub.sellGoods` (line ~1045), same pattern:

```lua
        OmniHubEvents.recordTrade(hubEvents, "sell", good.name, amount, price)
```

- [ ] **Step 6: Trade failure hooks (replace the hubLog lines)**

In `OmniHub.buyFromShip` (line ~964):
- Replace `hubLog("docked delivery of %s x%s unaffordable ...)` (line ~981-982) with:

```lua
            OmniHubEvents.tradeFailed(hubEvents, "cantpay", goodName, amount)
```

- Replace `hubLog("docked delivery of %s x%s moved NO stock ...)` (line ~987-988) with:

```lua
        OmniHubEvents.tradeFailed(hubEvents, "nostock_in", goodName, amount)
```

In `OmniHub.sellToShip` (line ~993):
- Replace `hubLog("docked pickup of %s x%s moved NO stock ...)` (line ~997-998) with:

```lua
        OmniHubEvents.tradeFailed(hubEvents, "nostock_out", goodName, amount)
```

In `applyWaveImmediate` (line ~723):
- Replace `hubLog("immediate wave: %s %s x%d failed (code %s)" ...)` (line ~736-737) with:

```lua
                if err ~= 0 then
                    OmniHubEvents.tradeFailed(hubEvents, "wave", op.name, op.amount, err)
                end
```

(keeping the surrounding `if err ~= 0 then ... end` structure — only the body changes).

Also update the wrapper's stale doc comment (line ~960-963): it says failures are logged
"(debug-gated)" — change the last sentence to "Wrap both to raise an owner event whenever a
docked exchange moved no stock, with the likely reason."

- [ ] **Step 7: Regression + commit**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.
Run: `grep -n "docked trade:" data/scripts/entity/merchants/omnihubcontroller.lua` — expected: no output.

```bash
git add data/scripts/entity/merchants/omnihubcontroller.lua
git commit -m "feat(omnihub): wire owner events — trades, failures, stalls, conditions; drop covered debug logs"
```

---

### Task 10: Config tab checkbox

**Files:**
- Modify: `data/scripts/lib/omnihub/ui/config.lua`

- [ ] **Step 1: Add the checkbox**

In `OmniHubUIConfig.new` (line ~58), after the `self.activeSellCheck` block (line ~69-71) and
before the `left:nextRect(12)`:

```lua
    self.eventsCheck = tab:createCheckBox(Rect(), "Send event notifications"%_t, opts.changeCallback)
    left:placeElementTop(self.eventsCheck)
    self.eventsCheck.tooltip = "If checked, the hub messages its owners in chat: a periodic trade summary, failed trades, and warnings when cargo, assembly, or ingredients hold production back."%_t
```

- [ ] **Step 2: Apply + read**

In `OmniHubUIConfig:apply(cfg)` (line ~138), after the `activeSellCheck` line:

```lua
    self.eventsCheck:setCheckedNoCallback(cfg.events ~= false)
```

In `OmniHubUIConfig:read()` (line ~171), add to the returned table after `activelySell = ...,`:

```lua
        events          = self.eventsCheck.checked == true,
```

(Explicit boolean for the same reason documented above the `debug` field: `nil` means "keep
current" on the server, so unchecking must send `false`, never collapse to `nil`.)

- [ ] **Step 3: Regression + commit**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass (config UI has a pure spec for
widget-independent logic only; this change is exercised in-game).

```bash
git add data/scripts/lib/omnihub/ui/config.lua
git commit -m "feat(omnihub): 'Send event notifications' checkbox in hub Config tab"
```

---

### Task 11: Statistics tab — capacity line + payload

**Files:**
- Modify: `data/scripts/lib/omnihub/ui/statistics.lua`
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua` (`sendStats`, `receiveStats`)

- [ ] **Step 1: UI — add the label and `setCapacity`**

In `OmniHubUIStatistics.new` (statistics.lua line ~11): after the `self.storageSummary` block
(line ~32-33), add:

```lua
    -- Production capacity vs the recommended value for max speed (server-computed; see
    -- OmniHubProduction.recommendedCapacity). Red when under.
    self.capacityLabel = tab:createLabel(vec2(pad, 88), "", 13)
    self.capacityLabel.bold = true
    self.capacityLabel.tooltip = "Assembly blocks raise production capacity. At or above the recommended value every module cycles at maximum speed; extra capacity beyond it does not speed up production further."%_t
```

and change the layout line (line ~36) from:

```lua
    local areaTop, mid = 92, math.floor(92 + (h - 92) * 0.5)
```

to:

```lua
    local areaTop, mid = 110, math.floor(110 + (h - 110) * 0.5)
```

Add the setter after `setStorage` (line ~92):

```lua
-- setCapacity(capacity, recommended) — both server numbers; recommended 0 means "no modules".
function OmniHubUIStatistics:setCapacity(capacity, recommended)
    capacity, recommended = capacity or 0, recommended or 0
    if recommended <= 0 then
        self.capacityLabel.caption = string.format("Production capacity: %d", math.floor(capacity))
        self.capacityLabel.color   = ColorRGB(0.8, 0.8, 0.8)
        return
    end
    local pct = math.floor(capacity / recommended * 100 + 0.5)
    self.capacityLabel.caption = string.format("Production capacity: %d / %d recommended (%d%%)",
        math.floor(capacity), math.floor(recommended), pct)
    self.capacityLabel.color = capacity < recommended and ColorRGB(1.0, 0.5, 0.5)
                                                       or ColorRGB(0.8, 0.8, 0.8)
end
```

- [ ] **Step 2: Controller — extend the payload**

In `OmniHub.sendStats` (controller line ~1064), extend the `invokeClientFunction` with two more
arguments:

```lua
    invokeClientFunction(Player(callingPlayer), "receiveStats",
        OmniHubStats.lifetimeProfit(stats), OmniHubStats.lastHourProfit(stats), OmniHubStats.recent(stats, 10),
        OmniHub.collectStorage(), OmniHub.productionCapacity, recommendedCapacity)
```

In `OmniHub.receiveStats` (line ~1781):

```lua
function OmniHub.receiveStats(lifetime, lastHour, txns, storage, capacity, recommended)
    if statisticsUI then
        statisticsUI:set(lifetime, lastHour, txns)
        statisticsUI:setStorage(storage)
        statisticsUI:setCapacity(capacity, recommended)
    end
end
```

- [ ] **Step 3: Regression + commit**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua` — expected: all pass.

```bash
git add data/scripts/lib/omnihub/ui/statistics.lua data/scripts/entity/merchants/omnihubcontroller.lua
git commit -m "feat(omnihub): show production capacity vs recommended in Statistics tab"
```

---

### Task 12: README events section + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an "Owner notifications" section to the README**

Insert after the section that describes the trade UI tabs (find the Statistics/Config tab
description; place the new section adjacent), with this content:

```markdown
## Owner notifications

When **Send event notifications** is enabled in the hub's Config tab (default on), the hub
messages its owning faction in chat — alliance hubs message alliance chat:

- **Trade summary** — at most one line per 5 minutes: goods sold/bought (top 4 by value) and the
  net credits.
- **Failed trades** — immediately, with the reason and the fix (e.g. deposit credits into the
  faction account).
- **Storage warning** — once, when the cargo bay becomes too small to hold every good's max
  stock; a confirmation when resolved.
- **Assembly warning** — once, when production capacity drops below the recommended value shown
  in the Statistics tab; a confirmation when resolved.
- **Production stalls** — one batched summary when modules have been stalled for 10+ minutes on
  missing ingredients or cargo space (full output buffers are normal and stay silent), and a
  batched notice when they resume.
```

- [ ] **Step 2: Full off-engine suite**

Run: `"$LUA_DIR/lua54.exe" tests/run.lua`
Expected: exit 0, all suites green including `events`.

- [ ] **Step 3: Deploy dry-run**

Run: `python build.py --dry-run`
Expected: deploy list includes `data/scripts/lib/omnihub/events.lua` and the modified files; no
errors.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(omnihub): README — configurable founding cost, cargo-floor removal, owner notifications"
```

- [ ] **Step 5: In-game verification checklist (manual, dev mode)**

Deploy (`python build.py`), start the game with the mod, `/devmode`, then verify:

1. Station founder shows the configured price (change `Founding cost` in MCM if installed; found
   a hub; confirm charged amount). **Also verify the MCM client-sync risk:** set a non-default
   cost, confirm the founder UI (client) shows the same price the server charges.
2. Found a hub with a small ship: no phantom 25k hold (`/devmode`, check cargo capacity equals
   block-provided capacity).
3. Install modules, let traders run: ONE trade-summary chat line per ~5 min; toggling the Config
   checkbox off silences everything; back on resumes.
4. Drain the faction account: failed-delivery events appear with the deposit hint.
5. Starve a module of an ingredient for 10+ min: one batched stall line; supply the ingredient:
   one resumed line.
6. Shrink cargo / add modules until limits exceed capacity: storage warning once; add cargo:
   resolved once. Same for assembly via the Statistics tab numbers.
7. Hub id (`#<index>`) appears in event lines only while dev mode is on.
8. Save, reload the sector: no duplicate condition events on load.
```
