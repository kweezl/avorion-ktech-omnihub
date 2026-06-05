-- MCM (Mod Configuration Menu) schema for KTech OmniHub.
-- Auto-discovered by MCM (workshop id 3674093144) at startup; returns a pages/options table.
-- SINGLE SOURCE OF TRUTH: the option schema lives in data/scripts/lib/omnihub/config.lua
-- (OmniHubConfig.schema) and is included here, so defaults/ranges/labels are declared in exactly one
-- place and the runtime fallback can never drift from the MCM UI. MCM supports include()/package.path
-- inside modconfig.lua (see its keybind example), so this is safe.
package.path = package.path .. ";data/scripts/lib/?.lua"
local OmniHubConfig = include("lib/omnihub/config")

return {
    pages = {
        {
            title   = "OmniHub",
            options = OmniHubConfig.schema,
        },
    },
}
