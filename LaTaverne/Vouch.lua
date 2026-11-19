-- Vouching: is an allied player really in the guild they claim?
--
-- Anyone who knows the alliance key can talk on the alliance channel, and every message
-- claims a guild. The first time we hear from someone, we ask the channel "is X in guild B?"
-- and one online member of B running La Taverne answers from their roster (after a short
-- random delay; the others stay quiet once someone answered). Everyone keeps the answers.
--   confirmed:  normal.
--   denied:     their messages are dropped (allied chat, auto-invite, and later allied groups).
--   unverified: nobody from B answered (nobody online): let through (no mark in chat).
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
local ONLINE = 10 * 60                 -- heard from this recently: online
local BEAT = 240                       -- "still here" on the alliance channel, so idle players stay online
local HELLO_MIN, HELLO_MAX = 2, 15     -- random delay before answering a hello

-- Messages that are part of vouching itself are never held.
Vouch.EXEMPT = { VQ = true, VA = true }
-- A hello only says someone is online: it never starts a question (every login would send one
-- from each online ally). They're checked once they post or talk. Same for "who's inviting?".
Vouch.PASSIVE = { HI = true, INVITING_Q = true }

-- [nameKey] = { name, guild, state, by, source, t (answer time), seen, waiting, timer }
-- state: "checking", "confirmed", "unverified", "denied"; source: "answer", "game", "timeout"
local players = {}
local answering = {} -- [nameKey] = timer: I'm about to answer a question about this player

-- Allied players seen before, saved so the Alliance page isn't empty at login. Kept per guild
-- of mine (test guilds apart): [nameKey] = { name, guild, seen }. Only a name and a time:
-- vouching always starts over, nothing here is trusted.
local function Memory() return ns.SeenMemory("allySeen") end

local function SameGuild(a, b)
    return type(a) == "string" and type(b) == "string" and strtrim(a):lower() == strtrim(b):lower()
end

local function Remember(entry)
    local memory = Memory()
    if not memory then return end
    local key = ns.NameKey(entry.name)
    if entry.state == "denied" then memory[key] = nil return end
    -- Runs on every allied message: update in place, a new table only for someone new.
    -- checked: they got past a hello at least once (a hello alone only lists them on the
    -- Alliance page; Find and the name autocomplete want more than a claim).
    local checked = entry.state ~= nil and entry.state ~= "checking" or nil
    local item = memory[key]
    if item then
        if not SameGuild(item.guild, entry.guild) then item.checked = nil end
        item.name, item.guild, item.seen = entry.name, entry.guild, entry.seen
        item.checked = item.checked or checked
    else
        memory[key] = { name = entry.name, guild = entry.guild, seen = entry.seen, checked = checked }
    end
end

Vouch.stats = { asked = 0, answered = 0, confirmed = 0, denied = 0, unverified = 0, dropped = 0 }

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
        Remember(entry) -- forgets them
        if old ~= "denied" then
            local tag = ns.Alliance:GetTag(entry.guild) or entry.guild
            ns.Print(L["%s says they're in [%s], but [%s] says no: their messages are ignored."]:format(entry.name, tag, tag))
        end
        if waiting then Vouch.stats.dropped = Vouch.stats.dropped + #waiting end
    else
        if entry.seen then Remember(entry) end -- now checked
        if waiting then
            for _, fn in ipairs(waiting) do fn() end
        end
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
-- passive (a hello): never asks; passes unless they were denied.
function Vouch:Gate(sender, guild, fn, passive)
    local entry = Entry(sender, guild)
    entry.seen = GetServerTime()
    Remember(entry)
    if passive and entry.state ~= "denied" then
        Changed()
        fn()
        return true
    end

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

