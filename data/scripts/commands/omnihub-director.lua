-- /omnihub-director [stats | debug on|off] — DEV-MODE-ONLY console access to the offline
-- director (the windowed dev UI from the design doc is still pending; this is the seam for it).
-- Commands run server-side, so the galaxy script is reachable directly via Galaxy():invokeFunction.
function execute(sender, commandName, sub, arg)
    if not GameSettings().devMode then
        return 1, "", "/omnihub-director is available only with dev mode enabled."
    end

    local DIRECTOR = "data/scripts/galaxy/omnihubdirector.lua"
    sub = sub or "stats"

    if sub == "stats" then
        local err, s = Galaxy():invokeFunction(DIRECTOR, "getStats")
        if err ~= 0 or not s then
            return 1, "", "Director not reachable — has any OmniHub initialized since this server started?"
        end
        return 0, "", string.format(
            "OmniHub director: %d hub(s) registered — %d awake, %d asleep. Uptime clock: %ds.",
            s.total, s.awake, s.asleep, math.floor(s.clock or 0))
    end

    if sub == "debug" then
        local enabled = (arg == "on" or arg == "true" or arg == "1")
        local err = Galaxy():invokeFunction(DIRECTOR, "setDebug", enabled)
        if err ~= 0 then
            return 1, "", "Director not reachable — has any OmniHub initialized since this server started?"
        end
        return 0, "", "Director debug logging " .. (enabled and "ENABLED — watch the server log."
                                                            or "disabled.")
    end

    if sub == "simulate" then
        local seconds = tonumber(arg) or 300
        local err, r = Galaxy():invokeFunction(DIRECTOR, "debugSimulate", seconds)
        if err ~= 0 or not r then
            return 1, "", "Director not reachable — has any OmniHub initialized since this server started?"
        end
        return 0, "", string.format(
            "Simulated +%ds offline on %d hub(s): %d wave(s), %d trade(s), paid %d, received %d. "
            .. "(Awake hubs re-snapshot on their next heartbeat — money movement is real, dev use only.)",
            r.seconds, r.hubs, r.waves, r.trades, math.floor(r.paid), math.floor(r.received))
    end

    return 1, "", "Usage: /omnihub-director [stats | debug on|off | simulate <seconds>]"
end

function getDescription()
    return "Dev-mode only: OmniHub offline-director stats and debug toggle."
end

function getHelp()
    return "Dev-mode only. /omnihub-director stats shows the registry; debug on|off toggles server-log tracing; simulate <seconds> force-runs the offline sim on all registered hubs (no unload needed)."
end
