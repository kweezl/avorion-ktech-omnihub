# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Required Environment Variables

These are defined in `.claude/settings.json` and must be set before working on this project. At the start of each session, verify they are defined — if any is missing or points to a non-existent path, ask the user to update `.claude/settings.json`.

| Variable            | Purpose                                                       | Suggested value                                              |
|---------------------|---------------------------------------------------------------|--------------------------------------------------------------|
| `AVORION_DATA_DIR`  | Avorion game data directory (scripts, assets, API reference) | `S:/SteamLibrary/steamapps/common/Avorion/data`              |
| `AVORION_MODS_DIR`  | Avorion local mods directory where this mod is deployed       | `C:/Users/<username>/AppData/Roaming/Avorion/mods`           |
| `LUA_DIR`           | Standalone Lua 5.4 install dir, used to run the off-engine tests (contains `lua54.exe`) | `D:/apps/lua-5.4.8` |

## Project Overview

This is **avorion-omnihub**, a mod for the game [Avorion](https://store.steampowered.com/app/445220/Avorion/) written in Lua. Avorion is a space-building sandbox game with a Lua scripting API for mods.

The project is configured as an IntelliJ IDEA Lua module (`LUA_MODULE`). The Avorion game data (API reference and built-in scripts) is at `$AVORION_DATA_DIR`.

## Avorion Mod Structure

Avorion mods live in `$AVORION_MODS_DIR/<modname>/` and follow this layout convention:

- `modinfo.lua` — mod metadata (name, author, version, description)
- `data/` — overrides and extensions to game data
  - `scripts/` — Lua scripts (server, client, entity, sector scripts)
  - `textures/`, `models/`, `sounds/` — asset overrides (if any)

Scripts are loaded directly by the game engine — there is no compile step. To deploy during development, symlink or copy the repo folder into `$AVORION_MODS_DIR`.

## EmmyLua Stubs

`stubs/` contains EmmyLua type annotation stubs for all engine-injected globals. These files are never deployed — they exist only so IntelliJ's EmmyLua plugin can resolve types and suppress false `undefined-global` warnings.

| File | Contents |
|------|----------|
| `avorion_globals.lua` | Engine functions: `include`, `invokeServerFunction`, `onServer`, `callingPlayer`, etc. |
| `avorion_math.lua` | Geometry types: `vec2`, `vec3`, `quat`, `Rect`, `ColorRGB`, `Random`, math helpers |
| `avorion_types.lua` | Object types: `Entity`, `Player`, `Sector`, `Faction`, `Galaxy`, `ShipAI`, `CargoBay`, `DockingPositions`, `Plan`, `TradingGood` |
| `avorion_enums.lua` | Enum tables: `EntityType`, `AIState`, `ChatMessageType`, `WeaponCategory`, `AlliancePrivilege`, `FontType` |
| `avorion_ui.lua` | UI widgets and layout helpers: `Label`, `Button`, `ComboBox`, `TabbedWindow`, `UIVerticalSplitter`, etc. |

**IntelliJ setup:** add `stubs/` as a Source root so EmmyLua scans it:
_File → Project Structure → Modules → avorion-omnihub → Sources → mark `stubs/` as Sources_

## Testing

There are two test layers, sharing one set of suites under `data/scripts/lib/omnihub/tests/`
(`framework.lua` = tiny assert/runner, `registry.lua` = suite catalog, `suites/*_spec.lua`).
See `tests/README.md` for details.

- **Off-engine (pure) tests** — run on the dev machine, no game needed. Cover engine-independent
  logic: `lib/omnihub/config.lua`, `moduledefs.lua`, and the extracted pure helpers in
  `lib/omnihub/production.lua` (`timeToProduce`, `sellerProbability`, `aggregate`, `canStartCycle`).
  Run from the repo root:

  ```sh
  "$LUA_DIR/lua54.exe" tests/run.lua
  ```

  Exit code is `0` on success, `1` on any failure (CI-friendly). The off-engine harness
  (`tests/run.lua` + `tests/mocks/engine.lua`) supplies an `include()` shim and mock engine
  globals (`productionsByGood`, `goods`, `lerp`, `%_t`). The `tests/` directory is **not** deployed
  (`build.py` whitelists only `modinfo.lua` and `data/`).

- **In-game (integration) tests** — engine-coupled paths (`secure`/`restore` round-trip, `rebuild`,
  `computeTimeToProduce` against real `goods`). Run live with **dev mode** on: interact with an
  OmniHub station → **Tests** tab → *Run Pure / Run Integration / Run All*. Results show in the tab
  and are echoed to chat and the server log. Integration tests snapshot station state via `secure()`
  and restore it afterwards, leaving the station unchanged. The Tests tab and the server-side
  `runTests` RPC are both gated on `GameSettings().devMode`.

When changing pure logic in `production.lua`/`config.lua`/`moduledefs.lua`, run the off-engine
suite before deploying. Add new pure suites under `suites/` and list them in `registry.lua`.

## Development Notes

- Lua scripts are interpreted directly by the Avorion engine — there is no compile step for the mod itself.
- The Avorion scripting API is documented in `$AVORION_DATA_DIR/scripts/`.
- Scripts run in a sandboxed Lua 5.2 environment; standard libraries are partially available.
- Server-side and client-side scripts are separate; network communication uses `invokeServerFunction` (client→server), `invokeClientFunction` (server→specific client), and `broadcastInvokeClientFunction` (server→all clients). Functions must be marked with `callable(namespace, "funcName")` at file scope to be remotely invocable.

Avorion-specific patterns, recipes, and reference material: see `.claude/skills/avorion-modding/`.