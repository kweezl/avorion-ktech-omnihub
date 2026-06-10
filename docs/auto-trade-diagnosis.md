# OmniHub ↔ NPC auto-trade: diagnosis & fix plan

**Status:** diagnosis complete, no code changed yet. Resume point for the next session.
**Goal:** make an OmniHub trade with NPC traders the way a vanilla factory does — both
(A) while the sector is **active** (player present / nearby) and (B) while the sector is
**off-grid / inactive** (unloaded, player away).

Everything below is grounded in the deployed controller
(`data/scripts/entity/merchants/omnihubcontroller.lua`) compared against vanilla
`$AVORION_DATA_DIR/scripts/entity/merchants/factory.lua` and the shared trade libraries
(`lib/tradingmanager.lua`, `lib/tradingutility.lua`, `entity/merchants/tradeship.lua`,
`sector/traders.lua`).

---

## TL;DR

There are **two independent problems**:

- **Problem A — active-sector NPC trading.** OmniHub's `requestTraders` mirrors vanilla
  line-for-line, so the *self-requested* trader path is structurally sound. But three things
  diverge from the invariants that path relies on, any of which silently kills trades:
  1. **Ambient traders can't see the hub.** `TradingUtility.getTradeableScripts()` is a
     hardcoded allow-list of vanilla scripts; `omnihubcontroller.lua` isn't in it. Every
     sector-wide / economy trader discovery (`sector/traders.lua`,
     `detectBuyableAndSellableGoods`) iterates that list, so the roaming NPC economy treats
     the OmniHub as if it trades nothing. OmniHub also never adds `sector/traders.lua`
     itself (vanilla factory does in `initialize`).
  2. **Explicit-opt-in marks break the trade helpers' assumptions.** Vanilla *always* lists
     production goods in `boughtGoods`/`soldGoods`. OmniHub lists only player-ticked goods.
     The engine trade methods assume the vanilla invariant: `getMaxGoods` returns `0`,
     `getSoldGoodByName` returns `nil`, and `increaseGoods`/`decreaseGoods` **no-op** for any
     good not in those lists. This makes `OmniHub.trySpawnSeller` compute a **negative
     amount** (and still `return true`, burning the 90 s cooldown) for an ingredient that
     isn't marked **Buy**, and makes `sellToShip` reject a result that isn't marked **Sell**.
  3. **`hasTraders()` wedge.** One orphaned `tradeship.lua` stuck in-sector (failed to dock)
     makes `TradingUtility.hasTraders(station)` return `true` forever, blocking *all* future
     self-requests.

- **Problem B — off-grid / inactive-sector trading & production. Not implemented at all.**
  OmniHub only defines `update(timeStep)`. It lacks vanilla's three off-grid mechanisms, so an
  OmniHub in an unloaded sector produces nothing, trades nothing, and never catches up.

The earlier hypothesis ("production itself is dead by default") was **wrong** — the user
confirmed production runs, ingredients are consumed, and products appear in cargo, which proves
the produced/consumed goods *are* in the trade lists (marks are set). So the factory pipeline is
healthy; the problem is specifically the NPC-trade and off-grid layers.

---

## Problem A — active-sector NPC trading

### A0. What already works
- `OmniHub.requestTraders` (controller.lua:390) is a faithful copy of `Factory.requestTraders`
  (factory.lua:1828): cooldown gate, `war_zone` check, `hasTraders` check,
  `immediate = (numPlayers == 0)`, seller-probability branch, then iterate
  `aggregatedProduction.results` → buyers, `.ingredients` → sellers, `.garbages` → buyers.
- `aggregatedProduction` has the correct shape — `ingredients/results/garbages` are arrays of
  `{name, amount[, optional]}` (`production.lua aggregate()`), so the spawn loops are valid.
