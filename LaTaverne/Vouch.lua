-- Vouching: is an allied player really in the guild they claim?
--
-- Anyone who knows the alliance key can talk on the alliance channel, and every message
-- claims a guild. The first time we hear from someone, we ask the channel "is X in guild B?"
-- and one online member of B running La Taverne answers from their roster (after a short
-- random delay; the others stay quiet once someone answered). Everyone keeps the answers.
--   confirmed:  normal.
--   denied:     their messages are dropped (allied chat, auto-invite, and later allied groups).
--   unverified: nobody from B answered (nobody online): let through, with a "?" after the tag.
-- While we wait for the answer (a few seconds, only the first time), their messages are held.
-- Answers are kept 30 minutes (unverified: asked again after 5). Once the player is in our
-- party or raid, or targeted, the game's own guild info replaces the answers (not in debug
-- mode: the test guilds aren't real guilds).
local ADDON, ns = ...
local Vouch = ns.NewModule("Vouch")
local L = ns.L

local KEEP = 30 * 60
local KEEP_UNVERIFIED = 5 * 60
local WAIT = 4                         -- seconds to wait for an answer
local ANSWER_MIN, ANSWER_MAX = 0.3, 2  -- random delay before answering
local HOLD_MAX = 10                    -- messages held per player while waiting

-- Messages that are part of vouching itself are never held.
Vouch.EXEMPT = { VQ = true, VA = true }

-- [nameKey] = { name, guild, state, by, source, t (answer time), seen, waiting, timer }
-- state: "checking", "confirmed", "unverified", "denied"; source: "answer", "game", "timeout"
local players = {}
local answering = {} -- [nameKey] = timer: I'm about to answer a question about this player

Vouch.stats = { asked = 0, answered = 0, confirmed = 0, denied = 0, unverified = 0, dropped = 0 }

local function SameGuild(a, b)
    return type(a) == "string" and type(b) == "string" and strtrim(a):lower() == strtrim(b):lower()
end

local refreshPending = false
local function Changed()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.2, function()
        refreshPending = false
        if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
        if ns.MockGuild and ns.MockGuild.Refresh then ns.MockGuild:Refresh() end
    end)
end

