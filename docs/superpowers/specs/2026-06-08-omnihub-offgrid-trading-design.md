# OmniHub off-grid trading & NPC auto-trade — design spec

**Date:** 2026-06-08 (revised 2026-06-10 after Phase-1 implementation review: VM-isolation
constraint added as a design principle, A1 mechanism corrected to a lib overlay, fidelity window
made a calibration output, shadow fields completed, client↔director transport leg specified,
Component-5 framing corrected).
**Status:** Phase 1 implemented and confirmed in-game (A1 overlay verified live: traders spawn).
**Phases 2+3 core implemented 2026-06-10** — see "Implementation status" below for what shipped
vs what remains deferred. Online trading now uses the WAVE model (see
`2026-06-10-npc-multi-trader-exploration.md`), and the offline model adopts the wave as its
fidelity unit.

## Implementation status (2026-06-10)

**Shipped** (on `feature/omnihub-phase1-auto-trade`):

- `lib/omnihub/offlinesim.lua` — the PURE coupled simulator (sub-stepped production via the shared
  `canStartCycle`, offline trade waves via the shared `planWave`; money through injected
  `env.tryPay/receive` callbacks so affordability stays truthful; covered by `offlinesim_spec`,
  11 off-engine tests incl. sub-step invariance and the boost/caps/flags gates).
- `galaxy/omnihubdirector.lua` — the director: heartbeat-driven registry, uptime clock
  (secure/restore), sleep detection (`lastSeen` timeout, offline credit starts at the snapshot's
  moment so live progress is re-simulated, never double-counted), per-hub simulation settling
  owner money live + `changeRelations` with the nearest faction (S4), `heartbeat`/`wake`/`remove`
  surface over synchronous `Galaxy():invokeFunction` (transport spike C3 resolved: the cheap path
  exists per the stubs; in-game confirmation pending).
- Controller glue: compact shadow snapshot (installed/ttm/progress/inventory/tradeCaps/stockCaps/
  freeSpace/factors/flags/cfg) published every 30 s + immediately on the first update tick after
  load (closes the registration gap); wake reconcile writes shadow inventory into real cargo as
  absolute amounts (money NOT re-applied — the loudest invariant); `onDestroyed` → `remove`.
- **Fidelity resolution (replaces the C1 calibration spike):** offline wave period =
  `traderRequestCooldown × offlineWaveDelayMultiplier` (new global config, default 3, range 1–10)
  — the multiplier models the docking latency online waves pay. Offline waves use ship-regime
  amounts (full deliveries; pickups clamped to stock at apply time, like `sellToShip` at dock).
  Spike 5 resolved as freeze-at-factors: offline prices = base × buy/sell factor snapshot (no
  regional term — documented residual gap).

**Deferred** (not yet implemented): `scheduler.lua` load-degradation (the director visits every
asleep hub on a flat 30 s cadence — fine for tens of hubs, revisit before stress scale), the
benchmark harness + save-serialization measurement (S5), the director dev UI /
`/omnihubdirector` + `allHubsDebug` override (Component 8; `setDebug`/`getStats` exist on the
director as the seam), and the risk-targeted in-game tests (S2/M3/M1/C3) — currently covered by
the pure suite + manual verification.
**Related:** `docs/auto-trade-diagnosis.md` (root-cause analysis of both problems).

## Goal

Make an OmniHub trade with NPC traders as well as a vanilla factory does, in **both** regimes:

- **Active sector** (sector loaded): real NPC traders are requested, arrive, and trade. (Fixes
  "Problem A" from the diagnosis.)
- **Off-grid / inactive sector** (sector unloaded): production **and** trading keep accruing
  continuously — without keeping the sector loaded — so owners profit from offline hubs the way
  players currently abuse "keep sector online 24/7" mods to achieve. (Implements "Problem B".)

**Fidelity invariant (the balance guardrail):** offline simulation must approximate what the
hub would have earned *if it were online*. The online ceiling is **at most one eligible trade per
window**, gated by the seller/buyer split and the `stock>80%` / `have<needed` conditions — but the
*realized* window length differs by regime. With players present, `hasTraders` blocks the next
request until the spawned tradeship has flown in, docked, traded, and **left the sector**, so the
realized rate is one trade per `max(cooldown, trader round-trip)` — and the round-trip plausibly
exceeds the 90 s cooldown *routinely*, not as a rare tail. With the sector loaded but empty
(`immediate = numPlayers==0`), trades are instant at exactly one per 90 s cooldown, but seller
delivery amounts are scaled **×0.3**. The offline model therefore makes **one trade decision per
window, honoring the same gates and prices**, where the **window length and per-window amounts are
calibration outputs of the C1 spike** (measure the realized online inter-trade interval and traded
amounts per regime; set offline to the *more conservative* of the two regimes). Offline cannot
exceed online because both the window and the amounts are anchored to measured online behavior —
not because of an assumed 90 s window with a tail cap.

