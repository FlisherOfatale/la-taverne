-- Guild relay: in each guild, one La Taverne player (the relay) passes on to the allied guilds
-- what members without La Taverne can't share themselves: guild chat, and the map positions of
-- those who share them through OpenMap. Members with La Taverne still send their own lines
-- (AllyChat.lua) and positions (AllyMap.lua); the relay only fills in for the others.
-- Relayed lines are shown exactly like other allied lines, and never posted in real guild chat.
-- (Design and reasons: .plans/guild-relay.md, not in the addon.)
--
-- Jobs: each job (chat, map positions) has its own relay per guild. Every La Taverne
-- player is a candidate unless they turned it off (Options) or their officers did (LT:r line,
-- Alliance.lua). Each client ranks itself (tier) from what it's doing, nothing to broadcast:
--   0 city   resting (city or inn), not in a raid group, no fight for 5 min
--   1 world  outside instances, not in a raid group, no fight for 5 min
--   2 fought a fight in the last 5 min
--   3        in a raid group, or away (AFK) for 20 min: last resort
--   can't    in an instance, switched off, officers' line off, alliance channel not ready...
-- A fight never makes a relay give up: it only holds what it sends until the fight is over
-- (the game would hold it anyway).
--
-- RLY messages (own prefix, alliance channel; every guild hears them, that's the relay state
-- shown for each guild):
--   ask    I just joined: holders, say who you are (they answer with a beacon)
--   claim  the job is free: each candidate waits a delay set by its tier, claims unless it heard
--          a claim as good as its own, and 2 s later applies the same order to the claims it
--          heard (newest protocol, tier, held it lately, hash): the best one holds the job
--          claim with ch = 1: "I'd be a much better relay" (challenge), only for the holder
--   hold   the holder's beacon, every 60 s (others count it gone after 150 s)
--   off    the holder gives the job up (why: logout, raid, off, instance, better...)
-- Two holders (they missed each other's claims): when one hears the other, the worse stops.
--
-- Chat job: every candidate keeps the guild lines of the last minute (three in a fight). The
-- holder sends each line from its own queue (RCHAT), at most 8 at once then 1 a second; for an
-- author who runs La Taverne it waits 5 s for their own copy first. A line still owed 8 s later
-- while the holder isn't heard: the job is free, and the new holder sends the owed lines
-- (replay). A line the holder missed while relaying others: one of the others sends it (gap
-- fill). Receivers drop copies (AllyChat.lua).
--
-- Map job: every candidate keeps the latest place of each guildmate who shares it through
-- OpenMap and doesn't run La Taverne (OpenMap's own messages to the guild). The holder passes
-- them on in batches (RMAP, own prefix): a player at most every 30 s while moving, 2 min while
-- still, everyone every 3 min; slower when busy, then handed over. Only for the allied guilds:
-- my own guild sees OpenMap's own dots.
--
-- Monitoring: every client measures its own sending on the relay prefix (messages, bytes,
-- budget, throttled); the beacon shares the holder's figures, the hello each player's tier (for
-- the count of candidates per tier); stability (uptime, holder changes) is counted from the
-- beacons heard. /taverne relay (and the Debug tab) shows it all in a live window.
local ADDON, ns = ...
local Relay = ns.NewModule("Relay")
local L = ns.L

Relay.RP = 1 -- relay protocol: raised only for a change older relays can't follow
local RP = Relay.RP
local PREFIX = ns.Comm.RELAY_PREFIX
local MAP_PREFIX = ns.Comm.MAP_PREFIX
local OPENMAP_PREFIX = "OpenMapLoc" -- OpenMap's positions (Map/Friends.lua), heard on the guild channel

