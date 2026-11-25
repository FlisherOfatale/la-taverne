-- /taverne roster: the guild roster (with notes and last online) and the game's roster history,
-- as tab-separated text to copy: pasted in a spreadsheet, each field lands in its own column
-- (to check the guild against a Discord member list, for example). Read only: nothing is sent.
local ADDON, ns = ...
local L = ns.L

-- One field: no tabs or line breaks inside (they'd split the columns or the rows), and no spaces
-- around it (a note typed " 04-11-2026" wouldn't match "04-11-2026" in a spreadsheet). Starting
-- with = + - @, a spreadsheet would read it as a formula ("-alt of Bob": an error): a ' in front
-- keeps it text (the spreadsheet doesn't show the ').
local function Field(v)
    if v == nil then return "" end
    local text = strtrim((tostring(v):gsub("[\t\r\n]+", " ")))
    if text:match("^[=+%-@]") then text = "'" .. text end
    return text
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

-- Offline members missing from the roster: an export without them would be easy to take for the
-- whole guild. Some games list only the online members while "Show Offline Members" is unticked
-- in the Guild window; Forever lists everyone either way. So the roster itself decides: with any
-- offline member in it, it's complete, whatever the box says.
local OFFLINE_HIDDEN = "Offline members are hidden, so the roster would be incomplete: tick Show Offline Members in the Guild window, then /taverne roster again."

local function OfflineHidden()
    return GetGuildRosterShowOffline ~= nil and not GetGuildRosterShowOffline()
end

local EVENTS = {
    invite = "Invited",
    join = "Joined",
    promote = "Promoted",
    demote = "Demoted",
    remove = "Removed",
    quit = "Left",
}

-- stamp: the time in the title, set once when the window opens (a text changing every minute
-- would be refilled, losing the selection Copy just made).
local function BuildText(stamp)
    local out = {}
    local function Add(text) out[#out + 1] = text end
    local guild = GetGuildInfo("player")
    Add(format(L["Guild roster of %s, %s"], tostring(guild or "?"), stamp or date("%Y-%m-%d %H:%M")))

    -- Members: by rank, then by name.
    local total, onlineCount = GetNumGuildMembers()
    total = total or 0
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
    -- Fewer listed than the game counts (always), or no offline member listed while the box is
    -- unticked and the game says someone is offline: an error instead of the list. (Everyone
    -- online: the list is complete, box ticked or not.)
    local someoneOffline = tonumber(onlineCount) == nil or tonumber(onlineCount) < total
    if #members > 0 and (#members < total or (not anyOffline and OfflineHidden() and someoneOffline)) then
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
                -- An invitation has no rank: the game gives the top rank's name there.
                if kind == "invite" or kind == "join" then rank = nil end
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
    -- Ask the game for the roster and its history: the text fills in as they arrive.
    if ns.Guild.RequestRoster then ns.Guild.RequestRoster() end
    if QueryGuildEventLog then QueryGuildEventLog() end
    local stamp = date("%Y-%m-%d %H:%M")
    ns.TextDialog({
        kind = "roster",
        title = L["Guild roster"],
        width = 760,
        hint = L["Tab-separated: pasted in a spreadsheet, each field gets its own column. Copy selects it all: then Ctrl+C."],
        text = BuildText(stamp),
        autoFill = function() return BuildText(stamp) end,
        autoEvery = 3,
        button = L["Copy"],
        onButton = function()
            ns.SelectTextDialog()
            return false
        end,
    })
end
