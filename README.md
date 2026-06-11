# KTech OmniHub

A mod for Avorion that adds a single configurable production station — the **OmniHub** — which combines any number of factory production lines into one hub. Instead of founding a separate station for every step of a production chain, you found one OmniHub, buy **factory modules** from an **OmniHub Supplier** station, and install them to compose exactly the production you want. The hub produces, consumes, buys, and sells like a whole industrial district in a single entity.

## Core Features

- **One station, many factories.** Every vanilla (and modded) factory recipe is available as an installable module. Install several copies of a module to multiply its output; mix unrelated recipes freely. Intermediate goods produced by one module feed directly into others from the same cargo hold.
- **OmniHub Supplier.** A dedicated shop station that stocks a rotating selection of factory modules, including a discounted special offer. Modules are tradeable inventory items of Exotic rarity.
- **Full trading station behavior.** The hub buys ingredients from and sells products to players and NPC traders, with per-good Buy/Sell switches, adjustable price factors, and supply/demand participation.
- **NPC trade waves.** The hub actively summons mixed-cargo NPC freighters that deliver the ingredients it is short on and haul away its products.
- **Offline economy.** Hubs in unloaded sectors keep producing and trading against a simulated shadow of their state. Money settles live against the owner's account, and offline trading moves faction relations — nothing is economically inert while you are away.
- **Statistics and rates.** Lifetime profit, last-hour profit, a recent-transaction log, and live per-good throughput shown as *actual / theoretical max* units per minute.
- **Configurable.** Works standalone with built-in defaults; if the Mod Configuration Menu mod is installed, all balance knobs become live server settings.

## Founding a Hub

The OmniHub appears in the station founder under *Other Stations*. The founding cost is
configurable (default **15,000,000 credits**, `Founding cost` in the mod config). A freshly
founded hub is an empty shell: it produces nothing until modules are installed, and its cargo
hold is whatever its blocks provide — build cargo bays before installing production.
*(Migration note: hubs founded before this version relied on a forced 25,000 minimum hold that
is no longer applied; if such a hub stalls after updating, add real cargo blocks.)*

A hub can also be capped: a configurable limit on total installed module units (default: unlimited).

## Production Mechanics

### Cycle time

Each installed module type runs production cycles. The duration of one cycle is:

```
cycle time = max(15s, total output value / production capacity / level bonus)
level bonus = 1 + (average tech level of outputs) / 100
```

where *total output value* is the summed base price of everything one cycle yields (products and by-products), *production capacity* comes from the station's assembly blocks, and a good's tech level ranges 0–9. More assembly capacity makes every module on the hub cycle faster, down to the 15-second floor.

### Starting a cycle

A cycle starts only when all three gates pass:

1. **Ingredients** — every required ingredient is in stock at `amount × installed count`. Ingredients are consumed up front; products appear when the cycle completes.
2. **Reservation cap** — no output would exceed its per-good stock limit (see below).
3. **Cargo space** — the cycle's *net* cargo footprint fits. Net footprint counts outputs *minus* the space freed by consumed ingredients, so ingredient-heavy recipes still run on a nearly full hold as long as the cycle frees more space than it fills.

### Boosted cycles

If a recipe lists **optional** ingredients and they are in stock, the cycle runs **boosted at 2× speed**. The optional goods are not consumed by the gate check — having them on hand is what grants the boost.

### Multiple copies

Installing a module several times multiplies its per-cycle ingredient and output amounts by the installed count; all copies of one module type advance as one combined cycle.

## Stock Reservation Limits

Every good the hub touches gets a per-good stock limit that governs both production (a cycle won't push a product past its limit) and auto-buying (the hub won't purchase past it):

```
produced and/or consumed goods:  limit = base × cycles × max(produced per cycle, consumed per cycle)
buy/sell-marked passthrough:     limit = flat buffer
everything else:                 limit = 0
```

Defaults: base = 200, cycles = 1, flat buffer = 1000 — all adjustable per hub. The *max* (not sum) of the two roles is used because a good that is both made and used here draws from a single pile. High-volume goods therefore get proportionally larger reservations instead of the vanilla even split across trade slots.

The limit is not a hard cargo cap: manually transferring cargo into the hub bypasses it, so owners can always overstock by hand.

## Trading Mechanics

### What can be traded

The hub lists only goods that are part of some production chain — any recipe's ingredients, products, or by-products. Mining ores, rift loot, salvage scrap, and illegal goods are excluded.

### Marks and prices

Each good has explicit **Buy** and **Sell** switches; installing or removing modules never silently changes what is traded. Buy and sell price factors are adjustable within **±20 %** of base price (0.8–1.2). The chance that the next ambient trader request spawns a *seller* (bringing goods) rather than a *buyer* scales linearly with the buy price factor:

```
seller probability = 0.1 at factor 0.8  →  0.9 at factor 1.2
```

so paying over base price attracts suppliers, and underpaying attracts customers.

### Summoning traders

A **seller** is summoned for an ingredient only when stock is below the per-cycle need, the good is externally tradeable, and the delivery amount `min(limit, 500) − stock` is positive.

A **buyer** is summoned for a product when either condition holds:

```
stock + per-cycle output > 80 % of the good's limit
or  stock value > 100,000 credits  (30 % chance per check)
```

### Trade waves

NPC traders arrive in **waves** of mixed-cargo ships:

- **Wave size** = `min(configured max, free docking positions − traders already serving)`. Default max: 3 ships per wave, attempted every 90 seconds (both configurable).
- A new wave starts only when **no trader is still serving the hub**; a backstop forces a restart after several consecutive blocked windows so a stuck ship can never wedge trading forever.
- **Per-ship budget** follows the vanilla richness formula — `sector richness factor × 750,000` credits — with a 20 % chance per ship of a high-value vessel carrying **1–5×** that budget. An optional cargo-volume cap applies as well.
- **Deliveries are packed most-starved first** (lowest stock-to-need ratio), so a tight wave or budget feeds the production bottleneck rather than whichever ingredient the recipe lists first. Items that overflow one ship spill into the next; whatever exceeds the wave waits for the next one.
- Deliveries are capped by what the **owner can actually pay** — goods the owner's balance cannot cover are never requested. If a docked delivery still fails the all-or-nothing payment check, the trader retries with half of what the balance covers: `⌊⌊balance / unit cost⌋ / 2⌋`, deliberately leaving budget for the wave's other deliveries.
- Buyer pickups request `100 + random(0–1000)` units, clamped to real stock at the dock.
- Docked ships transact **deliveries first, then pickups** — selling their cargo frees hold space for what they haul away.
- Traders carry a time-to-live; a ship that overstays is forced to fly out so it cannot block future waves.

## Offline Simulation

When a hub's sector unloads, a galaxy-wide director takes over:

- The hub periodically snapshots its state while loaded; two missed snapshots mark it asleep and simulation begins from the last snapshot, so nothing is double-counted.
- Production advances with the same cycle rules as online, including boosts and multi-cycle completions across long gaps. Elapsed time is split into sub-steps of at least 30 seconds, capped at 240 steps per visit.
- Offline trade waves run every `trader request cooldown × offline delay multiplier` seconds (default multiplier 3), modelling the docking latency online traders pay. The same wave planner decides what is bought and sold.
- Money settles live against the owner faction — purchases are skipped if the owner cannot pay at that moment — and trades shift relations with the nearest faction.
- Only server uptime is credited; real-world downtime while the server is off does not produce goods.

## Module Economy

- **Module price** = vanilla factory founding cost × configurable factor (default 100 %, range 10–500 %).
- The Supplier stocks a configurable number of distinct modules at a time (default 10), each with a random stock rolled between a configurable minimum and maximum (defaults 5–20 units).
- One stocked module is the rotating **special offer** at **30 % off**.
- Uninstalling a module returns it to inventory.
- **Destruction drops:** when a hub is destroyed, each installed module unit independently rolls the configured drop chance (default 50 %) to drop as lootable cargo.

## Statistics and Throughput

- **Profit** is tracked as lifetime total and a rolling last-hour window (sell = +, buy = −), plus a log of the 10 most recent NPC transactions.
- **Per-good rates** show *actual / max* units per minute:
  - *Actual* is measured over a trailing ~60-second window, accrued smoothly across the cycle so the reading never aliases above the ceiling.
  - *Max* is the theoretical full-utilisation rate: `60 / cycle time × amount per cycle × installed count`, doubled while the module runs boosted.

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

## Configuration Defaults

| Setting | Default | Range |
|---|---|---|
| Founding cost | 15 M cr | 0–500 M cr |
| Modules for sale at the Supplier | 10 | 1–200 |
| Stock per module (min / max) | 5 / 20 | 1–9999 |
| Module price factor | 100 % | 10–500 % |
| Installed module cap per hub | unlimited | up to 999 |
| Module drop chance on destruction | 50 % | 0–100 % |
| Trader request cooldown | 90 s | 10–600 s |
| Max traders per wave | 3 | 1–6 |
| Offline wave delay multiplier | 3 | 1–10 |

All settings apply server-wide and take effect immediately when changed through the Mod Configuration Menu; without it, the defaults above are used.