## Design principles

1. **No logic duplication — shared logic lives in `lib/omnihub/`.** The production and
   trade *decisions* are pure functions called by both the online and offline executors.
2. **Performance first.** Event-driven handoff (no polling), bounded sub-stepped catch-up (no
   unbounded per-tick loops), chunked scheduling with load-based degradation, compact shadow state,
   lazy UI reads. Every choice is validated by an in-game benchmark.
3. **Single authority at all times.** A hub's storage is owned by exactly one of {live entity,
   director shadow} — never both. Reconciled once on each transition.
4. **Cheap validity guards.** A hub may be destroyed; guard entity dereferences at every
   engine-touching boundary (heartbeat, wake/reconcile) and drop dead entries.
5. **Per-namespace VM isolation (engine constraint, added 2026-06-10).** Every script namespace
   runs in its own Lua VM; included libs are per-VM copies, and runtime mutations never cross VMs.
   Anything that must be visible engine-wide ships as a **VFS overlay** at the vanilla path (the
   engine concatenates same-path files into one chunk, injected before the trailing `return`, with
   the vanilla file-locals in scope). Anything that must touch another script's live state goes
   through `invokeFunction` (server-side, synchronous, returns plain tables — never functions).
   This constrains A1 (discovery), the in-game test harness (suites must execute in the
   controller's VM), and the hub↔director transport.

---

## Architecture overview: one decision core, two executors

```
                 ┌─────────────────────────────┐
                 │  lib/omnihub/  (pure core)   │
                 │  • production catch-up math  │
                 │  • trade decision (seller/   │
                 │    buyer, good, amount, price)│
                 │  • scheduler math            │
                 └───────────▲────────▲─────────┘
                             │        │  (same pure decisions)
        ONLINE executor      │        │      OFFLINE executor
  entity/merchants/          │        │   galaxy/omnihubdirector.lua
  omnihubcontroller.lua      │        │   (galaxy script)
  • requestTraders → decision│        │ • decision → apply to SHADOW
  • decision → spawn REAL    │        │   inventory + pay owner
    NPC ship (TradingUtility)│        │ • no ships
```

The **same decision core** drives both paths — the *per-trade decision* (which good, how much, at
what price) is identical. Matching online *throughput* is a separate concern handled by the
per-window model + bounded sub-stepping (Component 6), not by the shared decision alone. The
core is unit-testable off-engine.

---

## Component 1 — Shared decision core (`lib/omnihub/`)

New/extended pure modules (engine-independent; covered by off-engine `pure` suites):

- **`production.lua` (extend):** `step(state, dt, ttm, caps) → {cyclesRun, ingredientsConsumed,
  resultsProduced, garbagesProduced, newProgress}` — advances production over one sub-step `dt`.
  Production *in isolation* is closed-form and step-size invariant; but it is **coupled** to trade
  (a buyer appears when stock crosses 80%, stock then falls, production resumes…), so the offline
  simulator drives this with **bounded fixed sub-steps** (Component 3/6), not one lump over the
  whole elapsed. Mirrors vanilla `factory.onRestoredFromDisk` math on OmniHub's per-module
  `{progress, boosted}` model.
- **`tradingdecision.lua` (Phase 1: shipped as per-good seams).** The spawn/trade decision inlined
  in the controller's `trySpawnSeller`/`trySpawnBuyer`, extracted to pure functions. Phase 1
  shipped `decideSeller(good, query, immediate)` / `decideBuyer(good, query, rng)` — the per-good
  decisions, which is where the **Problem-A2 negative-amount bug is fixed**: return `nil` (don't
  trade) when `getMaxGoods(good) == 0` / the good isn't externally tradeable, instead of computing
  a negative amount. The **window-level** decision (`pSeller` roll, the
  results → ingredients → garbages iteration order, the war-zone gate) still lives only in the
  controller's `requestTraders`; **Phase 3 must lift it into a `decideTrade(agg, query, rng, cfg)`
  entry point** so the director consumes the same loop — otherwise the "nothing written twice"
  principle breaks exactly where it matters.
- **`scheduler.lua` (new):** pure scheduler math — given `{count, targetRefreshSec, tickRate,
  maxPerTick, loadSignal}` return `{kPerTick, effectiveRefreshSec}` and next-due ordering helpers.
  No engine calls; fully unit-tested.

The controller and the director both `include()` these. **Nothing about trade/production decisions
is written twice.**

---

## Component 2 — Online executor: Problem-A fixes (`omnihubcontroller.lua`)

Independent of the director; ships first.

- **A1 — discovery (corrected 2026-06-10: lib overlay, not runtime insert).** The allow-list in
  `lib/tradingutility.lua` is a **file-local**, and per design principle 5 a runtime
  `table.insert(TradingUtility.getTradeableScripts(), ...)` from the controller's VM patches only
  *that VM's copy* — `sector/traders.lua` (and every other consumer) includes its own copy and
  never sees it. The fix is a **VFS overlay**: ship `data/scripts/lib/tradingutility.lua`
  containing only `table.insert(TradingUtility.getTradeableScripts(), "/omnihubcontroller.lua")`;
  the engine merges the fragment into the vanilla file before its trailing `return` (file-locals in
  scope), so **every** VM that includes the lib sees the entry. Also
  `Sector():addScriptOnce("sector/traders.lua")` in server `initialize` (the spawner may not be
  running otherwise). *Spike (now test-backed):* the in-game autotrade suite asserts
  `Entity():invokeFunction("/omnihubcontroller.lua", "getSellsToOthers")` resolves (code 0) on the
  live station; the supplier (a Shop, different basename) is never matched by the entry.
- **A2 — spawn correctness.** `requestTraders` calls `OmniHubTradingDecision.decideTrade(...)`;
  never spawn for a good with `getMaxGoods == 0`. (Bug fix + the shared seam.)
- **A3 — `hasTraders` wedge (UNCONFIRMED — investigate, don't pre-build).** *Hypothesis:* an
  orphaned `tradeship.lua` partner could make `hasTraders` return true forever and block requests.
  Note the wedge is worse than first diagnosed: `Traders.isSpawnCandidate` *also* bails on
  `hasTraders`, so one orphan blocks self-requests **and** ambient spawns. *Instrumentation
  (shipped in Phase 1):* `requestTraders` counts consecutive `hasTraders`-blocked windows behind
  the debug gate — a count that climbs without resetting is the wedge. Only add a
  watchdog/cleanup once observed.

---

## Component 3 — The director (`galaxy/omnihubdirector.lua`)

A **galaxy script** (host model confirmed against vanilla `galaxy/server.lua`): ticks via
`update(timeStep)` server-side galaxy-wide regardless of sector load; persists via `secure`/
`restore`; attached once via `Galaxy():addScriptOnce("data/scripts/galaxy/omnihubdirector.lua")`
from a hub's server `initialize`.

**Registry (heartbeat-driven).** No explicit register step: a hub's first **heartbeat** creates
its registry entry. Entry = `{id, sectorX, sectorY, owner, shadow, lastSeen, lastSim, awake}`.
Removed on `onDestroyed` notification, or by a validity guard when found dead. To close the
new-hub gap, a hub **pings immediately in server `initialize`** (not only on the ~30 s timer) —
otherwise a hub founded and abandoned within the first interval would never register and would
earn nothing offline.

**Heartbeat = publish (one mechanism, two jobs).** While a hub is awake, it pings the director
every ~30 s (NOT per tick) with its compact shadow. This keeps the director's storage current (for
UI + handoff) and refreshes `lastSeen`. *Spike:* heartbeat transport — `Galaxy():invokeFunction`
vs a namespaced shared store; pick the one that exists and is cheap.

**Sleep detection (no unload callback exists).** A registered hub whose `lastSeen` exceeds
`heartbeatInterval + margin` is treated as asleep and simulated; the ~30 s detection gap is covered
exactly because catch-up is fed `elapsed = now − lastSim`. Explicit **wake** (on load) is an
immediate ping that sets `awake = true` and excludes the hub from sim; explicit sleep needs no
signal — the heartbeat simply stops.

**Scheduler.** Next-due ordering (NOT a raw index cursor, which breaks on a mutating set). Process
`kPerTick` asleep hubs per tick to hit `targetRefreshSec` (e.g. 30 s); under load, **degrade the
visit cadence** (how often a hub is processed). This changes only **latency**, not outcomes,
because each visit replays the hub's elapsed time as a fixed number of **internal sub-steps**
(below) — so a hub visited every 30 s vs every 100 s simulates the same trajectory, just later.
`kPerTick` and `effectiveRefreshSec` come from the pure `scheduler.lua`.

**Per-hub coupled step (one director, no locks).** Single-threaded server context ⇒ nothing to lock
against. For each due hub, sequentially: validity guard → compute `elapsed = now − lastSim` →
**iterate fixed sub-steps of `dt`** (a fixed offline cadence, e.g. matching online's trade window,
capped to a max count for very long sleeps), and within each sub-step run the **coupled** order
**buy-in → produce → sell-out** (simulated ingredient deliveries, then `production.step(dt)`, then
simulated sales) so trade thresholds see the evolving stock — then settle owner credits, **update
the shadow storage** (so UI reflects actual cargo), and stamp `lastSim`. Production and trade stay
separate *pure functions* for testing, composed inside the sub-step loop. **No second director, no
per-good locks.** The sub-step count is bounded (long sleeps coarsen `dt`, accepting a documented,
measured error rather than unbounded work).

---

## Component 4 — Shadow state model

Compact, per offline hub (persisted with the director, not the sector):

- recipe set (installed module keys → counts) — lets the director resolve recipes locally;
- per-module production progress `{progress, boosted}`;
- **per-module `timeToProduce` snapshot** (online value derived from `Plan():getStats().productionCapacity`,
  which is unavailable offline — so it MUST be captured at heartbeat, not recomputed);
- inventory `{good → amount}`;
- **cargo capacity snapshot** (`maxCargoSpace`) — offline production must stall when cargo is full
  and the on-load write-back clamp needs the same number; unavailable offline, so captured at
  heartbeat like `timeToProduce`;
- trade config snapshot (sell/buy marks, price factors, **and the max-limit config**
  `hubMaxLimit` = buyLimit/prodBase/prodCycles — these feed the `getMaxGoods`/stock caps that the
  `stock>80%` and `min(maxStock,500)` gates read). **No** inter-station transfer data — that
  feature is removed (see "Removed scope");
- owner faction index;
- **last-known sector flags** (war_zone / no_trade_zone / in-rift) — Case D reads them;
- last-known regional market snapshot per traded good (see Component 6);
- `lastSim` timestamp.

**Publish vs persist (terminology, corrected).** The heartbeat publishes a **full compact snapshot**
(small: counts + a per-good amount map), not a delta — the director needs no prior baseline and the
snapshot is the authoritative seed if the hub sleeps right after. "Compact" means *narrow rows*
(amounts, not full good objects), **not** delta encoding. At rest, the director's persisted registry
is necessarily a **full mirror** of all offline hubs; bounding its cost (see Performance / save
serialization) is a real constraint, not solved by "deltas."

---

## Component 5 — Handoff & reconciliation (the riskiest path)

- **While asleep:** director shadow is the *sole* source of truth.
- **⚠ Loudest invariant — no double-count (reframed 2026-06-10).** OmniHub is **not** built on
  `factory.lua`: `onRestoredFromDisk` fires only for scripts that *register* it, and today OmniHub
  registers nothing — there is **no vanilla catch-up to "suppress"; the time-based fallback is new
  Phase-2 code**. The load handler's rule: **if a director shadow exists, apply the shadow and
  nothing else** (that offline period is already credited in the shadow); only when no shadow
  exists (first load after building, or director disabled) run the new vanilla-style
  `timeSinceLastSimulation` catch-up math. Getting this wrong double-credits every offline period.
- **On load (`onRestoredFromDisk`, registered by OmniHub in Phase 2):** apply
  the director's offline result: the hub fires an immediate wake ping, pulls its shadow, and writes
  the director-updated inventory into real cargo via `entity:addCargo` directly (bypassing the
  `increaseGoods` no-op trap from A2), clamped to capacity. After this, **cargo already reflects all
  offline activity and the hub simply runs in normal online mode** (`update()` resumes production +
  trade) — no special online-side catch-up. **Money is NOT reconciled here**: owner credits were
  settled *live during* offline sim, so re-applying would double-pay. Director sets `awake = true`
  and stops simulating the hub.
- **Validity guard:** before write-back and before any sim touch, check the entity/sector is valid;
  if the hub is gone, drop the registry entry and skip.
- **Anti-double-sim + intra-tick ordering:** authority is keyed on `awake`. Within a director tick,
  **process incoming wake pings before the sim loop**, so a hub that just woke is excluded from
  this tick's simulation — a hub is never advanced by both `update()` and the director in the same
  window.

---

## Component 6 — Offline trade fidelity (per-window model)

### How online actually paces trades (the model offline must match)

`requestTraders` runs on the **`traderRequestCooldown` (90 s)** timer; each time the timer reaches
zero it resets to 90 s and, if `not hasTraders`, spawns **at most one** trader. The trader flies in,
docks, trades, and leaves; while it exists `hasTraders` is true, so no new request spawns until it's
gone. Therefore the long-run online rate is **one eligible trade per
`max(cooldown, trader round-trip)`**, gated by: the **seller/buyer split** (`pSeller` from
`buyPriceFactor`), the **buyer gate** (`stock > 80%` of max, or value-gated), and the **seller
gate** (`have < needed`). The round-trip (spawn ~1500 m out → fly in → dock → trade → leave the
sector) plausibly exceeds the cooldown **routinely** when players are present — treat the realized
window length as an **empirical quantity the C1 calibration spike measures**, not as 90 s with a
rare-tail correction.

**Cases the offline model reproduces:**

- **A — sell-side (products accumulating).** Per window, if `buyer` is chosen and `stock>80%`, one
  buyer drains a batch. Offline: one decision per window, same gate → same drain rate.
- **B — buy-side (ingredient-starved).** Per window, if `seller` is chosen and `have<needed`, one
  seller delivers `min(maxStock,500) − have`. Offline: identical.
- **C — latency-bound (NOT assumed rare).** When round-trip > cooldown, online runs at
  ~1/round-trip. The offline **window length is set from the measured online inter-trade interval**
  (C1 spike) rather than fixed at the cooldown, so this case is handled by construction instead of
  by a tail cap on a too-fast base rate.
- **D — suppressed.** War zone / no-trade zone / relations < threshold → online rate is 0; offline
  honors the **last-known sector flags** from the heartbeat snapshot (Component 4 carries them).
- **E — loaded-but-empty (immediate mode).** Online already does instant per-cooldown trades with no
  ship (`immediate = numPlayers==0`) — but note its **seller amounts are scaled ×0.3**. The offline
  model must pick one amount semantics and state it; defaulting to the immediate-mode shape
  (instant, ×0.3 deliveries) is the conservative choice since it's also the closest vanilla
  analogue for an unwatched sector. Final amounts come from the C1 calibration.

### Implementation (inside the per-hub sub-step loop, Component 3)

The director advances a per-hub **trade-window timer** alongside production sub-steps. Each time the
window elapses it runs **one** `tradingdecision.decideTrade` against the **current sub-step stock**
(so the `stock>80%` / `have<needed` gates see evolving state — why the loop is sub-stepped, not
lumped), then applies the result:

- **Prices** = `base × factors × regionalMarket`, using the **last-known regional snapshot** captured
  at heartbeat. *Open question:* last-known vs freeze-at-base.
- **Affordability.** Ingredient purchases debit the owner faction subject to a `canPay` check
  (mirrors online); if unaffordable the buy is skipped and production naturally stalls — exactly as
  online when `buyGoods` fails.

### Economic impact (S4 — offline trades DO affect the economy)

Offline trade is **not** economically inert. To match online impact it uses a **counterparty
faction** — the nearest faction to the hub's sector (`Galaxy():getNearestFaction(coords)`, same source
online uses) — and:

