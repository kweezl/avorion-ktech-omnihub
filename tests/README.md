# OmniHub tests

Two layers of tests, sharing one set of suites under `data/scripts/lib/omnihub/tests/`.

## Off-engine (pure) tests

Run the pure suites on your dev machine — no game required. Needs a Lua 5.4 interpreter (the mod
targets Lua 5.4; CLAUDE.md points `$LUA_DIR` at a standalone `lua54.exe`).

```sh
"$LUA_DIR/lua54.exe" tests/run.lua   # run from the repo root (or `lua tests/run.lua` if on PATH)
```

Exit code is `0` when everything passes, `1` on any failure (CI-friendly). Output lists each
test as `PASS`/`FAIL` followed by a `N passed, M failed, T total` line.

What runs: every suite tagged `pure` in `registry.lua` — currently `config_spec`, `goodstable_spec`,
`modconfig_spec`, `moduledefs_spec`, `moduleitem_spec`, `production_spec`, `rates_spec`, `stats_spec`,
`supplier_spec`, `trading_spec`. These load the real library code (`lib/omnihub/config.lua`,
`moduledefs.lua`, `production.lua`, etc.) with the engine globals mocked in `tests/mocks/engine.lua`
(an `include()` shim, `lerp`, `%_t`, and small `productionsByGood` / `goods` fixtures).

This `tests/` directory is **not** deployed — `build.py` only copies `modinfo.lua`, `modconfig.lua`,
and `data/`.

## In-game (integration) tests

The engine-coupled suite (`integration_spec`) can only run inside Avorion against a live OmniHub
station. With **dev mode** on, interact with an OmniHub → **OmniHub Tests** (a dedicated,
dev-mode-only interaction option, separate from the trade window) → *Run All / Run Pure / Run
Integration*. Results are shown in the test window and echoed to chat and the server log.
Every integration test snapshots station state with `secure()` and restores it afterwards, so the
station is left unchanged.
