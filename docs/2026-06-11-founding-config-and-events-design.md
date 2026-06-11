# Founding Config & Owner Event Notifications — Design

Date: 2026-06-11
Status: approved design, pre-implementation

## Goals

1. Move the OmniHub founding cost (currently hardcoded 15,000,000 cr) into the mod config,
   keeping 15M as the default.
2. Remove the forced 25,000 cargo-hold floor at founding — it is phantom capacity not backed by
   blocks, and the first block-plan change recalculates the hold from the real plan, dropping any
   overflow into space.
3. Add an owner event-notification system: a per-hub checkbox (default on) that sends chat
   messages to the owning faction for trade results, trade failures, storage shortfall,
   insufficient assembly capacity, and persistent production stalls — styled like vanilla
   factory/tradingmanager messages, but digesting trades instead of reporting each one as
   vanilla does.
4. Show the recommended assembly (production capacity) value in the Statistics tab.
5. Delete dev-gated `hubLog` lines that the new events make redundant.

## 1. Founding cost → MCM config

- New entry in `OmniHubConfig.schema` (`data/scripts/lib/omnihub/config.lua`):
  - key `foundingCostMillions`, type `number`, title "Founding cost",
    description "OmniHub founding price, in millions of credits.",
    default **15**, min **0**, max **500**, unit "M cr" (label only; value stays a plain number).
    Min 0 supports free founding on creative servers.
  - Not a percent key — no fraction conversion.
- `data/scripts/entity/stationfounder.lua` includes `lib/omnihub/config` and sets
  `price = OmniHubConfig.get("foundingCostMillions") * 1000000`.
- The price is evaluated when the founder script loads (every founder interaction), so MCM
  changes apply on the next founding without restart.
- **Implementation risk to verify:** the MCM-synced value must be readable in the client VM so
  the *displayed* founder price matches the server-charged one. If MCM does not sync to clients,
  fall back to the schema default client-side and document the mismatch; do not invent a custom
  sync channel for this.
- README: replace the "costs 15,000,000 credits" sentence with "configurable, default 15M".

## 2. Remove the 25k cargo floor

- Delete `MIN_CARGO_BAY` (`omnihubcontroller.lua:50`) and the `initialize()` block that writes
  `bay.cargoHold` (lines ~263–267).
- Rationale: the floor writes capacity the block plan does not back. When the player edits the
  plan (e.g. adds a small cargo block), the engine recomputes the hold from real blocks; cargo
  above the recomputed capacity drops into space. The floor is a trap, not a safety net.
- Migration: existing hubs relying on the phantom 25k see their real (smaller) capacity on next
  load. Goods do NOT drop at load — production stalls until real cargo blocks are added, and the
  new storage-shortfall event tells the owner why. Add a changelog/README note.
- README: remove the "minimum cargo hold of 25,000" guarantee sentence.

## 3. Owner event notifications

### 3.1 Pure module `data/scripts/lib/omnihub/events.lua` (namespace `OmniHubEvents`)

Engine-independent (same style as `rates.lua`), covered by an off-engine suite. API:

- `OmniHubEvents.new()` → state: pending trade records, digest timer, condition latches.
- `recordTrade(s, kind, goodName, amount, price, partnerName)` — accumulate a completed docked
  trade (`kind` = "buy" | "sell").
- `advance(s, dt)` → returns the events due this tick: a **digest** payload when ≥300 s (5 min)
  have passed since the first pending record (flush at most once per 5 min, only when non-empty),
  plus any stall events whose threshold elapsed (see `recordStallState`). Digest aggregates
  per-good totals and net credits, listing at most 4 goods by traded value with a "+N more"
  suffix, e.g. *"Sold Steel ×120, bought Coal ×80 +3 more — net +45,000 cr"*.
- `tradeFailed(goodName, amount, reason)` → immediate event payload. Reasons map from the
  existing failure branches: partner cannot pay, stock cap reached, nothing in stock, ship hold
  full, immediate-wave failure code.