- **moves money** both directions through that faction and the owner faction (real wealth transfer,
  not money conjured from nowhere);
- **applies relation changes** (`changeRelations`) on each simulated trade, so offline trading builds
  standing the way online does.
- **Regional supply/demand contribution** (production consumes/produces, shifting prices) is the one
  piece that needs the sector economy, which is unloaded. *Spike:* whether the director can feed the
  economy system for an unloaded sector, or whether this contribution is applied lazily when the
  sector next loads. If neither is cheap, this single aspect is the documented residual gap — money
  and relations impact are still modeled.

---

## Component 7 — Offline storage visibility (UI)

Alliance/map station list shows real offline cargo by reading the director shadow **lazily on
demand**, never pushed. Keeps the cost zero when no one is looking. **Transport note (principle
5):** a client cannot RPC into a galaxy script; the read goes client → the requesting script's own
server half (`invokeServerFunction`) → `Galaxy():invokeFunction(director, ...)` → result back via
`invokeClientFunction`. The galaxy script is never a client RPC target.

---

## Component 8 — Director debug gate & dev UI

The per-hub debug gate (hub config "debugLogging") only covers a hub's own logs. The director runs
in its own galaxy-script context, so it needs an **independent debug gate**:

- **Director debug gate.** A director-level `debugEnabled` flag (persisted in the director's
  `secure`/`restore` state), used to gate `OmniHubLog.debug` calls inside the director. The shared
  `lib/omnihub/log.lua` is gate-agnostic: each context passes its own enable check (hub passes its
  effective flag; director passes `debugEnabled`). So there are **independent gates over one
  logger**, no duplication.

