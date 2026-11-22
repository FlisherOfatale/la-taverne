-- Diagnostics run in-game with /taverne test. Output goes to chat and to a copy window.
local ADDON, ns = ...
local L = ns.Log

local TEST_PREFIX = "TaverneT"
local TEST_CHANNEL = "TaverneTest"
local TEST_PASSWORD = "secretpw"

local function has(v) return v and "ok" or "MISSING" end
local function q(v) return "[" .. tostring(v) .. "]" end
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- 12.x game: chat and addon messages can be locked during a fight or an encounter.
local function Lockdown()
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not f then return "n/a" end
    local ok, on = pcall(f)
    if not ok then return "error" end
    return on and "yes" or "no"
end

local function TestEnv()
    L("== env ==")
    local version, build, buildDate, toc = GetBuildInfo()
    L("build", version, build, buildDate, "toc", toc)
    L("addon", ADDON, ns.version, "locale", GetLocale())
end

local function TestAPI()
    L("== api ==")
    L("C_ChatInfo.SendAddonMessage", has(C_ChatInfo and C_ChatInfo.SendAddonMessage))
    L("C_PartyInfo.InviteUnit", has(C_PartyInfo and C_PartyInfo.InviteUnit), "InviteUnit", has(InviteUnit))
    L("GetServerTime", has(GetServerTime), GetServerTime and GetServerTime(), "time()", time())
    L("C_Timer.After", has(C_Timer and C_Timer.After))
    L("JoinTemporaryChannel", has(JoinTemporaryChannel), "ChatFrame_RemoveChannel", has(ChatFrame_RemoveChannel))
    L("GetGuildInfoText", has(GetGuildInfoText), "C_GuildInfo", has(C_GuildInfo))
    L("C_LFGList", has(C_LFGList))
    L("C_AddOns", has(C_AddOns), "BackdropTemplate", has(BackdropTemplateMixin))
    L("Ambiguate", has(Ambiguate), "UnitFullName", has(UnitFullName))
    L("secret values (issecretvalue)", issecretvalue and "PRESENT" or "absent",
        "ChatFrameUtil.AddMessageEventFilter", has(ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter),
        "ChatFrame_MessageEventHandler", has(ChatFrame_MessageEventHandler))
    local cf = ChatFrame1
    L("chat frame handlers:", "ChatFrame1.MessageEventHandler", has(cf and cf.MessageEventHandler),
        "ChatFrame1.OnEvent script", has(cf and cf:GetScript("OnEvent")),
        "ChatFrame_OnEvent", has(ChatFrame_OnEvent), "ChatFrameMixin", has(ChatFrameMixin),
        "ChatFrameUtil.DisplayChatMessage", has(ChatFrameUtil and ChatFrameUtil.DisplayChatMessage))
    -- Positions on the map (AllyMap.lua)
    L("map:", "GetBestMapForUnit", has(C_Map and C_Map.GetBestMapForUnit),
        "GetPlayerMapPosition", has(C_Map and C_Map.GetPlayerMapPosition),
        "GetWorldPosFromMapPos", has(C_Map and C_Map.GetWorldPosFromMapPos),
        "GetMapPosFromWorldPos", has(C_Map and C_Map.GetMapPosFromWorldPos),
        "map pins", has(WorldMapFrame and WorldMapFrame.pinPools and MapCanvasDataProviderMixin and MapCanvasPinMixin),
        "OpenMapAPI", OpenMapAPI and ("v" .. tostring(OpenMapAPI.version)) or "absent")
    local m, x, y
    if ns.AllyMap then m, x, y = ns.AllyMap.Here() end
    L("map: my position", m and format("map %d, %.1f, %.1f", m, x * 100, y * 100) or "unknown (instance, secret, or the game won't say)")
end

local function TestNames()
    L("== names ==")
    local n, r = UnitName("player")
    L("UnitName", q(n), "realm", q(r))
    if UnitFullName then
        local a, b = UnitFullName("player")
        L("UnitFullName", q(a), q(b))
    end
    L("GetRealmName", q(GetRealmName()), "normalized", q(GetNormalizedRealmName and GetNormalizedRealmName()))
    if Ambiguate then
        L("Ambiguate none", q(Ambiguate(n, "none")), "short", q(Ambiguate(n, "short")))
    end
    if GetUnitName then
        L("GetUnitName player", q(GetUnitName("player", true)))
    end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local pn, pr = UnitName(unit)
            L(unit, "UnitName", q(pn), q(pr), "GetUnitName", q(GetUnitName and GetUnitName(unit, true)), "guild", q(GetGuildInfo(unit)))
        end
    end
    if UnitExists("target") and UnitIsPlayer("target") then
        local tn, tr = UnitName("target")
        L("target UnitName", q(tn), q(tr), "GetUnitName", q(GetUnitName and GetUnitName("target", true)))
        L("target guild", q(GetGuildInfo("target")), "UnitGUID", q(UnitGUID("target")))
    else
        L("target: none (target another player to test their name format)")
    end