- Config `traderRequestCooldown` default = 90, same as vanilla.
- The station attaches `omnihubcontroller.lua` (stationfounder.lua:9), so `getScriptPath()`
  matches what the spawned `tradeship.lua` invokes back into. Docking trades route through
  `buyFromShip`/`sellToShip` (tradingmanager.lua:922 / :1061), **not** the `buyGoods`/`sellGoods`
  that OmniHub wraps for stats. **Addressed 2026-06-10** (confirmed live: traders docked but profit
  stayed 0): the controller now records docked trades via the
  `onTradingManagerBuyFromPlayer`/`onTradingManagerSellToPlayer` entity callbacks those two
  functions fire on success (total price, disjoint from the `buyGoods`/`sellGoods` wrappers, so no
  double-count).

### A1. Ambient traders can't discover the OmniHub  *(confirmed, design-level)*
`lib/tradingutility.lua:13` hardcodes:
```
/consumer.lua /seller.lua /turretfactoryseller.lua /turretfactorysupplier.lua
/factory.lua /tradingpost.lua /planetarytradingpost.lua /casino.lua /habitat.lua /biotope.lua
```
- `sector/traders.lua` (the sector-wide ambient trader spawner) uses
  `TradingUtility.getTradeableScripts()` (traders.lua:60) to find stations that buy/sell.
  OmniHub's script isn't listed → the hub is invisible to ambient traders.
- `detectBuyableAndSellableGoods` / `getBuyableAndSellableGoods` (tradingutility.lua:95/181),
  used by other traders and tooling, also iterate that list → same blind spot.
- Vanilla factory `addScriptOnce("sector/traders.lua")` in `initialize` (factory.lua:188).
  OmniHub never does this, so unless a vanilla factory already added it to the sector, the
  ambient spawner isn't even running.

**Candidate fix:** ~~register the OmniHub script with the allow-list at load time, e.g.
`table.insert(TradingUtility.getTradeableScripts(), "/omnihubcontroller.lua")` (the list is
returned by reference; entries are `/basename.lua`)~~ — **CORRECTED 2026-06-10: the runtime insert
cannot work.** The allow-list is a *file-local* in `tradingutility.lua`, and every script
namespace runs in its own Lua VM with its own copy of each included lib — an insert from the
controller's VM is invisible to `sector/traders.lua`'s copy. The working fix (implemented) is a
**VFS lib overlay**: the mod ships `data/scripts/lib/tradingutility.lua` containing only the
insert; the engine concatenates it into the vanilla file before its trailing `return` (vanilla
file-locals in scope), so every VM that includes the lib sees the entry. Also (still correct)
`Sector():addScriptOnce("sector/traders.lua")` in the server branch of `OmniHub.initialize`.
**Must verify in-game:** that `invokeFunction(script, …)` resolves a `/basename.lua` entry to the
full deployed path (asserted by the in-game `autotrade_spec`), and that the supplier
(`omnihubsupplier.lua`, a Shop not a TradingManager) isn't accidentally matched (different
basename — it can't be).

### A2. Explicit-opt-in marks vs the engine's always-listed invariant  *(confirmed, latent bug)*
Because OmniHub's `boughtGoods`/`soldGoods` come only from ticked marks
(`OmniHubTrading.buildTradeLists`, default OFF — see `trading_spec.lua`), goods that the engine
trade path touches can be absent from the lists. The engine then silently degrades:
- `getMaxGoods(name)` → `0` when not listed (tradingmanager.lua:1409).
- `getSoldGoodByName(name)` → `nil` → `sellToShip` early-returns (tradingmanager.lua:1064).
- `increaseGoods`/`decreaseGoods` → iterate only `soldGoods`/`boughtGoods`, so unlisted goods
  are no-ops (tradingmanager.lua:1253/1292).

Concrete bug in `OmniHub.trySpawnSeller` (controller.lua:434): with an unmarked ingredient,
`maximum = getMaxGoods(name) = 0` → `amount = min(0,500) - have` → **negative**, passed to
`TradingUtility.spawnSeller`, and it still `return true`. So a partially-marked hub spawns a
degenerate/no-cargo seller *and* resets its 90 s cooldown without trading. Vanilla never hits
this because ingredients are always listed.