- **All-hubs debug override (director → hubs).** The director also holds an `allHubsDebug`
  directive (`nil` = no override / `true` = force on / `false` = force off), persisted with the
  director. A hub's **effective** debug gate = `allHubsDebug` when set, else its own config
  "debugLogging". **Delivery depends on the transport spike (C3) and must not assume a synchronous
  heartbeat reply.** Network RPCs (`invokeServerFunction`/`invokeClientFunction`) are fire-and-forget
  with no return value, so a heartbeat cannot *return* the directive over them. Two viable paths,
  chosen by the spike: (a) if a **synchronous server-side** hub↔director channel exists
  (`Galaxy():invokeFunction` returning a value), the heartbeat can be request/response; (b)
  otherwise the directive is delivered by a **separate director→hub push** — the director iterates
  its awake set and calls each loaded hub via `Sector(x,y):getEntity(id):invokeFunction(...)` (server
  side, sector loaded since the hub is awake). Either way it is eventually-consistent within ~one
  heartbeat; offline hubs need nothing. Toggle is server-authoritative and dev-mode-gated.

- **Director dev UI (dev-mode only, chat-command activated).** A `/`-command (e.g.
  `/omnihubdirector`), gated on `GameSettings().devMode` like the existing OmniHub Tests window,
  opens a small client window that displays:
  - **registered hubs** (total in the registry),
  - **online / offline split** (awake vs asleep counts),
  - a **director debug checkbox** that toggles the director `debugEnabled` flag,
  - an **all-hubs debug checkbox** that sets the `allHubsDebug` override (on/off), pushed to hubs.
  Optionally surfaces the live production counters (hubs simulated, trades simulated, credits paid,
  director time/tick) for at-a-glance observability.

  *Mechanism (corrected 2026-06-10 — the client leg needs an intermediary):* galaxy scripts are
  server-side, and a chat-command script also runs server-side — neither can build client UI or be
  a client RPC target. The command (`data/scripts/commands/omnihubdirector.lua`) therefore attaches
  a dev-gated **player script** (`player:addScriptOnce("player/omnihubdirectorui.lua")`): its
  client half owns the window; its server half bridges to the director via
  `Galaxy():invokeFunction(...)` (the stubs confirm `Galaxy():addScriptOnce` / `invokeFunction` /
  `registerCallback` exist). Toggles remain **server-authoritative and dev-mode-gated** (rejected
  server-side if not dev mode).

