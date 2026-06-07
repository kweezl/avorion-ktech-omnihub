-- OmniHub mod: appends OmniHub to the Found Station > Other Stations list.
-- This file is concatenated by the engine after the vanilla stationfounder.lua.
-- StationFounder and StationFounder.stations are already defined above.

table.insert(StationFounder.stations, {
    name    = "OmniHub"%_t,
    tooltip = "A modular production station. Install factory modules to produce goods. Modules can be bought from an OmniHub Supplier."%_t,
    scripts = {
        { script = "data/scripts/entity/merchants/omnihubcontroller.lua" },
        { script = "data/scripts/entity/merchants/omnihubsupplier.lua" },
        -- Dev-mode-only "OmniHub Tests" interaction option (gated in its interactionPossible).
        { script = "data/scripts/entity/merchants/omnihubtests.lua" },
    },
    price = 15000000,
})
