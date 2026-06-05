#!/usr/bin/env lua
-- Off-engine test runner for the avorion-omnihub PURE suites.
--
--   lua tests/run.lua          (run from the repo root)
--
-- Loads the same library code the game loads (data/scripts/lib/omnihub/*) with mocked engine
-- globals (see tests/mocks/engine.lua), runs the pure suites, prints a report, and exits
-- non-zero if any test failed — suitable for a pre-commit / CI gate.

local function script_dir()
    local p = (arg and arg[0]) or "tests/run.lua"
    return p:match("^(.*)[/\\][^/\\]+$") or "."
end

local TESTS_DIR = script_dir()
local REPO      = TESTS_DIR .. "/.."

-- Install the include() shim + mock globals.
local setup = dofile(TESTS_DIR .. "/mocks/engine.lua")
setup(REPO)

-- include() is now global; load the registry and run the pure category.
local registry = include("lib/omnihub/tests/registry")
local runner   = registry.run("pure")

print(runner:format())

local summary = runner:summary()
os.exit(summary.failed == 0 and 0 or 1)