---

## Removed scope (S1) — inter-station direct transfers

The hub's **inter-station direct-transfer feature is removed entirely**, not deferred. Online it
works (`updateTransfers` moves goods between a hub and chosen partner stations), but offline it is a
**cross-authority move (shadow ↔ live entity)** that breaks the single-authority rule and is not
worth the complexity. Rather than carry a feature that silently dies offline, we cut it so behavior
is consistent in both regimes.

**Existing code to remove (part of Phase 1 cleanup):** the controller's `updateTransfers`,
`chosenDelivered`/`chosenDelivering`/`candidate*`/`*Errors` state and `resolveChosen`, the
`secure`/`restore` of `chosenDelivered/Delivering`, `OmniHubTransfers` (`lib/omnihub/transfers.lua`),
`OmniHubTransfers.collectPartners`, and the partner-combo selection in the Config tab
(`sendHubConfig`/`applyHubConfig` partner fields + `ui/config` partner widgets). The shadow model
carries **no** transfer data.

---

## Performance model

| Concern | Mitigation |
|---|---|
| Discovery of sleep/wake | event wake + `lastSeen` timeout; **no sector-state polling** |
| Publish | heartbeat **is** the publish (one mechanism), ~30 s, only for *awake* hubs (scales with loaded sectors — can be many on a busy MP server; each carries a compact full snapshot, so keep rows narrow) |
| Catch-up | bounded fixed sub-steps per visit; long sleeps coarsen `dt` (documented error), never unbounded work |
| Scheduling | `kPerTick`, next-due order, **degrade visit cadence (latency), not the sub-step trajectory** |
| Save serialization | director `secure()` mirrors the whole registry every autosave → **must be benchmarked** for save-stall at ≥1000 hubs; bound row width, consider cap/shard if needed |
| UI | lazy on-demand read |
| Locks/duplication | **one director, coupled step, no locks**; shared pure core |
| Common case | a player owns *tens* of hubs → director is near-free; the 1000–10000 figures are stress ceilings, not the expected load |

