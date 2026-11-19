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
local PROTOCOL = 1
local JOIN_DELAY = 8   -- seconds after login, so the game's own channels (General, Trade...) keep their numbers
local MAX_QUEUE = 50
local PART_SIZE = 240  -- addon messages are limited to 255 bytes

local handlers = {}      -- ["guild" | "ally"][msgType] = { fn, ... }
local queues = { guild = {}, ally = {} } -- serialized messages waiting for a channel
local loggedIn = false

Comm.stats = { sent = 0, received = 0, rejected = 0 }

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

local function Dispatch(scope, msgType, sender, payload, protocol)
    local list = handlers[scope] and handlers[scope][msgType]
    if not list then return end
    local isSelf = ns.IsMe(sender)
    if not isSelf and type(payload) == "table" then NoteVersion(sender, payload.ver) end
    for _, fn in ipairs(list) do
        fn(sender, payload, isSelf, protocol)
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
-- Never leave that popup to the player: close it and report the problem instead.
local function HidePasswordPopup()
    if StaticPopup_Hide then
        StaticPopup_Hide("CHAT_CHANNEL_PASSWORD")
    end
end

local FlushQueue -- defined below

ns.On("CHAT_MSG_CHANNEL_NOTICE", function(notice, _, _, _, _, _, _, _, baseName)
    local ch = ChannelByName(baseName)
    if not ch then return end
    if notice == "WRONG_PASSWORD" or notice == "BANNED" then
        ch.failed = true
        ch.ready = false
        HidePasswordPopup()
        C_Timer.After(0.1, HidePasswordPopup)
        ns.Print("could not join the hidden channel " .. ch.name .. " (" .. notice .. "). Messages there are disabled until the next reload.")
    elseif notice == "YOU_LEFT" then
        ch.ready = false
    end
end)

-- A freshly joined channel rejects messages for a moment (InvalidChannel), so send a tiny
-- probe on a prefix nobody listens to until the game accepts it.
local function Probe(ch)
    if channels[ch.role] ~= ch or ch.failed then return end
    local id = ChannelId(ch)
    if id then
        local result = C_ChatInfo.SendAddonMessage(PROBE_PREFIX, "p", "CHANNEL", id)
        if result == 0 or result == true then
            ch.ready = true
            HideChannel(ch.name)
            FlushQueue()
            if Comm.onReady then Comm.onReady(ch.role) end
            for _, fn in ipairs(Comm.readyListeners) do fn(ch.role) end
            return
        end
    end
    ch.tries = ch.tries + 1
    if ch.tries < 40 then
        C_Timer.After(0.5, function() Probe(ch) end)
    else
        ns.Print("could not join the hidden channel " .. ch.name)
    end
end

