-- The relay simulator's world: a clock, timers, the guild and alliance channels, and players.
-- Each simulated player loads the real LaTaverne/Relay.lua in its own environment, with the game
-- API and the other La Taverne modules replaced by small fakes (below). Nothing here runs in game.
--
-- Time is simulated: World:Run(seconds) plays the timers in order, so hours take a second or two.
-- Randomness (latency, losses, the relay's own math.random) comes from one seed: a run with the
-- same seed plays the same way.
local World = {}
World.__index = World

local SERVER_BASE = 1764000000 -- GetServerTime() at the start (any date)

-- Timers: a binary heap on (at, seq).
local function HeapPush(h, e)
    h[#h + 1] = e
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        local a, b = h[p], h[i]
        if a.at < b.at or (a.at == b.at and a.seq < b.seq) then break end
        h[p], h[i] = b, a
        i = p
    end
end

local function HeapPop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            local function less(x, y) return h[x].at < h[y].at or (h[x].at == h[y].at and h[x].seq < h[y].seq) end
            if l <= #h and less(l, m) then m = l end
            if r <= #h and less(r, m) then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]
            i = m
        end
    end
    return top
end

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = DeepCopy(x) end
    return t
end

-- opts: addonDir (path to LaTaverne/), seed, latency = { min, max } seconds, loss (0..1, each
-- delivery on its own), rosterEvery (seconds between two guild roster reads).
function World.new(opts)
    local w = setmetatable({}, World)
    w.addonDir = opts.addonDir
    w.now = 1000
    w.timers, w.seq = {}, 0
    w.latency = opts.latency or { 0.05, 0.4 }
    w.loss = opts.loss or 0
    w.rosterEvery = opts.rosterEvery or 60
    w.guilds = {}      -- [name] = { name, tag, members = { [key] = client } }
    w.guildOrder = {}
    w.clients = {}     -- [key] = client (online or not)
    w.watchers = {}
    w.selfChecks = {}  -- the relay's self-check lines: { at, name, guild, text }
    w.trace = opts.trace
    math.randomseed(opts.seed or 1)
    w.relayChunk = assert(loadfile(w.addonDir .. "/Relay.lua"))
    return w
end

function World:Log(fmt, ...)
    if self.trace then print(string.format("%9.1f  " .. fmt, self.now, ...)) end
end

-- owner: a client; its timers die when it logs out (gen changes).
function World:After(delay, fn, owner)
    self.seq = self.seq + 1
    HeapPush(self.timers, { at = self.now + math.max(0, delay), seq = self.seq, fn = fn, owner = owner,
        gen = owner and owner.gen })
end

function World:Every(interval, fn, owner)
    local ticker = { cancelled = false }
    function ticker.Cancel() ticker.cancelled = true end
    local function step()
        if ticker.cancelled then return end
        fn()
        self:After(interval, step, owner)
    end
    self:After(interval, step, owner)
    return ticker
end

-- Plays the timers up to now + seconds. watch: fn(world) every simulated second (invariants).
function World:Run(seconds)
    local stop = self.now + seconds
    local nextWatch = math.floor(self.now) + 1
    while true do
        local top = self.timers[1]
        local at = top and top.at or math.huge
        if nextWatch <= stop and nextWatch <= at then
            self.now = nextWatch
            for _, fn in ipairs(self.watchers) do fn(self) end
            nextWatch = nextWatch + 1
        elseif at <= stop then
            HeapPop(self.timers)
            self.now = at
            local o = top.owner
            if not o or (o.online and o.gen == top.gen) then top.fn() end
        else
            break
        end
    end
    self.now = stop
end

function World:Watch(fn) self.watchers[#self.watchers + 1] = fn end

function World:AddGuild(name, tag)
    local g = { name = name, tag = tag, members = {}, list = {} } -- list: members in order (same seed, same run)
    self.guilds[name] = g
    self.guildOrder[#self.guildOrder + 1] = g
    return g
end

function World:Online(guild)
    local list = {}
    for _, g in ipairs(self.guildOrder) do
        if not guild or g.name == guild then
            for _, c in ipairs(g.list) do
                if c.online then list[#list + 1] = c end
            end
        end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

-- Network --------------------------------------------------------------------------------------

-- The chat lockdown (a boss fight, Client:Lockdown) blocks both ways: the game refuses what a
-- locked player sends, and a locked player gets nothing (measured in game).
function World:Deliver(from, to, fn)
    if from.locked then return end
    if to ~= from and self.loss > 0 and math.random() < self.loss then return end
    local lat = self.latency[1] + math.random() * (self.latency[2] - self.latency[1])
    self:After(lat, function()
        if to.locked then return end
        fn()
    end, to)
end

function World:SendGuild(from, msgType, payload)
    local g = self.guilds[from.guild]
    for _, c in ipairs(g.list) do
        if c.online then
            local copy = DeepCopy(payload)
            self:Deliver(from, c, function() c.ns.Comm:ReceiveGuild(from.name, msgType, copy) end)
        end
    end
end

function World:SendAlly(from, msgType, payload)
    if from.faults.allyOutLost then return end -- the game took it, nobody gets it
    for _, g in ipairs(self.guildOrder) do
        for _, c in ipairs(g.list) do
            if c.online and c.allyReady and not c.faults.allyInLost then
                local copy = DeepCopy(payload)
                self:Deliver(from, c, function() c.ns.Comm:ReceiveAlly(from.name, msgType, copy) end)
            end
        end
    end
end

-- A player ----------------------------------------------------------------------------------

local Client = {}
Client.__index = Client
World.Client = Client

local function Strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

local function Strsplit(delim, str, limit)
    local out, pos = {}, 1
    while true do
        if limit and #out == limit - 1 then break end
        local a, b = str:find(delim, pos, true)
        if not a then break end
        out[#out + 1] = str:sub(pos, a - 1)
        pos = b + 1
    end
    out[#out + 1] = str:sub(pos)
    return unpack(out)
end

-- Names a fake may leave nil (the addon checks them before use).
local MAY_BE_NIL = { issecretvalue = true }

-- A table that errors on a missing field: a fake that doesn't cover what the addon now calls
-- says so, instead of the simulation quietly going wrong.
local function Strict(name, t)
    return setmetatable(t, { __index = function(_, k)
        error("simulator: " .. name .. "." .. tostring(k) .. " has no fake (tests/sim/world.lua)", 2)
    end })
end

-- Anything goes (UI calls): every field is a function doing nothing.
local function Loose()
    return setmetatable({}, { __index = function() return function() end end })
end

function World:AddPlayer(guildName, name)
    local g = assert(self.guilds[guildName], "no guild " .. tostring(guildName))
    local c = setmetatable({ world = self, guild = guildName, name = name .. "-Realm",
        online = false, gen = 0, faults = {} }, Client)
    c.key = c.name:lower()
    g.members[c.key] = c
    g.list[#g.list + 1] = c
    self.clients[c.key] = c
    return c
end

-- Fake Comm: the two channels as Comm.lua delivers them to Relay.lua (handlers per scope; my
-- guild's messages read on the alliance channel go to the guild handlers, with via = "ally").
local OWN_GUILD_ON_ALLY = { RLY = true, RCHAT = true, CHAT = true, RMAP = true }

local function NewComm(c)
    local w = c.world
    local comm = { RELAY_PREFIX = "LaTaverneR", MAP_PREFIX = "LaTaverneM", lastSend = { parts = 0, bytes = 0 } }
    local handlers = { guild = {}, ally = {} }
    local ready = {}
    local seen = {}
    local serial = 0
    c.notes = {}

    function comm:On(t, fn) handlers.guild[t] = handlers.guild[t] or {}; table.insert(handlers.guild[t], fn) end
    function comm:OnAlly(t, fn) handlers.ally[t] = handlers.ally[t] or {}; table.insert(handlers.ally[t], fn) end
    function comm:OnReady(fn) ready[#ready + 1] = fn end
    function comm:WatchParts() end
    function comm:IsAllyReady() return c.allyReady end
    function comm:AllyLooksBroken() return c.faults.allyLooksBroken or false end
    function comm:LogNote(text, unusual)
        c.notes[#c.notes + 1] = string.format("%.1f %s%s", w.now, unusual and "!! " or "", text)
        if #c.notes > 400 then table.remove(c.notes, 1) end
        if unusual == "relay self-check" then
            w.selfChecks[#w.selfChecks + 1] = { at = w.now, name = c.name, guild = c.guild, text = text }
        end
        if w.trace then w:Log("%s: %s", c.name, text) end
    end

    function comm:Send(msgType, payload)
        payload = payload or {}
        payload.ver = "sim"
        w:SendGuild(c, msgType, payload)
        return true
    end

    function comm:SendAlly(msgType, payload)
        if not c.allyReady then return false end
        payload = payload or {}
        payload.g, payload.ver = c.guild, "sim"
        serial = serial + 1
        payload.n = math.random(1, 1000000) * 1000 + serial % 1000
        comm.lastSend = { parts = 1, bytes = 100 }
        w:SendAlly(c, msgType, payload)
        return true
    end

    local function Dispatch(scope, msgType, sender, payload, via)
        local list = handlers[scope][msgType]
        if not list then return end
        local isSelf = sender:lower() == c.key
        for _, fn in ipairs(list) do fn(sender, payload, isSelf, 1, via) end
    end

    function comm:ReceiveGuild(sender, msgType, payload)
        if not c.ns.Guild:IsMember(sender) then return end
        Dispatch("guild", msgType, sender, payload)
    end

    function comm:ReceiveAlly(sender, msgType, payload)
        if payload.g == c.guild then
            if not (OWN_GUILD_ON_ALLY[msgType] and handlers.guild[msgType]) then return end
            if not c.ns.Guild:IsMember(sender) then return end
            local id = sender .. "#" .. tostring(payload.n)
            if seen[id] and w.now - seen[id] < 120 then return end
            seen[id] = w.now
            Dispatch("guild", msgType, sender, payload, "ally")
            return
        end
        Dispatch("ally", msgType, sender, payload)
    end

    function comm:FireReady(role) for _, fn in ipairs(ready) do fn(role) end end
    return comm
end

-- The roster as this player's client last read it: La Taverne asks for it once a minute, and
-- reads it again when the game says it changed (a guildmate logs in or out: here 2-10 s later;
-- the game's real delay isn't measured).
local function ReadRoster(c)
    local g = c.world.guilds[c.guild]
    c.roster = {}
    for key, m in pairs(g.members) do c.roster[key] = { name = m.name, online = m.online } end
    c.rosterCount = 0
    for _ in pairs(c.roster) do c.rosterCount = c.rosterCount + 1 end
end

local function NewNs(c)
    local w = c.world
    local ns = {}
    local events = {}
    c.events = events
    c.printed = {}

    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    ns.version = "sim"
    ns.commands = {}
    ns.db = { relay = { help = true, told = true } }
    function ns.NewModule(name)
        local m = { name = name }
        ns[name] = m
        return m
    end
    function ns.On(event, fn) events[event] = events[event] or {}; table.insert(events[event], fn) end
    function ns.Print(text) c.printed[#c.printed + 1] = text end
    function ns.NameKey(name) return name and Strtrim(name):lower() or nil end
    function ns.FullName() return c.name end
    function ns.IsMe(name) return ns.NameKey(name) == c.key end
    function ns.IsAway() return c.away or false end
    ns.TextDialog, ns.ConfirmDialog, ns.SelectTextDialog = function() end, function() end, function() end

    ns.Comm = NewComm(c)
    ns.Guild = Strict("Guild", {
        GetName = function() return c.guild end,
        IsMyGuild = function(_, name) return type(name) == "string" and Strtrim(name):lower() == c.guild:lower() end,
        IsSandbox = function() return false end,
        Restricted = function() return false end,
        IsMember = function(_, name) return w.guilds[c.guild].members[ns.NameKey(name)] ~= nil end,
        GetMember = function(_, name) return c.roster and c.roster[ns.NameKey(name)] end,
        GetRosterCount = function() return c.rosterCount or 0 end,
    })
    local function Guilds()
        local list = {}
        for _, g in ipairs(w.guildOrder) do list[#list + 1] = { name = g.name, tag = g.tag } end
        return list
    end
    ns.Alliance = Strict("Alliance", {
        IsActive = function() return true end,
        IsInfoKnown = function() return true end,
        RelayAllows = function() return not c.officersOff end,
        GetGuilds = function() return Guilds() end,
        IsAllied = function(_, name) return w.guilds[name] ~= nil end,
        GetTag = function(_, name) return w.guilds[name] and w.guilds[name].tag end,
        GetRelayRule = function() return nil end,
        RelayLine = nil,
    })
    ns.AllyChat = Strict("AllyChat", { Enabled = function() return true end, stats = {},
        TextKey = function(text) return text end })
    ns.AllyMap = Strict("AllyMap", { stats = {}, Here = function() return nil end })
    ns.Players = Strict("Players", {
        RunsAddon = function(_, name) return w.clients[ns.NameKey(name)] ~= nil end,
        GetGuildHellos = function() return {} end,
        HellosComplete = function() return true end,
        NoteAddon = function() end,
    })
    ns.Vouch = Strict("Vouch", {
        GetPlayers = function()
            local list = {}
            for _, o in ipairs(w:Online()) do
                if o.guild ~= c.guild then list[#list + 1] = { name = o.name, guild = o.guild, online = true } end
            end
            return list
        end,
        Mark = function() return "" end,
        HelloChanged = function() end,
    })
    ns.UI = Loose()
    return ns
end

local function NewEnv(c)
    local w = c.world
    local api = {
        format = string.format, wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        strtrim = Strtrim, strsplit = Strsplit, tinsert = table.insert, tremove = table.remove,
        date = os.date, time = function() return SERVER_BASE + math.floor(w.now) end,
        GetTime = function() return w.now end,
        GetServerTime = function() return SERVER_BASE + math.floor(w.now) end,
        IsInInstance = function() return c.inInstance or false end,
        IsInRaid = function() return c.inRaid or false end,
        IsResting = function() return c.resting or false end,
        UnitAffectingCombat = function() return c.inCombat or false end,
        C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end,
            InChatMessagingLockdown = function() return c.locked or false end },
        C_Map = { GetMapInfo = function() return nil end },
        C_Timer = {
            After = function(delay, fn) w:After(delay, fn, c) end,
            NewTicker = function(interval, fn) return w:Every(interval, fn, c) end,
        },
        geterrorhandler = function() return error end,
    }
    return setmetatable({}, { __index = function(_, k)
        local v = api[k]
        if v == nil then v = _G[k] end
        if v == nil and MAY_BE_NIL[k] == nil then
            error("simulator: game global " .. tostring(k) .. " has no fake (tests/sim/world.lua)", 2)
        end
        return v
    end })
end

-- Fires a game event at this player's handlers.
function Client:Fire(event, ...)
    for _, fn in ipairs(self.events[event] or {}) do fn(...) end
end

-- Logs in: a fresh client (the addon loaded again), the roster read a few seconds later, the
-- alliance channel ready after allyDelay (default 3-8 s).
function Client:Login(allyDelay)
    local w = self.world
    assert(not self.online, self.name .. " is already online")
    self.online, self.gen = true, self.gen + 1
    self.allyReady, self.roster, self.rosterCount = false, nil, 0
    self.inCombat, self.inInstance, self.inRaid, self.away, self.locked = false, false, false, false, false
    self.ns = NewNs(self)
    local chunk = w.relayChunk
    setfenv(chunk, NewEnv(self))
    chunk("LaTaverne", self.ns)
    self.relay = self.ns.Relay
    self.jobs = self:Upvalue(self.relay.IsHolding, "jobs")
    self.relay:OnLogin()
    w:After(2 + math.random() * 3, function()
        ReadRoster(self)
        w:Every(w.rosterEvery, function() ReadRoster(self) end, self)
    end, self)
    w:After(allyDelay or (3 + math.random() * 5), function()
        self.allyReady = true
        self.ns.Comm:FireReady("ally")
    end, self)
    self:RosterChanged()
    w:Log("%s logs in (%s)", self.name, self.guild)
end

-- My guildmates' clients read the roster again a little later (GUILD_ROSTER_UPDATE).
function Client:RosterChanged()
    local w = self.world
    for _, c in ipairs(w.guilds[self.guild].list) do
        if c ~= self and c.online then w:After(2 + math.random() * 8, function() ReadRoster(c) end, c) end
    end
end

-- Logs out the normal way: the countdown (handed over first), then gone.
function Client:Logout()
    self:Fire("PLAYER_CAMPING")
    self.world:After(20, function() self:Drop() end, self)
end

-- Gone at once, nothing said (game closed, disconnected).
function Client:Drop()
    self.online, self.allyReady = false, false
    self.gen = self.gen + 1
    self:RosterChanged()
    self.world:Log("%s is gone", self.name)
end

function Client:Fight(seconds)
    self.inCombat = true
    self.world:Log("%s fights for %d s", self.name, seconds)
    self:Fire("PLAYER_REGEN_DISABLED")
    local gen = self.gen
    self.world:After(seconds, function()
        if self.gen ~= gen then return end
        self.inCombat = false
        self:Fire("PLAYER_REGEN_ENABLED")
    end, self)
end

-- A boss fight: a fight with the game's chat lockdown on for all of it (Deliver).
function Client:Lockdown(seconds)
    self.locked = true
    self.world:Log("%s: chat lockdown for %d s", self.name, seconds)
    self:Fight(seconds)
    local gen = self.gen
    self.world:After(seconds, function()
        if self.gen ~= gen then return end
        self.locked = false
    end, self)
end

-- A local of Relay.lua, read through one of its functions (the simulator only reads it).
function Client:Upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then error("simulator: no upvalue " .. name) end
        if n == name then return v end
        i = i + 1
    end
end

-- This player's view of a job: "me" while holding it, else the holder's key, or nil.
function Client:View(job)
    local st = self.jobs[job]
    if st.holding then return self.key end
    if st.holder and not st.free then return st.holder.name:lower() end
    return nil
end

function Client:Holding(job) return self.online and self.jobs[job].holding or false end

-- Could this player do the job right now (Relay's own tier)?
function Client:CanRelay(job)
    return self.online and self.allyReady and self.relay:Tier(job) ~= nil
end

return World
