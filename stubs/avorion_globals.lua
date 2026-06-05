-- EmmyLua stubs: Avorion engine-injected global functions and variables.
-- Not deployed — IDE type annotations only.

--- Load a Lua library from data/scripts/lib/ (like require but uses Avorion search paths)
---@param path string
---@return any
function include(path) end

--- Returns true when executing on the server
---@return boolean
function onServer() end

--- Returns true when executing on the client
---@return boolean
function onClient() end

--- Returns the path of the currently executing script file
---@return string
function getScriptPath() end

--- Application uptime in milliseconds
---@return number
function appTimeMs() end

--- Call a named function on the server (invoked from a client script)
---@param functionName string
---@param ... any
function invokeServerFunction(functionName, ...) end

--- Call a named function on a specific client (invoked from a server script)
---@param player Player
---@param functionName string
---@param ... any
function invokeClientFunction(player, functionName, ...) end

--- Call a named function on all connected clients (invoked from a server script)
---@param functionName string
---@param ... any
function broadcastInvokeClientFunction(functionName, ...) end

--- Mark a function as remotely callable via invokeServerFunction / invokeClientFunction.
--- Must be called at file scope, not inside a function.
---@param namespace table
---@param functionName string
function callable(namespace, functionName) end

--- Returns false if the object has been destroyed or is otherwise invalid
---@param object any
---@return boolean
function valid(object) end

--- Count entries in a table; works with non-sequential (hash) keys unlike #
---@param tbl table
---@return integer
function tablelength(tbl) end

--- Shuffle a table in-place using the provided RNG
---@param random Random
---@param tbl table
function shuffle(random, tbl) end

--- Pick and return a random entry from a table
---@param random Random
---@param tbl table
---@return any
function randomEntry(random, tbl) end

--- Draw a filled rectangle on the HUD (client only)
---@param rect Rect
---@param color ColorRGB
function drawRect(rect, color) end

--- Draw text on the HUD (client only)
---@param x number
---@param y number
---@param text string
---@param color? ColorRGB
function drawText(x, y, text, color) end

--- Draw a 3D sphere in world space for one frame (client only)
---@param position vec3
---@param radius number
---@param color ColorRGB
function drawSphere(position, radius, color) end

--- Draw a debug sphere in world space for one frame (client only)
---@param position vec3
---@param radius number
---@param color ColorRGB
function drawDebugSphere(position, radius, color) end

--- Display a tooltip string at the current mouse position (client only)
---@param text string
function drawMouseTooltip(text) end

--- Index of the player whose RPC triggered the current server-side call.
--- Only valid inside a function invoked via invokeServerFunction.
---@type integer
callingPlayer = 0

--- Translation marker used with the string modulo operator: `"Hello"%_t`.
--- The engine overrides string.__mod so `str % _t` returns the localised string.
---@type boolean
_t = true

--- Upper-case translation marker — same as _t but forces the first letter uppercase.
---@type boolean
_T = true