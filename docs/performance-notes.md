# OmniHub — Performance Notes & Optimization Backlog

> **Status: KNOWN ISSUES — OPTIMIZE LATER.** Nothing here is a current bug; these are expected
> performance/network costs that scale poorly with the planned features (combined Goods tab,
> "show all goods" / trading-station mode). Captured so we don't rediscover them. Revisit before
> shipping the all-goods phase.

## 1. Network: how the OmniHub UI syncs today

Server → client payloads:

| RPC | Contents | Sent when |
|---|---|---|
| `receiveGoods` *(inherited TradingManager)* | `buyPriceFactor, sellPriceFactor, boughtGoods[], soldGoods[], policies, stats, ownSupplyTypes, supplyDemandInfluence, stockInfluence` | init, window open, **every mark toggle**, install/uninstall |
| `receiveHubGoods` *(ours)* | products[] + resources[] rows (name, icon, amount, internal, price, regionalPct, enabled) | window open only |
| `receiveModuleData` | installed[] + inventory[] | open, install/uninstall |
| `receiveStats` | lifetime, lastHour, last-10 txns | open |
| `receiveHubConfig` | config + partner option lists + errors | open, config change |

## 2. The heavy payload: `receiveGoods`

- `boughtGoods` / `soldGoods` are arrays of **full `Good` objects** (name, plural, description, price,
  size, icon path, color, level, …) — roughly **~150–250 bytes/good serialized**, sent as **two**
  arrays plus several extra tables.
- It is **monolithic**: vanilla always sends *both* lists and repaints both. There is **no
  "update just the Buy tab"** entry point in the inherited code.
- Cheap today only because the hub trades few goods (typically **5–30** produced/consumed + marked-on).

## 3. The real hotspot — frequency × size

- `setGoodSell` / `setGoodBuy` currently end with `OmniHub.sendGoods()` → **every checkbox click
  re-sends the entire `receiveGoods` payload** (both full good arrays + extras). Invisible at 5–30
  goods; it's the *frequency × size* product that bites at scale.
- `rebuild()` also runs on each toggle (aggregate → buildTradeLists → initializeTrading →
  updateOwnSupply → computeTimeToProduce per module) — **server CPU**, scales with good count.

## 4. Constraints

1. **`receiveGoods` is all-or-nothing.** To send less we must either stop using it on toggles or
   build our own minimal update on top of the rendering we already control
   (`allSold`/`allBought` + pagination + `repaintTradeLines`).
2. **`Good` objects are fat**, and we send two arrays of them.
3. **Avorion RPCs** serialize the whole Lua table per call; very large packets cost serialization
   time, can stutter the landing frame, and have practical size ceilings to stay well under.
4. **Key lever:** the client's `goods` table is ambient, and `soldGoods` elements are literally
   `goods[name]:good()`. So **the client can reconstruct any good object locally from just its name** —
   a toggle need not ship good data at all, only "good X: side, on/off".

## 5. Expected degradation under the planned features

- **All-goods + per-toggle `sendGoods`:** if `soldGoods`/`boughtGoods` can each hold ~200 goods,
  every `receiveGoods` becomes **~400 fat objects ≈ tens of KB (order ~80 KB)** — fired **on every
  checkbox click**. Rapid toggling would spray large packets and stutter. **This is the primary risk.**
- **Combined Goods tab data (rates/SP/BP/Market) is fine** as long as it stays **once per window
  open** (no live push; rates refresh on reopen). Its cost is **server CPU**, not bandwidth:
  ~200 `economyupdater` calls + price calcs per open → solve with caching, not networking.
- Stats / config / modules payloads are small and unaffected.

## 6. Planned mitigations (design intent — implement when doing all-goods)

- **Bulk goods/rates payload: once per open only.** Never push rates while the window is open.
- **Mark toggles → incremental, single-tab updates.** A Sell-mark change only alters `soldGoods`
  (Buy tab); a Buy-mark change only alters `boughtGoods` (Sell tab). Optimized toggle:
  - Server: validate owner, flip the mark, **do not call `sendGoods`**; ack a tiny
    `(goodName, side, on/off)`.
  - Client: add/remove `goods[name]:good()` from `allSold`/`allBought` and `repaintTradeLines()` —
    near-zero payload, only the affected tab.
- **Cache the per-good `economyupdater`/price lookups** for the all-goods open payload (compute once
  per open or on a timer) to avoid ~200 sector-script calls per refresh.

### 6a. economyupdater per-good cost — NOW LIVE (all-goods Goods tab)

The trading-station Goods tab is implemented and lists **every** good. Confirmed call sites:

| Path | economyupdater calls | where | when |
|---|---|---|---|
| **Goods tab** (`sendHubGoodsTo` → `regionalInfo`) | ~1 per good (**~200**) | **server** | window open, install, uninstall |
| **Buy/Sell tabs** (`repaintTradeLines` → `getSellPrice`/`getBuyPrice`) | ≤15 (current page only) | client | repaint / page change |

- The heavy cost is **server-side**: `sendHubGoodsTo` (omnihubcontroller.lua, see the `OPTIMIZE LATER`
  comment at the `regionalInfo` loop) calls `Sector():invokeFunction("economyupdater.lua", …)` once
  for **every** good in `goods` (~200) each time the payload is built, then ships the whole list. The
  **client does NOT** call economyupdater per Goods row — it renders the server-sent numbers.
- The client only calls economyupdater for the vanilla **Buy/Sell** rows, and only for the **current
  page slice (≤15)** on repaint — stock vanilla behaviour, bounded, not a concern.

**Mitigations (in priority order):**
1. **Skip the lookup for non-produced/consumed goods.** Only call `regionalInfo` where
   `OmniHub.trader.ownSupplyTypes[name]` is set (the hub's own production goods, ~10); show a neutral
   market (`0%`, `base × factor`) for the rest. Drops ~200 → ~10 with no loss where it matters. **Cheapest, biggest win.**
2. **Cache `regionalInfo` per good** for a few seconds so rapid reopens / install-uninstall reuse it.
3. Fold into the **general delta-sync** (§7) so only changed goods are recomputed/sent.

## 7. TODO — general delta-sync

> **Find a general solution to send the player only the CHANGES, not the full data payload, when the
> client already holds the major portion of the data.** The per-good incremental toggle above is the
> first instance; generalize it: version/diff the goods + rates tables server-side and transmit only
> added/removed/changed entries (keyed by good name), letting the client patch its cached lists. This
> keeps the all-goods / trading-station mode cheap on the wire even with ~200 goods, and applies to the
> combined Goods tab as well as the Buy/Sell lists.

## 8. Current code touch points (for when we optimize)

- `data/scripts/entity/merchants/omnihubcontroller.lua`
  - `setGoodSell` / `setGoodBuy` — currently call `OmniHub.sendGoods()` (full resync) → make incremental.
  - `receiveGoods` wrap + `applyPageSlices` / `repaintTradeLines` — client-side list management already
    here; the delta path plugs in here.
  - `sendHubGoodsTo` + `regionalInfo` — the once-per-open bulk payload + per-good economy/price lookups
    to cache.
- `data/scripts/lib/tradingmanager.lua` *(vanilla, reference only — do not edit)* — `receiveGoods` /
  `sendGoods` are the monolithic path we work around.
