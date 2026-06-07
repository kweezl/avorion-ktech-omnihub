package.path = package.path .. ";data/scripts/lib/?.lua"

-- namespace OmniHubStorage
-- Pure storage-readout math for the Statistics tab: turns per-good {current, size, limit} units
-- into cargo VOLUMES and totals, so the player can see how much hold the hub's reservations want vs
-- how much it's actually using, and whether the cargo bay is big enough. Engine reads (current stock,
-- good size, cargo capacity) are gathered by the controller and passed in; this module is pure.
OmniHubStorage = {}

-- rows: array of { name = string, current = units, size = volumePerUnit, limit = units }.
-- capacity: total cargo space of the hub (Entity().maxCargoSpace).
-- Returns:
--   { goods = { { name, current, currentVol, limit, limitVol }, ... } sorted by name,
--     totalCurrentVol, totalLimitVol, capacity,
--     over = totalLimitVol > capacity }   -- cargo too small to hold every reservation
function OmniHubStorage.summarize(rows, capacity)
    capacity = capacity or 0
    local goods = {}
    local totalCur, totalRes = 0, 0

    for _, r in ipairs(rows or {}) do
        local size   = r.size or 1
        local cur    = r.current or 0
        local res    = r.limit or 0
        local curVol = cur * size
        local resVol = res * size
        totalCur = totalCur + curVol
        totalRes = totalRes + resVol
        goods[#goods + 1] = {
            name       = r.name,
            current    = cur,
            currentVol = curVol,
            limit   = res,
            limitVol = resVol,
        }
    end

    table.sort(goods, function(a, b) return a.name < b.name end)

    return {
        goods            = goods,
        totalCurrentVol  = totalCur,
        totalLimitVol = totalRes,
        capacity         = capacity,
        over             = totalRes > capacity,
    }
end

return OmniHubStorage
