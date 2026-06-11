-- OmniHub mod: every equipment dock also sells OmniHub factory modules.
-- This file is concatenated by the engine after the vanilla equipmentdock.lua — EquipmentDock and
-- its initialize are already defined above. Attaching in initialize covers both newly spawned
-- docks AND docks in existing saves: initialize runs again every time the sector loads, and
-- addScriptOnce dedupes against docks that already carry the script. The supplier script brings
-- its own interaction option ("Buy OmniHub Modules") and its own shop window, so the dock's
-- vanilla equipment shop is untouched.

local omnihub_base_initialize = EquipmentDock.initialize

function EquipmentDock.initialize(...)
    omnihub_base_initialize(...)

    if onServer() then
        Entity():addScriptOnce("data/scripts/entity/merchants/omnihubsupplier.lua")
    end
end
