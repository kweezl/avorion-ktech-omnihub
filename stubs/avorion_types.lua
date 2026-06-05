-- EmmyLua stubs: Avorion engine object types.
-- Not deployed — IDE type annotations only.

---@class Index
---@field sector integer
---@field id integer
Index = {}

---@class TradingGood
---@field name string
---@field plural string
---@field description string
---@field icon string
---@field price number
---@field size number
local _TradingGood = {}

---@param name string
---@param plural string
---@param description string
---@param icon string
---@param price number
---@param size number
---@return TradingGood
function TradingGood(name, plural, description, icon, price, size) end

-- ─── Entity ───────────────────────────────────────────────────────────────────

---@class Entity
---@field id Index
---@field index integer
---@field title string Untranslated title key
---@field translatedTitle string Localized display title
---@field name string
---@field position Transform
---@field translationf vec3 World-space position vector
---@field radius number
---@field factionIndex integer
---@field playerOwned boolean
---@field allianceOwned boolean
---@field aiOwned boolean
---@field dockingParent Index
---@field freeCargoSpace number
---@field maxCargoSpace number
---@field transporterRange number
local _Entity = {}

---@param key string
---@return any
function _Entity:getValue(key) end

---@param key string
---@param value any
function _Entity:setValue(key, value) end

---@param prefix? string
---@return table
function _Entity:getValues(prefix) end

---@param eventName string
---@param functionName string
function _Entity:registerCallback(eventName, functionName) end

---@param scriptPath string
---@param functionName string
---@param ... any
---@return boolean, ...
function _Entity:invokeFunction(scriptPath, functionName, ...) end

---@param scriptPath string
---@param ... any
function _Entity:addScript(scriptPath, ...) end

---@param scriptPath string
---@param ... any
function _Entity:addScriptOnce(scriptPath, ...) end

---@param scriptPath string
function _Entity:removeScript(scriptPath) end

---@param scriptPath string
---@return boolean
function _Entity:hasScript(scriptPath) end

---@return string[]
function _Entity:getScripts() end

---@param functionName string
---@param ... any
function _Entity:sendCallback(functionName, ...) end

---@param good TradingGood|string
---@return number
function _Entity:getCargoAmount(good) end

---@param good TradingGood
---@param amount number
function _Entity:addCargo(good, amount) end

---@param other Entity
---@return boolean
function _Entity:isInDockingArea(other) end

---@return number
function _Entity:getNearestDistance() end

---@return integer
function _Entity:getNumArmedTurrets() end

--- Get the current entity (when called with no args inside an entity script) or entity by index
---@overload fun(): Entity
---@param index integer
---@return Entity
function Entity(index) end

-- ─── Player ───────────────────────────────────────────────────────────────────

---@class Player
---@field index integer
---@field craftIndex integer Index of the ship/station the player is piloting
---@field allianceIndex integer
---@field relationBonus number
local _Player = {}

---@param key string
---@return any
function _Player:getValue(key) end

---@param key string
---@param value any
function _Player:setValue(key, value) end

---@param eventName string
---@param functionName string
function _Player:registerCallback(eventName, functionName) end

---@param targetEntity Entity|string
---@param messageType integer ChatMessageType value
---@param message string
---@param ... any
function _Player:sendChatMessage(targetEntity, messageType, message, ...) end

---@param faction Faction
---@return number
function _Player:getRelation(faction) end

---@return table
function _Player:getResources() end

---@param amount number
---@return boolean, string?, any[]?
function _Player:canPay(amount) end

---@param amount number
function _Player:pay(amount) end

---@param good TradingGood
---@param amount number
function _Player:receive(good, amount) end

---@param sender string
---@param subject string
---@param body string
function _Player:addMail(sender, subject, body) end

---@return integer, integer x, y
function _Player:getHomeSectorCoordinates() end

---@return integer, integer x, y
function _Player:getSectorCoordinates() end

---@param ship Entity
---@return boolean
function _Player:ownsShip(ship) end

---@param scriptPath string
---@param functionName string
---@param ... any
---@return ...
function _Player:invokeFunction(scriptPath, functionName, ...) end

---@param scriptPath string
---@param ... any
function _Player:addScript(scriptPath, ...) end

---@param scriptPath string
---@param ... any
function _Player:addScriptOnce(scriptPath, ...) end

---@param scriptPath string
function _Player:removeScript(scriptPath) end

---@param scriptPath string
---@return boolean
function _Player:hasScript(scriptPath) end

---@return string[]
function _Player:getScripts() end

---@param functionName string
---@param ... any
function _Player:sendCallback(functionName, ...) end

--- Get the current player or player by index
---@overload fun(): Player
---@param index integer
---@return Player
function Player(index) end

-- ─── Sector ───────────────────────────────────────────────────────────────────

---@class Sector
---@field numEntities integer
---@field numPlayers integer
---@field seed Seed
local _Sector = {}

