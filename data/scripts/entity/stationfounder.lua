-- OmniHub mod: appends OmniHub to the Found Station > Other Stations list.
-- This file is concatenated by the engine after the vanilla stationfounder.lua.
-- StationFounder and StationFounder.stations are already defined above.

-- Founding price comes from the mod config (MCM-backed when installed, built-in default
-- otherwise). Evaluated when this script loads — i.e. fresh on each founder interaction — and
-- INDEPENDENTLY in the client (displayed price) and server (charged price) VMs: with MCM
-- installed the value must reach both VMs or the UI shows a different price than is charged
-- (without MCM both fall back to the same built-in default). Verify in-game with a non-default
-- cost when MCM is present. An error while this chunk loads would break the WHOLE concatenated
-- founder script (every station type), which is why get() guarantees a non-nil number.
package.path = package.path .. ";data/scripts/lib/?.lua"
local OmniHubConfig = include("lib/omnihub/config")

table.insert(StationFounder.stations, {
    name    = "OmniHub"%_t,
    tooltip = "A modular production station. Install factory modules to produce goods. Modules can be bought at any Equipment Dock."%_t,
    scripts = {
        { script = "data/scripts/entity/merchants/omnihubcontroller.lua" },
        -- The supplier on the hub itself is a dev-mode convenience: its interaction option only
        -- shows with dev mode on (gated in omnihubsupplier.lua:interactionPossible). Players buy
        -- modules at equipment docks, which get the same script via our equipmentdock.lua fragment.
        { script = "data/scripts/entity/merchants/omnihubsupplier.lua" },
        -- omnihubtests.lua is deliberately NOT listed here: the controller attaches it in its
        -- initialize, which runs inside the founder's addScript loop — i.e. BEFORE the founder
        -- would reach a tests entry, so listing it here double-attaches it (two interaction
        -- options). The controller is the single attach point.
    },
    price = OmniHubConfig.get("foundingCostMillions") * OmniHubConfig.CREDITS_PER_MILLION,
})
