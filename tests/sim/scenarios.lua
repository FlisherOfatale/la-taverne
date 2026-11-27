-- Relay scenarios: guilds, players and what happens to them, and what must hold meanwhile.
-- Each scenario returns its failures (empty: passed) and its figures. "known" scenarios show a
-- limitation of the relay as it is: printed, never failing the run (see README in this folder).
local World = require("world")

local JOBS = { "chat", "map" }

-- Per second, for each guild and job: how many hold it (two at once, neither in a chat lockdown:
-- they missed each other),
-- whether nobody holds it while someone could (a gap), whether the guild's players agree on
-- who holds it, and whether the allied guilds see that holder.
local function Recorder(w)
    local rec = { by = {}, world = w }
    local function Get(g, job)
        local k = g .. "/" .. job
        local r = rec.by[k]
        if not r then
            r = { guild = g, job = job, dual = 0, maxDual = 0, gap = 0, maxGap = 0, gapTotal = 0,
                eligibleTotal = 0, split = 0, maxSplit = 0, hidden = 0, maxHidden = 0, changes = 0 }
            rec.by[k] = r
        end
        return r
    end
    w:Watch(function()
        for _, g in ipairs(w.guildOrder) do
            local online = w:Online(g.name)
            for _, job in ipairs(JOBS) do
                local r = Get(g.name, job)
                local holders, eligible = {}, 0
                local sending = 0 -- holders not in a lockdown: a locked holder sends nothing
                for _, c in ipairs(online) do
                    if c:Holding(job) then
                        holders[#holders + 1] = c
                        if not c.locked then sending = sending + 1 end
                    end
                    if c:CanRelay(job) then eligible = eligible + 1 end
                end
                r.dual = sending >= 2 and r.dual + 1 or 0
                if r.dual > r.maxDual then r.maxDual, r.maxDualAt = r.dual, w.now end
                if eligible > 0 then r.eligibleTotal = r.eligibleTotal + 1 end
                if #holders == 0 and eligible > 0 then
                    r.gap, r.gapTotal = r.gap + 1, r.gapTotal + 1
                else
                    r.gap = 0
                end
                if r.gap > r.maxGap then r.maxGap, r.maxGapAt = r.gap, w.now end
                local holder = #holders == 1 and holders[1] or nil
                local hk = holder and holder.key
                if hk ~= r.last then
                    if hk and r.last then r.changes = r.changes + 1 end
                    r.last = hk or r.last
                end
                -- Agreement: every guildmate ready on the alliance channel names that holder.
                local split = false
                if holder then
                    for _, c in ipairs(online) do
                        if c.allyReady and c:View(job) ~= hk then split = true end
                    end
                end
                r.split = split and r.split + 1 or 0
                if r.split > r.maxSplit then r.maxSplit, r.maxSplitAt = r.split, w.now end
                -- Seen by the allies: every player of another guild who's ready names that holder.
                local hidden = false
                if holder then
                    for _, c in ipairs(w:Online()) do
                        if c.guild ~= g.name and c.allyReady then
                            local entry = c.relay:GetStatus(g.name, job)
                            if not entry or entry.name:lower() ~= hk then hidden = true end
                        end
                    end
                end
                r.hidden = hidden and r.hidden + 1 or 0
                if r.hidden > r.maxHidden then r.maxHidden, r.maxHiddenAt = r.hidden, w.now end
            end
        end
    end)
    return rec
end

local function NewWorld(seed, opts)
    opts = opts or {}
    opts.seed, opts.addonDir = seed, opts.addonDir
    local w = World.new(opts)
    return w, Recorder(w)
end

-- Checks on the figures; limits: { dual, gap, split, hidden, changes } per guild/job (max).
local function Check(rec, limits, only)
    local fails = {}
    for _, r in pairs(rec.by) do
        if not only or only[r.guild] then
            local function over(field, label, value)
                local limit = limits[field]
                if limit and value > limit then
                    fails[#fails + 1] = string.format("%s %s: %s %d s (limit %d)", r.guild, r.job, label, value, limit)
                end
            end
            over("dual", "two holders for", r.maxDual)
            over("gap", "no holder for", r.maxGap)
            over("split", "guildmates disagreeing on the holder for", r.maxSplit)
            over("hidden", "holder unseen by the allied guilds for", r.maxHidden)
            if limits.changes and r.changes > limits.changes then
                fails[#fails + 1] = string.format("%s %s: %d holder changes (limit %d)", r.guild, r.job, r.changes, limits.changes)
            end
            if limits.gapShare and r.eligibleTotal > 0 and r.gapTotal / r.eligibleTotal > limits.gapShare then
                fails[#fails + 1] = string.format("%s %s: no holder %.1f %% of the time (limit %.1f %%)", r.guild, r.job,
                    100 * r.gapTotal / r.eligibleTotal, 100 * limits.gapShare)
            end
        end
    end
    -- The relay's self-checks (Relay.lua) must stay quiet unless the scenario expects them.
    if not limits.selfChecks then
        for _, e in ipairs(rec.world.selfChecks) do
            if not only or only[e.guild] then
                fails[#fails + 1] = string.format("%s at %.0f: %s", e.name, e.at, e.text)
            end
        end
    end
    table.sort(fails)
    return fails
end

local function Players(w, guild, n, prefix)
    local list = {}
    for i = 1, n do list[i] = w:AddPlayer(guild, prefix .. i) end
    return list
end

local function Holder(w, guild, job)
    for _, c in ipairs(w:Online(guild)) do
        if c:Holding(job) then return c end
    end
end

-- Steady state: a guild and an ally, everyone logged in a while ago.
local function Settled(seed, opts)
    local w, rec = NewWorld(seed, opts)
    w:AddGuild("Alpha", "A")
    w:AddGuild("Beta", "B")
    local a = Players(w, "Alpha", 5, "Alpha")
    local b = Players(w, "Beta", 3, "Beta")
    for i, c in ipairs(a) do w:After(i * 7, function() c:Login() end) end
    for i, c in ipairs(b) do w:After(i * 9, function() c:Login() end) end
    w:Run(240)
    return w, rec, a, b
end

local S = {}

S[#S + 1] = { name = "logins one by one",
    about = "players of two guilds log in a few seconds apart: one relay per job and guild, everyone agrees",
    run = function(seed, opts)
        local w, rec = NewWorld(seed, opts)
        w:AddGuild("Alpha", "A")
        w:AddGuild("Beta", "B")
        for i, c in ipairs(Players(w, "Alpha", 6, "Alpha")) do w:After(i * 20, function() c:Login() end) end
        for i, c in ipairs(Players(w, "Beta", 3, "Beta")) do w:After(i * 31, function() c:Login() end) end
        w:Run(600)
        return Check(rec, { dual = 5, gap = 30, split = 15, hidden = 15, changes = 2 }), rec
    end }

S[#S + 1] = { name = "everyone at once",
    about = "ten players log in the same second (a server restart): exactly one relay per job",
    run = function(seed, opts)
        local w, rec = NewWorld(seed, opts)
        w:AddGuild("Alpha", "A")
        w:AddGuild("Beta", "B")
        for _, c in ipairs(Players(w, "Alpha", 10, "Alpha")) do w:After(1, function() c:Login(5) end) end
        for _, c in ipairs(Players(w, "Beta", 2, "Beta")) do w:After(1, function() c:Login(5) end) end
        w:Run(600)
        return Check(rec, { dual = 5, gap = 30, split = 15, hidden = 15, changes = 2 }), rec
    end }

S[#S + 1] = { name = "holder logs out",
    about = "the chat relay logs out the normal way: it hands over, another player takes it at once",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        h:Logout()
        w:Run(600)
        return Check(rec, { dual = 5, gap = 25, split = 15, hidden = 15, changes = 2 }), rec
    end }

S[#S + 1] = { name = "holder disconnects",
    about = "the chat relay's game closes, nothing said: the roster (or the lease) frees the job",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        h:Drop()
        w:Run(600)
        -- The roster says offline a few seconds later (then 5 s quiet: free), the lease (150 s) otherwise.
        return Check(rec, { dual = 5, gap = 45, split = 45, hidden = 45, changes = 2 }), rec
    end }

S[#S + 1] = { name = "holder fighting when someone logs in",
    about = "a guildmate logs in and asks who relays while the relay fights outdoors (no lockdown): "
        .. "the relay answers at once, nobody else takes the job",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        local late = w:AddPlayer("Alpha", "Late")
        h:Fight(40)
        w:After(2, function() late:Login(1) end)
        w:Run(600)
        -- (No holder: the first election, at the start.)
        return Check(rec, { dual = 0, gap = 25, split = 15, hidden = 15, changes = 0 }), rec
    end }

S[#S + 1] = { name = "holder in a boss fight when someone logs in",
    about = "a guildmate logs in and asks who relays while the relay is in a chat lockdown (a boss "
        .. "fight: it sends and hears nothing): the newcomer takes the job meanwhile, and one of them "
        .. "steps down once the lockdown is over",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        local late = w:AddPlayer("Alpha", "Late")
        h:Lockdown(40)
        w:After(2, function() late:Login(1) end)
        w:Run(600)
        -- Split: the guildmates follow the newcomer, then (maybe) the old relay again after the lockdown.
        return Check(rec, { dual = 5, gap = 25, split = 60, hidden = 60, changes = 2 }), rec
    end }

S[#S + 1] = { name = "better holder in a boss fight when someone logs in",
    about = "as above, but the newcomer is in a raid group (the worse relay): once the lockdown is over, "
        .. "the relay's owed beacon makes the newcomer step down at once",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        local late = w:AddPlayer("Alpha", "Late")
        -- Right after its regular beacon: the next one is a minute away.
        for _ = 1, 70 do
            if w.now - h.jobs.chat.lastBeacon < 1 then break end
            w:Run(1)
        end
        h:Lockdown(40)
        w:After(2, function()
            late:Login(1)
            late.inRaid = true
        end)
        w:Run(600)
        return Check(rec, { dual = 5, gap = 25, split = 60, hidden = 60, changes = 2 }), rec
    end }

S[#S + 1] = { name = "the relay enters an instance",
    about = "the chat relay enters a dungeon (can't relay there): it hands over, and may take it back later",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        h.inInstance = true
        w:After(300, function() h.inInstance = false end)
        w:Run(900)
        return Check(rec, { dual = 5, gap = 25, split = 15, hidden = 15, changes = 3 }), rec
    end }

S[#S + 1] = { name = "lossy channels",
    about = "10 % of all messages lost, 30 minutes: elections still end with one relay",
    run = function(seed, opts)
        opts = opts or {}
        opts.loss = 0.10
        local w, rec = NewWorld(seed, opts)
        w:AddGuild("Alpha", "A")
        w:AddGuild("Beta", "B")
        for i, c in ipairs(Players(w, "Alpha", 6, "Alpha")) do w:After(i * 5, function() c:Login() end) end
        for i, c in ipairs(Players(w, "Beta", 3, "Beta")) do w:After(i * 5, function() c:Login() end) end
        w:Run(1800)
        -- Two alliance copies in a row lost now and then: the self-check may say so, rightly.
        return Check(rec, { dual = 20, gap = 40, gapShare = 0.03, selfChecks = true }), rec
    end }

S[#S + 1] = { name = "busy evening",
    about = "three guilds, two hours: players come and go (some disconnect), fight, enter dungeons and fight bosses there (chat lockdown); 1 % loss",
    run = function(seed, opts)
        opts = opts or {}
        opts.loss = 0.01
        local w, rec = NewWorld(seed, opts)
        local sizes = { { "Alpha", 12 }, { "Beta", 6 }, { "Gamma", 3 } }
        for _, gs in ipairs(sizes) do
            w:AddGuild(gs[1], gs[1]:sub(1, 1))
            for _, c in ipairs(Players(w, gs[1], gs[2], gs[1])) do
                -- Sessions: online 20-90 min, offline 5-30 min; most log out, some disconnect.
                local function Session()
                    c:Login()
                    local function Activity()
                        if not c.online then return end
                        local roll = math.random()
                        if roll < 0.6 and c.inInstance then
                            c:Lockdown(30 + math.random(150)) -- a boss: the chat lockdown
                        elseif roll < 0.6 then
                            c:Fight(10 + math.random(50))
                        elseif roll < 0.7 then
                            c.inInstance = true
                            w:After(600 + math.random(900), function() c.inInstance = false end, c)
                        elseif roll < 0.8 then
                            c.resting = not c.resting
                        end
                        w:After(60 + math.random(240), Activity, c)
                    end
                    w:After(30 + math.random(120), Activity, c)
                    w:After(1200 + math.random(4200), function()
                        if math.random() < 0.8 then c:Logout() else c:Drop() end
                        w:After(300 + math.random(1500) + 20, Session)
                    end, c)
                end
                w:After(math.random(1800), Session)
            end
        end
        w:Run(7200)
        -- No holder: each election takes 10-20 s, and players come and go all evening.
        return Check(rec, { dual = 15, gap = 165, gapShare = 0.05 }), rec
    end }

S[#S + 1] = { name = "self-check sees a holder unseen by the allies",
    about = "the relay's alliance messages never arrive: its guildmates' self-check says so",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        h.faults.allyOutLost = true
        local lostAt = w.now
        w:Run(360)
        -- Every guildmate notices within 4 min 20 (three beacons without their alliance copy, a fourth says so).
        local fails = {}
        for _, c in ipairs(w:Online("Alpha")) do
            if c ~= h then
                local seen
                for _, e in ipairs(w.selfChecks) do
                    if e.name == c.name and e.text:find("guild channel only", 1, true) and e.at - lostAt <= 260 then seen = true end
                end
                if not seen then fails[#fails + 1] = c.name .. ": no self-check line within 260 s" end
            end
        end
        return fails, rec
    end }

S[#S + 1] = { name = "holder's alliance messages lost", known = true,
    about = "the relay's alliance channel looks fine but its messages never arrive: its guild hears it "
        .. "(guild channel), the allied guilds don't, and nobody takes over",
    run = function(seed, opts)
        local w, rec = Settled(seed, opts)
        local h = Holder(w, "Alpha", "chat")
        if not h then return { "Alpha chat: no holder after 4 minutes" }, rec end
        h.faults.allyOutLost = true
        w:Run(600)
        return Check(rec, { hidden = 160, selfChecks = true }, { Alpha = true }), rec
    end }

return S
