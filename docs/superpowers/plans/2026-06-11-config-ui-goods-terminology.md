# Config UI "Goods" Terminology + Dev-Gated Debug Checkbox — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the Configure tab around "goods" vocabulary, restructure the limits section into two headed groups, and make the dev-only debug checkbox server-authoritative and dynamically hidden.

**Architecture:** Pure rename/relayout inside the client-only `ui/config.lua`, with matching wire-key renames (`limitBuy/limitBase/limitCycles` → `tradeStock/prodBase/prodCycles`) on both ends of the config RPC in `omnihubcontroller.lua`. The server now ships `devMode` in the config payload; the client builds the debug checkbox always (bottom of tab, hidden) and toggles visibility on every sync. Persisted save keys (`maxLimit.buyLimit/prodBase/prodCycles`), `maxlimit.lua` params, and vanilla `activelyRequest/activelySell` are deliberately untouched.

**Tech Stack:** Avorion Lua 5.4 mod; off-engine test runner `"$LUA_DIR/lua54.exe" tests/run.lua`; deploy via `python build.py`.

**Spec:** `docs/superpowers/specs/2026-06-11-config-ui-goods-terminology-design.md`

**Note on TDD:** the touched files are client-UI and engine-coupled controller code, which the off-engine (pure) suites cannot execute — there is no pure module change here. The pure suite is run as a regression gate; `integration_spec.lua` (in-game suite) is updated in lockstep with the wire keys. All edits land in ONE commit because the wire keys must match across client and server files — an intermediate commit would be a broken mod state.

---

### Task 1: Feature branch

