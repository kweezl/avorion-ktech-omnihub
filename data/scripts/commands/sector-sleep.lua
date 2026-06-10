-- /sector-sleep <x> <y> — DEV-MODE-ONLY: ask the engine to unload a loaded sector (puts it "to
-- sleep" so e.g. the OmniHub offline director takes over). No-op when the sector is already
-- unloaded. The engine refuses while something pins the sector — a player inside / within the
-- alive-sectors radius, or a script holding it — so jump away first (/warp).
function execute(sender, commandName, x, y)
    if not GameSettings().devMode then
        return 1, "", "/sector-sleep is available only with dev mode enabled."
    end

    x, y = tonumber(x), tonumber(y)
    if not x or not y then
        return 1, "", "Usage: /sector-sleep <x> <y>"
    end
    x, y = math.floor(x), math.floor(y)

    if not Galaxy():sectorLoaded(x, y) then
        return 0, "", string.format("Sector (%d:%d) is already offline.", x, y)
    end

    local player = Player(sender)
    if player then
        local px, py = player:getSectorCoordinates()
        if px == x and py == y then
            return 1, "", "You are inside that sector — it can't unload while you pin it. Leave first (/warp)."
        end
    end

    Galaxy():tryUnloadSector(x, y)
    return 0, "", string.format(
        "Unload of (%d:%d) requested. NOTE: each player's recently visited sectors stay alive "
        .. "(server setting aliveSectorsPerPlayer, default 5) — visit other sectors to push this one "
        .. "off your list. Re-run this command to probe: 'already offline' = it worked.", x, y)
end

function getDescription()
    return "Dev-mode only: request unloading of a sector (offline simulation takes over)."
end

function getHelp()
    return "Dev-mode only. Asks the engine to unload a loaded sector. Usage: /sector-sleep <x> <y>"
end