**Implication for the user's case:** production works ⇒ their produced/consumed goods are marked
in *some* direction. NPC auto-trade additionally needs **both** directions: ingredient marked
**Buy** (so a seller can deliver) and result marked **Sell** (so a buyer can take it). If only
one side is ticked, half the auto-trade silently dies and the negative-amount path triggers.

**Candidate fix options (decide in design step):**
- Guard the spawn helpers: bail when `getMaxGoods(name) == 0` (don't spawn for non-tradeable
  goods). Minimal, keeps explicit opt-in.
- Or seed the trade lists from production roles like vanilla (auto-list ingredients/results),
  with marks as opt-out — contradicts the chosen "keep explicit opt-in" policy, so likely not.
- Or decouple: always include production goods in the lists used by the *trade engine*, while
  the UI marks govern only what's offered to **players** in the Buy/Sell tabs. (Cleanest match
  to "explicit opt-in for the storefront, but the factory still auto-trades its recipe.")

### A3. `hasTraders()` wedge  *(possible, runtime)*
`TradingUtility.hasTraders` (tradingutility.lua:60) returns true if any `tradeship.lua` in the
sector has `trade_partner == station.index.string`. A trader that spawned but never
docked/cleaned-up blocks every future `requestTraders`. Check for orphan tradeships during
testing.

### A4. Timing reality
`getUpdateInterval` returns 1 s (players present) / 5 s (none). Cooldown is 90 s and the
seller/buyer choice is probabilistic, and buyers only spawn when stock > 80 % (or value-gated).
So even when healthy, "nothing for ~90 s" is normal — don't mistake latency for breakage.

---

## Problem B — off-grid / inactive-sector trading & production

Vanilla keeps factories "alive" while unloaded via **three** mechanisms OmniHub has **none** of:

1. **`onRestoredFromDisk(timeSinceLastSimulation)`** (factory.lua:238; registered on the
   **Sector** at factory.lua:210). On reload it does a *statistical catch-up* — no real ships:
   - simulate ingredient deliveries (AI-owned only): refill bought goods toward stock, scaled
     by `factor = clamp((tSinceSim − 10·60) / (100·60), 0, 1)`;
   - fast-forward production: `floor(tSinceSim / timeToProduce) · maxNumProductions` cycles,
     capped by available ingredients, free space, and time;
   - simulate goods sold off (AI-owned only): drain sold stock toward equilibrium by `factor`.
2. **`updateParallelSelf(timeStep)`** (factory.lua:1446): advances production during *weak
   updates* (sector in memory, no players). OmniHub puts all its logic in `update()`, which the
   engine only calls under full simulation.
3. **`updateServer` immediate trades**: `requestTraders` with `immediate=(numPlayers==0)` does
   instant `buyGoods`/`sellGoods` instead of fly-in ships — trade with no one watching. OmniHub
   *does* use this branch, so trades can fire while the sector is **loaded-but-empty**, but the
   moment it **unloads** nothing runs and there is no catch-up on return.

Note: vanilla's simulated *external* trades in `onRestoredFromDisk` run only for
`faction.isAIFaction`. A **player-owned** factory/hub only fast-forwards *production* off-grid;
it does not magically buy/sell while away. Since OmniHubs are typically player-owned, the main
missing behavior is **production catch-up**, with simulated trade being a secondary, AI-owned
concern.

### Implementation considerations specific to OmniHub
- OmniHub's production model differs from vanilla's `currentProductions` list: it tracks
  `productionProgress[key] = {progress 0..1, boosted}` and per-module `timeToProduce[key]`
  (controller.lua:53–56, `tickRecipe`). A catch-up routine must, per installed module:
  advance the in-flight cycle, then run `floor(remainingTime / ttm)` whole cycles, consuming
  ingredients and producing results/garbages via the same `increaseGoods`/`decreaseGoods`
  paths — which again require the goods to be in the trade lists (ties back to A2).
