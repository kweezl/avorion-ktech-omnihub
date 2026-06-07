# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Required Environment Variables

These are defined in `.claude/settings.json` and must be set before working on this project. At the start of each session, verify they are defined — if any is missing or points to a non-existent path, ask the user to update `.claude/settings.json`.

| Variable            | Purpose                                                       | Suggested value                                              |
|---------------------|---------------------------------------------------------------|--------------------------------------------------------------|
| `AVORION_DATA_DIR`  | Avorion game data directory (scripts, assets, API reference) | `C:/Program Files (x86)/Steam/steamapps/common/Avorion/data` |
| `AVORION_MODS_DIR`  | Avorion local mods directory where this mod is deployed       | `C:/Users/<username>/AppData/Roaming/Avorion/mods`           |
| `LUA_DIR`           | Standalone Lua 5.4 install dir, used to run the off-engine tests (contains `lua54.exe`) | `C:/Path/To/lua-5.4` |

## Project Overview

This is **avorion-omnihub**, a mod for the game [Avorion](https://store.steampowered.com/app/445220/Avorion/) written in Lua. Avorion is a space-building sandbox game with a Lua scripting API for mods.

The project is configured as an IntelliJ IDEA Lua module (`LUA_MODULE`). The Avorion game data (API reference and built-in scripts) is at `$AVORION_DATA_DIR`.

## Avorion Mod Structure

Avorion mods live in `$AVORION_MODS_DIR/<modname>/` and follow this layout convention:

- `modinfo.lua` — mod metadata (name, author, version, description)
- `data/` — overrides and extensions to game data
  - `scripts/` — Lua scripts (server, client, entity, sector scripts)
  - `textures/`, `models/`, `sounds/` — asset overrides (if any)

Scripts are loaded directly by the game engine — there is no compile step.

## Deploying (build.py)

Deploy with `build.py` (repo root) — it copies only the deployable whitelist
(`modinfo.lua`, `modconfig.lua`, `data/`) into `<mods-dir>/<modFolder>`, stripping dev-only files
(`tests/`, `stubs/`, `.claude/`, `docs/`, etc.). The deploy folder name comes from the `modFolder`
key in `modinfo.lua`; the mods dir defaults to `$AVORION_MODS_DIR`. Steam-injected `modinfo.lua`
keys (e.g. the numeric Workshop `id`) are preserved across rebuilds.

```sh
python build.py                 # deploy to <AVORION_MODS_DIR>/<modFolder>
python build.py --dry-run       # show what would happen, touch nothing
python build.py --mods-dir PATH # override the mods directory
python build.py --dest PATH     # override the full destination path
python build.py --name NAME     # override the mod folder name
```

## Architecture

Server domain logic, client UI, and engine-coupled glue are deliberately separated (see also
`.claude/skills/avorion-modding/` for the patterns):

- **Entity scripts** (`data/scripts/entity/merchants/`) — the deployed, engine-loaded scripts:
  - `omnihubcontroller.lua` (namespace `OmniHub`) — the main station controller; orchestrates
    production, trading, and the trade UI. Largest file.
  - `omnihubsupplier.lua` — the supplier/shop side.
  - `omnihubtests.lua` (namespace `OmniHubTests`) — dev-mode-only test window (see Testing).
- **`lib/omnihub/`** — pure-ish domain modules (`production`, `trading`, `stats`, `rates`,
  `config`, `moduledefs`, `moduleitem`, `supplierstock`). Engine-independent helpers here are what
  the off-engine suites cover. `transfers.lua` and `factorymap` are server-only (they touch
  `Sector()`/`Entity()`), included only under `if onServer()`.
- **`lib/omnihub/ui/`** — client-only presentation modules (`goodstable`, `modules`, `config`,
  `statistics`, `common`); no server calls or domain math. Included only under `if onClient()`.

**MCM config:** `modconfig.lua` (repo root, deployed) integrates the optional **Mod Configuration
Menu** mod (Workshop `3674093144`, an *optional* dependency). The mod works standalone on built-in
defaults; when MCM is present, `OmniHubConfig.get` reads live values from it.

## EmmyLua Stubs

EmmyLua type-annotation stubs for the engine API live in `stubs/generated/` and
exist only so IntelliJ's EmmyLua plugin can resolve types and suppress false
`undefined-global` warnings. They are never deployed.

The stubs are **generated**, not hand-written — `stub_generator.py` (repo root)
parses the shipped Avorion API documentation (`$AVORION_DATA_DIR/../documentation`,
~270 HTML pages) into one snake_case `.lua` file per type (`entity.lua`,
`cargo_bay.lua`, `globals.lua`, …). `stubs/generated/` is **gitignored** — the
generator is the source of truth, so regenerate after cloning or when the game
updates:

```sh
python stub_generator.py            # docs path from $AVORION_DATA_DIR; out → stubs/generated/
python stub_generator.py <docs> <out>   # or pass paths explicitly
```

Requires Python 3 + `beautifulsoup4` (`pip install beautifulsoup4`). Engine
globals that have no documentation page (`include`, `callable`, `callingPlayer`,
`_t`/`_T`, `quat`, …) are hand-maintained in the generator's `EXTRAS_LUA` block
and emitted as `stubs/generated/_extras.lua`; types referenced but lacking a doc
page are forward-declared in `stubs/generated/_forward.lua`.

**Looking up the engine API:** grep `stubs/generated/*.lua` — NOT the HTML docs. The stubs are the
same API distilled into clean EmmyLua (`---@field name type`, `function _Type:method(args)`), one
snake_case file per type (e.g. `scroll_frame.lua`, `entity.lua`), so a member's type/signature is one
grep away instead of buried in markup. Example: `grep -i scroll stubs/generated/scroll_frame.lua`.
Only fall back to `$AVORION_DATA_DIR/../documentation/*.html` for prose the stubs don't carry.

**IntelliJ setup:** add `stubs/` as a Source root so EmmyLua scans `generated/`:
_File → Project Structure → Modules → avorion-omnihub → Sources → mark `stubs/` as Sources_

**VS Code / emmylua-analyzer-rust setup:** copy `.emmyrc.json.example` →
`.emmyrc.json` (gitignored) and set the game `data/scripts` path in
`workspace.library` to your local Avorion install. The config wires `include`
as the require-like function and lists `stubs/generated` as a library so the
generated stubs resolve. `runtime.version` is set to `Lua5.4` to match the Lua
version the mod targets (also what the off-engine tests run on via `lua54.exe`),
which provides the `integer` type used throughout the generated stubs.

## Testing

**`tests/README.md` is the source of truth** for the test layout, suite list, and how each layer
runs. The essentials:

- Two layers share one set of suites under `data/scripts/lib/omnihub/tests/` (`framework.lua` =
  assert/runner, `registry.lua` = suite catalog tagging each suite `pure` vs `integration`,
  `suites/*_spec.lua`).
- **Off-engine (pure)** — run on the dev machine, no game needed, against the suites tagged `pure`:

  ```sh
  "$LUA_DIR/lua54.exe" tests/run.lua   # exit 0 on success, 1 on any failure
  ```

  Also run in CI on push/PR to `main` (`.github/workflows/tests.yml`, Lua 5.4 on `ubuntu-latest`).
- **In-game (integration)** — engine-coupled paths; run live with **dev mode** on via the dedicated
  **OmniHub Tests** interaction option (`data/scripts/entity/merchants/omnihubtests.lua`), a separate
  window kept out of the trade UI. Both the option and the `runTests` RPC are gated on
  `GameSettings().devMode`.

When changing pure logic (`production.lua`/`config.lua`/`moduledefs.lua`/…), run the off-engine
suite before deploying. Add new pure suites under `suites/` and list them in `registry.lua`.

## Development Notes

- Lua scripts are interpreted directly by the Avorion engine — there is no compile step for the mod itself.
- The Avorion scripting API: grep `stubs/generated/*.lua` first (see EmmyLua Stubs above); the
  shipped built-in scripts live in `$AVORION_DATA_DIR/scripts/` for reference examples.
- Scripts run in a sandboxed Lua 5.4 environment; standard libraries are partially available.
- Server-side and client-side scripts are separate; network communication uses `invokeServerFunction` (client→server), `invokeClientFunction` (server→specific client), and `broadcastInvokeClientFunction` (server→all clients). Functions must be marked with `callable(namespace, "funcName")` at file scope to be remotely invocable.

## Networking

Bandwidth and tick cost matter — a multiplayer server may run many of these stations. Follow these rules when sending data between server and client:

- **The server is always authoritative.** Client-sent values are requests/hints only — validate, clamp, and re-derive everything on the server before applying. Never trust a client value for a gameplay effect or permission.
- **Send the minimum; resolve the rest client-side.** Don't ship data the client can reconstruct on its own:
  - **Entities:** send an id (uuid/index), not the entity's data. The client resolves the live object with `Sector():getEntity(id)` / `Entity(id)` and reads what it needs.
  - **Localized text:** never send display strings the client can localize itself. `translatedName`/`translatedTitle` are **client-only** — reading them on the server fails (and Avorion *logs the failed read even inside `pcall`*; see Pitfalls). Send the id/key and call the translated getter on the client. Use the raw `name` only when a non-localized label is acceptable.
  - **Static/derivable data:** catalogs, recipes, schemas, and anything both VMs can `include()` should be derived locally, not transmitted.
- **Prefer deltas over full payloads.** When one field or row changes, push just that partition (a targeted `invokeClientFunction` carrying the changed item) and patch it in place — don't re-send the whole table. Reserve full syncs for first open.
- **Lazy-reload on demand, not eagerly.** When something goes stale but isn't visible, mark it dirty and refresh only when the player actually looks at it (e.g. on tab select), instead of pushing immediately. **Ask the user before adding any new lazy-reload trigger** — it's a UX trade-off they should approve.
- **Don't push per-tick.** Sync on events (window open, value change, explicit request) and debounce frequent inputs (commit a text field on focus-out/Enter, not per keystroke). Raise the client `getUpdateInterval` to a fast tick only while a window is open, and drop back afterward.
- **Target, don't broadcast.** Use `invokeClientFunction(player, ...)` for one viewer; reserve `broadcastInvokeClientFunction` for state every client genuinely needs.
- **Gate sends by permission/relevance.** Only send owner-only data to the owner (server-side `callerIsOwner()` check on the send RPC, *and* don't request it client-side for non-owners). This is both security and bandwidth.
- **Batch related updates** into a single RPC rather than firing several in a row; RPCs are async, fire-and-forget (no return value), so design explicit request→response pairs.

Avorion-specific patterns, recipes, and reference material: see `.claude/skills/avorion-modding/`.