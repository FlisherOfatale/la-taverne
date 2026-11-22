-- Addon-to-addon messaging, two scopes:
--
-- "guild": the group finder and anything only our guild should hear.
--   Normal mode: hidden addon messages on the GUILD channel (AceComm).
--   Sandbox mode: the same messages on a private password-protected test channel.
--   In sandbox mode nothing is ever sent to the guild.
--
-- "ally": allied guild traffic (allied chat). Always on the alliance channel, whose name and
--   password come from the alliance key in the Guild Info (or the fake Guild Info in sandbox).
--   Our own small multipart format, so every part can be checked to come from that channel:
--   anyone can send addon messages on a public channel like General, and must not be able to
--   pose as an allied guild that way.
local ADDON, ns = ...
local Comm = ns.NewModule("Comm")

local AceSerializer = LibStub("AceSerializer-3.0")
LibStub("AceComm-3.0"):Embed(Comm)
local CTL = _G.ChatThrottleLib

local PREFIX = "LaTaverne"
local ALLY_PREFIX = "LaTaverneA"
local PROBE_PREFIX = "LaTaverneProbe"
-- The guild relay (Relay.lua) talks on its own prefix, on the same alliance channel and with the
-- same checks: the game limits messages per prefix, so relaying never slows down groups,
-- positions and the chat of La Taverne users. Old versions never registered it: they don't
-- receive any of it.
Comm.RELAY_PREFIX = "LaTaverneR"
local ALLY_PREFIXES = { [ALLY_PREFIX] = true, [Comm.RELAY_PREFIX] = true }
local PROTOCOL = 1
local JOIN_DELAY = 8   -- seconds after login, so the game's own channels (General, Trade...) keep their numbers
local MAX_QUEUE = 50
local PART_SIZE = 240  -- addon messages are limited to 255 bytes

local handlers = {}      -- ["guild" | "ally"][msgType] = { fn, ... }
local queues = { guild = {}, ally = {} } -- serialized messages waiting for a channel
local loggedIn = false

Comm.stats = { sent = 0, received = 0, rejected = 0 }

-- Message log --------------------------------------------------------------------------
-- Debug tab or /taverne msglog: every hidden message in and out while it's on, and what
-- happened to it. Never what it says: only the payload's field names. The unusual ones are
-- marked "!!" and counted at the top, to spot a bug in a two-PC test. Kept in memory only (the
-- last LOG_MAX lines), cleared on /reload. Costs nothing while off.
-- Test mode: the test guild's channel and the alliance channel (what La Taverne listens to).
-- The real guild's messages are ignored then: only counted.
local LOG_MAX = 300
local RATE_MAX = 30 -- messages in a minute from one sender: unusual
local msgLog = { on = false, lines = {}, unusual = {}, order = {}, rate = {}, realIgnored = 0,
    quiet = { positions = { ["in"] = 0, out = 0 }, relayed = { ["in"] = 0, out = 0 } },
    guildQuiet = { hellos = 0, lines = 0 } }
-- Positions on the map (AllyMap.lua) go every few seconds from everyone, and relayed guild lines
-- (Relay.lua) one per line: only counted, never listed, or they'd push everything else out of
-- the log. [type] = its counter.
local QUIET_TYPES = { POS = "positions", RCHAT = "relayed" }
-- My guildmates' hellos (Vouch.lua), heard on the alliance channel: one every 4-4.5 minutes from
-- each of them, a lot in a big guild. And their own copies of their guild lines (AllyChat.lua),
-- read only by the relay: one per line. Only counted too. [type] = its counter.
local QUIET_GUILD_TYPES = { HI = "hellos", CHAT = "lines" }

function Comm:IsLogging() return msgLog.on end

local function FieldNames(payload)
    if type(payload) ~= "table" then return "" end
    local keys = {}
    for k in pairs(payload) do
        if k ~= "ver" and k ~= "g" and k ~= "n" then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    return "{" .. table.concat(keys, ",") .. "}"
end

