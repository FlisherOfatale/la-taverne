-- /taverne roster: the guild roster (with notes and last online) and the game's roster history,
-- as tab-separated text to copy: pasted in a spreadsheet, each field lands in its own column
-- (to check the guild against a Discord member list, for example). Read only: nothing is sent.
local ADDON, ns = ...
local L = ns.L

-- One field: no tabs or line breaks inside (they'd split the columns or the rows).
local function Field(v)
    if v == nil then return "" end
    return (tostring(v):gsub("[\t\r\n]+", " "))
end

local function Row(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = Field((select(i, ...))) end
    return table.concat(parts, "\t")
end

local function CanSeeOfficerNotes()
    if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then return C_GuildInfo.CanViewOfficerNote() and true or false end
    if CanViewOfficerNote then return CanViewOfficerNote() and true or false end
    return false
end

-- Days since last online (approximate: the game gives years, months, days and hours).
local function DaysOffline(i)
    if not GetGuildRosterLastOnline then return "" end
    local years, months, days = GetGuildRosterLastOnline(i)
    if not (years or months or days) then return "" end
    return (years or 0) * 365 + (months or 0) * 30 + (days or 0)
end

-- How long ago a roster history event happened, as the game gives it.
local function Ago(year, month, day, hour)
    local parts = {}
    if (year or 0) > 0 then parts[#parts + 1] = format(L["%dy"], year) end
    if (month or 0) > 0 then parts[#parts + 1] = format(L["%dmo"], month) end
    if (day or 0) > 0 then parts[#parts + 1] = format(L["%dd"], day) end
    if #parts == 0 then parts[1] = format(L["%dh"], hour or 0) end
    return table.concat(parts, " ")
end

-- "Show Offline Members" unticked in the Guild window: the game then lists only the online
-- members, and an export missing everyone offline would be easy to take for the whole guild.
local OFFLINE_HIDDEN = "Offline members are hidden, so the roster would be incomplete: tick Show Offline Members in the Guild window, then /taverne roster again."

local function OfflineHidden()
    return GetGuildRosterShowOffline ~= nil and not GetGuildRosterShowOffline()
end

local function ShowError(text)
    ns.Print("|cffff3333" .. text .. "|r")
end

local EVENTS = {
    invite = "Invited",
    join = "Joined",
    promote = "Promoted",
    demote = "Demoted",
    remove = "Removed",
    quit = "Left",
}

local function BuildText()
    local out = {}
    local function Add(text) out[#out + 1] = text end
    local guild = GetGuildInfo("player")
    Add(format(L["Guild roster of %s, %s"], tostring(guild or "?"), date("%Y-%m-%d %H:%M")))

    -- Members: by rank, then by name.
    local total = GetNumGuildMembers() or 0
    local officer = CanSeeOfficerNotes()
    local members, anyOffline = {}, false
    for i = 1, total do
        local name, rank, rankIndex, level, class, _, note, officerNote, online = GetGuildRosterInfo(i)
        if name then
            if not online then anyOffline = true end
            members[#members + 1] = {
                name = name, rank = rank, rankIndex = rankIndex or 99, level = level, class = class,
                note = note, officerNote = officerNote, online = online,
                days = online and 0 or DaysOffline(i),
            }
        end
    end
    table.sort(members, function(a, b)
        if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        return a.name < b.name
    end)
    -- Offline members missing: an error instead of the list (also when the box is unticked while
    -- this window is open, or, on a game without that setting, when the counts give it away).
    if OfflineHidden() or (#members > 0 and not anyOffline and #members < total) then
        return "|cffff3333" .. L[OFFLINE_HIDDEN] .. "|r"
    end
    Add(format(L["Members: %d"], #members))
    if #members == 0 then
        Add(L["The roster isn't loaded yet: it shows here in a few seconds."])
    end
    if not officer then Add(L["Officer notes: your rank can't see them."]) end
    Add("")
    if officer then
        Add(Row(L["Name"], L["Rank"], L["Level"], L["Class"], L["Online"], L["Days offline"], L["Note"], L["Officer note"]))
    else
        Add(Row(L["Name"], L["Rank"], L["Level"], L["Class"], L["Online"], L["Days offline"], L["Note"]))
    end
    for _, m in ipairs(members) do
        local online = m.online and L["Yes"] or L["No"]
        if officer then
            Add(Row(m.name, m.rank, m.level, m.class, online, m.days, m.note, m.officerNote))
        else
            Add(Row(m.name, m.rank, m.level, m.class, online, m.days, m.note))
        end
    end

    -- Roster history: the game keeps only its last events (about 100).
    Add("")
    Add(L["Roster history (the game keeps only the last events, about 100)"])
    if not (GetNumGuildEvents and GetGuildEventInfo) then
        Add(L["Not available in this version of the game."])
    else
        local n = GetNumGuildEvents() or 0
        if n == 0 then
            Add(L["No events (or not loaded yet: they show here in a few seconds)."])
        else
            Add(Row(L["When (ago)"], L["Event"], L["By"], L["Player"], L["Rank"]))
            for i = 1, n do
                local kind, player1, player2, rank, year, month, day, hour = GetGuildEventInfo(i)
                local label = EVENTS[kind] and L[EVENTS[kind]] or kind
                local by, who = player1, player2
                if kind == "join" or kind == "quit" then by, who = nil, player1 end
                Add(Row(Ago(year, month, day, hour), label, by, who, rank))
            end
        end
    end
    return table.concat(out, "\n")
end

ns.commands.roster = function()
    if not IsInGuild() then
        ns.Print(L["You're not in a guild."])
        return
    end
    if OfflineHidden() then
        ShowError(L[OFFLINE_HIDDEN])
        return
    end
    -- Ask the game for the roster and its history: the text fills in as they arrive.
    if ns.Guild.RequestRoster then ns.Guild.RequestRoster() end
    if QueryGuildEventLog then QueryGuildEventLog() end
    ns.TextDialog({
        kind = "roster",
        title = L["Guild roster"],
        width = 760,
        hint = L["Tab-separated: pasted in a spreadsheet, each field gets its own column. Copy selects it all: then Ctrl+C."],
        text = BuildText(),
        autoFill = BuildText,
        autoEvery = 3,
        button = L["Copy"],
        onButton = function()
            ns.SelectTextDialog()
            return false
        end,
    })
end