---

## Testing & observability (layered off one core)

1. **Guarded debug logging.** New gate-agnostic `lib/omnihub/log.lua` → `OmniHubLog.debug(...)`,
   driven by **independent gates** (Component 8): per-hub effective flag (`allHubsDebug` override
   when set, else `OmniHubConfig` "debugLogging") and director (`debugEnabled`, toggled from the
   director dev UI). Replaces all temporary `print`s.
2. **Pure off-engine tests** (`tests/run.lua`): `tradingdecision` (incl. the no-negative-amount
   regression), `production.step` (cycles vs time/ingredients/space; sub-step composition),
   `scheduler` (kPerTick, degradation, next-due ordering).
3. **In-game integration tests** (dev-mode OmniHub Tests window) — **hosted in the controller's
   VM** (principle 5): the OmniHubTests window script (own namespace = own VM) has no `_G.OmniHub`
   and a different copy of every lib, so it only *renders*; `runTests` delegates via
   `Entity():invokeFunction(controller, "runDevTests", category)`, which runs the suites inside
   the controller VM and returns the results table. Suites **monkey-patch**
   `TradingUtility.spawnSeller/spawnBuyer` **on the controller's own instance** (exposed by the
   dev-gated `getTradingUtilityForTests` seam — patching any other VM's/include's copy intercepts
   nothing) — assert `requestTraders` emits valid spawns with non-negative amounts and correct
   goods; a **director-step test** seeds a shadow hub, runs one director step, and asserts
   inventory/credit deltas and `lastSim` advance. Patches are restored after each test.
