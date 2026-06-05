# MCM Config + Supplier Shop Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move OmniHub configuration into the in-game Mod Configuration Menu (MCM) and redesign the OmniHub Supplier shop to sell a configurable rotating random subset of factory modules with a special offer, a dev-only refresh button, and pagination.

**Architecture:** MCM (Workshop id `3674093144`) is an *optional* dependency. A root `modconfig.lua` schema defines all options and their defaults; `OmniHubConfig.get` binds MCM once at load (pcall-guarded) and delegates, falling back to a built-in `defaults` table when MCM is absent. The supplier picks `sellingModuleCount` distinct random catalog keys per restock, flags one as the vanilla special offer, and (final phase) paginates the Buy tab when the count exceeds the 15-line page.

**Tech Stack:** Avorion Lua (sandboxed 5.x), the vanilla `shop` framework (`data/scripts/lib/shop.lua`), MCM `include("mcm")` API, the project's off-engine test harness (`tests/run.lua` + `tests/mocks/engine.lua`) and in-game dev Tests tab.

**Spec:** `docs/superpowers/specs/2026-06-05-mcm-config-supplier-shop-design.md`

**Reference — run the off-engine suite (from repo root):**
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Exit `0` = all pass, `1` = any failure.

---

## Testing Requirements (apply to EVERY task)

Lua reads a missing table field as `nil` silently, so typos and absent functions/properties don't
error at definition — they surface later as "attempt to index a nil value". This project has hit that
repeatedly. Guard against it in two ways on every task:

1. **Contract assertions (runtime).** Whenever a task adds or depends on a module/table, assert the
   members it relies on **exist and have the expected type** before using them. Patterns:
   - `eq(type(OmniHubSupplierStock.pickRandomSubset), "function", "pickRandomSubset exists")`
   - `notn(OmniHubConfig.defaults, "defaults table exists")`
   - For function results that are tables, assert each expected key is present and typed.
   - For engine-coupled code (supplier), add the existence checks to the **integration** suite
     (e.g. assert `OmniHubSupplier.shop.setSpecialOffer`, `.restock`, `.buyTab`, `.soldItemLines`,
     `.itemsPerPage` exist before relying on them) since they can't run off-engine.

2. **Static diagnostics.** After editing any `.lua` file, run IDE diagnostics on it
   (`mcm__ide__getDiagnostics` for the file URI) and treat **new** `undefined-global`,
   `undefined-field`, or `inject-field`/nil-access warnings as failures to investigate — the `stubs/`
   directory makes these meaningful. Pre-existing false positives (engine UI globals already flagged
   elsewhere, e.g. `Rarity`, `Tooltip`, `TooltipLine`) may be left, but anything referencing a name
   or field that genuinely doesn't exist must be fixed before commit.

A task is not "done" until both its behavior tests AND its contract/diagnostic checks pass.

---

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `modconfig.lua` | Create (repo root) | MCM schema: pages/options + defaults |
| `data/scripts/lib/omnihub/config.lua` | Modify | MCM-aware `get(key)` + percent conversion + `sellingModuleCount` default |
| `data/scripts/lib/omnihub/supplierstock.lua` | Create | Pure helpers: `pickRandomSubset`, `pickSpecialOffer`, `pageSlice` |
| `data/scripts/entity/merchants/omnihubsupplier.lua` | Modify | Subset stock, special offer, dev refresh button, paged Buy tab |
| `modinfo.lua` | Modify | Add optional MCM dependency |
| `build.py` | Modify | Whitelist `modconfig.lua` for deploy |
| `tests/mocks/engine.lua` | Modify | Expose repo-root modconfig path global |
| `data/scripts/lib/omnihub/tests/suites/config_spec.lua` | Modify | Fallback fractions + `sellingModuleCount` default |
| `data/scripts/lib/omnihub/tests/suites/modconfig_spec.lua` | Create | Schema ↔ defaults consistency (off-engine) |
| `data/scripts/lib/omnihub/tests/suites/supplier_spec.lua` | Create | Pure subset/special-offer/pagination tests |
| `data/scripts/lib/omnihub/tests/suites/integration_spec.lua` | Modify | Live MCM round-trip + real-catalog subset |
| `data/scripts/lib/omnihub/tests/registry.lua` | Modify | Register `modconfig_spec`, `supplier_spec` |

---

## PHASE 1 — MCM configuration

### Task 1: Create the MCM schema (`modconfig.lua`) and deploy it

**Files:**
- Create: `modconfig.lua` (repo root)
- Modify: `build.py:35`

- [ ] **Step 1: Write `modconfig.lua` at the repo root**

```lua
-- MCM (Mod Configuration Menu) schema for KTech OmniHub.
-- Auto-discovered by MCM (workshop id 3674093144) at startup; returns a pages/options table.
-- DEFAULTS LIVE HERE. data/scripts/lib/omnihub/config.lua mirrors them as a fallback for when
-- MCM is not installed; the modconfig_spec test asserts the two stay in sync.
-- Percent options (modulePriceFactor, dropChance) are stored as INTEGER percents here (100, 50);
-- OmniHubConfig.get divides them by 100 so callers receive fractions (1.0, 0.5).
return {
    pages = {
        {
            title = "OmniHub",
            options = {
                {
                    key         = "sellingModuleCount",
                    type        = "number",
                    title       = "Modules for sale",
                    description = "How many factory modules the OmniHub Supplier stocks at once.",
                    default     = 10,
                    min         = 1,
                    max         = 50,
                },
                {
                    key         = "modulePriceFactor",
                    type        = "slider",
                    title       = "Module price",
                    description = "Multiplier on module shop price. 100% = vanilla factory cost.",
                    default     = 100,
                    min         = 10,
                    max         = 500,
                    step        = 10,
                    unit        = "%",
                },
                {
                    key         = "moduleCap",
                    type        = "number",
                    title       = "Installed module cap",
                    description = "Maximum installed module units per hub. -1 = unlimited.",
                    default     = -1,
                    min         = -1,
                    max         = 999,
                },
                {
                    key         = "dropChance",
                    type        = "slider",
                    title       = "Module drop chance",
                    description = "Chance each installed unit drops as loot when the hub is destroyed.",
                    default     = 50,
                    min         = 0,
                    max         = 100,
                    step        = 5,
                    unit        = "%",
                },
                {
                    key         = "traderRequestCooldown",
                    type        = "number",
                    title       = "Trader request cooldown",
                    description = "Seconds between auto-sell trader spawn attempts.",
                    default     = 90,
                    min         = 10,
                    max         = 600,
                },
            },
        },
    },
}
```

