package.path = package.path .. ";data/scripts/lib/?.lua"

-- /warp <x> <y> — DEV-MODE-ONLY instant sector teleport for the caller's current craft.
-- Command scripts run server-side without a sector context (Sector() doesn't resolve here), so the
-- actual transfer is delegated to a one-shot entity script (utility/omnihubwarp.lua) attached to
-- the craft: it runs in the sector VM and calls Sector():transferEntity on its first tick.
function execute(sender, commandName, x, y)
    if not GameSettings().devMode then
        return 1, "", "/warp is available only with dev mode enabled."
    end

    local player = Player(sender)
    if not player then
        return 1, "", "Player not found."
    end

    local craft = player.craft
    if not craft then
        return 1, "", "You're not in a ship!"
    end

    x, y = tonumber(x), tonumber(y)
    if not x or not y then
        return 1, "", "Usage: /warp <x> <y>"
    end
    x, y = math.floor(x), math.floor(y)
    if math.abs(x) > 499 or math.abs(y) > 499 then
        return 1, "", "Coordinates out of galaxy bounds (-499..499)."
    end

    craft:addScriptOnce("data/scripts/entity/utility/omnihubwarp.lua", x, y)
    return 0, "", string.format("Warping to (%d:%d)...", x, y)
end

function getDescription()
    return "Dev-mode only: instantly warp your craft to a sector."
end

function getHelp()
    return "Dev-mode only. Warps your current craft to the given sector coordinates. Usage: /warp <x> <y>"
end
