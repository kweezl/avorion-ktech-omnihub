package.path = package.path .. ";data/scripts/lib/?.lua"

local OmniHubTest = include("lib/omnihub/tests/framework")
local OmniHubLog  = include("lib/omnihub/log")

local eq  = OmniHubTest.assertEqual
local nilq = OmniHubTest.assertNil

return function(runner)
    runner:suite("log")

    runner:test("format passes a bare string through", function()
        eq(OmniHubLog.format("hello"), "hello")
    end)

    runner:test("format applies string.format args", function()
        eq(OmniHubLog.format("n=%d", 5), "n=5")
    end)

    runner:test("debug returns nil when gated off (no output)", function()
        nilq(OmniHubLog.debug(false, "should not log"))
    end)

    runner:test("debug returns the prefixed message when enabled", function()
        eq(OmniHubLog.debug(true, "hello"), "[OmniHub] hello")
    end)

    runner:test("debug formats args when enabled", function()
        eq(OmniHubLog.debug(true, "seller %s x%d", "Steel", 3), "[OmniHub] seller Steel x3")
    end)
end
