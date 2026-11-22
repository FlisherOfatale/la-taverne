-- Guild relay: in each guild, one La Taverne player (the relay) passes on to the allied guilds
-- what members without La Taverne can't share themselves. For now: guild chat. Members with La
-- Taverne still send their own lines (AllyChat.lua); the relay only fills in for the others.
-- Relayed lines are shown exactly like other allied lines, and never posted in real guild chat.
-- (Design and reasons: .plans/guild-relay.md, not in the addon.)
--
-- Jobs: each job (chat now, map positions later) has its own relay per guild. Every La Taverne
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
local ADDON, ns = ...
local Relay = ns.NewModule("Relay")
local L = ns.L

Relay.RP = 1 -- relay protocol: raised only for a change older relays can't follow
local RP = Relay.RP
local PREFIX = ns.Comm.RELAY_PREFIX

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

-- Jobs: name, what HI says I can do (cap), claim delay offset, message priority.
local JOBS = {
    chat = { name = "chat", cap = "c1", offset = 0 },
}
local JOB_ORDER = { "chat" }

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- Counters for /taverne relay and the beacon's report.
Relay.stats = {
    lines = 0,           -- guild lines seen (not mine)
    needed = 0,          -- ... whose author doesn't run La Taverne: they need a relay
    onTime = 0, late = 0, lost = 0, -- needed lines: relayed within 8 s, later, never
    byAuthor = 0,        -- lines covered by the author's own copy
    sent = 0, gapFills = 0, waitTotal = 0, waitMax = 0, maxQueue = 0, -- as the relay
    took = 0, released = 0, stalls = 0, elections = 0, claims = 0,
}
local stats = Relay.stats

-- State --------------------------------------------------------------------------------------

local myKey
local function MyKey()
    myKey = myKey or ns.NameKey(ns.FullName("player"))
    return myKey
end

local fighting, lastFight, awaySince = false, nil, nil
local loggingOut = false -- the logout countdown: handed over, never claimed back
local allyReadyAt        -- GetTime() my alliance channel got ready (the hellos I can have heard)
local newerRp, newerAt -- a higher relay protocol heard in my guild (and when): I step aside
local NEWER_FOR = 600   -- ...until it hasn't been heard for this long (hellos repeat it every 4-4.5 min)
local newerTold = false

-- [job] = my view of that job in my guild.
--   holding, since (server time), heldTier, lastHeld (GetTime, for "prev")
--   holder: my guild's holder when it isn't me: { name, key, tier, since, rp, heard, q, lastLine }
--   free: an election is open. stall: it started because the holder stalled (void if heard again)
--   claims: [key] = { name, key, tier, prev, rp, rank, at }; claimAt, settleAt, quiet
--   electionStart, lastClaimHeard, askedAt, lastBeacon, lastAnswer, lastBeaconAgain
--   betterSince, challenged: the challenge watch. report: { sent, maxq } since my last beacon
local jobs = {}
for _, job in ipairs(JOB_ORDER) do
    jobs[job] = { claims = {}, lastBeacon = 0, lastAnswer = 0, lastBeaconAgain = 0, challenged = 0,
        report = { sent = 0, maxq = 0 } }
end

-- Every guild's relays, as heard from beacons and releases (mine too):
-- [guild lowercase] = { [job] = { name, tier, since, rp, heard (server time), sent, maxq } or { why, heard } }
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

local function Note(text, unusual)
    ns.Comm:LogNote("relay: " .. text, unusual)
end

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
    if not ns.AllyChat.Enabled() then return "chat" end
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

-- Status --------------------------------------------------------------------------------------

local function NoteStatus(guild, job, entry)
    if type(guild) ~= "string" or guild == "" then return end
    local g = strtrim(guild):lower()
    status[g] = status[g] or {}
    entry.heard = GetServerTime()
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

local function SendRLY(op, job, fields)
    local payload = fields or {}
    payload.op, payload.j, payload.rp = op, job, RP
    return ns.Comm:SendAlly("RLY", payload, "ALERT", true, PREFIX)
end

