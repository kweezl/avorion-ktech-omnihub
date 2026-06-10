# NPC multi-good / multi-trader exploration — feasibility & proposed design

**Date:** 2026-06-10 (v2 same day: design reviewed with owner — wave model, gating, caps, amount
rules, TDD plan, and offline coupling agreed; see "Agreed design (v2)").
**Status:** **online wave model IMPLEMENTED** (2026-06-10, `feature/omnihub-phase1-auto-trade`):
pure wave logic in `tradingdecision.lua` (`planWave`/`waveSize`/`waveGate`/`shouldFlyOut`/
`transactionList`, TDD via `wave_spec`), `lib/omnihub/traderfleet.lua` (spawn/count),
`entity/merchants/omnihubtradeship.lua` (mixed trader + TTL), controller wave `requestTraders`,
`maxTradersPerWave` config (default 3). **Offline coupling pending** (Phase 2/3 of the offline
spec). In-game confirmation of the wave pending.
**Related:** `2026-06-08-omnihub-offgrid-trading-design.md` (the offline-trading spec this must stay
consistent with — see "Balance & offline-fidelity coupling" below), `docs/auto-trade-diagnosis.md`.

## Goal

Two requested capabilities for OmniHub ↔ NPC auto-trade:

1. **Multi-good merchants** — one trader buys/sells more than one good in a single visit.
2. **Concurrent traders** — more than one trader serving the hub at once, scaled by the hub's
   dock count and capped by a global config value.

---

## Engine findings (verified against vanilla scripts, game version as of 2026-06-10)

### Multi-good selling already works in vanilla

`entity/merchants/tradeship.lua` is a 78-line shell over `ai/trade`. Its `sell()` iterates
`ship:getCargos()` and calls `station:invokeFunction(script, "buyFromShip", ship.index, good.name,
amount, true)` once **per good aboard** (tradeship.lua:24-31). A delivery trader carrying five
ingredients needs zero ship-script changes — the only limiter is the spawn path:
`TradingUtility.spawnTrader` (tradingutility.lua:217) takes a single `trade.name` and adds exactly
one cargo in its async `onGenerated` callback.

### Multi-good buying needs a custom ship script

The buy side is hardcoded to one `{name, amount}` captured at `initialize` (tradeship.lua:14-20,
33-35). But the `ai/trade` contract is tiny:

- it calls `doTransaction(ship, station, script)` once docked, after a fixed **40 s** docked wait
  (ai/trade.lua:107-116);
- it calls `onTradingFinished(ship)` to trigger fly-away (also on abort paths: docks disabled,
  population unfulfilled, tractor timeout ~2 min);
- the ship script secures/restores its own state alongside `ai/trade`'s (`secureAI`/`restoreAI`
  wrapping pattern), so traders survive sector unload/reload.

A custom `entity/merchants/omnihubtradeship.lua` (same shape as vanilla) can override
`doTransaction` to **sell all cargo AND buy a pickup list in one docking** — one freighter
delivering ingredients and hauling products away in a single visit. Each `buyFromShip`/`sellToShip`
call fires the `onTradingManagerBuyFromPlayer`/`onTradingManagerSellToPlayer` entity callbacks
individually, so the hub's statistics recording works unchanged.

### Concurrency is gated in exactly one place per consumer

`TradingUtility.hasTraders(station)` (tradingutility.lua:60) returns true if **any** entity with
script `merchants/tradeship.lua` in-sector has `trade_partner == station.index.string`. That
boolean is the only thing preventing multiple traders:

- the hub's own `requestTraders` checks it once per cooldown window;
- the ambient spawner's `Traders.isSpawnCandidate` (sector/traders.lua:36) also bails on it.

Two consequences:

- replacing the boolean with a **count** in our `requestTraders` is the entire change needed for
  concurrency on the self-request path;
- `hasTraders` filters **by script path**, so a custom OmniHub tradeship script is invisible to it.
  Vanilla/ambient traders and our custom ones must be **counted separately and summed**. Side
  effect (acceptable, arguably desirable): the ambient spawner will still send vanilla traders to
  the hub while our custom traders are en route.

### Spawning is plain Lua — fully replicable

`spawnTrader` = war/no-trade-zone guards → nearest-faction selection (eradicated-faction and
relations < −40000 guards) → **value cap** `maxValue = Balancing_GetSectorRichnessFactor(x, y, 50)
* 750000` (20% chance of 1–5× boost), `maxAmount = maxValue / good.price` → AsyncShipGenerator →
`onGenerated`: validity guard, `ship:setValue("trade_partner", station.id.string)`, `addCargo`
(sellers), `addScript("merchants/tradeship.lua", ...)`. Nothing engine-internal; we can write our
own multi-good variant without touching vanilla.

### Dock count is readable

`DockingPositions(entity).numDockingPositions` (+ `docksEnabled`) — the ambient spawner already
uses it as a spawn-candidate gate, so it is a natural concurrency ceiling.

### Bonus datum for the offline spec

