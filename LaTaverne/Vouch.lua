-- Vouching: is an allied player really in the guild they claim?
--
-- Anyone who knows the alliance key can talk on the alliance channel, and every message
-- claims a guild. Trust comes from evidence, kept in a ledger (saved, for the whole account):
--   tier 1: seen first-hand. The game showed their guild (group, target, mouseover, nameplate),
--           or one of my characters saw them on that guild's roster (Guild.lua saves it).
--   tier 2: told by someone I trust (later: guildmates, a guild's relay).
--   tier 3: their claim only.
-- The newest tier 1-2 record wins (the tier only breaks a tie; a claim never overrides one):
-- "in B" confirms a claim of B; "in C" denies it; "missing from B's roster" only disputes it
-- (that roster was saved by one of my other characters, they may have joined since). Records are kept
-- 7 days (tier 1) or 1 day (tier 2). If the game shows no guild, that's no evidence at all.
--
-- With no record, the older questions decide, as a fallback: the first time we hear from
-- someone, we ask the channel "is X in guild B?" and one online member of B running La Taverne
-- answers from their roster (after a short random delay; the others stay quiet once someone
-- answered). Everyone keeps the answers 30 minutes (unverified: asked again after 5).
--   confirmed:  normal.
--   denied:     their messages are dropped (allied chat, auto-invite, allied groups), with one
--               line in chat per session saying why, and a count on the Alliance page.
--   disputed:   a "no" from someone nobody vouches for: let through, with a mark in lists;
--               auto-invite waits for a click.
--   unverified: "not checked yet", nothing for or against them: let through (no mark in chat);
--               auto-invite waits for a click.
-- While we wait for the answer (a few seconds, only the first time), their messages are held.
-- No game evidence in test mode, and the ledger isn't read there: the test guilds aren't real.
local ADDON, ns = ...
local Vouch = ns.NewModule("Vouch")
local L = ns.L

local KEEP = 30 * 60
local KEEP_UNVERIFIED = 5 * 60
local WAIT = 4                         -- seconds to wait for an answer
local ASK_DELAY_MAX = 2                -- random wait before asking (someone else may ask first)
local ANSWER_MIN, ANSWER_MAX = 0.3, 2  -- random delay before answering
local HOLD_MAX = 10                    -- messages held per player while waiting
local ONLINE = 10 * 60                 -- heard from this recently: online
local BEAT = 240                       -- "still here" on the alliance channel, so idle players stay online
local HELLO_MIN, HELLO_MAX = 2, 15     -- random delay before answering a hello

-- Evidence ledger.
local TIER_KEEP = { 7 * 24 * 3600, 24 * 3600 } -- records kept: tier 1, tier 2
local SNAPSHOT_DENY = 24 * 3600 -- missing from a roster snapshot this recent: disputed (not denied)
local OTHER_DENY = 24 * 3600    -- seen in another guild this recent: denied (older: disputed)
local RECORD_QUIET = 60         -- the same sighting again within a minute isn't written
local RECORDS_MAX = 6           -- records kept per player (the newest)
local SECOND_LOOK = 1           -- the game showed no guild: look once more after this (seconds)

-- Messages that are part of vouching itself are never held.
Vouch.EXEMPT = { VQ = true, VA = true }
-- A hello only says someone is online: it never starts a question (every login would send one
-- from each online ally). They're checked once they post or talk. Same for "who's inviting?".
-- Map positions (every few seconds from each ally) too, and without refreshing the window for
-- each one ("quiet": only when the player is new).
-- The relay's coordination (RLY: claims, beacons, Relay.lua) only says who relays: quiet too.
-- So do the positions a relay passes on (RMAP, every 30 s to 2 min).
Vouch.PASSIVE = { HI = true, INVITING_Q = true, POS = "quiet", RLY = "quiet", RMAP = "quiet" }

-- [nameKey] = { name, guild, state, by, source, t (answer time), seen, waiting, timer, shown,
-- hidden }. state, by, source, t: the answers (state: "checking", "confirmed", "unverified",
-- "denied", "disputed"; source: "answer", "timeout"). shown: the state last worked out with the
-- evidence (StateOf). hidden: messages dropped this session.
local players = {}
local answering = {} -- [nameKey] = timer: I'm about to answer a question about this player
local told = {}      -- [nameKey] = true: the "messages hidden" line was shown this session

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- Allied players seen before, saved so the Alliance page isn't empty at login. Kept per guild
-- of mine (test guilds apart): [nameKey] = { name, guild, seen }. Only a name and a time:
-- nothing here is trusted (the evidence has its own ledger).
local function Memory() return ns.SeenMemory("allySeen") end

local function SameGuild(a, b)
    return type(a) == "string" and type(b) == "string" and strtrim(a):lower() == strtrim(b):lower()
end

local function TagOf(guild) return ns.Alliance:GetTag(guild) or guild or "?" end

local function Ago(t)
    local seconds = GetServerTime() - (t or 0)
    if seconds < 60 then return L["just now"] end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return format(L["%d min ago"], minutes) end
    local hours = math.floor(minutes / 60)
    if hours < 48 then return format(L["%d h ago"], hours) end
    return format(L["%d d ago"], math.floor(hours / 24))
end

Vouch.stats = { asked = 0, answered = 0, confirmed = 0, denied = 0, disputed = 0, unverified = 0, dropped = 0 }

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

-- Evidence ------------------------------------------------------------------------------------
-- ns.db.vouchLedger[nameKey] = { name, recs = { { g = guild, ok = in (true) / out (false),
-- src, w = witness, t, tier }, ... } }. Account-wide: what my alts saw counts too.
-- ns.db.rosterSnapshots[guild, lowercase] = { guild, t, by, partial, names = { [nameKey] } }
-- (written by Guild.lua). Neither is used in test mode.

local function Ledger()
    if ns.Guild:IsSandbox() then return nil end
    ns.db.vouchLedger = ns.db.vouchLedger or {}
    return ns.db.vouchLedger
end

local function Snapshots()
    if ns.Guild:IsSandbox() then return nil end
    return ns.db.rosterSnapshots
end

-- a beats b: newer, or as new from a higher tier (tier 1 above tier 2).
local function Better(t, tier, best)
    if not best then return true end
    if t ~= best.t then return t > best.t end
    return tier < (best.tier or 1)
end

-- The record that decides about a claim of this guild, or nil. A record "in" any guild decides
-- (another guild than the claim: against it); "out" of another guild says nothing about it.
local function Evidence(key, claimed)
    if not key or type(claimed) ~= "string" then return nil end
    local now = GetServerTime()
    local best
    local book = Ledger()
    local item = book and book[key]
    if type(item) == "table" and type(item.recs) == "table" then
        for _, rec in ipairs(item.recs) do
            if now - rec.t < (TIER_KEEP[rec.tier or 1] or 0) and (rec.ok or SameGuild(rec.g, claimed))
                and Better(rec.t, rec.tier or 1, best) then
                best = rec
            end
        end
    end
    -- My characters' rosters: on one, they're in that guild. Missing from the claimed guild's
    -- (ok = false): only a doubt, while the snapshot is recent and complete. It was saved by one
    -- of my other characters (an allied guild is never my current one): they may have joined
    -- since, so an answer from that guild still decides (StateOf).
    for _, snap in pairs(Snapshots() or {}) do
        if type(snap) == "table" and type(snap.names) == "table" and snap.t and now - snap.t < TIER_KEEP[1]
            and Better(snap.t, 1, best) then
            if snap.names[key] then
                best = { g = snap.guild, ok = true, src = "roster", w = snap.by, t = snap.t, tier = 1 }
            elseif SameGuild(snap.guild, claimed) and not snap.partial and now - snap.t < SNAPSHOT_DENY then
                best = { g = snap.guild, ok = false, src = "roster", w = snap.by, t = snap.t, tier = 1 }
            end
        end
    end
    return best
end

-- What a deciding record says about a claim. Seen in another guild long ago: they may have
-- moved since, only disputed. Missing from an old roster: disputed too.
local function Verdict(rec, claimed)
    if not rec.ok then return "disputed" end
    if SameGuild(rec.g, claimed) then return "confirmed" end
    return GetServerTime() - rec.t < OTHER_DENY and "denied" or "disputed"
end

-- A player's state: the evidence first, the answers otherwise. Returns the state and the
-- deciding record (nil when the answers decide).
-- Only a doubt (missing from an old roster, Evidence): the answers still decide when they said
-- yes or no; otherwise disputed. The questions go on meanwhile (Gate).
local function Absence(rec) return rec ~= nil and not rec.ok end

local function StateOf(entry)
    local rec = Evidence(ns.NameKey(entry.name), entry.guild)
    if Absence(rec) and (entry.state == "confirmed" or entry.state == "denied") then return entry.state, nil end
    if rec then return Verdict(rec, entry.guild), rec end
    return entry.state, nil
end

-- Someone I can vouch for in that guild: evidence, or confirmed by an answer.
local function Vouched(name, guild)
    local key = ns.NameKey(name)
    local rec = Evidence(key, guild)
    if rec and rec.ok then return Verdict(rec, guild) == "confirmed" end
    local entry = players[key]
    return entry ~= nil and SameGuild(entry.guild, guild) and entry.state == "confirmed"
end

local SOURCE_TEXT = { group = "in the group", target = "target", mouseover = "mouseover",
    nameplate = "nameplate", roster = "guild roster" }

-- One line saying why, for the Alliance page and the chat line. nil: nothing to say.
local function Reason(rec, entry)
    if rec then
        if rec.ok then
            return L["Seen in [%s] by %s (%s), %s."]:format(TagOf(rec.g), rec.w or "?",
                L[SOURCE_TEXT[rec.src] or tostring(rec.src)], Ago(rec.t))
        end
        return L["Not on the [%s] roster %s saw %s."]:format(TagOf(rec.g), rec.w or "?", Ago(rec.t))
    end
    if entry.state == "confirmed" then return L["Confirmed by %s"]:format(entry.by or "?") end
    if entry.state == "denied" then
        return L["%s, a member of [%s], says this player isn't in it."]:format(entry.by or "?", TagOf(entry.guild))
    end
    if entry.state == "disputed" then
        return L["%s says this player isn't in [%s], but %s isn't confirmed either."]:format(entry.by or "?",
            TagOf(entry.guild), entry.by or "?")
    end
    return nil
end

local function Remember(entry, state)
    local memory = Memory()
    if not memory then return end
    local key = ns.NameKey(entry.name)
    if state == "denied" then memory[key] = nil return end
    -- Runs on every allied message: update in place, a new table only for someone new.
    -- checked: they got past a hello at least once (a hello alone only lists them on the
    -- Alliance page; Find and the name autocomplete want more than a claim).
    local checked = state ~= nil and state ~= "checking" or nil
    local item = memory[key]
    if item then
        if not SameGuild(item.guild, entry.guild) then item.checked = nil end
        item.name, item.guild, item.seen = entry.name, entry.guild, entry.seen
        item.checked = item.checked or checked
    else
        memory[key] = { name = entry.name, guild = entry.guild, seen = entry.seen, checked = checked }
    end
end

local function Hide(entry, n)
    entry.hidden = (entry.hidden or 0) + n
    Vouch.stats.dropped = Vouch.stats.dropped + n
end

-- One line per denied player per session, saying why (only players we heard from).
local function Notice(entry, rec)
    local key = ns.NameKey(entry.name)
    if told[key] or not entry.seen then return end
    told[key] = true
    ns.Print(L["%s says they're in [%s]. %s Their messages are hidden."]:format(entry.name, TagOf(entry.guild),
        Reason(rec, entry) or ""))
end

-- An answer or a record changed: work the state out again, then let held messages through or
-- drop them.
local function Recheck(entry)
    local state, rec = StateOf(entry)
    local old = entry.shown
    entry.shown = state
    if state ~= old and state and state ~= "checking" then Vouch.stats[state] = (Vouch.stats[state] or 0) + 1 end
    -- The evidence decided: no need to ask (or wait for the answer). Asked again if it expires.
    if rec and rec.ok and entry.timer then
        entry.timer:Cancel()
        entry.timer, entry.asking = nil, nil
    end
    if state == "denied" then
        local waiting = entry.waiting
        entry.waiting = nil
        Remember(entry, state) -- forgets them
        if waiting then Hide(entry, #waiting) end
        if old ~= "denied" then
            Notice(entry, rec)
            ns.Comm:LogNote(format("%s is not in [%s] (%s): %d held messages dropped", entry.name, tostring(entry.guild),
                tostring(rec and rec.src or entry.source), waiting and #waiting or 0), "denied sender")
        end
    elseif state and state ~= "checking" then
        local waiting = entry.waiting
        entry.waiting = nil
        if entry.seen then Remember(entry, state) end -- now checked
        if waiting then
            for _, fn in ipairs(waiting) do fn() end
        end
    end
    Changed()
end

-- First-hand: the game shows this player in this guild. Kept for players we heard from (any
-- guild: it may go against their claim) and for the allied guilds' members.
local function Record(name, guild, src)
    local key = ns.NameKey(name)
    local entry = players[key]
    if not entry and not ns.Alliance:IsAllied(guild) then return end
    local book = Ledger()
    if not book then return end
    local now = GetServerTime()
    local me = ns.FullName("player")
    local item = book[key]
    if type(item) ~= "table" or type(item.recs) ~= "table" then
        item = { recs = {} }
        book[key] = item
    end
    item.name = name
    local rec
    for _, r in ipairs(item.recs) do
        if r.ok and SameGuild(r.g, guild) then rec = r break end
    end
    if rec then
        if now - rec.t < RECORD_QUIET then return end
        rec.g, rec.src, rec.w, rec.t, rec.tier = guild, src, me, now, 1
    else
        table.insert(item.recs, 1, { g = guild, ok = true, src = src, w = me, t = now, tier = 1 })
        if #item.recs > RECORDS_MAX then
            table.sort(item.recs, function(a, b) return a.t > b.t end)
            for i = #item.recs, RECORDS_MAX + 1, -1 do item.recs[i] = nil end
        end
    end
    if entry then Recheck(entry) end
end

-- A yes from the game we can use: true, and not a secret value (testing a secret errors).
local function Yes(v) return not IsSecret(v) and v and true or false end

-- The unit's player name, or nil (no player there, me, or a secret name).
local function UnitPlayer(unit)
    if not Yes(UnitExists(unit)) or not Yes(UnitIsPlayer(unit)) or Yes(UnitIsUnit(unit, "player")) then return nil end
    local first, last = UnitName(unit)
    if IsSecret(first) or IsSecret(last) or type(first) ~= "string" then return nil end
    return ns.FullName(unit)
end

-- What the game shows about a unit: a player and a guild, into the ledger. No guild shown: no
-- evidence. It's often not known yet the first time (seen: nil, then the guild a second later),
-- so a nil gets one second look (expected: the same player still on that unit). Never in test
-- mode.
local function Sight(unit, src, expected)
    if ns.Guild:IsSandbox() then return end
    local name = UnitPlayer(unit)
    if not name or (expected and ns.NameKey(name) ~= ns.NameKey(expected)) then return end
    local guild = GetGuildInfo(unit)
    if IsSecret(guild) then return end
    if type(guild) ~= "string" or guild == "" then
        if not expected then C_Timer.After(SECOND_LOOK, function() Sight(unit, src, name) end) end
        return
    end
    Record(name, guild, src)
end

local function GroupUnit(i)
    if IsInRaid and IsInRaid() then return "raid" .. i end
    return i <= 4 and ("party" .. i) or nil
end

-- Everyone in my group.
local function ScanGroup()
    for i = 1, 40 do
        local unit = GroupUnit(i)
        if not unit then return end
        Sight(unit, "group")
    end
end

-- This player, if the game shows them right now (target, mouseover, group).
local function LookAt(name)
    if ns.Guild:IsSandbox() then return end
    local key = ns.NameKey(name)
    local function Is(unit)
        local seen = UnitPlayer(unit)
        return seen ~= nil and ns.NameKey(seen) == key
    end
    if Is("target") then Sight("target", "target") return end
    if Is("mouseover") then Sight("mouseover", "mouseover") return end
    for i = 1, 40 do
        local unit = GroupUnit(i)
        if not unit then return end
        if Is(unit) then Sight(unit, "group") return end
    end
end

-- Drop expired records and snapshots. At login.
local function Prune()
    local now = GetServerTime()
    local book = ns.db.vouchLedger
    if type(book) == "table" then
        for key, item in pairs(book) do
            local recs = type(item) == "table" and type(item.recs) == "table" and item.recs or nil
            if recs then
                for i = #recs, 1, -1 do
                    local r = recs[i]
                    if type(r) ~= "table" or type(r.t) ~= "number" or now - r.t >= (TIER_KEEP[r.tier or 1] or 0) then
                        table.remove(recs, i)
                    end
                end
            end
            if not recs or #recs == 0 then book[key] = nil end
        end
    end
    local snaps = ns.db.rosterSnapshots
    if type(snaps) == "table" then
        for key, snap in pairs(snaps) do
            if type(snap) ~= "table" or type(snap.t) ~= "number" or now - snap.t >= TIER_KEEP[1] then snaps[key] = nil end
        end
    end
end

-- Questions -----------------------------------------------------------------------------------

local function Fresh(entry)
    if not entry.t then return false end
    local age = GetServerTime() - entry.t
    return age < (entry.state == "unverified" and KEEP_UNVERIFIED or KEEP)
end

-- An answer (or no answer): the fallback when there's no evidence.
local function Settle(entry, state, by, source)
    entry.state, entry.by, entry.source, entry.t = state, by, source, GetServerTime()
    if entry.timer then entry.timer:Cancel() entry.timer = nil end
    entry.asking = nil
    Recheck(entry)
end

-- Everyone hearing a new player would ask at once (and everyone hears the answer): wait a
-- moment first, and stay quiet if someone else asks about them meanwhile (entry.heardAsk).
-- now: ask right away (the Debug tab's button).
local function Ask(entry, now)
    entry.asked = GetServerTime()
    entry.asking, entry.heardAsk = true, nil
    entry.timer = C_Timer.NewTimer(now and 0 or math.random() * ASK_DELAY_MAX, function()
        entry.asking = false
        if not entry.heardAsk then
            Vouch.stats.asked = Vouch.stats.asked + 1
            ns.Comm:SendAlly("VQ", { p = entry.name, pg = entry.guild }, "ALERT")
        else
            ns.Comm:LogNote(format("someone else asked about %s: waiting for their answer", entry.name))
        end
        entry.heardAsk = nil
        entry.timer = C_Timer.NewTimer(WAIT, function()
            entry.timer = nil
            if entry.state == "denied" or entry.state == "disputed" then
                -- Nobody answered this time: a "no" stays until someone says yes.
                entry.t = GetServerTime()
                Recheck(entry)
                return
            end
            ns.Comm:LogNote(format("nobody from [%s] answered about %s: let through, not checked", tostring(entry.guild), entry.name))
            Settle(entry, "unverified", nil, "timeout")
        end)
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
    local isNew = entry.seen == nil
    entry.seen = GetServerTime()
    LookAt(sender) -- in my group, targeted...: what the game says goes in the ledger first
    local state, rec = StateOf(entry)
    Remember(entry, state)
    if passive and state ~= "denied" then
        if passive ~= "quiet" or isNew then Changed() end
        fn()
        return true
    end

    if state == "denied" then
        -- Only the answers say so: an old answer is asked again in the background.
        if not rec and not Fresh(entry) and not entry.timer then Ask(entry) end
        if passive then
            Vouch.stats.dropped = Vouch.stats.dropped + 1
        else
            Hide(entry, 1)
        end
        Notice(entry, rec)
        Changed()
        return false
    end
    if state == "confirmed" or state == "unverified" or state == "disputed" then
        -- Old answer (and no evidence, or only a doubt): let it through and ask again in the
        -- background.
        if (not rec or Absence(rec)) and not Fresh(entry) and not entry.timer then Ask(entry) end
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

-- "confirmed", "unverified", "disputed", "denied", "checking", or nil (never heard of them).
function Vouch:GetState(name)
    local entry = players[ns.NameKey(name) or ""]
    if not entry then return nil end
    return (StateOf(entry))
end

function Vouch:IsDenied(name)
    return self:GetState(name) == "denied"
end

-- Confirmed (not "not checked yet", "disputed", or anything else): auto-invite may invite them
-- without a click.
function Vouch:IsConfirmed(name)
    return self:GetState(name) == "confirmed"
end

-- The mark after an allied player's name in lists: "(not checked yet)", "(disputed)", or "".
function Vouch:Mark(name)
    local state = self:GetState(name)
    if state == "unverified" then return " |cffff9900(" .. L["not checked yet"] .. ")|r" end
    if state == "disputed" then return " |cffff9900(" .. L["disputed"] .. ")|r" end
    return ""
end

-- The allied guild a player belongs to, as far as we know (never for a denied player).
function Vouch:GetGuild(name)
    local entry = players[ns.NameKey(name) or ""]
    if not entry then return nil end
    local state = StateOf(entry)
    if not state or state == "denied" then return nil end
    return entry.guild
end

-- A player we heard from (not denied), or seen in an earlier session (the name autocomplete
-- offers them too): { name, guild } with their name as they wrote it.
function Vouch:Find(name)
    local key = ns.NameKey(name) or ""
    local entry = players[key]
    local state = entry and StateOf(entry)
    if state == "denied" then return nil end
    -- Heard from and checked (a hello alone isn't): what they claim. Otherwise remembered ones.
    if entry and entry.seen and state then return { name = entry.name, guild = entry.guild } end
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
        if entry.seen and key:find(needle, 1, true) and StateOf(entry) ~= "denied" and not ns.Guild:IsMember(entry.name) then
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

-- One player as the lists want them: { name, guild, tag, state, by, source, reason, hidden, t }.
local function Item(entry)
    local state, rec = StateOf(entry)
    return {
        name = entry.name, guild = entry.guild, tag = ns.Alliance:GetTag(entry.guild),
        state = state, by = entry.by, source = rec and rec.src or entry.source, t = rec and rec.t or entry.t,
        reason = state and state ~= "checking" and state ~= "unverified" and Reason(rec, entry) or nil,
        hidden = entry.hidden,
    }
end

-- Allied players heard from, most recent first: { name, guild, tag, state, by, source, reason,
-- hidden, seen, t, online }, then the ones seen before this session ({ name, guild, tag, seen,
-- remembered }).
function Vouch:GetPlayers()
    local list = {}
    local now = GetServerTime()
    for _, entry in pairs(players) do
        if entry.seen or entry.manual then
            local item = Item(entry)
            item.seen = entry.seen or entry.asked
            item.online = entry.seen and now - entry.seen < ONLINE or false
            list[#list + 1] = item
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

-- One line for a player's state, colored. Used by the Alliance page and the test guild window.
function Vouch.StateText(item)
    local tag = item.tag or item.guild or "?"
    if item.state == "confirmed" then
        return "|cff40ff40" .. (item.reason or L["Confirmed by %s"]:format(item.by or "?")) .. "|r"
    elseif item.state == "denied" then
        return "|cffff4040" .. (item.reason and L["Not in [%s]: %s"]:format(tag, item.reason) or L["Not in [%s]"]:format(tag)) .. "|r"
    elseif item.state == "disputed" then
        return "|cffff9900" .. (item.reason and L["Disputed: %s"]:format(item.reason) or L["Disputed"]) .. "|r"
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
    if not entry then return nil end
    local item = Item(entry)
    if not item.state then return nil end
    return Vouch.StateText(item)
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
            Ask(entry, true)
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

-- A question: only members of the named guild answer, from their roster. The others note that
-- it was asked: no need to ask the same.
ns.Comm:OnAlly("VQ", function(sender, payload, isSelf)
    if isSelf then return end
    local name, guild = payload.p, payload.pg
    if type(name) ~= "string" or type(guild) ~= "string" or name == "" then return end
    if not ns.Guild:IsMyGuild(guild) then
        local entry = players[ns.NameKey(name)]
        if entry and entry.asking and SameGuild(entry.guild, guild) then entry.heardAsk = true end
        return
    end
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

-- An answer: kept by everyone who hears it (the fallback: any evidence overrides it).
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

    -- A "no" only counts from someone I can vouch for in that guild; from anyone else it only
    -- disputes them (an impostor can't get a real member's messages dropped). Test mode has no
    -- evidence at all: every answer counts there, as before, so a denial can still be tested.
    local trusted = ns.Guild:IsSandbox() or Vouched(sender, guild)
    local state = payload.ok and "confirmed" or (trusted and "denied" or "disputed")
    -- A "no" wins over a "yes" for as long as it's kept (a disputing "no", only over a "yes"
    -- from someone nobody vouches for either), and a disputing "no" doesn't soften a denial.
    if entry.source == "answer" and Fresh(entry) then
        if state == "confirmed" and (entry.state == "denied" or (entry.state == "disputed" and not trusted)) then return end
        if state == "disputed" and entry.state == "denied" then return end
    end
    Settle(entry, state, sender, "answer")
end)

-- Hello: each addon says it's there when it joins the alliance channel, and the ones already
-- online answer (spread out; one answer covers everyone who said hello while it waited). So the
-- Alliance page shows who's online within seconds, not only players who post or talk. A
-- newcomer missed every message sent before it joined, so a hello is always answered. Then a
-- "still here" every few minutes keeps idle players online (online = heard in the last 10 min).
-- My guildmates hear my hellos too: that's how they know I run La Taverne (Players.lua). A hello
-- also says whether I'm away (afk), and what Relay.lua adds about relaying. Old versions only
-- read r.
local helloTimer
local lastAfk          -- what my last hello said about being away
local lastChange = -60 -- GetTime() of my last hello sent because something changed
local changeTimer
local CHANGE_EVERY = 60 -- a change (away) is said at most once a minute

local function HelloPayload(answer)
    -- Away: unknown right now (the game won't say during a fight): what my last hello said.
    local away = ns.IsAway()
    local afk
    if away == nil then afk = lastAfk else afk = away and 1 or nil end
    local payload = { r = answer or nil, afk = afk }
    if ns.Relay and ns.Relay.HelloFields then ns.Relay:HelloFields(payload) end
    return payload
end

local function SayHello(answer)
    local payload = HelloPayload(answer)
    lastAfk = payload.afk
    ns.Comm:SendAlly("HI", payload)
end

-- Something my hello says changed: say it again, as an answer (nobody answers it). now: right
-- away (the relay switch); otherwise at most once a minute, and only if being away changed (it
-- comes and goes).
function Vouch:HelloChanged(now)
    if not (ns.Alliance:IsActive() and ns.Comm:IsAllyReady()) then return end
    if now then
        if changeTimer then changeTimer:Cancel() changeTimer = nil end
        lastChange = GetTime()
        SayHello(true)
        return
    end
    if changeTimer then return end
    local wait = math.max(0, CHANGE_EVERY - (GetTime() - lastChange))
    changeTimer = C_Timer.NewTimer(wait, function()
        changeTimer = nil
        if not (ns.Alliance:IsActive() and ns.Comm:IsAllyReady()) then return end
        if HelloPayload(true).afk == lastAfk then return end
        lastChange = GetTime()
        SayHello(true)
    end)
end

ns.Comm:OnAlly("HI", function(sender, payload, isSelf)
    if isSelf or payload.r or helloTimer then return end
    helloTimer = C_Timer.NewTimer(HELLO_MIN + math.random() * (HELLO_MAX - HELLO_MIN), function()
        helloTimer = nil
        SayHello(true)
    end)
end)

function Vouch:OnLogin()
    ns.Comm:OnReady(function(role)
        if role == "ally" and ns.Alliance:IsActive() then SayHello(false) end
    end)
    -- Still here (an answer: nobody answers it), a little spread so clients don't sync up.
    C_Timer.NewTicker(BEAT + math.random(0, 30), function()
        if ns.Alliance:IsActive() and ns.Comm:IsAllyReady() then SayHello(true) end
    end)
    -- Away or back: my guildmates' counts of who can relay say how many are away.
    ns.On("PLAYER_FLAGS_CHANGED", function(unit)
        if unit ~= "player" then return end
        local away = ns.IsAway()
        if away == nil then return end -- the game won't say right now
        if (away and 1 or nil) ~= lastAfk then Vouch:HelloChanged() end
    end)
    ns.PruneSeen("allySeen")
    Prune()
    -- What the game shows: my group, my target, the player under the mouse, nameplates.
    ns.On("GROUP_ROSTER_UPDATE", ScanGroup)
    ns.On("PLAYER_TARGET_CHANGED", function() Sight("target", "target") end)
    ns.On("UPDATE_MOUSEOVER_UNIT", function() Sight("mouseover", "mouseover") end)
    -- (An event this version of the game may not have: never an error at login.)
    pcall(ns.On, "NAME_PLATE_UNIT_ADDED", function(unit) Sight(unit, "nameplate") end)
end

-- For /taverne ally (Guild Alliance status in the Debug tab).
function Vouch:Report(log)
    local s = self.stats
    local records, snapshots = 0, 0
    for _ in pairs(ns.db.vouchLedger or {}) do records = records + 1 end
    for _ in pairs(ns.db.rosterSnapshots or {}) do snapshots = snapshots + 1 end
    log("vouching: asked", s.asked, "answered", s.answered, "confirmed", s.confirmed, "denied", s.denied,
        "disputed", s.disputed, "unverified", s.unverified, "messages dropped", s.dropped,
        "questions about me", ns.Guild:IsSandbox() and tostring(ns.db.dev.vouchSelf or "quiet") or "quiet")
    log("evidence: players in the ledger", records, "roster snapshots", snapshots)
    for _, item in ipairs(self:GetPlayers()) do
        log("  ", item.name, "[" .. tostring(item.tag or item.guild) .. "]", item.state or "?",
            item.source or "", item.by and ("by " .. item.by) or "", item.hidden and ("hidden " .. item.hidden) or "")
    end
end