4. **Risk-targeted integration tests (the glue, where bugs live — S7).** Explicit coverage for the
   paths the pure tests *don't* reach:
   - **No double-count on reconcile (S2):** load a hub that has a shadow; assert the vanilla
     `onRestoredFromDisk` time-based catch-up is **suppressed** and only the shadow is applied.
   - **Wake-during-sim race (M3):** queue a wake ping in the same tick the hub is due; assert it is
     excluded from that tick's sim (no double advance).
   - **Cargo-only reconcile (M1):** assert `addCargo` write-back matches the shadow and that **no
     money** is moved on load.
   - **Transport round-trip (C3):** whichever transport the spike picks — assert a heartbeat
     registers/updates a hub and the all-hubs directive reaches an awake hub.
   - **Fidelity calibration (C1):** over a fixed window, assert offline owner profit **does not
     exceed** the measured online profit for the same config.
5. **In-game benchmark harness** (dev-mode): synthetic shadow-hub generator (N = 100 / 1 000 /
   10 000), run the real director loop, record hubs/sec, avg & p99 per-hub time, per-tick budget
   used, degradation activations + effective interval, shadow memory, **and `secure()` serialization
   time** (save-stall check, S5). Output a metrics panel + CSV-able line via the guarded log channel.
6. **Production counters** (behind the debug flag): hubs simulated, trades simulated, credits paid,
   director time/tick — live-server observability.

---

## Lifecycle & edge cases

- **Destroyed online:** `onDestroyed` → notify director → drop entry.
- **Destroyed offline:** an entity can only be destroyed while its sector is loaded (⇒ it was
  online ⇒ `onDestroyed` fired). Validity guard at load/heartbeat catches any residual ghost.
- **Ownership/faction change:** refreshed on next heartbeat; on load, re-read owner before paying.
- **Server restart:** director `restore()` rebuilds the registry from persisted shadows; `awake`
  reset to false; first heartbeats re-mark live hubs.
- **Weak-update sector (loaded, no player):** define **online = sector loaded at all**. The hub
  owns simulation whenever loaded; ensure it advances production in that state (today it only runs
  in `update()` — acceptable since `update` runs while loaded). The director covers only truly
  unloaded sectors.
- **Dedup:** `addScriptOnce` guarantees a single director instance galaxy-wide.
- **Time base:** the director keeps its **own clock accumulated from `update(timeStep)`** (persisted
  in `secure`/`restore`); `lastSeen`/`lastSim` use it. This is *server-uptime*, so periods while the
  **server is down are not credited** — an offline hub earns only while the server actually runs,
  which is the correct behavior. No wall-clock dependency.
