# Design: MCM Config + Supplier Shop Redesign

**Date:** 2026-06-05
**Status:** Approved (design phase)
**Scope:** Two related changes — (A) move mod configuration to the Mod Configuration Menu (MCM)
framework, and (B) redesign the OmniHub Supplier shop so it presents a configurable rotating
subset of factory modules with a special offer, optional pagination, and a dev-only refresh button.

## Background / Problem

The supplier shop (`data/scripts/entity/merchants/omnihubsupplier.lua`) currently dumps the entire
113-entry module catalog (`OmniHubModuleDefs.getCatalog()`) into a vanilla `shop` "Buy" tab. That
tab is built for a handful of items: it creates exactly `itemsPerPage = 15` line widgets with **no
pagination**, and the 113-item RPC payload is large enough to truncate over the network. The visible
symptoms were a malformed pre-last row (odd font) and an empty trailing row with a stray Buy button.

Separately, configuration lives in `data/scripts/lib/omnihub/config.lua` as a `defaults` table with a
`get(key)` accessor whose own comment notes "server overrides = future feature". The user wants server
owners to configure the mod through the in-game **Mod Configuration Menu** (MCM, Workshop id
`3674093144`), like the Cosmic-Overhaul mod.

## Goals

1. Server owners configure the mod via the in-game MCM panel.
2. A configurable number of modules for sale (`sellingModuleCount`, default **10**).
3. The supplier shows a **rotating random subset** of the catalog, re-rolled on the shop's existing
   restock cadence (the special-offer period, ≈20 min).
4. Use the vanilla **special offer** feature (one module at -30% with a countdown).
5. **Pagination** on the Buy tab when the configured count exceeds the page size (15).
6. A **dev-mode-only "Refresh Stock"** button to force a restock without waiting for the timer.

## Non-Goals

- Per-faction / tech-level / region gating of stock (all 113 are eligible everywhere).
- Rewriting the controller, item, or moduledefs logic beyond what config integration requires.
- A hard MCM requirement (we integrate MCM as an *optional* dependency with built-in fallback).

---

## Part A — Configuration via MCM

### A.1 Dependency (optional + fallback)

`modinfo.lua` gains an **optional** dependency:

```lua
dependencies = {
    {id = "Avorion", min = "2.0", max = "2.*"},
    {id = "3674093144", min = "1.0.0", optional = true}, -- Mod Configuration Menu (MCM)
}
```

Rationale for *optional* over *required*:
- The mod keeps working standalone (no MCM → built-in defaults).
- `OmniHubConfig.defaults` stays as the fallback and as the oracle for the off-engine pure tests
  (which run with no MCM present).
- The four existing call sites (`OmniHubConfig.get("…")`) are unchanged.
- MCM itself pulls in the Lua JSON Library as *its* dependency; we declare only MCM.

### A.2 `modconfig.lua` (mod root, new) — MCM schema

MCM auto-discovers a `modconfig.lua` next to `modinfo.lua` at startup and reads it to build the admin
UI. It returns `{ pages = { ... } }`. **Defaults live in this schema.** All options are server-wide
(admin-only) — none use `isClient`.

Option set (one page, "OmniHub"):

| key | MCM type | default | min / max | runtime meaning |
|---|---|---|---|---|
| `moduleCap` | number | -1 | -1 / 999 | hard cap on installed module units; -1 = unlimited |
| `dropChance` | slider | 50 | 0 / 100 | % chance each installed unit drops on hub destruction |
| `modulePriceFactor` | slider | 100 | 10 / 500 | % multiplier on module shop price |
| `traderRequestCooldown` | number | 90 | 10 / 600 | seconds between trader spawn attempts |
| `sellingModuleCount` | number | 10 | 1 / 50 | how many modules the supplier stocks |

Percentage representation: `dropChance` and `modulePriceFactor` are stored by MCM as integer percents
(50, 100). `OmniHubConfig.get` divides these two keys by 100 so callers keep receiving the same
fractional values they do today (0.5, 1.0). This conversion is the single source of truth for the
"percent → fraction" mapping and is covered by tests.

### A.3 `config.lua` — MCM-aware accessor

