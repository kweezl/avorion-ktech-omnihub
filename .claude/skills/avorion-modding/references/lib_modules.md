# Standard Library Modules (`data/scripts/lib/`)

Include any of these with `include("name")` after extending `package.path`. All are in `$AVORION_DATA_DIR/scripts/lib/`.

## Most commonly included

| Module | Style | Key exports |
|--------|-------|-------------|
| `stringutility` | side-effecting | `string:split(sep)`, `string.join(tbl, sep, fmt)`, `string.starts(s, prefix)`, `string.ends(s, suffix)`, `string.trim(s)`, `enumerate(values, f)`, the `%` / `%_t` / `%_T` localization operators |
| `callable` | side-effecting | `callable(namespace, "funcName")` / alias `rcall` — registers a function as server-callable via RPC |
| `utility` | side-effecting | `lerp`, `multilerp`, `round`, `getRandomEntry`, `getValueFromDistribution`, `tablelength`, `createDigitalTimeString`, `createMonetaryString`, `createReadableTimeTable`. Auto-includes `stringutility`. |
| `randomext` | side-effecting | Overrides `math.random` with a per-state RNG. Exports: `random()` (get current RNG), `getFloat(min, max)`, `getInt(min, max)`, `selectByWeight(rnd, values)`, `shuffle(rnd, array)`, `randomEntry(rnd, array)`, `makeSerialNumber(seed, length, prefix, postfix, chars)` |
| `goods` | side-effecting | `tableToGood(table) → TradingGood`, `goodToTable(good) → table` — serialize/deserialize TradingGood userdata for cross-script passing |
| `entity` | side-effecting | Interaction gate helpers: `checkCaptain(errors)`, `checkForPilot(errors)`, `checkArmed(errors)`. Used in `interactionPossible` to explain why interaction is locked |
| `faction` | side-effecting | `FactionStateFormType`, `FactionArchetype` enums and faction-state helpers |
| `player` | side-effecting | `CheckPlayerDocked(player, object, errors)`, `CheckShipDocked(faction, ship, object, errors)` — standard interaction precondition checks |
| `class` | module | `class(base, init) → Class` — Lua 5.1 OOP with `is_a` test and `_base` chain. `local MyClass = class(nil, function(self, args) ... end)` |

## Generator modules (module-returning)

```lua
local PlanGenerator = include("plangenerator")
local ShipGenerator = include("shipgenerator")
local Placer        = include("placer")
local ShipUtility   = include("shiputility")
local DefaultScripts = include("defaultscripts")
```

| Module | Purpose |
|--------|---------|
| `plangenerator` | Build a block plan for a ship; `PlanGenerator.generate(seed, style, ...)` |
| `plangeneratorbase` | Base class for plan generators |
| `shipgenerator` | Generate a complete ship (plan + faction + AI) |
| `asyncshipgenerator` | Async version that yields across frames |
| `pirategenerator`, `asyncpirategenerator` | Pirate ship generation |
| `fightergenerator`, `sectorturretgenerator` | Fighter and turret generation |
| `placer` | Spawn entities without overlap: `Placer.resolveIntersections(entities)`, `Placer.placeAtOrigin(entity)` |
| `shiputility` | Ship content utilities; `ArmedWeapons`, `DefenseWeapons`, `AttackWeapons` catalogs |
| `defaultscripts` | `AddDefaultShipScripts(ship)`, `AddDefaultStationScripts(station)`, `SetBoardingDefenseLevel(entity)` — attach the standard script set to a new entity |
| `tradingmanager` | Station trading state management |
| `tradingutility` | Price calculation, demand curves |
| `dialogutility` | NPC dialog scaffolding; `Dialog.addDialogOption(...)`, responses, choices |
| `galaxy` | Galaxy-level helpers; coordinates, faction territories, sector type queries |
| `sectornamegenerator` | Generate sector names from seeds |
| `passagemap` | Wormhole / passage query map |
| `factorymap` | Factory ↔ good ↔ sector mapping |
| `upgradegenerator` | `local gen = include("upgradegenerator")()` — generates system upgrades |
| `captaingenerator` | Generate captain characters |
| `captainutility` | Captain stat manipulation |
| `rewards` | Reward distribution utilities |
| `mission`, `missionutility`, `structuredmission` | Mission framework helpers |
| `weapongenerator`, `turretgenerator` | Weapon and turret generation |

## Utility modules

| Module | Purpose |
|--------|---------|
| `tooltipmaker` | Build richly formatted tooltip strings |
| `uicollection` | UI container/list helper |
| `queue`, `ringbuffer` | Standard data structures |
| `xml` | Minimal XML parser |
| `eventutility` | Event scheduling helpers |
| `spawnutility` | Sector spawn helpers |
| `waveutility` | Enemy wave management |
| `relations` | Faction relationship utilities |
| `reconstructionutility` | Reconstruct destroyed ships |
| `damagetypeutility`, `weapontype`, `weapontypeutility` | Damage type and weapon category helpers |
| `orderTypes` | AI order type constants |
| `music` | Client-side music control |
| `entitydbg` | Debug overlay (attached via `/run Entity():addScript("lib/entitydbg.lua")` in dev) |
| `testsuite` | Unit testing helpers for offline scripts |

## Subfolders

| Subfolder | Contents |
|-----------|----------|
| `lib/story/` | Story-mission helpers: `adventurerguide`, `ai`, `scientist`, `smuggler`, `swoks`, `the4`, `xsotan`, etc. Include as `include("story/xsotan")` |
| `lib/npcapi/` | Dialog sub-helpers: `adddialogoption`, `singleinteraction` |

## Include call styles

```lua
-- Side-effecting (library injects globals, returns nil):
include("stringutility")    -- now string.split() etc. are available globally

-- Module-returning (library returns a table):
local Placer = include("placer")
Placer.resolveIntersections(...)

-- Factory-returning (library returns a constructor):
local UpgradeGenerator = include("upgradegenerator")()
```

If you're unsure which style a library uses, read its last line:
- No `return` → side-effecting
- `return SomeName` → module-returning
- `return function(...) end` → factory-returning