The fixed 40 s docked wait + fly-in + dock queue + fly-out confirms the trader round-trip
routinely exceeds the 90 s request cooldown — supporting the revised fidelity invariant (realized
online window = `max(cooldown, round-trip)`, measured by the C1 calibration spike).

---

## Agreed design (v2 — reviewed with owner 2026-06-10)

The trading model is a **wave**: plan all eligible trades, spawn the wave's ships together, and do
not start a new wave until the previous one is gone (with a forced-restart escape hatch, below).

### Wave composition

1. **`planWave` (pure; extends `lib/omnihub/tradingdecision.lua`).** Runs every ingredient through
   `decideSeller` and every result/garbage through `decideBuyer` (the Phase-1 per-good seams reused
   unchanged — A2 gates hold by construction) and bundles the hits into ship **manifests**
   `{deliveries = {{name, amount}…}, pickups = {{name, amount}…}}`:
   - **No side priority** (owner decision, v2.1: the earlier "deliveries first" rule is removed):
     every ship is a **mixed trader** that delivers ingredients and picks up products in the same
     dock visit, so there is nothing to order between "seller ships" and "buyer ships" — the
     planner packs both sides into each manifest until the per-ship caps are hit, and whatever
     doesn't fit the wave (either side) waits for the next wave. The `pSeller` coin flip stays
     **dropped**: composition is deterministic, which keeps offline/online equivalence exact.
   - **Within a docked visit the transaction order remains deliver-then-pickup** — this is cargo
     mechanics, not priority: selling the deliveries first frees the trader's hold for the
     pickups.
   - **Per-good amounts follow vanilla exactly**: seller delivers `min(maxStock,500) − have`
     (×0.3 in immediate mode); buyer takes `100 + random(0..1000)` units, value-capped.
   - **Per-ship TOTAL value cap** (owner decision): a ship's whole manifest is capped at the
     vanilla per-ship value (`Balancing_GetSectorRichnessFactor(x,y,50) × 750000`, with vanilla's
     20% chance of a 1–5× high-value ship); overflow goods spill into the next ship of the wave.
     Keeps wealth-per-hull at vanilla levels. Manifests are also capped by the spawned freighter's
     **cargo volume** (vanilla never checks; multi-good loads must).
   - Cap inputs (value cap, volume, max ships) enter via a `caps` argument so the planner stays
     pure and off-engine testable.

2. **Wave size** = `min(OmniHubConfig.get("maxTradersPerWave"), freeDocks)`, where
   `maxTradersPerWave` is a **new global MCM config entry, default 3** (range 1–6) and
   `freeDocks = numDockingPositions − live traders currently targeting the hub` (ours + ambient),
   floored at 0. This is **logical capacity reservation** — the engine's DockAI self-assigns
   physical docks per ship (`docks:getFreeDock`, ai/dock.lua:62); there is no cross-ship
   dock-pinning API, and none is needed: never spawning more ships than docking positions gives
   the same guarantee without reimplementing the dock AI. If the planner produced more manifests
   than the wave size, the surplus waits for the next wave.

### Wave gating (the A3-aware part)

3. **Derived live count, never a stored counter.** Each request window, count live sector entities
   targeting the hub: our `merchants/omnihubtradeship.lua` ships + vanilla
   `merchants/tradeship.lua` ships, both matched by the existing `trade_partner == hub.id` entity
   value. A destroyed trader vanishes from the scan, so the gate self-heals — no counter to leak.
   Owner decision: ambient vanilla traders **both gate the wave and count against docks**
   ("Gate + docks").
4. **A new wave starts only when the count is 0** *(the requested strict gate)*, protected against
   zombie ships at two levels (owner decision, v2.1):
   - **Primary — trader TTL self-despawn (our ships).** Each `omnihubtradeship` runs its own
     watchdog: a lifetime clock accumulated in `updateServer` (secured/restored with the
     manifest). When it exceeds the TTL (e.g. 10 min — comfortably above a normal round-trip),
     the ship aborts whatever it is doing and **forces its own fly-out/despawn** via the vanilla
     `startFlyAway` path (`ai/passsector` to the sector edge, then despawn). A stuck trader
     therefore removes *itself* from the gate's live scan — the wedge cleans itself up.
   - **Backstop — forced wave restart (mainly for ambient ships we didn't spawn and can't give a
     TTL).** The existing consecutive-blocked-windows counter doubles as the escape hatch: after
     **N consecutive blocked windows (default 4 ≈ 6 min)** the wave starts anyway, sized to
     whatever docks remain free, with a `hubLog` line marking the forced start. Fully derived,
     survives reload.
5. **Cooldown semantics:** the 90 s `traderRequestCooldown` stays the request-tick cadence; a wave
   spawns all its ships in one window (they stagger naturally via spawn positions and the dock
   queue).
6. **Immediate mode** (`numPlayers == 0`, sector loaded): apply one wave's manifests instantly per
   window through the existing `buyGoods`/`sellGoods` path — no ships, so dock caps don't apply;
   the wave *period* in this regime is exactly the cooldown.

