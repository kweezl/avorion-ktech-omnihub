-- OmniHub mod: appends OmniHub to the Found Station > Other Stations list.
-- This file is concatenated by the engine after the vanilla stationfounder.lua.
-- StationFounder and StationFounder.stations are already defined above.

table.insert(StationFounder.stations, {
    name    = "OmniHub"%_t,
    tooltip = "A modular production station. Install factory modules to produce goods. Modules can be bought from an OmniHub Supplier."%_t,
    scripts = {
        { script = "data/scripts/entity/merchants/omnihubcontroller.lua" },
        { script = "data/scripts/entity/merchants/omnihubsupplier.lua" },
        -- omnihubtests.lua is deliberately NOT listed here: the controller attaches it in its
        -- initialize, which runs inside the founder's addScript loop — i.e. BEFORE the founder
        -- would reach a tests entry, so listing it here double-attaches it (two interaction
        -- options). The controller is the single attach point.
    },
    price = 15000000,
})
