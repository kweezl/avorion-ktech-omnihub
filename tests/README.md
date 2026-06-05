# OmniHub tests

Two layers of tests, sharing one set of suites under `data/scripts/lib/omnihub/tests/`.

## Off-engine (pure) tests

Run the pure suites on your dev machine — no game required. Needs a Lua interpreter (5.2+) on PATH.

```sh
lua tests/run.lua        # run from the repo root
```

Exit code is `0` when everything passes, `1` on any failure (CI-friendly). Output lists each
test as `PASS`/`FAIL` followed by a `N passed, M failed, T total` line.

What runs: `config_spec`, `moduledefs_spec`, `production_spec`. These load the real library code
(`lib/omnihub/config.lua`, `moduledefs.lua`, `production.lua`) with the engine globals mocked in
`tests/mocks/engine.lua` (an `include()` shim, `lerp`, `%_t`, and small `productionsByGood` /
`goods` fixtures).

This `tests/` directory is **not** deployed — `build.py` only copies `modinfo.lua` and `data/`.

## In-game (integration) tests

The engine-coupled suite (`integration_spec`) can only run inside Avorion against a live OmniHub
station. With **dev mode** on, interact with an OmniHub → **Tests** tab → *Run Pure / Run
Integration / Run All*. Results are shown in the tab and echoed to chat and the server log.
Every integration test snapshots station state with `secure()` and restores it afterwards, so the
station is left unchanged.