`OmniHubConfig` keeps its `defaults` table (fallback + test oracle) and gains MCM awareness. The MCM
module is resolved and bound **once at module load** (the pattern MCM's own docs use), then
`get(key)` just delegates and applies the percent conversion:

```lua
-- pseudo-shape
-- include() THROWS on a missing module, and MCM is an OPTIONAL dependency, so guard the once-call
-- with pcall: absent MCM -> mcm nil -> config nil -> built-in defaults are used.
local ok, mcm = pcall(include, "mcm")
local config  = (ok and mcm) and mcm.bind("ktech-omnihub") or nil  -- name matches modinfo `name`

local PERCENT_KEYS = { dropChance = true, modulePriceFactor = true }

function OmniHubConfig.get(key)
    if config then
        local raw = config.get(key)       -- MCM returns the schema default when unset
        -- MCM stores these as integer percents (50, 100); convert to the fractions callers expect.
        if PERCENT_KEYS[key] and type(raw) == "number" then raw = raw / 100 end
        return raw
    end
    return OmniHubConfig.defaults[key]     -- fallback values are ALREADY fractional (0.5, 1.0)
end
```

Notes:
- Resolve+bind **once** at module scope, not per call. `config.get(key)` is still read on-demand, so
  admin changes take effect immediately (MCM's "read on-demand" rule is about not caching *values*,
  not the bound instance).
- `pcall(include, "mcm")` is required for the optional case: a bare `include("mcm")` throws "module
  not found" when MCM is absent and would break the whole mod. (The MCM "no pcall" rule applies only
  to *required* integration, where the module is guaranteed present.)
- `mcm.bind` takes the mod **`name`** from `modinfo.lua`, which is `"ktech-omnihub"`.
- `defaults` stores the *fractional* values (0.5, 1.0). The `/100` conversion applies **only** to the
  MCM-returned value (an integer percent); the fallback path must NOT divide again, or 0.5 would
  become 0.005. The consistency test (below) compares `schemaDefault/100` against `defaults`.
- Off-engine harness: `pcall` makes the fallback path work even though the mock `include` errors on
  an unmocked `"mcm"`. To exercise the *MCM-present* path (percent conversion), the harness gets a
  small `mcm` stub whose `bind().get` returns schema percents.

### A.4 `build.py`

Add `"modconfig.lua"` to `WHITELIST` so the schema deploys. The existing checksum verification then
covers it automatically.

---

## Part B — Supplier shop redesign

File: `data/scripts/entity/merchants/omnihubsupplier.lua` (+ a small pure helper in
`data/scripts/lib/omnihub/`).

### B.1 Rotating random subset

`OmniHubSupplier.shop:addItems()` runs server-side inside `Shop:restock()`. It will:

1. Read `n = OmniHubConfig.get("sellingModuleCount")` and `priceFactor = OmniHubConfig.get("modulePriceFactor")`.
2. Pick `n` distinct random keys from `OmniHubModuleDefs.getCatalog()` (clamped to catalog size).
3. For each, build the `UsableInventoryItem` and `self:add(item, 99)` at the scaled price.
4. Choose one of the added modules as the special offer (see B.2).

The selection logic is extracted as a **pure** function for testing:

```lua
-- in a pure lib (engine-independent): takes the list of keys + n + an rng(maxInclusive)->int
function pickRandomSubset(keys, n, rng) -> { selectedKeys }
```

`restock()` re-fires when `Shop:generateSeed()` changes — every `Shop.specialOfferDuration`
(≈20 min) — so the subset and special offer rotate together. Randomness is server-only; clients
receive the broadcast item list, so there is no client/server divergence.

### B.2 Special offer

- Enable it by **omitting** `showSpecialOffer` from the `initUI` config table. The vanilla flag is
  inverted (`nil` → enabled; any value → disabled), so the current `showSpecialOffer = false` is what
  turned it off.
- In `addItems`, after building the subset, call `self:setSpecialOffer(item, 1)` for one randomly
  chosen module from the subset. Vanilla renders it at -30% with the countdown timer and refreshes it
  on each restock.

### B.3 `initUI` (already added; adjusted)

