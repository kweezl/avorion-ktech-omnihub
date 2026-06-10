-- /sector-wakeup <x> <y> — DEV-MODE-ONLY: load an unloaded sector into memory (wakes it up; a
-- sleeping OmniHub there will reconcile with the offline director and resume live simulation).
-- No-op when the sector is already active. Loading is asynchronous (may take a few seconds) and
-- the engine keeps the sector alive for ~15 seconds minimum afterwards.
function execute(sender, commandName, x, y)
    if not GameSettings().devMode then
        return 1, "", "/sector-wakeup is available only with dev mode enabled."
    end

    x, y = tonumber(x), tonumber(y)
    if not x or not y then
        return 1, "", "Usage: /sector-wakeup <x> <y>"
    end
    x, y = math.floor(x), math.floor(y)

    if Galaxy():sectorLoaded(x, y) then
        return 0, "", string.format("Sector (%d:%d) is already active.", x, y)
    end

    Galaxy():loadSector(x, y)
    return 0, "", string.format(
        "Loading sector (%d:%d) — may take a few seconds; it stays alive ~15s unless something keeps it.", x, y)
end

function getDescription()
    return "Dev-mode only: load an unloaded sector into memory."
end

function getHelp()
    return "Dev-mode only. Loads an unloaded sector (generates it if it never existed). Usage: /sector-wakeup <x> <y>"
end
