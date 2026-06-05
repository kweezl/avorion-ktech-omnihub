-- EmmyLua stubs: Avorion math and geometry types.
-- Not deployed — IDE type annotations only.

---@class vec2
---@field x number
---@field y number
local _vec2 = {}

---@param x number
---@param y number
---@return vec2
function vec2(x, y) end

---@class vec3
---@field x number
---@field y number
---@field z number
local _vec3 = {}

---@param x number
---@param y number
---@param z number
---@return vec3
function vec3(x, y, z) end

---@class vec4
---@field x number
---@field y number
---@field z number
---@field w number

---@param x number
---@param y number
---@param z number
---@param w number
---@return vec4
function vec4(x, y, z, w) end

---@class ivec3
---@field x integer
---@field y integer
---@field z integer

---@param x integer
---@param y integer
---@param z integer
---@return ivec3
function ivec3(x, y, z) end

---@class quat
---@field x number
---@field y number
---@field z number
---@field w number

---@overload fun(x: number, y: number, z: number, w: number): quat
---@return quat
function quat() end

---@class Transform
---@field pos vec3
---@field right vec3
---@field up vec3
---@field look vec3
Transform = {}

---@class Rect
---@field lower vec2
---@field upper vec2
---@field width number
---@field height number
---@field position vec2
---@field size vec2
local _Rect = {}

---@overload fun(lower: vec2, upper: vec2): Rect
---@overload fun(x: number, y: number, width: number, height: number): Rect
---@return Rect
function Rect() end

---@class ColorRGB
---@field r number 0.0–1.0
---@field g number 0.0–1.0
---@field b number 0.0–1.0

---@param r number 0.0–1.0
---@param g number 0.0–1.0
---@param b number 0.0–1.0
---@return ColorRGB
function ColorRGB(r, g, b) end

---@class Seed
---@param value number
---@return Seed
function Seed(value) end

---@class Random
local _Random = {}

---@param min integer
---@param max integer
---@return integer
function _Random:getInt(min, max) end

---@overload fun(): number
---@param min number
---@param max number
---@return number
function _Random:getFloat(min, max) end

---@param probability number 0.0–1.0
---@return boolean
function _Random:test(probability) end

---@overload fun(seed: Seed): Random
---@return Random
function Random() end

--- Normalize a vector, returning a new vector
---@overload fun(v: vec3): vec3
---@param v vec2
---@return vec2
function normalize(v) end

--- Normalize a vector in-place
---@overload fun(v: vec3)
---@param v vec2
function normalize_ip(v) end

--- Get the magnitude of a vector
---@overload fun(v: vec3): number
---@param v vec2
---@return number
function length(v) end

--- Euclidean distance between two 3D points
---@param v1 vec3
---@param v2 vec3
---@return number
function distance(v1, v2) end