---@param key string
---@return any
function _Sector:getValue(key) end

---@param key string
---@param value any
function _Sector:setValue(key, value) end

---@return integer, integer x, y
function _Sector:getCoordinates() end

---@param eventName string
---@param functionName string
function _Sector:registerCallback(eventName, functionName) end

---@param scriptPath string
---@param functionName string
---@param ... any
---@return boolean, ...
function _Sector:invokeFunction(scriptPath, functionName, ...) end

---@param type integer EntityType value
---@return Entity[]
function _Sector:getEntitiesByType(type) end

---@param scriptPath string
---@return Entity[]
function _Sector:getEntitiesByScript(scriptPath) end

---@param scriptPath string
---@param valueKey string
---@param value any
---@return Entity[]
function _Sector:getEntitiesByScriptValue(scriptPath, valueKey, value) end

---@param factionIndex integer
---@return Entity[]
function _Sector:getEntitiesByFaction(factionIndex) end

---@return Entity[]
function _Sector:getEntities() end

---@param indexOrName integer|string
---@return Entity?
function _Sector:getEntity(indexOrName) end

---@param factionIndex integer
---@param name string
---@return Entity?
function _Sector:getEntityByFactionAndName(factionIndex, name) end

---@param type integer EntityType value
---@return integer
function _Sector:getNumEntitiesByType(type) end

---@return Player[]
function _Sector:getPlayers() end

---@return integer[]
function _Sector:getPresentFactions() end

---@param scriptPath string
---@param ... any
function _Sector:addScript(scriptPath, ...) end

---@param scriptPath string
---@param ... any
function _Sector:addScriptOnce(scriptPath, ...) end

---@param scriptPath string
function _Sector:removeScript(scriptPath) end

---@param scriptPath string
---@return boolean
function _Sector:hasScript(scriptPath) end

---@return string[]
function _Sector:getScripts() end

---@param functionName string
---@param ... any
function _Sector:sendCallback(functionName, ...) end

---@param messageType integer ChatMessageType value
---@param message string
---@param ... any
function _Sector:broadcastChatMessage(messageType, message, ...) end

---@param position vec3
---@param factionIndex integer
---@param scriptPath string
---@param uuid? string
---@return Entity?
function _Sector:createShip(position, factionIndex, scriptPath, uuid) end

---@param position vec3
---@param factionIndex integer
---@param scriptPath string
---@param uuid? string
---@return Entity?
function _Sector:createStation(position, factionIndex, scriptPath, uuid) end

---@param position vec3
---@param size number
---@return Entity?
function _Sector:createAsteroid(position, size) end

---@param position vec3
---@param sectorX integer
---@param sectorY integer
---@return Entity?
function _Sector:createWormHole(position, sectorX, sectorY) end

---@param position vec3
---@param radius number
---@param damage number
function _Sector:createExplosion(position, radius, damage) end

---@param entity Entity
function _Sector:deleteEntity(entity) end

---@param entity Entity
function _Sector:deleteEntityJumped(entity) end

---@param entity Entity
---@param targetX integer
---@param targetY integer
function _Sector:transferEntity(entity, targetX, targetY) end

---@param entity Entity
---@return Entity?
function _Sector:copyEntity(entity) end

---@param position vec3
---@param good TradingGood
---@param amount integer
---@return Entity?
function _Sector:dropCargo(position, good, amount) end

---@param rayStart vec3
---@param rayEnd vec3
---@return Entity?, number
function _Sector:intersectBeamRay(rayStart, rayEnd) end

---@param scriptPath string
---@return string
function _Sector:resolveScriptPath(scriptPath) end

--- Get the current sector or sector at galaxy coordinates
---@overload fun(): Sector
---@overload fun(coordinates: table): Sector
---@param x integer
---@param y integer
---@return Sector
function Sector(x, y) end

---@class ReadOnlySector : Sector
local _ReadOnlySector = {}

---@overload fun(): ReadOnlySector
---@overload fun(x: integer, y: integer): ReadOnlySector
---@return ReadOnlySector
function ReadOnlySector() end

-- ─── Faction / Galaxy ─────────────────────────────────────────────────────────

---@class Faction
---@field index integer
---@field name string
---@field translatedName string
---@field isAIFaction boolean
---@field isAlliance boolean
local _Faction = {}

---@param key string
---@return any
function _Faction:getValue(key) end

---@param key string
---@param value any
function _Faction:setValue(key, value) end

---@return table
function _Faction:getValues() end

---@param targetEntity Entity|string
---@param messageType integer ChatMessageType value
---@param message string
---@param ... any
function _Faction:sendChatMessage(targetEntity, messageType, message, ...) end

---@param good TradingGood
---@param amount integer
function _Faction:receive(good, amount) end

---@param resourceName string
---@param amount number
function _Faction:receiveResource(resourceName, amount) end

---@return table
function _Faction:getResources() end

