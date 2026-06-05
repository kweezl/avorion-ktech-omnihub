package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubTest
-- Tiny pure-Lua test framework — no engine dependencies. Loads identically off-engine
-- (tests/run.lua) and in-game (the OmniHub dev-mode Tests tab).
OmniHubTest = {}

-- ── Assertions ───────────────────────────────────────────────────────────────
-- Each raises a Lua error with a descriptive message on failure; the runner traps it via pcall.

local function fail(msg)
    error(msg, 2)
end

local function tostr(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function OmniHubTest.assertTrue(value, msg)
    if not value then
        fail((msg or "assertTrue failed") .. " (got " .. tostr(value) .. ")")
    end
end

function OmniHubTest.assertFalse(value, msg)
    if value then
        fail((msg or "assertFalse failed") .. " (got " .. tostr(value) .. ")")
    end
end

function OmniHubTest.assertEqual(actual, expected, msg)
    if actual ~= expected then
        fail((msg or "assertEqual failed") ..
            ": expected " .. tostr(expected) .. ", got " .. tostr(actual))
    end
end

function OmniHubTest.assertNil(value, msg)
    if value ~= nil then
        fail((msg or "assertNil failed") .. " (got " .. tostr(value) .. ")")
    end
end

function OmniHubTest.assertNotNil(value, msg)
    if value == nil then
        fail(msg or "assertNotNil failed (got nil)")
    end
end

function OmniHubTest.assertNear(actual, expected, eps, msg)
    eps = eps or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > eps then
        fail((msg or "assertNear failed") ..
            ": expected " .. tostr(expected) .. " +/- " .. tostr(eps) .. ", got " .. tostr(actual))
    end
end

-- Asserts that calling fn raises an error.
function OmniHubTest.assertError(fn, msg)
    local ok = pcall(fn)
    if ok then
        fail(msg or "assertError failed: expected an error but none was raised")
    end
end

-- ── Runner ───────────────────────────────────────────────────────────────────

local Runner = {}
Runner.__index = Runner

-- Sets the suite name applied to subsequently registered tests.
function Runner:suite(name)
    self.currentSuite = name
end

-- Registers and immediately runs one test. `fn` uses the OmniHubTest.assert* helpers.
function Runner:test(name, fn)
    local ok, err = pcall(fn)
    self.results[#self.results + 1] = {
        suite = self.currentSuite or "(default)",
        name  = name,
        ok    = ok,
        err   = ok and nil or tostring(err),
    }
end

-- Aggregated counts + the list of failures.
function Runner:summary()
    local passed, failed, failures = 0, 0, {}
    for _, r in ipairs(self.results) do
        if r.ok then
            passed = passed + 1
        else
            failed = failed + 1
            failures[#failures + 1] = r
        end
    end
    return {
        total    = #self.results,
        passed   = passed,
        failed   = failed,
        failures = failures,
        results  = self.results,
    }
end

-- Human-readable multi-line report for chat / server log / off-engine stdout.
function Runner:format()
    local s   = self:summary()
    local out = {}
    for _, r in ipairs(self.results) do
        out[#out + 1] = string.format("[%s] %s :: %s%s",
            r.ok and "PASS" or "FAIL", r.suite, r.name,
            r.ok and "" or ("\n        " .. (r.err or "")))
    end
    out[#out + 1] = string.format("---- %d passed, %d failed, %d total ----",
        s.passed, s.failed, s.total)
    return table.concat(out, "\n")
end

function OmniHubTest.newRunner()
    return setmetatable({ results = {}, currentSuite = nil }, Runner)
end

return OmniHubTest
