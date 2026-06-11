# Config UI "Goods" Terminology + Dev-Gated Debug Checkbox — Design

**Date:** 2026-06-11
**Status:** Approved (pending user spec review)

## Goal

Unify the Configure tab's vocabulary around **goods**. The hub trades any good in its
list — produced, consumed, or passthrough — so UI labels and tooltips must stop
splitting the world into "resources" and "products". Also fix the dev-only debug
checkbox so it can never appear while dev mode is off, and align code names with the
new vocabulary.

**Non-scope (future session):** excluding specific good categories (ores, rift goods,
etc.) from the hub's trade list.

## 1. Dev-gated debug checkbox (server-authoritative, dynamic)

Today `ui/config.lua` builds the checkbox only when the *client's*
`GameSettings().devMode` is true, evaluated once at `initUI()`. Two failure modes:
the flag reflects the client's persisted `/devmode` state (not the server's), and the
check never re-runs, so dev-state changes mid-session leave stale UI.

Fix:

- Server adds `devMode = GameSettings().devMode` to the config payload it already
  sends to the client (`omnihubcontroller.lua` `sendConfig`, ~line 1153).
- Client **always builds** the checkbox, placed at the **bottom** of the tab (below
  the stock fields, so hiding it leaves no layout gap), starting `visible = false`.
- `apply(cfg)` sets visibility from `cfg.devMode` on every config sync — server
  authoritative, re-evaluated dynamically.
- `read()` returns `debug` only while the checkbox is **visible**; otherwise `nil`
  ("keep current"), preserving the guard that a non-dev client can never clear a
  dev session (`omnihubcontroller.lua` ~line 1195).
- No server-side behavior change needed: logging is already double-gated on the
  owner toggle AND server devMode (`omnihubcontroller.lua` ~line 181).

## 2. UI label and tooltip wording

All in `data/scripts/lib/omnihub/ui/config.lua` unless noted. Every `%_t` string that
says "resources", "products", or "ingredients" in a trade-direction sense becomes
"goods".

| Current | New |
|---|---|
| Actively buy resources | Actively buy goods |
| Actively sell products | Actively sell goods |
| Buy resources at ${p}% | Buy goods at ${p}% |
| Sell products at ${p}% | Sell goods at ${p}% |
| Max Limit (units) *(section header)* | Max goods stock (units) |
| Buy goods max limit *(field)* | Max buy/sell goods stock |
| *(none)* | **Max production stock** *(new section header before "Production base")* |
| Cargo too small for all max limits — … (`ui/statistics.lua:70`) | Cargo too small for all goods stocks — … |

Resulting Configure-tab limits layout:

```
Max goods stock (units)        ← header (renamed)
  Max buy/sell goods stock     ← field (renamed)
Max production stock           ← header (new)
  Production base
  Production cycles
```

Tooltip rewrites (same mechanics, "goods" nouns):

- Actively buy: "…summons traders to deliver the goods it needs when it runs low."
- Actively sell: "…summons traders to buy its goods when stocks get full."
- Buy slider: "Price the hub pays for goods it buys. A higher price attracts more sellers."
- Sell slider: "Price the hub charges for goods it sells. A lower price attracts more buyers."
- **Max buy/sell goods stock (bug fix):** the current tooltip claims the cap applies
  only to buy-marked goods, but `maxlimit.lua` applies it to goods marked Buy **or
  Sell** that the hub neither produces nor consumes. Reword to match reality:
  "Max units stocked of each good marked Buy or Sell that the hub neither produces
  nor consumes (a passthrough trade good). 0 = don't stockpile it."
- Production base / Production cycles: "max limit" → "max stock" in the formula text.

## 3. Code renames (UI + wire keys only)

Renamed — wire keys are RPC-only (never persisted; client and server deploy together):

- Wire config keys: `limitBuy` → `tradeStock`, `limitBase` → `prodBase`,
  `limitCycles` → `prodCycles` (the latter two now match the server's own
  `hubMaxLimit` field names). Both directions: client `read()` payload and server
  `sendConfig` payload, plus the server `updateConfig` reader.
- `ui/config.lua` internals: `limitBuyBox` → `tradeStockBox`, `limitBaseBox` →
  `prodBaseBox`, `limitCyclesBox` → `prodCyclesBox`, `limitBoxes` → `stockBoxes`,
  `limitCommitted` → `stockCommitted`, `pollLimitCommit` → `pollStockCommit`,
  `setLimitBox` → `setStockBox`. Controller call sites updated.
- `integration_spec.lua` (~line 242) updated to the new wire keys.

**Deliberately NOT renamed** (compatibility):

- Persisted save keys: `data.maxLimit` with `buyLimit` / `prodBase` / `prodCycles`
  (renaming requires a save-migration shim — out of scope).
- `maxlimit.lua` `params` field names (tied to the persisted table).
- `activelyRequest` / `activelySell` — vanilla `TradingManager` trader fields.

## 4. Testing & verification

- Off-engine suite must pass: `"$LUA_DIR/lua54.exe" tests/run.lua`.
- The pure suites don't cover `ui/config.lua` (client-only), but `integration_spec`
  references the wire keys — keep it in sync.
- Deploy with `python build.py`; user verifies the Configure tab in-game: labels,
  new header, and that the debug checkbox appears only with dev mode on (and
  disappears after a config sync when dev mode goes off).

## Error handling

No new failure paths: `cfg.devMode == nil` (e.g. stale server build) keeps the
checkbox hidden — fail closed. Missing wire keys remain "keep current" via the
existing nil-safe clamps.
