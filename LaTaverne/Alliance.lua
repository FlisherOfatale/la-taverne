-- Allied guilds, set up by the officers in the Guild Info text (the fake one in sandbox).
--
-- The same lines go in the Guild Info of every guild of the alliance:
--   LT:g:Exact Guild Name:TAG     one line per guild, ours included (TAG = short marker shown in chat)
--   LT:k:key                      shared secret, letters and digits
--   LT:t:key                      test mode only: the test guild's own hidden channel (each test
--                                 guild picks its key, so testers elsewhere never share a channel)
-- Lines can also be separated by ";" (handy for /taverne dev info, which is a single line).
--
-- The key gives the hidden alliance channel (name made from the key, password = key). Only
-- current members can read the Guild Info, so knowing the key means being in one of the guilds.
-- To change it for everybody, an officer edits the LT:k line: every client switches on its own
-- and stays on the old channel a few minutes so nothing is lost during the switch.
local ADDON, ns = ...
local Alliance = ns.NewModule("Alliance")

local OLD_CHANNEL_GRACE = 600 -- seconds on the previous channel after a key change

local config = { guilds = {}, key = nil } -- guilds: [lowercase name] = { name, tag }
local configSig = ""

-- Short stable hash for the channel name, so the key itself doesn't show in channel lists.
local function Hash(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 2147483647
    end
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = ""
    for _ = 1, 6 do
        local n = h % 36
        out = out .. digits:sub(n + 1, n + 1)
        h = math.floor(h / 36)
    end
    return out
end

function Alliance.Parse(text)
    local result = { guilds = {}, key = nil, testKey = nil, count = 0 }
    if type(text) ~= "string" then return result end
    for line in (text:gsub(";", "\n") .. "\n"):gmatch("(.-)\r?\n") do
        line = strtrim(line)
        local name, tag = line:match("^[Ll][Tt]:[Gg]:(.+):([^:]+)$")
        if name then
            name, tag = strtrim(name), strtrim(tag)
            if name ~= "" and tag ~= "" and not result.guilds[name:lower()] then
                result.guilds[name:lower()] = { name = name, tag = tag }
                result.count = result.count + 1
            end
        else
            local key = line:match("^[Ll][Tt]:[Kk]:(%w+)$")
            if key and #key >= 4 then result.key = key end
            local testKey = line:match("^[Ll][Tt]:[Tt]:(%w+)$")
            if testKey and #testKey >= 4 then result.testKey = testKey end
        end
    end
    return result
end

-- Officer helpers ----------------------------------------------------------------------------

Alliance.INFO_MAX = 500 -- the game's limit on the Guild Info text

function Alliance.NewKey()
    local chars = "abcdefghijkmnpqrstuvwxyz23456789" -- no look-alikes (l, 1, o, 0)
    local key = ""
    for _ = 1, 12 do
        local n = math.random(1, #chars)
        key = key .. chars:sub(n, n)
    end
    return key
end

-- Setup lines for a list of { name, tag } and a key.
function Alliance.BuildLines(guilds, key)
    local lines = {}
    for _, entry in ipairs(guilds) do
        lines[#lines + 1] = "LT:g:" .. entry.name .. ":" .. entry.tag
    end
    if key then lines[#lines + 1] = "LT:k:" .. key end
    return lines
end

-- The Guild Info text with our lines replaced by new ones; everything else is kept.
-- oneLine: the test Guild Info, whose lines may be written on one line with ";" between them
-- (/taverne dev info), like Parse reads it. Not the real one: its own text may hold a ";".
function Alliance.ReplaceLines(text, lines, oneLine)
    local kept = {}
    text = text or ""
    if oneLine then text = text:gsub(";", "\n") end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if not strtrim(line):match("^[Ll][Tt]:[GgKk]:") then kept[#kept + 1] = line end
    end
    while #kept > 0 and strtrim(kept[#kept]) == "" do kept[#kept] = nil end
    if #lines > 0 then
        if #kept > 0 then kept[#kept + 1] = "" end
        for _, line in ipairs(lines) do kept[#kept + 1] = line end
    end
    return table.concat(kept, "\n")
end

-- GuildUnion's setup lines ("GU:g:Exact Guild Name:TAG") in the real Guild Info, to import them.
function Alliance.ReadGuildUnion()
    local text = (GetGuildInfoText and GetGuildInfoText()) or ""
    local list = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name, tag = strtrim(line):match("^GU:g:(.+):([^:]+)$")
        if name then list[#list + 1] = { name = strtrim(name), tag = strtrim(tag) } end
    end
    return list
end

-- A guild name or tag that would break the lines.
function Alliance.ValidName(name)
    return type(name) == "string" and strtrim(name) ~= "" and not name:find("[;\n|]")
end

function Alliance.ValidTag(tag)
    return type(tag) == "string" and #strtrim(tag) >= 1 and #strtrim(tag) <= 6 and not tag:find("[:;\n|%s]")
end

-- Write the setup into the Guild Info (the fake one in sandbox). Returns ok, error text.
function Alliance:Save(guilds, key)
    local lines = Alliance.BuildLines(guilds, key)
    if ns.Guild:IsSandbox() then
        ns.db.dev.infoText = Alliance.ReplaceLines(ns.db.dev.infoText or "", lines, true)
        self:Refresh()
        return true
    end
    if not (CanEditGuildInfo and CanEditGuildInfo()) then
        return false, ns.L["You can't edit the Guild Info."]
    end
    if not SetGuildInfoText then
        return false, ns.L["The game doesn't let addons change the Guild Info here."]
    end
    local text = Alliance.ReplaceLines(GetGuildInfoText and GetGuildInfoText() or "", lines)
    if #text > Alliance.INFO_MAX then
        return false, ns.L["The Guild Info would be too long (%d / %d)."]:format(#text, Alliance.INFO_MAX)
    end
    SetGuildInfoText(text)
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    C_Timer.After(2, function() Alliance:Refresh() end)
    return true
end

-- Current setup as an editable copy: { guilds = { {name, tag, mine} }, key }.
function Alliance:GetDraft()
    local draft = { guilds = {}, key = config.key }
    local myName = ns.Guild:GetName()
    local hasMine = false
    for _, entry in ipairs(self:GetGuilds()) do
        local mine = ns.Guild:IsMyGuild(entry.name)
        hasMine = hasMine or mine
        table.insert(draft.guilds, mine and 1 or #draft.guilds + 1, { name = entry.name, tag = entry.tag, mine = mine })
    end
    if not hasMine and myName then
        local tag = myName:gsub("[^%w]", ""):sub(1, 3):upper()
        table.insert(draft.guilds, 1, { name = myName, tag = tag ~= "" and tag or "G1", mine = true })
    end
    return draft
end

-- The alliance is active when the info names a key and at least one other guild.
function Alliance:IsActive()
    if not config.key then return false end
    for lname in pairs(config.guilds) do
        if not ns.Guild:IsMyGuild(lname) then return true end
    end
    return false
end

-- Is this guild part of the alliance (and not our own guild)?
function Alliance:IsAllied(guildName)
    if type(guildName) ~= "string" or not self:IsActive() then return false end
    if ns.Guild:IsMyGuild(guildName) then return false end
    return config.guilds[strtrim(guildName):lower()] ~= nil
end

function Alliance:GetTag(guildName)
    local entry = type(guildName) == "string" and config.guilds[strtrim(guildName):lower()]
    return entry and entry.tag or nil
end

function Alliance:GetGuilds()
    local list = {}
    for _, entry in pairs(config.guilds) do list[#list + 1] = entry end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function Alliance:GetKey()
    return config.key
end

function Alliance.ChannelFor(key)
    return "LaTaverneA" .. Hash(key)
end

function Alliance.TestChannelFor(key)
    return "LaTaverneT" .. Hash(key)
end

-- Test mode: the test guild's channel key (LT:t line of the fake Guild Info), or nil.
function Alliance:GetTestKey()
    if not ns.Guild:IsSandbox() then return nil end
    return config.testKey
end

-- Test mode: the fake Guild Info with its LT:t line set to a new key.
function Alliance.WithNewTestKey(text)
    local kept = {}
    for line in ((text or ""):gsub(";", "\n") .. "\n"):gmatch("(.-)\r?\n") do
        if strtrim(line) ~= "" and not strtrim(line):match("^[Ll][Tt]:[Tt]:") then kept[#kept + 1] = line end
    end
    kept[#kept + 1] = "LT:t:" .. Alliance.NewKey()
    return table.concat(kept, "\n")
end

-- Re-read the Guild Info and follow any change (called at login and on guild updates).
function Alliance:Refresh()
    if not ns.Comm:IsLoggedIn() then return end
    if not ns.Guild:InGuild() then
        config = { guilds = {}, key = nil }
    else
        config = Alliance.Parse(ns.Guild:GetInfoText())
    end

    -- Test mode: follow the test guild's channel (joins, switches or leaves it).
    if ns.Guild:IsSandbox() then
        ns.Comm:JoinSandbox()
    else
        ns.Comm:LeaveChannel("sandbox")
    end

    local names = {}
    for lname, entry in pairs(config.guilds) do names[#names + 1] = lname .. "=" .. entry.tag end
    table.sort(names)
    local sig = table.concat(names, ",") .. "|" .. tostring(config.key) .. "|" .. tostring(self:IsActive())
    if sig == configSig then return end
    configSig = sig

    local current = ns.Comm:GetChannel("ally")
    if not self:IsActive() then
        if current then
            ns.Comm:LeaveChannel("ally")
            ns.Comm:LeaveChannel("allyOld")
            ns.Print(ns.L["Guild Alliance: off."])
        end
        Alliance:Changed()
        return
    end

    local name = Alliance.ChannelFor(config.key)
    if current and current.name ~= name then
        ns.Comm:RetireAllyChannel(OLD_CHANNEL_GRACE)
        ns.Print(ns.L["Guild Alliance: the key changed, switching channel."])
    end
    ns.Comm:JoinChannel("ally", name, config.key)
    Alliance:Changed()
end

-- Whoever shows the alliance (the window) hears when it's read or changes: the Guild Info is
-- only read a few seconds after login, so a window opened before that must update itself.
local listeners = {}
function Alliance:OnChange(fn) listeners[#listeners + 1] = fn end
function Alliance:Changed()
    for _, fn in ipairs(listeners) do fn() end
end

-- Has the Guild Info been read since login? (Before that, "not set up" would be wrong.)
function Alliance:IsLoaded()
    return ns.Comm:IsLoggedIn() -- Refresh reads it right when this turns true
end

function Alliance:OnLogin()
    ns.On("GUILD_ROSTER_UPDATE", function() Alliance:Refresh() end)
    ns.On("PLAYER_GUILD_UPDATE", function() Alliance:Refresh() end)
end

-- /taverne ally: what the addon understood from the Guild Info.
ns.commands.ally = function()
    local L = ns.Log
    wipe(ns.log)
    L("LaTaverne", ns.version, "alliance", date("%Y-%m-%d %H:%M:%S"))
    L("my guild", "[" .. tostring(ns.Guild:GetName()) .. "]", ns.Guild:IsSandbox() and "(fake, sandbox)" or "")
    local guilds = Alliance:GetGuilds()
    if #guilds == 0 then
        L("no LT:g: lines in the guild info")
    end
    for _, entry in ipairs(guilds) do
        L("guild", "[" .. entry.name .. "]", "tag", "[" .. entry.tag .. "]", ns.Guild:IsMyGuild(entry.name) and "(mine)" or "")
    end
    L("key", config.key and "set" or "missing", "active", Alliance:IsActive() and "yes" or "no")
    for _, role in ipairs({ "ally", "allyOld" }) do
        local ch = ns.Comm:GetChannel(role)
        if ch then
            L("channel", role, ch.name, "ready", ch.ready and "yes" or "no", ch.failed and "(join FAILED)" or "")
        end
    end
    local s = ns.AllyChat.stats
    L("allied chat", ns.db.allyChat.enabled and "on" or "off", "tag", ns.db.allyChat.showTag and "on" or "off",
        "lines shown: handler", s.handler, "chattynator", s.chattynator or 0, "tagged", s.tagged, "fallback", s.fallback,
        "guild window", ns.AllyChat:IsWindowHooked() and "hooked" or "not loaded yet", "saved lines", #ns.db.allyLog)
    if s.lastError then L("last handler error", s.lastError) end
    if ns.Vouch then ns.Vouch:Report(L) end

    local check = ns.Comm.lastAllyCheck
    if check then
        L("last allied message: target", "[" .. tostring(check.target) .. "]", "localID", tostring(check.localID),
            "channelName", "[" .. tostring(check.channelName) .. "]", "accepted", check.ok and "yes" or "no")
    end
    ns.ShowCopyWindow()
end