local function Beacon(job)
    local st = jobs[job]
    if SendingPaused() then return end -- the tick sends it once the fight is over
    st.lastBeacon = GetTime()
    local tier = Tier(job) or 3
    st.beaconTier = tier -- what the others know of me (two holders compare these)
    local report = st.report
    SendRLY("hold", job, { tier = tier, since = st.since, sent = report.sent, mq = report.maxq })
    report.sent, report.maxq = 0, 0
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
        Note(format("%s is free (%s)", job, why))
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
    st.report.sent, st.report.maxq = 0, 0
    stats.took = stats.took + 1
    Note(format("I hold %s (tier %s)", job, tostring(st.heldTier)))
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
    stats.released = stats.released + 1
    Note(format("I give %s up (%s)", job, tostring(why)))
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
    Note(format("I claim %s (tier %d)", job, tier))
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
        Note(format("%s: %s is back, no new relay", job, h.name))
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
            sent = tonumber(p.sent), maxq = tonumber(p.mq) })
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
            sent = tonumber(p.sent), maxq = tonumber(p.mq) })
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

-- What my hello says about relaying (Vouch.lua): switch on (rl), jobs I can do (cap), protocol.
function Relay:HelloFields(payload)
    payload.rl = ns.db.relay.help and 1 or nil
    local caps = {}
    for _, job in ipairs(JOB_ORDER) do caps[#caps + 1] = JOBS[job].cap end
    payload.cap = table.concat(caps, ",")
    payload.rp = RP
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
                    Note(format("%s missed a line from %s: sent it", h.name, e.author))
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
            Note(format("%s: %s is tier %d, I'm %d: asking for it", job, h.name, h.tier, tier))
        end
    else
        st.betterSince = nil
    end
end

local function Tick()
    Prune()
    for _, job in ipairs(JOB_ORDER) do TickJob(job) end
    Pump()
end

function Relay:OnLogin()
    lastRefill = GetTime()
    awaySince = (UnitIsAFK and UnitIsAFK("player")) and GetTime() or nil
    ns.On("PLAYER_REGEN_DISABLED", function()
        fighting, lastFight = true, GetTime()
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        fighting, lastFight = false, GetTime()
        Pump()
    end)
    ns.On("PLAYER_FLAGS_CHANGED", function(unit)
        if unit ~= "player" then return end
        local away = UnitIsAFK and UnitIsAFK("player")
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
        allyReadyAt = GetTime()
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
-- (they're sent every 4-4.5 min), switch on, the job in what they can do. And how many of
-- them are away (they may be logged out soon), and whether the count is complete: my
-- guildmates don't answer my hello, so in my first minutes on the channel some aren't heard yet.
local HELLO_FRESH = 9 * 60
local HELLO_ALL = 300 -- on the channel this long: every guildmate's hello heard once
function Relay:CountOthers(job)
    local cap = JOBS[job or "chat"].cap
    local count, away = 0, 0
    for _, h in ipairs(ns.Players:GetGuildHellos(HELLO_FRESH)) do
        local can = false
        for c in tostring(h.cap or ""):gmatch("[^,]+") do
            if strtrim(c) == cap then can = true end
        end
        if h.rl and can then
            count = count + 1
            if h.afk then away = away + 1 end
        end
    end
    return count, away, allyReadyAt ~= nil and GetTime() - allyReadyAt >= HELLO_ALL
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
    local count, away, complete = self:CountOthers("chat")
    if count > 0 or not complete then
        if count > 0 then
            lines[#lines + 1] = (away > 0 and format(L["Other players in %s who can relay right now: %d (%d away)."], guild, count, away))
                or format(L["Other players in %s who can relay right now: %d."], guild, count)
        end
        if not complete then lines[#lines + 1] = L["You logged in a few minutes ago: players say whether they can relay every 4 to 5 minutes, so some may not be counted yet."] end
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
}
-- A reason code (CantReason, a release's why) as text for the player.
function Relay.WhyText(why)
    return L[WHY[why] or "unknown"]
end

local TIER_NAMES = { [0] = "city", [1] = "world", [2] = "fought recently", [3] = "last resort" }
function Relay.TierText(tier)
    return L[TIER_NAMES[tier] or "unknown"]
end

local JOB_NAMES = { chat = "Guild chat" }
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

-- /taverne relay: everything about the relay, in the copy window (to paste in a message to the
-- author). English only, like the other reports.
local function Plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Since(t)
    return t and date("%H:%M", t) or "?"
end

ns.commands.relay = function()
    local Log = ns.Log
    wipe(ns.log)
    Log("La Taverne", ns.version, "relay", date("%Y-%m-%d %H:%M:%S"), "protocol", RP)
    local myGuild = ns.Guild:GetName()
    Log("me:", Plain(Relay:MyStateText()), "| switch", ns.db.relay.help and "on" or "off",
        "| guild info", ns.Alliance:IsInfoKnown() and "read" or "not read yet",
        "| rule", tostring(ns.Alliance.RelayLine(ns.Alliance:GetRelayRule()) or "none (every job)"),
        newerRp and ("| newer protocol in my guild: " .. newerRp) or "")
    local others, away = Relay:CountOthers("chat")
    Log("others in my guild who can relay now:", others, away > 0 and ("(" .. away .. " away)") or "")
    -- Every guild's relay, as heard.
    for _, g in ipairs(ns.Alliance:GetGuilds()) do
        for _, job in ipairs(JOB_ORDER) do
            local entry, why = Relay:GetStatus(g.name, job)
            local mine = ns.Guild:IsMyGuild(g.name) and " (mine)" or ""
            if entry then
                local heard = GetServerTime() - entry.heard
                Log(format("[%s]%s %s: %s, tier %s, since %s, heard %d s ago, vouch %s, since its previous beacon %s sent, max queue %s",
                    g.tag or "?", mine, job, entry.name, tostring(entry.tier), Since(entry.since), heard,
                    ns.IsMe(entry.name) and "me" or mine ~= "" and "my guild" or tostring(ns.Vouch:GetState(entry.name)),
                    tostring(entry.sent or "?"), tostring(entry.maxq or "?")))
            else
                if mine ~= "" and ns.Alliance:IsInfoKnown() and not ns.Alliance:RelayAllows(job) then why = "officers" end
                Log(format("[%s]%s %s: none%s, La Taverne players online: %s", g.tag or "?", mine, job,
                    why and (" (" .. why .. ")") or "", Relay:HasPlayersOnline(g.name) and "yes" or "no"))
            end
        end
    end
    -- My view of my guild's election.
    local now = GetTime()
    for _, job in ipairs(JOB_ORDER) do
        local st = jobs[job]
        local h = st.holder
        local n = 0
        for _ in pairs(st.claims) do n = n + 1 end
        Log(format("%s: holding %s, holder %s, free %s%s%s, claims %d%s%s", job,
            st.holding and ("yes since " .. Since(st.since) .. ", tier " .. tostring(st.heldTier)) or "no",
            h and format("%s (tier %s, heard %d s ago, q %d)", h.name, tostring(h.tier), math.floor(now - h.heard), h.q or 0) or "none",
            st.free and "yes" or "no", st.stall and " (stall)" or "", st.quiet and " quiet" or "", n,
            st.claimAt and format(", my claim in %.1f s", st.claimAt - now) or "",
            st.settleAt and format(", settling in %.1f s", st.settleAt - now) or ""))
    end
    local owed = 0
    for _, e in ipairs(buffer) do
        if not e.covered then owed = owed + 1 end
    end
    Log(format("buffer %d lines (%d not covered), early copies %d, queue %d, budget %.1f / %d, sending %s",
        #buffer, owed, #earlyCopies, #queue, tokens, BURST, SendingPaused() and "paused" or "ok"))
    local s = stats
    Log(format("guild lines %d, needed a relay %d (%d%%), within %d s %d (%d%%), late %d, lost %d, covered by their author %d",
        s.lines, s.needed, s.lines > 0 and math.floor(s.needed * 100 / s.lines) or 0, STALL_OWED, s.onTime,
        s.needed > 0 and math.floor(s.onTime * 100 / s.needed) or 0, s.late, s.lost, s.byAuthor))
    Log(format("as the relay: sent %d (gap fills %d), wait avg %.1f s, max %.1f s, max queue %d",
        s.sent, s.gapFills, s.sent > 0 and s.waitTotal / s.sent or 0, s.waitMax, s.maxQueue))
    Log(format("took %d, gave up %d, stalls %d, elections %d, my claims %d",
        s.took, s.released, s.stalls, s.elections, s.claims))
    local a = ns.AllyChat.stats
    Log(format("received: relayed lines accepted %d, copies dropped %d, refused %d", a.relayed or 0, a.copies or 0, a.refused or 0))
    ns.ShowCopyWindow()
end