- Whatever off-grid model is chosen must respect the chosen **explicit-opt-in** trade policy.

---

## Off-grid model — options to decide next session
(User chose "decide after diagnosis".)

| Option | Production off-grid | NPC trade off-grid | Notes |
|--------|--------------------|--------------------|-------|
| **Mirror vanilla** | fast-forward on reload | statistical buy/sell toward stock equilibrium (AI-owned only) | closest to AI factories; player-owned hubs only get production catch-up |
| **Catch-up + weak updates** | reload catch-up **and** `updateParallelSelf` | same as above | smoother for sectors held in memory; more surface area |
| **Minimal / player-first** | reload catch-up only | none (external trade only when sector is live) | simplest; matches "player-owned, explicit opt-in" philosophy |

---

## Phased fix plan (proposed)

**Phase 0 — confirm with instrumentation (active sector).**
Add temporary `print`s and capture the server log:
- `requestTraders`: cooldown, `hasTraders` result, `wantSeller`, ingredient/result counts.
- `trySpawnSeller`/`trySpawnBuyer`: `name`, `have`, `getMaxGoods`, computed `amount`, whether it
  actually called `spawn*` (directly catches the A2 negative-amount bug).
- Log the return code of the `buyGoods`/`sellGoods` wrappers (immediate-trade path).
Run the test scenario below for both `immediate=false` (stay in sector) and `immediate=true`
(leave + re-enter). Revert prints after diagnosis.

**Phase 1 — Problem A fixes (pure-testable parts first).**
- A2: guard `trySpawnSeller`/`trySpawnBuyer` against `getMaxGoods==0`; add a pure unit test.
- A1: register `/omnihubcontroller.lua` with `getTradeableScripts()` and
  `addScriptOnce("sector/traders.lua")` in `initialize` (server). Verify path resolution.
- A3: confirm/clean orphan tradeships; consider a watchdog if needed.

**Phase 2 — Problem B (after model decision).**
- Implement `OmniHub.onRestoredFromDisk(timeSinceLastSimulation)` registered on the Sector in
  `initialize`, fast-forwarding each installed module's production (and, if chosen, simulated
  AI-owned trades). Optionally add `updateParallelSelf`.
- Add pure tests for the catch-up math (cycles vs time/ingredients/space) where it can be
  factored into `lib/omnihub/production.lua`.

**Verification:** run `"$LUA_DIR/lua54.exe" tests/run.lua` after each pure change; in-game via
the dev-mode OmniHub Tests window + the scenario below.

---

## In-game test scenario (dev mode on, owned sector)

1. Found/own an OmniHub; install one simple factory module (ideally a single-ingredient recipe).
2. **Goods** tab: tick **Buy** on every ingredient **and** **Sell** on every result (both
   directions — isolates A2).
3. Pre-load ingredients so production runs (already confirmed working).
4. **Active, immediate=false:** stay in the sector ≥ 2 min; watch for fly-in freighters and
   Statistics entries. Check the sector for stuck `tradeship.lua` (A3).
5. **Active, immediate=true:** leave the sector and re-enter; instant transactions should post.
6. **Off-grid (B):** fly several sectors away long enough for the sector to unload, return after
   a known interval; vanilla would show production catch-up — OmniHub currently shows none.
   Compare against a vanilla factory placed in the same/adjacent sector as a control.

---

## Open questions for next session
- Off-grid model choice (table above).
- A2 resolution: guard-the-spawners vs decouple trade-engine lists from UI marks.
- A1: does `invokeFunction` resolve the `/basename.lua` allow-list entry to the deployed mod
  path? (Needs an in-game check; affects whether ambient-trader discovery is fixable cleanly.)
- Confirm whether `OmniHub.update` runs at all while a sector is loaded-but-player-less on a
  dedicated server (governs how much the `immediate` branch covers before true unload).