---@return string
function _Faction:getPlanStyle() end

--- Get a faction by index
---@overload fun(): Faction
---@param index integer
---@return Faction
function Faction(index) end

--- Get the owning faction or player of the current entity
---@return Faction
function Owner() end

---@class Galaxy
local _Galaxy = {}

---@return integer, integer x, y
function _Galaxy:getCoordinates() end

---@param x integer
---@param y integer
---@return boolean
function _Galaxy:sectorInRift(x, y) end

---@param factionName string
---@return Faction?
function _Galaxy:findFaction(factionName) end

---@param x integer
---@param y integer
---@return Faction?
function _Galaxy:getLocalFaction(x, y) end

---@param x integer
---@param y integer
---@return Faction?
function _Galaxy:getNearestFaction(x, y) end

---@param x integer
---@param y integer
---@return Faction?
function _Galaxy:getControllingFaction(x, y) end

---@param x integer
---@param y integer
---@return boolean
function _Galaxy:isCentralFactionArea(x, y) end

---@return Faction?
function _Galaxy:getPirateFaction() end

---@param name string
---@param short string
---@return Faction?
function _Galaxy:createFaction(name, short) end

---@param faction1 Faction
---@param faction2 Faction
---@param relationLevel number
function _Galaxy:setFactionRelations(faction1, faction2, relationLevel) end

---@return Galaxy
function Galaxy() end

-- ─── ShipAI ───────────────────────────────────────────────────────────────────

---@class ShipAI
---@field state integer AIState value
---@field isStuck boolean
---@field flyTarget vec3?
local _ShipAI = {}

function _ShipAI:setPassive() end
function _ShipAI:setIdle() end

---@param target vec3
---@param speed? number
function _ShipAI:setFly(target, speed) end

---@param target vec3
---@param speed? number
function _ShipAI:setFlyLinear(target, speed) end

---@param enemy Entity
function _ShipAI:setAttack(enemy) end

---@param enemy Entity
function _ShipAI:setAggressive(enemy) end

---@param targetShip Entity
function _ShipAI:setEscort(targetShip) end

---@param targetEntity Entity
function _ShipAI:setFollow(targetEntity) end

---@param enemy Entity
function _ShipAI:registerEnemyEntity(enemy) end

---@param factionIndex integer
function _ShipAI:registerEnemyFaction(factionIndex) end

---@param friend Entity
function _ShipAI:registerFriendEntity(friend) end

---@param factionIndex integer
function _ShipAI:registerFriendFaction(factionIndex) end

function _ShipAI:setPassiveShooting() end
function _ShipAI:setPassiveTurning() end
function _ShipAI:stop() end

---@param message string
function _ShipAI:setStatusMessage(message) end

---@return Entity?
function _ShipAI:getFollowTarget() end

---@overload fun(): ShipAI
---@param ship Entity|integer
---@return ShipAI
function ShipAI(ship) end

-- ─── CargoBay / Hangar / DockingPositions / Plan ──────────────────────────────

---@class CargoBay
---@field cargoHold number Total cargo capacity
---@field fixedSize boolean
local _CargoBay = {}

---@param good TradingGood
---@param amount integer
---@return integer Amount actually added
function _CargoBay:addCargo(good, amount) end

---@param good TradingGood
---@param amount integer
---@return integer Amount added (excess is dropped into the sector)
function _CargoBay:addOrDrop(good, amount) end

---@param good TradingGood
---@param amount integer
---@return integer Amount taken
function _CargoBay:take(good, amount) end

---@return CargoBay
function CargoBay() end

---@class Hangar
local _Hangar = {}

---@return integer[]
function _Hangar:getSquads() end

---@param squadIndex integer
---@return integer WeaponCategory value
function _Hangar:getSquadMainWeaponCategory(squadIndex) end

---@return Hangar
function Hangar() end

---@class DockingPositions
---@field numDockingPositions integer
---@field docksEnabled boolean
local _DockingPositions = {}

---@param ship Entity
---@return integer?
function _DockingPositions:getFreeDock(ship) end

---@param dockIndex integer
---@return table? {position: vec3, direction: vec3}
function _DockingPositions:getDockingPosition(dockIndex) end

---@param ship Entity
---@param dockIndex integer
---@return boolean
function _DockingPositions:startPulling(ship, dockIndex) end

---@param ship Entity
function _DockingPositions:stopPulling(ship) end

---@param ship Entity
function _DockingPositions:startPushing(ship) end

---@param ship Entity
function _DockingPositions:stopPushing(ship) end

---@param ship Entity
---@return boolean
function _DockingPositions:isPushing(ship) end

---@param ship Entity
---@return boolean
function _DockingPositions:isTractoring(ship) end

---@param station Entity
---@return DockingPositions
function DockingPositions(station) end

---@class Plan
local _Plan = {}

---@return table
function _Plan:getStats() end

---@return Plan
function Plan() end