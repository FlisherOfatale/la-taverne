local ADDON, ns = ...

-- Profession recipes: the catalog of every recipe in the game, and which ones my characters know.
-- Nothing here goes on the network: the Professions tab asks the guild and the allied guilds, and
-- this module answers what this account knows.
--
-- Catalog: every client builds its own from the game's data, with no recipe list shipped with the
-- addon (Forever adds, removes and changes recipes). A sweep of spell IDs 1 to SWEEP_LAST, about
-- 30 s after login, out of combat, a few milliseconds a frame: the name first (C_Spell.GetSpellName,
-- empty for an ID that isn't a spell, or a recipe Forever removed), then its profession
-- (C_TradeSkillUI.GetProfessionInfoByRecipeID, which makes a table: only for spells). Measured in
-- game: 0.7 s of work over about 2 s, no server traffic. Saved with the game build, swept again
-- only when the build changes. Names aren't saved: the client gives them in its own language.
--
-- Known recipes: IsPlayerSpell(recipeID) says it with no profession window open (checked in game:
-- the same count as the profession window). The character I play is asked live; my other
-- characters (alts) can't be, so each one saves the recipes it knows at login, for answering
-- for it from another character.
local Recipes = ns.NewModule("Recipes")

local SWEEP_LAST = 1500000 -- recipes go up to about 1330000 (Forever's additions), with gaps
local SWEEP_BUDGET = 4     -- milliseconds of sweeping a frame
local SWEEP_AFTER = 30     -- seconds after login
local SAVE_AFTER = 10      -- seconds after login (when the catalog is ready), and after learning
local CATALOG_FORMAT = 1   -- how the catalog is saved: a new number sweeps again

-- Professions kept, by their classic skill line (parentProfessionID: Forever's own skill lines,
-- 2937 for Alchemy and so on, have the classic one as parent). The gathering ones too: Forever
-- gives them recipes (Camp Chair for Skinning, Fish Bowl for Fishing, smelting). Not Poisons (a
-- rogue skill) or the game's test profession.
Recipes.PROFESSIONS = {
    [171] = true, -- Alchemy
    [164] = true, -- Blacksmithing
    [333] = true, -- Enchanting
    [202] = true, -- Engineering
    [165] = true, -- Leatherworking
    [197] = true, -- Tailoring
    [185] = true, -- Cooking
    [129] = true, -- First Aid
    [186] = true, -- Mining
    [182] = true, -- Herbalism
    [393] = true, -- Skinning
    [356] = true, -- Fishing
}

local entries = {}   -- the catalog in memory: { id, prof, name, lower }, sorted by name
local byID = {}      -- [recipe ID] = its entry
local profNames = {} -- [profession] = its name in the client's language
local ready = false
local sweep          -- while sweeping: { next, found = { [prof] = { ids } }, names, skipped, work, frames, started }
local sweepFrame
local saveTimer

local function Now() return GetServerTime() end

local function Build()
    local version, build = GetBuildInfo()
    return tostring(version) .. "." .. tostring(build)
end

-- IDs as text for the save: base 36, comma-separated.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function ToBase36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = n % 36
        s = DIGITS:sub(d + 1, d + 1) .. s
        n = (n - d) / 36
    end
    return s
end

local function Encode(ids)
    local parts = {}
    for i, id in ipairs(ids) do parts[i] = ToBase36(id) end
    return table.concat(parts, ",")
end

local function Decode(text, into)
    into = into or {}
    for part in tostring(text or ""):gmatch("[^,]+") do
        local id = tonumber(part, 36)
        if id then into[#into + 1] = id end
    end
    return into
end

local function Store()
    ns.db.recipes = ns.db.recipes or {}
    return ns.db.recipes
end

local function ProfessionOf(id)
    local info = C_TradeSkillUI.GetProfessionInfoByRecipeID(id)
    local prof = info and info.parentProfessionID
    if not prof or prof <= 0 then return nil end
    return prof, info.parentProfessionName
end

-- The catalog in memory, from the saved IDs: names from the client, sorted for the search.
local function Load(catalog)
    wipe(entries)
    wipe(byID)
    wipe(profNames)
    for profKey, text in pairs(catalog.profs or {}) do
        local prof = tonumber(profKey)
        for _, id in ipairs(Decode(text)) do
            local name = C_Spell.GetSpellName(id)
            if name and name ~= "" then
                local entry = { id = id, prof = prof, name = name, lower = name:lower() }
                entries[#entries + 1] = entry
                byID[id] = entry
                if not profNames[prof] then
                    local _, profName = ProfessionOf(id)
                    profNames[prof] = profName
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.lower ~= b.lower then return a.lower < b.lower end
        return a.id < b.id
    end)
    ready = true
end

local function CatalogCurrent(catalog)
    return catalog and catalog.format == CATALOG_FORMAT and catalog.build == Build() and catalog.profs ~= nil
end

local function ScheduleSave(delay)
    if saveTimer then saveTimer:Cancel() end
    saveTimer = C_Timer.NewTimer(delay, function()
        saveTimer = nil
        Recipes:SaveMine()
    end)
end

-- Sweep ---------------------------------------------------------------------------

local function FinishSweep()
    local profs = {}
    local count = 0
    for prof, ids in pairs(sweep.found) do
        profs[tostring(prof)] = Encode(ids)
        count = count + #ids
    end
    Store().catalog = { format = CATALOG_FORMAT, build = Build(), t = Now(), profs = profs, count = count }
    Recipes.lastSweep = { count = count, skipped = sweep.skipped, work = sweep.work, frames = sweep.frames,
        seconds = GetTime() - sweep.started }
    sweep = nil
    sweepFrame:Hide()
    Load(Store().catalog)
    ScheduleSave(1)
end

local function SweepStep()
    if not sweep then sweepFrame:Hide() return end
    if InCombatLockdown() then return end -- carries on after the fight
    local getName, profOf = C_Spell.GetSpellName, C_TradeSkillUI.GetProfessionInfoByRecipeID
    local started = debugprofilestop()
    local id = sweep.next
    while id <= SWEEP_LAST do
        local name = getName(id)
        if name and name ~= "" then
            local info = profOf(id)
            local prof = info and info.parentProfessionID
            if prof and prof > 0 then
                if Recipes.PROFESSIONS[prof] then
                    local list = sweep.found[prof]
                    if not list then list = {} sweep.found[prof] = list end
                    list[#list + 1] = id
                else
                    sweep.skipped[prof] = (sweep.skipped[prof] or 0) + 1
                end
            end
        end
        id = id + 1
        -- The clock is read every 500 IDs: reading it costs about as much as one ID.
        if id % 500 == 0 and debugprofilestop() - started >= SWEEP_BUDGET then break end
    end
    sweep.next = id
    sweep.work = sweep.work + (debugprofilestop() - started)
    sweep.frames = sweep.frames + 1
    if id > SWEEP_LAST then FinishSweep() end
end

function Recipes:StartSweep()
    if sweep then return false end
    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoByRecipeID and C_Spell and C_Spell.GetSpellName) then
        return false
    end
    sweep = { next = 1, found = {}, skipped = {}, work = 0, frames = 0, started = GetTime() }
    if not sweepFrame then
        sweepFrame = CreateFrame("Frame")
        sweepFrame:SetScript("OnUpdate", SweepStep)
    end
    sweepFrame:Show()
    return true
end

function Recipes:IsSweeping()
    return sweep ~= nil, sweep and sweep.next or nil, SWEEP_LAST
end

function Recipes:IsReady() return ready end

-- Catalog -------------------------------------------------------------------------

function Recipes:Get(id) return byID[id] end

function Recipes:ProfessionName(prof) return profNames[prof] end

-- Recipes whose name has the text in it, those starting with it first. At most limit (20).
function Recipes:Search(text, limit)
    limit = limit or 20
    local found = {}
    text = strtrim(text or ""):lower()
    if text == "" or not ready then return found end
    local later = {}
    for _, entry in ipairs(entries) do
        local at = entry.lower:find(text, 1, true)
        if at == 1 then
            found[#found + 1] = entry
            if #found >= limit then return found end
        elseif at then
            later[#later + 1] = entry
        end
    end
    for _, entry in ipairs(later) do
        if #found >= limit then break end
        found[#found + 1] = entry
    end
    return found
end

-- How many recipes the catalog has: in all, and [profession] = count.
function Recipes:Counts()
    local per, total = {}, 0
    for _, entry in ipairs(entries) do
        per[entry.prof] = (per[entry.prof] or 0) + 1
        total = total + 1
    end
    return total, per
end

-- My recipes ----------------------------------------------------------------------

-- Does the character I'm playing know this recipe? Read live, no profession window needed.
function Recipes:Knows(id)
    return IsPlayerSpell(id) and true or false
end

-- Save the recipes this character knows, for answering for it from my other characters. With its
-- guild (the test guild's in test mode, marked), so it answers only to its own guild and allies.
function Recipes:SaveMine()
    if not ready then return false end
    local mine = {}
    for _, entry in ipairs(entries) do
        if IsPlayerSpell(entry.id) then mine[#mine + 1] = entry.id end
    end
    table.sort(mine)
    local store = Store()
    store.chars = store.chars or {}
    local guild = ns.Guild:InGuild() and ns.Guild:GetName() or nil
    store.chars[ns.FullName("player")] = { guild = guild, test = ns.Guild:IsSandbox() or nil,
        build = Build(), t = Now(), ids = Encode(mine), count = #mine }
    return true, #mine
end

-- My characters who know this recipe: the one I'm playing (read live), and my alts in my guild or
-- an allied guild (from their saved recipes). { { name, alt = true for an alt }, ... }
function Recipes:WhoKnows(id)
    local who = {}
    local me = ns.FullName("player")
    if self:Knows(id) then who[#who + 1] = { name = me } end
    local sandbox = ns.Guild:IsSandbox() and true or nil
    for name, char in pairs(Store().chars or {}) do
        if name ~= me and type(char) == "table" and char.test == sandbox and char.guild
            and (ns.Guild:IsMyGuild(char.guild) or ns.Alliance:IsAllied(char.guild)) then
            for _, known in ipairs(Decode(char.ids)) do
                if known == id then
                    who[#who + 1] = { name = name, alt = true, guild = char.guild }
                    break
                end
            end
        end
    end
    return who
end

-- Login ---------------------------------------------------------------------------

function Recipes:OnLogin()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoByRecipeID and C_Spell and C_Spell.GetSpellName) then
        return
    end
    local catalog = Store().catalog
    if CatalogCurrent(catalog) then
        Load(catalog)
        ScheduleSave(SAVE_AFTER)
    else
        C_Timer.After(SWEEP_AFTER, function() Recipes:StartSweep() end)
    end
    -- A recipe learned: saved again a moment later. Which event the game sends isn't known yet
    -- (to check in game): every likely one, those it doesn't have are skipped.
    local f = CreateFrame("Frame")
    for _, event in ipairs({ "LEARNED_SPELL_IN_TAB", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED" }) do
        pcall(f.RegisterEvent, f, event)
    end
    f:SetScript("OnEvent", function()
        if ready then ScheduleSave(2) end
    end)
end

-- /taverne recipes: what the catalog and my characters hold (test and diagnostics).
ns.commands.recipes = function(arg)
    local sub, rest = strtrim(arg or ""):match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    if sub == "sweep" then
        ns.Print(Recipes:StartSweep() and "recipe catalog: sweeping again..." or "recipe catalog: already sweeping, or not possible here")
    elseif sub == "find" and rest ~= "" then
        local found = Recipes:Search(rest, 20)
        ns.Print(#found .. " recipe(s) for \"" .. rest .. "\":")
        for _, entry in ipairs(found) do
            local who = Recipes:WhoKnows(entry.id)
            local names = {}
            for _, w in ipairs(who) do names[#names + 1] = w.name .. (w.alt and " (alt)" or "") end
            ns.Print(entry.id, entry.name, "-", Recipes:ProfessionName(entry.prof) or entry.prof,
                #names > 0 and ("- known by " .. table.concat(names, ", ")) or "")
        end
    elseif sub == "save" then
        local ok, n = Recipes:SaveMine()
        ns.Print(ok and ("saved: this character knows " .. n .. " recipe(s)") or "the catalog isn't ready yet")
    else
        local sweeping, at, last = Recipes:IsSweeping()
        local catalog = Store().catalog
        if sweeping then
            ns.Print(string.format("recipe catalog: sweeping, %d%%", math.floor(at / last * 100)))
        elseif not ready then
            ns.Print("recipe catalog: not built yet (starts " .. SWEEP_AFTER .. " s after login, out of combat)")
        else
            local total, per = Recipes:Counts()
            ns.Print("recipe catalog: " .. total .. " recipes, game build " .. tostring(catalog and catalog.build))
            local lines = {}
            for prof, n in pairs(per) do lines[#lines + 1] = (profNames[prof] or prof) .. " " .. n end
            table.sort(lines)
            ns.Print(table.concat(lines, ", "))
        end
        local s = Recipes.lastSweep
        if s then
            local skipped = {}
            for prof, n in pairs(s.skipped) do skipped[#skipped + 1] = prof .. ":" .. n end
            ns.Print(string.format("last sweep: %d recipes, %.2f s of work over %d frames, %.1f s in all; other skill lines skipped: %s",
                s.count, s.work / 1000, s.frames, s.seconds, #skipped > 0 and table.concat(skipped, " ") or "none"))
        end
        local me = ns.FullName("player")
        for name, char in pairs(Store().chars or {}) do
            if type(char) == "table" then
                ns.Print((name == me and "this character" or name) .. ": " .. tostring(char.count) .. " recipe(s), guild "
                    .. tostring(char.guild) .. (char.test and " (test)" or "") .. ", saved " .. date("%Y-%m-%d %H:%M", char.t or 0))
            end
        end
        ns.Print("/taverne recipes find <text> | save | sweep")
    end
end