- [ ] **Step 2: Whitelist `modconfig.lua` in `build.py`**

In `build.py`, change line 35 from:

```python
WHITELIST = ["modinfo.lua", "data"]          # copied recursively (dirs) / as-is (files)
```

to:

```python
WHITELIST = ["modinfo.lua", "modconfig.lua", "data"]  # copied recursively (dirs) / as-is (files)
```

- [ ] **Step 3: Verify the schema is valid Lua and loads to a table**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "local t = dofile('modconfig.lua'); assert(type(t)=='table' and #t.pages==1 and #t.pages[1].options==5, 'schema shape'); print('modconfig OK: '..#t.pages[1].options..' options')"
```
Expected: `modconfig OK: 5 options`

- [ ] **Step 4: Commit**

```sh
git add modconfig.lua build.py
git commit -m "feat: add MCM modconfig.lua schema and deploy it via build.py"
```

---

### Task 2: Make `OmniHubConfig` MCM-aware (bind once, percent conversion, new default)

**Files:**
- Modify: `data/scripts/lib/omnihub/config.lua`
- Test: `data/scripts/lib/omnihub/tests/suites/config_spec.lua`

- [ ] **Step 1: Extend `config_spec.lua` with the new default and percent-fallback assertions**

Replace the entire body of `data/scripts/lib/omnihub/tests/suites/config_spec.lua` with:

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq   = OmniHubTest.assertEqual
local nilf = OmniHubTest.assertNil

-- Pure suite: with MCM absent (the off-engine harness has no "mcm" module), OmniHubConfig.get
-- returns the built-in fractional defaults. Percent keys must come back as fractions, not percents.
return function(runner)
    runner:suite("config")

    runner:test("module contract: get + defaults exist", function()
        eq(type(OmniHubConfig.get),      "function", "OmniHubConfig.get is a function")
        eq(type(OmniHubConfig.defaults), "table",    "OmniHubConfig.defaults is a table")
        for _, key in ipairs({"moduleCap", "dropChance", "modulePriceFactor",
                              "traderRequestCooldown", "sellingModuleCount"}) do
            OmniHubTest.assertNotNil(OmniHubConfig.defaults[key], "defaults has key: " .. key)
        end
    end)

    runner:test("get returns documented defaults", function()
        eq(OmniHubConfig.get("moduleCap"),             -1,   "moduleCap default")
        eq(OmniHubConfig.get("dropChance"),            0.5,  "dropChance default (fraction)")
        eq(OmniHubConfig.get("modulePriceFactor"),     1.0,  "modulePriceFactor default (fraction)")
        eq(OmniHubConfig.get("traderRequestCooldown"), 90,   "traderRequestCooldown default")
        eq(OmniHubConfig.get("sellingModuleCount"),    10,   "sellingModuleCount default")
    end)

    runner:test("get returns nil for unknown key", function()
        nilf(OmniHubConfig.get("doesNotExist"), "unknown key should be nil")
    end)
end
```