- **War / no-trade zone offline:** the per-window model honors the **last-known** sector flags from
  the heartbeat snapshot (Case D); live changes during sleep aren't seen until the next heartbeat
  (i.e. until the sector loads again). Accepted approximation.
- **Server internal, not network:** hub↔director calls are **server-side Lua** (entity/galaxy
  scripts on the same server), not client RPCs — so the heartbeat's full-snapshot payload is an
  in-process table pass, not bandwidth. (The transport spike is about *reachability/return values*,
  not bandwidth.)

---

## Open questions / spikes (resolve at start of planning)

**Phase-2-blocking spikes — do these BEFORE designing the director in detail:**

1. **Heartbeat/director transport (C3 — highest risk).** Determine the hub↔director channel:
   does `Galaxy():invokeFunction` exist and return values (→ synchronous request/response), or must
   we use a director→hub push via `Sector(x,y):getEntity(id):invokeFunction`, or a persisted shared
   queue (`Server():setValue`)? **The director architecture depends on the answer; pick a fallback
   if the cheap path is absent.**
2. **Galaxy-script persistence:** confirm galaxy scripts honor `secure`/`restore` across saves, and
   measure `secure()` serialization cost at scale (save-stall, S5).
3. **Fidelity calibration (C1):** measure the **realized online inter-trade interval and traded
   amounts** for a few representative configs in both regimes (players present / loaded-but-empty)
   — these set the offline **window length and amount scaling** directly (see the revised fidelity
   invariant); confirm offline ≤ online over a fixed period.

**Other spikes:**

4. **A1 path resolution (RESOLVED in code, in-game confirmation pending):** the lib-overlay
   registration is shipped and the in-game autotrade suite asserts
   `Entity():invokeFunction("/omnihubcontroller.lua", ...)` resolves on the live station; the
   supplier has a different basename and is never matched. Run the suite in-game to close this.
5. **Offline regional pricing:** last-known snapshot vs freeze-at-base.
6. **Sub-step `dt` choice:** what fixed offline cadence balances fidelity vs cost, and what's the
   error from coarsening it on very long sleeps?
7. **Offline supply/demand impact (S4):** can the director feed regional supply/demand for an
   unloaded sector, or must that contribution be applied lazily on next load (or left as the
   documented residual gap)? Money + relations impact are modeled regardless.

---

## Decomposition / phasing

Each phase is independently shippable and gets its own implementation plan.

- **Phase 1 — Problem A + transfer removal + test seam (no director). [IMPLEMENTED]** Extract
  **only `tradingdecision`** to a lib (per-good `decideSeller`/`decideBuyer`; the window-level loop
  lifts in Phase 3); fix A1 (**lib overlay**, see Component 2) and A2; instrument A3 (consecutive
  `hasTraders`-block counter); **remove the inter-station transfer feature** (see Removed scope);
  add the guarded `OmniHubLog`, pure tests for `tradingdecision`, and the in-game spawner-override
  integration tests **hosted in the controller VM** (Testing §3). *Outcome:* live NPC auto-trade
  works; transfers are gone; the shared decision seam + test harness exist.
  **Do not** pre-extract `scheduler`/`production.step` here — they have no consumer yet and their
  interfaces would be guesses (S8).
- **Phase 2 — transport spike, then director + offline production.** **Gate: resolve the
  Phase-2-blocking spikes (transport C3, galaxy persistence, fidelity calibration) first.** Then:
  galaxy host, heartbeat registration, shadow model, `scheduler.lua`, `production.step`, the coupled
  sub-step loop (production side), handoff/reconcile **with double-count suppression (S2)**,
  benchmark harness (incl. save-serialization), **director debug gate + dev UI** (`/omnihubdirector`).
  *Outcome:* offline production accrues and reconciles on visit, with observability from day one.
- **Phase 3 — offline trade + UI + counters.** **Lift the window-level trade decision out of the
  controller's `requestTraders` into `tradingdecision.decideTrade(agg, query, rng, cfg)`** (the
  `pSeller` roll, results → ingredients → garbages order, suppression gates) so the director and
  the controller run the identical loop; calibrated per-window trade model inside the sub-step
  loop (window length + amounts from C1), affordability-checked credit settlement, lazy UI read,
  production counters, fidelity-calibration test. *Outcome:* full offline accrual, calibrated to
  not exceed online. (Inter-station transfers are removed entirely — see Removed scope.)

**Implementation begins with Phase 1**, which is fully independent of the unresolved director spikes.