- `checkStorage(s, over)` → edge-triggered: event payload on `false→true` ("cargo too small to
  hold all goods max stocks"), a "resolved" payload on `true→false`, otherwise `nil`. No repeats
  while the state holds.
- `checkAssembly(s, capacity, recommended)` → same latch semantics for
  `capacity < recommended`.
- `recordStallState(s, moduleKey, productName, stalled, reason, detail)` — fed once per
  production tick per installed module with the `canStartCycle` outcome. The module accumulates
  per-key stalled time (via `advance(dt)`); a key whose **actionable** stall persists ≥600 s
  (10 min) becomes report-pending. Stall reports are **batched into one summary** and
  cooldown-gated like the trade digest: `advance` returns at most one stall summary per 300 s,
  aggregating every report-pending key, grouped by reason and capped at 4 entries with "+N
  more", e.g. *"Production stalled for 10+ minutes: Steel, Aluminium +2 more (missing: Coal);
  Wire (no cargo space)"* — so 40 modules starving on one ingredient cost one chat line, not 40.
  Reported keys latch (no repeats while stalled); when previously reported keys produce again,
  the next flush carries one batched "resumed" line. Actionable reasons are missing ingredients
  and insufficient cargo space; a stall on max-stock-reached is the buffer working as intended
  and stays silent. Brief stalls between trade waves never reach the threshold, so they stay
  silent too.

Payloads are plain tables `{ text, severity }` (severity: info | warning); the module never
touches `Entity()`/`Faction()`/chat. Timestamps come from `advance(dt)` accumulation, not
wall-clock.

### 3.2 Controller glue (server-only, `omnihubcontroller.lua`)

- `eventsEnabled` boolean, default **true**, persisted via `secure()`/`restore()` (wrapped, never
  redefined). Edited via a new "Send event notifications" checkbox in the hub's Config tab
  (`ui/config.lua`), joining the existing config RPC payload — server clamps/validates as it does
  for the other fields. Single master checkbox; no per-event toggles (can be added later).
- Emit helper, vanilla pattern:
  `Faction(Entity().factionIndex):sendChatMessage(Entity(), <ChatMessageType>, msg, ...)`.
  - Message text carries hub name, sector name, sector coords (vanilla `\s(%i:%i)` style), the
    related entity's **raw `name`** (never `translatedName` server-side — it errors and logs), and
    the related entity's owner faction name where relevant.
  - **Hub id (entity index) is appended only when the server's `GameSettings().devMode` is on**,
    checked at emit time. Regular players see no internal ids.
  - Severity mapping: digests → Information; failures and condition events → Warning/Error
    (exact `ChatMessageType` values confirmed against `stubs/generated/` at implementation).
  - Alliance-owned hubs message alliance chat (all members see it) — matches vanilla.
- Hook points:
  - `onDockedTradeBought` / `onDockedTradeSold` → `recordTrade` (player UI trades route through
    the same tradingmanager callbacks, so they land in the digest too).
  - Existing failure branches (docked delivery unaffordable / moved-no-stock, docked pickup
    moved-no-stock, immediate-wave failure) → `tradeFailed` → emit immediately.
  - `rebuild()`, `onBlockPlanChanged`, config-change RPC → recompute storage `over`
    (`totalLimitVol > capacity` — depends only on limits and capacity, so these are the only
    change points) and recommended capacity → `checkStorage` / `checkAssembly` → emit.
  - The production tick feeds each installed module's `canStartCycle` outcome to
    `recordStallState` (the tick already computes it; no extra work).
  - Digest flush and stall thresholds driven from the existing server update tick via
    `advance(timeStep)`.
- **Offline (director) simulation emits no events.** Online sectors only; existing stats still
  capture offline trades.

### 3.3 Spam control (decided)

- Successful trades: periodic **digest** (≤1 chat line per 5 min per hub, ≤4 goods listed —
  covers multiple trade waves, since wave completion itself is not reliably detectable), never
  per-transaction.
- Failures: individual and immediate.
- Conditions (storage, assembly): edge-triggered with a one-time "resolved" message.
- Production stalls: 10-minute persistence threshold, actionable reasons only, **batched into
  one summary line** (≤1 per 5 min per hub, grouped by reason, ≤4 entries + "+N more"), with a
  one-time batched "resumed" message.
- Message texts state the fix, not just the fault, where one exists (e.g. "deposit credits into
  the faction account", "add cargo space", "add assembly blocks").

## 4. Assembly recommendation

- Pure function in `production.lua`:
  `OmniHubProduction.recommendedCapacity(installed, resolveRecipe, goodsTable, minTime)` =
  max over installed module recipes of `totalValue / (minTime × levelBonus)` — the production
  capacity above which `timeToProduce` bottoms out at `MIN_TIME_TO_PRODUCE` (15 s) and cycles
  cannot get faster. Empty hub → 0.
- Statistics tab (`ui/statistics.lua`): new line near the storage summary —
  "Production capacity: X / Y recommended (Z%)", red when `X < Y`, with a tooltip explaining
  that assembly blocks raise production capacity and that capacity beyond the recommended value
  does not speed up cycles further. The two numbers ride the existing statistics payload (no new
  RPC).
- The same comparison feeds `checkAssembly` (section 3.2).

## 5. Log cleanup

Delete `hubLog` lines now covered by events (events fire in normal play; `hubLog` is dev-gated):

- docked trade success logs (`omnihubcontroller.lua:1018`, `:1025`),
- docked delivery/pickup failure logs (`:981`, `:987`, `:997`),
- immediate-wave failure log (`:736`).

Other `hubLog` lines (rebuild, sync, director) stay — events do not cover them.

## Testing

- New pure suite `data/scripts/lib/omnihub/tests/suites/events_spec.lua`, tagged `pure`,
  registered in `registry.lua`: digest accumulation/flush timing, per-good aggregation, the
  4-good cap and net credits, latch edge semantics (no repeat while held, resolved fires exactly
  once, re-arm), stall threshold accumulation (below/at/above 600 s, reason changes reset, silent
  for max-stock stalls), stall batching (many keys crossing at once → one summary, grouping by
  reason, cap + "+N more", cooldown between summaries, batched "resumed" exactly once),
  `tradeFailed` formatting.
- `production_spec.lua`: `recommendedCapacity` cases (single module, max across modules,
  level bonus, empty hub → 0).
- Run `"$LUA_DIR/lua54.exe" tests/run.lua` before deploying.
- In-game (dev mode): found a hub at a configured price, watch digest/failure/condition messages,
  toggle the checkbox off and confirm silence, verify hub id appears only with dev mode on.

## Out of scope

- Per-event-type toggles (master checkbox only, for now).
- Events from the offline director simulation (including wake summaries).
- Any new lazy-reload triggers or per-tick syncs (per CLAUDE.md networking rules).
- Repeat-failure cooldowns, excluding the owner's own UI trades from the digest, and debouncing
  condition checks during block-plan editing — considered and deliberately not included.