-- The guild the game shows for this player, when they're in our group or targeted.
-- nil: not around, or the game doesn't know yet. Never in debug mode.
local function GameGuild(name)
    if ns.Guild:IsSandbox() then return nil end
    local key = ns.NameKey(name)
    local units = { "target", "mouseover" }
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and 40 or 4 do units[#units + 1] = (raid and "raid" or "party") .. i end
    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitIsPlayer(unit) and ns.NameKey(ns.FullName(unit)) == key then
            return (GetGuildInfo(unit))
        end
    end
    return nil
end

local function Fresh(entry)
    if not entry.t then return false end
    local age = GetServerTime() - entry.t
    return age < (entry.state == "unverified" and KEEP_UNVERIFIED or KEEP)
end

local function Settle(entry, state, by, source)
    local old = entry.state
    entry.state, entry.by, entry.source, entry.t = state, by, source, GetServerTime()
    if entry.timer then entry.timer:Cancel() entry.timer = nil end
    if old ~= state then Vouch.stats[state] = (Vouch.stats[state] or 0) + 1 end
    local waiting = entry.waiting
    entry.waiting = nil
    if state == "denied" then
        if old ~= "denied" then
            local tag = ns.Alliance:GetTag(entry.guild) or entry.guild
            ns.Print(L["%s says they're in [%s], but [%s] says no: their messages are ignored."]:format(entry.name, tag, tag))
        end
        if waiting then Vouch.stats.dropped = Vouch.stats.dropped + #waiting end
    elseif waiting then
        for _, fn in ipairs(waiting) do fn() end
    end
    Changed()
end

local function Ask(entry)
    Vouch.stats.asked = Vouch.stats.asked + 1
    entry.asked = GetServerTime()
    ns.Comm:SendAlly("VQ", { p = entry.name, pg = entry.guild }, "ALERT")
    entry.timer = C_Timer.NewTimer(WAIT, function()
        entry.timer = nil
        if entry.state == "denied" then
            -- Nobody answered this time: a denial stays until someone confirms them.
            entry.t = GetServerTime()
            if entry.waiting then Vouch.stats.dropped = Vouch.stats.dropped + #entry.waiting end
            entry.waiting = nil
            return
        end
        Settle(entry, "unverified", nil, "timeout")
    end)
end

local function Entry(name, guild)
    local key = ns.NameKey(name)
    local entry = players[key]
    if not entry or not SameGuild(entry.guild, guild) then
        if entry and entry.timer then entry.timer:Cancel() end
        entry = { name = name, guild = guild }
        players[key] = entry
    end
    return entry
end

-- Let a message from an allied player through (fn), hold it until we know, or drop it.
-- Returns true (passed now), nil (held) or false (dropped).
function Vouch:Gate(sender, guild, fn)
    local entry = Entry(sender, guild)
    entry.seen = GetServerTime()

    local real = GameGuild(sender)
    if real then
        local state = SameGuild(real, guild) and "confirmed" or "denied"
        if entry.source ~= "game" or entry.state ~= state then
            Settle(entry, state, nil, "game")
        else
            entry.t = GetServerTime()
        end
    end

    local state = entry.state
    if state == "denied" then
        if not Fresh(entry) and not entry.timer then Ask(entry) end
        Vouch.stats.dropped = Vouch.stats.dropped + 1
        Changed()
        return false
    end
    if state == "confirmed" or state == "unverified" then
        -- Old answer: let it through and ask again in the background.
        if not Fresh(entry) and not entry.timer then Ask(entry) end
        Changed()
        fn()
        return true
    end
    entry.state = "checking"
    entry.waiting = entry.waiting or {}
    if #entry.waiting < HOLD_MAX then entry.waiting[#entry.waiting + 1] = fn end
    if not entry.timer then Ask(entry) end
    Changed()
    return nil
end

-- "confirmed", "unverified", "denied", "checking", or nil (never heard of them).
function Vouch:GetState(name)
    local entry = players[ns.NameKey(name) or ""]
    return entry and entry.state or nil
end

function Vouch:IsDenied(name)
    return self:GetState(name) == "denied"
end

-- The allied guild a player belongs to, as far as we know (never for a denied player).
function Vouch:GetGuild(name)
    local entry = players[ns.NameKey(name) or ""]
    if not entry or not entry.state or entry.state == "denied" then return nil end
    return entry.guild
end

-- A player we heard from (not denied): { name, guild } with their name as they wrote it.
function Vouch:Find(name)
    local entry = players[ns.NameKey(name) or ""]
    if not entry or not entry.seen or entry.state == "denied" then return nil end
    return { name = entry.name, guild = entry.guild }
end

-- Allied players we heard from whose name contains the text, for name autocomplete.
-- online: heard from in the last 10 minutes.
function Vouch:Search(text, limit)
    local needle = ns.NameKey(text)
    local out = {}
    if not needle or needle == "" or (limit or 0) <= 0 then return out end
    local now = GetServerTime()
    for key, entry in pairs(players) do
        if entry.seen and entry.state ~= "denied" and key:find(needle, 1, true) and not ns.Guild:IsMember(entry.name) then
            out[#out + 1] = { name = entry.name, guild = entry.guild, online = now - entry.seen < 600, starts = key:sub(1, #needle) == needle }
        end
    end
    table.sort(out, function(a, b)
        if a.starts ~= b.starts then return a.starts end
        return a.name < b.name
    end)
    for i = #out, limit + 1, -1 do out[i] = nil end
    return out
end


-- Allied players heard from, most recent first: { name, guild, tag, state, by, source, seen, t }.
function Vouch:GetPlayers()
    local list = {}
    for _, entry in pairs(players) do
        if entry.seen or entry.manual then
            list[#list + 1] = {
                name = entry.name, guild = entry.guild, tag = ns.Alliance:GetTag(entry.guild),
                state = entry.state, by = entry.by, source = entry.source, seen = entry.seen or entry.asked, t = entry.t,
            }
        end
    end
    table.sort(list, function(a, b) return (a.seen or 0) > (b.seen or 0) end)
    return list
end

-- One line for a player's state, colored. Used by the Network tab and the test guild window.
function Vouch.StateText(item)
    local tag = item.tag or item.guild or "?"
    if item.state == "confirmed" then
        if item.source == "game" then return "|cff40ff40" .. L["In [%s] (the game says so)"]:format(tag) .. "|r" end
        return "|cff40ff40" .. L["Confirmed by %s"]:format(item.by or "?") .. "|r"
    elseif item.state == "denied" then
        return "|cffff4040" .. L["Not in [%s]"]:format(tag) .. "|r"
    elseif item.state == "unverified" then
        return "|cffff9900" .. L["Unverified: nobody from [%s] answered"]:format(tag) .. "|r"
    end
    return "|cff808080" .. L["Checking..."] .. "|r"
end

-- The state line of one player, or nil if never heard of.
function Vouch:Describe(name)
    local entry = players[ns.NameKey(name) or ""]
    if not entry or not entry.state then return nil end
    return Vouch.StateText({ state = entry.state, by = entry.by, source = entry.source,
        guild = entry.guild, tag = ns.Alliance:GetTag(entry.guild) })
end

-- Debug and officer helpers --------------------------------------------------------------------


-- Ask the allied guilds about any name (Debug tab). Each allied guild is asked.
function Vouch:AskAbout(name)
    name = strtrim(name or "")
    if name == "" or not ns.Alliance:IsActive() then return false end
    for _, g in ipairs(ns.Alliance:GetGuilds()) do
        if not ns.Guild:IsMyGuild(g.name) then
            local entry = Entry(name, g.name)
            -- A fresh question: the previous answer (even a denial) no longer counts.
            entry.manual = true
            entry.state, entry.source, entry.t, entry.by = "checking", nil, nil, nil

            if entry.timer then entry.timer:Cancel() entry.timer = nil end
            Ask(entry)
        end
    end
    Changed()
    return true
end

function Vouch:Forget()
    for _, entry in pairs(players) do
        if entry.timer then entry.timer:Cancel() end
    end
    wipe(players)
    Changed()
end

-- Messages ----------------------------------------------------------------------------------

-- A question: only members of the named guild answer, from their roster.
ns.Comm:OnAlly("VQ", function(sender, payload, isSelf)
    if isSelf then return end
    local name, guild = payload.p, payload.pg
    if type(name) ~= "string" or type(guild) ~= "string" or name == "" then return end
    if not ns.Guild:IsMyGuild(guild) then return end
    local key = ns.NameKey(name)
    if answering[key] then return end
    local ok
    if ns.IsMe(name) then
        -- Nobody answers about themselves. Debug mode: the test guild window can make me answer.
        local mode = ns.Guild:IsSandbox() and ns.db.dev.vouchSelf
        if mode ~= "yes" and mode ~= "no" then return end
        ok = mode == "yes"
    else
        if not ns.Guild:IsSandbox() and ns.Guild:GetRosterCount() == 0 then return end -- roster not loaded yet
        ok = ns.Guild:IsMember(name)
    end
    answering[key] = C_Timer.NewTimer(ANSWER_MIN + math.random() * (ANSWER_MAX - ANSWER_MIN), function()
        answering[key] = nil
        Vouch.stats.answered = Vouch.stats.answered + 1
        ns.Comm:SendAlly("VA", { p = name, pg = guild, ok = ok and true or false }, "ALERT")
    end)
end)

-- An answer: kept by everyone who hears it.
ns.Comm:OnAlly("VA", function(sender, payload, isSelf)
    if isSelf then return end
    local name, guild = payload.p, payload.pg
    if type(name) ~= "string" or type(guild) ~= "string" or name == "" then return end
    local key = ns.NameKey(name)
    -- Only a member of that guild can answer, never about themselves (except debug mode),
    -- and not someone who was denied themselves. Checked before anything else, so a fake
    -- answer can't silence the real ones.
    if not SameGuild(payload.g, guild) then return end
    if ns.NameKey(sender) == key and not ns.Guild:IsSandbox() then return end
    if Vouch:IsDenied(sender) then return end
    if ns.Guild:IsMyGuild(guild) then
        -- An answer about my own guild: I stay quiet only when a real member gave it (I have
        -- the roster). Nothing to learn from it.
        if answering[key] and ns.Guild:IsMember(sender) then
            answering[key]:Cancel()
            answering[key] = nil
        end
        return
    end
    -- We're waiting on another guild's answer about them (they claim that one): not this one.
    local existing = players[key]
    if existing and existing.waiting and not SameGuild(existing.guild, guild) then return end
    local entry = Entry(name, guild)

    if entry.source == "game" and Fresh(entry) then return end
    local state = payload.ok and "confirmed" or "denied"
    -- A denial wins over a confirmation for as long as it's kept.
    if state == "confirmed" and entry.state == "denied" and entry.source == "answer" and Fresh(entry) then return end
    Settle(entry, state, sender, "answer")
end)

-- The game shows allied players' real guild once they're in the group.
function Vouch:OnLogin()
    ns.On("GROUP_ROSTER_UPDATE", function()
        for _, entry in pairs(players) do
            local real = GameGuild(entry.name)
            if real then
                local state = SameGuild(real, entry.guild) and "confirmed" or "denied"
                if entry.source ~= "game" or entry.state ~= state then Settle(entry, state, nil, "game") end
            end
        end
    end)
end

-- For /taverne ally (Guild Alliance status in the Debug tab).
function Vouch:Report(log)
    local s = self.stats
    log("vouching: asked", s.asked, "answered", s.answered, "confirmed", s.confirmed, "denied", s.denied,
        "unverified", s.unverified, "messages dropped", s.dropped,
        "questions about me", ns.Guild:IsSandbox() and tostring(ns.db.dev.vouchSelf or "quiet") or "quiet")
    for _, item in ipairs(self:GetPlayers()) do
        log("  ", item.name, "[" .. tostring(item.tag or item.guild) .. "]", item.state or "?",
            item.source or "", item.by and ("by " .. item.by) or "")
    end
end