### Ship + spawn plumbing

7. **`entity/merchants/omnihubtradeship.lua` (new ship script).** Vanilla-shaped thin shell:
   include `ai/trade`, wrap `initialize` to accept the manifest, `doTransaction` iterates a
   pure-built transaction list (deliveries via `buyFromShip`, then pickups via `sellToShip` — each
   call fires the stats callbacks, so statistics work unchanged), secure/restore the manifest
   **and the TTL clock**, same `startFlyAway` ending, same `trade_partner` value. The wrapped
   `updateServer` accumulates the lifetime clock and triggers the TTL self-despawn (gating §4).
8. **`lib/omnihub/traderfleet.lua` (server-only).** `spawnWave(manifests, immediate)` modeled on
   vanilla `spawnTrader` (AsyncShipGenerator, eradicated-faction/relations guards, cargo loading
   for deliveries); `countTraders(station)` as in (3).

### Offline trading — IMPLEMENTED 2026-06-10
(`lib/omnihub/offlinesim.lua` + `galaxy/omnihubdirector.lua` + controller heartbeat/reconcile;
the wave period is `traderRequestCooldown × offlineWaveDelayMultiplier` (config, default 3) —
the multiplier models online docking latency, replacing the C1 calibration. Details in the
offgrid spec's "Implementation status".)

The offline-trading spec's Component 6 adopts the **wave as its fidelity unit** — a cleaner
mapping than per-trade windows:

- Offline applies **one full wave of eligible trades per wave-period**, with the same
  deterministic deliveries-first composition (no `pSeller`), the same per-good vanilla amounts,
  the same per-ship total value cap × wave size, and affordability checks.
- The **wave period** is the C1 calibration output: measured online wave round-trip (spawn →
  all despawned) with these features enabled; immediate-mode period = the cooldown.
- The shadow snapshot must carry the inputs the wave planner needs offline: dock count and the
  `maxTradersPerWave` value at heartbeat (decide there whether config changes during sleep apply
  on next heartbeat only — recommended — or live).
- **Sleep-with-traders-inbound edge:** the hub can unload mid-wave; frozen traders deliver again
  on wake while the offline sim also credited that period — a bounded (≤ one wave) double-credit.
  Documented accepted error; optionally the director skips its first offline window after sleep
  to compensate.

### TDD plan (tests first, red → green)

Pure (off-engine, written before implementation):
- `planWave`: mixed manifests pack both sides; per-good vanilla amounts (seller formula, buyer
  100–1100 via injected rng); per-ship total value cap splits overflow to the next ship;
  freighter-volume cap; wave-size clamp defers the surplus; A2 exclusion (`getMaxGoods == 0`
  goods never appear); empty plan when nothing eligible.
- `waveSize(configMax, dockCount, liveTraders)`: min/floor behavior, zero docks, zero config.
- Gate math (pure decision given `{count, blockedWindows, forceThreshold}` → start/wait/forced).
- TTL decision (pure: `{age, ttl} → keep flying / force fly-out`), so the watchdog threshold
  logic is testable off-engine even though the despawn itself is engine glue.
- Transaction-list builder for the ship script (deliver-then-pickup order) so
  `omnihubtradeship.lua` stays a shell with no logic of its own.

In-game (controller-VM suite, spawner-capture pattern from `autotrade_spec`):
- wave spawns the planned composition and respects `min(config, freeDocks)`;
- non-zero live count blocks the wave; forced restart fires after N blocked windows;
- a captured wave's manifests stay within the per-ship value cap.

## Risks / notes

- **hasTraders asymmetry:** vanilla consumers don't see our custom ships (script-path filter), so
  the ambient spawner keeps sending vanilla traders; per the owner decision those gate our waves
  and consume dock capacity. Our own zombies self-despawn via the TTL; a persistent *ambient*
  zombie is covered by the forced restart.
- **TTL edge:** the TTL clock only ticks while the sector is loaded (ships freeze when it
  unloads), so a trader that slept mid-flight gets its remaining TTL back on wake — fine. A ship
  so wedged that even `ai/passsector` cannot move it would survive the TTL fly-out; the forced
  wave restart still unblocks trading in that case.
- **Dock congestion:** ai/trade already aborts after a ~2 min tractor wait and flies away cleanly;
  capping wave size at free docks keeps queues sane.
- **Stats:** per-good `buyFromShip`/`sellToShip` calls mean one stats transaction per good per
  visit — consistent with current recording; no changes needed.
- **Persistence:** trader ships are entities; manifest secure/restore follows the vanilla
  tradeship pattern, so in-flight traders survive save/load. Wave state is never persisted — the
  gate is recomputed from the live scan each window.
- **Balance:** waves × multi-good manifests deliberately exceed a vanilla factory's throughput;
  the per-ship total value cap and the dock/config caps are the balance levers, and the offline
  model inherits all of them (above).
- **Compat:** other mods looking for `merchants/tradeship.lua` won't see our ships — acceptable;
  no vanilla files are modified beyond the existing allow-list overlay.
