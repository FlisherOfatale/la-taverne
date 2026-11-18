-- Allied guild chat: guild chat shared with the allied guilds, as if it were one guild.
--
-- Sending (author relay): what I type in guild chat goes to my guild as usual, and my addon
-- also sends it to the allied guilds on the alliance channel. Nobody relays for anybody else.
-- Showing: allied lines are fed to the chat windows that show guild chat, through the chat
-- window's own guild message handler (same color, timestamps, clickable name), with the
-- allied guild's tag in front of the name. They also go in the guild window's chat.
--
-- Sandbox: the real guild chat is never read nor relayed. "/taverne g <text>" stands in for
-- typing in guild chat: it goes to the fake guild (test channel) and to the allied guilds.
--
-- The guild window part follows GuildUnion's BlizzTab.lua (MIT, by Sadance): keep our lines
-- and put them back, in time order, each time the window rebuilds its chat.
local ADDON, ns = ...
local AllyChat = ns.NewModule("AllyChat")
local L = ns.L

local LOG_MAX = 200
local LOG_AGE = 48 * 3600
local TAG_COLOR = "|cff8fb8e8"

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

local function Enabled()
    return ns.db and ns.db.allyChat.enabled
end

-- Log of allied lines (saved per account, used for the guild window) -----------------------

local function Prune()
    local log = ns.db.allyLog
    local oldest = GetServerTime() - LOG_AGE
    while #log > 0 and (#log > LOG_MAX or (log[1].t or 0) < oldest) do
        table.remove(log, 1)
    end
end

-- Chat windows -----------------------------------------------------------------------------

local function UsingChattynator()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return loaded and loaded("Chattynator") and true or false
end

