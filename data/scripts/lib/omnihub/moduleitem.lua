package.path = package.path .. ";data/scripts/lib/?.lua"
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")

-- namespace OmniHubModuleItem
-- Builds the inventory item that represents one OmniHub module. Modules are passive tokens whose
-- only verb is "install via the station Manage tab", so they are VanillaInventoryItems (no script,
-- no activate, no right-click "Use") rather than UsableInventoryItems. Split into a PURE describe /
-- tooltipLines layer (tested off-engine) and a thin engine build() that constructs the real item.
OmniHubModuleItem = {}

local BULLET = "\xE2\x80\xA2"  -- •
local TIMES  = "\xC3\x97"      -- ×

local function bullet(amount, name)
    return "  " .. BULLET .. " " .. amount .. TIMES .. " " .. name%_t
end

-- PURE. Returns the tooltip line descriptors for a module def's production. Each descriptor is
-- { role = "head"|"section"|"item"|"spacer"|"gap", text = string? }; the engine layer maps roles to
-- TooltipLine sizes/colors. Mirrors the legacy item-script tooltip layout.
function OmniHubModuleItem.tooltipLines(def)
    local prod  = def.production
    local lines = {}
    local function add(role, text) lines[#lines + 1] = { role = role, text = text } end

    add("head", def.name)
    add("spacer")

    add("section", "Produces:"%_t)
    for _, res in ipairs(prod.results or {}) do
        add("item", bullet(res.amount, res.name))
    end
    for _, gar in ipairs(prod.garbages or {}) do
        add("item", bullet(gar.amount, gar.name) .. " (byproduct)"%_t)
    end
    add("gap")

    if prod.ingredients and #prod.ingredients > 0 then
        add("section", "Requires:"%_t)
        for _, ing in ipairs(prod.ingredients) do
            local opt = (ing.optional == 1) and " (optional)"%_t or ""
            add("item", bullet(ing.amount, ing.name) .. opt)
        end
        add("gap")
    end

    add("item", "Install from an OmniHub station\xE2\x80\x99s Manage tab."%_t)
    return lines
end

-- PURE. Returns the full item spec for a module key: name/price/icon, custom values, and tooltip
-- line descriptors. An unknown key yields a labelled fallback with no recipe lines so the item never
-- silently vanishes.
function OmniHubModuleItem.describe(key)
    local def = OmniHubModuleDefs.get(key)
    if not def then
        return {
            known  = false,
            name   = "Unknown OmniHub Module"%_t,
            values = { subtype = "OmniHubModule", moduleKey = key or "" },
            lines  = {},
        }
    end

    return {
        known  = true,
        name   = def.name,
        price  = def.price,
        icon   = def.icon,
        values = { subtype = "OmniHubModule", moduleKey = key, category = "factory" },
        lines  = OmniHubModuleItem.tooltipLines(def),
    }
end

-- Maps a line role to (height, fontSize). Spacers carry no text.
local ROLE_SIZE = {
    head    = { 25, 15 },
    section = { 18, 14 },
    item    = { 16, 12 },
    spacer  = { 14, 14 },
    gap     = { 10, 10 },
}

-- ENGINE. Constructs the VanillaInventoryItem for a module key. `rarity` defaults to the single
-- source of truth in moduledefs. Runs in the entity/sector VM, where `goods` is ambient and the
-- full UI/Tooltip API is available.
function OmniHubModuleItem.build(key, rarity)
    rarity = rarity or Rarity(OmniHubModuleDefs.RARITY)
    local spec = OmniHubModuleItem.describe(key)

    local item = VanillaInventoryItem()
    item.stackable = true
    item.tradeable = true
    item.droppable = true
    item.name      = spec.name
    item.rarity    = rarity
    if spec.price then item.price = spec.price end
    if spec.icon  then item.icon  = spec.icon  end
    for k, v in pairs(spec.values) do item:setValue(k, v) end

    if #spec.lines > 0 then
        local tooltip = Tooltip()
        tooltip.icon   = spec.icon or item.icon
        tooltip.rarity = rarity
        for _, line in ipairs(spec.lines) do
            local size = ROLE_SIZE[line.role] or ROLE_SIZE.item
            local tl   = TooltipLine(size[1], size[2])
            if line.role == "head" then
                tl.ctext  = line.text
                tl.ccolor = rarity.tooltipFontColor
            elseif line.text then
                tl.ltext = line.text
            end
            tooltip:addLine(tl)
        end
        item:setTooltip(tooltip)
    end

    return item
end

return OmniHubModuleItem
