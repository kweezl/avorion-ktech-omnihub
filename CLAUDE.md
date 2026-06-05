# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Required Environment Variables

These are defined in `.claude/settings.json` and must be set before working on this project. At the start of each session, verify both are defined — if either is missing or points to a non-existent path, ask the user to update `.claude/settings.json`.

| Variable            | Purpose                                                       | Suggested value                                              |
|---------------------|---------------------------------------------------------------|--------------------------------------------------------------|
| `AVORION_DATA_DIR`  | Avorion game data directory (scripts, assets, API reference) | `S:/SteamLibrary/steamapps/common/Avorion/data`              |
| `AVORION_MODS_DIR`  | Avorion local mods directory where this mod is deployed       | `C:/Users/<username>/AppData/Roaming/Avorion/mods`           |

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

## Development Notes

- No build system or test runner — Lua scripts are interpreted directly by the Avorion engine.
- The Avorion scripting API is documented in `$AVORION_DATA_DIR/scripts/`.
- Scripts run in a sandboxed Lua 5.2 environment; standard libraries are partially available.
- Server-side and client-side scripts are separate; network communication uses `invokeServerFunction` (client→server), `invokeClientFunction` (server→specific client), and `broadcastInvokeClientFunction` (server→all clients). Functions must be marked with `callable(namespace, "funcName")` at file scope to be remotely invocable.

Avorion-specific patterns, recipes, and reference material: see `.claude/skills/avorion-modding/`.