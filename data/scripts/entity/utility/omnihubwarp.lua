package.path = package.path .. ";data/scripts/lib/?.lua"

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHubWarp
-- One-shot helper for the dev-mode /warp command: attached to the craft by commands/warp.lua
-- (which runs without a sector context), it executes the actual transfer from inside the sector VM
-- on its first server tick, then removes itself. transferEntity marks the entity for transfer at
-- the end of the frame; SectorChangeType.Jump places it at the destination's edge with the usual
-- jump effect.
OmniHubWarp = {}

local targetX, targetY

function OmniHubWarp.initialize(x, y)
    if onClient() then
        terminate()
        return
    end
    targetX, targetY = x, y
end

function OmniHubWarp.getUpdateInterval()
    return 0  -- act on the first tick
end

function OmniHubWarp.updateServer(timeStep)
    if targetX and targetY then
        Sector():transferEntity(Entity(), targetX, targetY, SectorChangeType.Jump)
    end
    terminate()
end

return OmniHubWarp
