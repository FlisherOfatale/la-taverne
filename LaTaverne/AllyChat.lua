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
local LATE = 20 -- seconds: a line arriving this long after it was typed says when it was typed
local TAG_COLOR = "|cff8fb8e8"

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- One guild line can reach us in slightly different forms: as its author typed it, as the game
-- delivers it, as another player passes it on. This key leaves out what may differ (colors,
-- icons, a link's name and details: kind and number only, spaces) and keeps the first 200 bytes
-- (a long line may be cut on the way), to tell copies of one line from new lines. Only for
-- comparing, never shown. nil for a secret text.
local KEY_MAX = 200
function AllyChat.TextKey(text)
    if type(text) ~= "string" or IsSecret(text) then return nil end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]*:", ""):gsub("|r", "")
    text = text:gsub("|H(%a+):([^:|]*)[^|]*|h.-|h", "<%1:%2>")
    text = text:gsub("|T.-|t", ""):gsub("|A.-|a", "")
    text = strtrim((text:gsub("%s+", " ")))
    return text:sub(1, KEY_MAX)
end

-- GuildUnion shares guild chat too: while both are loaded, one of them should stop, or allied
-- lines show twice. That's the only time La Taverne's switch shows (Options).
function AllyChat:CanTurnOff()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return loaded and loaded("GuildUnion") and true or false
end

-- Shared chat is a core part of the alliance: always on, unless turned off while GuildUnion
-- runs too (an old "off" is ignored once GuildUnion is gone).
local function Enabled()
    return ns.db and (ns.db.allyChat.enabled or not AllyChat:CanTurnOff())
end
AllyChat.Enabled = function() return Enabled() and true or false end

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

-- In front of an allied player's name: the Nation du Québec lynx (a line shared by La Taverne),
-- then the guild's tag; each has its option, so allied lines can look like guild ones.
-- relayed: the line came through the guild relay (Relay.lua) and its author doesn't run La
-- Taverne (nothing heard from their La Taverne lately), so they never see allied answers. Marked
-- (its own option, on by default): a grey lynx in place of the gold one, or a grey dot when the
-- lynx is off.
local LYNX_ICON = "|TInterface\\AddOns\\LaTaverne\\media\\lynx_icon:0|t "
local LYNX_GREY = "|TInterface\\AddOns\\LaTaverne\\media\\lynx_icon_grey:0|t "
local GREY_DOT = "|TInterface\\FriendsFrame\\StatusIcon-Offline:0|t "

local function MarkRelayed() return ns.db.allyChat.markRelayed ~= false end

local function TagText(tag, relayed)
    if not tag then return "" end
    -- (also AllyChat.TagText, for the test guild window)
    local text = ""
    local mark = relayed and MarkRelayed()
    if ns.db.allyChat.showLynx ~= false then
        text = mark and LYNX_GREY or LYNX_ICON
    elseif mark then
        text = GREY_DOT
    end
    if ns.db.allyChat.showTag then text = text .. TAG_COLOR .. "[" .. tag .. "]|r " end
    return text
end

AllyChat.TagText = TagText

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

AllyChat.stats = { handler = 0, fallback = 0, tagged = 0, relayed = 0, copies = 0, refused = 0 }

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
        -- The 18th value (game 12.1.0 and later): about a line from the guild's linked Discord.
        -- The game's handler reads it for every guild line; an in-game line says it's not one.
        -- userID must be the number 0: anything else (even "") makes the game take the line for a
        -- Discord one, with a Discord link in place of the player link (so no tag, no whisper).
        local discordInfo = {
            userID = 0, globalName = author, type = 0, lastOnlineGUID = guid or "", lastOnlineName = author,
            hasAttachment = false, hasPoll = false, hasEmbed = false, hasSticker = false, hasEmoji = false,
            hasError = false, hasForwardedMessage = false, forwardedMessage = "", fromDiscord = false,
        }
        local ok, err = pcall(handler, frame, "CHAT_MSG_GUILD",
            text, author, "", "", author, "", 0, 0, "", 0, 0, guid or "", 0, false, false, false, false, discordInfo)
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