-- Chat windows that show guild chat. With Chattynator, only the main one: it's the one it collects.
local function GuildFrames()
    if UsingChattynator() then return { DEFAULT_CHAT_FRAME } end
    local frames = {}
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.messageTypeList then
            for _, group in ipairs(frame.messageTypeList) do
                if group == "GUILD" then
                    frames[#frames + 1] = frame
                    break
                end
            end
        end
    end
    if #frames == 0 then frames[1] = DEFAULT_CHAT_FRAME end
    return frames
end

local function TagText(tag)
    if not tag or not ns.db.allyChat.showTag then return "" end
    return TAG_COLOR .. "[" .. tag .. "]|r "
end

local function ClassColored(name, class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. name .. "|r"
    end
    return name
end

-- Our own line, for when the chat window's handler can't be used.
local function FallbackLine(author, class, text, tagText)
    local link = "|Hplayer:" .. author .. "|h[" .. ClassColored(author, class) .. "]|h"
    local head = CHAT_GUILD_GET and CHAT_GUILD_GET:format(link) or ("[" .. GUILD .. "] " .. link .. ": ")
    local p = head:find("|Hplayer:", 1, true)
    if p and tagText ~= "" then head = head:sub(1, p - 1) .. tagText .. head:sub(p) end
    return head .. text
end

AllyChat.stats = { handler = 0, fallback = 0, tagged = 0 }

-- Chattynator doesn't read the chat windows: its own hidden frame listens to the chat events
-- and formats each line with the player's settings (short channel names, level...), and it
-- ignores lines written by a chat window's handler. So allied lines are handed to that frame,
-- like a real guild message. Found among the frames listening to guild chat.
local chattyMonitor
local function ChattynatorMonitor()
    if chattyMonitor then return chattyMonitor end
    if not UsingChattynator() or not GetFramesRegisteredForEvent then return nil end
    for _, frame in ipairs({ GetFramesRegisteredForEvent("CHAT_MSG_GUILD") }) do
        if type(frame) == "table" and type(frame.SetIncomingType) == "function"
            and type(frame.OnEvent) == "function" and type(frame.MessageEventHandler) == "function" then
            chattyMonitor = frame
            return frame
        end
    end
    return nil
end

-- Show one guild line in one chat window, through the window's own handler when possible.
-- viaEvent: hand it over as a chat event (Chattynator's frame) instead of the window's handler.
local function ShowInFrame(frame, author, class, guid, text, tagText, viaEvent)
    if type(frame.MessageEventHandler) == "function" then
        -- Put the tag in front of the name while the handler writes the line.
        local had = rawget(frame, "AddMessage")
        local orig = frame.AddMessage
        local tagged, called = false, false
        frame.AddMessage = function(self, line, ...)
            called = true
            if not tagged and tagText ~= "" and type(line) == "string" and not IsSecret(line) then
                local p = line:find("|Hplayer:", 1, true)
                if p then
                    line = line:sub(1, p - 1) .. tagText .. line:sub(p)
                    tagged = true
                end
            end
            return orig(self, line, ...)
        end
        local handler = viaEvent and frame.OnEvent or frame.MessageEventHandler
        local ok, err = pcall(handler, frame, "CHAT_MSG_GUILD",
            text, author, "", "", author, "", 0, 0, "", 0, 0, guid or "", 0, false, false, false, false)
        rawset(frame, "AddMessage", had)
        if not ok then AllyChat.stats.lastError = tostring(err) end
        -- Once the line is written, an error after that must not write it a second time.
        -- If the handler wrote nothing (it skipped the line), write our own.
        if called then
            AllyChat.stats.handler = AllyChat.stats.handler + 1
            if tagged then AllyChat.stats.tagged = AllyChat.stats.tagged + 1 end
            return
        end
    end
    local info = ChatTypeInfo and ChatTypeInfo.GUILD
    frame:AddMessage(FallbackLine(author, class, text, tagText), info and info.r or 0.25, info and info.g or 1, info and info.b or 0.25)
    AllyChat.stats.fallback = AllyChat.stats.fallback + 1
end

local function ShowInChat(author, class, guid, text, tag)
    local tagText = TagText(tag)
    local monitor = ChattynatorMonitor()
    if monitor then
        AllyChat.stats.chattynator = (AllyChat.stats.chattynator or 0) + 1
        ShowInFrame(monitor, author, class, guid, text, tagText, true)
        return
    end
    for _, frame in ipairs(GuildFrames()) do
        ShowInFrame(frame, author, class, guid, text, tagText)
    end
end

-- Guild window ------------------------------------------------------------------------------

local function Window() return _G.CommunitiesFrame end

-- Is the guild window showing my guild's main chat?
local function GuildChatShown()
    local f = Window()
    if not (f and f:IsShown() and f.Chat and f.Chat:IsShown() and f.Chat.MessageFrame) then return false end
    local clubId = f.GetSelectedClubId and f:GetSelectedClubId()
    local streamId = f.GetSelectedStreamId and f:GetSelectedStreamId()
    if not (clubId and streamId and C_Club) then return false end
    local ok, info = pcall(C_Club.GetClubInfo, clubId)
    if not ok or not info or not Enum.ClubType or info.clubType ~= Enum.ClubType.Guild then return false end
    local ok2, stream = pcall(C_Club.GetStreamInfo, clubId, streamId)
    return ok2 and stream and Enum.ClubStreamType and stream.streamType == Enum.ClubStreamType.Guild or false
end

local function WindowLine(entry)
    local link = "|Hplayer:" .. entry.a .. "|h[" .. ClassColored(entry.a, entry.c) .. "]|h"
    return TagText(entry.tag) .. link .. ": " .. entry.m
end

local function AddToWindow(entry)
    local info = ChatTypeInfo and ChatTypeInfo.GUILD
    pcall(Window().Chat.MessageFrame.AddMessage, Window().Chat.MessageFrame, WindowLine(entry),
        info and info.r or 0.25, info and info.g or 1, info and info.b or 0.25)
end

-- When the window rebuilds its chat (open, change of channel) it clears everything, then adds
-- its messages oldest first. We slip ours in between, by time.
local rebuild -- { epochs = {...}, k = 0, ptr = 1 } while the window is refilling
local function PutOurs(upto)
    local log = ns.db.allyLog
    while rebuild.ptr <= #log and (log[rebuild.ptr].t or 0) * 1000000 < upto do
        AddToWindow(log[rebuild.ptr])
        rebuild.ptr = rebuild.ptr + 1
    end
end

local function OnClear()
    rebuild = nil
    if not Enabled() or not GuildChatShown() or #ns.db.allyLog == 0 then return end
    local chat = Window().Chat
    local ok, messages = pcall(chat.GetMessagesToDisplay, chat)
    local epochs = {}
    for i, m in ipairs(ok and messages or {}) do
        epochs[i] = m.messageId and m.messageId.epoch or 0
    end
    rebuild = { epochs = epochs, k = 0, ptr = 1 }
    -- Skip ours older than the window's first message: it only shows recent history.
    if epochs[1] and epochs[1] > 0 then
        local log = ns.db.allyLog
        while rebuild.ptr <= #log and (log[rebuild.ptr].t or 0) * 1000000 < epochs[1] do
            rebuild.ptr = rebuild.ptr + 1
        end
    end
end

local function OnWindowLine(_, _, _, _, backfill)
    if not rebuild or backfill then return end
    rebuild.k = rebuild.k + 1
    PutOurs(rebuild.epochs[rebuild.k + 1] or math.huge)
end

local function OnDisplayDone()
    if rebuild then PutOurs(math.huge) end
    rebuild = nil
end

local windowHooked = false
local function HookWindow()
    local f = Window()
    if windowHooked or not (f and f.Chat and f.Chat.MessageFrame) then return end
    windowHooked = true
    hooksecurefunc(f.Chat.MessageFrame, "Clear", function() pcall(OnClear) end)
    if f.Chat.AddMessage then
        hooksecurefunc(f.Chat, "AddMessage", function(...) pcall(OnWindowLine, ...) end)
    end
    if f.Chat.DisplayChat then
        hooksecurefunc(f.Chat, "DisplayChat", function() pcall(OnDisplayDone) end)
    end
end

function AllyChat:IsWindowHooked()
    return windowHooked
end

-- Receiving ----------------------------------------------------------------------------------

-- In test mode the lines also go to the test guild window; the game's chat windows only get
-- them when the Debug tab's option says so.
local function ShowLine(author, class, guid, text, tag)
    if ns.Guild:IsSandbox() then
        if ns.MockGuild then ns.MockGuild:AddChat(author, class, text, tag) end
        if not ns.db.dev.gameChat then return end
    end
    ShowInChat(author, class, guid, text, tag)
end

local function Receive(author, payload, tag)
    local text = payload.m
    if type(text) ~= "string" or text == "" or IsSecret(text) then return end
    if #text > 255 then
        -- Cut, without leaving half a letter (UTF-8) at the end.
        text = text:sub(1, 255):gsub("[\192-\255][\128-\191]*$", "")
    end
    -- Shown as typed: no links, colors or icons slipped in ("|" codes), unlike real chat the
    -- server never checked this text.
    local shown = text:gsub("|", "||")
    local class = type(payload.c) == "string" and payload.c or nil
    local guid = type(payload.id) == "string" and payload.id or nil
    ShowLine(author, class, guid, shown, tag)
    if ns.Invites then ns.Invites:OnChat(author, text, tag and "ally" or "guild") end
    if tag then
        local entry = { t = GetServerTime(), a = author, c = class, g = payload.g, tag = tag, m = shown }
        local log = ns.db.allyLog
        log[#log + 1] = entry
        Prune()
        if GuildChatShown() then AddToWindow(entry) end
    end
end

ns.Comm:OnAlly("CHAT", function(sender, payload, isSelf)
    if isSelf or not Enabled() then return end
    local tag = ns.Alliance:GetTag(payload.g) or "?"
    -- Nobody from their guild could confirm them (yet): a "?" after the tag.
    if ns.Vouch and ns.Vouch:GetState(sender) == "unverified" then tag = tag .. "?" end
    Receive(sender, payload, tag)

end)

-- Sandbox only: a fake guild mate typed in the fake guild chat.
ns.Comm:On("GCHAT", function(sender, payload, isSelf)
    if isSelf or not ns.Guild:IsSandbox() then return end
    Receive(sender, payload, nil)
end)

-- Sending ----------------------------------------------------------------------------------

local function MyPayload(text)
    local _, class = UnitClass("player")
    return { m = text, c = class, id = UnitGUID("player") }
end

local function Relay(text)
    if not Enabled() or not ns.Alliance:IsActive() then return end
    ns.Comm:SendAlly("CHAT", MyPayload(text), "ALERT")
end

-- A line La Taverne itself sends to guild chat that must stay in my guild (a group shown to my
-- guild only): the next send of that exact text isn't relayed.
local skipText
function AllyChat:SkipRelay(text)
    skipText = text
    C_Timer.After(2, function() if skipText == text then skipText = nil end end)
end

local lastSig, lastTime = nil, 0
local function OnSend(text, chatType)
    if ns.Guild:IsSandbox() then return end -- never touch the real guild chat in sandbox
    if type(text) ~= "string" or IsSecret(text) or text == "" or type(chatType) ~= "string" then return end
    if chatType:upper() ~= "GUILD" then return end
    if skipText and text == skipText then
        lastSig, lastTime = text, GetTime() -- the second send function of the same message too
        return
    end
    -- Both send functions can fire for one message.
    local now = GetTime()
    if text == lastSig and now - lastTime < 0.2 then return end
    lastSig, lastTime = text, now
    Relay(text)
end

if SendChatMessage then hooksecurefunc("SendChatMessage", OnSend) end
if C_ChatInfo and C_ChatInfo.SendChatMessage then hooksecurefunc(C_ChatInfo, "SendChatMessage", OnSend) end

-- Typing in the guild window's chat goes through the community API instead.
if C_Club and C_Club.SendMessage and C_Club.GetGuildClubId then
    hooksecurefunc(C_Club, "SendMessage", function(clubId, streamId, text)
        if type(text) ~= "string" or IsSecret(text) then return end
        local ok, guildClub = pcall(C_Club.GetGuildClubId)
        if not ok or not guildClub or clubId ~= guildClub then return end
        local ok2, info = pcall(C_Club.GetStreamInfo, clubId, streamId)
        local streamType = ok2 and info and info.streamType
        if Enum.ClubStreamType and streamType ~= Enum.ClubStreamType.Guild then return end
        OnSend(text, "GUILD")
    end)
end

-- Test mode stand-in for typing in guild chat: goes to the test guild and to the allied guilds
-- (unless guildOnly).
function AllyChat:SendTestGuildChat(text, guildOnly)
    if not ns.Guild:IsSandbox() then return false end
    text = strtrim(text or "")
    if text == "" then return false end
    local _, class = UnitClass("player")
    ShowLine(ns.FullName("player"), class, UnitGUID("player"), text, nil)
    ns.Comm:Send("GCHAT", MyPayload(text), "ALERT")
    if not guildOnly and Enabled() and ns.Alliance:IsActive() then

        ns.Comm:SendAlly("CHAT", MyPayload(text), "ALERT")
    end
    return true
end

-- /taverne g <text>
ns.commands.g = function(text)
    if not ns.Guild:IsSandbox() then
        ns.Print("/taverne g only works in test mode. Use your normal guild chat.")
        return
    end
    if not AllyChat:SendTestGuildChat(text) then
        ns.Print("usage: /taverne g <message> (fake guild chat, test mode)")
    end
end

function AllyChat:OnLogin()
    Prune()
    HookWindow()
    ns.On("ADDON_LOADED", function(name)
        if name == "Blizzard_Communities" then HookWindow() end
    end)
end
