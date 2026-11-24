-- Allied guilds, set up by the officers in the Guild Info text (the fake one in sandbox).
--
-- The same lines go in the Guild Info of every guild of the alliance:
--   LT:g:Exact Guild Name:TAG     one line per guild, ours included (TAG = short marker shown in chat)
--   LT:k:key                      shared secret, letters and digits
--   LT:t:key                      test mode only: the test guild's own hidden channel (each test
--                                 guild picks its key, so testers elsewhere never share a channel)
--   LT:ai:0,1,3   or   LT:ai:off  who may use auto-invite: these ranks (0 = guild master), or
--                                 nobody. No line: everyone. Each guild's own, alliance or not.
--   LT:r:off   or   LT:r:chat     the guild relay (Relay.lua): nothing relayed, or only these
--                                 jobs. No line: every job. Each guild's own, like LT:ai.
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
local infoPending = false -- the Guild Info couldn't be read (game restriction): read it again after
local infoKnown = false   -- read once since login (or the setup saved last time is used)

-- The last setup read from the real Guild Info, saved per character: used when the game blocks
-- reading it at login or after a /reload (in a dungeon, in combat), until it can be read again.
local function SavedSetup()
    local key = ns.FullName("player")
    ns.db.chars[key] = ns.db.chars[key] or {}
    return ns.db.chars[key]
end

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

-- "off" -> "off"; "0,1,3" -> { [0] = true, [1] = true, [3] = true }; anything else: nil (everyone).
function Alliance.ParseAutoInvite(rule)
    rule = strtrim(rule or ""):lower()
    if rule == "off" then return "off" end
    local ranks, any = {}, false
    for n in rule:gmatch("%d+") do
        ranks[tonumber(n)] = true
        any = true
    end
    return any and ranks or nil
end

