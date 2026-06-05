-- EmmyLua stubs: Avorion UI element types and layout helpers.
-- Not deployed — IDE type annotations only.

-- ─── Base / shared ────────────────────────────────────────────────────────────

---@class UIElement
---@field visible boolean
---@field tooltip string
local _UIElement = {}

function _UIElement:show() end
function _UIElement:hide() end

-- ─── Widgets ──────────────────────────────────────────────────────────────────

---@class Label : UIElement
---@field caption string
---@field color ColorRGB
---@field font integer FontType value
---@field italic boolean
local _Label = {}

function _Label:setLeftAligned() end
function _Label:setRightAligned() end
function _Label:setCenterAligned() end

---@class Button : UIElement
---@field icon string Texture path for the button icon
---@field active boolean
local _Button = {}

---@class CheckBox : UIElement
---@field checked boolean
local _CheckBox = {}

--- Set checked state without triggering the registered callback
---@param checked boolean
function _CheckBox:setCheckedNoCallback(checked) end

---@class Slider : UIElement
---@field value number
---@field unit string Label appended to the numeric display
local _Slider = {}

--- Set value without triggering the registered callback
---@param value number
function _Slider:setValueNoCallback(value) end

---@class Frame : UIElement
local _Frame = {}

---@class Picture : UIElement
local _Picture = {}

---@class ComboBox : UIElement
---@field selectedValue any
---@field selectedIndex integer
local _ComboBox = {}

---@param value any
---@param text string
function _ComboBox:addEntry(value, text) end

function _ComboBox:clear() end

--- Select by value without triggering the registered callback
---@param value any
function _ComboBox:setSelectedValueNoCallback(value) end

--- Select by index without triggering the registered callback
---@param index integer
function _ComboBox:setSelectedIndexNoCallback(index) end

-- ─── Containers ───────────────────────────────────────────────────────────────

---@class Tab : UIElement
local _Tab = {}

---@param rect Rect
---@param text string
---@param fontSize number
---@return Label
function _Tab:createLabel(rect, text, fontSize) end

---@param rect Rect
---@param text string
---@param callbackFunc string Function name called on click
---@return Button
function _Tab:createButton(rect, text, callbackFunc) end

---@param rect Rect
---@param text string
---@param callbackFunc string Function name called on toggle
---@return CheckBox
function _Tab:createCheckBox(rect, text, callbackFunc) end

---@param rect Rect
---@param min number
---@param max number
---@param numSteps integer
---@param label string
---@param callbackFunc string Function name called on change
---@return Slider
function _Tab:createSlider(rect, min, max, numSteps, label, callbackFunc) end

---@param rect Rect
---@return Frame
function _Tab:createFrame(rect) end

---@param rect Rect
---@param texturePath string
---@return Picture
function _Tab:createPicture(rect, texturePath) end

---@param rect Rect
---@param callbackFunc string Function name called on selection change
---@return ComboBox
function _Tab:createValueComboBox(rect, callbackFunc) end

---@class Window : UIElement
local _Window = {}

---@class TabbedWindow : UIElement
local _TabbedWindow = {}

---@param name string
---@param iconPath string
---@param tooltip string
---@return Tab
function _TabbedWindow:createTab(name, iconPath, tooltip) end

---@return Tab
function _TabbedWindow:getActiveTab() end

---@param tab Tab
function _TabbedWindow:activateTab(tab) end

---@param tab Tab
function _TabbedWindow:deactivateTab(tab) end

-- ─── Layout helpers ───────────────────────────────────────────────────────────

---@class UIHorizontalSplitter
---@field top Rect Upper partition
---@field bottom Rect Lower partition
local _UIHorizontalSplitter = {}

---@param left number
---@param top number
---@param right number
---@param bottom number
function _UIHorizontalSplitter:setPadding(left, top, right, bottom) end

function _UIHorizontalSplitter:setLeftQuadratic() end
function _UIHorizontalSplitter:setRightQuadratic() end

---@param rect Rect
---@param paddingLeft number
---@param paddingRight number
---@param splitRatio number 0.0–1.0 (top fraction)
---@return UIHorizontalSplitter
function UIHorizontalSplitter(rect, paddingLeft, paddingRight, splitRatio) end

---@class UIVerticalSplitter
---@field left Rect
---@field right Rect
---@field leftSize number Override: fix the left panel to this pixel width
---@field rightSize number Override: fix the right panel to this pixel width
local _UIVerticalSplitter = {}

---@param left number
---@param top number
---@param right number
---@param bottom number
function _UIVerticalSplitter:setPadding(left, top, right, bottom) end

function _UIVerticalSplitter:setLeftQuadratic() end
function _UIVerticalSplitter:setRightQuadratic() end

---@param rect Rect
---@param paddingLeft number
---@param paddingRight number
---@param splitRatio number 0.0–1.0 (left fraction)
---@return UIVerticalSplitter
function UIVerticalSplitter(rect, paddingLeft, paddingRight, splitRatio) end

---@class UIVerticalMultiSplitter
local _UIVerticalMultiSplitter = {}

---@param index integer 0-based partition index
---@return Rect
function _UIVerticalMultiSplitter:partition(index) end

---@param rect Rect
---@param marginX number Outer horizontal margin
---@param paddingX number Gap between partitions
---@param numPartitions integer
---@return UIVerticalMultiSplitter
function UIVerticalMultiSplitter(rect, marginX, paddingX, numPartitions) end

---@class UIHorizontalMultiSplitter
local _UIHorizontalMultiSplitter = {}

---@param index integer 0-based partition index
---@return Rect
function _UIHorizontalMultiSplitter:partition(index) end

---@param rect Rect
---@param marginY number Outer vertical margin
---@param paddingY number Gap between partitions
---@param numPartitions integer
---@return UIHorizontalMultiSplitter
function UIHorizontalMultiSplitter(rect, marginY, paddingY, numPartitions) end

---@class UIVerticalLister
local _UIVerticalLister = {}

--- Allocate the next rectangle of the given height and advance the internal cursor
---@param height number
---@return Rect
function _UIVerticalLister:nextRect(height) end

---@param element UIElement
function _UIVerticalLister:placeElementTop(element) end

---@param rect Rect
---@param spacing number Vertical gap between rows
---@param margin number Outer margin
---@return UIVerticalLister
function UIVerticalLister(rect, spacing, margin) end