**Files:** none

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feature/config-ui-goods-terms
```

Expected: `Switched to a new branch 'feature/config-ui-goods-terms'`

---

### Task 2: Rewrite `data/scripts/lib/omnihub/ui/config.lua`

**Files:**
- Modify: `data/scripts/lib/omnihub/ui/config.lua` (full-file replacement below)

What changes vs. current file:
- All labels/tooltips use "goods" (see spec table).
- Section restructure: header `Max goods stock (units)` → field `Max buy/sell goods stock`; new header `Max production stock` → `Production base` + `Production cycles`.
- Debug checkbox: always built, moved to the BOTTOM of the lister, `visible = false` until `apply()` sees `cfg.devMode == true`. No more client-side `GameSettings().devMode` check.
- `read()` reports `debug` only while the checkbox is visible (nil otherwise = "keep current" on the server).
- Renames: `limitBuyBox→tradeStockBox`, `limitBaseBox→prodBaseBox`, `limitCyclesBox→prodCyclesBox`, `limitBoxes→stockBoxes`, `limitCommitted→stockCommitted`, `setLimitBox→setStockBox`, `pollLimitCommit→pollStockCommit`; wire keys `limitBuy/limitBase/limitCycles → tradeStock/prodBase/prodCycles`.

- [ ] **Step 1: Replace the file content with exactly this**

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubUIConfig
-- Client-only Configuration tab: actively-buy / actively-sell checkboxes, two price sliders
-- (buy/sell goods, ±20%), the per-good max-stock fields, and the dev-only debug checkbox (hidden
-- unless the server reports dev mode). Holds its own widget state and exposes read()/apply() for
-- the controller; the single change handler name (opts.changeCallback) is wired by the controller
-- to push config to the server.
OmniHubUIConfig = {}
OmniHubUIConfig.__index = OmniHubUIConfig

-- Maps a price factor (0.8..1.2) to slider units (-20..20) and back.
local function factorToSlider(f) return round(((f or 1.0) - 1.0) * 100) end
local function sliderToFactor(v) return 1.0 + (v or 0) / 100.0 end

-- Adds a captioned numeric text box (digits only) to a vertical lister and returns the box. NO
-- per-keystroke callback: committing every character round-trips to the server, which clamps/floors the
-- partial value and echoes it back, overwriting what you're typing. Instead the box commits on
-- focus-out / Enter — pollStockCommit (driven by the controller's updateClient) watches isTypingActive.
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

-- Sets a stock box's text without stomping it while the player is typing, and records the shown value
-- as the committed baseline so pollStockCommit only fires on a real edit.
function OmniHubUIConfig:setStockBox(box, idx, val)
    if not box or box.isTypingActive then return end
    local text = (val ~= nil) and tostring(val) or ""
    box.text = text
    self.stockCommitted[idx] = text
end

-- Called each client tick by the controller. Commits a stock field once it LOSES focus (isTypingActive
-- false) with a value different from what was last committed — i.e. on focus-out or Enter, not per
-- keystroke. Returns true if anything changed (the controller then pushes the full config).
function OmniHubUIConfig:pollStockCommit()
    if not self.stockBoxes then return false end
    local changed = false
    for i, box in ipairs(self.stockBoxes) do
        if not box.isTypingActive and box.text ~= self.stockCommitted[i] then
            self.stockCommitted[i] = box.text
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

    self.activeBuyCheck = tab:createCheckBox(Rect(), "Actively buy goods"%_t, opts.changeCallback)
    left:placeElementTop(self.activeBuyCheck)
    self.activeBuyCheck.tooltip = "If checked, the hub summons traders to deliver the goods it needs when it runs low."%_t

    self.activeSellCheck = tab:createCheckBox(Rect(), "Actively sell goods"%_t, opts.changeCallback)
    left:placeElementTop(self.activeSellCheck)
    self.activeSellCheck.tooltip = "If checked, the hub summons traders to buy its goods when stocks get full."%_t

    left:nextRect(12)

    self.buyPriceLabel = tab:createLabel(Rect(), "Buy goods at 100%"%_t, 12)
    left:placeElementTop(self.buyPriceLabel)
    self.buyPriceLabel.centered = true
    -- Sliders update their % label live (priceMovedCallback) while dragging, but only commit to the
    -- server + recompute prices once, on mouse release (onMouseUpChangedFunction = priceCommitCallback).
    self.buyPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.buyPriceSlider)
    self.buyPriceSlider.unit = "%"
    self.buyPriceSlider:setValueNoCallback(0)
    self.buyPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.buyPriceSlider.tooltip = "Price the hub pays for goods it buys. A higher price attracts more sellers."%_t

    left:nextRect(6)

    self.sellPriceLabel = tab:createLabel(Rect(), "Sell goods at 100%"%_t, 12)
    left:placeElementTop(self.sellPriceLabel)
    self.sellPriceLabel.centered = true
    self.sellPriceSlider = tab:createSlider(Rect(), -20, 20, 40, "", opts.priceMovedCallback)
    left:placeElementTop(self.sellPriceSlider)
    self.sellPriceSlider.unit = "%"
    self.sellPriceSlider:setValueNoCallback(0)
    self.sellPriceSlider.onMouseUpChangedFunction = opts.priceCommitCallback
    self.sellPriceSlider.tooltip = "Price the hub charges for goods it sells. A lower price attracts more buyers."%_t

    left:nextRect(12)

    -- ── Max goods stock (passthrough trade goods cap, in units) ──────────────
    local tradeHeader = tab:createLabel(Rect(), "Max goods stock (units)"%_t, 12)
    left:placeElementTop(tradeHeader); tradeHeader.centered = true

    self.tradeStockBox = self:numField(tab, left, "Max buy/sell goods stock"%_t,
        "Max units stocked of each good marked Buy or Sell that the hub neither produces nor consumes (a passthrough trade good). 0 = don't stockpile it."%_t)

    left:nextRect(6)

    -- ── Max production stock (produced/consumed goods cap) ───────────────────
    local prodHeader = tab:createLabel(Rect(), "Max production stock"%_t, 12)
    left:placeElementTop(prodHeader); prodHeader.centered = true

    self.prodBaseBox = self:numField(tab, left, "Production base"%_t,
        "Base multiplier for goods the hub produces or consumes. Max stock = base x cycles x the good's per-cycle amount across all modules."%_t)
    self.prodCyclesBox = self:numField(tab, left, "Production cycles"%_t,
        "How many production cycles of buffer to keep for produced/consumed goods. The hub stops a good's production once it reaches the max stock (or the cargo bay is full)."%_t)

    left:nextRect(12)

    -- Dev-only: production debug logging. ALWAYS built — at the bottom, so hiding it leaves no gap —
    -- but visible only when the SERVER reports dev mode in the config payload (see apply). The server
    -- stays authoritative: the client's own GameSettings().devMode reflects the locally persisted
    -- /devmode state, which can disagree with the server and goes stale (initUI runs once).
    self.debugCheck = tab:createCheckBox(Rect(), "Debug production logging (dev)"%_t, opts.changeCallback)
    left:placeElementTop(self.debugCheck)
    self.debugCheck.tooltip = "Dev only. Periodically prints each module's production state (active / stalled + reason) to the server log."%_t
    self.debugCheck.visible = false

    -- Ordered list + committed baseline for focus-out commits (see pollStockCommit).
    self.stockBoxes     = { self.tradeStockBox, self.prodBaseBox, self.prodCyclesBox }
    self.stockCommitted = { self.tradeStockBox.text, self.prodBaseBox.text, self.prodCyclesBox.text }

    return self
end

-- Applies a server config table to the widgets (no callbacks fire).
function OmniHubUIConfig:apply(cfg)
    if not cfg then return end
    self.activeBuyCheck:setCheckedNoCallback(cfg.activelyRequest ~= false)
    self.activeSellCheck:setCheckedNoCallback(cfg.activelySell ~= false)

    -- Server-authoritative dev gate, re-evaluated on every config sync. nil (older server build /
    -- missing key) fails closed: the checkbox stays hidden.
    self.debugCheck.visible = cfg.devMode == true
    self.debugCheck:setCheckedNoCallback(cfg.debug == true)

    self.buyPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorBuy))
    self.sellPriceSlider:setValueNoCallback(factorToSlider(cfg.priceFactorSell))
    self:refreshPriceLabels()

    if self.stockBoxes then
        -- Skips any field currently being typed in (setStockBox), so the server echo never stomps it.
        self:setStockBox(self.tradeStockBox, 1, cfg.tradeStock)
        self:setStockBox(self.prodBaseBox,   2, cfg.prodBase)
        self:setStockBox(self.prodCyclesBox, 3, cfg.prodCycles)
    end
end

function OmniHubUIConfig:refreshPriceLabels()
    self.buyPriceLabel.caption  = "Buy goods at ${p}%"%_t  % { p = round(sliderToFactor(self.buyPriceSlider.value) * 100) }
    self.sellPriceLabel.caption = "Sell goods at ${p}%"%_t % { p = round(sliderToFactor(self.sellPriceSlider.value) * 100) }
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
    -- toggle could never be turned off. nil while the checkbox is hidden (non-dev), so a non-dev
    -- client can never clear a debug session a dev started.
    local debug = nil
    if self.debugCheck.visible then debug = self.debugCheck.checked == true end
    return {
        activelyRequest = self.activeBuyCheck.checked,
        activelySell    = self.activeSellCheck.checked,
        priceFactorBuy  = sliderToFactor(self.buyPriceSlider.value),
        priceFactorSell = sliderToFactor(self.sellPriceSlider.value),
        -- tonumber("") -> nil; the server treats nil as "keep current" (nil-safe clamp).
        tradeStock = tonumber(self.tradeStockBox.text),
        prodBase   = tonumber(self.prodBaseBox.text),
        prodCycles = tonumber(self.prodCyclesBox.text),
        debug      = debug,
    }
end

return OmniHubUIConfig
```