-- The LT:ai line for a rule (nil: no line, everyone).
function Alliance.AutoInviteLine(rule)
    if rule == "off" then return "LT:ai:off" end
    if type(rule) ~= "table" then return nil end
    local list = {}
    for rank in pairs(rule) do list[#list + 1] = rank end
    table.sort(list)
    if #list == 0 then return "LT:ai:off" end
    return "LT:ai:" .. table.concat(list, ",")
end

-- The guild relay (Relay.lua), each guild's own line, for its own members:
--   no line          every job relayed (guild chat, and later map positions...)
--   LT:r:off         nothing relayed
--   LT:r:chat        only these jobs (comma-separated)
-- "off" -> "off"; "chat,map" -> { chat = true, map = true }; "on", "all" or no job named: nil
-- (every job).
function Alliance.ParseRelay(rule)
    rule = strtrim(rule or ""):lower()
    if rule == "off" then return "off" end
    if rule == "on" or rule == "all" then return nil end
    local jobs, any = {}, false
    for job in rule:gmatch("%a+") do
        jobs[job] = true
        any = true
    end
    return any and jobs or nil
end

-- Does a relay rule (nil, "off" or { [job] = true }) let this job be relayed?
function Alliance.RelayRuleAllows(rule, job)
    if rule == "off" then return false end
    if type(rule) == "table" then return rule[job] == true end
    return true
end

-- A new rule with one job switched on or off (the Setup page; rule itself isn't changed). known:
-- the jobs this version has. None left: "off". Every known job on: no line, unless the rule
-- already listed its jobs (it may hold jobs of a newer version, kept as they were).
function Alliance.RelayRuleWith(rule, job, on, known)
    local jobs, listed = {}, type(rule) == "table"
    if listed then
        for j, v in pairs(rule) do jobs[j] = v and true or nil end
    elseif rule ~= "off" then
        for _, j in ipairs(known) do jobs[j] = true end
    end
    jobs[job] = on and true or nil
    if next(jobs) == nil then return "off" end
    if listed then return jobs end
    for _, j in ipairs(known) do
        if not jobs[j] then return jobs end
    end
    return nil
end

-- The LT:r line for a rule (nil: no line, every job).
function Alliance.RelayLine(rule)
    if rule == "off" then return "LT:r:off" end
    if type(rule) ~= "table" then return nil end
    local list = {}
    for job, on in pairs(rule) do
        if on then list[#list + 1] = job end
    end
    table.sort(list)
    if #list == 0 then return "LT:r:off" end
    return "LT:r:" .. table.concat(list, ",")
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
            local rule = line:match("^[Ll][Tt]:[Aa][Ii]:(.+)$")
            if rule then result.autoInvite = Alliance.ParseAutoInvite(rule) end
            local relay = line:match("^[Ll][Tt]:[Rr]:(.+)$")
            if relay then result.relay = Alliance.ParseRelay(relay) end
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

-- Setup lines for a list of { name, tag } and a key (what Export sends to the allied guilds).
function Alliance.BuildLines(guilds, key)
    local lines = {}
    for _, entry in ipairs(guilds) do
        lines[#lines + 1] = "LT:g:" .. entry.name .. ":" .. entry.tag
    end
    if key then lines[#lines + 1] = "LT:k:" .. key end
    return lines
end

-- All of La Taverne's lines for my Guild Info: the alliance's (only with an allied guild: a
-- guild alone needs none, not even a key), then who may use auto-invite (see GetAutoInvite),
-- then what the guild relay may pass on (relayRule, see GetRelayRule).
function Alliance.InfoLines(guilds, key, rule, relayRule)
    local others = 0
    for _, entry in ipairs(guilds) do
        if not ns.Guild:IsMyGuild(entry.name) then others = others + 1 end
    end
    local lines = others > 0 and Alliance.BuildLines(guilds, key) or {}
    local ai = Alliance.AutoInviteLine(rule)
    if ai then lines[#lines + 1] = ai end
    local relay = Alliance.RelayLine(relayRule)
    if relay then lines[#lines + 1] = relay end
    return lines
end

-- The Guild Info text with our lines (LT:g, LT:k, LT:ai, LT:r) replaced by new ones; everything
-- else is kept. oneLine: the test Guild Info, whose lines may be written on one line with ";"
-- between them (/taverne dev info), like Parse reads it. Not the real one: its own text may
-- hold a ";".
local function Ours(line)
    line = strtrim(line)
    return line:match("^[Ll][Tt]:[GgKk]:") ~= nil or line:match("^[Ll][Tt]:[Aa][Ii]:") ~= nil
        or line:match("^[Ll][Tt]:[Rr]:") ~= nil
end

function Alliance.ReplaceLines(text, lines, oneLine)
    local kept = {}
    text = text or ""
    if oneLine then text = text:gsub(";", "\n") end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if not Ours(line) then kept[#kept + 1] = line end
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
    if ns.Guild:Restricted() then return {} end
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

-- Save the setup: the alliance (guilds, key), who may use auto-invite (rule) and what the guild
-- relay may pass on (relayRule). The game forbids addons to change the Guild Info
-- (SetGuildInfoText is protected), so this returns the whole new Guild Info text for the officer
-- to paste: ok, error text, text to paste. Test mode does the same with the test Guild Info
-- (pasted in the test guild window), so the officer's steps can be tried.
function Alliance:Save(guilds, key, rule, relayRule)
    local lines = Alliance.InfoLines(guilds, key, rule, relayRule)
    if ns.Guild:IsSandbox() then
        local text = Alliance.ReplaceLines(ns.db.dev.infoText or "", lines, true)
        if #text > Alliance.INFO_MAX then
            return false, ns.L["The Guild Info would be too long (%d / %d)."]:format(#text, Alliance.INFO_MAX)
        end
        return true, nil, text
    end
    if not (CanEditGuildInfo and CanEditGuildInfo()) then
        return false, ns.L["You can't edit the Guild Info."]
    end
    -- A blocked read comes back empty: the text to paste would lose the rest of the Guild Info.
    if ns.Guild:Restricted() then
        return false, ns.L["The game blocks the Guild Info right now (combat or boss). Try again in a moment."]
    end
    local text = Alliance.ReplaceLines(GetGuildInfoText and GetGuildInfoText() or "", lines)
    if #text > Alliance.INFO_MAX then
        return false, ns.L["The Guild Info would be too long (%d / %d)."]:format(#text, Alliance.INFO_MAX)
    end
    return true, nil, text
end

-- Who may use auto-invite: nil (everyone), "off", or { [rankIndex] = true }.
function Alliance:GetAutoInvite()
    return config.autoInvite
end

-- My guild's relay line (LT:r): nil (every job), "off", or { [job] = true }.
function Alliance:GetRelayRule()
    return config.relay
end

-- May this job be relayed for my guild? Never before the Guild Info was read once: the officers
-- may have turned it off.
function Alliance:RelayAllows(job)
    if not infoKnown then return false end
    return Alliance.RelayRuleAllows(config.relay, job)
end

function Alliance:IsInfoKnown()
    return infoKnown
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

local ownLinesSig = "nil|nil"
-- Turning the alliance off waits for a second read: a read that comes back without it (an empty
-- Guild Info during a loading screen, the guild for a moment not known) isn't the officers
-- removing it. OFF_CONFIRM seconds later, still off: then it's off.
local OFF_CONFIRM = 5
local offSince      -- when a read first came back without the alliance (waiting to confirm)
local saidOff       -- "Guild Alliance: off." was said: say when it's back on
local emptyRetry    -- the Guild Info came back empty: a new read is on its way

-- Does this setup link us to another guild (a key and a guild that isn't mine)?
local function ActiveIn(cfg)
    if not cfg.key then return false end
    for lname in pairs(cfg.guilds) do
        if not ns.Guild:IsMyGuild(lname) then return true end
    end
    return false
end

-- Re-read the Guild Info and follow any change (called at login and on guild updates).
function Alliance:Refresh()
    if not ns.Comm:IsLoggedIn() then return end
    local read -- the setup just read (nil: nothing new read)
    if not ns.Guild:InGuild() then
        read = { guilds = {}, key = nil }
    else
        local text = ns.Guild:GetInfoText()
        -- An empty Guild Info: not loaded yet (after a login or /reload, until the game gets the
        -- guild's data; opening the game's guild window does it). Not a real one: those aren't
        -- empty. Ask the game for it and read again shortly; meanwhile, the setup saved last time.
        -- (Test mode's made-up Guild Info can be empty for real.)
        if text == "" and not ns.Guild:IsSandbox() then
            text = nil
            if not emptyRetry then
                emptyRetry = true
                if ns.Guild.RequestRoster then ns.Guild.RequestRoster() end
                C_Timer.After(3, function()
                    emptyRetry = false
                    Alliance:Refresh()
                end)
            end
        end
        if text then
            infoPending = false
            read = Alliance.Parse(text)
        else
            -- Blocked for now: keep the current setup (and channel) instead of turning it off.
            infoPending = true
            -- Nothing read yet since login: use the setup saved last time, if it's the same guild.
            local saved = SavedSetup().alliance
            if configSig ~= "" or not saved or not saved.guild or saved.guild ~= ns.Guild:GetName() then return end
            config = { guilds = saved.guilds or {}, key = saved.key, autoInvite = saved.autoInvite, relay = saved.relay }
            infoKnown = true
        end
    end
    if read then
        -- Linked until now, and this read says no: read again in a moment before believing it.
        if ActiveIn(config) and not ActiveIn(read) then
            -- (An offSince from long ago, its second read blocked meanwhile, doesn't count: start over.)
            if not offSince or GetTime() - offSince > OFF_CONFIRM * 3 then
                offSince = GetTime()
                C_Timer.After(OFF_CONFIRM + 0.5, function() Alliance:Refresh() end)
                return
            end
            if GetTime() - offSince < OFF_CONFIRM then return end
        end
        offSince = nil
        config = read
        infoKnown = true
        if ns.Guild:InGuild() and not ns.Guild:IsSandbox() then
            SavedSetup().alliance = { guild = ns.Guild:GetName(), guilds = config.guilds, key = config.key,
                autoInvite = config.autoInvite, relay = config.relay }
        end
    end

    -- My guild's own lines changed (who may use auto-invite, what the relay may pass on): tell
    -- the window and auto-invite (not the channel's business; Relay.lua checks every second).
    local ownSig = tostring(Alliance.AutoInviteLine(config.autoInvite)) .. "|" .. tostring(Alliance.RelayLine(config.relay))
    if ownSig ~= ownLinesSig then
        ownLinesSig = ownSig
        Alliance:Changed()
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
            saidOff = true
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
    if saidOff then
        saidOff = nil
        ns.Print(ns.L["Guild Alliance: on again."])
    end
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
    -- Read the Guild Info again once a restriction is over (the event comes right before or
    -- after the change, so look a moment later).
    local function Retry()
        if not infoPending then return end
        C_Timer.After(1, function()
            if infoPending and not ns.Guild:Restricted() then Alliance:Refresh() end
        end)
    end
    if C_RestrictedActions then ns.On("ADDON_RESTRICTION_STATE_CHANGED", Retry) end
    ns.On("PLAYER_REGEN_ENABLED", Retry)
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
            L("channel", role, ch.name, "ready", ch.ready and "yes" or "no", ch.failed and "(join FAILED)" or "",
                "in the server's list", ns.Comm:ChannelListed(ch), "rejoins", ch.rejoins or 0)
        end
    end
    L("alliance channel health", ns.Comm:AllyHealthText())
    local s = ns.AllyChat.stats
    L("allied chat", ns.AllyChat.Enabled() and "on" or "off", "GuildUnion", ns.AllyChat:CanTurnOff() and "loaded" or "no", "tag", ns.db.allyChat.showTag and "on" or "off", "lynx", ns.db.allyChat.showLynx ~= false and "on" or "off",
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