end

local function TestGuild()
    L("== guild ==")
    L("IsInGuild", IsInGuild())
    if not IsInGuild() then return end
    local guildName, rankName, rankIndex = GetGuildInfo("player")
    L("guild", q(guildName), "rank", q(rankName), rankIndex)
    local text = (GetGuildInfoText and GetGuildInfoText()) or ""
    L("guild info length", #text, "has [Taverne tag", text:find("[Taverne", 1, true) and "yes" or "no")
    local guLines = 0
    for _ in text:gmatch("GU:g:") do guLines = guLines + 1 end
    L("GuildUnion community lines (GU:g:)", guLines, "channel line (GU:c:)", text:find("GU:c:", 1, true) and "yes" or "no")
    L("CanEditGuildInfo", CanEditGuildInfo and CanEditGuildInfo())
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
    local total, online = GetNumGuildMembers()
    L("members", total, "online", online)
    local me = UnitName("player")
    local found = false
    for i = 1, total or 0 do
        local name = GetGuildRosterInfo(i)
        if name and name:find(me, 1, true) == 1 then
            L("my roster name", q(name), "index", i)
            found = true
            break
        end
    end
    if not found then
        L("my roster name: not found, first roster entry", q(GetGuildRosterInfo(1)))
    end
end

-- Which Blizzard UI templates and helpers exist, to build windows that look like the default UI.
local function TestUI()
    L("== ui ==")
    local templates = {
        "ButtonFrameTemplate", "PortraitFrameTemplate", "DefaultPanelFlatTemplate", "InsetFrameTemplate",
        "UIPanelButtonTemplate", "UICheckButtonTemplate", "SearchBoxTemplate", "InputBoxTemplate",
        "PanelTabButtonTemplate", "TabSystemTemplate", "WowScrollBoxList", "MinimalScrollBar",
        "WowStyle1DropdownTemplate", "UIDropDownMenuTemplate", "UIPanelScrollFrameTemplate",
    }
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local missing = {}
        for _, name in ipairs(templates) do
            if C_XMLUtil.GetTemplateInfo(name) then
                L("template", name, "ok")
            else
                missing[#missing + 1] = name
            end
        end
        L("templates MISSING:", #missing > 0 and table.concat(missing, ", ") or "none")
    else
        L("C_XMLUtil.GetTemplateInfo MISSING (cannot list templates)")
    end
    L("ScrollBox helpers", has(CreateScrollBoxListLinearView), has(ScrollUtil), "DataProvider", has(CreateDataProvider))
    L("MenuUtil", has(MenuUtil), "UIDropDownMenu_Initialize", has(UIDropDownMenu_Initialize))
    L("Settings panel", has(Settings and Settings.RegisterCanvasLayoutCategory), "InterfaceOptions_AddCategory", has(InterfaceOptions_AddCategory))
    L("ButtonFrameTemplate_HidePortrait", has(ButtonFrameTemplate_HidePortrait), "SetPortraitToTexture", has(SetPortraitToTexture))
    L("chat filters", has(ChatFrame_AddMessageEventFilter), "SetItemRef", has(SetItemRef), "EventRegistry", has(EventRegistry))
    L("party", "ConvertToRaid", has(C_PartyInfo and C_PartyInfo.ConvertToRaid), "UninviteUnit", has(UninviteUnit), "C_PartyInfo.UninviteUnit", has(C_PartyInfo and C_PartyInfo.UninviteUnit))
    L("ERR_ALREADY_IN_GROUP_S", q(ERR_ALREADY_IN_GROUP_S), "ERR_DECLINE_GROUP_S", q(ERR_DECLINE_GROUP_S))
end

-- Dungeons known by the game's own group finder, with names in the client's language.
local function TestLFG()
    L("== lfg activities ==")
    if not (C_LFGList and C_LFGList.GetAvailableActivities) then
        L("C_LFGList.GetAvailableActivities MISSING")
        return
    end
    local ids = C_LFGList.GetAvailableActivities() or {}
    L("activities", #ids)
    for _, id in ipairs(ids) do
        local info = C_LFGList.GetActivityInfoTable and C_LFGList.GetActivityInfoTable(id)
        if info then
            L(id, q(info.fullName), "level", info.minLevel, info.maxLevel or info.maxLevelSuggestion,
                "players", info.maxNumPlayers, "category", info.categoryID)
        else
            L(id, "(no info)")
        end
    end
end

-- Hidden channel test --------------------------------------------------------

local listener

local function EnsureListener()
    if listener then return end
    C_ChatInfo.RegisterAddonMessagePrefix(TEST_PREFIX)
    listener = CreateFrame("Frame")
    listener:RegisterEvent("CHAT_MSG_ADDON")
    listener:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
        if prefix ~= TEST_PREFIX then return end
        L("RECV", channel, "from", q(sender), "msg", q(text))
    end)
end

local function HideChannel(name)
    if not ChatFrame_RemoveChannel then return false end
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, name) end
    end
    return true
end

-- Enum.SendAddonMessageResult values, for readable output.
local SEND_RESULTS = {
    [0] = "Success", "InvalidPrefix", "InvalidMessage", "AddonMessageThrottle", "InvalidChatType",
    "NotInGroup", "TargetRequired", "InvalidChannel", "ChannelThrottle", "GeneralError",
}

-- Sends on the test channel. A freshly joined channel can reject messages for a moment
-- (InvalidChannel), so retry a few times before giving up.
local function SendTest(text, attempt)
    attempt = attempt or 1
    local id = GetChannelName(TEST_CHANNEL)
    if not id or id == 0 then
        L("not in channel", TEST_CHANNEL, "- run /taverne test chan first")
        return
    end
    local result = C_ChatInfo.SendAddonMessage(TEST_PREFIX, text, "CHANNEL", id)
    local resultName = SEND_RESULTS[result] or "?"
    L("SEND chan", id, "attempt", attempt, "result", result, resultName, "msg", q(text))
    if result == 7 and attempt < 10 then
        C_Timer.After(0.5, function() SendTest(text, attempt + 1) end)
    end
end

local function TestChannel()
    L("== channel ==")
    EnsureListener()
    if GetChannelName(TEST_CHANNEL) == 0 then
        L("JoinTemporaryChannel returned", JoinTemporaryChannel(TEST_CHANNEL, TEST_PASSWORD))
    else
        L("already in channel")
    end
    local tries = 0
    local function WaitForJoin()
        tries = tries + 1
        local id = GetChannelName(TEST_CHANNEL)
        if id and id > 0 then
            L("joined", TEST_CHANNEL, "id", id, "after", tries, "checks")
            L("hidden from chat windows", HideChannel(TEST_CHANNEL))
            SendTest("ping from " .. UnitName("player"))
            C_Timer.After(3, function()
                L("== channel test done: a RECV line above means it works ==")
            end)
        elseif tries < 20 then
            C_Timer.After(0.25, WaitForJoin)
        else
            L("could not join", TEST_CHANNEL, "after 5 seconds")
        end
    end
    WaitForJoin()
end

-- Commands -------------------------------------------------------------------

local suites = {
    env = TestEnv,
    api = TestAPI,
    names = TestNames,
    guild = TestGuild,
    chan = TestChannel,
    ui = TestUI,
    lfg = TestLFG, -- not part of "all": long list
}
local order = { "env", "api", "names", "guild", "ui", "chan" }

ns.commands.test = function(arg)
    arg = (arg or ""):lower()
    if arg == "" then arg = "all" end
    if arg ~= "all" and not suites[arg] then
        ns.Print("unknown test '" .. arg .. "' - use all, env, api, names, guild, ui, chan or lfg")
        return
    end
    wipe(ns.log)
    L("LaTaverne", ns.version, "test", arg, date("%Y-%m-%d %H:%M:%S"))
    if arg == "all" then
        for _, key in ipairs(order) do suites[key]() end
    else
        suites[arg]()
    end
    ns.ShowCopyWindow()
end

ns.commands.ping = function(arg)
    EnsureListener()
    SendTest(arg ~= "" and arg or ("ping from " .. UnitName("player")))
    ns.ShowCopyWindow()
end

-- /taverne invite Firstname Lastname: checks which name format the invite accepts.
ns.commands.invite = function(arg)
    if arg == "" then
        ns.Print("usage: /taverne invite Firstname Lastname")
        return
    end
    wipe(ns.log)
    L("LaTaverne", ns.version, "invite test", date("%Y-%m-%d %H:%M:%S"))
    local ok, err = pcall(C_PartyInfo.InviteUnit, arg)
    L("C_PartyInfo.InviteUnit", q(arg), "ok", ok, "err", q(err))
    L("(did the other account get an invite? any error message on screen?)")
    ns.ShowCopyWindow()
end

-- /taverne who Firstname Lastname: looks the name up in the guild roster.
ns.commands.who = function(arg)
    if arg == "" then
        ns.Print("usage: /taverne who Firstname Lastname")
        return
    end
    wipe(ns.log)
    L("LaTaverne", ns.version, "roster lookup", q(arg), date("%Y-%m-%d %H:%M:%S"))
    if not IsInGuild() then
        L("not in a guild")
        ns.ShowCopyWindow()
        return
    end
    local needle = arg:lower()
    local total = GetNumGuildMembers()
    local hits = 0
    for i = 1, total or 0 do
        local name, rank, rankIndex, level, class, zone, _, _, online = GetGuildRosterInfo(i)
        if name and name:lower():find(needle, 1, true) then
            hits = hits + 1
            L(q(name), "rank", q(rank), rankIndex, "level", level, "class", class, "online", online and "yes" or "no")
            if hits >= 10 then L("(stopped at 10 matches)") break end
        end
    end
    if hits == 0 then L("no match in", total, "members") end
    ns.ShowCopyWindow()
end

-- /taverne chatwatch: logs, for each chat message received, whether its text and sender are
-- readable by addons ("secret" or not), with combat and instance state. Never logs the text itself.
local watcher
local WATCHED = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "CHAT_MSG_CHANNEL",
}

ns.commands.chatwatch = function()
    if watcher then
        watcher:UnregisterAllEvents()
        watcher = nil
        L("chat watch OFF")
        return
    end
    wipe(ns.log)
    L("LaTaverne", ns.version, "chat watch ON", date("%Y-%m-%d %H:%M:%S"), "- /taverne chatwatch again to stop")
    watcher = CreateFrame("Frame")
    for _, event in ipairs(WATCHED) do watcher:RegisterEvent(event) end
    watcher:SetScript("OnEvent", function(_, event, msg, sender)
        local msgSecret = issecretvalue and issecretvalue(msg)
        local senderSecret = issecretvalue and issecretvalue(sender)
        local _, instanceType = IsInInstance()
        L((event:gsub("CHAT_MSG_", "")),
            "text", msgSecret and "SECRET" or ("readable, " .. #msg .. " chars"),
            "sender", senderSecret and "SECRET" or "readable",
            "combat", InCombatLockdown() and "yes" or "no",
            "instance", instanceType or "none",
            "lockdown", Lockdown())
    end)
    ns.ShowCopyWindow()
end

function ns.IsChatWatching()
    return watcher ~= nil
end

ns.commands.copy = function()
    ns.ShowCopyWindow()
end

-- Relay probes ----------------------------------------------------------------------------------
-- What the guild relay (.plans/guild-relay.md, section 12) needs measured in game. /taverne probe
-- lists them. Most are switches: the same command again stops it. They write to the output
-- window only (/taverne probe show), never a chat line for each thing seen. Probe messages use
-- prefixes nobody else listens to (TaverneP, TaverneX1, TaverneX2): other players' addons never
-- see them. Guild lines are never written out, only an 8-digit fingerprint, so two PCs can match
-- the same line without copying it. Except my own lines in "lines", to see what the game changed.
local PROBE_PREFIX = "TaverneP"
local THROTTLE_PREFIX_1, THROTTLE_PREFIX_2 = "TaverneX1", "TaverneX2"
local PROBE_LOG_MAX = 1500

local probes = {} -- [name] = true while that switch is on

local function Raw(line)
    ns.log[#ns.log + 1] = line
    if #ns.log > PROBE_LOG_MAX then table.remove(ns.log, 1) end
    ns.UpdateCopyWindow()
end

-- A probe line, with the time.
local function Note(...)
    local parts = { date("%H:%M:%S") }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    Raw(table.concat(parts, " "))
end

-- A probe that breaks says so in its output, once per error, instead of an error popup each time.
local function Safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then Note("probe error:", err) end
    end
end

-- 8 hex digits for a text: the same text gives the same digits on every PC.
local function Fingerprint(text)
    if IsSecret(text) then return "SECRET" end
    if type(text) ~= "string" then return "-" end
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    -- In two halves: %x can't take a number this big everywhere.
    return format("%04x%04x", math.floor(h / 65536), h % 65536)
end

-- Big numbers (message numbers) written out in full.
local function Num(v)
    if type(v) == "number" then return format("%.0f", v) end
    return tostring(v)
end

local function Sent(r) return r == 0 or r == true end
local function ResultName(r)
    if type(r) == "number" then return (SEND_RESULTS[r] or "?") .. "(" .. r .. ")" end
    return tostring(r)
end

local function MyState()
    local _, kind = IsInInstance()
    return format("combat %s, %s, lockdown %s, restricted %s, away %s",
        (UnitAffectingCombat and UnitAffectingCombat("player")) and "yes" or "no",
        (kind and kind ~= "none") and kind or "outside", Lockdown(),
        ns.Guild:Restricted() and "yes" or "no", (UnitIsAFK and UnitIsAFK("player")) and "yes" or "no")
end

-- Where probe messages go: the alliance channel (what the relay will use), else the test guild's
-- channel (test mode), else the guild. Two PCs comparing must be on the same one.
local function ProbeRoute()
    for _, role in ipairs({ "ally", "sandbox" }) do
        local ch = ns.Comm:GetChannel(role)
        if ch and ch.ready then
            local id = GetChannelName(ch.name)
            if id and id > 0 then return "CHANNEL", id, role == "ally" and "alliance channel" or "test channel" end
        end
    end
    if not ns.Guild:IsSandbox() and IsInGuild() then return "GUILD", nil, "guild" end
    return nil, nil, "nowhere (no channel ready)"
end

local function SendProbe(prefix, text)
    local distribution, target, label = ProbeRoute()
    if not distribution then return nil, label end
    return C_ChatInfo.SendAddonMessage(prefix, text, distribution, target), label
end

-- Some events don't exist in every game version: registering one of those is an error.
local function Listen(frame, events)
    for _, event in ipairs(events) do pcall(frame.RegisterEvent, frame, event) end
end

-- beacon: every 2 s a numbered message with my state. Every PC running it writes what it hears
-- from the others: how late (server time, to the second), numbers missed, and their state. Also
-- one message at each fight start and end, loading screen, and 3 s after loading. Run it on two
-- PCs, then fight, zone, enter a dungeon with one of them. Only changes are written (and a line
-- every 30 s), not every message. It also receives the logout probe's message.
local BEACON_EVERY = 2
local BEACON_EVENTS = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ENCOUNTER_START", "ENCOUNTER_END",
    "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED", "PLAYER_ENTERING_WORLD" }
local beacon = { seq = 0, heard = {} }

-- kind: B (beacon), E (an event, named in extra), C (logout countdown, logout probe).
local function BeaconSend(kind, extra)
    local state = MyState()
    local r, label = SendProbe(PROBE_PREFIX, table.concat({ kind, beacon.seq, GetServerTime(), state, extra or "" }, ";"))
    return r, label, state
end

local function BeaconTick()
    beacon.seq = beacon.seq + 1
    local r, label, state = BeaconSend("B")
    local now = GetTime()
    if not Sent(r) or state ~= beacon.lastState or now - (beacon.lastLogged or 0) >= 30 then
        Note("out #" .. beacon.seq, "via", label, Sent(r) and "sent" or ResultName(r), "- me:", state)
        beacon.lastState, beacon.lastLogged = state, now
    end
end

local function BeaconEvent(event)
    local r, label, state = BeaconSend("E", event)
    Note("out", event, "via", label, Sent(r) and "sent" or ResultName(r), "- me:", state)
end

local function BeaconHeard(prefix, text, _, sender)
    if prefix ~= PROBE_PREFIX or IsSecret(text) or IsSecret(sender) or type(text) ~= "string"
        or type(sender) ~= "string" or ns.IsMe(sender) then return end
    local kind, seq, sent, state, extra = strsplit(";", text)
    seq, sent = tonumber(seq), tonumber(sent)
    if not seq or not sent then return end
    local late = GetServerTime() - sent
    if kind ~= "B" then
        Note("in", sender, (extra and extra ~= "") and extra or kind, late .. " s late", "- them:", tostring(state))
        return
    end
    local h = beacon.heard[sender]
    if not h then
        h = {}
        beacon.heard[sender] = h
    end
    local gap = h.seq and (seq - h.seq - 1) or 0
    local now = GetTime()
    if not h.seq or gap ~= 0 or late >= 3 or state ~= h.state or now - (h.logged or 0) >= 30 then
        local what = gap > 0 and ("MISSED " .. gap) or (gap < 0 and "(restarted)" or "")
        Note("in #" .. seq, sender, late .. " s late", what, "- them:", tostring(state))
        h.logged = now
    end
    h.seq, h.state = seq, state
end

local function BeaconStart()
    C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
    beacon.frame = beacon.frame or CreateFrame("Frame")
    beacon.frame:RegisterEvent("CHAT_MSG_ADDON")
    Listen(beacon.frame, BEACON_EVENTS)
    beacon.frame:SetScript("OnEvent", Safe(function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            BeaconHeard(...)
            return
        end
        BeaconEvent(event)
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(3, Safe(function() if probes.beacon then BeaconEvent("3 s after loading") end end))
        end
    end))
    beacon.seq, beacon.lastState, beacon.lastLogged = 0, nil, 0
    wipe(beacon.heard)
    local _, _, label = ProbeRoute()
    Note("beacon on: a message every", BEACON_EVERY, "s via", label, "- me:", MyState())
    beacon.ticker = C_Timer.NewTicker(BEACON_EVERY, Safe(BeaconTick))
end

local function BeaconStop()
    if beacon.ticker then beacon.ticker:Cancel() beacon.ticker = nil end
    if beacon.frame then beacon.frame:UnregisterAllEvents() end
    Note("beacon off after #" .. beacon.seq)
end

-- lines: each guild line, with what could recognize the same line on another PC: the game's line
-- number, the guild community's message number (epoch, position), a fingerprint of the text and
-- of its cleaned-up key (AllyChat.TextKey). Run it on two PCs and type a few lines (an item link,
-- %t with a target, extra spaces): the same line should show the same fingerprints, maybe the
-- same message number. My own lines are also compared with what I typed.
local lines = { mine = {}, hooked = false }

local function NoteMyLine(text, chatType)
    if not probes.lines or IsSecret(text) or type(text) ~= "string" or type(chatType) ~= "string" then return end
    if chatType:upper() ~= "GUILD" then return end
    local last = lines.mine[#lines.mine]
    if last and last.text == text and GetTime() - last.t < 0.2 then return end -- both send hooks, one line
    lines.mine[#lines.mine + 1] = { text = text, t = GetTime() }
    if #lines.mine > 5 then table.remove(lines.mine, 1) end
end

local function HookMyLines()
    if lines.hooked then return end
    lines.hooked = true
    if SendChatMessage then hooksecurefunc("SendChatMessage", NoteMyLine) end
    if C_ChatInfo and C_ChatInfo.SendChatMessage then hooksecurefunc(C_ChatInfo, "SendChatMessage", NoteMyLine) end
    -- Typed in the guild window: the community API (its guild stream, not the officers' one).
    if C_Club and C_Club.SendMessage and C_Club.GetGuildClubId then
        hooksecurefunc(C_Club, "SendMessage", function(clubId, streamId, text)
            if not probes.lines then return end
            local ok, guildClub = pcall(C_Club.GetGuildClubId)
            if not ok or not guildClub or clubId ~= guildClub then return end
            local ok2, info = pcall(C_Club.GetStreamInfo, clubId, streamId)
            if Enum.ClubStreamType and not (ok2 and info and info.streamType == Enum.ClubStreamType.Guild) then return end
            NoteMyLine(text, "GUILD")
        end)
    end
end

local function Shown(text) return (text:gsub("|", "||")) end

local function OnGuildLine(text, author, _, _, _, _, _, _, _, _, lineID, guid)
    local key = (not IsSecret(text)) and ns.AllyChat.TextKey(text) or nil
    Note("guild line #" .. Num(lineID), "from", IsSecret(author) and "SECRET" or tostring(author),
        "text", Fingerprint(text), "key", Fingerprint(key),
        IsSecret(text) and "" or (#text .. " bytes"), "guid", IsSecret(guid) and "SECRET" or (guid and "yes" or "no"))
    if IsSecret(text) or IsSecret(author) or type(author) ~= "string" or not ns.IsMe(author) then return end
    -- My own line, back from the server: what I typed, the same once cleaned up, or different?
    local now, newest = GetTime(), nil
    for i = #lines.mine, 1, -1 do
        local mine = lines.mine[i]
        if now - mine.t <= 10 then
            newest = newest or mine
            if mine.text == text then
                table.remove(lines.mine, i)
                Note("  my line: the same as typed")
                return
            end
            if ns.AllyChat.TextKey(mine.text) == key then
                table.remove(lines.mine, i)
                Note("  my line: the same once cleaned up. Typed:", Shown(mine.text), "Received:", Shown(text))
                return
            end
        end
    end
    if newest then
        Note("  my line: DIFFERENT. Last typed:", Shown(newest.text), "Received:", Shown(text))
    else
        Note("  my line: nothing typed in the last 10 s (typed before the probe started?)")
    end
end

local function OnClubMessage(clubId, streamId, messageId)
    if not (C_Club and C_Club.GetGuildClubId) then return end
    local ok, guildClub = pcall(C_Club.GetGuildClubId)
    if not ok or not guildClub or clubId ~= guildClub then return end
    local epoch = type(messageId) == "table" and messageId.epoch or nil
    local position = type(messageId) == "table" and messageId.position or nil
    local okInfo, info = pcall(C_Club.GetMessageInfo, clubId, streamId, messageId)
    if not okInfo or type(info) ~= "table" then
        Note("  community message", Num(epoch), Num(position), "stream", Num(streamId), "(no details: " .. tostring(info) .. ")")
        return
    end
    if not lines.fieldsShown then
        lines.fieldsShown = true
        local keys = {}
        for k, v in pairs(info) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
        table.sort(keys)
        Note("  (community message fields: " .. table.concat(keys, ", ") .. ")")
    end
    local author = type(info.author) == "table" and info.author.name or nil
    local content = info.content
    Note("  community message epoch", Num(epoch), "position", Num(position), "stream", Num(streamId),
        "from", IsSecret(author) and "SECRET" or tostring(author), "text", Fingerprint(content),
        "key", Fingerprint((not IsSecret(content)) and ns.AllyChat.TextKey(content) or nil))
end

local function LinesStart()
    HookMyLines()
    wipe(lines.mine)
    lines.fieldsShown = false
    lines.frame = lines.frame or CreateFrame("Frame")
    Listen(lines.frame, { "CHAT_MSG_GUILD", "CLUB_MESSAGE_ADDED" })
    lines.frame:SetScript("OnEvent", Safe(function(_, event, ...)
        if event == "CHAT_MSG_GUILD" then OnGuildLine(...) else OnClubMessage(...) end
    end))
    Note("lines on. Community message details:", has(C_Club and C_Club.GetMessageInfo))
end

local function LinesStop()
    if lines.frame then lines.frame:UnregisterAllEvents() end
    Note("lines off")
end

-- throttle: how many addon messages the game lets through. 15 at once on one prefix, then 15 at
-- once on a second prefix (a limit per prefix, or shared?), then both side by side every 0.5 s
-- for 8 s (how fast it comes back). Code 3 = the prefix's limit, 8 = the channel's. Nobody
-- receives these; La Taverne's own messages may wait a few seconds after it.
local throttleRunning = false

local function ThrottleRun()
    if throttleRunning then
        ns.Print("the throttle probe is already running")
        return
    end
    local distribution, target, label = ProbeRoute()
    if not distribution then
        Note("throttle: no channel to send on:", label)
        return
    end
    throttleRunning = true
    Note("throttle via", label, "- me:", MyState())
    local function Burst(prefix, from)
        local out = {}
        for i = 1, 15 do
            local r = C_ChatInfo.SendAddonMessage(prefix, "t" .. (from + i), distribution, target)
            out[#out + 1] = Sent(r) and "ok" or ResultName(r)
        end
        return table.concat(out, " ")
    end
    Note("15 at once, prefix 1:", Burst(THROTTLE_PREFIX_1, 0))
    Note("15 at once, prefix 2:", Burst(THROTTLE_PREFIX_2, 100))
    local round, start = 0, GetTime()
    C_Timer.NewTicker(0.5, Safe(function()
        round = round + 1
        local r1 = C_ChatInfo.SendAddonMessage(THROTTLE_PREFIX_1, "s" .. round, distribution, target)
        local r2 = C_ChatInfo.SendAddonMessage(THROTTLE_PREFIX_2, "s" .. round, distribution, target)
        Note(format("+%.1f s", GetTime() - start), "prefix 1:", Sent(r1) and "ok" or ResultName(r1),
            "prefix 2:", Sent(r2) and "ok" or ResultName(r2))
        if round >= 16 then
            throttleRunning = false
            Note("throttle done")
        end
    end), 16)
end

-- logout: what happens when I log out, or the game logs me out for being idle (about 30 min
-- without touching anything): which events fire, when, and whether a message still goes out
-- (a PC running "beacon" shows it). Saved, since the session ends: log back in and run it again
-- to see what happened (that also starts a new one).
local LOGOUT_EVENTS = { "PLAYER_FLAGS_CHANGED", "PLAYER_CAMPING", "PLAYER_QUITING", "LOGOUT_CANCEL", "PLAYER_LOGOUT" }
local logout = {}

local function IsAway() return (UnitIsAFK and UnitIsAFK("player")) and true or false end

local function LogoutNote(text)
    local record = ns.db.probeLogout
    if record then record.events[#record.events + 1] = date("%H:%M:%S") .. " " .. text end
    Note("logout:", text)
end

local function LogoutEvent(event, unit)
    if event == "PLAYER_FLAGS_CHANGED" then
        if unit ~= "player" then return end
        local away = IsAway()
        if away == logout.away then return end
        logout.away = away
        LogoutNote(away and "away (AFK) on" or "away (AFK) off")
    elseif event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        local r, label = BeaconSend("C", event)
        LogoutNote(format("%s, message %s via %s - me: %s", event, Sent(r) and "sent" or ResultName(r), label, MyState()))
    else
        LogoutNote(event)
    end
end

local function LogoutStart()
    local old = ns.db.probeLogout
    if old and type(old.events) == "table" and #old.events > 0 then
        Note("logout: last time (started " .. tostring(old.started) .. "):")
        for _, line in ipairs(old.events) do Raw("    " .. line) end
    end
    ns.db.probeLogout = { started = date("%Y-%m-%d %H:%M:%S"), events = {} }
    logout.away = IsAway()
    logout.frame = logout.frame or CreateFrame("Frame")
    Listen(logout.frame, LOGOUT_EVENTS)
    logout.frame:SetScript("OnEvent", Safe(function(_, event, unit) LogoutEvent(event, unit) end))
    LogoutNote("started - me: " .. MyState())
end

local function LogoutStop()
    if logout.frame then logout.frame:UnregisterAllEvents() end
    LogoutNote("stopped")
end

-- What the logout probe saved last session: said once after logging back in.
ns.On("PLAYER_LOGIN", function()
    local record = ns.db and ns.db.probeLogout
    if record and type(record.events) == "table" and #record.events > 0 and not record.told then
        record.told = true
        ns.Print(format("logout probe: %d things saved last session. /taverne probe logout shows them (and starts again).", #record.events))
    end
end)

-- rest: where the game counts me as resting (IsResting: cities and inns, "city" for the relay),
-- written at each change of zone, sub-zone or resting. Walk through each city.
local rest = {}

local function PlaceText()
    local _, kind = IsInInstance()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return format("%s / %s (map %s, %s): resting %s", GetZoneText() or "?", GetSubZoneText() or "",
        IsSecret(map) and "SECRET" or tostring(map), (kind and kind ~= "none") and kind or "outside",
        IsResting() and "YES" or "no")
end

local function RestCheck()
    local text = PlaceText()
    if text ~= rest.last then
        rest.last = text
        Note(text)
    end
end

local function RestStart()
    rest.frame = rest.frame or CreateFrame("Frame")
    Listen(rest.frame, { "PLAYER_UPDATE_RESTING", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS" })
    rest.frame:SetScript("OnEvent", Safe(RestCheck))
    rest.last = nil
    Note("rest on")
    RestCheck()
end

local function RestStop()
    if rest.frame then rest.frame:UnregisterAllEvents() end
    Note("rest off")
end

local PROBES = {
    { name = "lines", start = LinesStart, stop = LinesStop,
      about = "guild lines: line and message numbers, fingerprints (two PCs in one guild)" },
    { name = "beacon", start = BeaconStart, stop = BeaconStop,
      about = "a message every 2 s: late, lost or held in fights, loading screens, dungeons (two PCs)" },
    { name = "throttle", run = ThrottleRun,
      about = "how many messages go out at once, per prefix (runs once, 10 s)" },
    { name = "logout", start = LogoutStart, stop = LogoutStop,
      about = "events and messages at logout and idle logout (saved; a PC running beacon sees the message)" },
    { name = "rest", start = RestStart, stop = RestStop,
      about = "where the game counts me as resting (walk through the cities)" },
}

-- /taverne probe [name | show | stop | clear]
ns.commands.probe = function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "show" then
        ns.ShowCopyWindow()
        return
    end
    if arg == "clear" then
        wipe(ns.log)
        ns.db.probeLogout = nil
        ns.UpdateCopyWindow()
        ns.Print("probe output cleared")
        return
    end
    if arg == "stop" then
        for _, p in ipairs(PROBES) do
            if probes[p.name] then
                probes[p.name] = nil
                p.stop()
            end
        end
        ns.Print("probes stopped: /taverne probe show")
        return
    end
    local probe
    for _, p in ipairs(PROBES) do
        if p.name == arg then probe = p end
    end
    if not probe then
        ns.Print("relay probes: /taverne probe <name> (again to stop), show, stop, clear")
        for _, p in ipairs(PROBES) do
            ns.Print(format("  %s%s - %s", p.name, probes[p.name] and " (ON)" or "", p.about))
        end
        return
    end
    if probe.run then
        Note("La Taverne", ns.version, probe.name, date("%Y-%m-%d"))
        probe.run()
        ns.ShowCopyWindow()
        return
    end
    if probes[probe.name] then
        probes[probe.name] = nil
        probe.stop()
        ns.Print(probe.name .. " probe off: /taverne probe show")
        ns.ShowCopyWindow()
    else
        probes[probe.name] = true
        Note("La Taverne", ns.version, probe.name, date("%Y-%m-%d"))
        probe.start()
        ns.Print(probe.name .. " probe on: /taverne probe " .. probe.name .. " again to stop, /taverne probe show to see it")
    end
end
