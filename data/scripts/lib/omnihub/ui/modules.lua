package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/lib/omnihub/?.lua"
local OmniHubModuleDefs     = include("moduledefs")
local OmniHubModuleItem     = include("moduleitem")
local OmniHubSupplierStock  = include("supplierstock")  -- tested pageSlice

-- namespace OmniHubUIModules
-- Client-only Modules tab: one paginated row per module TYPE with columns
--   NAME (icon+name+recipe tooltip) | INSTALLED | INVENTORY | [qty][Install][Uninstall].
-- The qty field (default 1) is shared by both buttons. A "show owned only" filter (default on) hides
-- types you neither have installed nor hold. Rows are built client-side by merging the module catalog
-- (names/icons/tooltips) with the per-key counts the server sends, so install/uninstall deltas just
-- patch one row's counts — no rebuild, page preserved. Styled like the Buy/Sell/Goods tables.
OmniHubUIModules = {}
OmniHubUIModules.__index = OmniHubUIModules

local PER_PAGE  = 14
local FONT      = 15
local FILTER_Y  = 4
local HEADER_Y  = 34
local ROWS_TOP  = 62
local ROW_PITCH = 34
local FRAME_H   = 30
local ICON_W    = 29

local function tooltipFor(key)
    local def = OmniHubModuleDefs.get(key)
    if not def then return "" end
    local out = {}
    for _, line in ipairs(OmniHubModuleItem.tooltipLines(def)) do out[#out + 1] = line.text or "" end
    return table.concat(out, "\n")
end

local function hideRow(r)
    r.frame:hide(); r.icon:hide(); r.name:hide(); r.installed:hide(); r.inventory:hide()
    r.qtyBox:hide(); r.installBtn:hide(); r.uninstallBtn:hide()
end
local function showRow(r)
    r.frame:show(); r.icon:show(); r.name:show(); r.installed:show(); r.inventory:show()
    r.qtyBox:show(); r.installBtn:show(); r.uninstallBtn:show()
end

-- new(tab, size, opts) where opts = {
--   filterCallback, installCallback, uninstallCallback, qtyCallback, prevCallback, nextCallback  -- handler NAME strings
-- }
function OmniHubUIModules.new(tab, size, opts)
    local self = setmetatable({}, OmniHubUIModules)
    self.opts     = opts
    self.allRows  = {}     -- every catalog type merged with counts
    self.data     = {}     -- current (filtered) view
    self.page     = 0
    self.filterOwned = true
    self.rows     = {}
    self.installBtnRow   = {}   -- install button.index   -> pool row index
    self.uninstallBtnRow = {}   -- uninstall button.index -> pool row index

    local W = (tab.size and tab.size.x) or (size.x - 30)
    local ICON_X = 10
    local NAME_X = ICON_X + ICON_W + 8
    local UN_W, IN_W, QTY_W = 92, 80, 44
    local UN_X  = W - 8 - UN_W
    local IN_X  = UN_X - IN_W - 6
    local QTY_X = IN_X - QTY_W - 8
    -- Wide enough that the "INSTALLED" / "INVENTORY" headers render at full font 15 (a narrower column
    -- makes the engine shrink the header text to fit).
    local INV_R = QTY_X - 12;  local INV_L = INV_R - 100
    local INS_R = INV_L - 14;  local INS_L = INS_R - 100
    local NAME_RIGHT = INS_L - 12
    local ROW_RIGHT  = W - 2

    -- Filter checkbox (top).
    self.filterCb = tab:createCheckBox(Rect(vec2(ICON_X, FILTER_Y), vec2(ICON_X + 220, FILTER_Y + 24)),
        "Show owned only"%_t, opts.filterCallback)
    self.filterCb:setCheckedNoCallback(true)
    self.filterCb.tooltip = "Show only modules you have installed or hold in inventory. Uncheck to browse every module type."%_t

    -- Column headers.
    tab:createLabel(vec2(NAME_X, HEADER_Y), "NAME"%_t, FONT)
    local function rh(x1, x2, caption, tip)
        local l = tab:createLabel(Rect(x1, HEADER_Y, x2, HEADER_Y + 26), caption, FONT)
        l:setTopRightAligned(); l.tooltip = tip
    end
    rh(INS_L, INS_R, "INSTALLED"%_t, "How many of this module are installed in the hub."%_t)
    rh(INV_L, INV_R, "INVENTORY"%_t, "How many you hold in your inventory."%_t)
    rh(QTY_X - 4, QTY_X + QTY_W, "QTY"%_t, "Amount to install / uninstall (clamped to what's available)."%_t)

    -- Reusable row pool.
    for i = 1, PER_PAGE do
        local top = ROWS_TOP + (i - 1) * ROW_PITCH
        local bot = top + FRAME_H

        local frame = tab:createFrame(Rect(vec2(0, top), vec2(ROW_RIGHT, bot)))

        local iconTop = top + math.floor((FRAME_H - ICON_W) / 2)
        local icon = tab:createPicture(Rect(vec2(ICON_X, iconTop), vec2(ICON_X + ICON_W, iconTop + ICON_W)), "")
        icon.isIcon = true

        local name = tab:createLabel(Rect(vec2(NAME_X, top), vec2(NAME_RIGHT, bot)), "", FONT)
        name:setLeftAligned(); name.shortenText = true

        local installed = tab:createLabel(Rect(vec2(INS_L, top), vec2(INS_R, bot)), "", FONT)
        installed:setRightAligned()
        local inventory = tab:createLabel(Rect(vec2(INV_L, top), vec2(INV_R, bot)), "", FONT)
        inventory:setRightAligned()

        local qtyBox = tab:createTextBox(Rect(vec2(QTY_X, top + 2), vec2(QTY_X + QTY_W, bot - 2)), opts.qtyCallback)
        qtyBox.allowedCharacters = "0123456789"
        qtyBox.text = "1"

        local btnTop = top + math.floor((FRAME_H - 26) / 2)
        local installBtn = tab:createButton(Rect(vec2(IN_X, btnTop), vec2(IN_X + IN_W, btnTop + 26)), "Install"%_t, opts.installCallback)
        installBtn.uppercase = false
        local uninstallBtn = tab:createButton(Rect(vec2(UN_X, btnTop), vec2(UN_X + UN_W, btnTop + 26)), "Uninstall"%_t, opts.uninstallCallback)
        uninstallBtn.uppercase = false

        local row = { frame = frame, icon = icon, name = name, installed = installed, inventory = inventory,
                      qtyBox = qtyBox, installBtn = installBtn, uninstallBtn = uninstallBtn }
        hideRow(row)
        self.rows[i] = row
    end

    -- Pager. Prev and Next are the same width (60), Next right-aligned to the table edge (the
    -- Uninstall column's right edge), matching the Goods tab.
    local py    = ROWS_TOP + PER_PAGE * ROW_PITCH + 6
    local right = UN_X + UN_W
    self.prevBtn   = tab:createButton(Rect(vec2(10, py), vec2(70, py + 26)), "<", opts.prevCallback)
    self.nextBtn   = tab:createButton(Rect(vec2(right - 60, py), vec2(right, py + 26)), ">", opts.nextCallback)
    self.pageLabel = tab:createLabel(Rect(vec2(80, py), vec2(right - 70, py + 26)), "", 14)
    self.pageLabel:setCenterAligned()
    self.prevBtn.uppercase = false
    self.nextBtn.uppercase = false

    return self
end

-- Rebuilds allRows from the catalog + per-key counts, then applies the filter and renders.
function OmniHubUIModules:setCounts(installedCounts, inventoryCounts)
    installedCounts = installedCounts or {}
    inventoryCounts = inventoryCounts or {}
    self.allRows = {}
    self.byKey   = {}                      -- key -> entry, for O(1) patch
    for key, def in pairs(OmniHubModuleDefs.getCatalog()) do
        local d = {
            key = key, name = def.name, icon = def.icon or OmniHubModuleDefs.ICON,
            installed = installedCounts[key] or 0, inventory = inventoryCounts[key] or 0,
        }
        self.allRows[#self.allRows + 1] = d
        self.byKey[key] = d
    end
    table.sort(self.allRows, function(a, b) return a.name < b.name end)
    self:applyFilter()
end

-- Patches one type's counts in place (from an install/uninstall delta) and re-renders. O(1) lookup.
function OmniHubUIModules:patch(key, installed, inventory)
    local d = self.byKey and self.byKey[key]
    if d then d.installed = installed; d.inventory = inventory end
    self:applyFilter()
end

function OmniHubUIModules:setFilter(ownedOnly)
    self.filterOwned = ownedOnly and true or false
    self.page = 0
    self:applyFilter()
end

function OmniHubUIModules:applyFilter()
    if self.filterOwned then
        self.data = {}
        for _, d in ipairs(self.allRows) do
            if (d.installed + d.inventory) > 0 then self.data[#self.data + 1] = d end
        end
    else
        self.data = self.allRows
    end
    self:render()
end

function OmniHubUIModules:nextPage() self.page = self.page + 1; self:render() end
function OmniHubUIModules:prevPage() self.page = self.page - 1; self:render() end

function OmniHubUIModules:render()
    self.installBtnRow   = {}
    self.uninstallBtnRow = {}
    local total = #self.data
    local s, e, page = OmniHubSupplierStock.pageSlice(total, PER_PAGE, self.page)
    self.page = page

    for i = 1, PER_PAGE do
        local row = self.rows[i]
        local idx = s + i - 1
        local d   = (s > 0 and idx <= e) and self.data[idx] or nil
        if d then
            local tip = tooltipFor(d.key)
            row.dataKey        = d.key
            row.icon.picture   = d.icon or ""
            row.icon.tooltip   = tip
            row.name.caption   = d.name or d.key
            row.name.tooltip   = tip
            row.installed.caption = tostring(d.installed)
            row.inventory.caption = tostring(d.inventory)
            row.installBtn.active   = d.inventory > 0
            row.uninstallBtn.active = d.installed > 0
            self.installBtnRow[row.installBtn.index]     = i
            self.uninstallBtnRow[row.uninstallBtn.index] = i
            showRow(row)
        else
            row.dataKey = nil
            hideRow(row)
        end
    end

    local pages = math.max(1, math.ceil(math.max(0, total) / PER_PAGE))
    self.pageLabel.caption = (total == 0) and "(none)"%_t
        or string.format("Page %d / %d (%d)", page + 1, pages, total)
    self.prevBtn.active = page > 0
    self.nextBtn.active = e < total
end

-- Reads the (key, qty) for an Install / Uninstall button press. qty is the row's field, min 1.
local function targetFor(self, map, btn)
    local i   = map[btn.index]
    local row = i and self.rows[i]
    if not (row and row.dataKey) then return end
    local qty = math.max(1, math.floor(tonumber(row.qtyBox.text) or 1))
    return row.dataKey, qty
end
function OmniHubUIModules:installTarget(btn)   return targetFor(self, self.installBtnRow, btn)   end
function OmniHubUIModules:uninstallTarget(btn) return targetFor(self, self.uninstallBtnRow, btn) end

return OmniHubUIModules