local function ShowInChat(author, class, guid, text, tag, relayed)
    local tagText = TagText(tag, relayed)
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

-- The time in front, as the window shows its own lines, when the chat timestamps setting is on.
local function TimeStamp(t)
    local fmt = (GetChatTimestampFormat and GetChatTimestampFormat()) or CHAT_TIMESTAMP_FORMAT
    if not fmt or not t then return "" end
    local ok, text = pcall(BetterDate or date, fmt, t)
    return ok and type(text) == "string" and text or ""
end

local function WindowLine(entry)
    local link = "|Hplayer:" .. entry.a .. "|h[" .. ClassColored(entry.a, entry.c) .. "]|h"
    return TimeStamp(entry.t) .. TagText(entry.tag, entry.r) .. link .. ": " .. entry.m
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
local function ShowLine(author, class, guid, text, tag, relayed)
    if ns.Guild:IsSandbox() then
        if ns.MockGuild then ns.MockGuild:AddChat(author, class, text, tag, relayed) end
        if not ns.db.dev.gameChat then return end
    end
    ShowInChat(author, class, guid, text, tag, relayed)
end

-- The first marked line (relayed, the mark on): say once what the mark means.
local function TellMark()
    if ns.db.allyChat.markTold or not MarkRelayed() then return end
    ns.db.allyChat.markTold = true
    local icon = ns.db.allyChat.showLynx ~= false and LYNX_GREY or GREY_DOT
    ns.Print(format(L["Allied lines marked %s come from players without La Taverne: they can't see your answers. (Options, Shared guild chat)"], strtrim(icon)))
end

-- Links typed in chat (items, spells, quests...). Unlike real chat, the server never checked
-- this text, so links are rebuilt from their numbers only: the game's own link (its name and
-- color) for an item it knows, otherwise a plain link with the name as typed. Clicking it shows
-- the real thing either way.
local LINK_TYPES = { item = true, spell = true, enchant = true, quest = true, achievement = true, talent = true }
local LINK_COLORS = { item = "ffffffff", quest = "ffffff00" }

-- The color an item link came with, kept only when it's one of the game's item quality colors
-- ("|cnIQ4:" or its "|cffa335ee"): an item my game hasn't seen yet still shows its rarity.
local function QualityColor(color)
    if type(color) ~= "string" then return nil end
    local qualities = ITEM_QUALITY_COLORS
    local n = tonumber(color:match("^|cnIQ(%d):$"))
    if n then
        local q = qualities and qualities[n]
        if q and type(q.hex) == "string" then return q.hex end
        return (n <= 8) and color or nil
    end
    local hex = color:match("^|c(%x%x%x%x%x%x%x%x)$")
    if not hex or type(qualities) ~= "table" then return nil end
    for _, q in pairs(qualities) do
        if type(q) == "table" and type(q.hex) == "string" and q.hex:lower() == ("|c" .. hex):lower() then return q.hex end
    end
    return nil
end