-- Each line keeps its message type (kind) and who it's from (who), for the window's filters:
-- notes (lines that aren't one message) are kind LOG_NOTES and nobody's, what I send is LOG_ME's.
local LOG_NOTES, LOG_ME = "--", "@me"
Comm.LOG_NOTES, Comm.LOG_ME = LOG_NOTES, LOG_ME

local function AddLine(text, unusual, kind, who)
    local line = date("%H:%M:%S") .. (unusual and " !! " or "    ") .. text
    local lines = msgLog.lines
    lines[#lines + 1] = { text = line, kind = kind or LOG_NOTES, who = who }
    if #lines > LOG_MAX then table.remove(lines, 1) end
    if unusual then
        local u = msgLog.unusual[unusual]
        if not u then
            u = { count = 0 }
            msgLog.unusual[unusual] = u
            msgLog.order[#msgLog.order + 1] = unusual
        end
        u.count = u.count + 1
        u.last = line
    end
end

-- A free line (a question nobody answered...). unusual: a short kind, counted at the top.
function Comm:LogNote(text, unusual)
    if msgLog.on then AddLine("-- " .. text, unusual) end
end

-- One message. dir: "in" or "out"; scope: "guild" or "ally"; what: what happened to it.
local function Trace(dir, scope, msgType, sender, size, what, payload, unusual)
    if not msgLog.on then return end
    -- Counted once each: in when delivered (not when held for vouching, then again when
    -- delivered, nor a copy from the old channel), out when sent.
    local quiet = QUIET_TYPES[msgType]
    if quiet and not unusual then
        local counter = msgLog.quiet[quiet]
        if what == "delivered" or what == "sent" then counter[dir] = (counter[dir] or 0) + 1 end
        return
    end
    local quietGuild = scope == "guild" and QUIET_GUILD_TYPES[msgType]
    if quietGuild and not unusual then
        if what == "delivered" then msgLog.guildQuiet[quietGuild] = msgLog.guildQuiet[quietGuild] + 1 end
        return
    end
    if scope == "guild" and ns.Guild:IsSandbox() then scope = "test" end
    local from = ""
    if dir == "in" then
        local tag = scope == "ally" and type(payload) == "table" and ns.Alliance:GetTag(payload.g)
        from = "  " .. tostring(sender) .. (tag and (" [" .. tag .. "]") or "")
        -- Their version, when it isn't mine (an old version explains a lot).
        local ver = type(payload) == "table" and payload.ver
        if type(ver) == "string" and ver ~= ns.version then from = from .. " (v" .. ver:sub(1, 16) .. ")" end
        -- One sender sending a lot.
        local key = tostring(sender)
        local r = msgLog.rate[key]
        local now = GetTime()
        if not r or now - r.start > 60 then
            r = { start = now, count = 0 }
            msgLog.rate[key] = r
        end
        r.count = r.count + 1
        if r.count == RATE_MAX + 1 then
            AddLine(format("%s sent more than %d messages in a minute", key, RATE_MAX), "busy sender")
        end
    end
    AddLine(format("%-3s %-5s %-12s%s  %db  %s  %s", dir, scope, tostring(msgType), from, size or 0,
        what, FieldNames(payload)), unusual and (unusual .. " (" .. tostring(msgType) .. ")") or nil,
        tostring(msgType), dir == "in" and tostring(sender) or LOG_ME)
end
Comm.Trace = Trace

function Comm:SetLogging(on)
    if on and not msgLog.on then
        wipe(msgLog.lines)
        wipe(msgLog.unusual)
        wipe(msgLog.order)
        wipe(msgLog.rate)
        msgLog.realIgnored = 0
        for _, counter in pairs(msgLog.quiet) do counter["in"], counter.out = 0, 0 end
        for name in pairs(msgLog.guildQuiet) do msgLog.guildQuiet[name] = 0 end
        msgLog.since = date("%H:%M:%S")
    end
    msgLog.on = on and true or false
end

function Comm:ClearLog()
    local on = msgLog.on
    msgLog.on = false
    self:SetLogging(on)
end

-- The log as text: what's unusual first, then the lines, oldest first.
-- hiddenKinds, hiddenWho: { [type or sender] = true } left out of the lines (the window's
-- filters); the counts at the top stay complete, and the text says what was left out.
function Comm:LogText(hiddenKinds, hiddenWho)
    local out = { format("La Taverne %s, message log %s%s, %s", ns.version,
        msgLog.on and "on" or "off", msgLog.since and (" since " .. msgLog.since) or "",
        ns.Guild:IsSandbox() and "test mode (test guild + alliance)" or "real guild + alliance") }
    if ns.Guild:IsSandbox() and msgLog.realIgnored > 0 then
        out[#out + 1] = format("Real guild: %d messages ignored (test mode)", msgLog.realIgnored)
    end
    out[#out + 1] = format("Queues: guild %d, alliance %d", #queues.guild, #queues.ally)
    local quiet = msgLog.quiet
    out[#out + 1] = format("Map positions (not listed): %d in, %d out", quiet.positions["in"], quiet.positions.out)
    out[#out + 1] = format("Relayed guild lines (not listed): %d in, %d out", quiet.relayed["in"], quiet.relayed.out)
    out[#out + 1] = format("Hellos from my guild (not listed): %d", msgLog.guildQuiet.hellos)
    out[#out + 1] = format("My guild's lines, their authors' copies to the allies (not listed): %d", msgLog.guildQuiet.lines)
    if #msgLog.order == 0 then
        out[#out + 1] = "Unusual: none"
    else
        out[#out + 1] = "Unusual:"
        for _, kind in ipairs(msgLog.order) do
            local u = msgLog.unusual[kind]
            out[#out + 1] = format("  %d x %s   last: %s", u.count, kind, u.last)
        end
    end
    local shown, left = {}, 0
    for _, line in ipairs(msgLog.lines) do
        if (hiddenKinds and hiddenKinds[line.kind]) or (line.who and hiddenWho and hiddenWho[line.who]) then
            left = left + 1
        else
            shown[#shown + 1] = line.text
        end
    end
    local function Names(set, renames)
        local names = {}
        for key in pairs(set or {}) do names[#names + 1] = renames[key] or key end
        table.sort(names)
        return names
    end
    local kinds = Names(hiddenKinds, { [LOG_NOTES] = "notes" })
    local who = Names(hiddenWho, { [LOG_ME] = "me" })
    if #kinds > 0 or #who > 0 then
        out[#out + 1] = format("Not listed (%d lines): types %s; senders %s", left,
            #kinds > 0 and table.concat(kinds, ", ") or "none", #who > 0 and table.concat(who, ", ") or "none")
    end
    out[#out + 1] = format("--- last %d lines (newest at the bottom) ---", LOG_MAX)
    for _, text in ipairs(shown) do out[#out + 1] = text end
    return table.concat(out, "\n")
end

-- How many lines of each type, and from each sender, the log has now (for the filters).
function Comm:LogCounts()
    local kinds, who = {}, {}
    for _, line in ipairs(msgLog.lines) do
        kinds[line.kind] = (kinds[line.kind] or 0) + 1
        if line.who then who[line.who] = (who[line.who] or 0) + 1 end
    end
    return kinds, who
end

-- Versions: every message carries the sender's La Taverne version (payload.ver), so a player on
-- an old version hears that a newer one is in use (once per session), and the Players page can
-- show who's behind.
local versions = {}  -- [name key] = "0.21.0"
local newerSeen

function Comm:GetVersion(name)
    return name and versions[ns.NameKey(name)]
end

local function NoteVersion(sender, v)
    if type(v) ~= "string" or #v > 16 or not v:match("^%d+%.%d+") then return end
    versions[ns.NameKey(sender)] = v
    if ns.version == "?" or ns.CompareVersions(v, ns.version) <= 0 then return end
    if not newerSeen or ns.CompareVersions(v, newerSeen) > 0 then
        newerSeen = v
        ns.Print(format(ns.L["A newer La Taverne (%s) is in use. You have %s: ask for the new version, so everything keeps working together."], v, ns.version))
    end
end

-- Register a handler for the guild scope: fn(sender, payload, isSelf)
function Comm:On(msgType, fn)
    self:OnScope("guild", msgType, fn)
end

-- Register a handler for the allied scope: fn(sender, payload, isSelf)
function Comm:OnAlly(msgType, fn)
    self:OnScope("ally", msgType, fn)
end

function Comm:OnScope(scope, msgType, fn)
    handlers[scope] = handlers[scope] or {}
    handlers[scope][msgType] = handlers[scope][msgType] or {}
    table.insert(handlers[scope][msgType], fn)
end

local function Dispatch(scope, msgType, sender, payload, protocol, size)
    local list = handlers[scope] and handlers[scope][msgType]
    local isSelf = ns.IsMe(sender)
    if msgLog.on and not isSelf then
        local bad = type(payload.ver) ~= "string"
            or (scope == "ally" and (type(payload.g) ~= "string" or type(payload.n) ~= "number"))
        if not list then
            local v = type(payload.ver) == "string" and payload.ver or "?"
            Trace("in", scope, msgType, sender, size, "no handler (sender has " .. v .. ")", payload, "unknown type")
        else
            Trace("in", scope, msgType, sender, size, "delivered", payload, bad and "bad field" or nil)
        end
    end
    if not list then return end
    if not isSelf and type(payload) == "table" then NoteVersion(sender, payload.ver) end
    for _, fn in ipairs(list) do
        if msgLog.on then
            -- One crashing handler: logged, still reported, and the next ones still run.
            xpcall(function() fn(sender, payload, isSelf, protocol) end, function(err)
                Comm:LogNote(format("%s handler crashed: %s", msgType, tostring(err)), "handler error (" .. msgType .. ")")
                geterrorhandler()(err)
            end)
        else
            fn(sender, payload, isSelf, protocol)
        end
    end
end

-- Hidden channels -------------------------------------------------------------------
-- A channel is { role, name, password, ready, failed, tries, expires }.
-- Roles: "sandbox" (test channel), "ally" (current alliance channel), "allyOld" (previous
-- alliance channel, kept for a few minutes after a key change so nothing is lost meanwhile).

local channels = {}

local function ChannelByName(name)
    if not name then return nil end
    local lower = name:lower()
    for _, ch in pairs(channels) do
        if ch.name:lower() == lower then return ch end
    end
    return nil
end

local function ChannelId(ch)
    local id = GetChannelName(ch.name)
    if id and id > 0 then return id end
    return nil
end

local function HideChannel(name)
    if not ChatFrame_RemoveChannel then return end
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, name) end
    end
end

-- The game asks for a password with a popup when the channel's password doesn't match.
-- Never leave that popup to the player: close it and report the problem instead. Not with the
-- gamepad UI on: closed by an addon, it makes the gamepad manager call protected functions
-- (ADDON_ACTION_FORBIDDEN). The chat line then says to close it with Cancel.
local function HidePasswordPopup()
    if StaticPopup_Hide and not ns.GamepadUI() then
        StaticPopup_Hide("CHAT_CHANNEL_PASSWORD")
    end
end

local FlushQueue -- defined below

-- A reload doesn't leave the game's channels: after switching test mode, I'm still in the side
-- I left (the real alliance channel in test mode, the test ones back in the real guild), and
-- its messages keep coming (rejected, but there). Once one of mine is ready, leave every
-- La Taverne channel (LaTaverneA..., LaTaverneT...) that none of my roles uses.
function Comm:LeaveStrayChannels()
    for i = 1, (MAX_WOW_CHAT_CHANNELS or 20) do
        local _, name = GetChannelName(i)
        if type(name) == "string" and not ChannelByName(name) then
            local lower = name:lower()
            if lower:match("^latavernea%w+$") or lower:match("^latavernet%w+$") then
                LeaveChannelByName(name)
                self:LogNote("left " .. name .. " (not used any more)")
            end
        end
    end
end

-- Switching test mode, right before the reload: leave the side I'm leaving.
function Comm:LeaveAllChannels()
    for role in pairs(channels) do self:LeaveChannel(role) end
end

-- Messages not gone out yet: waiting for a channel here, or held by the game's throttle.
function Comm:Pending()
    if #queues.guild > 0 or #queues.ally > 0 then return true end
    local ctl = _G.ChatThrottleLib
    return ctl and ctl.bQueueing and true or false
end

ns.On("CHAT_MSG_CHANNEL_NOTICE", function(notice, _, _, _, _, _, _, _, baseName)
    local ch = ChannelByName(baseName)
    if not ch then return end
    if notice == "WRONG_PASSWORD" or notice == "BANNED" then
        ch.failed = true
        ch.ready = false
        HidePasswordPopup()
        C_Timer.After(0.1, HidePasswordPopup)
        ns.Print("could not join the hidden channel " .. ch.name .. " (" .. notice .. "). Messages there are disabled until the next reload."
            .. (ns.GamepadUI() and (" " .. ns.L["Close the password window with Cancel (B)."]) or ""))
    elseif notice == "YOU_LEFT" then
        -- Dropped by the game (not by me: LeaveChannel forgets the channel first): back in shortly.
        ch.ready = false
        Comm:LogNote("dropped from " .. ch.name .. ": joining again")
        C_Timer.After(2, function() Comm:Reconnect(ch) end)
    end
end)

-- A freshly joined channel rejects messages for a moment (InvalidChannel), so send a tiny
-- probe on a prefix nobody listens to until the game accepts it.
local function Probe(ch)
    if channels[ch.role] ~= ch or ch.failed then
        ch.probing = false
        return
    end
    local id = ChannelId(ch)
    if id then
        local result = C_ChatInfo.SendAddonMessage(PROBE_PREFIX, "p", "CHANNEL", id)
        if result == 0 or result == true then
            ch.probing = false
            if ch.lost then Comm:LogNote("back in " .. ch.name) end
            ch.ready, ch.lost = true, nil
            HideChannel(ch.name)
            FlushQueue()
            Comm:LeaveStrayChannels()
            if Comm.onReady then Comm.onReady(ch.role) end
            for _, fn in ipairs(Comm.readyListeners) do fn(ch.role) end
            return
        end
    end
    ch.tries = ch.tries + 1
    if ch.tries < 40 then
        C_Timer.After(0.5, function() Probe(ch) end)
    else
        ch.probing = false
        -- Said once; the watchdog (Comm:Reconnect, every 15 s) keeps trying.
        if not ch.warned then
            ch.warned = true
            ns.Print("could not join the hidden channel " .. ch.name .. " (trying again)")
        end
    end
end

-- A channel of mine that isn't ready (the game dropped me, or a send found it gone): join it
-- again if I'm not in it any more, then probe until it takes messages. Not a channel refused
-- for its password or a ban (that would bring the password popup back).
function Comm:Reconnect(ch)
    if not ch or channels[ch.role] ~= ch or ch.failed or ch.ready or ch.probing then return end
    ch.lost = true
    if GetChannelName(ch.name) == 0 then JoinTemporaryChannel(ch.name, ch.password) end
    ch.tries, ch.probing = 0, true
    C_Timer.After(0.5, function() Probe(ch) end)
end

-- Join (or rejoin) a hidden channel for a role. Replaces what the role had before.
function Comm:JoinChannel(role, name, password)
    local old = channels[role]
    if old and old.name == name and (old.ready or not old.failed) then return end
    if old and old.name ~= name then self:LeaveChannel(role) end
    local ch = { role = role, name = name, password = password, ready = false, failed = false, tries = 0, probing = true }
    channels[role] = ch
    if GetChannelName(name) == 0 then
        JoinTemporaryChannel(name, password)
    end
    C_Timer.After(0.5, function() Probe(ch) end)
end

function Comm:LeaveChannel(role)
    local ch = channels[role]
    if not ch then return end
    channels[role] = nil
    -- Another role may use the same channel (sandbox tests): only leave when nobody does.
    if ChannelByName(ch.name) then return end
    if GetChannelName(ch.name) ~= 0 then
        LeaveChannelByName(ch.name)
    end
end

-- Keep the previous alliance channel around for a while after a key change.
function Comm:RetireAllyChannel(seconds)
    local ch = channels.ally
    if not ch then return end
    channels.ally = nil
    if channels.allyOld then self:LeaveChannel("allyOld") end
    ch.role = "allyOld"
    channels.allyOld = ch
    C_Timer.After(seconds, function()
        if channels.allyOld == ch then Comm:LeaveChannel("allyOld") end
    end)
end

function Comm:GetChannel(role)
    return channels[role]
end

-- The test guild's channel name, for the dev and test commands.
function Comm:GetChannelName()
    return channels.sandbox and channels.sandbox.name or "(none: no LT:t line in the test Guild Info)"
end

function Comm:JoinFailed()
    return channels.sandbox and channels.sandbox.failed or false
end

function Comm:IsReady()
    if ns.Guild:IsSandbox() then return channels.sandbox ~= nil and channels.sandbox.ready end
    return IsInGuild()
end

function Comm:IsAllyReady()
    return channels.ally ~= nil and channels.ally.ready
end

-- The alliance channel's state, with its icon and color: ready, or connecting. Shown on the
-- Alliance page and in the minimap tooltip.
function Comm:AllyStatusText()
    if self:IsAllyReady() then
        return "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t |cff20ff20" .. ns.L["ready"] .. "|r"
    end
    return "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t |cffff9900" .. ns.L["connecting"] .. "|r"
end

-- Guild scope -------------------------------------------------------------------------

-- Where guild messages go right now, or nil if we can't send yet.
local function Route()
    if ns.Guild:IsSandbox() then
        local ch = channels.sandbox
        if not (ch and ch.ready) then return nil end
        local id = ChannelId(ch)
        if not id then
            ch.ready = false
            return nil
        end
        return "CHANNEL", id
    end
    if not IsInGuild() then return nil end
    return "GUILD"
end

local function SendGuildText(text, priority)
    local distribution, target = Route()
    if not distribution then return false end
    Comm:SendCommMessage(PREFIX, text, distribution, target, priority or "NORMAL")
    Comm.stats.sent = Comm.stats.sent + 1
    return true
end

-- Broadcast a message to the guild (or the sandbox channel).
-- priority: "BULK", "NORMAL" (default) or "ALERT" (chat).
-- noQueue: dropped instead of queued when it can't go now (a position: an old one is worth nothing).
function Comm:Send(msgType, payload, priority, noQueue)
    if ns.reloadPending then return false end -- test mode switched, the reload comes next
    payload = payload or {}
    payload.ver = ns.version
    local text = AceSerializer:Serialize(PROTOCOL, msgType, payload)
    if SendGuildText(text, priority) then
        Trace("out", "guild", msgType, nil, #text, "sent", payload)
        return true
    end
    if noQueue then
        Trace("out", "guild", msgType, nil, #text, "not sent: not ready (not queued)", payload)
        return false
    end
    if #queues.guild < MAX_QUEUE then
        queues.guild[#queues.guild + 1] = { text = text, priority = priority, msgType = msgType }
        Trace("out", "guild", msgType, nil, #text, "queued (" .. #queues.guild .. " waiting)", payload,
            #queues.guild == 10 and "queue growing" or nil)
    else
        Trace("out", "guild", msgType, nil, #text, "dropped: queue full", payload, "queue full")
    end
    return false
end

local function OnGuildReceive(prefix, text, distribution, sender)
    -- Only accept the route that matches the current mode.
    if ns.Guild:IsSandbox() then
        if distribution ~= "CHANNEL" then
            if msgLog.on and distribution == "GUILD" then msgLog.realIgnored = msgLog.realIgnored + 1 end
            return
        end
    elseif distribution ~= "GUILD" then
        return
    end

    local ok, protocol, msgType, payload = AceSerializer:Deserialize(text)
    if not ok or type(msgType) ~= "string" or type(payload) ~= "table" then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "guild", ok and msgType or "?", sender, #text, "rejected: unreadable", nil, "unreadable")
        return
    end
    if not ns.Guild:IsMember(sender) then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "guild", msgType, sender, #text, "rejected: not in the guild", payload, "sender not in the guild")
        if ns.Guild:IsSandbox() then
            ns.Log("ignored", msgType, "from", "[" .. tostring(sender) .. "]", "(not in the test guild - /taverne dev add " .. tostring(sender) .. ")")
        end
        return
    end
    Comm.stats.received = Comm.stats.received + 1
    ns.Guild:NoteSeen(sender)
    if ns.Players then ns.Players:NoteAddon(sender) end -- they run La Taverne

    Dispatch("guild", msgType, sender, payload, protocol, #text)
end

-- Allied scope ------------------------------------------------------------------------
-- Parts: "1" first of several, "2" middle, "3" last, "0" a whole message in one part. Parts
-- of a message in several carry the message's letter (PART_IDS) after the mark.
local PART_IDS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local partId = 0

local function SendOnChannel(ch, text, prio, prefix)
    local id = ChannelId(ch)
    if not id then
        ch.ready = false
        return false
    end
    prefix = prefix or ALLY_PREFIX
    if #text <= PART_SIZE then
        CTL:SendAddonMessage(prio, prefix, "0" .. text, "CHANNEL", id)
    else
        -- Each message of several parts gets its own letter after the mark, so two of them
        -- sent at once (different priorities, mixed by ChatThrottleLib) stay apart.
        partId = partId % #PART_IDS + 1
        local tag = PART_IDS:sub(partId, partId)
        local pos, len = 1, #text
        while pos <= len do
            local chunk = text:sub(pos, pos + PART_SIZE - 1)
            local mark = (pos == 1) and "1" or ((pos + PART_SIZE > len) and "3" or "2")
            CTL:SendAddonMessage(prio, prefix, mark .. tag .. chunk, "CHANNEL", id)
            pos = pos + PART_SIZE
        end
    end
    return true
end

-- During a key change, also send on the previous channel, for the guilds that haven't switched
-- yet. Receivers drop the copy (same sender and message number).
local function SendAllyText(text, priority, prefix)
    local ch = channels.ally
    if not (ch and ch.ready) then return false end
    local prio = priority or "NORMAL"
    if not SendOnChannel(ch, text, prio, prefix) then return false end
    local old = channels.allyOld
    if old and old.ready then SendOnChannel(old, text, prio, prefix) end
    Comm.stats.sent = Comm.stats.sent + 1
    return true
end

local allySerial = 0

-- Send to the allied guilds. Payload always gets the sender's guild name.
-- noQueue: as for Comm:Send. prefix: Comm.RELAY_PREFIX for the relay, nil otherwise.
function Comm:SendAlly(msgType, payload, priority, noQueue, prefix)
    if ns.reloadPending then return false end
    payload = payload or {}
    payload.g = ns.Guild:GetName()
    payload.ver = ns.version
    allySerial = allySerial + 1
    payload.n = math.random(1, 1000000) * 1000 + allySerial % 1000
    local text = AceSerializer:Serialize(PROTOCOL, msgType, payload)
    if SendAllyText(text, priority, prefix) then
        Trace("out", "ally", msgType, nil, #text, "sent", payload)
        return true
    end
    if noQueue then
        Trace("out", "ally", msgType, nil, #text, "not sent: channel not ready (not queued)", payload)
        return false
    end
    if #queues.ally < MAX_QUEUE then
        queues.ally[#queues.ally + 1] = { text = text, priority = priority, msgType = msgType, prefix = prefix }
        Trace("out", "ally", msgType, nil, #text, "queued (" .. #queues.ally .. " waiting)", payload,
            #queues.ally == 10 and "queue growing" or nil)
    else
        Trace("out", "ally", msgType, nil, #text, "dropped: queue full", payload, "queue full")
    end
    return false
end

FlushQueue = function()
    while #queues.guild > 0 do
        local item = queues.guild[1]
        if not SendGuildText(item.text, item.priority) then break end
        table.remove(queues.guild, 1)
        Trace("out", "guild", item.msgType, nil, #item.text, "sent from the queue")
    end
    while #queues.ally > 0 do
        local item = queues.ally[1]
        if not SendAllyText(item.text, item.priority, item.prefix) then break end
        table.remove(queues.ally, 1)
        Trace("out", "ally", item.msgType, nil, #item.text, "sent from the queue")
    end
end

-- Last channel check seen, for /taverne ally status (how the game reports the channel).
Comm.lastAllyCheck = nil

-- True when an addon message came through one of our alliance channels.
local function FromAllyChannel(target, localID, channelName)
    local candidates = { target, channelName }
    if localID and tonumber(localID) and tonumber(localID) > 0 then
        local _, name = GetChannelName(tonumber(localID))
        candidates[#candidates + 1] = name
    end
    for _, value in ipairs(candidates) do
        if type(value) == "string" and value ~= "" then
            local ch = ChannelByName(value)
            if ch and (ch.role == "ally" or ch.role == "allyOld") then return true end
        end
    end
    return false
end

local partial = {} -- [sender#channel] = { text, time }
-- Sent by my guild's members on the alliance channel only (no guild copy): AllyMap.lua's
-- positions, the hellos (Vouch.lua), which tell me which guildmates run La Taverne, and what the
-- relay (Relay.lua) needs from its own guild: the relay's messages (RLY, RCHAT) and the authors'
-- own copies of their lines (CHAT), to know which guild lines were already passed on. Read as
-- my guild's messages (guild handlers, not the allied ones: a guildmate's hello is never
-- answered, nothing of my guild goes through vouching, and my guild's lines are never shown
-- twice). "relay": only while something reads it (Relay.lua loaded); otherwise my guild's copy,
-- ignored as before, and not an unknown message in the message log.
local OWN_GUILD_ON_ALLY = { POS = true, HI = true, CHAT = "relay", RCHAT = "relay", RLY = "relay" }
local seen = {}    -- [sender .. "#" .. n] = time, to drop copies sent on two channels

local function AlreadySeen(sender, n)
    if not n then return false end
    local now = GetTime()
    local id = sender .. "#" .. tostring(n)
    if seen[id] and now - seen[id] < 120 then return true end
    seen[id] = now
    if math.random(1, 50) == 1 then
        for key, t in pairs(seen) do
            if now - t > 120 then seen[key] = nil end
        end
    end
    return false
end

local function OnAllyMessage(text, sender)
    local ok, protocol, msgType, payload = AceSerializer:Deserialize(text)
    if not ok or type(msgType) ~= "string" or type(payload) ~= "table" then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "ally", ok and msgType or "?", sender, #text, "rejected: unreadable", nil, "unreadable")
        return
    end
    -- The sender's guild must be one of ours, and a member of our own guild can't pose as another one.
    local guild = payload.g
    -- My guild's copy (allied guilds get it here, I got it on the guild channel): not logged.
    -- Except what my guild sends only here (OWN_GUILD_ON_ALLY): read as my guild's, from a member.
    if ns.Guild:IsMyGuild(guild) then
        local own = OWN_GUILD_ON_ALLY[msgType]
        if own == "relay" and not (handlers.guild and handlers.guild[msgType]) then own = nil end
        if own and ns.Guild:IsMember(sender) then
            if AlreadySeen(sender, payload.n) then return end
            Comm.stats.received = Comm.stats.received + 1
            ns.Guild:NoteSeen(sender)
            if ns.Players then ns.Players:NoteAddon(sender) end -- they run La Taverne
            Dispatch("guild", msgType, sender, payload, protocol, #text)
            return
        end
        Comm.stats.rejected = Comm.stats.rejected + 1
        return
    end
    if not ns.Alliance:IsAllied(guild) then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "ally", msgType, sender, #text, "rejected: guild not allied (" .. tostring(guild) .. ")", payload, "guild not allied")
        return
    end
    if ns.Guild:IsMember(sender) and not ns.Guild:IsMyGuild(guild) then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "ally", msgType, sender, #text, "rejected: my guild's member says another guild", payload, "guild member posing")
        return
    end
    if AlreadySeen(sender, payload.n) then
        if not ns.IsMe(sender) then Trace("in", "ally", msgType, sender, #text, "copy, already seen (key change)", payload) end
        return
    end
    if ns.MockGuild then ns.MockGuild:NoteAlly(sender, guild) end
    Comm.stats.received = Comm.stats.received + 1
    -- Vouching: is the sender really in that guild? Held until we know, dropped if not.
    if ns.Vouch and not ns.Vouch.EXEMPT[msgType] then
        local passed = ns.Vouch:Gate(sender, guild, function() Dispatch("ally", msgType, sender, payload, protocol, #text) end,
            ns.Vouch.PASSIVE[msgType])
        if not ns.IsMe(sender) then
            if passed == nil then
                Trace("in", "ally", msgType, sender, #text, "held: checking their guild", payload)
            elseif passed == false then
                Trace("in", "ally", msgType, sender, #text, "dropped: their guild says no", payload, "denied sender")
            end
        end
        return
    end
    Dispatch("ally", msgType, sender, payload, protocol, #text)

end

ns.On("CHAT_MSG_ADDON", function(prefix, message, distribution, sender, target, zoneChannelID, localID, channelName)
    if not ALLY_PREFIXES[prefix] then return end
    if distribution ~= "CHANNEL" then return end
    local fromOurs = FromAllyChannel(target, localID, channelName)
    Comm.lastAllyCheck = { target = target, localID = localID, channelName = channelName, ok = fromOurs }
    if not fromOurs then
        Comm.stats.rejected = Comm.stats.rejected + 1
        Trace("in", "ally", "?", sender, type(message) == "string" and #message or 0,
            "rejected: not from our channel (" .. tostring(channelName or target) .. ")", nil, "wrong channel")
        return
    end
    if type(message) ~= "string" or #message < 1 or type(sender) ~= "string" then return end
    local mark, body = message:sub(1, 1), message:sub(2)
    if mark == "0" then
        OnAllyMessage(body, sender)
        return
    end
    -- Parts are put together per sender, per prefix, per channel (two channels during a key
    -- change) and per message letter.
    local slot = sender .. "#" .. prefix .. "#" .. tostring(localID) .. "#" .. body:sub(1, 1)
    body = body:sub(2)
    if mark == "1" then
        partial[slot] = { text = body, time = GetTime() }
    elseif mark == "2" or mark == "3" then
        local p = partial[slot]
        if not p or GetTime() - p.time > 30 then
            partial[slot] = nil
            Trace("in", "ally", "?", sender, #body, p and "part too late: message lost" or "part without its start: message lost",
                nil, "broken parts")
            return
        end
        p.text = p.text .. body
        p.time = GetTime()
        if mark == "3" then
            partial[slot] = nil
            OnAllyMessage(p.text, sender)
        end
    end
end)

-- Sandbox channel ----------------------------------------------------------------

-- Test mode: each test guild has its own hidden channel, from the LT:t line of its fake Guild
-- Info. No line, no channel: testers elsewhere never end up sharing one.
function Comm:JoinSandbox()
    if not loggedIn then return end
    local key = ns.Alliance:GetTestKey()
    if not key then
        self:LeaveChannel("sandbox")
        return
    end
    local name = ns.Alliance.TestChannelFor(key)
    local current = channels.sandbox
    if current and current.name ~= name then self:LeaveChannel("sandbox") end
    self:JoinChannel("sandbox", name, key)
end

-- Other listeners for "a channel is ready" (the window shows the alliance channel's state).
Comm.readyListeners = {}
function Comm:OnReady(fn) self.readyListeners[#self.readyListeners + 1] = fn end

function Comm:IsLoggedIn()
    return loggedIn
end

-- Test mode: the log is always on from the start (still only the last LOG_MAX lines), so a
-- problem is there to copy without having thought of starting it. It can still be stopped.
function Comm:OnInit()
    if ns.Guild:IsSandbox() then self:SetLogging(true) end
end

function Comm:OnLogin()
    C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
    for prefix in pairs(ALLY_PREFIXES) do C_ChatInfo.RegisterAddonMessagePrefix(prefix) end
    self:RegisterComm(PREFIX, OnGuildReceive)
    C_Timer.After(JOIN_DELAY, function()
        loggedIn = true
        ns.Alliance:Refresh() -- joins the test guild channel and the alliance channel
    end)
    -- Watchdog: a channel that stopped being ready (dropped by the game, gone during a loading
    -- screen) joins again; before this it stayed "connecting" until a reload.
    C_Timer.NewTicker(15, function()
        for _, ch in pairs(channels) do Comm:Reconnect(ch) end
    end)
end

-- /taverne msglog [on | off | show]: no argument switches it on or off and shows it.
ns.commands.msglog = function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "on" or arg == "off" then
        Comm:SetLogging(arg == "on")
        ns.Print("message log " .. arg)
        return
    end
    if arg == "" then Comm:SetLogging(not Comm:IsLogging()) end
    if ns.ShowMessageLog then ns.ShowMessageLog() end
end
