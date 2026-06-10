package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubLog
-- Gate-agnostic debug logger shared by the hub controller and (later) the offline director. The CALLER
-- owns the enable check (the hub passes its hubDebug flag; the director passes its own debugEnabled) —
-- this module only formats and emits, so independent gates share one logger with no duplication.
-- Pure/testable: format() has no side effects; debug() returns the exact string it logged (or nil when
-- gated off) so tests assert behaviour without capturing stdout.
OmniHubLog = {}

OmniHubLog.PREFIX = "[OmniHub]"

-- Builds the message body. With no varargs the format string is returned verbatim (so a literal
-- message containing a stray % never reaches string.format and throws).
function OmniHubLog.format(fmt, ...)
    if select("#", ...) > 0 then
        return string.format(fmt, ...)
    end
    return fmt
end

-- Logs "<PREFIX> <message>" via print when `enabled` is truthy; returns the logged string, or nil when
-- gated off. The caller's gate (e.g. hubDebug AND GameSettings().devMode) decides `enabled`.
function OmniHubLog.debug(enabled, fmt, ...)
    if not enabled then return nil end
    local msg = OmniHubLog.PREFIX .. " " .. OmniHubLog.format(fmt, ...)
    print(msg)
    return msg
end

return OmniHubLog