local function SafeLink(kind, data, name, color)
    if not LINK_TYPES[kind] or #data > 150 then return nil end
    -- Letters only in an achievement's (a player's ID, and its data isn't used): the others are numbers.
    if kind ~= "achievement" and data:find("[^%d:%-]") then return nil end
    name = name:gsub("|", "")
    if name == "" or #name > 100 then return nil end
    if kind == "item" then
        local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
        local ok, _, link = pcall(getInfo, "item:" .. data)
        if ok and type(link) == "string" and not IsSecret(link) and link:find("|Hitem:", 1, true) then return link end
    end
    -- Achievements (WoW Forever's Legacy objectives, e.g. [Explore Eastern Kingdoms]): the game
    -- has no achievement window to open, so the name in yellow, not a link.
    if kind == "achievement" then return "|cffffff00[" .. name .. "]|r" end
    local quality = kind == "item" and QualityColor(color)
    return (quality or ("|c" .. (LINK_COLORS[kind] or "ff71d5ff"))) .. "|H" .. kind .. ":" .. data .. "|h[" .. name .. "]|h|r"
end

-- The text as typed: no colors, icons or other "|" codes slipped in, except rebuilt links.
local function SafeText(text)
    local links = {}
    local function keep(kind, data, name, color)
        local link = SafeLink(kind, data, name, color)
        if not link then return nil end -- left as typed, shown as plain text below
        links[#links + 1] = link
        return "\1" .. #links .. "\2"
    end
    text = text:gsub("[\1\2]", "")
    -- (Link data: numbers, and for achievements the player's ID, letters too: Player-6933-005A8B24.)
    text = text:gsub("(|c[^|]*)|H(%a+):([%w:%-]*)|h%[([^%]|]*)%]|h|r", function(color, kind, data, name)
        return keep(kind, data, name, color)
    end)
    text = text:gsub("|H(%a+):([%w:%-]*)|h%[([^%]|]*)%]|h", keep)
    text = text:gsub("|", "||")
    return (text:gsub("\1(%d+)\2", function(i) return links[tonumber(i)] end))
end
AllyChat.SafeText = SafeText

local function Receive(author, payload, tag, relayed)
    local text = payload.m
    if type(text) ~= "string" or text == "" or IsSecret(text) then return end
    -- On my ignore list: the game hides their real chat on its side, but these lines don't go
    -- through it. Not shown, not logged, not read by auto-invite.
    if ns.IsIgnored(author) then return end
    if #text > 255 then
        -- Cut, without leaving half a letter (UTF-8) at the end.
        text = text:sub(1, 255):gsub("[\192-\255][\128-\191]*$", "")
    end
    local shown = SafeText(text)
    -- Held on the way (the sender was in a fight, where the game holds addon messages): say
    -- when it was typed. t: when they typed it (server time, same clock for everyone).
    local typed = tonumber(payload.t)
    if typed and GetServerTime() - typed >= LATE then
        local note = payload.f and L["(typed at %s, in combat)"] or L["(typed at %s)"]
        shown = shown .. " |cff808080" .. note:format(date("%H:%M", typed)) .. "|r"
    end
    local class = type(payload.c) == "string" and payload.c or nil
    local guid = type(payload.id) == "string" and payload.id or nil
    -- An allied author's class: the allied player lists show it too.
    if tag and class and ns.Vouch then ns.Vouch:NoteLooks(author, class) end
    relayed = (tag and relayed) and true or nil
    ShowLine(author, class, guid, shown, tag, relayed)
    if relayed then TellMark() end
    if ns.Invites then ns.Invites:OnChat(author, text, tag and "ally" or "guild") end
    if tag then
        local entry = { t = GetServerTime(), a = author, c = class, g = payload.g, tag = tag, m = shown, r = relayed }
        local log = ns.db.allyLog
        log[#log + 1] = entry
        Prune()
        if GuildChatShown() then AddToWindow(entry) end
    end
end

-- Copies: one allied line can come twice (its author's own copy and a relay's, two relays at
-- once, a copy the game held during a fight): same guild, author and text (TextKey), typed
-- within 10 s of each other, passed on by someone else (source: "author" for the author's own
-- copy, the relay's name otherwise). The same source twice is the line typed again (a "+1"
-- repeated): it shows. Two relays' copies carry the time each one saw the guild line, a second
-- or two apart: closer than that (RELAYS_WINDOW), so a line typed again across a relay handover
-- still shows. Kept 15 min.
local COPY_WINDOW, RELAYS_WINDOW, COPY_KEEP = 10, 3, 15 * 60
local copies = {} -- [guild \0 author \0 key] = { { t = server time, src = source }, ... }

local function IsCopy(guild, author, text, t, source)
    local key = AllyChat.TextKey(text)
    if not key or type(guild) ~= "string" or type(author) ~= "string" then return false end
    local id = strtrim(guild):lower() .. "\0" .. ns.NameKey(author) .. "\0" .. key
    local now = GetServerTime()
    t = tonumber(t) or now
    source = source == "author" and "\0" or ns.NameKey(source) or "?"
    local list = copies[id]
    if list then
        for _, seen in ipairs(list) do
            local window = (seen.src ~= "\0" and source ~= "\0") and RELAYS_WINDOW or COPY_WINDOW
            if seen.src ~= source and math.abs(seen.t - t) <= window then return true end
        end
    else
        list = {}
        copies[id] = list
    end
    list[#list + 1] = { t = t, src = source }
    if math.random(1, 50) == 1 then
        for other, seen in pairs(copies) do
            if now - seen[#seen].t > COPY_KEEP then copies[other] = nil end
        end
    end
    return false
end

ns.Comm:OnAlly("CHAT", function(sender, payload, isSelf)
    if isSelf or not Enabled() then return end
    if IsCopy(payload.g, sender, payload.m, payload.t, "author") then
        AllyChat.stats.copies = AllyChat.stats.copies + 1
        return
    end
    local tag = ns.Alliance:GetTag(payload.g) or "?"
    Receive(sender, payload, tag)
end)

-- Relayed lines (Relay.lua): an allied guild's member without La Taverne, passed on by their
-- guild's relay (the sender, checked by vouching like any allied player). Shown like any other
-- allied line. The relay speaks for someone else, so what it says is checked more.
-- Relayed lines a minute from one guild (copies not counted): more is a broken relay. A relay
-- sends 8 at once then 1 a second (Relay.lua), 68 in its first minute: room above that.
local FLOOD_MAX = 90
local TIME_DRIFT = 300    -- a time further than this from mine: taken as now
local flood = {}          -- [guild lowercase] = { start, count }

local function Refuse(sender, why)
    AllyChat.stats.refused = AllyChat.stats.refused + 1
    ns.Comm:LogNote(format("relayed line from %s refused: %s", tostring(sender), why), "relayed line refused")
end

-- A player's name: no codes, no link characters, not too long.
local function ValidAuthor(name)
    return type(name) == "string" and not IsSecret(name) and #name <= 48 and name:find("%S") ~= nil
        and not name:find("[%c|%[%]:]")
end

ns.Comm:OnAlly("RCHAT", function(sender, payload, isSelf)
    if isSelf or not Enabled() or not ns.Relay then return end
    local rp = tonumber(payload.rp) or 0
    if rp > ns.Relay.RP then
        ns.Relay:NoteProtocol(rp, false)
        return
    end
    if rp < ns.Relay.RP - 1 then return end
    local author = payload.a
    if not ValidAuthor(author) then return Refuse(sender, "bad author name") end
    -- Nobody of my guild, nor me: my guild's lines never come from an allied guild.
    if ns.IsMe(author) or ns.Guild:IsMember(author) then return Refuse(sender, "author in my guild") end
    local g = strtrim(payload.g):lower()
    local now = GetServerTime()
    local t = tonumber(payload.t)
    if not t or math.abs(now - t) > TIME_DRIFT then t = now end
    -- A copy (two relays for a moment, a gap fill, the author's own) is dropped before the flood
    -- count: only lines that would show count.
    if IsCopy(payload.g, author, payload.m, t, sender) then
        AllyChat.stats.copies = AllyChat.stats.copies + 1
        return
    end
    local f = flood[g]
    if not f or now - f.start >= 60 then
        f = { start = now, count = 0 }
        flood[g] = f
    end
    f.count = f.count + 1
    if f.count > FLOOD_MAX then
        if f.count == FLOOD_MAX + 1 then Refuse(sender, "more than " .. FLOOD_MAX .. " lines in a minute") end
        return
    end
    local guid = type(payload.id) == "string" and payload.id:match("^Player%-[%w%-]+$") or nil
    local class = type(payload.c) == "string" and payload.c:match("^%u+$") or nil
    -- A line that wouldn't show (empty, hidden by the game, the author on my ignore list): it
    -- counts for nothing, vouching included.
    local text = payload.m
    if type(text) ~= "string" or text == "" or IsSecret(text) or ns.IsIgnored(author) then return end
    -- Vouching: the author is only as checked as their relay (before Receive: auto-invite reads
    -- it). The game shows them in another guild: hidden.
    if ns.Vouch and not ns.Vouch:Relayed(author, payload.g, sender, "chat") then return end
    AllyChat.stats.relayed = AllyChat.stats.relayed + 1
    -- The mark says "without La Taverne": not for an author whose La Taverne I heard lately on the
    -- alliance channel (the relay's copy only beat theirs, or theirs was lost on the way).
    local without = not (ns.Vouch and ns.Vouch:HeardRecently(author, payload.g))
    Receive(author, { m = payload.m, t = t, c = class, id = guid, g = payload.g }, ns.Alliance:GetTag(payload.g) or "?", without)
end)

-- Sandbox only: a fake guild mate typed in the fake guild chat. as: a test guild member without
-- La Taverne said it (/taverne dev say, typed by the sender): shown under that name, without
-- the sender's own class and GUID.
ns.Comm:On("GCHAT", function(sender, payload, isSelf)
    if isSelf or not ns.Guild:IsSandbox() then return end
    if payload.as ~= nil then
        if not ValidAuthor(payload.as) then return end
        Receive(payload.as, { m = payload.m, t = payload.t, c = payload.c, g = payload.g }, nil)
        return
    end
    Receive(sender, payload, nil)
end)

-- Sending ----------------------------------------------------------------------------------

-- t: when I typed it, f: I was in a fight (the line may arrive late, see Receive).
local function MyPayload(text)
    local _, class = UnitClass("player")
    -- Only real combat: Restricted() is also on in Mythic+ and PvP, where "in combat" would be wrong.
    local fighting = UnitAffectingCombat and UnitAffectingCombat("player")
    return { m = text, c = class, id = UnitGUID("player"), t = GetServerTime(), f = fighting and true or nil }
end

local function Relay(text)
    if not Enabled() or not ns.Alliance:IsActive() then return end
    -- Sent again if the game's channel throttle refuses it (Comm.lua).
    ns.Comm:SendAlly("CHAT", MyPayload(text), "ALERT", nil, nil, true)
end

local lastSig, lastTime = nil, 0
local function OnSend(text, chatType)
    if ns.Guild:IsSandbox() then return end -- never touch the real guild chat in sandbox
    if type(text) ~= "string" or IsSecret(text) or text == "" or type(chatType) ~= "string" then return end
    if chatType:upper() ~= "GUILD" then return end
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

        ns.Comm:SendAlly("CHAT", MyPayload(text), "ALERT", nil, nil, true)
    end
    return true
end

-- Test mode: a member of the test guild who doesn't run La Taverne says a line, to try the guild
-- relay (Relay.lua) with two PCs in two test guilds. The name needn't exist. It goes to the test
-- guild like my own lines (GCHAT, as = who said it), never straight to the allied guilds: that's
-- the relay's job, mine included (I see the line too, like everyone in the guild).
local FAKE_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

function AllyChat:SendFakeMemberLine(name, text)
    if not ns.Guild:IsSandbox() then return false end
    name, text = strtrim(name or ""), strtrim(text or "")
    if text == "" or not ValidAuthor(name) or ns.IsMe(name) then return false end
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 1000003 end
    local class = FAKE_CLASSES[h % #FAKE_CLASSES + 1] -- always the same for one name
    ShowLine(name, class, nil, text, nil)
    ns.Comm:Send("GCHAT", { m = text, c = class, t = GetServerTime(), as = name }, "ALERT")
    if ns.Relay then ns.Relay:GuildLine(name, text, class, nil) end
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
