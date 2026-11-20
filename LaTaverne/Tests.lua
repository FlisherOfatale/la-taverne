-- Diagnostics run in-game with /taverne test. Output goes to chat and to a copy window.
local ADDON, ns = ...
local L = ns.Log

local TEST_PREFIX = "TaverneT"
local TEST_CHANNEL = "TaverneTest"
local TEST_PASSWORD = "secretpw"

local function has(v) return v and "ok" or "MISSING" end
local function q(v) return "[" .. tostring(v) .. "]" end

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
    local m, x, y = ns.AllyMap and ns.AllyMap.Here()
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
            "instance", instanceType or "none")
    end)
    ns.ShowCopyWindow()
end

function ns.IsChatWatching()
    return watcher ~= nil
end

ns.commands.copy = function()
    ns.ShowCopyWindow()
end
