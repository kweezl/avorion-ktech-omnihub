package.path = package.path .. ";data/scripts/lib/?.lua"
-- Item-script VMs (UsableInventoryItem) do NOT get the default "data/scripts/?.lua" path
-- entry that entity/sector VMs have, so the "lib/omnihub/..." include style fails to resolve
-- (it would look under data/scripts/lib/lib/...). Add it explicitly. See serverlog 2026-06-05.
package.path = package.path .. ";data/scripts/?.lua"
include("utility")
local OmniHubModuleDefs = include("lib/omnihub/moduledefs")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace OmniHubModule
OmniHubModule = {}

-- Called by the engine when constructing: UsableInventoryItem("data/scripts/items/omnihubmodule.lua", rarity, key)
-- item  — the UsableInventoryItem being created (mutable)
-- rarity — Rarity object passed at construction time
-- key    — the module catalog key (string)
function OmniHubModule.create(item, rarity, key)
    local def = OmniHubModuleDefs.get(key)
    if not def then
        -- Unknown key — still produce an item so it doesn't silently vanish
        item.name = "Unknown OmniHub Module"
        item:setValue("subtype", "OmniHubModule")
        item:setValue("moduleKey", key or "")
        return item
    end

    local prod = def.production
    rarity = rarity or Rarity(RarityType.Common)

    item.stackable      = true
    item.depleteOnUse   = false
    item.tradeable      = true
    item.droppable      = true
    item.name           = def.name
    item.price          = def.price
    item.icon           = def.icon
    item.rarity         = rarity

    item:setValue("subtype",   "OmniHubModule")
    item:setValue("moduleKey", key)
    item:setValue("category",  "factory")

    -- Build tooltip
    local tooltip = Tooltip()
    tooltip.icon   = item.icon
    tooltip.rarity = rarity

    local headLine = TooltipLine(25, 15)
    headLine.ctext  = def.name
    headLine.ccolor = rarity.tooltipFontColor
    tooltip:addLine(headLine)

    tooltip:addLine(TooltipLine(14, 14))  -- spacer

    local producesLine = TooltipLine(18, 14)
    producesLine.ltext = "Produces:"%_t
    tooltip:addLine(producesLine)
    for _, res in pairs(prod.results) do
        local l = TooltipLine(16, 12)
        l.ltext = "  \xE2\x80\xA2 " .. res.amount .. "\xC3\x97 " .. res.name%_t
        tooltip:addLine(l)
    end
    if prod.garbages then
        for _, gar in pairs(prod.garbages) do
            local l = TooltipLine(16, 12)
            l.ltext = "  \xE2\x80\xA2 " .. gar.amount .. "\xC3\x97 " .. gar.name%_t .. " (byproduct)"%_t
            tooltip:addLine(l)
        end
    end

    tooltip:addLine(TooltipLine(10, 10))  -- spacer

    if prod.ingredients and #prod.ingredients > 0 then
        local reqLine = TooltipLine(18, 14)
        reqLine.ltext = "Requires:"%_t
        tooltip:addLine(reqLine)
        for _, ing in pairs(prod.ingredients) do
            local opt = (ing.optional == 1) and " (optional)"%_t or ""
            local l = TooltipLine(16, 12)
            l.ltext = "  \xE2\x80\xA2 " .. ing.amount .. "\xC3\x97 " .. ing.name%_t .. opt
            tooltip:addLine(l)
        end
        tooltip:addLine(TooltipLine(10, 10))
    end

    local hintLine = TooltipLine(16, 12)
    hintLine.ltext = "Install from an OmniHub station\xE2\x80\x99s Manage tab."%_t
    tooltip:addLine(hintLine)

    item:setTooltip(tooltip)
    return item
end

-- Called when player double-clicks the item. We don't activate on use — install is UI-driven.
function OmniHubModule.activate(item)
    if onClient() then
        Player():sendChatMessage(
            "OmniHub"%_t,
            ChatMessageType.Information,
            "Approach an OmniHub station and use its Manage tab to install this module."%_t
        )
    end
    return false  -- do not consume
end

return OmniHubModule
