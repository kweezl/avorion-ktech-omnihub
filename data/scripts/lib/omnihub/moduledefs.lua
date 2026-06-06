package.path = package.path .. ";data/scripts/lib/?.lua"
include("productions")  -- sets productionsByGood, getFactoryCost, getTranslatedFactoryName
-- buildCatalog -> getTranslatedFactoryName -> productions.lua:formatFactoryName indexes the
-- global `goods` table. Entity/sector VMs have it loaded ambiently, but the restricted item-script
-- VM (UsableInventoryItem) does not, so include it explicitly when absent. See serverlog 2026-06-05.
if not goods then include("goods") end

-- namespace OmniHubModuleDefs
OmniHubModuleDefs = {}

-- Rarity of every OmniHub module item — single source of truth for all construction sites
-- (onDestroyed drops, uninstall, supplier stock, and the item create() fallback). Exotic so the
-- loot reads as valuable; Common drops were routinely ignored by players.
OmniHubModuleDefs.RARITY = RarityType.Exotic

local catalog = nil  -- lazy-built on first call

-- Builds a stable key from goodName + productionIndex.
-- Keys must survive save/reload, so they are deterministic strings.
local function makeKey(goodName, idx)
    return goodName .. "|" .. tostring(idx)
end

local function buildCatalog()
    local result = {}
    local seen = {}  -- deduplicate by production table identity

    -- Iterate goods in SORTED order. A production that yields multiple goods appears under each of
    -- them in productionsByGood; the seen[] dedup keeps it under the FIRST good visited. pairs()
    -- order is arbitrary and DIFFERS across script VMs (entity vs item vs client), which made the
    -- same production get different keys in different VMs — so a key chosen by addItems (server
    -- entity VM) could resolve to a different production, or to nothing, in the item/client VMs,
    -- producing wrong names/icons/tooltips and "Unknown" items. Sorting makes the key deterministic.
    local goodNames = {}
    for goodName in pairs(productionsByGood) do goodNames[#goodNames + 1] = goodName end
    table.sort(goodNames)

    for _, goodName in ipairs(goodNames) do
        local prods = productionsByGood[goodName]
        for idx, prod in ipairs(prods) do
            if not prod.mine and not seen[prod] then
                seen[prod] = true
                local key = makeKey(goodName, idx)
                -- Tech level + icon come from the factory's PRIMARY result good. Tech level = the
                -- good's `level` (0..9), matching how the station founder tiers factories (Basic = 0,
                -- Low = 1-3, Advanced = 4-6, High = 7-9; see stationfounder.lua). The icon is the
                -- produced good's icon so each module is recognizable; fall back to the mod icon.
                local primaryResult = prod.results and prod.results[1]
                local primaryGood   = primaryResult and goods[primaryResult.name]
                local techLevel     = primaryGood and primaryGood.level or nil
                local icon          = (primaryGood and primaryGood.icon) or "data/textures/omnihub.png"
                result[key] = {
                    key             = key,
                    goodName        = goodName,
                    productionIndex = idx,
                    production      = prod,
                    name            = getTranslatedFactoryName(prod),
                    price           = getFactoryCost(prod),
                    techLevel       = techLevel,
                    icon            = icon,
                }
            end
        end
    end

    return result
end

-- Returns the full module catalog (lazy-initialized).
-- Keys are stable strings; values are module definition tables.
function OmniHubModuleDefs.getCatalog()
    if not catalog then
        catalog = buildCatalog()
    end
    return catalog
end

-- Returns the definition for one module key, or nil.
function OmniHubModuleDefs.get(key)
    return OmniHubModuleDefs.getCatalog()[key]
end

-- Returns the raw production table for a key (from productionsByGood).
function OmniHubModuleDefs.resolveRecipe(key)
    local def = OmniHubModuleDefs.get(key)
    if not def then return nil end
    return productionsByGood[def.goodName][def.productionIndex]
end

-- Returns an array of {key, name, price} sorted by name, for UI display.
function OmniHubModuleDefs.getSortedList()
    local list = {}
    for _, def in pairs(OmniHubModuleDefs.getCatalog()) do
        list[#list + 1] = { key=def.key, name=def.name, price=def.price }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

return OmniHubModuleDefs