-- Join (or rejoin) a hidden channel for a role. Replaces what the role had before.
function Comm:JoinChannel(role, name, password)
    local old = channels[role]
    if old and old.name == name and (old.ready or not old.failed) then return end
    if old and old.name ~= name then self:LeaveChannel(role) end
    local ch = { role = role, name = name, password = password, ready = false, failed = false, tries = 0 }
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
function Comm:Send(msgType, payload, priority)
    payload = payload or {}
    payload.ver = ns.version
    local text = AceSerializer:Serialize(PROTOCOL, msgType, payload)
    if SendGuildText(text, priority) then return true end
    if #queues.guild < MAX_QUEUE then
        queues.guild[#queues.guild + 1] = { text = text, priority = priority }
    end
    return false
end

local function OnGuildReceive(prefix, text, distribution, sender)
    -- Only accept the route that matches the current mode.
    if ns.Guild:IsSandbox() then
        if distribution ~= "CHANNEL" then return end
    elseif distribution ~= "GUILD" then
        return
    end

    local ok, protocol, msgType, payload = AceSerializer:Deserialize(text)
    if not ok or type(msgType) ~= "string" or type(payload) ~= "table" then
        Comm.stats.rejected = Comm.stats.rejected + 1
        return
    end
    if not ns.Guild:IsMember(sender) then
        Comm.stats.rejected = Comm.stats.rejected + 1
        if ns.Guild:IsSandbox() then
            ns.Log("ignored", msgType, "from", "[" .. tostring(sender) .. "]", "(not in the test guild - /taverne dev add " .. tostring(sender) .. ")")
        end
        return
    end
    Comm.stats.received = Comm.stats.received + 1
    ns.Guild:NoteSeen(sender)
    if ns.Players then ns.Players:NoteAddon(sender) end -- they run La Taverne

    Dispatch("guild", msgType, sender, payload, protocol)
end

-- Allied scope ------------------------------------------------------------------------
-- Parts: "1" first of several, "2" middle, "3" last, "0" a whole message in one part. Parts
-- of a message in several carry the message's letter (PART_IDS) after the mark.
local PART_IDS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local partId = 0

local function SendOnChannel(ch, text, prio)
    local id = ChannelId(ch)
    if not id then
        ch.ready = false
        return false
    end
    if #text <= PART_SIZE then
        CTL:SendAddonMessage(prio, ALLY_PREFIX, "0" .. text, "CHANNEL", id)
    else
        -- Each message of several parts gets its own letter after the mark, so two of them
        -- sent at once (different priorities, mixed by ChatThrottleLib) stay apart.
        partId = partId % #PART_IDS + 1
        local tag = PART_IDS:sub(partId, partId)
        local pos, len = 1, #text
        while pos <= len do
            local chunk = text:sub(pos, pos + PART_SIZE - 1)
            local mark = (pos == 1) and "1" or ((pos + PART_SIZE > len) and "3" or "2")
            CTL:SendAddonMessage(prio, ALLY_PREFIX, mark .. tag .. chunk, "CHANNEL", id)
            pos = pos + PART_SIZE
        end
    end
    return true
end

-- During a key change, also send on the previous channel, for the guilds that haven't switched
-- yet. Receivers drop the copy (same sender and message number).
local function SendAllyText(text, priority)
    local ch = channels.ally
    if not (ch and ch.ready) then return false end
    local prio = priority or "NORMAL"
    if not SendOnChannel(ch, text, prio) then return false end
    local old = channels.allyOld
    if old and old.ready then SendOnChannel(old, text, prio) end
    Comm.stats.sent = Comm.stats.sent + 1
    return true
end

local allySerial = 0

-- Send to the allied guilds. Payload always gets the sender's guild name.
function Comm:SendAlly(msgType, payload, priority)
    payload = payload or {}
    payload.g = ns.Guild:GetName()
    payload.ver = ns.version
    allySerial = allySerial + 1
    payload.n = math.random(1, 1000000) * 1000 + allySerial % 1000
    local text = AceSerializer:Serialize(PROTOCOL, msgType, payload)
    if SendAllyText(text, priority) then return true end
    if #queues.ally < MAX_QUEUE then
        queues.ally[#queues.ally + 1] = { text = text, priority = priority }
    end
    return false
end

FlushQueue = function()
    while #queues.guild > 0 do
        local item = queues.guild[1]
        if not SendGuildText(item.text, item.priority) then break end
        table.remove(queues.guild, 1)
    end
    while #queues.ally > 0 do
        local item = queues.ally[1]
        if not SendAllyText(item.text, item.priority) then break end
        table.remove(queues.ally, 1)
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
        return
    end
    -- The sender's guild must be one of ours, and a member of our own guild can't pose as another one.
    local guild = payload.g
    if not ns.Alliance:IsAllied(guild) or (ns.Guild:IsMember(sender) and not ns.Guild:IsMyGuild(guild)) then
        Comm.stats.rejected = Comm.stats.rejected + 1
        return
    end
    if AlreadySeen(sender, payload.n) then return end
    if ns.MockGuild then ns.MockGuild:NoteAlly(sender, guild) end
    Comm.stats.received = Comm.stats.received + 1
    -- Vouching: is the sender really in that guild? Held until we know, dropped if not.
    if ns.Vouch and not ns.Vouch.EXEMPT[msgType] then
        ns.Vouch:Gate(sender, guild, function() Dispatch("ally", msgType, sender, payload, protocol) end,
            ns.Vouch.PASSIVE[msgType])
        return
    end
    Dispatch("ally", msgType, sender, payload, protocol)

end

ns.On("CHAT_MSG_ADDON", function(prefix, message, distribution, sender, target, zoneChannelID, localID, channelName)
    if prefix ~= ALLY_PREFIX then return end
    if distribution ~= "CHANNEL" then return end
    local fromOurs = FromAllyChannel(target, localID, channelName)
    Comm.lastAllyCheck = { target = target, localID = localID, channelName = channelName, ok = fromOurs }
    if not fromOurs then
        Comm.stats.rejected = Comm.stats.rejected + 1
        return
    end
    if type(message) ~= "string" or #message < 1 or type(sender) ~= "string" then return end
    local mark, body = message:sub(1, 1), message:sub(2)
    if mark == "0" then
        OnAllyMessage(body, sender)
        return
    end
    -- Parts are put together per sender, per channel (two channels during a key change) and
    -- per message letter.
    local slot = sender .. "#" .. tostring(localID) .. "#" .. body:sub(1, 1)
    body = body:sub(2)
    if mark == "1" then
        partial[slot] = { text = body, time = GetTime() }
    elseif mark == "2" or mark == "3" then
        local p = partial[slot]
        if not p or GetTime() - p.time > 30 then
            partial[slot] = nil
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

function Comm:LeaveSandbox()
    wipe(queues.guild)
    self:LeaveChannel("sandbox")
end

-- Other listeners for "a channel is ready" (the window shows the alliance channel's state).
Comm.readyListeners = {}
function Comm:OnReady(fn) self.readyListeners[#self.readyListeners + 1] = fn end

function Comm:IsLoggedIn()
    return loggedIn
end

function Comm:OnLogin()
    C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
    C_ChatInfo.RegisterAddonMessagePrefix(ALLY_PREFIX)
    self:RegisterComm(PREFIX, OnGuildReceive)
    C_Timer.After(JOIN_DELAY, function()
        loggedIn = true
        ns.Alliance:Refresh() -- joins the test guild channel and the alliance channel
    end)
end
