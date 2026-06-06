# OmniHub Mod — Design Spec

**Date:** 2026-06-04  
**Status:** Approved  
**Scope:** Milestone 1 (core: hub + factory modules)

---

## Problem

Avorion production stations are **one-recipe-per-station**. To produce many goods the player
must build, fund, and manage many separate stations. This creates tedious micro-management as
an empire grows.

## Solution

The **OmniHub** is a single foundable station that starts empty. The player installs
**production-factory modules** into it — one per recipe they want to run. Installing the
*same module again stacks it*, scaling that recipe's output and ingredient consumption
linearly. Modules are tangible inventory items: bought, looted, and dropped on destruction.

---

## User-Confirmed Decisions

| Decision | Choice |
|---|---|
| Interaction UI | Single unified tabbed window (Manage · Production · [future service tabs]) |
| Service modules | Reimplemented inside OmniHub UI (M2+) |
| "Turrets" module | = Turret Factory tab (build & sell) |
| Acquiring the hub | Foundable empty station via standard transform flow |
| Vendor | Dedicated "OmniHub Supplier" NPC station |
| Selling produced goods | Auto-sell like vanilla factories (TradingManager) |
| Module cap | Unlimited by default; adjustable via mod config |

---

## Architecture

### The master controller script

One entity script — `omnihubcontroller.lua` — carries all hub logic:

- **Is a `TradingManager` namespace** (`OmniHub = TradingAPI:CreateNamespace()`) — reuses
  all of vanilla's cargo/buy/sell/trader-spawn/supply-demand machinery.
- Holds a **module registry**: `installed = { [key] = count }`.
- Runs a **custom multi-recipe production loop** over all installed factory recipes.
- Recomputes an **aggregate `bought`/`sold`** goods table on every registry change and calls
  `initializeTrading(bought, sold)` — auto-sell just works.
- Builds **one unified `TabbedWindow`** on the client, server-authoritative via RPCs.

### Module item

A module is a `UsableInventoryItem` (script: `items/omnihubmodule.lua`) with:
- `subtype = "OmniHubModule"`, `category = "factory"` (M1), `moduleKey` (stable lookup key).
- `stackable = true`, `tradeable = true`, `droppable = true`.
- `rarity = Exotic` — single source of truth `OmniHubModuleDefs.RARITY`, used by every
  construction site (loot drop, uninstall, supplier stock, item `create()` fallback). Exotic so
  drops stand out; Common modules were routinely ignored by players.
- Install/uninstall via the **Manage tab UI** (not double-click).
- Stacking = `count × recipe.amount` per cycle; production time unchanged.

### Key engine constraints

- No native station-socket system exists; station behavior comes from attached entity scripts.
- `factory.lua` is locked to one recipe; OmniHub implements a custom multi-recipe loop but
  reuses all recipe data (`productionsByGood`, `goods`, `TradingManager`).
- Module loot drops via `Sector():dropUsableItem(...)` in `onDestroyed` (50%-per-unit roll). The
  `Loot` component is the wrong tool here — it only spawns content populated *before* death, so
  usable items dropped at destruction must go through `dropUsableItem` (cf. vanilla
  `buildingknowledgeloot.lua`). The pure roll lives in `OmniHubProduction.rollDrops`.
- Founding reuses `stationfounder.lua`'s `transformToStation` + `StationFounder.stations` list.

---

## File Layout

```
modinfo.lua
data/scripts/
  lib/omnihub/
    config.lua           -- moduleCap, dropChance, modulePriceFactor + server config
    moduledefs.lua       -- factory module catalog from productionsByGood (skip mines)
    production.lua       -- multi-recipe production helpers (pure logic, debuggable)
  items/
    omnihubmodule.lua    -- UsableInventoryItem: create/activate/tooltip
  entity/merchants/
    omnihubcontroller.lua  -- MASTER: TradingManager ns + UI + registry + production loop
    omnihubsupplier.lua    -- NPC vendor: founding service + module shop (shop.lua)
  entity/
    stationfounder.lua   -- EXTEND vanilla list to add OmniHub entry
```

---

## Milestone 1 Deliverables

1. `modinfo.lua` — mod metadata
2. `lib/omnihub/config.lua` — config defaults and loader
3. `lib/omnihub/moduledefs.lua` — factory module catalog
4. `items/omnihubmodule.lua` — UsableInventoryItem definition
5. `entity/merchants/omnihubcontroller.lua` — master hub script
6. `entity/merchants/omnihubsupplier.lua` — NPC vendor + shop
7. `entity/stationfounder.lua` — vanilla extension (cache-then-wrap, appends OmniHub entry)
8. *(optional M1.5)* NPC loot-drop hook for modules

### Vanilla symbols reused (do not reimplement)

| Symbol | Source |
|---|---|
| `productionsByGood`, `getFactoryCost`, `getTranslatedFactoryName` | `lib/productions.lua` |
| `goods[name]`, `g:good()` | `lib/goods.lua` |
| `TradingAPI:CreateNamespace`, `initializeTrading`, `requestTraders` | `lib/tradingmanager.lua` |
| `increaseGoods`, `decreaseGoods`, `getMaxStock`, `TradingUtility.spawn*` | `lib/tradingmanager.lua` |
| `transformToStation`, `StationFounder.stations` | `entity/stationfounder.lua` |
| `ShopAPI.CreateNamespace`, `sellToPlayer` | `lib/shop.lua` |
| `UsableInventoryItem`, `Inventory:take/addOrDrop`, `Loot:insert` | engine |

---

## Later Milestones (separate specs)

- **M2** — Research / Refinery / Trade / Turret Factory service tabs
- **M3** — World-gen vendor spawning, NPC loot tuning, config UI, Workshop publish

---

## Verification

1. Found → OmniHub appears with empty tabbed window
2. Buy 2× Steel Factory module + 1× other from OmniHub Supplier → correct tooltips/prices
3. Install at Manage tab → registry `Steel ×2`, other `×1`; Production tab shows scaled amounts
4. Auto-sell: NPC traders appear, ingredients purchased, results sold
5. Uninstall one Steel → `Steel ×1`, item returned to inventory, production halves
6. Destroy hub (devmode) → each module unit drops ~50% of the time
7. Config changes (cap/drop/price) take effect on re-found/re-test
