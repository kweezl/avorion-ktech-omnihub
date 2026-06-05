-- EmmyLua stubs: Avorion engine enumeration constants.
-- Not deployed — IDE type annotations only.

---@class EntityType
---@field None integer
---@field Ship integer
---@field Station integer
---@field Asteroid integer
---@field Fighter integer
---@field Drone integer
---@field Torpedo integer
---@field Turret integer
---@field Container integer
---@field Loot integer
---@field Wreckage integer
---@field Anomaly integer
---@field Unknown integer
EntityType = {}

---@class AIState
---@field Idle integer
---@field Passive integer
---@field Fly integer
---@field LinearFly integer
---@field Attack integer
---@field Aggressive integer
---@field Escort integer
---@field Harvest integer
---@field Repair integer
---@field RepairTarget integer
---@field Boarding integer
---@field Jump integer
AIState = {}

---@class ChatMessageType
---@field Normal integer
---@field Information integer
---@field Error integer
---@field Warning integer
---@field Notification integer
---@field Chatter integer
---@field Economy integer
---@field ServerInfo integer
ChatMessageType = {}

---@class WeaponCategory
---@field Armed integer
---@field Mining integer
---@field Salvaging integer
---@field Heal integer
WeaponCategory = {}

---@class AlliancePrivilege
---@field ManageStations integer
---@field ManageShips integer
---@field FlyCrafts integer
---@field FoundStations integer
---@field FoundShips integer
---@field AddResources integer
---@field SpendResources integer
---@field AddItems integer
---@field TakeItems integer
---@field SpendItems integer
---@field NegotiateRelations integer
---@field ModifyCrafts integer
AlliancePrivilege = {}

---@class FontType
---@field Normal integer
FontType = {}