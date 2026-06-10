package.path = package.path .. ";data/scripts/?.lua"
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
include("callable")
local OmniHubModuleDefs = include("moduledefs")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHubTests
-- A self-contained, DEV-MODE-ONLY interaction option ("OmniHub Tests") attached to the OmniHub
-- station alongside the controller. It exposes a dedicated window with the pure/integration test
-- runner — kept out of the main trade window so players never see it. Both the interaction option
-- and the server-side runTests RPC are gated on GameSettings().devMode.
OmniHubTests = {}

-- Only offer this interaction in dev mode (checked client-side when the menu is built).
function OmniHubTests.interactionPossible(playerIndex, option)
    return GameSettings().devMode
end

function OmniHubTests.getIcon()
    return OmniHubModuleDefs.ICON
end

-- ────────────────────────────────────────────────────────────────
-- Server: run a category against the live station
-- ────────────────────────────────────────────────────────────────
function OmniHubTests.runTests(category)
    if not onServer() then return end
    if not GameSettings().devMode then return end

    category = category or "all"

    -- Each namespace runs in its own Lua VM: this VM has no _G.OmniHub and holds a different copy
    -- of every included lib, so suites that touch the live station (or monkey-patch the spawners)
    -- MUST execute in the controller's VM. invokeFunction crosses VMs server-side and returns
    -- plain tables; this script only renders the result.
    local err, summary = Entity():invokeFunction(
        "data/scripts/entity/merchants/omnihubcontroller.lua", "runDevTests", category)

    local player = Player(callingPlayer)
    if err ~= 0 or not summary then
        print("[OmniHub] tests: could not reach the controller (invokeFunction code "
            .. tostring(err) .. ")")
        if player then
            player:sendChatMessage("OmniHub"%_t, ChatMessageType.Error,
                "Tests could not run: controller not reachable (code %1%)."%_t, err)
        end
        return
    end

    print("[OmniHub] tests (" .. category .. "): "
        .. summary.passed .. " passed, " .. summary.failed .. " failed of " .. summary.total)

    if player then
        local msgType = (summary.failed == 0) and ChatMessageType.Information or ChatMessageType.Error
        player:sendChatMessage("OmniHub"%_t, msgType,
            "Tests (%1%): %2% passed, %3% failed"%_t, category, summary.passed, summary.failed)
        invokeClientFunction(player, "receiveTestResults", summary.results, category)
    end
end
callable(OmniHubTests, "runTests")

-- ────────────────────────────────────────────────────────────────
-- Client: dedicated test window
-- ────────────────────────────────────────────────────────────────
local window      = nil
local resultFrame = nil
local rows        = {}
OmniHubTests.lastResults = {}

function OmniHubTests.initUI()
    local res  = getResolution()
    local size = vec2(700, 550)

    local menu = ScriptUI()
    window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    window.caption         = "OmniHub Tests"%_t
    window.showCloseButton = 1
    window.moveable        = 1
    menu:registerWindow(window, "OmniHub Tests"%_t)

    local padding = 10
    local inner   = vec2(size.x - 20, size.y - 40)

    local btnH = 30
    local btnW = math.floor((inner.x - padding * 2) / 3)
    local defs = {
        { caption = "Run All"%_t,         func = "onRunAllTestsPress" },
        { caption = "Run Pure"%_t,        func = "onRunPureTestsPress" },
        { caption = "Run Integration"%_t, func = "onRunIntegrationTestsPress" },
    }
    for i, d in ipairs(defs) do
        local x   = padding + (i - 1) * btnW
        local btn = window:createButton(Rect(vec2(x, padding), vec2(x + btnW, padding + btnH)), d.caption, d.func)
        btn.uppercase = false
    end

    local top = padding + btnH + padding
    resultFrame = window:createScrollFrame(Rect(vec2(padding, top), vec2(inner.x, inner.y)))
    resultFrame.scrollSpeed = 30
end

function OmniHubTests.onShowWindow()
end

function OmniHubTests.onCloseWindow()
end

function OmniHubTests.onRunAllTestsPress(button)         invokeServerFunction("runTests", "all") end
function OmniHubTests.onRunPureTestsPress(button)        invokeServerFunction("runTests", "pure") end
function OmniHubTests.onRunIntegrationTestsPress(button) invokeServerFunction("runTests", "integration") end

function OmniHubTests.receiveTestResults(results, category)
    OmniHubTests.lastResults = results or {}
    OmniHubTests.refreshUI()
end

function OmniHubTests.refreshUI()
    if not resultFrame then return end

    for _, row in ipairs(rows) do
        if row.label then row.label:hide() end
    end
    rows = {}

    local rowH  = 22
    local pad   = 4
    local width = resultFrame.size.x - pad * 2
    local list  = OmniHubTests.lastResults or {}
    local passed, failed = 0, 0

    for i, r in ipairs(list) do
        local y      = pad + (i - 1) * (rowH + 2)
        local status = r.ok and "PASS" or "FAIL"
        local text   = status .. "  " .. (r.suite or "") .. " :: " .. (r.name or "")
        if not r.ok and r.err then text = text .. "  - " .. r.err end

        local label = resultFrame:createLabel(vec2(pad, y), text, 12)
        label.size  = vec2(width, rowH)
        label:setLeftAligned()
        if r.ok then
            label.color = ColorRGB(0.5, 1.0, 0.5); passed = passed + 1
        else
            label.color = ColorRGB(1.0, 0.5, 0.5); failed = failed + 1
        end
        rows[#rows + 1] = { label = label }
    end

    local y        = pad + #list * (rowH + 2)
    local sumText  = passed .. " passed, " .. failed .. " failed, " .. #list .. " total"
    local sumLabel = resultFrame:createLabel(vec2(pad, y), sumText, 13)
    sumLabel.size  = vec2(width, rowH)
    sumLabel:setLeftAligned()
    sumLabel.bold = true
    rows[#rows + 1] = { label = sumLabel }
end

return OmniHubTests
