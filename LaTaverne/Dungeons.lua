-- WoW Forever dungeon list, with level ranges and group size.
-- fr = French name when known; otherwise the English name is shown.
-- size = 10 for 10-player dungeons (technically raids). Default is 5.
-- faction = "Horde" / "Alliance" for dungeons only one faction can reach: hidden from the other.
local ADDON, ns = ...

ns.Dungeons = {
    -- Names and level ranges as the game's own dungeon finder shows them (frFR client, 2026-11).
    { key = "HOT",      min = 13, max = 20, en = "The Hall of Thanes",              fr = "La salle des Thanes" },
    { key = "RFC",      min = 13, max = 18, en = "Ragefire Chasm",                  fr = "Gouffre de Ragefeu", faction = "Horde" },
    { key = "ROL",      min = 15, max = 22, en = "Ruins of Lordaeron",              fr = "Ruines de Lordaeron" },
    { key = "WC",       min = 15, max = 24, en = "Wailing Caverns",                 fr = "Cavernes des lamentations" },
    { key = "DM",       min = 17, max = 26, en = "The Deadmines",                   fr = "Mortemines" },
    { key = "SFK",      min = 20, max = 30, en = "Shadowfang Keep",                 fr = "Donjon d’Ombrecroc" },
    { key = "BFD",      min = 24, max = 32, en = "Blackfathom Deeps",               fr = "Profondeurs de Brassenoire" },
    { key = "STOCKS",   min = 24, max = 32, en = "The Stockade",                    fr = "Prison de Stormwind" },
    { key = "EXCAV",    min = 26, max = 33, en = "Excavation Site: Wetlands",       fr = "Excavations : les Paluns" },
    { key = "DALARAN",  min = 28, max = 35, en = "City of Dalaran",                 fr = "Cité de Dalaran" },
    { key = "GNOMER",   min = 29, max = 38, en = "Gnomeregan",                      fr = "Gnomeregan" },
    { key = "RFK",      min = 29, max = 38, en = "Razorfen Kraul",                  fr = "Kraal de Tranchebauge" },
    { key = "SMGY",     min = 30, max = 38, en = "Scarlet Monastery: Graveyard",    fr = "Cimetière Écarlate" },
    { key = "SMLIB",    min = 33, max = 41, en = "Scarlet Monastery: Library",      fr = "Bibliothèque Écarlate" },
    { key = "DROWNED",  min = 35, max = 42, en = "The Drowned City",                fr = "La cité Submergée" },
    { key = "SMARM",    min = 36, max = 44, en = "Scarlet Monastery: Armory",       fr = "Armurerie Écarlate" },
    { key = "RFD",      min = 37, max = 46, en = "Razorfen Downs",                  fr = "Souilles de Tranchebauge" },
    { key = "SMCATH",   min = 38, max = 46, en = "Scarlet Monastery: Cathedral",    fr = "Cathédrale Écarlate" },
    { key = "KROLDOK",  min = 40, max = 47, en = "Krol'dok Stronghold",             fr = "Bastion Krol’dok" },
    { key = "ULDA",     min = 41, max = 51, en = "Uldaman",                         fr = "Uldaman" },
    { key = "ZF",       min = 44, max = 54, en = "Zul'Farrak",                      fr = "Zul’Farrak" },
    { key = "MARA",     min = 46, max = 55, en = "Maraudon",                        fr = "Maraudon" },
    { key = "ALCAZ",    min = 48, max = 55, en = "Alcaz Prison",                    fr = "Prison d’Alcaz" },
    { key = "ST",       min = 50, max = 60, en = "Sunken Temple",                   fr = "Temple Englouti" },
    { key = "BRD",      min = 52, max = 60, en = "Blackrock Depths",                fr = "Profondeurs de Rochenoire" },
    { key = "DMEAST",   min = 54, max = 60, en = "Dire Maul - East",                fr = "Haches-Tripes (est)" },
    { key = "BLACKMAW", min = 55, max = 60, en = "Blackmaw Hold",                   fr = "Repaire des Noiregueules" },
    { key = "LBRS",     min = 55, max = 60, en = "Lower Blackrock Spire",           fr = "Bas du pic Rochenoire" },
    { key = "DMNORTH",  min = 56, max = 60, en = "Dire Maul - North",               fr = "Haches-Tripes (nord)" },
    { key = "DMWEST",   min = 56, max = 60, en = "Dire Maul - West",                fr = "Haches-Tripes (ouest)" },
    { key = "SCHOLO",   min = 58, max = 60, en = "Scholomance",                     fr = "Scholomance" },
    { key = "SHAPER",   min = 58, max = 60, en = "Shaper's Terrace",                fr = "La terrasse du Façonneur" },
    { key = "STRATLIVE",min = 58, max = 60, en = "Stratholme - Main Gate",          fr = "Stratholme (porte principale)" },
    { key = "STRATUD",  min = 58, max = 60, en = "Stratholme - Service Entrance",   fr = "Stratholme (porte de service)" },
    { key = "UBRS",     min = 59, max = 60, en = "Upper Blackrock Spire",           fr = "Sommet du pic Rochenoire", size = 10 },
    { key = "OTHER",                        en = "Other (see note)",                fr = "Autre (voir la note)" },
    -- Debug mode only: a group that fills up with two testers (full, in progress, looking again).
    { key = "TEST2",                        en = "Test dungeon",                    fr = "Donjon de test", size = 2, test = true },
}


local byKey = {}
for _, d in ipairs(ns.Dungeons) do byKey[d.key] = d end

