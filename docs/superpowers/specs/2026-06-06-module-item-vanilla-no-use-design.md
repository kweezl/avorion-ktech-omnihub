# Module item → VanillaInventoryItem (remove the dead "Use" option)

**Date:** 2026-06-06
**Status:** Approved (Option A)

## Problem

OmniHub module items are built as `UsableInventoryItem`s backed by the script
`data/scripts/items/omnihubmodule.lua`. The engine adds a right-click **"Use"** entry to
*every* scripted usable item. Our `activate` is intentionally a no-op (install is UI-driven from
the station's Manage tab), so "Use" does nothing and is confusing. There is no property to hide
"Use" on a `UsableInventoryItem` — the only way to remove it is to stop being a usable item.

## Decision

Model the module as a `VanillaInventoryItem` (`InventoryItemType.VanillaItem`): a plain,
non-scripted inventory token. No script → no `activate` → no "Use". It carries everything the
module needs (`name`, `icon`, `price`, `rarity`, `stackable`, `tradeable`, `droppable`,
`setValue`/`getValue`, `setTooltip`). The shop lib (`shop.lua`) and the loot system both support
vanilla items (`Sector():dropVanillaItem`).

Rejected alternative (Option B): keep `UsableInventoryItem` and make `activate` install at the
nearest in-sector OmniHub. Adds unrequested behavior, keeps the restricted item-VM and its
workarounds, and contradicts the goal of removing "Use".

## Design

### New library: `data/scripts/lib/omnihub/moduleitem.lua`

Two layers so the interesting logic is testable off-engine.

- **`OmniHubModuleItem.describe(key)` — PURE.** Returns a spec table independent of engine object
  construction:
  ```lua
  {
    known  = true,                         -- false for an unknown key
    name   = def.name,                     -- "Unknown OmniHub Module" when unknown
    price  = def.price,                    -- nil when unknown
    icon   = def.icon,                     -- nil when unknown
    values = { subtype = "OmniHubModule",  -- always
               moduleKey = key,
               category  = "factory" },    -- omitted when unknown
    lines  = { {role="head", text=...}, {role="spacer"}, {role="section", text="Produces:"},
               {role="item", text="  • 2× Steel"}, ... },  -- tooltip descriptors
  }
  ```
  Depends only on `OmniHubModuleDefs.get(key)` and `%_t`. No engine objects.

  Tooltip line roles (engine layer maps role → size/color/field):
  - `head` → (25,15) `ctext`, color = `rarity.tooltipFontColor`
  - `spacer` → (14,14) empty · `gap` → (10,10) empty
  - `section` → (18,14) `ltext` ("Produces:", "Requires:")
  - `item` → (16,12) `ltext` (results, byproducts, ingredients, install hint)

  Line order mirrors today's tooltip: head, spacer, "Produces:", each result, each byproduct
  (`… (byproduct)`), gap, optional ("Requires:" + each ingredient with ` (optional)` suffix, gap),
  install-hint item.

- **`OmniHubModuleItem.build(key, rarity)` — ENGINE.** `rarity` defaults to
  `Rarity(OmniHubModuleDefs.RARITY)`. Constructs `VanillaInventoryItem()`, applies
  name/price/icon/rarity, sets `stackable/tradeable/droppable = true`, copies `spec.values` via
  `setValue`, builds a `Tooltip` from `spec.lines` (only when `known`), returns the item.
  Note: `VanillaInventoryItem` has **no** `depleteOnUse` (usable-only) — that line is dropped.

### Call-site changes (4 + delete)

| File:line | Was | Now |
|-----------|-----|-----|
| `omnihubsupplier.lua:89` | `UsableInventoryItem("…/omnihubmodule.lua", Rarity(RARITY), key)` | `OmniHubModuleItem.build(key)` (price override below stays) |
| `omnihubcontroller.lua:106` (drop) | `UsableInventoryItem(...)` + `sector:dropUsableItem(...)` | `OmniHubModuleItem.build(key)` + `sector:dropVanillaItem(pos, nil, nil, item)` |
| `omnihubcontroller.lua:370` (uninstall) | `UsableInventoryItem(...)` + `inventory:addOrDrop(item, true)` | `OmniHubModuleItem.build(key)` + `addOrDrop` |
| `omnihubcontroller.lua:401` (inventory scan) | `getItemsByType(InventoryItemType.UsableItem)` | `getItemsByType(InventoryItemType.VanillaItem)` |
| `data/scripts/items/omnihubmodule.lua` | exists | **deleted** |

Both `omnihubsupplier.lua` and `omnihubcontroller.lua` add `include("lib/omnihub/moduleitem")`.

Unchanged and verified safe: `installModule`/`uninstallModule` read `moduleKey` via `getValue`
(identical on vanilla items); `moduleDef`/`moduleDisplayName` in the supplier already avoid
`getName()` and resolve from the catalog; `secure`/`restore` store only `installed` counts, not
items.

### Bonus cleanup

Deleting the item-script VM removes its `package.path .. ";data/scripts/?.lua"` hack
(`omnihubmodule.lua:2-5`) along with the whole file. The `if not goods then include("goods")`
guard in `moduledefs.lua` is **kept** — it is still load-bearing for the off-engine test VM (the
test mock installs `goods` on that include); only its comment is corrected to drop the stale
item-script-VM reference.

## Testing

- **New pure suite** `tests/.../suites/moduleitem_spec.lua`, registered in `registry.lua`,
  exercises `OmniHubModuleItem.describe`:
  - known key → `known=true`, name/price/icon match the catalog def; `values` has
    `subtype="OmniHubModule"`, `moduleKey`, `category="factory"`; first line is `head` = def name;
    a `section` "Produces:" exists; result lines contain the good name and amount.
  - unknown key → `known=false`, name = "Unknown OmniHub Module", `values.moduleKey` = key,
    no `category`, no result lines.
  - ingredient with `optional=1` renders ` (optional)`; a `garbages` entry renders ` (byproduct)`.
- Run off-engine before deploy: `"$LUA_DIR/lua54.exe" tests/run.lua` (exit 0).
- The engine `build()` layer (vanilla item type, real Tooltip) is covered manually in-game and is a
  candidate for the integration suite, not the pure one.

## Manual verification (in-game)

1. Supplier shop lists and sells modules; tooltip renders.
2. Module in inventory: right-click shows **no "Use"** option.
3. Install from Manage tab consumes the item; uninstall returns it.
4. Destroy a station with installed modules → modules drop as wreckage loot and are lootable.