```lua
function OmniHubSupplier.initUI()
    OmniHubSupplier.shop:initUI(
        "Buy Modules"%_t, "OmniHub Supplier"%_t, "Modules"%_t,
        "data/textures/icons/factory.png",
        {showAmountBoxes = true})            -- showSpecialOffer omitted => special offer ON
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.sellTab)
    OmniHubSupplier.shop.tabbedWindow:deactivateTab(OmniHubSupplier.shop.buyBackTab)
    -- dev-only Refresh Stock button added here (B.5)
end
```

### B.4 Pagination on the Buy/sold tab (final phase)

The vanilla Buy/sold tab (`updateSellGui` over `soldItemLines`) renders up to `itemsPerPage = 15`
items with **no paging**; only the player-Sell tab pages. With the default count (10) everything fits
and **no paging is exercised**. Paging is only needed when an admin sets `sellingModuleCount > 15`.

Implementation (ported from the Sell tab's pager):
- Add a `soldItemsPage` index and `<` / `>` buttons + a page label in the Buy tab, created in an
  override of `buildBuyGui` (or appended in `initUI`). Buttons are shown only when
  `#soldItems > itemsPerPage`.
- Override `OmniHubSupplier.shop.updateSellGui` with a paged version: hide all lines, compute the
  page slice `[page*itemsPerPage+1 .. min(#soldItems, …)]`, map the slice onto lines `1..15`, update
  the page label. Mirrors the existing `boughtItemsPage` math and `onLeft/onRightButtonPressed`.

This is the **last phase** so the core fix (subset + special offer + dev button) lands and is
verifiable first.

### B.5 Dev-only "Refresh Stock" button

- A button placed in the Buy tab, created only when `GameSettings().devMode` is true (mirrors the
  controller's Tests-tab gating at `omnihubcontroller.lua:427/501`).
- Click handler → `invokeServerFunction("omniRefreshStock")`.
- Server function re-checks `GameSettings().devMode`, then calls `self:restock()` (re-roll subset +
  new special offer) and re-broadcasts items. Marked `callable(...)` at file scope.

---

## Architecture / data flow

```
modconfig.lua (schema, defaults)  ──read by──>  MCM admin UI  ──writes──>  MCM store (server-synced)
                                                                                  │
config.lua  OmniHubConfig.get(key) ── include("mcm").bind("ktech-omnihub").get ──┘
        │           └─ fallback ─> OmniHubConfig.defaults  (when MCM absent)
        ▼
omnihubsupplier.lua  shop:addItems() (server, inside restock)
        ├─ sellingModuleCount ─> pickRandomSubset(catalogKeys, n, rng)
        ├─ build UsableInventoryItem per key @ modulePriceFactor
        └─ setSpecialOffer(one random subset module)
                 │ broadcastItems()
                 ▼
client  receiveSoldItems ─> updateSellGui (paged override) ─> Buy tab
client  initUI ─> [dev] Refresh Stock button ─> invokeServerFunction ─> server restock()
```

## Testing strategy

Reuse the project's existing two-layer harness (see `tests/README.md`). Suites live under
`data/scripts/lib/omnihub/tests/suites/` and are registered in `tests/.../registry.lua`. The same
suites run two ways:

- **Local / off-engine** — `lua tests/run.lua` (no game). Runs the `pure` category via the mock
  engine in `tests/mocks/engine.lua`. CI-friendly exit code.
- **In-game / dev menu** — interact with an OmniHub station → **Tests** tab → *Run Pure / Run
  Integration / Run All* (gated on `GameSettings().devMode`, dispatched by `OmniHub.runTests` on the
  controller). Engine-coupled suites can only run here.

Every new test goes into one of these layers — nothing is "manual only".

### Pure suites (run locally and in-game)

Add/extend, then register names in `OmniHubTestRegistry.pure`:

- **`supplier_spec`** (new) — covers the engine-independent shop logic extracted as pure helpers:
  - `pickRandomSubset(keys, n, rng)`: returns `min(n, #keys)` distinct keys; no repeats; deterministic
    under a seeded rng; handles `n = 0` and `n > #keys`.
  - special-offer pick: the chosen special-offer key is always a member of the selected subset.
  - pagination slice math: `pageSlice(total, itemsPerPage, page)` returns correct
    `itemStart/itemEnd`, clamps the last page, and never indexes past `itemsPerPage` lines.
- **`config_spec`** (extend existing) — with MCM mocked **absent**: `dropChance`/`modulePriceFactor`
  return fractions (0.5, 1.0) from `defaults`, integer keys pass through unchanged, `sellingModuleCount`
  default is 10. The existing default-value assertions keep passing.
- **`modconfig_spec`** (new) — load `modconfig.lua` (by explicit repo-root path, supplied by the
  runner) and assert every option's schema default, after percent→fraction conversion for
  `PERCENT_KEYS`, equals `OmniHubConfig.defaults[key]`. Guards schema/code drift.

Harness changes (`tests/mocks/engine.lua`): expose the repo-root `modconfig.lua` path (e.g. a
`_G.OMNIHUB_MODCONFIG_PATH` global) so `modconfig_spec` can `loadfile` it off-engine. No `mcm` stub
is needed: because `OmniHubConfig` binds MCM **once at module load**, the off-engine process always
takes the MCM-absent path. The percent mapping is validated by `modconfig_spec` (schema `50`/100 ==
`defaults` `0.5`), and the live MCM-present path is validated by the integration suite. `modconfig_spec`
self-skips in-game (where the mod-root file isn't on the script path) by checking the global first.
Existing 20 pure tests keep passing.

### Integration suite (in-game, dev Tests tab)

Add to `integration_spec` (or a new `supplier_integration_spec`) and register in
`OmniHubTestRegistry.integration`:

- **Real catalog vs count**: `OmniHubModuleDefs.getCatalog()` has `>= sellingModuleCount` entries, so
  the subset is meaningful; `pickRandomSubset` over the real keys yields distinct keys that all resolve
  via `OmniHubModuleDefs.get`.
- **MCM round-trip** (skips with a clear message if MCM is absent): after `config.set("sellingModuleCount", X)`
  via the bound MCM instance, `OmniHubConfig.get("sellingModuleCount")` reflects `X`; restore afterward.
- **Percent keys live**: `OmniHubConfig.get("dropChance")`/`("modulePriceFactor")` return finite
  fractions in range against the live config (MCM or fallback).

### Manual smoke (not a substitute for the above)

A short checklist for the dev session: MCM tab lists the OmniHub options; editing `sellingModuleCount`
then clicking dev **Refresh Stock** shows the new count; the special-offer row renders with discount +
timer; `sellingModuleCount > 15` shows the pager and `<`/`>` navigate pages.

## Risks & mitigations

- **MCM `name` mismatch** — `bind` must use `"ktech-omnihub"` (the `name` field), not the title or id.
  Covered by an in-game smoke check.
- **Percent representation drift** — centralizing the `/100` in `OmniHubConfig.get` and adding the
  consistency test prevents the schema and code from disagreeing.
- **RPC payload** — selling ≤ ~50 modules keeps the broadcast small, avoiding the original truncation.
- **Pager regressions** — overriding `updateSellGui` risks diverging from vanilla; keep the override
  minimal and mirror the Sell-tab math exactly.

## Implementation phases (for the plan)

Each phase adds its tests in the appropriate layer (pure suite + registry entry for off-engine/in-game,
integration suite for engine-coupled) and must keep `lua tests/run.lua` green.

1. MCM config: `modconfig.lua`, `OmniHubConfig` MCM-aware + percent handling, `modinfo` dep,
   `build.py` whitelist. Tests: extend `config_spec`, add `modconfig_spec`, add `mcm` stub +
   repo-root path to the harness; integration: MCM round-trip + live percent keys.
2. Supplier subset + special offer: `pickRandomSubset`/`pageSlice`/special-offer pure helpers;
   `addItems` rewrite; `initUI` special-offer enable. Tests: new `supplier_spec` (pure);
   integration: real-catalog vs count + distinct resolvable keys.
3. Dev-only Refresh Stock button + server `callable` (dev-mode gated, mirrors `runTests`).
4. Buy-tab pagination (override `updateSellGui` + pager controls); `pageSlice` already covered by
   `supplier_spec`.