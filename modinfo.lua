meta =
{
    -- Unique string ID before publishing; the Workshop upload overwrites this with the numeric
    -- Workshop ID. build.py preserves whatever the engine writes back into the deployed copy.
    id = "KTechOmniHub",

    -- Internal name shown in the Mods() listing.
    name = "ktech-omnihub",

    -- Deploy folder name under <AVORION_MODS_DIR>, read by build.py. Custom field — the
    -- engine ignores unknown meta keys, so this is safe. Unlike `id` (overwritten with the
    -- numeric Workshop ID on upload), this stays stable as the on-disk mod directory name.
    modFolder = "KTechOmniHub",

    -- Title displayed to players.
    title = "KTech OmniHub",

    -- "mod" or "factionpack".
    type = "mod",

    description = "A single configurable station combining multiple production factories into one hub.",

    authors = {"kweezl"},

    -- Semver "major.minor.patch" or "major.minor".
    version = "0.1.0",

    -- Tested Avorion version range. max = "2.*" covers all 2.x patch releases.
    dependencies = {
        {id = "Avorion", min = "2.0", max = "2.*"},
        -- Mod Configuration Menu (MCM). Optional: the mod works standalone using built-in defaults;
        -- when MCM is present, OmniHubConfig.get reads live values from it. See modconfig.lua.
        {id = "3674093144", min = "1.0.0", optional = true},
    },

    -- Dual-side mod: attaches scripts with both server logic and client UI.
    serverSideOnly = false,
    clientSideOnly = false,

    -- Adds persistent scripts/items to the savegame (secure/restore), so warn on removal.
    saveGameAltering = true,

    contact = "https://github.com/kweezl/avorion-ktech-omnihub",
}