-- Timings (seconds) ---------------------------------------------------------------------------
local TICK = 1
local BEACON_EVERY = 60       -- the holder's beacon
local LEASE = 150             -- no beacon (or anything) from the holder for this long: gone
local ASK_WAIT = 5            -- after asking: no beacon from my guild by then, the job is free
local ANSWER_EVERY = 3        -- a holder answers questions at most this often (per job)
local SETTLE = 2              -- after claiming: wait for the other claims, then apply the order
local CLAIM_STALE = 20        -- claims older than this belong to a past election
local FRESH_CLAIM = 5         -- a new election keeps only the claims this recent
local ELECTION_TIMEOUT = 15   -- an election nobody won (no beacon): start again
local BEACON_AGAIN = 5        -- a holder hearing claims beacons at once, at most this often
local FOUGHT = 300            -- "fought recently"
local LONG_AWAY = 1200        -- away this long: tier 3, before the game's idle logout
local PREV = 120              -- "held it lately": wins ties
local TAKEOVER_GAP = 2        -- a challenger must be this many tiers better than the holder...
local TAKEOVER_AFTER = 120    -- ...for this long
local OWN_COPY_WAIT = 5       -- the author runs La Taverne: wait this long for their own copy
local STALL_OWED = 8          -- a line owed this long...
local HOLDER_SILENT = 5       -- ...while the holder wasn't heard for this long: stalled
local GAP_FILL = 15           -- a line owed this long while the holder relays others: missed
local BUFFER_AGE, BUFFER_MAX = 60, 40             -- guild lines kept
local BUFFER_AGE_FIGHT, BUFFER_MAX_FIGHT = 180, 100 -- in or just after my fight: lines wait longer
local COPY_WINDOW = 10        -- two copies of one line: their times differ by this much at most
local EARLY_COPY_KEEP = 30    -- a copy heard before the guild line itself: kept this long
local BURST, REFILL = 8, 1    -- my own budget on the relay prefix: 8 at once, then 1 a second
local BUDGET_WARN = 70        -- messages a minute on the relay prefix, % of the game's 1 a second...
local BUDGET_WARN_FOR = 120   -- ...held this long: a warning (and a job handed over, see Shed)
local SLOW_PART = 1           -- a part held back this long before going out: counted as throttled
local EVENTS_MAX = 20         -- relay events kept for the live window
local LIVE_EVERY = 3          -- the live window's refresh
local BUSY_REST = 600         -- a job handed over for being too busy: not claimed back for this long
-- Map job
local MAP_BATCH = 10          -- a batch at most this often (the steps below say who's in it)
local MAP_MOVING = 30         -- a player passed on at most this often while moving...
local MAP_STILL = 120         -- ...and while standing still
local MAP_FULL = 180          -- everyone again, with class and level
local MAP_MOVED = 0.01        -- moved less than this (1 % of the map) since the last place passed on: still
local MAP_GONE = 150          -- no word from their OpenMap this long: gone (OpenMap's own wait)
local MAP_CAP = 20            -- players in one batch, most recently moved first (and as many stops)
local MAP_STALL = 90          -- the holder not heard this long (it beacons every 60 s) while places come in
local MAP_SLOW_BELOW = 50     -- slowed down (steps doubled): back to normal under this % of the budget

-- Jobs: name, what HI says I can do (cap), claim delay offset, prefix (the game limits messages
-- per prefix: each job has its own). shed: handed to someone else first when I'm too busy and
-- hold another job too; chat is never shed, it queues.
local JOBS = {
    chat = { name = "chat", cap = "c1", offset = 0, shed = false, prefix = PREFIX },
    map = { name = "map", cap = "m1", offset = 5, shed = true, prefix = MAP_PREFIX },
}
local JOB_ORDER = { "chat", "map" }

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- Counters for /taverne relay and the beacon's report.
Relay.stats = {
    lines = 0,           -- guild lines seen (not mine)
    needed = 0,          -- ... whose author doesn't run La Taverne: they need a relay
    onTime = 0, late = 0, lost = 0, -- needed lines: relayed within 8 s, later, never
    byAuthor = 0,        -- lines covered by the author's own copy
    sent = 0, gapFills = 0, waitTotal = 0, waitMax = 0, maxQueue = 0, -- as the relay
    took = 0, released = 0, stalls = 0, elections = 0, claims = 0,
    -- map: places heard from OpenMap, skipped (they run La Taverne), refused (bad values); as
    -- the relay: batches, positions and stops passed on
    mapHeard = 0, mapSkipped = 0, mapBad = 0, mapBatches = 0, mapSent = 0, mapOffs = 0,
}
-- The players behind those messages (OpenMap sends one every 10 s while moving): [key] = true.
local mapHeardFrom, mapSkippedFrom = {}, {}
local stats = Relay.stats

-- State --------------------------------------------------------------------------------------

local myKey
local function MyKey()
    myKey = myKey or ns.NameKey(ns.FullName("player"))
    return myKey
end

local fighting, lastFight, awaySince = false, nil, nil
local loggingOut = false -- the logout countdown: handed over, never claimed back
local newerRp, newerAt -- a higher relay protocol heard in my guild (and when): I step aside
local NEWER_FOR = 600   -- ...until it hasn't been heard for this long (hellos repeat it every 4-4.5 min)
local newerTold = false

-- [job] = my view of that job in my guild.
--   holding, since (server time), heldTier, lastHeld (GetTime, for "prev")
--   holder: my guild's holder when it isn't me: { name, key, tier, since, rp, heard, q, lastLine }
--   free: an election is open. stall: it started because the holder stalled (void if heard again)
--   claims: [key] = { name, key, tier, prev, rp, rank, at }; claimAt, settleAt, quiet
--   electionStart, lastClaimHeard, askedAt, lastBeacon, lastAnswer, lastBeaconAgain
--   betterSince, challenged: the challenge watch. report, since my last beacon: { sent (items),
--   maxq, b (bytes), p (parts: one addon message each), th (parts throttled or refused) }
local jobs = {}
local function NewReport() return { sent = 0, maxq = 0, b = 0, p = 0, th = 0 } end
for _, job in ipairs(JOB_ORDER) do
    jobs[job] = { claims = {}, lastBeacon = 0, lastAnswer = 0, lastBeaconAgain = 0, challenged = 0,
        report = NewReport() }
end

-- Every guild's relays, as heard from beacons and releases (mine too):
-- [guild lowercase] = { [job] = { name, tier, since, rp, heard (server time), sent, maxq, b, p, th }
--   or { why, heard } }
local status = {}

local listeners = {}
function Relay:OnChange(fn) listeners[#listeners + 1] = fn end
local changePending = false
local function Changed()
    if changePending then return end
    changePending = true
    C_Timer.After(0.5, function()
        changePending = false
        for _, fn in ipairs(listeners) do fn() end
    end)
end

-- Relay events: in the message log (English, like its other lines) and the last few for the live
-- window, where fmt is translated (Locale.lua) and the values aren't. unusual: marked "!!".
local events = {}
local function Record(unusual, fmt, ...)
    ns.Comm:LogNote("relay: " .. format(fmt, ...), unusual)
    events[#events + 1] = { t = time(), fmt = fmt, args = { n = select("#", ...), ... } }
    if #events > EVENTS_MAX then table.remove(events, 1) end
end
local function Note(fmt, ...) Record(nil, fmt, ...) end

-- Where I stand ---------------------------------------------------------------------------------

local function Fighting()
    return fighting or (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
end

local function InInstance()
    local inside = IsInInstance()
    return inside and true or false
end

-- The game holds or drops messages during my own fights and game restrictions: nothing is
-- handed to it then (the queue waits).
local function SendingPaused()
    if Fighting() or ns.Guild:Restricted() then return true end
    local lockdown = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if lockdown then
        local ok, on = pcall(lockdown)
        if ok and on then return true end
    end
    return false
end

-- Why I can't do this job right now (a short code, Relay.WhyText), or nil.
local function CantReason(job)
    if not ns.db.relay.help then return "off" end
    if loggingOut then return "logout" end
    if not ns.Alliance:IsActive() then return "alliance" end
    if not ns.Comm:IsAllyReady() then return "channel" end
    if job == "chat" and not ns.AllyChat.Enabled() then return "chat" end
    if not ns.Alliance:IsInfoKnown() then return "info" end
    if not ns.Alliance:RelayAllows(job) then return "officers" end
    if newerRp then
        if GetTime() - newerAt < NEWER_FOR then return "newer" end
        newerRp, newerAt = nil, nil -- not heard for a while: they logged off
    end
    if InInstance() then return "instance" end
    return nil
end

-- My tier for a job (0 best .. 3 last resort), or nil and why not.
local function Tier(job)
    local why = CantReason(job)
    if why then return nil, why end
    local now = GetTime()
    if IsInRaid and IsInRaid() then return 3, "raid" end
    if awaySince and now - awaySince >= LONG_AWAY then return 3, "away" end
    if Fighting() or (lastFight and now - lastFight < FOUGHT) then return 2 end
    if IsResting() then return 0 end
    return 1
end
Relay.Tier = function(_, job) return Tier(job) end

-- The tier I claim with: one worse while I hold another job, so jobs spread over players.
local function ClaimTier(job)
    local tier, why = Tier(job)
    if not tier then return nil, why end
    -- Handed over for being too busy: not claimed back for a while.
    local rest = jobs[job].restUntil
    if rest and GetTime() < rest then return nil, "busy" end
    for other, st in pairs(jobs) do
        if other ~= job and st.holding then return math.min(3, tier + 1) end
    end
    return tier
end

local function Hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return h
end

-- The same for everyone: where a player stands among equals for a job.
local function Rank(key, job) return Hash(key .. ":" .. job) end

-- Is claim a better than claim b? The same order on every client: newest relay protocol, tier,
-- held it lately, rank, name.
local function Better(a, b)
    local ra, rb = a.rp or 0, b.rp or 0
    if ra ~= rb then return ra > rb end
    if a.tier ~= b.tier then return a.tier < b.tier end
    local pa, pb = a.prev and true or false, b.prev and true or false
    if pa ~= pb then return pa end
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.key < b.key
end

-- How long I wait before claiming: by tier, those who held it lately first, then by rank, so
-- the first to claim in a tier is usually the best one of it.
local function ClaimDelay(job, tier, prev)
    local spot = (Rank(MyKey(), job) % 1000) / 1000
    return JOBS[job].offset + tier * 3 + (prev and 0 or 0.5) + spot * 1.5
end

local function HeldLately(st)
    return st.lastHeld ~= nil and GetTime() - st.lastHeld < PREV
end

-- Measuring ------------------------------------------------------------------------------------
-- Rings of 60 slots (seconds or minutes), each { i (its second or minute), m (messages: parts,
-- each its own addon message), b (bytes), up, online (seconds), planned, unplanned }.

local function Slot(ring, index)
    local pos = index % 60 + 1
    local s = ring[pos]
    if not s or s.i ~= index then
        s = { i = index, m = 0, b = 0, up = 0, online = 0, planned = 0, unplanned = 0 }
        ring[pos] = s
    end
    return s
end

-- A field added up over the last n slots up to index (slots not written since count 0).
local function Sum(ring, index, n, field)
    local total = 0
    for i = index - n + 1, index do
        local s = ring[i % 60 + 1]
        if s and s.i == i then total = total + s[field] end
    end
    return total
end

-- My sending on the relay prefix, counted as it's handed to the game (Comm.lastSend): per
-- second and per minute; the busiest 60 s this session (peak); parts per relayed item; RLY among
-- everything I sent (coordination share); parts held back SLOW_PART or more before going out
-- (held) or refused (failed, and failCodes: [the game's result code] = count); budget warnings.
-- prefix: [prefix] = ring of seconds, the same per prefix (the game's limit is per prefix).
local meter = { sec = {}, min = {}, prefix = {}, peak = 0, items = 0, parts = 0, maxParts = 0, rly = 0, all = 0,
    held = 0, failed = 0, failCodes = {}, warnings = 0 }
for _, job in ipairs(JOB_ORDER) do meter.prefix[JOBS[job].prefix] = {} end

local function Measure(kind, job, parts, bytes)
    local now = math.floor(GetTime())
    local s = Slot(meter.sec, now)
    s.m, s.b = s.m + parts, s.b + bytes
    local ps = Slot(meter.prefix[JOBS[job or "chat"].prefix], now)
    ps.m, ps.b = ps.m + parts, ps.b + bytes
    local m = Slot(meter.min, math.floor(now / 60))
    m.m, m.b = m.m + parts, m.b + bytes
    meter.all = meter.all + 1
    if kind == "RLY" then
        meter.rly = meter.rly + 1
    else
        meter.items = meter.items + 1
        meter.parts = meter.parts + parts
        if parts > meter.maxParts then meter.maxParts = parts end
    end
    -- The beacon's report: what I sent for a job I hold.
    local st = job and jobs[job]
    if st and st.holding then
        st.report.b, st.report.p = st.report.b + bytes, st.report.p + parts
    end
end

-- ChatThrottleLib tells when it really sent each part (Comm.lua): one held back a second or more
-- (its budget, or the game's throttle), or refused, counts as throttled.
for _, job in ipairs(JOB_ORDER) do
    ns.Comm:WatchParts(JOBS[job].prefix, function(didSend, waited, result)
        if didSend and waited < SLOW_PART then return end
        if didSend then
            meter.held = meter.held + 1
        else
            meter.failed = meter.failed + 1
            local code = tostring(result)
            meter.failCodes[code] = (meter.failCodes[code] or 0) + 1
        end
        local st = jobs[job]
        if st.holding then st.report.th = st.report.th + 1 end
    end)
end

-- Stability per guild and job, from the beacons heard: [guild lowercase][job] = { min = ring
-- (up: seconds with a fresh beacon, online: seconds with a La Taverne player of that guild
-- online, planned / unplanned: holder changes), holder (key), off (an "off" heard since) }.
-- A change is planned when the last holder said "off" first, unplanned when it just went quiet.
local stability = {}

local function Track(g, job)
    stability[g] = stability[g] or {}
    local t = stability[g][job]
    if not t then
        t = { min = {} }
        stability[g][job] = t
    end
    return t
end

local function MinuteSlot(t)
    return Slot(t.min, math.floor(GetTime() / 60))
end

local function NoteChange(g, job, entry)
    local t = Track(g, job)
    if entry.name then
        local key = ns.NameKey(entry.name)
        if t.holder and t.holder ~= key then
            local s = MinuteSlot(t)
            if t.off then s.planned = s.planned + 1 else s.unplanned = s.unplanned + 1 end
        end
        t.holder, t.off = key, nil
    else
        t.off = true
    end
end

-- Status --------------------------------------------------------------------------------------

local function NoteStatus(guild, job, entry)
    if type(guild) ~= "string" or guild == "" then return end
    local g = strtrim(guild):lower()
    status[g] = status[g] or {}
    entry.heard = GetServerTime()
    NoteChange(g, job, entry)
    status[g][job] = entry
    Changed()
end

-- The relay of a guild for a job: { name, tier, since, heard, sent, maxq } while its beacon is
-- fresh, or nil and the last reason given ("raid", "off"...) if it gave the job up. Turned off
-- by its officers: said until a relay is heard again (nobody of that guild sends anything then).
function Relay:GetStatus(guild, job)
    if type(guild) ~= "string" then return nil end
    local g = status[strtrim(guild):lower()]
    local entry = g and g[job or "chat"]
    if not entry then return nil end
    local fresh = GetServerTime() - entry.heard < LEASE
    if entry.name then return fresh and entry or nil end
    if fresh or entry.why == "officers" then return nil, entry.why end
    return nil
end

-- Has this guild a La Taverne player online (someone who could relay)? Mine: me.
function Relay:HasPlayersOnline(guild)
    if ns.Guild:IsMyGuild(guild) then return true end
    local g = type(guild) == "string" and strtrim(guild):lower() or ""
    for _, pl in ipairs(ns.Vouch:GetPlayers()) do
        if pl.online and (pl.guild or ""):lower() == g then return true end
    end
    return false
end

-- A guild's relay for a job in a few words (Alliance page, minimap tooltip): who and their tier,
-- or none (and why, if its last relay said). Orange when it matters: that guild has La Taverne
-- players online (playersOnline; nil: looked up), so its members without it aren't passed on.
-- Also the entry.
function Relay:StatusText(guild, job, playersOnline)
    job = job or "chat"
    if playersOnline == nil then playersOnline = self:HasPlayersOnline(guild) end
    local entry, why = self:GetStatus(guild, job)
    if entry then
        local who = ns.IsMe(entry.name) and L["you"] or entry.name
        return format("%s (%s)", who, Relay.TierText(entry.tier)), entry
    end
    if ns.Guild:IsMyGuild(guild) and ns.Alliance:IsInfoKnown() and not ns.Alliance:RelayAllows(job) then
        why = "officers"
    end
    local text = why and format(L["nobody (%s)"], Relay.WhyText(why)) or L["nobody"]
    local problem = playersOnline and why ~= "officers"
    return (problem and "|cffff9900" or "|cff808080") .. text .. "|r", nil
end

function Relay:IsHolding(job)
    local st = jobs[job or "chat"]
    return st ~= nil and st.holding
end

function Relay:GetJobs() return JOB_ORDER end

-- Messages out ----------------------------------------------------------------------------------

-- On the job's own prefix ("ask", for every job: the chat one).
local function SendRLY(op, job, fields)
    local payload = fields or {}
    payload.op, payload.j, payload.rp = op, job, RP
    if not ns.Comm:SendAlly("RLY", payload, "ALERT", true, job and JOBS[job].prefix or PREFIX) then return false end
    Measure("RLY", job, ns.Comm.lastSend.parts, ns.Comm.lastSend.bytes)
    return true
end

-- The beacon carries what I sent for the job since the previous one (sent, mq, b, p, th): every
-- guild sees every relay's load. (The report starts again before it goes: the beacon itself
-- counts in the next one.)
local function Beacon(job)
    local st = jobs[job]
    if SendingPaused() then return end -- the tick sends it once the fight is over
    st.lastBeacon = GetTime()
    local tier = Tier(job) or 3
    st.beaconTier = tier -- what the others know of me (two holders compare these)
    local report = st.report
    st.report = NewReport()
    SendRLY("hold", job, { tier = tier, since = st.since, sent = report.sent, mq = report.maxq,
        b = report.b, p = report.p, th = report.th })
    NoteStatus(ns.Guild:GetName(), job, { name = ns.FullName("player"), tier = tier, since = st.since, rp = RP })
end

-- A holder hearing claims (they think it's gone) or a challenge it turns down: a beacon now.
local function BeaconSoon(job)
    local st = jobs[job]
    local now = GetTime()
    if now - st.lastBeaconAgain < BEACON_AGAIN then return end
    st.lastBeaconAgain = now
    Beacon(job)
end

-- Elections -------------------------------------------------------------------------------------

local JobHooks = {} -- [job] = { onTake = fn, onRelease = fn, watch = fn(job, st, tier) }

local function CloseElection(job)
    local st = jobs[job]
    st.free, st.stall, st.quiet = false, false, false
    st.claimAt, st.settleAt, st.electionStart = nil, nil, nil
    wipe(st.claims)
end

local function ScheduleClaim(job)
    local st = jobs[job]
    if not st.free or st.holding or st.settleAt or st.quiet then return end
    local tier = ClaimTier(job)
    -- Not while I can't send (my fight, a game restriction): once it's over (the tick tries again).
    if not tier or SendingPaused() then
        st.claimAt = nil
        return
    end
    st.claimAt = GetTime() + ClaimDelay(job, tier, HeldLately(st))
end

-- No holder in my guild for this job (or it stalled): an election opens; I claim in my turn if
-- I can. stall: the holder may only be busy, kept to void the election if it's heard again.
local function MarkFree(job, stall, why)
    local st = jobs[job]
    if st.holding then return end
    local now = GetTime()
    st.free, st.stall, st.quiet = true, stall and true or false, false
    if not stall then st.holder = nil end
    st.claimAt, st.settleAt = nil, nil
    st.electionStart = now
    -- A new election (why): only the claims of the last few seconds can belong to it (the one
    -- that opened it, others that noticed at the same time); older ones were answered or lost.
    local keep = why and FRESH_CLAIM or CLAIM_STALE
    for key, c in pairs(st.claims) do
        if now - c.at >= keep then st.claims[key] = nil end
    end
    -- why: a new election (logged, counted); none: the same one, started again.
    if why then
        stats.elections = stats.elections + 1
        Note("%s is free (%s)", job, why)
    end
    ScheduleClaim(job)
    Changed()
end

local function Take(job)
    local st = jobs[job]
    CloseElection(job)
    st.holding, st.holder = true, nil
    st.since = GetServerTime()
    st.heldTier = Tier(job)
    st.lastHeld = GetTime()
    st.betterSince = nil
    st.report = NewReport()
    stats.took = stats.took + 1
    Note("I hold %s (tier %s)", job, tostring(st.heldTier))
    -- Now, or (sending paused) as soon as it can: the tick beacons once lastBeacon is old.
    st.lastBeacon, st.beaconTier = 0, nil
    Beacon(job)
    if not ns.db.relay.told and job == "chat" then
        ns.db.relay.told = true
        ns.Print(L["You're relaying your guild's chat to the allied guilds, for the members without La Taverne. You can turn this off in Options."])
    end
    local hooks = JobHooks[job]
    if hooks and hooks.onTake then hooks.onTake() end
    Changed()
end

-- Give the job up. silent: no message (another holder is better: it's already beaconing).
local function Release(job, why, silent)
    local st = jobs[job]
    if not st.holding then return end
    st.holding = false
    st.lastHeld = GetTime()
    if why == "busy" then st.restUntil = GetTime() + BUSY_REST end
    stats.released = stats.released + 1
    Note("I give %s up (%s)", job, tostring(why))
    local hooks = JobHooks[job]
    if hooks and hooks.onRelease then hooks.onRelease() end
    if silent then
        Changed()
        return
    end
    SendRLY("off", job, { why = why })
    NoteStatus(ns.Guild:GetName(), job, { why = why })
    -- Free for the others now (and for me, if I can still do it, after my wait).
    MarkFree(job, false, "I gave it up")
end

local function Claim(job)
    local st = jobs[job]
    local tier = ClaimTier(job)
    st.claimAt = nil
    if not tier then return end
    local prev = HeldLately(st)
    if not SendRLY("claim", job, { tier = tier, prev = prev or nil }) then return end
    local key = MyKey()
    local now = GetTime()
    st.claims[key] = { name = ns.FullName("player"), key = key, tier = tier, prev = prev, rp = RP, rank = Rank(key, job), at = now }
    st.settleAt = now + SETTLE
    st.lastClaimHeard = now
    stats.claims = stats.claims + 1
    Note("I claim %s (tier %d)", job, tier)
end

-- My turn to claim: unless I heard a claim as good as mine meanwhile (it'll win or settle it).
local function TryClaim(job)
    local st = jobs[job]
    if SendingPaused() then
        st.claimAt = nil -- once my fight (or the restriction) is over
        return
    end
    local tier = ClaimTier(job)
    if not tier then
        st.claimAt = nil
        return
    end
    local now = GetTime()
    for key, c in pairs(st.claims) do
        if key ~= MyKey() and now - c.at < CLAIM_STALE
            and ((c.rp or 0) > RP or ((c.rp or 0) == RP and c.tier <= tier)) then
            st.claimAt, st.quiet = nil, true
            return
        end
    end
    Claim(job)
end

-- After claiming: the best claim I heard (mine included) takes the job.
local function Settle(job)
    local st = jobs[job]
    st.settleAt = nil
    if not st.free or st.holding then return end
    local key = MyKey()
    -- I can't any more, or can't send now (a fight started: no beacon until it ends, the others
    -- would take it meanwhile): someone else, or me again in the next round.
    if not ClaimTier(job) or SendingPaused() then st.claims[key] = nil end
    local now, best = GetTime(), nil
    for _, c in pairs(st.claims) do
        if now - c.at < CLAIM_STALE and (not best or Better(c, best)) then best = c end
    end
    if best and best.key == key then
        Take(job)
        return
    end
    -- The best one takes it and beacons; if nobody does, the election starts again.
    st.quiet = true
end

-- Someone just joined: tell them who I relay for (a beacon per job I hold). Every ask gets a
-- beacon sent after it, but one beacon answers all the asks heard while it waits, and they go
-- out ANSWER_EVERY apart at most (every guild's logins ask).
local function AnswerAsk()
    for _, job in ipairs(JOB_ORDER) do
        local st = jobs[job]
        if st.holding and not st.answerPending then
            st.answerPending = true
            local wait = math.max(0.2 + math.random() * 0.8, ANSWER_EVERY - (GetTime() - st.lastAnswer))
            C_Timer.After(wait, function()
                st.answerPending = false
                st.lastAnswer = GetTime()
                if st.holding then Beacon(job) end
            end)
        end
    end
end

local function Ask()
    local now = GetTime()
    for _, job in ipairs(JOB_ORDER) do jobs[job].askedAt = now end
    SendRLY("ask", nil)
end

-- A higher relay protocol than mine: in my guild I step aside (the newer ones relay); anywhere,
-- one chat line to update.
function Relay:NoteProtocol(rp, myGuild)
    rp = tonumber(rp)
    if not rp or rp <= RP then return end
    if myGuild then
        if not newerRp or rp > newerRp then newerRp = rp end
        newerAt = GetTime()
    end
    if not newerTold then
        newerTold = true
        ns.Print(L["A newer guild relay is in use: update La Taverne to see all of the allied guilds' chat."])
    end
end

-- Messages in -------------------------------------------------------------------------------

-- Anything from my guild's holder: it's still there. q: lines still waiting in its queue.
local function HeardFrom(job, key, q, isLine)
    local st = jobs[job]
    local h = st.holder
    if not h or h.key ~= key then return end
    h.heard = GetTime()
    if q ~= nil then h.q = tonumber(q) or 0 end
    if isLine then h.lastLine = GetTime() end
    -- A stall election is void once the holder is heard again: it was only busy (a fight).
    if st.free and st.stall then
        Note("%s: %s is back, no new relay", job, h.name)
        CloseElection(job)
        Changed()
    end
end

local function ValidTier(t)
    t = tonumber(t)
    if t and t >= 0 and t <= 3 and t == math.floor(t) then return t end
    return nil
end

-- RLY from my own guild.
local function OnGuildRLY(sender, p)
    if p.op == "ask" then
        AnswerAsk()
        return
    end
    local job = p.j
    local st = jobs[job]
    if not st then return end -- a job of a newer version
    local key = ns.NameKey(sender)
    local rp = tonumber(p.rp) or 0
    Relay:NoteProtocol(rp, true)
    local tier = ValidTier(p.tier)
    if p.op == "hold" then
        if not tier then return end
        NoteStatus(ns.Guild:GetName(), job, { name = sender, tier = tier, since = tonumber(p.since), rp = rp,
            sent = tonumber(p.sent), maxq = tonumber(p.mq), b = tonumber(p.b), p = tonumber(p.p), th = tonumber(p.th) })
        if st.holding then
            -- Two holders: the worse one stops (silently), the better one says so at once.
            -- Both sides compare the tiers of their last beacons (what the other one heard),
            -- so they agree on which one stops.
            local other = { key = key, tier = tier, rp = rp, prev = true, rank = Rank(key, job) }
            local mine = { key = MyKey(), tier = st.beaconTier or Tier(job) or 3, rp = RP, prev = true, rank = Rank(MyKey(), job) }
            if Better(other, mine) then
                Release(job, "two holders", true)
                st.holder = { name = sender, key = key, tier = tier, since = tonumber(p.since), rp = rp, heard = GetTime(), q = 0 }
            else
                BeaconSoon(job)
            end
            return
        end
        local old = st.holder
        st.holder = { name = sender, key = key, tier = tier, since = tonumber(p.since), rp = rp, heard = GetTime(),
            q = (old and old.key == key) and old.q or 0, lastLine = (old and old.key == key) and old.lastLine or nil }
        if st.free then CloseElection(job) end
        Changed()
    elseif p.op == "off" then
        NoteStatus(ns.Guild:GetName(), job, { why = type(p.why) == "string" and p.why:sub(1, 16) or nil })
        if st.holder and st.holder.key == key then st.holder = nil end
        if not st.holding and not st.free and not st.holder then
            MarkFree(job, false, sender .. " gave it up (" .. tostring(p.why) .. ")")
        end
    elseif p.op == "claim" then
        if not tier then return end
        HeardFrom(job, key)
        if p.ch then
            -- A challenge: only the holder decides. Much better than me: the job is theirs to claim.
            if st.holding then
                local mine = Tier(job)
                if mine and tier + TAKEOVER_GAP <= mine then
                    Release(job, "better")
                else
                    BeaconSoon(job)
                end
            end
            return
        end
        st.claims[key] = { name = sender, key = key, tier = tier, prev = p.prev and true or false, rp = rp,
            rank = Rank(key, job), at = GetTime() }
        st.lastClaimHeard = GetTime()
        if st.holding then
            BeaconSoon(job) -- they think it's free: it isn't
            return
        end
        -- An election I didn't see coming: join it unless my holder is still there.
        if not st.free and not (st.holder and GetTime() - st.holder.heard < LEASE) then
            MarkFree(job, false, sender .. " claims it")
        end
    end
end

-- RLY from an allied guild: who relays for them (the status of every guild).
local function OnAllyRLY(sender, p)
    if p.op == "ask" then
        AnswerAsk()
        return
    end
    if not JOBS[p.j] then return end
    if p.op == "hold" then
        local tier = ValidTier(p.tier)
        if not tier then return end
        NoteStatus(p.g, p.j, { name = sender, tier = tier, since = tonumber(p.since), rp = tonumber(p.rp),
            sent = tonumber(p.sent), maxq = tonumber(p.mq), b = tonumber(p.b), p = tonumber(p.p), th = tonumber(p.th) })
    elseif p.op == "off" then
        NoteStatus(p.g, p.j, { why = type(p.why) == "string" and p.why:sub(1, 16) or nil })
    end
end

ns.Comm:On("RLY", function(sender, p, isSelf)
    if isSelf or type(p.op) ~= "string" then return end
    OnGuildRLY(sender, p)
end)

ns.Comm:OnAlly("RLY", function(sender, p, isSelf)
    if isSelf or type(p.op) ~= "string" then return end
    OnAllyRLY(sender, p)
end)

-- My guildmates' hellos say their relay protocol.
ns.Comm:On("HI", function(_, p, isSelf)
    if not isSelf then Relay:NoteProtocol(p.rp, true) end
end)

-- What my hello says about relaying (Vouch.lua): switch on (rl), jobs I can do (cap), protocol,
-- and my tier for the chat job (tr: 0-3, or "x" can't and tw why), for my guildmates' count of
-- candidates per tier (the live window). Only in the hellos sent anyway (every 4-4.5 min, and
-- when being away or the switch changes): a tier changing (fights) never sends one.
function Relay:HelloFields(payload)
    payload.rl = ns.db.relay.help and 1 or nil
    local caps = {}
    for _, job in ipairs(JOB_ORDER) do caps[#caps + 1] = JOBS[job].cap end
    payload.cap = table.concat(caps, ",")
    payload.rp = RP
    local tier, why = Tier("chat")
    payload.tr = tier or "x"
    payload.tw = not tier and why or nil
end

-- Chat job ----------------------------------------------------------------------------------------
-- buffer: my guild's lines, oldest first (not mine: AllyChat.lua sends those):
--   { author, akey, key (AllyChat.TextKey), text, class, guid, t (server time), seen, due
--     (GetTime when the holder owes it), runs (the author has La Taverne), covered, by, queued }
-- earlyCopies: copies heard before the guild line itself (the author's own copy is sent as they
-- type, so it often comes first): { akey, key, t, at, by }
-- queue: the lines I still have to send, as the holder.
local buffer, earlyCopies, queue = {}, {}, {}
local tokens, lastRefill = BURST, 0

local function Matches(e, akey, key, t)
    return e.akey == akey and e.key == key and math.abs((t or e.t) - e.t) <= COPY_WINDOW
end

-- The same author at about the same time, whatever the text: a copy's text can differ from
-- mine (the game's profanity filter changes the lines I get, not what the author typed). Only
-- when no line matches the text.
local function Near(e, akey, t)
    return e.akey == akey and math.abs((t or e.t) - e.t) <= COPY_WINDOW
end

local function CountCovered(e)
    if e.by == "author" then
        stats.byAuthor = stats.byAuthor + 1
    elseif not e.runs then
        if e.covered - e.due <= STALL_OWED then stats.onTime = stats.onTime + 1 else stats.late = stats.late + 1 end
    end
end

-- A copy of one of my guild's lines went out (the author's own, or a relay's): covered.
local function Cover(author, text, t, by)
    if IsSecret(author) or IsSecret(text) or type(author) ~= "string" or type(text) ~= "string" then return end
    local akey, key = ns.NameKey(author), ns.AllyChat.TextKey(text)
    if not key then return end
    t = tonumber(t)
    for _, e in ipairs(buffer) do
        if Matches(e, akey, key, t) then
            if not e.covered then
                e.covered, e.by = GetTime(), by
                CountCovered(e)
                return
            end
        end
    end
    for _, e in ipairs(buffer) do
        if Matches(e, akey, key, t) then return end -- a second copy of a covered line
    end
    -- No line with this text: the author's oldest line still owed from about then.
    for _, e in ipairs(buffer) do
        if not e.covered and Near(e, akey, t) then
            e.covered, e.by = GetTime(), by
            CountCovered(e)
            return
        end
    end
    earlyCopies[#earlyCopies + 1] = { akey = akey, key = key, t = t, at = GetTime(), by = by }
end

local function TakeEarlyCopy(e)
    for i, c in ipairs(earlyCopies) do
        if Matches(e, c.akey, c.key, c.t) then
            table.remove(earlyCopies, i)
            return c.by
        end
    end
    for i, c in ipairs(earlyCopies) do
        if Near(e, c.akey, c.t) then
            table.remove(earlyCopies, i)
            return c.by
        end
    end
    return nil
end

local function Prune()
    local now = GetTime()
    local inFight = Fighting() or (lastFight and now - lastFight < BUFFER_AGE_FIGHT)
    local age, max = inFight and BUFFER_AGE_FIGHT or BUFFER_AGE, inFight and BUFFER_MAX_FIGHT or BUFFER_MAX
    while #buffer > 0 and (#buffer > max or now - buffer[1].seen > age) do
        local e = table.remove(buffer, 1)
        -- (Still in my queue as the relay: not lost yet, Pump sends it or counts it.)
        if not e.covered and not e.runs and not e.queued then stats.lost = stats.lost + 1 end
    end
    while #earlyCopies > 0 and now - earlyCopies[1].at > EARLY_COPY_KEEP do table.remove(earlyCopies, 1) end
end

local function QueueDue()
    local now = GetTime()
    for _, e in ipairs(buffer) do
        if not e.covered and not e.queued and e.due <= now then
            e.queued = true
            queue[#queue + 1] = e
        end
    end
    if #queue > stats.maxQueue then stats.maxQueue = #queue end
    local report = jobs.chat.report
    if #queue > report.maxq then report.maxq = #queue end
end

local function Refill()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRefill) * REFILL)
    lastRefill = now
end

-- Messages a line costs: about 140 bytes go with any text (names, fields), and a message holds
-- 240 (Comm.lua's parts): a longer line is two.
local function Cost(e)
    return #e.text > 90 and 2 or 1
end

-- One line to the allied guilds. waiting: lines still in my queue after it (q). gapFill: I'm
-- not the holder, it missed this one.
local function SendLine(e, waiting, gapFill)
    local payload = { a = e.author, m = e.text, c = e.class, id = e.guid, t = e.t, q = waiting or 0, rp = RP,
        gf = gapFill and 1 or nil }
    if not ns.Comm:SendAlly("RCHAT", payload, "ALERT", true, PREFIX) then return false end
    Measure("RCHAT", "chat", ns.Comm.lastSend.parts, ns.Comm.lastSend.bytes)
    local now = GetTime()
    if not e.covered then
        e.covered, e.by = now, "me"
        CountCovered(e)
    end
    stats.sent = stats.sent + 1
    if gapFill then stats.gapFills = stats.gapFills + 1 end
    local wait = math.max(0, now - e.due)
    stats.waitTotal = stats.waitTotal + wait
    if wait > stats.waitMax then stats.waitMax = wait end
    -- The beacon's report: what I sent as the relay (not a gap fill for another one).
    if jobs.chat.holding then
        local report = jobs.chat.report
        report.sent = report.sent + 1
    end
    return true
end

-- Send what's owed, as the holder, within my budget. Nothing during my fight: the lines wait.
local function Pump()
    if not jobs.chat.holding then
        for _, e in ipairs(queue) do e.queued = nil end
        wipe(queue)
        return
    end
    QueueDue()
    if #queue == 0 or SendingPaused() or not ns.Comm:IsAllyReady() then return end
    Refill()
    local now = GetTime()
    while #queue > 0 and tokens >= Cost(queue[1]) do
        local e = table.remove(queue, 1)
        e.queued = nil
        -- Still owed (someone else may have covered it meanwhile), and not too old.
        if not e.covered and now - e.seen <= BUFFER_AGE_FIGHT then
            if not SendLine(e, #queue) then
                e.queued = true
                table.insert(queue, 1, e)
                break
            end
            tokens = tokens - Cost(e)
        elseif not e.covered and not e.runs then
            stats.lost = stats.lost + 1
        end
    end
end

-- A line in my guild's chat (CHAT_MSG_GUILD; test mode: the test guild's chat).
function Relay:GuildLine(author, text, class, guid)
    if IsSecret(author) or IsSecret(text) or type(author) ~= "string" or type(text) ~= "string" then return end
    if text == "" or ns.IsMe(author) or not ns.Alliance:IsActive() then return end
    if IsSecret(guid) or type(guid) ~= "string" then guid = nil end
    local key = ns.AllyChat.TextKey(text)
    if not key then return end
    if type(class) ~= "string" then
        local member = ns.Guild:GetMember(author)
        class = member and member.class or nil
    end
    local now = GetTime()
    local runs = ns.Players:RunsAddon(author)
    local e = { author = author, akey = ns.NameKey(author), key = key, text = text, class = class, guid = guid,
        t = GetServerTime(), seen = now, due = now + (runs and OWN_COPY_WAIT or 0), runs = runs }
    local by = TakeEarlyCopy(e)
    if by then
        e.covered, e.by = now, by
        CountCovered(e)
    end
    buffer[#buffer + 1] = e
    stats.lines = stats.lines + 1
    if not runs then stats.needed = stats.needed + 1 end
    Prune()
    if jobs.chat.holding then Pump() end
end

-- Gap fill: how long a watcher waits past GAP_FILL. By tier, then spread over 6 s by rank: the
-- watchers check once a second, the first one's line must reach the others before their turn.
local function GapDelay(job, tier)
    return tier * 3 + (Rank(MyKey(), job) % 1000) / 1000 * 6
end

-- Watching the holder (not me), every second: stalled, or missed a line?
-- - A line still owed while the holder is silent: it may be gone, the job is free (a stall
--   election, void if it's heard again). Once per line: a holder that answers the election but
--   still doesn't send that line only missed it, a new election wouldn't change that.
-- - Missed: the holder has nothing waiting but relays later lines (or answered the stall
--   election), and not this one. One of us sends it, by tier and rank (the others hear it and
--   drop theirs), the holder keeps the job.
-- The holder's own lines are its to share as their author, like anyone's: never owed by the relay.
local function WatchChat(job, st, tier)
    local h = st.holder
    local now = GetTime()
    for _, e in ipairs(buffer) do
        if not e.covered and e.akey ~= h.key then
            local owed = now - e.due
            if not e.stalled and owed >= STALL_OWED and now - h.heard >= HOLDER_SILENT then
                e.stalled = true
                stats.stalls = stats.stalls + 1
                MarkFree(job, true, format("%s silent with a line owed %d s", h.name, math.floor(owed)))
                return
            end
            if tier and owed >= GAP_FILL + GapDelay(job, tier) and (h.q or 0) == 0
                and (e.stalled or (h.lastLine and h.lastLine > e.seen)) and not SendingPaused() then
                Refill()
                if tokens >= Cost(e) and SendLine(e, 0, true) then
                    tokens = tokens - Cost(e)
                    Note("%s missed a line from %s: sent it", h.name, e.author)
                end
            end
        end
    end
end

JobHooks.chat = {
    onTake = function() Pump() end, -- the owed lines first (replay)
    onRelease = function() Pump() end, -- (empties the queue)
    watch = WatchChat,
}

-- The authors' own copies and the relay's lines, from my guild: covered.
ns.Comm:On("CHAT", function(sender, p, isSelf)
    if isSelf then return end
    Cover(sender, p.m, p.t, "author")
end)

ns.Comm:On("RCHAT", function(sender, p, isSelf)
    if isSelf then return end
    Relay:NoteProtocol(p.rp, true)
    HeardFrom("chat", ns.NameKey(sender), p.q, true)
    if type(p.a) == "string" then Cover(p.a, p.m, p.t, "relay") end
end)

-- Test mode: the test guild's chat stands in for the real guild chat (never read then). as: a
-- test guild member without La Taverne said it (/taverne dev say), the sender only typed it.
ns.Comm:On("GCHAT", function(sender, p, isSelf)
    if isSelf or not ns.Guild:IsSandbox() then return end
    if p.as ~= nil then
        Relay:GuildLine(p.as, p.m, p.c, nil)
    else
        Relay:GuildLine(sender, p.m, p.c, p.id)
    end
end)

ns.On("CHAT_MSG_GUILD", function(text, author, _, _, _, _, _, _, _, _, _, guid)
    if ns.Guild:IsSandbox() then return end
    Relay:GuildLine(author, text, nil, guid)
end)

-- Map job ---------------------------------------------------------------------------------------
-- Every candidate keeps the latest place of each guildmate who shares it through OpenMap (its
-- "Share where you are": OpenMapLoc on the guild channel) and doesn't run La Taverne: those who
-- do share their own place (AllyMap.lua). A state job: the holder sends one batch (RMAP) every
-- MAP_BATCH at most, with up to MAP_CAP players, most recently moved first: whoever moved more
-- than MAP_MOVED since the place it last passed on (at most every MAP_MOVING), or stood still
-- (every MAP_STILL), and everyone with class and level every MAP_FULL. Stopped sharing (OpenMap's
-- L0, or no word for MAP_GONE): in the batch's "off" list. Too busy on the map prefix: slower
-- steps (doubled), then the job goes to someone else. For the allied guilds only: my own guild
-- sees OpenMap's own dots (faster), my guild's RMAP is never drawn (Comm.lua reads it as my
-- guild's, only here).
-- places: [key] = { name, m, x, y, c, l, heard, moved (GetTime of its last move), sent = { m, x,
--   y, at } (the last place I passed on), full (class and level owed: new, changed, full refresh) }
-- gone: [key] = name, an "off" owed by the holder.
local places, gone = {}, {}
local mapBatchAt, mapFullAt = 0, 0
local mapSlow, mapBusySince = false, nil

local function MapStep(seconds) return mapSlow and seconds * 2 or seconds end

local function ValidPlace(m, x, y)
    if type(m) ~= "number" or m < 1 or m > 1000000 or m ~= math.floor(m) then return false end
    if type(x) ~= "number" or type(y) ~= "number" or not (x >= 0 and x <= 1 and y >= 0 and y <= 1) then return false end
    local ok, info = pcall(C_Map.GetMapInfo, m)
    return ok and info ~= nil
end

-- A name that fits in a batch: no separators, codes or link characters.
local function ValidMapName(name)
    return type(name) == "string" and not IsSecret(name) and #name <= 48 and name:find("%S") ~= nil
        and not name:find("[%c|%[%]:,;]")
end

-- A guildmate's place, from their OpenMap (test mode: a walker, /taverne dev walk).
function Relay:MapPlace(author, m, x, y, class, level)
    if not ValidMapName(author) or ns.IsMe(author) or not ns.Alliance:IsActive() then return end
    local key = ns.NameKey(author)
    if not key then return end
    -- They run La Taverne: they share their own place (AllyMap.lua), nothing to pass on.
    if ns.Players:RunsAddon(author) then
        stats.mapSkipped = stats.mapSkipped + 1
        mapSkippedFrom[key] = true
        places[key] = nil
        return
    end
    m, x, y, level = tonumber(m), tonumber(x), tonumber(y), tonumber(level)
    if not ValidPlace(m, x, y) then
        stats.mapBad = stats.mapBad + 1
        return
    end
    if type(class) ~= "string" or #class > 20 or not class:match("^%u+$") then class = nil end
    if not level or level < 1 or level > 200 or level ~= math.floor(level) then level = nil end
    local now = GetTime()
    local e = places[key]
    if not e then
        e = { name = author, full = true }
        places[key] = e
    end
    if e.m ~= m or math.abs(x - e.x) > 0.002 or math.abs(y - e.y) > 0.002 then e.moved = now end
    if (class and class ~= e.c) or (level and level ~= e.l) then e.full = true end
    e.m, e.x, e.y, e.heard = m, x, y, now
    e.c, e.l = class or e.c, level or e.l
    gone[key] = nil
    stats.mapHeard = stats.mapHeard + 1
    mapHeardFrom[key] = true
end

-- They stopped sharing (OpenMap's L0).
function Relay:MapStop(author)
    if not ValidMapName(author) then return end
    local key = ns.NameKey(author)
    local e = key and places[key]
    if not e then return end
    places[key] = nil
    gone[key] = e.name
end

local function PruneMap(now)
    for key, e in pairs(places) do
        if now - e.heard > MAP_GONE then
            places[key] = nil
            gone[key] = e.name
        end
    end
end

-- x or y (0..1) as 3 base-36 digits (1/46655 of the map).
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function Coord(v)
    local n = math.floor(v * 46655 + 0.5)
    local a, b, c = math.floor(n / 1296) + 1, math.floor(n / 36) % 36 + 1, n % 36 + 1
    return B36:sub(a, a) .. B36:sub(b, b) .. B36:sub(c, c)
end

local function MapDue(e, now)
    if e.full or not e.sent then return true end
    local s = e.sent
    local moved = s.m ~= e.m or math.abs(e.x - s.x) > MAP_MOVED or math.abs(e.y - s.y) > MAP_MOVED
    return now - s.at >= MapStep(moved and MAP_MOVING or MAP_STILL) - 0.5
end

-- As the holder: the next batch, once it's time and there's something to say. d = "name,map,x,y"
-- (",class,level" added when owed) joined by ";"; o = the names that stopped, joined by ";";
-- q = players still due after this batch.
local function PumpMap()
    local now = GetTime()
    PruneMap(now)
    local st = jobs.map
    if not st.holding then
        wipe(gone)
        return
    end
    if now - mapBatchAt < MapStep(MAP_BATCH) - 0.5 or SendingPaused() or not ns.Comm:IsAllyReady() then return end
    if now - mapFullAt >= MapStep(MAP_FULL) then
        mapFullAt = now
        for _, e in pairs(places) do e.full = true end
    end
    local due = {}
    for _, e in pairs(places) do
        if MapDue(e, now) then due[#due + 1] = e end
    end
    local offs = {}
    for key in pairs(gone) do
        if #offs >= MAP_CAP then break end
        offs[#offs + 1] = key
    end
    if #due == 0 and #offs == 0 then return end
    table.sort(due, function(a, b) return (a.moved or 0) > (b.moved or 0) end)
    local items, names = {}, {}
    for i = 1, math.min(#due, MAP_CAP) do
        local e = due[i]
        local item = format("%s,%d,%s,%s", e.name, e.m, Coord(e.x), Coord(e.y))
        if e.full then item = item .. "," .. (e.c or "") .. "," .. (e.l and tostring(e.l) or "") end
        items[#items + 1] = item
    end
    for i, key in ipairs(offs) do names[i] = gone[key] end
    local waiting = math.max(0, #due - MAP_CAP)
    local payload = { d = #items > 0 and table.concat(items, ";") or nil,
        o = #names > 0 and table.concat(names, ";") or nil, q = waiting, rp = RP }
    if not ns.Comm:SendAlly("RMAP", payload, "BULK", true, MAP_PREFIX) then return end
    Measure("RMAP", "map", ns.Comm.lastSend.parts, ns.Comm.lastSend.bytes)
    mapBatchAt = now
    for i = 1, #items do
        local e = due[i]
        e.sent, e.full = { m = e.m, x = e.x, y = e.y, at = now }, nil
    end
    for _, key in ipairs(offs) do gone[key] = nil end
    stats.mapBatches = stats.mapBatches + 1
    stats.mapSent = stats.mapSent + #items
    stats.mapOffs = stats.mapOffs + #names
    local report = st.report
    report.sent = report.sent + #items
    if waiting > report.maxq then report.maxq = waiting end
end

-- Watching the holder (not me): silent MAP_STALL while places come in (it beacons every minute,
-- and sends a batch whenever someone moves): it may be gone, the job is free (a stall election,
-- void if it's heard again).
local function WatchMap(job, st)
    local h = st.holder
    local now = GetTime()
    if now - h.heard < MAP_STALL then return end
    for _, e in pairs(places) do
        if now - e.heard < MAP_STALL then
            stats.stalls = stats.stalls + 1
            MarkFree(job, true, format("%s silent %d s with places to pass on", h.name, math.floor(now - h.heard)))
            return
        end
    end
end

JobHooks.map = {
    onTake = function() mapBatchAt, mapFullAt = 0, 0 end, -- everyone at once (a full refresh)
    onRelease = function() mapSlow, mapBusySince = false, nil end,
    watch = WatchMap,
}

-- My guild's map relay's batches: it's still there.
ns.Comm:On("RMAP", function(sender, p, isSelf)
    if isSelf then return end
    Relay:NoteProtocol(p.rp, true)
    HeardFrom("map", ns.NameKey(sender), p.q)
end)

-- OpenMap's messages to my guild: "L1 map x y class level" (tab-separated), "L0" stopped.
-- OpenMap needn't be installed here (OnLogin registers its prefix). Test mode: never the real
-- guild's (walkers stand in, below).
ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if IsSecret(prefix) or IsSecret(text) or IsSecret(channel) or IsSecret(sender) then return end
    if prefix ~= OPENMAP_PREFIX or channel ~= "GUILD" or ns.Guild:IsSandbox() then return end
    if type(text) ~= "string" or #text > 120 or type(sender) ~= "string" then return end
    local kind, m, x, y, class, level = strsplit("\t", text, 6)
    if kind == "L1" then
        Relay:MapPlace(sender, m, x, y, class, level)
    elseif kind == "L0" then
        Relay:MapStop(sender)
    end
end)

-- Test mode: a made-up test guild member without La Taverne who shares through OpenMap, walking
-- a circle around where I stood (/taverne dev walk). Every test guild candidate hears it (OMLOC on
-- the test guild's channel), as OpenMap's messages reach a real guild.
ns.Comm:On("OMLOC", function(sender, p, isSelf)
    if isSelf or not ns.Guild:IsSandbox() then return end
    if p.off then Relay:MapStop(p.as) else Relay:MapPlace(p.as, p.m, p.x, p.y, p.c, p.l) end
end)

local FAKE_CLASSES = { "WARRIOR", "MAGE", "PRIEST", "HUNTER", "ROGUE", "DRUID", "PALADIN", "WARLOCK", "SHAMAN" }
local walkers = {}
-- Started (true, true), stopped (true, false), or not possible (false: not test mode, a bad name,
-- or the game won't say where I am).
function Relay:FakeWalk(name)
    if not ns.Guild:IsSandbox() then return false end
    name = strtrim(name or "")
    if not ValidMapName(name) or ns.IsMe(name) then return false end
    local key = ns.NameKey(name)
    if walkers[key] then
        walkers[key]:Cancel()
        walkers[key] = nil
        ns.Comm:Send("OMLOC", { as = name, off = true }, "NORMAL")
        Relay:MapStop(name)
        return true, false
    end
    local m, x, y = ns.AllyMap.Here()
    if not m then return false end
    local class = FAKE_CLASSES[Hash(name) % #FAKE_CLASSES + 1]
    local angle = math.random() * 2 * math.pi
    local function Step()
        angle = angle + 0.17 -- (a lap in about 6 minutes, at one place every 10 s like OpenMap)
        local px = math.min(1, math.max(0, x + math.cos(angle) * 0.03))
        local py = math.min(1, math.max(0, y + math.sin(angle) * 0.03))
        ns.Comm:Send("OMLOC", { as = name, m = m, x = px, y = py, c = class, l = 60 }, "BULK", true)
        Relay:MapPlace(name, m, px, py, class, 60)
    end
    Step()
    walkers[key] = C_Timer.NewTicker(10, Step)
    return true, true
end

-- Every second -------------------------------------------------------------------------------

local function TickJob(job)
    local st = jobs[job]
    local now = GetTime()
    local tier, why = Tier(job)
    if st.holding then
        if not tier then
            Release(job, why)
        elseif tier == 3 and (st.heldTier or 0) < 3 then
            -- Joined a raid group, or away a long time: someone else, if anyone can. (Took it at
            -- tier 3: kept, or it would give it up and take it back forever.)
            Release(job, why)
        else
            st.heldTier = tier
            if now - st.lastBeacon >= BEACON_EVERY then Beacon(job) end
        end
        return
    end
    if not ns.Alliance:IsActive() or not ns.Comm:IsAllyReady() then return end
    if not st.askedAt then
        Ask()
        return
    end
    local h = st.holder
    if h and not st.free then
        if now - h.heard >= LEASE then
            MarkFree(job, false, h.name .. " not heard for " .. LEASE .. " s")
            return
        end
        -- Logged out (or left the guild), says the roster (once it's loaded), and it's quiet: the
        -- roster is refreshed once a minute, a holder who just logged in may still be offline in it.
        if ns.Guild:GetRosterCount() > 0 and now - h.heard >= HOLDER_SILENT then
            local member = ns.Guild:GetMember(h.name)
            if not (member and member.online) then
                MarkFree(job, false, h.name .. " is offline")
                return
            end
        end
    end
    if not st.free and not st.holder then
        if now - st.askedAt >= ASK_WAIT then MarkFree(job, false, "no relay") end
        return
    end
    if st.free then
        if st.settleAt then
            if now >= st.settleAt then Settle(job) end
            return
        end
        if st.claimAt then
            if now >= st.claimAt then TryClaim(job) end
        else
            ScheduleClaim(job)
        end
        if not st.claimAt and not st.settleAt
            and now - math.max(st.electionStart or 0, st.lastClaimHeard or 0) > ELECTION_TIMEOUT then
            -- Nobody took it: again. The claims heard (15 s old at least) belong to the round
            -- that failed: if they were kept, they'd keep everyone quiet a few seconds more.
            wipe(st.claims)
            MarkFree(job, st.stall)
        end
        return
    end
    -- A holder is there. Not during my own fight: I'd see stalls that aren't.
    if Fighting() then return end
    local hooks = JobHooks[job]
    if hooks and hooks.watch then
        hooks.watch(job, st, tier)
        if st.free then return end
    end
    -- Challenge: I'd be a much better relay, for a while now.
    if tier and h.tier and h.tier >= tier + TAKEOVER_GAP and (h.rp or 0) <= RP then
        st.betterSince = st.betterSince or now
        local spot = (Rank(MyKey(), job) % 1000) / 1000 * 5
        if now - st.betterSince >= TAKEOVER_AFTER + spot and now - st.challenged >= TAKEOVER_AFTER then
            st.challenged = now
            SendRLY("claim", job, { tier = tier, ch = 1 })
            Note("%s: %s is tier %d, I'm %d: asking for it", job, h.name, h.tier, tier)
        end
    else
        st.betterSince = nil
    end
end

-- Too busy: messages on the relay prefix at BUDGET_WARN % of the game's limit or more for
-- BUDGET_WARN_FOR: one warning (marked "!!" in the message log), and while I hold two jobs or
-- more, a job that can be shed goes to someone else (chat never: it queues).
local function Shed()
    local held = 0
    for _, job in ipairs(JOB_ORDER) do
        if jobs[job].holding then held = held + 1 end
    end
    if held < 2 then return end
    for i = #JOB_ORDER, 1, -1 do
        local job = JOB_ORDER[i]
        if JOBS[job].shed and jobs[job].holding then
            Release(job, "busy")
            return
        end
    end
end

-- Messages on a prefix in the last 60 s, as a % of the game's limit (1 a second per prefix).
local function PrefixPct(prefix, now)
    return math.floor(Sum(meter.prefix[prefix], math.floor(now), 60, "m") * 100 / 60)
end

-- The chat prefix: a warning, and a job handed over (Shed). The map prefix: slower steps at once,
-- and still busy BUDGET_WARN_FOR later, the map job handed over (chat untouched).
local function WatchBudget()
    local now = GetTime()
    local last = Sum(meter.sec, math.floor(now), 60, "m")
    if last > meter.peak then meter.peak = last end
    local pct = PrefixPct(PREFIX, now)
    if pct < BUDGET_WARN then
        meter.busySince, meter.warned = nil, false
    else
        meter.busySince = meter.busySince or now
        if not meter.warned and now - meter.busySince >= BUDGET_WARN_FOR then
            meter.warned = true
            meter.warnings = meter.warnings + 1
            Record("relay busy", "busy: %d%% of the game's limit for %d s", pct, BUDGET_WARN_FOR)
            Shed()
        end
    end
    if not jobs.map.holding then return end
    pct = PrefixPct(MAP_PREFIX, now)
    if pct >= BUDGET_WARN then
        mapBusySince = mapBusySince or now
        if not mapSlow then
            mapSlow = true
            Note("map: %d%% of the game's limit: slower steps", pct)
        elseif now - mapBusySince >= BUDGET_WARN_FOR then
            meter.warnings = meter.warnings + 1
            Record("relay busy", "map: still %d%% of the game's limit after %d s: handed over", pct, BUDGET_WARN_FOR)
            Release("map", "busy")
        end
    else
        mapBusySince = nil
        if mapSlow and pct < MAP_SLOW_BELOW then
            mapSlow = false
            Note("map: back to normal steps")
        end
    end
end

-- Uptime: each second, for every guild with a La Taverne player online (mine: me), whether its
-- relay's beacon is fresh. Which guilds have players online is read again every 15 s (the
-- allied players list isn't small).
local onlineGuilds, onlineAt = {}, nil
local function TrackUptime()
    if not ns.Alliance:IsActive() then return end
    local now = GetTime()
    if not onlineAt or now - onlineAt >= 15 then
        onlineAt = now
        wipe(onlineGuilds)
        for _, pl in ipairs(ns.Vouch:GetPlayers()) do
            if pl.online and type(pl.guild) == "string" then onlineGuilds[strtrim(pl.guild):lower()] = true end
        end
    end
    local online = onlineGuilds
    for _, g in ipairs(ns.Alliance:GetGuilds()) do
        local key = strtrim(g.name):lower()
        if online[key] or ns.Guild:IsMyGuild(g.name) then
            for _, job in ipairs(JOB_ORDER) do
                local s = MinuteSlot(Track(key, job))
                s.online = s.online + 1
                if Relay:GetStatus(g.name, job) then s.up = s.up + 1 end
            end
        end
    end
end

local function Tick()
    Prune()
    for _, job in ipairs(JOB_ORDER) do TickJob(job) end
    Pump()
    PumpMap()
    WatchBudget()
    TrackUptime()
end

function Relay:OnLogin()
    lastRefill = GetTime()
    -- OpenMap's positions reach me even without OpenMap (the map job).
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, OPENMAP_PREFIX)
    end
    awaySince = ns.IsAway() and GetTime() or nil
    ns.On("PLAYER_REGEN_DISABLED", function()
        fighting, lastFight = true, GetTime()
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        fighting, lastFight = false, GetTime()
        Pump()
    end)
    ns.On("PLAYER_FLAGS_CHANGED", function(unit)
        if unit ~= "player" then return end
        local away = ns.IsAway()
        if away == nil then return end -- the game won't say right now: as before
        if away and not awaySince then
            awaySince = GetTime()
        elseif not away then
            awaySince = nil
        end
    end)
    -- Logging out (or quitting): hand over while messages still go out, and don't claim it back
    -- during the countdown. Cancelled: a candidate again.
    local function LoggingOut()
        loggingOut = true
        for _, job in ipairs(JOB_ORDER) do Release(job, "logout") end
    end
    ns.On("PLAYER_CAMPING", LoggingOut)
    ns.On("PLAYER_QUITING", LoggingOut)
    ns.On("LOGOUT_CANCEL", function() loggingOut = false end)
    -- The alliance channel is ready (after login, or a new key): the next tick asks who relays
    -- (each guild's holders answer).
    ns.Comm:OnReady(function(role)
        if role ~= "ally" then return end
        for _, job in ipairs(JOB_ORDER) do jobs[job].askedAt = nil end
    end)
    C_Timer.NewTicker(TICK, Tick)
end

-- My switch (Options) ---------------------------------------------------------------------------

-- Turning "Help relay for my guild" on or off: my hello says it at once (the others' counts),
-- and the jobs I hold are handed over right away.
function Relay:SetHelp(on)
    on = on and true or false
    if (ns.db.relay.help and true or false) == on then return end
    ns.db.relay.help = on
    if on then
        ns.db.relay.told = true -- turned on by hand: no "you're relaying" notice owed
    else
        for _, job in ipairs(JOB_ORDER) do Release(job, "off") end
    end
    if ns.Vouch and ns.Vouch.HelloChanged then ns.Vouch:HelloChanged(true) end
    Changed()
end

-- How many other players of my guild can do this job right now: online, hello heard lately
-- (they're sent every 4-4.5 min), switch on, the job in what they can do; how many of them are
-- away (they may be logged out soon); whether the count is complete (my guildmates don't answer
-- my hello: in my first 5 minutes on the channel some aren't heard yet); and how many more
-- probably can (Players.lua: online, and their last hello before my login said they could).
local HELLO_FRESH = 9 * 60
function Relay:CountOthers(job)
    local cap = JOBS[job or "chat"].cap
    local count, away, probable = 0, 0, 0
    for _, h in ipairs(ns.Players:GetGuildHellos(HELLO_FRESH)) do
        local can = false
        for c in tostring(h.cap or ""):gmatch("[^,]+") do
            if strtrim(c) == cap then can = true end
        end
        if h.rl and can then
            if h.probable then
                probable = probable + 1
            else
                count = count + 1
                if h.afk then away = away + 1 end
            end
        end
    end
    return count, away, ns.Players:HellosComplete(), probable
end

-- The lines about the others (Stop popup, Alliance page): who can, who probably can, and that the
-- count isn't complete yet. guild: nil for "your guild".
function Relay:OthersLines(guild)
    local count, away, complete, probable = self:CountOthers("chat")
    local lines = {}
    if guild then
        if count > 0 or complete then
            lines[#lines + 1] = (away > 0 and format(L["Other players in %s who can relay right now: %d (%d away)."], guild, count, away))
                or format(L["Other players in %s who can relay right now: %d."], guild, count)
        end
    else
        lines[#lines + 1] = (away > 0 and format(L["Others in your guild who can relay right now: %d (%d away)."], count, away))
            or format(L["Others in your guild who can relay right now: %d."], count)
    end
    if probable > 0 then
        lines[#lines + 1] = format(L["Probably %d more: they could relay last time, and haven't said so yet since you logged in (players say it every 4 to 5 minutes)."], probable)
    elseif not complete then
        lines[#lines + 1] = L["You logged in a few minutes ago: players say whether they can relay every 4 to 5 minutes, so some may not be counted yet."]
    end
    return lines, count + probable > 0 or not complete
end

local function MyGuildLabel()
    local name = ns.Guild:GetName()
    local tag = ns.Alliance:GetTag(name)
    return tag and ("[" .. tag .. "]") or (name or "?")
end

-- Before turning the switch off: how many others can still relay, and what the allied guilds
-- lose if none are left. onStop: the player confirmed.
function Relay:AskToStop(onStop)
    local guild = MyGuildLabel()
    local lines = {}
    for _, job in ipairs(JOB_ORDER) do
        if jobs[job].holding then
            lines[#lines + 1] = format(L["You're relaying for %s right now."], guild)
            break
        end
    end
    local others, maybeSomeone = self:OthersLines(guild)
    if maybeSomeone then
        for _, line in ipairs(others) do lines[#lines + 1] = line end
        lines[#lines + 1] = L["If none are left, the allied guilds stop seeing the guild chat of your members without La Taverne."]
    else
        lines[#lines + 1] = format(L["Nobody else in %s can relay right now."], guild)
        lines[#lines + 1] = L["If you stop, the allied guilds stop seeing the guild chat of your members without La Taverne."]
    end
    ns.ConfirmDialog({
        kind = "relayStop",
        text = table.concat(lines, "\n\n"),
        buttons = {
            { text = L["Stop relaying"], onClick = onStop },
            { text = L["Keep helping"] },
        },
    })
end

-- Text -----------------------------------------------------------------------------------------

local WHY = {
    off = "switched off", alliance = "no alliance", channel = "alliance channel not ready",
    chat = "allied chat off", info = "Guild Info not read yet", officers = "turned off by the officers",
    newer = "a newer relay is in use", instance = "in an instance", raid = "in a raid group",
    away = "away", logout = "logged out", better = "a better relay took over", ["two holders"] = "another relay",
    busy = "too busy", old = "La Taverne without the relay",
}
-- A reason code (CantReason, a release's why) as text for the player.
function Relay.WhyText(why)
    return L[WHY[why] or "unknown"]
end

local TIER_NAMES = { [0] = "city", [1] = "world", [2] = "fought recently", [3] = "last resort" }
function Relay.TierText(tier)
    return L[TIER_NAMES[tier] or "unknown"]
end

local JOB_NAMES = { chat = "Guild chat", map = "Map positions" }
function Relay.JobText(job)
    return L[JOB_NAMES[job] or tostring(job)]
end

-- My state in a few words (Options, Alliance page, minimap tooltip): relaying (green), ready
-- to (and my tier), or why not (grey).
function Relay:MyStateText()
    local held = {}
    for _, job in ipairs(JOB_ORDER) do
        if jobs[job].holding then held[#held + 1] = Relay.JobText(job) end
    end
    if #held > 0 then return "|cff20ff20" .. format(L["Relaying: %s"], table.concat(held, ", ")) .. "|r" end
    local tier, why = Tier("chat")
    if not tier then return "|cff808080" .. format(L["Not relaying: %s"], Relay.WhyText(why)) .. "|r" end
    local text = Relay.TierText(tier)
    if why then text = text .. ", " .. Relay.WhyText(why) end
    return format(L["Ready to relay (%s)"], text)
end

-- The live window (/taverne relay, the Debug tab) ---------------------------------------------
-- Everything about the relay, filled again every LIVE_EVERY seconds, in both modes (test mode
-- carries only the test guild's lines, so the real guild's load shows only outside it). Top
-- first: every guild's relay, my guild's candidates per tier, me and the election, my sending,
-- the counts since login, the last events. Copy selects it all (to paste in a message).
local function Plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Since(t)
    return t and date("%H:%M", t) or "?"
end

local function Pct(a, b)
    return b > 0 and math.floor(a * 100 / b + 0.5) or 0
end

-- This hour for a guild and job: uptime %, planned and unplanned holder changes, and the seconds
-- it had a La Taverne player online (0: nothing to say). nil: never heard of.
local function Stability(g, job)
    local t = stability[g] and stability[g][job]
    if not t then return nil end
    local idx = math.floor(GetTime() / 60)
    local online = Sum(t.min, idx, 60, "online")
    return Pct(Sum(t.min, idx, 60, "up"), online), Sum(t.min, idx, 60, "planned"),
        Sum(t.min, idx, 60, "unplanned"), online
end

-- My guild's candidates for a job, per tier: me now, the others as their last hello said (up to
-- 4.5 min old). tiers[0..3]; cant[why] (switched off, an instance..., "old": La Taverne without
-- the relay); unknown: their hello didn't say a tier (an earlier test version); probable: not
-- heard since my login, and their last hello before it said they could (Players.lua); the
-- others not heard yet count where their last hello put them (off, or without the relay).
local function TierCounts(job)
    local cap = JOBS[job].cap
    local tiers, cant, unknown, probable = { [0] = 0, 0, 0, 0 }, {}, 0, 0
    local function Add(tr, tw)
        local t = ValidTier(tr)
        if t then
            tiers[t] = tiers[t] + 1
        elseif tr == "x" then
            local why = tw or "unknown"
            cant[why] = (cant[why] or 0) + 1
        else
            unknown = unknown + 1
        end
    end
    local mine, why = Tier(job)
    Add(mine or "x", not mine and why or nil)
    for _, h in ipairs(ns.Players:GetGuildHellos(HELLO_FRESH)) do
        local can = false
        for c in tostring(h.cap or ""):gmatch("[^,]+") do
            if strtrim(c) == cap then can = true end
        end
        if h.probable and h.rl and can then
            probable = probable + 1
        elseif not h.cap then
            cant.old = (cant.old or 0) + 1
        elseif not h.rl then
            cant.off = (cant.off or 0) + 1
        elseif not can then
            cant.old = (cant.old or 0) + 1
        else
            Add(h.tr, h.tw)
        end
    end
    return tiers, cant, unknown, probable
end

local function ReportText()
    local out = {}
    local function Add(text) out[#out + 1] = text end
    local now, server = GetTime(), GetServerTime()
    Add(format(L["La Taverne %s, guild relay, %s (relay protocol %d)"], tostring(ns.version), date("%H:%M:%S"), RP))

    -- Every guild's relay, as heard.
    Add("")
    Add(L["Relays"])
    if not ns.Alliance:IsActive() then Add("    " .. L["No Guild Alliance: nothing to relay."]) end
    for _, g in ipairs(ns.Alliance:GetGuilds()) do
        local key = strtrim(g.name):lower()
        local label = "[" .. (g.tag or "?") .. "]" .. (ns.Guild:IsMyGuild(g.name) and (" " .. L["(your guild)"]) or "")
        for _, job in ipairs(JOB_ORDER) do
            local entry, why = Relay:GetStatus(g.name, job)
            local head = "    " .. label .. " " .. Relay.JobText(job) .. ": "
            if entry then
                Add(head .. format(L["%s (%s), heard %d s ago, relaying since %s"],
                    ns.IsMe(entry.name) and L["you"] or entry.name, Relay.TierText(entry.tier),
                    server - entry.heard, Since(entry.since)))
                if entry.p and job == "map" then
                    Add("        " .. format(L["last minute: %d positions, %d messages (%d bytes), budget about %d%%, most waiting %d, throttled %d"],
                        entry.sent or 0, entry.p, entry.b or 0, Pct(entry.p, BEACON_EVERY), entry.maxq or 0, entry.th or 0))
                elseif entry.p then
                    Add("        " .. format(L["last minute: %d lines, %d messages (%d bytes), budget about %d%%, max queue %d, throttled %d"],
                        entry.sent or 0, entry.p, entry.b or 0, Pct(entry.p, BEACON_EVERY), entry.maxq or 0, entry.th or 0))
                elseif entry.sent then
                    Add("        " .. format(L["last minute: %d lines, max queue %d"], entry.sent, entry.maxq or 0))
                end
            else
                if ns.Guild:IsMyGuild(g.name) and ns.Alliance:IsInfoKnown() and not ns.Alliance:RelayAllows(job) then
                    why = "officers"
                end
                Add(head .. (why and format(L["nobody (%s)"], Relay.WhyText(why)) or L["nobody"]) .. ", "
                    .. (Relay:HasPlayersOnline(g.name) and L["La Taverne players online"] or L["no La Taverne player online"]))
            end
            local up, planned, unplanned, online = Stability(key, job)
            if up and online > 0 then
                Add("        " .. format(L["this hour: up %d%% of the time, holder changes: %d planned, %d unplanned"],
                    up, planned, unplanned))
            end
        end
    end

    -- My guild's candidates per tier.
    for _, job in ipairs(JOB_ORDER) do
        local tiers, cant, unknown, probable = TierCounts(job)
        Add("")
        Add(format(L["Who can relay in %s (%s): you now, the others as of their last hello (up to 5 min old)"],
            MyGuildLabel(), Relay.JobText(job)))
        local parts = {}
        for t = 0, 3 do parts[#parts + 1] = Relay.TierText(t) .. " " .. tiers[t] end
        Add("    " .. table.concat(parts, ", "))
        parts = {}
        for code, n in pairs(cant) do parts[#parts + 1] = Relay.WhyText(code) .. " " .. n end
        table.sort(parts)
        if #parts > 0 then Add("    " .. L["can't:"] .. " " .. table.concat(parts, ", ")) end
        if unknown > 0 then Add("    " .. format(L["tier not said: %d"], unknown)) end
        if probable > 0 then Add("    " .. format(L["not heard since you logged in, probably can: %d"], probable)) end
    end

    -- Me, and my view of my guild's election.
    Add("")
    Add(L["You"])
    Add("    " .. Plain(Relay:MyStateText()) .. "; " .. (ns.db.relay.help and L["switch on"] or L["switch off"]) .. "; "
        .. (ns.Alliance:IsInfoKnown() and L["Guild Info read"] or L["Guild Info not read yet"]) .. "; "
        .. format(L["officers' line: %s"], tostring(ns.Alliance.RelayLine(ns.Alliance:GetRelayRule()) or L["none (every job allowed)"])))
    if newerRp then Add("    " .. format(L["A newer relay protocol is in use in your guild: %d."], newerRp)) end
    for _, job in ipairs(JOB_ORDER) do
        local st = jobs[job]
        local h = st.holder
        local claims = 0
        for _ in pairs(st.claims) do claims = claims + 1 end
        local line
        if st.holding then
            line = format(L["%s: you hold it since %s (%s)"], Relay.JobText(job), Since(st.since), Relay.TierText(st.heldTier))
        elseif h then
            line = format(L["%s: %s holds it (%s), heard %d s ago, %d waiting"], Relay.JobText(job), h.name,
                Relay.TierText(h.tier), math.floor(now - h.heard), h.q or 0)
        else
            line = format(L["%s: nobody holds it"], Relay.JobText(job))
        end
        if st.free then
            line = line .. "; " .. format(L["election open: %d claims"], claims)
            if st.stall then line = line .. " " .. L["(the holder went quiet)"] end
            if st.claimAt then line = line .. ", " .. format(L["your claim in %.1f s"], st.claimAt - now) end
            if st.settleAt then line = line .. ", " .. format(L["settling in %.1f s"], st.settleAt - now) end
            if st.quiet then line = line .. ", " .. L["you stay quiet (a claim as good as yours)"] end
        end
        Add("    " .. line)
    end

    -- My sending on the relay prefix.
    local sec, minute = math.floor(now), math.floor(now / 60)
    local last = Sum(meter.sec, sec, 60, "m")
    Add("")
    Add(L["What you send for the relay"])
    Add("    " .. format(L["messages (bytes): last 10 s %d (%d), last minute %d (%d), last 10 min %d (%d)"],
        Sum(meter.sec, sec, 10, "m"), Sum(meter.sec, sec, 10, "b"), last, Sum(meter.sec, sec, 60, "b"),
        Sum(meter.min, minute, 10, "m"), Sum(meter.min, minute, 10, "b")))
    Add("    " .. format(L["budget: chat %d%%, map %d%% of the game's limit (warning at %d%% for %d min: %d so far), busiest minute %d messages"],
        PrefixPct(PREFIX, now), PrefixPct(MAP_PREFIX, now), BUDGET_WARN, BUDGET_WARN_FOR / 60, meter.warnings, meter.peak))
    -- Refused: the game's result codes too (Enum.SendAddonMessageResult: 7 invalid channel...).
    local codes = {}
    for code, n in pairs(meter.failCodes) do codes[#codes + 1] = code .. " x" .. n end
    table.sort(codes)
    Add("    " .. format(L["messages per line: average %.1f, max %d; coordination %d%% of what you sent; held back 1 s or more %d, refused %d"],
        meter.items > 0 and meter.parts / meter.items or 0, meter.maxParts, Pct(meter.rly, meter.all), meter.held, meter.failed)
        .. (#codes > 0 and (" (" .. L["game codes:"] .. " " .. table.concat(codes, ", ") .. ")") or ""))
    local owed = 0
    for _, e in ipairs(buffer) do
        if not e.covered then owed = owed + 1 end
    end
    Add("    " .. format(L["lines kept %d (%d not passed on yet), queue %d, burst left %.1f of %d, sending %s"],
        #buffer, owed, #queue, tokens, BURST, SendingPaused() and L["paused (a fight)"] or L["ok"]))
    local kept, recent, stops = 0, 0, 0
    for _, e in pairs(places) do
        kept = kept + 1
        if now - e.heard < 60 then recent = recent + 1 end
    end
    for _ in pairs(gone) do stops = stops + 1 end
    Add("    " .. format(L["map: players kept %d (heard in the last minute %d), stops owed %d, steps %s"],
        kept, recent, stops, mapSlow and L["slowed (busy)"] or L["normal"]))

    -- Counts since login.
    local s = stats
    Add("")
    Add(L["Since you logged in"])
    Add("    " .. format(L["guild lines %d, needed a relay %d (%d%%), passed on within %d s %d (%d%%), late %d, lost %d, sent by their author %d"],
        s.lines, s.needed, Pct(s.needed, s.lines), STALL_OWED, s.onTime, Pct(s.onTime, s.needed), s.late, s.lost, s.byAuthor))
    Add("    " .. format(L["as the relay: sent %d (gap fills %d), wait average %.1f s, max %.1f s, max queue %d"],
        s.sent, s.gapFills, s.sent > 0 and s.waitTotal / s.sent or 0, s.waitMax, s.maxQueue))
    Add("    " .. format(L["took it %d, gave it up %d, stalls %d, elections %d, your claims %d"],
        s.took, s.released, s.stalls, s.elections, s.claims))
    local a = ns.AllyChat.stats
    Add("    " .. format(L["received: relayed lines %d, copies dropped %d, refused %d"], a.relayed or 0, a.copies or 0, a.refused or 0))
    local heardFrom, skippedFrom = 0, 0
    for _ in pairs(mapHeardFrom) do heardFrom = heardFrom + 1 end
    for _ in pairs(mapSkippedFrom) do skippedFrom = skippedFrom + 1 end
    Add("    " .. format(L["map, heard from OpenMap: %d positions from %d players without La Taverne (to pass on); skipped %d from %d players with La Taverne (they share their own); refused %d"],
        s.mapHeard, heardFrom, s.mapSkipped, skippedFrom, s.mapBad))
    Add("    " .. format(L["map, sent by you as the relay: %d positions in %d messages, %d players stopped sharing"],
        s.mapSent, s.mapBatches, s.mapOffs))
    local m = ns.AllyMap.stats
    Add("    " .. format(L["received: relayed positions %d, refused %d"], m.relayed or 0, m.relayedRefused or 0))

    -- The last events, newest first.
    Add("")
    Add(L["Last events"])
    if #events == 0 then Add("    " .. L["none yet"]) end
    for i = #events, 1, -1 do
        local e = events[i]
        local ok, text = pcall(format, L[e.fmt], unpack(e.args, 1, e.args.n))
        Add("    " .. date("%H:%M:%S", e.t) .. "  " .. (ok and text or e.fmt))
    end
    return table.concat(out, "\n")
end

function Relay:ShowLive()
    ns.TextDialog({
        kind = "relay",
        title = L["Guild relay"],
        width = 760,
        hint = L["Filled again every 3 seconds (it waits while the mouse is over the text). Copy selects it all: then Ctrl+C."],
        text = ReportText(),
        button = L["Copy"],
        onButton = function()
            ns.SelectTextDialog()
            return false
        end,
        autoFill = ReportText,
        autoEvery = LIVE_EVERY,
    })
end

ns.commands.relay = function() Relay:ShowLive() end
