package.path = package.path .. ";data/scripts/lib/?.lua"
include("productions")  -- sets productionsByGood, getFactoryCost, getTranslatedFactoryName
-- buildCatalog -> getTranslatedFactoryName -> productions.lua:formatFactoryName indexes the
-- global `goods` table. Entity/sector VMs have it loaded ambiently, but the restricted item-script
-- VM (UsableInventoryItem) does not, so include it explicitly when absent. See serverlog 2026-06-05.
if not goods then include("goods") end

-- namespace OmniHubModuleDefs
OmniHubModuleDefs = {}

local catalog = nil  -- lazy-built on first call

-- Builds a stable key from goodName + productionIndex.
-- Keys must survive save/reload, so they are deterministic strings.
local function makeKey(goodName, idx)
    return goodName .. "|" .. tostring(idx)
end

local function buildCatalog()
    local result = {}
    local seen = {}  -- deduplicate by production table identity

    for goodName, prods in pairs(productionsByGood) do
        for idx, prod in ipairs(prods) do
            if not prod.mine and not seen[prod] then
                seen[prod] = true
                local key = makeKey(goodName, idx)
                result[key] = {
                    key             = key,
                    goodName        = goodName,
                    productionIndex = idx,
                    production      = prod,
                    name            = getTranslatedFactoryName(prod),
                    price           = getFactoryCost(prod),
                    icon            = "data/textures/icons/factory.png",
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