local french = GetLocale() == "frFR"

local function Name(d)
    return (french and d.fr) or d.en
end

-- Dungeon names in the other languages La Taverne knows, for tooltips (Options: one switch per
-- language, the client's own language left out). name = the language's name, a Locale key.
ns.DUNGEON_LANGUAGES = {
    { key = "en", name = "English", get = function(d) return d.en end },
    { key = "fr", name = "French", get = function(d) return d.fr or d.en end },
}
local CLIENT_LANGUAGE = french and "fr" or "en"

-- The languages other than the client's: { key, name, get }.
function ns.OtherDungeonLanguages()
    local out = {}
    for _, lang in ipairs(ns.DUNGEON_LANGUAGES) do
        if lang.key ~= CLIENT_LANGUAGE then out[#out + 1] = lang end
    end
    return out
end

-- Tooltip lines for a dungeon (entry or key): its name in each language switched on in Options,
-- when it differs, e.g. "English: The Deadmines". Empty when none.
function ns.DungeonOtherNames(d)
    if type(d) == "string" then d = ns.DungeonByKey(d) end
    local out = {}
    if not d or d.test then return out end
    local shown = ns.db and ns.db.dungeonLanguages or {}
    for _, lang in ipairs(ns.OtherDungeonLanguages()) do
        local name = lang.get(d)
        if shown[lang.key] and name then -- even when the same: no line would look like a bug
            -- "Anglais : ...": capitalized here, at the start of the line (lowercase mid-sentence).
            local label = ns.L[lang.name]:gsub("^%l", string.upper)
            out[#out + 1] = format(ns.L["%s: %s"], "|cff808080" .. label .. "|r", name)
        end
    end
    return out
end

-- The dungeon entry for a key (nil when unknown).
function ns.DungeonByKey(key)
    return byKey[key]
end

function ns.DungeonName(key)
    local d = byKey[key]
    if not d then return tostring(key) end
    return Name(d)
end

-- Can I pick this dungeon? The test dungeon only exists in debug mode, and faction dungeons
-- only for their faction.
function ns.DungeonShown(d)
    if d.test and not ns.Guild:IsSandbox() then return false end
    if d.faction and d.faction ~= UnitFactionGroup("player") then return false end
    return true
end

-- Group size for a dungeon: 5, or 10 for 10-player dungeons.
function ns.DungeonSize(key)
    local d = byKey[key]
    return (d and d.size) or 5
end

-- Difficulty colors of the game's quest log (QuestDifficultyColors), with fallbacks.
local DIFFICULTY_FALLBACK = {
    impossible    = "ff2020", -- red (and skull)
    verydifficult = "ff8040", -- orange
    difficult     = "ffff00", -- yellow
    standard      = "40c040", -- green
    trivial       = "808080", -- gray
}
local function DifficultyHex(kind)
    local c = QuestDifficultyColors and QuestDifficultyColors[kind]
    if c and c.r then
        return format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return DIFFICULTY_FALLBACK[kind]
end

-- The highest level that is gray for a player of this level (none up to level 5), as in the
-- game's mob / quest color table.
local function GrayLevel(level)
    if level <= 5 then return 0 end
    if level < 40 then return level - math.floor(level / 10) - 5 end
    if level < 50 then return level - 9 end
    if level < 60 then return level - math.floor(level / 5) - 1 end
    return level - 9
end

-- The game's "con" color for something of level target, seen by a player of this level:
--   red (impossible)      5 or more levels above (skull from 10: red too)
--   orange (verydifficult) 3 or 4 above
--   yellow (difficult)    2 below to 2 above
--   green (standard)      lower, but above the gray level
--   gray (trivial)        at or under the gray level
function ns.LevelDifficulty(target, level)
    local diff = target - level
    if diff >= 5 then return "impossible" end
    if diff >= 3 then return "verydifficult" end
    if diff >= -2 then return "difficult" end
    if target > GrayLevel(level) then return "standard" end
    return "trivial"
end

-- How hard a dungeon is for a player of this level: the con color of the middle of its range
-- (its mobs are around there). E.g. The Hall of Thanes 13-20 (middle 17): yellow at 15 to 19,
-- orange at 13-14, red under 13, green from 20, gray from 25.
function ns.DungeonDifficulty(d, level)
    if not (d and d.min and d.max) then return nil end
    level = level or UnitLevel("player") or 0
    return ns.LevelDifficulty(math.ceil((d.min + d.max) / 2), level)
end

-- The dungeon's difficulty color for me, as "rrggbb" (white when it has no range).
function ns.DungeonColor(d)
    local kind = ns.DungeonDifficulty(d)
    return kind and DifficultyHex(kind) or "ffffff"
end

-- The level range in that color ("" when it has none).
function ns.DungeonRange(d)
    if not (d and d.min) then return "" end
    return "|cff" .. ns.DungeonColor(d) .. d.min .. "-" .. d.max .. "|r"
end

-- Name (and size when it's not 5) without the range, in the difficulty color.
function ns.DungeonColoredName(d)
    local label = Name(d)
    if d.size and d.size ~= 5 then label = label .. " (" .. d.size .. ")" end
    return "|cff" .. ns.DungeonColor(d) .. label .. "|r"
end

-- Name with level range, all in the difficulty color, for one-line texts.
function ns.DungeonLabel(d)
    if not d.min then return ns.DungeonColoredName(d) end
    return ns.DungeonColoredName(d) .. " " .. ns.DungeonRange(d)
end