- [ ] **Step 2: Sanity-check the file parses (Lua 5.4 syntax only — engine globals won't resolve, so only a syntax check)**

```bash
"$LUA_DIR/lua54.exe" -e "local f, err = loadfile('data/scripts/lib/omnihub/ui/config.lua'); assert(f, err); print('syntax OK')"
```

Expected: `syntax OK`

---

### Task 3: Controller — wire keys, devMode flag, poll rename

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua:1151-1163` (sendHubConfigTo)
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua:1177-1185` (applyHubConfig limits)
- Modify: `data/scripts/entity/merchants/omnihubcontroller.lua:1665-1672` (updateClient)

- [ ] **Step 1: sendHubConfigTo — rename wire keys, add devMode**

Replace:

```lua
function OmniHub.sendHubConfigTo(player)
    local cfg = {
        activelyRequest = OmniHub.trader.activelyRequest,
        activelySell    = OmniHub.trader.activelySell,
        priceFactorBuy  = OmniHub.trader.buyPriceFactor,
        priceFactorSell = OmniHub.trader.sellPriceFactor,
        limitBuy        = hubMaxLimit.buyLimit,
        limitBase       = hubMaxLimit.prodBase,
        limitCycles     = hubMaxLimit.prodCycles,
        debug           = hubDebug,
    }
    invokeClientFunction(player, "receiveHubConfig", cfg)
end
```

with:

```lua
function OmniHub.sendHubConfigTo(player)
    local cfg = {
        activelyRequest = OmniHub.trader.activelyRequest,
        activelySell    = OmniHub.trader.activelySell,
        priceFactorBuy  = OmniHub.trader.buyPriceFactor,
        priceFactorSell = OmniHub.trader.sellPriceFactor,
        tradeStock      = hubMaxLimit.buyLimit,
        prodBase        = hubMaxLimit.prodBase,
        prodCycles      = hubMaxLimit.prodCycles,
        debug           = hubDebug,
        -- Server-authoritative dev gate for the client's debug checkbox: the client's own
        -- GameSettings().devMode can disagree (locally persisted /devmode) and goes stale.
        devMode         = GameSettings().devMode == true,
    }
    invokeClientFunction(player, "receiveHubConfig", cfg)
end
```

- [ ] **Step 2: applyHubConfig — read the new wire keys**

Replace (inside `OmniHub.applyHubConfig`):

```lua
    local limitsChanged =
            cfg.limitBuy ~= nil or cfg.limitBase ~= nil or cfg.limitCycles ~= nil
    hubMaxLimit.buyLimit   = math.floor(clamp(cfg.limitBuy    or hubMaxLimit.buyLimit,   0, 1000000))
    hubMaxLimit.prodBase   = math.floor(clamp(cfg.limitBase   or hubMaxLimit.prodBase,   1, 1000000))
    hubMaxLimit.prodCycles = math.floor(clamp(cfg.limitCycles or hubMaxLimit.prodCycles, 1, 10000))
```

with:

```lua
    local limitsChanged =
            cfg.tradeStock ~= nil or cfg.prodBase ~= nil or cfg.prodCycles ~= nil
    hubMaxLimit.buyLimit   = math.floor(clamp(cfg.tradeStock or hubMaxLimit.buyLimit,   0, 1000000))
    hubMaxLimit.prodBase   = math.floor(clamp(cfg.prodBase   or hubMaxLimit.prodBase,   1, 1000000))
    hubMaxLimit.prodCycles = math.floor(clamp(cfg.prodCycles or hubMaxLimit.prodCycles, 1, 10000))
```

(The comment block directly above — "Max-limit tuning (nil-safe…" — stays as is; it describes server fields, which keep their names.)

- [ ] **Step 3: updateClient — renamed poll method**

Replace:

```lua
-- Client-only tick (engine calls updateClient after update). While the window is open, commit Max Limit
-- fields that lost focus / took an Enter (pollLimitCommit), pushing the full config once per edit — no
-- per-keystroke RPC. Defined here so it can see the client-local configUI upvalue.
function OmniHub.updateClient(timeStep)
    if OmniHub.windowOpen and configUI and configUI:pollLimitCommit() then
        OmniHub.onConfigChanged()
    end
end
```

with:

```lua
-- Client-only tick (engine calls updateClient after update). While the window is open, commit max-stock
-- fields that lost focus / took an Enter (pollStockCommit), pushing the full config once per edit — no
-- per-keystroke RPC. Defined here so it can see the client-local configUI upvalue.
function OmniHub.updateClient(timeStep)
    if OmniHub.windowOpen and configUI and configUI:pollStockCommit() then
        OmniHub.onConfigChanged()
    end
end
```

- [ ] **Step 4: Verify no stale references remain**

```bash
grep -n "limitBuy\|limitBase\|limitCycles\|pollLimitCommit\|setLimitBox\|limitBoxes\|limitCommitted" data/scripts/entity/merchants/omnihubcontroller.lua data/scripts/lib/omnihub/ui/config.lua
```

Expected: no output (exit code 1).

---

### Task 4: Statistics tab wording

**Files:**
- Modify: `data/scripts/lib/omnihub/ui/statistics.lua:70` and `:77`

- [ ] **Step 1: Reword the over-capacity warning**

Replace:

```lua
            "Cargo too small for all max limits — some production may stall. Add cargo space."%_t, 12)
```

with:

```lua
            "Cargo too small for all goods stocks — some production may stall. Add cargo space."%_t, 12)
```

- [ ] **Step 2: Reword the empty-list label (same vocabulary)**

Replace:

```lua
            "No goods have a max limit yet."%_t, 12)
```

with:

```lua
            "No goods have a max stock yet."%_t, 12)
```

---

### Task 5: In-game integration spec — new wire keys

**Files:**
- Modify: `data/scripts/lib/omnihub/tests/suites/integration_spec.lua:239-243`

- [ ] **Step 1: Update the applyHubConfig call**

Replace:

```lua
        -- prodCycles = 0 must floor to 1 (0 would silently halt production); buyLimit = 0 is allowed.
        OmniHub.applyHubConfig({
            activelyRequest = true, activelySell = true,
            limitBuy = 0, limitBase = 200, limitCycles = 0,
        })
```

with:

```lua
        -- prodCycles = 0 must floor to 1 (0 would silently halt production); tradeStock = 0 is allowed.
        OmniHub.applyHubConfig({
            activelyRequest = true, activelySell = true,
            tradeStock = 0, prodBase = 200, prodCycles = 0,
        })
```

(The assertions below it read `OmniHub.secure().maxLimit.buyLimit/prodBase/prodCycles` — those are the
persisted server field names, deliberately unchanged. Do NOT edit them.)

- [ ] **Step 2: Confirm no other suite/file uses the old wire keys**

```bash
grep -rn "limitBuy\|limitBase\|limitCycles" data/scripts/
```

Expected: no output (exit code 1).

---

### Task 6: Regression-test and commit

**Files:** none new

- [ ] **Step 1: Run the off-engine pure suite**

```bash
"$LUA_DIR/lua54.exe" tests/run.lua
```

Expected: exit code 0, all suites PASS (the pure suites don't touch the renamed wire keys, so this is a regression gate).

- [ ] **Step 2: Commit everything together (wire keys must stay consistent across files)**

```bash
git add data/scripts/lib/omnihub/ui/config.lua data/scripts/entity/merchants/omnihubcontroller.lua data/scripts/lib/omnihub/ui/statistics.lua data/scripts/lib/omnihub/tests/suites/integration_spec.lua
git commit -m "feat(omnihub): unify config UI on 'goods' wording; server-gated debug checkbox

- Labels/tooltips: resources/products -> goods; limits section split into
  'Max goods stock (units)' and new 'Max production stock' headers
- Fix stale tooltip: passthrough stock cap applies to Buy AND Sell marks
- Debug checkbox now server-authoritative (devMode in config payload),
  always built at tab bottom, hidden unless server dev mode; read() only
  reports debug while visible
- Wire keys limitBuy/limitBase/limitCycles -> tradeStock/prodBase/prodCycles
  (RPC-only; persisted maxLimit.* save keys unchanged)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Deploy + manual verification

**Files:** none

- [ ] **Step 1: Deploy to the local mods dir**

```bash
python build.py
```

Expected: copy summary ending in the mod folder under `$AVORION_MODS_DIR`, no errors.

- [ ] **Step 2: Hand off in-game checks to the user**

User verifies on a hub station's Configure tab:
1. Labels read: "Actively buy goods", "Actively sell goods", "Buy goods at X%", "Sell goods at X%", header "Max goods stock (units)", field "Max buy/sell goods stock", new header "Max production stock", then "Production base"/"Production cycles".
2. With dev mode OFF: no debug checkbox anywhere (including after reopening the window).
3. With dev mode ON (`/devmode`, restart): checkbox appears at the bottom after the window opens (first config sync), toggles still work, and editing stock fields still commits on focus-out/Enter.
4. Statistics tab over-capacity warning says "goods stocks" (visible only when cargo is over capacity).

---

## Self-Review (done at planning time)

- **Spec coverage:** §1 dev gate → Tasks 2+3; §2 wording table → Tasks 2+4; §3 renames → Tasks 2+3+5; §4 verification → Tasks 6+7. No gaps.
- **Placeholders:** none; every step carries the literal code.
- **Type consistency:** wire keys `tradeStock/prodBase/prodCycles` identical in `read()`, `apply()`, `sendHubConfigTo`, `applyHubConfig`, and the spec; method names `pollStockCommit`/`setStockBox` match between `ui/config.lua` and the controller call site.
