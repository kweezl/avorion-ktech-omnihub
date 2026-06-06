-- Off-engine mocks for the Avorion engine globals used by the pure OmniHub libraries.
-- Returns setup(repoRoot): installs a global include() shim plus the mock globals the pure
-- suites need, so `lua tests/run.lua` can exercise the same library code the game loads.
--
-- Only the PURE libraries are loaded off-engine (config, moduledefs, production, framework,
-- registry, pure suites). The attached controller and the integration suite are never loaded here.

return function(repoRoot)
    -- Lets modconfig_spec locate the mod-root modconfig.lua when running off-engine.
    _G.OMNIHUB_MODCONFIG_PATH = repoRoot .. "/modconfig.lua"

    -- %_t string-translation operator (the game injects this via stringutility). Identity here.
    _t = {}
    local smeta = getmetatable("")
    if smeta then smeta.__mod = function(s) return s end end

    -- RarityType enum — canonical Avorion values, so moduledefs.lua (which pins the module item
    -- rarity) loads off-engine and rarity assertions mean what they do in-game.
    RarityType = {
        Petty       = -1,
        Common      =  0,
        Uncommon    =  1,
        Rare        =  2,
        Exceptional =  3,
        Exotic      =  4,
        Legendary   =  5,
    }

    -- lerp — copy of data/scripts/lib/utility.lua:4-22 (the real one lives in an engine lib).
    function lerp(factor, lowerBound, upperBound, lowerValue, upperValue, allowOverstepping)
        if lowerBound > upperBound then
            lowerBound, upperBound = upperBound, lowerBound
            lowerValue, upperValue = upperValue, lowerValue
        end
        if lowerBound == upperBound then return lowerValue end
        local value
        if allowOverstepping then
            value = (factor - lowerBound) / (upperBound - lowerBound)
        else
            value = math.min(1.0, math.max(0.0, (factor - lowerBound) / (upperBound - lowerBound)))
        end
        return lowerValue + (upperValue - lowerValue) * value
    end

    -- ── Mock data installers (mirror the side-effecting engine includes) ──────────
    local function installProductions()
        -- A tiny, deterministic productionsByGood: a chain Iron Ore -> Steel -> Steel Plate,
        -- plus one `mine` entry to verify it is excluded from the catalog.
        local prodSteel  = { ingredients = {{name = "Iron Ore", amount = 5, optional = 0}},
                             results     = {{name = "Steel", amount = 2}}, garbages = {} }
        local prodPlateA = { ingredients = {{name = "Steel", amount = 2, optional = 0}},
                             results     = {{name = "Steel Plate", amount = 1}} }
        local prodPlateB = { ingredients = {{name = "Steel", amount = 4, optional = 0}},
                             results     = {{name = "Steel Plate", amount = 3}} }
        local prodMine   = { mine = true, ingredients = {},
                             results = {{name = "Iron Ore", amount = 10}} }
        -- A single production yielding TWO goods (appears under both in productionsByGood, SAME table
        -- identity) — exercises the deterministic-key dedup: it must always key under "Helium"
        -- (alphabetically first of Helium/Neon), never "Neon".
        local prodGas    = { ingredients = {},
                             results = {{name = "Helium", amount = 3}, {name = "Neon", amount = 3}},
                             garbages = {} }

        productionsByGood = {
            ["Steel"]       = { prodSteel },
            ["Steel Plate"] = { prodPlateA, prodPlateB },
            ["Iron Ore"]    = { prodMine },
            ["Helium"]      = { prodGas },
            ["Neon"]        = { prodGas },
        }

        function getTranslatedFactoryName(prod, suffix)
            local base = (prod.results and prod.results[1] and prod.results[1].name) or "Unknown"
            return base .. " Factory" .. (suffix or "")
        end

        function getFactoryCost(prod)
            local n = (prod.ingredients and #prod.ingredients) or 0
            return 1000 + n * 500
        end
    end

    local function installGoods()
        goods = {
            ["Steel"]       = { name = "Steel",       price = 120, level = 1, icon = "data/textures/icons/steel.png" },
            ["Steel Plate"] = { name = "Steel Plate", price = 300, level = 2, icon = "data/textures/icons/steel-plate.png" },
            ["Iron Ore"]    = { name = "Iron Ore",    price = 40,  level = 0, icon = "data/textures/icons/ore.png" },
        }
    end

    -- ── include() shim ───────────────────────────────────────────────────────────
    local NIL   = {}   -- sentinel so cached nils (side-effecting includes) aren't recomputed
    local cache = {}
    function include(name)
        local cached = cache[name]
        if cached ~= nil then
            if cached == NIL then return nil end
            return cached
        end

        local result
        if name == "productions" then
            installProductions(); result = nil
        elseif name == "goods" then
            installGoods(); result = nil
        elseif name:match("^lib/omnihub/") then
            local path = repoRoot .. "/data/scripts/" .. name .. ".lua"
            local chunk, err = loadfile(path)
            if not chunk then
                error("mock include: cannot load " .. path .. ": " .. tostring(err))
            end
            result = chunk()
        else
            error("mock include: unmocked module '" .. tostring(name) .. "'")
        end

        cache[name] = (result == nil) and NIL or result
        return result
    end
end