-- A player we heard from (not denied), or seen in an earlier session (the name autocomplete
-- offers them too): { name, guild } with their name as they wrote it.
function Vouch:Find(name)
    local key = ns.NameKey(name) or ""
    local entry = players[key]
    if entry and entry.state == "denied" then return nil end
    -- Heard from and checked (a hello alone isn't): what they claim. Otherwise remembered ones.
    if entry and entry.seen and entry.state then return { name = entry.name, guild = entry.guild } end
    local item = (Memory() or {})[key]
    if item and item.checked and ns.Alliance:IsAllied(item.guild) then return { name = item.name, guild = item.guild } end
    return nil
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
            out[#out + 1] = { name = entry.name, guild = entry.guild, online = now - entry.seen < ONLINE, starts = key:sub(1, #needle) == needle }
        end
    end
    -- Players seen before this session, offline as far as we know.
    for key, item in pairs(Memory() or {}) do
        if not players[key] and item.checked and key:find(needle, 1, true) and ns.Alliance:IsAllied(item.guild) and not ns.Guild:IsMember(item.name) then
            out[#out + 1] = { name = item.name, guild = item.guild, online = false, starts = key:sub(1, #needle) == needle }
        end
    end
    table.sort(out, function(a, b)
        if a.starts ~= b.starts then return a.starts end
        return a.name < b.name
    end)
    for i = #out, limit + 1, -1 do out[i] = nil end
    return out
end


-- Allied players heard from, most recent first: { name, guild, tag, state, by, source, seen, t,
-- online }, then the ones seen before this session ({ name, guild, tag, seen, remembered }).
function Vouch:GetPlayers()
    local list = {}
    local now = GetServerTime()
    for _, entry in pairs(players) do
        if entry.seen or entry.manual then
            list[#list + 1] = {
                name = entry.name, guild = entry.guild, tag = ns.Alliance:GetTag(entry.guild),
                state = entry.state, by = entry.by, source = entry.source, seen = entry.seen or entry.asked, t = entry.t,
                online = entry.seen and now - entry.seen < ONLINE or false,
            }
        end
    end
    for key, item in pairs(Memory() or {}) do
        if not players[key] then
            list[#list + 1] = { name = item.name, guild = item.guild, tag = ns.Alliance:GetTag(item.guild),
                seen = item.seen, remembered = true, online = false }
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
        return "|cffff9900" .. L["Not checked yet: nobody from [%s] was online to confirm they're a member. They still get through; it's checked again once someone from [%s] is online."]:format(tag, tag) .. "|r"
    elseif not item.state then
        -- Only said hello so far.
        return "|cff808080" .. L["Online. Checked once they post a group or talk."] .. "|r"
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

-- Hello: each addon says it's there when it joins the alliance channel, and the ones already
-- online answer (spread out; one answer covers everyone who said hello while it waited). So the
-- Alliance page shows who's online within seconds, not only players who post or talk. A
-- newcomer missed every message sent before it joined, so a hello is always answered. Then a
-- "still here" every few minutes keeps idle players online (online = heard in the last 10 min).
local helloTimer
local function SayHello(answer)
    ns.Comm:SendAlly("HI", { r = answer or nil })
end

ns.Comm:OnAlly("HI", function(sender, payload, isSelf)
    if isSelf or payload.r or helloTimer then return end
    helloTimer = C_Timer.NewTimer(HELLO_MIN + math.random() * (HELLO_MAX - HELLO_MIN), function()
        helloTimer = nil
        SayHello(true)
    end)
end)

-- The game shows allied players' real guild once they're in the group.
function Vouch:OnLogin()
    ns.Comm:OnReady(function(role)
        if role == "ally" and ns.Alliance:IsActive() then SayHello(false) end
    end)
    -- Still here (an answer: nobody answers it), a little spread so clients don't sync up.
    C_Timer.NewTicker(BEAT + math.random(0, 30), function()
        if ns.Alliance:IsActive() and ns.Comm:IsAllyReady() then SayHello(true) end
    end)
    ns.PruneSeen("allySeen")
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