- [ ] **Step 2: Run the suite to verify the new assertion FAILS**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: FAIL — `config :: get returns documented defaults` errors on
`sellingModuleCount default: expected 10, got nil` (the key isn't in `defaults` yet).

- [ ] **Step 3: Rewrite `config.lua` to add the default, MCM binding, and percent conversion**

Replace the entire contents of `data/scripts/lib/omnihub/config.lua` with:

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubConfig
OmniHubConfig = {}

-- Built-in defaults, used when MCM is not installed. These are the FRACTIONAL forms callers expect
-- (dropChance/modulePriceFactor as 0.5/1.0). The MCM schema in modconfig.lua stores those two as
-- integer percents (50/100); get() divides the MCM-returned value by 100. modconfig_spec asserts
-- the two stay consistent.
OmniHubConfig.defaults = {
    moduleCap             = -1,   -- -1 = unlimited; >= 0 = hard cap on total installed module units
    dropChance            = 0.5,  -- probability each installed module unit drops on hub destruction
    modulePriceFactor     = 1.0,  -- multiplier applied to getFactoryCost() for module shop prices
    traderRequestCooldown = 90,   -- seconds between trader spawn attempts (matches vanilla factory.lua)
    sellingModuleCount    = 10,   -- how many modules the OmniHub Supplier stocks at once
}

-- Keys MCM stores as integer percents; converted to fractions on read.
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- Resolve + bind MCM ONCE at load. include() throws on a missing module and MCM is an OPTIONAL
-- dependency, so guard with pcall: absent MCM -> config nil -> built-in defaults are used.
-- "ktech-omnihub" must match the `name` field in modinfo.lua (MCM keys mods by that name).
local ok, mcm = pcall(include, "mcm")
local config  = (ok and mcm) and mcm.bind("ktech-omnihub") or nil

-- Returns the config value for key. Reads from MCM on-demand when present (so admin changes take
-- effect immediately), else from the built-in defaults.
function OmniHubConfig.get(key)
    if config then
        local raw = config.get(key)  -- MCM returns the schema default when unset, nil if unknown
        if PERCENT_KEYS[key] and type(raw) == "number" then
            raw = raw / 100
        end
        return raw
    end
    return OmniHubConfig.defaults[key]  -- already fractional; do NOT divide again
end

return OmniHubConfig
```

- [ ] **Step 4: Run the suite to verify it PASSES**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: PASS — `0 failed`. The `config` suite now also asserts `sellingModuleCount == 10` and that
the percent keys come back as fractions (`0.5`, `1.0`). (We added assertions, not new test cases, so
the total count is unchanged from before this task.)

- [ ] **Step 5: Commit**

```sh
git add data/scripts/lib/omnihub/config.lua data/scripts/lib/omnihub/tests/suites/config_spec.lua
git commit -m "feat: MCM-aware OmniHubConfig with percent conversion and sellingModuleCount default"
```

---

### Task 3: Schema ↔ defaults consistency test (`modconfig_spec`)

**Files:**
- Modify: `tests/mocks/engine.lua` (expose repo-root modconfig path)
- Modify: `tests/run.lua` is unchanged (it already passes `repoRoot` to setup)
- Create: `data/scripts/lib/omnihub/tests/suites/modconfig_spec.lua`
- Modify: `data/scripts/lib/omnihub/tests/registry.lua`

- [ ] **Step 1: Expose the repo-root modconfig path in the harness**

In `tests/mocks/engine.lua`, inside the returned `function(repoRoot)` body, add this line near the top
(right after the opening `return function(repoRoot)` line, before the `_t` setup):

```lua
    -- Lets modconfig_spec locate the mod-root modconfig.lua when running off-engine.
    _G.OMNIHUB_MODCONFIG_PATH = repoRoot .. "/modconfig.lua"
```

- [ ] **Step 2: Create `modconfig_spec.lua`**

Create `data/scripts/lib/omnihub/tests/suites/modconfig_spec.lua`:

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest   = include("lib/omnihub/tests/framework")
local OmniHubConfig = include("lib/omnihub/config")

local eq  = OmniHubTest.assertEqual
local tru = OmniHubTest.assertTrue

-- Keys the MCM schema stores as integer percents (mirror of config.lua's PERCENT_KEYS).
local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

-- Loads the mod-root modconfig.lua and returns { [key] = default } from its first page.
local function loadSchemaDefaults(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local schema = chunk()
    local defaults = {}
    for _, page in ipairs(schema.pages) do
        for _, opt in ipairs(page.options) do
            defaults[opt.key] = opt.default
        end
    end
    return defaults
end

-- Pure suite: every modconfig.lua option default, after percent->fraction conversion, must equal
-- OmniHubConfig.defaults[key]. Runs only where the mod-root file is reachable (off-engine; the
-- harness sets OMNIHUB_MODCONFIG_PATH). In-game it self-skips, since the mod root isn't on the
-- script path.
return function(runner)
    runner:suite("modconfig")

    local path = _G.OMNIHUB_MODCONFIG_PATH
    local schemaDefaults = path and loadSchemaDefaults(path) or nil

    if not schemaDefaults then
        runner:test("schema/defaults consistency (off-engine only)", function()
            tru(true, "skipped: modconfig.lua not reachable in this environment")
        end)
        return
    end

    runner:test("every code default has a schema option", function()
        for key in pairs(OmniHubConfig.defaults) do
            tru(schemaDefaults[key] ~= nil, "schema is missing option: " .. key)
        end
    end)

    runner:test("every schema default matches the code default", function()
        for key, schemaDefault in pairs(schemaDefaults) do
            local expected = OmniHubConfig.defaults[key]
            tru(expected ~= nil, "code defaults missing key: " .. key)
            if PERCENT_KEYS[key] then
                eq(schemaDefault / 100, expected, "percent default mismatch for " .. key)
            else
                eq(schemaDefault, expected, "default mismatch for " .. key)
            end
        end
    end)
end
```

- [ ] **Step 3: Register `modconfig_spec` in the pure category**

In `data/scripts/lib/omnihub/tests/registry.lua`, change the `pure` list from:

```lua
OmniHubTestRegistry.pure = {
    "config_spec",
    "moduledefs_spec",
    "production_spec",
}
```

to:

```lua
OmniHubTestRegistry.pure = {
    "config_spec",
    "modconfig_spec",
    "moduledefs_spec",
    "production_spec",
}
```

- [ ] **Step 4: Run the suite to verify the new tests PASS**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: PASS — two new `modconfig` tests pass (proving schema defaults `100`/`50` map to `1.0`/`0.5`,
and `-1`/`90`/`10` match exactly).

- [ ] **Step 5: Commit**

```sh
git add tests/mocks/engine.lua data/scripts/lib/omnihub/tests/suites/modconfig_spec.lua data/scripts/lib/omnihub/tests/registry.lua
git commit -m "test: modconfig.lua schema/defaults consistency suite"
```

---

### Task 4: Declare MCM as an optional dependency

**Files:**
- Modify: `modinfo.lua`

- [ ] **Step 1: Add the MCM dependency**

In `modinfo.lua`, change the `dependencies` table from:

```lua
    dependencies = {
        {id = "Avorion", min = "2.0", max = "2.*"},
    },
```

to:

```lua
    dependencies = {
        {id = "Avorion", min = "2.0", max = "2.*"},
        -- Mod Configuration Menu (MCM). Optional: the mod works standalone using built-in defaults;
        -- when MCM is present, OmniHubConfig.get reads live values from it. See modconfig.lua.
        {id = "3674093144", min = "1.0.0", optional = true},
    },
```

- [ ] **Step 2: Verify modinfo.lua still loads as valid Lua**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "dofile('modinfo.lua'); assert(#meta.dependencies==2, 'two deps'); print('modinfo OK, deps='..#meta.dependencies)"
```
Expected: `modinfo OK, deps=2`

- [ ] **Step 3: Commit**

```sh
git add modinfo.lua
git commit -m "feat: declare optional MCM dependency"
```

---

### Task 5: Integration tests — live MCM round-trip + live percent keys

**Files:**
- Modify: `data/scripts/lib/omnihub/tests/suites/integration_spec.lua`

These run only in-game (dev Tests tab → Run Integration / Run All). They are written now and verified
during the in-game test pass.

- [ ] **Step 1: Append MCM integration tests to `integration_spec.lua`**

In `data/scripts/lib/omnihub/tests/suites/integration_spec.lua`, add these requires near the top
(after the existing `local OmniHubProduction = include(...)` line):

```lua
local OmniHubConfig = include("lib/omnihub/config")
```

Then, inside the returned `function(runner)`, after the existing `aggregate bridges to real recipes`
test (before the closing `end`), add:

```lua
    runner:test("config percent keys return finite fractions", function()
        local drop  = OmniHubConfig.get("dropChance")
        local price = OmniHubConfig.get("modulePriceFactor")
        tru(type(drop) == "number" and drop >= 0 and drop <= 1, "dropChance is a 0..1 fraction")
        tru(type(price) == "number" and price > 0 and price ~= math.huge, "modulePriceFactor positive finite")
    end)

    runner:test("MCM round-trip reflects in OmniHubConfig.get", function()
        local mcm = nil
        local ok, mod = pcall(include, "mcm")
        if ok then mcm = mod end
        if not mcm then
            tru(true, "skipped: MCM not installed")
            return
        end
        local cfg = mcm.bind("ktech-omnihub")
        local original = cfg.get("sellingModuleCount")
        local target = (original == 12) and 13 or 12
        cfg.set("sellingModuleCount", target)
        eq(OmniHubConfig.get("sellingModuleCount"), target, "get reflects MCM-set value")
        cfg.set("sellingModuleCount", original)  -- restore
    end)

    -- Contract guard: the vanilla shop API the supplier calls must exist (catches an Avorion rename).
    runner:test("vanilla shop API used by the supplier exists", function()
        local ShopAPI = include("shop")
        notn(ShopAPI, "shop lib loads")
        eq(type(ShopAPI.CreateNamespace), "function", "ShopAPI.CreateNamespace exists")
        local ns = ShopAPI.CreateNamespace()
        notn(ns.shop, "namespace has .shop")
        for _, m in ipairs({"add", "setSpecialOffer", "restock", "initUI", "initialize"}) do
            eq(type(ns.shop[m]), "function", "shop:" .. m .. " exists")
        end
        notn(ns.shop.itemsPerPage, "shop.itemsPerPage exists")
    end)
```

- [ ] **Step 2: Verify the file still parses off-engine (it is NOT run there, only loaded by registry in-game)**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "assert(loadfile('data/scripts/lib/omnihub/tests/suites/integration_spec.lua'), 'parses'); print('integration_spec parses OK')"
```
Expected: `integration_spec parses OK`

- [ ] **Step 3: Commit**

```sh
git add data/scripts/lib/omnihub/tests/suites/integration_spec.lua
git commit -m "test: integration coverage for live MCM round-trip and percent keys"
```

---

## PHASE 2 — Supplier subset + special offer

### Task 6: Pure supplier-stock helpers (`supplierstock.lua`)

**Files:**
- Create: `data/scripts/lib/omnihub/supplierstock.lua`
- Create: `data/scripts/lib/omnihub/tests/suites/supplier_spec.lua`
- Modify: `data/scripts/lib/omnihub/tests/registry.lua`

- [ ] **Step 1: Create `supplier_spec.lua` (the failing tests first)**

Create `data/scripts/lib/omnihub/tests/suites/supplier_spec.lua`:

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest         = include("lib/omnihub/tests/framework")
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")

local eq   = OmniHubTest.assertEqual
local tru  = OmniHubTest.assertTrue
local notn = OmniHubTest.assertNotNil

-- A deterministic rng(hi) that walks a fixed sequence (values clamped into [1, hi]).
local function seqRng(seq)
    local i = 0
    return function(hi)
        i = i + 1
        local v = seq[((i - 1) % #seq) + 1]
        if v > hi then v = ((v - 1) % hi) + 1 end
        if v < 1 then v = 1 end
        return v
    end
end

local KEYS = {"a", "b", "c", "d", "e"}

return function(runner)
    runner:suite("supplier")

    runner:test("module contract: helpers exist and are functions", function()
        eq(type(OmniHubSupplierStock.pickRandomSubset), "function", "pickRandomSubset exists")
        eq(type(OmniHubSupplierStock.pickSpecialOffer), "function", "pickSpecialOffer exists")
        eq(type(OmniHubSupplierStock.pageSlice),        "function", "pageSlice exists")
    end)

    runner:test("pickRandomSubset returns n distinct keys", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 3, seqRng({1, 1, 1}))
        eq(#sub, 3, "subset size is n")
        local seen = {}
        for _, k in ipairs(sub) do
            tru(not seen[k], "no duplicate key: " .. tostring(k))
            seen[k] = true
        end
    end)

    runner:test("pickRandomSubset clamps n to pool size", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 99, seqRng({1}))
        eq(#sub, #KEYS, "clamped to pool size")
    end)

    runner:test("pickRandomSubset handles n=0 and empty pool", function()
        eq(#OmniHubSupplierStock.pickRandomSubset(KEYS, 0, seqRng({1})), 0, "n=0 -> empty")
        eq(#OmniHubSupplierStock.pickRandomSubset({}, 3, seqRng({1})), 0, "empty pool -> empty")
    end)

    runner:test("pickRandomSubset only returns keys from the pool", function()
        local sub = OmniHubSupplierStock.pickRandomSubset(KEYS, 4, seqRng({2, 1, 3, 1}))
        local pool = {}
        for _, k in ipairs(KEYS) do pool[k] = true end
        for _, k in ipairs(sub) do tru(pool[k], "key came from pool: " .. tostring(k)) end
    end)

    runner:test("pickSpecialOffer returns a member of the subset", function()
        local sub = {"x", "y", "z"}
        local pick = OmniHubSupplierStock.pickSpecialOffer(sub, seqRng({2}))
        notn(pick, "special offer chosen")
        local inSub = false
        for _, k in ipairs(sub) do if k == pick then inSub = true end end
        tru(inSub, "special offer is in the subset")
    end)

    runner:test("pickSpecialOffer returns nil for empty subset", function()
        eq(OmniHubSupplierStock.pickSpecialOffer({}, seqRng({1})), nil, "empty -> nil")
    end)

    runner:test("pageSlice computes 1-based inclusive bounds", function()
        local s, e = OmniHubSupplierStock.pageSlice(23, 15, 0)
        eq(s, 1, "page 0 start"); eq(e, 15, "page 0 end")
        s, e = OmniHubSupplierStock.pageSlice(23, 15, 1)
        eq(s, 16, "page 1 start"); eq(e, 23, "page 1 end (clamped to total)")
    end)

    runner:test("pageSlice clamps out-of-range pages and handles empty", function()
        local s, e, page = OmniHubSupplierStock.pageSlice(23, 15, 99)
        eq(page, 1, "clamped to last page"); eq(s, 16, "last-page start"); eq(e, 23, "last-page end")
        s, e = OmniHubSupplierStock.pageSlice(0, 15, 0)
        eq(s, 0, "empty start"); eq(e, 0, "empty end")
    end)
end
```

- [ ] **Step 2: Register `supplier_spec` in the pure category**

In `data/scripts/lib/omnihub/tests/registry.lua`, update the `pure` list to:

```lua
OmniHubTestRegistry.pure = {
    "config_spec",
    "modconfig_spec",
    "moduledefs_spec",
    "production_spec",
    "supplier_spec",
}
```

- [ ] **Step 3: Run to verify the new suite FAILS (module missing)**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: FAIL — the runner errors loading `supplier_spec` because
`lib/omnihub/supplierstock` does not exist yet.

- [ ] **Step 4: Create `supplierstock.lua`**

Create `data/scripts/lib/omnihub/supplierstock.lua`:

```lua
package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubSupplierStock
-- Pure, engine-independent helpers for the OmniHub Supplier shop: choosing which modules to stock,
-- which one is the special offer, and how to slice a list into Buy-tab pages. No Entity()/random()
-- access here — randomness is injected as rng(hi) -> integer in [1, hi].
OmniHubSupplierStock = {}

-- Partial Fisher-Yates: returns up to n DISTINCT entries from `keys` (order randomized).
-- rng(hi) must return an integer in [1, hi]. n is clamped to #keys; n<=0 or empty pool -> {}.
function OmniHubSupplierStock.pickRandomSubset(keys, n, rng)
    local pool = {}
    for i = 1, #keys do pool[i] = keys[i] end

    local count = #pool
    if n > count then n = count end
    if n < 0 then n = 0 end

    local result = {}
    for i = 1, n do
        local pick = rng(count - i + 1)        -- 1 .. (count - i + 1)
        local idx  = i - 1 + pick              -- maps into the unpicked tail [i .. count]
        pool[i], pool[idx] = pool[idx], pool[i]
        result[i] = pool[i]
    end
    return result
end

-- Returns one key from `subset` (the special offer), or nil if the subset is empty.
function OmniHubSupplierStock.pickSpecialOffer(subset, rng)
    local count = #subset
    if count == 0 then return nil end
    return subset[rng(count)]
end

-- Computes the 1-based inclusive item bounds for a 0-based page over `total` items at `perPage`
-- per page. Returns itemStart, itemEnd, clampedPage. total==0 returns 0, 0, 0.
function OmniHubSupplierStock.pageSlice(total, perPage, page)
    if total <= 0 then return 0, 0, 0 end
    if page < 0 then page = 0 end
    local maxPage = math.max(0, math.ceil(total / perPage) - 1)
    if page > maxPage then page = maxPage end
    local itemStart = page * perPage + 1
    local itemEnd   = math.min(total, itemStart + perPage - 1)
    return itemStart, itemEnd, page
end

return OmniHubSupplierStock
```

- [ ] **Step 5: Run to verify the suite PASSES**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: PASS — all 8 `supplier` tests pass; `0 failed`.

- [ ] **Step 6: Commit**

```sh
git add data/scripts/lib/omnihub/supplierstock.lua data/scripts/lib/omnihub/tests/suites/supplier_spec.lua data/scripts/lib/omnihub/tests/registry.lua
git commit -m "feat: pure supplier-stock helpers (subset, special offer, page slice) + tests"
```

---

### Task 7: Rewrite supplier `addItems` to stock a subset + special offer

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubsupplier.lua`

This is engine-coupled (uses `UsableInventoryItem`, `random()`), so it is verified in-game. Keep the
pure logic delegated to `supplierstock.lua` (already tested).

- [ ] **Step 1: Add the supplierstock include**

In `data/scripts/entity/merchants/omnihubsupplier.lua`, after the line
`local OmniHubModuleDefs = include("lib/omnihub/moduledefs")`, add:

```lua
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")
```

- [ ] **Step 2: Replace `OmniHubSupplier.shop:addItems` with the subset + special-offer version**

Replace the whole `function OmniHubSupplier.shop:addItems() ... end` block with:

```lua
-- Build a Random-backed rng(hi) -> int in [1, hi]. A fresh random() each restock rotates the stock.
local function makeRng()
    local r = random()
    return function(hi)
        if hi < 1 then return 1 end
        return r:getInt(1, hi)
    end
end

function OmniHubSupplier.shop:addItems()
    local priceFactor = OmniHubConfig.get("modulePriceFactor")
    local count       = OmniHubConfig.get("sellingModuleCount")
    local catalog     = OmniHubModuleDefs.getCatalog()

    -- Catalog keys as an array, so the pure picker can sample distinct entries.
    local keys = {}
    for key in pairs(catalog) do keys[#keys + 1] = key end

    local rng     = makeRng()
    local subset  = OmniHubSupplierStock.pickRandomSubset(keys, count, rng)
    local offerKey = OmniHubSupplierStock.pickSpecialOffer(subset, rng)

    for _, key in ipairs(subset) do
        local def  = catalog[key]
        local item = UsableInventoryItem(
            "data/scripts/items/omnihubmodule.lua",
            Rarity(RarityType.Common),
            key
        )
        item.price = math.ceil(def.price * priceFactor)
        if key == offerKey then
            self:setSpecialOffer(item, 1)
        else
            self:add(item, 99)
        end
    end
end
```

- [ ] **Step 3: Make `initialize` call `shop:initialize` on both sides (so the client also requests items)**

Replace the `function OmniHubSupplier.initialize() ... end` block with:

```lua
function OmniHubSupplier.initialize()
    local entity = Entity()
    if entity.title == "" then
        entity.title = "OmniHub Supplier"%_t
    end
    OmniHubSupplier.shop:initialize("OmniHub Supplier"%_t)
end
```

(`shop:initialize` already branches on `onServer()`: server restocks; client sets the interaction
text via `Dialog` and requests items. This removes the duplicated client-only interaction-text code.)

- [ ] **Step 4: Enable the special offer in `initUI`**

In `OmniHubSupplier.initUI`, change the `initUI` config argument from
`{showSpecialOffer = false, showAmountBoxes = true}` to `{showAmountBoxes = true}`:

```lua
    OmniHubSupplier.shop:initUI(
        "Buy Modules"%_t,                    -- interaction-menu caption
        "OmniHub Supplier"%_t,               -- window caption
        "Modules"%_t,                        -- Buy tab caption
        "data/textures/icons/factory.png",   -- Buy tab icon
        {showAmountBoxes = true}             -- omit showSpecialOffer => special offer ENABLED
    )
```

(The vanilla `showSpecialOffer` flag is inverted: absent → enabled. Note: after Step 3 removed our
own `InteractionText`/`Dialog` line, the file's `local Dialog = include("dialogutility")` is no longer
referenced — `shop:initialize`'s client branch uses `shop.lua`'s own `Dialog`, not ours. Leaving the
unused local is harmless; optionally delete that line for cleanliness.)

- [ ] **Step 5: Verify the file parses off-engine**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "assert(loadfile('data/scripts/entity/merchants/omnihubsupplier.lua'), 'parses'); print('supplier parses OK')"
```
Expected: `supplier parses OK`

- [ ] **Step 6: Run the full off-engine suite (no regressions)**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: PASS — all suites green.

- [ ] **Step 7: Commit**

```sh
git add data/scripts/entity/merchants/omnihubsupplier.lua
git commit -m "feat: supplier stocks a rotating random subset with a special offer"
```

---

### Task 8: Integration test — real-catalog subset is distinct and resolvable

**Files:**
- Modify: `data/scripts/lib/omnihub/tests/suites/integration_spec.lua`

- [ ] **Step 1: Add the require for the stock helper**

In `integration_spec.lua`, after the new `local OmniHubConfig = include("lib/omnihub/config")` line
from Task 5, add:

```lua
local OmniHubSupplierStock = include("lib/omnihub/supplierstock")
```

- [ ] **Step 2: Append the subset integration test**

Inside the returned `function(runner)`, after the `MCM round-trip` test added in Task 5, add:

```lua
    runner:test("real-catalog subset is distinct and resolvable", function()
        local catalog = OmniHubModuleDefs.getCatalog()
        local keys = {}
        for k in pairs(catalog) do keys[#keys + 1] = k end
        tru(#keys >= OmniHubConfig.get("sellingModuleCount"), "catalog has at least sellingModuleCount entries")

        local i = 0
        local rng = function(hi) i = i + 1; return ((i - 1) % hi) + 1 end
        local subset = OmniHubSupplierStock.pickRandomSubset(keys, 10, rng)
        eq(#subset, 10, "subset has 10 entries")

        local seen = {}
        for _, key in ipairs(subset) do
            tru(not seen[key], "no duplicate: " .. tostring(key))
            seen[key] = true
            notn(OmniHubModuleDefs.get(key), "key resolves to a real def: " .. tostring(key))
        end
    end)
```

- [ ] **Step 3: Verify it parses**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "assert(loadfile('data/scripts/lib/omnihub/tests/suites/integration_spec.lua'), 'parses'); print('integration_spec parses OK')"
```
Expected: `integration_spec parses OK`

- [ ] **Step 4: Commit**

```sh
git add data/scripts/lib/omnihub/tests/suites/integration_spec.lua
git commit -m "test: integration check that the real-catalog subset is distinct and resolvable"
```

---

## PHASE 3 — Dev-only Refresh Stock button

### Task 9: Add a dev-mode "Refresh Stock" button to the Buy tab

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubsupplier.lua`

Engine-coupled (UI + RPC + `GameSettings().devMode`), verified in-game. Mirrors the controller's
dev-gated `runTests` pattern (`omnihubcontroller.lua:425-448`).

- [ ] **Step 1: Create the dev button at the end of `initUI`**

In `OmniHubSupplier.initUI`, after the two `deactivateTab(...)` lines, append:

```lua
    -- Dev-mode-only: a button to force a restock (re-roll subset + special offer) without waiting
    -- for the ~20-min special-offer timer. Created on the Buy tab; bound to a namespace callback.
    if GameSettings().devMode then
        local tab  = OmniHubSupplier.shop.buyTab
        local size = tab.size
        OmniHubSupplier.refreshButton = tab:createButton(
            Rect(size.x - 170, size.y - 40, size.x - 10, size.y - 12),
            "Refresh Stock"%_t, "onRefreshStockPressed")
        OmniHubSupplier.refreshButton.maxTextSize = 14
    end
```

- [ ] **Step 2: Add the client button handler and the server RPC**

In `data/scripts/entity/merchants/omnihubsupplier.lua`, immediately before the final
`return OmniHubSupplier` line, add:

```lua
-- ────────────────────────────────────────────────────────────────
-- Dev-only Refresh Stock (dev mode gated on BOTH sides)
-- ────────────────────────────────────────────────────────────────

-- Client: the Buy-tab button callback. Resolved by name on the OmniHubSupplier namespace.
function OmniHubSupplier.onRefreshStockPressed()
    if not GameSettings().devMode then return end
    invokeServerFunction("omniRefreshStock")
end

-- Server: re-roll the shop stock and broadcast it to clients.
function OmniHubSupplier.omniRefreshStock()
    if not onServer() then return end
    if not GameSettings().devMode then return end
    OmniHubSupplier.shop:restock()  -- restock() re-runs addItems + broadcasts the new items
end
callable(OmniHubSupplier, "omniRefreshStock")
```

- [ ] **Step 3: Verify the file parses off-engine**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "assert(loadfile('data/scripts/entity/merchants/omnihubsupplier.lua'), 'parses'); print('supplier parses OK')"
```
Expected: `supplier parses OK`

- [ ] **Step 4: Commit**

```sh
git add data/scripts/entity/merchants/omnihubsupplier.lua
git commit -m "feat: dev-mode Refresh Stock button to force a supplier restock"
```

---

## PHASE 4 — Buy-tab pagination

### Task 10: Paginate the Buy tab when stock exceeds the page size

**Files:**
- Modify: `data/scripts/entity/merchants/omnihubsupplier.lua`

The vanilla Buy/sold tab (`Shop:updateSellGui` over `soldItemLines`) renders up to `itemsPerPage`
(15) items with **no paging**. We override `updateSellGui` on our shop instance (the namespace
forwards `updateSellGui` to `shop:updateSellGui`, so an instance override wins) to render only the
current page, and add `<` / `>` buttons + a page label. `pageSlice` (Task 6) is already tested.

- [ ] **Step 1: Add page state init + pager controls at the end of `initUI`**

In `OmniHubSupplier.initUI`, after the dev-button block from Task 9, append:

```lua
    -- Buy-tab pagination controls. Shown only when stock exceeds one page (updated in updateSellGui).
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = 0
    local tab  = shop.buyTab
    local size = tab.size
    shop.prevPageButton = tab:createButton(Rect(10, size.y - 40, 70, size.y - 12), "<", "onPrevPagePressed")
    shop.nextPageButton = tab:createButton(Rect(80, size.y - 40, 140, size.y - 12), ">", "onNextPagePressed")
    shop.pageLabelBuy   = tab:createLabel(vec2(150, size.y - 38), "", 14)
    shop.prevPageButton:hide()
    shop.nextPageButton:hide()
```

- [ ] **Step 2: Add the pager callbacks and the paged `updateSellGui` override**

In `data/scripts/entity/merchants/omnihubsupplier.lua`, immediately before the final
`return OmniHubSupplier` line, add:

```lua
-- ────────────────────────────────────────────────────────────────
-- Buy-tab pagination (override of the vanilla single-page sold-items render)
-- ────────────────────────────────────────────────────────────────

function OmniHubSupplier.onPrevPagePressed()
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = (shop.soldItemsPage or 0) - 1
    shop:updateSellGui()
end

function OmniHubSupplier.onNextPagePressed()
    local shop = OmniHubSupplier.shop
    shop.soldItemsPage = (shop.soldItemsPage or 0) + 1
    shop:updateSellGui()
end

-- Paged replacement for Shop:updateSellGui. Renders only the current page of soldItems onto the
-- fixed soldItemLines, plus the pager controls. Mirrors the vanilla per-line population, but maps
-- the page slice onto lines 1..itemsPerPage. Special offer (specialOfferUI) is left to vanilla,
-- which our override calls through for everything except the sold-line loop.
function OmniHubSupplier.shop:updateSellGui()
    if not self.guiInitialized then return end

    for _, line in pairs(self.soldItemLines) do line:hide() end
    if self.specialOfferUI then self.specialOfferUI:toSoldOut() end

    local faction = Faction()
    local buyer   = Player()
    local craft   = buyer.craft
    if craft and craft.factionIndex == buyer.allianceIndex then buyer = buyer.alliance end

    local total = #self.soldItems
    if total == 0 then
        local topLine = self.soldItemLines[1]
        topLine.nameLabel:show()
        topLine.nameLabel.color = ColorRGB(1.0, 1.0, 1.0)
        topLine.nameLabel.bold = false
        topLine.nameLabel.caption = "We are completely sold out."%_t
    end

    local itemStart, itemEnd, page = OmniHubSupplierStock.pageSlice(total, self.itemsPerPage, self.soldItemsPage or 0)
    self.soldItemsPage = page

    local uiIndex = 1
    for index = itemStart, itemEnd do
        local item = self.soldItems[index]
        if item == nil then break end
        local line = self.soldItemLines[uiIndex]
        line:show()

        line.nameLabel.caption = item:getName()%_t
        line.nameLabel.color = item.rarity.color
        line.nameLabel.bold = false

        if item.material then
            line.materialLabel.caption = item.material.name
            line.materialLabel.color = item.material.color
        else
            line.materialLabel:hide()
        end

        if item.icon then
            line.icon.picture = item.icon
            line.icon.color = item.rarity.color
        end

        if item.displayedPrice then
            line.priceLabel.caption = item.displayedPrice
        else
            local price = self:getSellPriceAndTax(item.price, faction, buyer)
            line.priceLabel.caption = createMonetaryString(price)
        end
        line.priceReductionLabel:hide()

        line.stockLabel.caption = item.amount
        line.techLabel.caption = item.tech or ""

        local msg, args = self:canBeBought(item, craft, buyer)
        if msg then
            line.button.active = false
            line.button.tooltip = string.format(msg%_t, unpack(args or {}))
        else
            line.button.active = true
            line.button.tooltip = nil
        end

        uiIndex = uiIndex + 1
    end

    -- Pager visibility + label.
    local multiPage = total > self.itemsPerPage
    if self.prevPageButton then
        if multiPage then
            self.prevPageButton:show(); self.nextPageButton:show()
            self.prevPageButton.active = page > 0
            local maxPage = math.max(0, math.ceil(total / self.itemsPerPage) - 1)
            self.nextPageButton.active = page < maxPage
            self.pageLabelBuy.caption = string.format("%d - %d / %d", itemStart, itemEnd, total)
        else
            self.prevPageButton:hide(); self.nextPageButton:hide()
            self.pageLabelBuy.caption = ""
        end
    end

    -- Re-render the special offer exactly as vanilla does (kept identical to Shop:updateSellGui).
    local offer = self.specialOffer.item
    if offer and self.specialOfferUI then
        local specialUI = self.specialOfferUI
        specialUI:show()
        specialUI.nameLabel.caption = offer.name%_t
        specialUI.nameLabel.color = offer.rarity.color
        specialUI.nameLabel.bold = false
        if offer.material then
            specialUI.materialLabel.caption = offer.material.name
            specialUI.materialLabel.color = offer.material.color
        else
            specialUI.materialLabel:hide()
        end
        if offer.icon then
            specialUI.icon.picture = offer.icon
            specialUI.icon.color = offer.rarity.color
        end
        if offer.amount then specialUI.stockLabel.caption = offer.amount end
        specialUI.techLabel.caption = offer.tech or ""
        specialUI.timeLeftLabel.caption = "LIMITED TIME OFFER!"%_t
        specialUI.label.caption = "SPECIAL OFFER: -30% OFF"%_t
        local price = self:getSellPriceAndTax(offer.price, faction, buyer)
        specialUI.priceLabel.caption = createMonetaryString(price * 0.7)
        specialUI.priceReductionLabel.caption = "${percentage} OFF!"%_t % {percentage = "30%"}
        local msg, args = self:canBeBought(offer, craft, buyer)
        if msg then
            specialUI.button.active = false
            specialUI.button.tooltip = string.format(msg%_t, unpack(args or {}))
        else
            specialUI.button.active = true
            specialUI.button.tooltip = nil
        end
    end
end
```

- [ ] **Step 3: Verify the file parses off-engine**

Run:
```sh
"$LUA_DIR/lua54.exe" -e "assert(loadfile('data/scripts/entity/merchants/omnihubsupplier.lua'), 'parses'); print('supplier parses OK')"
```
Expected: `supplier parses OK`

- [ ] **Step 4: Run the full off-engine suite (no regressions)**

Run:
```sh
"$LUA_DIR/lua54.exe" tests/run.lua
```
Expected: PASS — all suites green (this phase adds no pure tests beyond `pageSlice`, already covered).

- [ ] **Step 5: Commit**

```sh
git add data/scripts/entity/merchants/omnihubsupplier.lua
git commit -m "feat: paginate the supplier Buy tab when stock exceeds one page"
```

---

## FINAL — Deploy and in-game verification

### Task 11: Deploy and run the in-game test + manual smoke

**Files:** none (deploy + manual)

- [ ] **Step 1: Deploy**

Run:
```sh
python build.py
```
Expected: `Verification: OK` and `modconfig.lua` listed among copied files (it must appear in dest).

- [ ] **Step 2: Confirm `modconfig.lua` deployed**

Run:
```sh
ls "$APPDATA/Avorion/mods/KTechOmniHub/modconfig.lua"
```
Expected: the path prints (file exists).

- [ ] **Step 3: In-game — run the dev Tests tab**

With dev mode on, interact with an OmniHub controller station → **Tests** tab → **Run All**.
Expected: all pure + integration suites pass (including `config`, `modconfig` self-skip note,
`supplier`, and the new integration tests). MCM round-trip passes if MCM is installed, else skips.

- [ ] **Step 4: In-game — manual smoke checklist**

- Settings → Mod Configuration Menu → OmniHub: the 5 options appear with the right defaults.
- Talk to an OmniHub Supplier → **Buy Modules**: shows ~10 modules; one is the SPECIAL OFFER row
  with -30% and a countdown.
- Click **Refresh Stock** (dev only): stock + special offer re-roll.
- In MCM set `Modules for sale` to e.g. 25 → Refresh Stock → the pager (`<` / `>`) appears and pages
  through 25 items; counts read like `1 - 15 / 25`.
- Set `Module price` to 200% → Refresh Stock → prices double vs 100%.

- [ ] **Step 5: Finalize the branch**

Use the superpowers:finishing-a-development-branch skill to decide merge/PR/cleanup.

---

## Notes for the implementer

- **Run from the repo root.** All `lua54.exe` commands assume CWD is the repo root.
- **`%_t` is the localization operator** injected by `stringutility`; off-engine it is mocked as
  identity. Keep using it on user-facing strings.
- **Do not remove the `-- namespace OmniHubSupplier` comment** — the engine parses it.
- **`callable(...)` must be at file scope**, after the function it references (as in Task 9).
- **The shop namespace forwards methods to the instance**, so overriding `OmniHubSupplier.shop.updateSellGui`
  (Task 10) is picked up because the namespace's `updateSellGui` calls `shop:updateSellGui(...)` dynamically.
- If a vanilla helper used in Task 10 (`getSellPriceAndTax`, `canBeBought`, `createMonetaryString`,
  `unpack`) is missing at runtime, check the installed Avorion `shop.lua` version — these are stable
  in 2.5.x but confirm against `$AVORION_DATA_DIR/scripts/lib/shop.lua`.
```
