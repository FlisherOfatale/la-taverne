-- Players: who can I ask?
--
-- "I'm available": a solo player says they want a group, with the roles ticked in the roles
-- bar, for any dungeon at their level or chosen dungeons, and a short note. It lasts a chosen
-- time (15 min to 2 h, or until logout); 5 minutes before the end a popup offers to extend
-- it. It stops when joining a party, posting a group, accepting an invitation, or logging out.
-- AFK players stay listed but marked (the time keeps running); in a dungeon it's paused.
-- Shared with the guild and the allied guilds (allied guilds count as the guild).
--
-- Presence: who in the guild runs La Taverne. The Players page asks ("WHO"), clients answer
-- ("HERE") after a short random delay; any guild message counts too.
--
-- Messages:
--   AVAIL      player -> all   I'm available: roles, dungeons (nil = any at my level), note, afk
--   AVAIL_OFF  player -> all   not available anymore (or paused)
--   WHO        anyone -> guild who runs La Taverne? (Players page open)
--   HERE       player -> guild me, with class and level
local ADDON, ns = ...
local Players = ns.NewModule("Players")
local L = ns.L

local HEARTBEAT = 60
local EXPIRE = 150           -- someone else's availability without heartbeat for this long is gone
local WARN_BEFORE = 300      -- popup this long before the end
local PRESENCE_AGE = 20 * 60 -- "has La Taverne": heard from in the last 20 minutes
local WHO_WAIT = 20           -- after asking who's there: online members who didn't answer
local WHO_EVERY = 60          -- nobody asks again this soon after a question (anyone's)
local WHO_SPREAD_MIN, WHO_SPREAD_MAX = 1, 10 -- answers come this many seconds after a question
local NOTE_MAX = 80

Players.DURATIONS = { 900, 1800, 3600, 7200, 0 } -- 0: until I log out
Players.DEFAULT_DURATION = 3600

local available = {} -- others: [key] = { name, class, level, roles, dungeons, note, afk, seen, scope, tag }
local present = {}   -- others running La Taverne: [key] = { name, class, level, seen }
local state = { active = false, expires = nil, warned = false, paused = false, sent = false }
local callbacks = {}

function Players:OnChange(fn) callbacks[#callbacks + 1] = fn end
local function Changed()
    for _, fn in ipairs(callbacks) do fn() end
end

-- My settings, per character: { duration, dungeons = { [key] = true } (empty: any), note }
local function Settings()
    local key = ns.FullName("player")
    ns.db.chars[key] = ns.db.chars[key] or {}
    local db = ns.db.chars[key]
    db.avail = db.avail or {}
    db.avail.dungeons = db.avail.dungeons or {}
    if db.avail.duration == nil then db.avail.duration = Players.DEFAULT_DURATION end
    return db.avail
end
Players.Settings = Settings

function Players.DurationText(seconds)
    if not seconds or seconds == 0 then return L["Until I log out"] end
    if seconds >= 3600 then return format(L["%d h"], seconds / 3600) end
    return format(L["%d min"], seconds / 60)
end

-- Scopes, like the group finder ---------------------------------------------------------------

local function OnBoth(msgType, fn)
    ns.Comm:On(msgType, function(sender, p, isSelf) fn(sender, p, isSelf, "guild") end)
    ns.Comm:OnAlly(msgType, function(sender, p, isSelf) fn(sender, p, isSelf, "ally") end)
end

local function Shared()
    return ns.Alliance:IsActive()
end

-- My availability ------------------------------------------------------------------------------

local function InDungeon()
    if not IsInInstance then return false end
    local inside, kind = IsInInstance()
    return inside and (kind == "party" or kind == "raid") or false
end

function Players:IsActive()
    return state.active
end

function Players:IsPaused()
    return state.active and state.paused
end

-- Seconds left, or nil (until logout / not active).
function Players:Remaining()
    if not state.active or not state.expires then return nil end
    return math.max(0, state.expires - GetServerTime())
end

-- Does my availability want this dungeon? (Not available, or any dungeon: yes.)
function Players:WantsDungeon(key)
    if not state.active then return true end
    local dungeons = Settings().dungeons
    return not next(dungeons) or dungeons[key] == true
end

local function MyPayload()
    local s = Settings()
    local _, class = UnitClass("player")
    local dungeons
    if next(s.dungeons) then
        dungeons = {}
        for key in pairs(s.dungeons) do dungeons[#dungeons + 1] = key end
    end
    return {
        roles = ns.Groups.RoleList(ns.Groups:GetMyRoles()), dungeons = dungeons,
        note = s.note ~= "" and s.note or nil, afk = UnitIsAFK and UnitIsAFK("player") or nil,
        class = class, level = UnitLevel("player"), vis = Shared() and "ally" or nil,
    }
end

local function SendOff(alsoAlly)
    ns.Comm:Send("AVAIL_OFF", {})
    if alsoAlly and ns.Alliance:IsActive() then ns.Comm:SendAlly("AVAIL_OFF", {}) end
end

local broadcastPending = false
function Players:Broadcast()
    if broadcastPending then return end
    broadcastPending = true
    C_Timer.After(1, function()
        broadcastPending = false
        if not state.active then return end
        local wasPaused = state.paused
        state.paused = InDungeon()
        if wasPaused ~= state.paused then Changed() end

        if state.paused then
            if state.sent then SendOff(state.sentAlly) state.sent = false end
            return
        end
        ns.Comm:Send("AVAIL", MyPayload())
        -- Allied guilds: when shared, and once more after unsharing (with vis = nil they drop it).
        if ns.Alliance:IsActive() and (Shared() or state.sentAlly) then
            ns.Comm:SendAlly("AVAIL", MyPayload())
            state.sentAlly = Shared()
        end
        state.sent = true
    end)
end

-- Start. Returns ok, error text.
function Players:Start()
    if ns.InParty() then return false, L["You're in a party: post a group for your party instead."] end
    if not next(ns.Groups:GetMyRoles()) then return false, L["Tick at least one role you can play first."] end
    local duration = Settings().duration or Players.DEFAULT_DURATION
    state.active = true
    state.expires = duration > 0 and (GetServerTime() + duration) or nil
    state.warned = false
    self:Broadcast()
    ns.Print(format(L["You're available (%s). Leaders looking for players see you."], Players.DurationText(duration)))
    Changed()
    return true
end

-- Stop. reason: a chat line to show, or nil.
function Players:Stop(reason)
    if not state.active then return end
    state.active, state.expires, state.warned, state.paused = false, nil, false, false
    SendOff(true)
    state.sent, state.sentAlly = false, false
    if Players.HidePopup then Players.HidePopup() end
    if reason then ns.Print(reason) end
    Changed()
end

-- Extend from now, for a new duration (also remembered as my choice).
function Players:Extend(duration)
    Settings().duration = duration
    if not state.active then return end
    state.expires = duration > 0 and (GetServerTime() + duration) or nil
    state.warned = false
    if Players.HidePopup then Players.HidePopup() end
    self:Broadcast()
    Changed()
end

-- Test: bring the end close so the expiry popup shows within a few seconds.
function Players:DevExpireSoon()
    if not state.active then return false end
    state.expires = GetServerTime() + WARN_BEFORE
    state.warned = false
    Changed()
    return true
end

-- From the availability dialog: roles (the roles bar's), dungeons, duration and note in one go,
-- then start (start = true), or update a running availability. Returns ok, error text.
-- d = { roles = { [role] = true }, dungeons = { [key] = true } (empty: any), duration, note }
function Players:Apply(d, start)
    for _, role in ipairs(ns.Groups.ROLES) do ns.Groups:SetMyRole(role, d.roles[role] == true) end
    local s = Settings()
    wipe(s.dungeons)
    for key in pairs(d.dungeons) do s.dungeons[key] = true end
    s.note = strtrim(d.note or ""):sub(1, NOTE_MAX)
    if start then
        s.duration = d.duration
        return self:Start()
    end
    -- A new length counts from now; the same length keeps the current end.
    if d.duration ~= s.duration then self:Extend(d.duration) end
    self:SettingsChanged()
    return true
end

-- Settings changed while available: tell everyone.
function Players:SettingsChanged()
    if state.active then self:Broadcast() end
    Changed()
end

function Players:SetNote(note)
    Settings().note = strtrim(note or ""):sub(1, NOTE_MAX)
    self:SettingsChanged()
end

function Players:SetDungeon(key, on)
    Settings().dungeons[key] = on and true or nil
    self:SettingsChanged()
end

function Players:SetAnyDungeon()
    wipe(Settings().dungeons)
    self:SettingsChanged()
end

-- Other players --------------------------------------------------------------------------------

local function DungeonFits(a, key)
    if a.dungeons then return a.dungeons[key] == true end
    local kind = ns.DungeonDifficulty(ns.DungeonByKey(key), a.level)
    return kind ~= "impossible" and kind ~= "trivial"
end
Players.DungeonFits = DungeonFits

-- Would an available player fit? A role still missing ({ [role] = n }), and the dungeon is one
-- they want (or at their level).
function Players:FitsNeed(a, dungeon, missing)
    local roleOk = false
    for role in pairs(a.roles or {}) do
        if (missing[role] or 0) > 0 then roleOk = true break end
    end
    return roleOk and DungeonFits(a, dungeon)
end

-- Does an available player fit a group? A role it misses, and a dungeon they want (or at their level).
function Players:FitsGroup(a, l)
    if not l or not ns.Groups:IsOpen(l) then return false end
    return self:FitsNeed(a, l.dungeon, ns.Groups:MissingRoles(l))
end

-- Available players (not AFK) who'd fit a group being made: the create form's hint.
function Players:GetFittingFor(dungeon, missing)
    local out = {}
    if not dungeon then return out end
    for _, a in pairs(available) do
        if not a.afk and self:FitsNeed(a, dungeon, missing) then out[#out + 1] = a end
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    return out
end

-- Available players (not me), AFK last.
function Players:GetAvailable()
    local out = {}
    for _, a in pairs(available) do out[#out + 1] = a end
    table.sort(out, function(a, b)
        if (a.afk or false) ~= (b.afk or false) then return not a.afk end
        return a.name < b.name
    end)
    return out
end

function Players:CountAvailable()
    local n = 0
    for _ in pairs(available) do n = n + 1 end
    return n
end

-- Available players who fit my open group.
function Players:CountFitting()
    local mine = ns.Groups:GetMine()
    if not mine then return 0 end
    local n = 0
    for _, a in pairs(available) do
        if not a.afk and self:FitsGroup(a, mine) then n = n + 1 end
    end
    return n
end

-- Wanted dungeons: { { dungeon, TANK = n, HEALER = n, DAMAGER = n, total } }, most wanted first,
-- plus how many are available for any dungeon at their level. Roles: each player counts once
-- per role they offer.
function Players:GetDemand()
    local byKey, anyCount = {}, 0
    for _, a in pairs(available) do
        if not a.afk then
            if a.dungeons then
                for key in pairs(a.dungeons) do
                    local d = byKey[key] or { dungeon = key, total = 0 }
                    byKey[key] = d
                    d.total = d.total + 1
                    for role in pairs(a.roles or {}) do d[role] = (d[role] or 0) + 1 end
                end
            else
                anyCount = anyCount + 1
            end
        end
    end
    local list = {}
    for _, d in pairs(byKey) do list[#list + 1] = d end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return ns.DungeonName(a.dungeon) < ns.DungeonName(b.dungeon)
    end)
    return list, anyCount
end

-- Online guild members, each with: tier "available" | "addon" | "none", and the available entry.
-- Allied available players are added too (tier "available").
function Players:GetOnline()
    local out, seen = {}, {}
    local now = GetServerTime()
    for _, m in ipairs(ns.Guild:GetOnline()) do
        local key = ns.NameKey(m.name)
        if not ns.IsMe(m.name) then
            seen[key] = true
            local a = available[key]
            local p = present[key]
            local tier = a and "available" or ((p and now - p.seen < PRESENCE_AGE) and "addon" or "none")
            out[#out + 1] = { key = key, name = m.name, class = m.class or (p and p.class), level = m.level or (p and p.level),
                tier = tier, avail = a }
        end
    end
    for key, a in pairs(available) do
        if not seen[key] then
            out[#out + 1] = { key = key, name = a.name, class = a.class, level = a.level, tier = "available", avail = a, tag = a.tag }
        end
    end
    local order = { available = 1, addon = 2, none = 3 }
    table.sort(out, function(a, b)
        local oa = order[a.tier] + ((a.avail and a.avail.afk) and 0.5 or 0)
        local ob = order[b.tier] + ((b.avail and b.avail.afk) and 0.5 or 0)
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)
    return out
end

-- Any guild message from a player: they run La Taverne.
-- Guild members seen with La Taverne, saved so the Alliance page lists them while they're
-- offline too. Per guild of mine (test guilds apart): [nameKey] = { name, class, level, seen }.
local function Memory() return ns.SeenMemory("guildSeen") end

function Players:NoteAddon(name, class, level)
    if not name or ns.IsMe(name) then return end
    local key = ns.NameKey(name)
    local p = present[key] or { name = name }
    present[key] = p
    p.seen = GetServerTime()
    if type(class) == "string" then p.class = class end
    if tonumber(level) then p.level = tonumber(level) end
    local memory = Memory()
    if memory then
        local item = memory[key]
        if item then
            item.name, item.class, item.level, item.seen = name, p.class, p.level, p.seen
            item.missed = nil
        else
            memory[key] = { name = name, class = p.class, level = p.level, seen = p.seen }
        end
    end
end

-- After asking who's there: forget the remembered members who left the guild, and the ones
-- online when asked and still online (the roster says so) who didn't answer: they don't run
-- La Taverne any more. onlineThen: who was online when the question went out (someone who
-- logged in after it never heard it). Silent twice in a row, not once: a busy guild can hold an
-- answer back past the wait.
local function ForgetSilent(asked, onlineThen)
    local memory = Memory()
    if not memory or ns.Guild:GetRosterCount() == 0 then return end
    local changed = false
    for key, item in pairs(memory) do
        local member = ns.Guild:GetMember(item.name)
        if not member then
            memory[key] = nil
            changed = true
        elseif member.online and onlineThen[key] and (item.seen or 0) < asked then
            item.missed = (item.missed or 0) + 1
            ns.Comm:LogNote(format("who's there: no answer from %s (%d in a row)", item.name, item.missed),
                item.missed >= 2 and "guildmate forgotten" or nil)
            if item.missed >= 2 then
                memory[key] = nil
                changed = true
            end
        end
    end
    if changed then Changed() end
end

-- The last question, mine or someone else's: everyone hears the answers, so nobody asks again
-- for a minute (a big guild answers each question with one message per player).
local lastWho = 0
local function WatchAnswers()
    lastWho = GetTime()
    local asked = GetServerTime()
    local onlineThen = {}
    for _, m in ipairs(ns.Guild:GetOnline()) do onlineThen[ns.NameKey(m.name)] = true end
    C_Timer.After(WHO_WAIT, function() ForgetSilent(asked, onlineThen) end)
end

function Players:AskWho()
    if GetTime() - lastWho < WHO_EVERY then return end
    -- The sweep counts on the answers: only when the question went out now (not just queued).
    if not ns.Comm:Send("WHO", {}) then
        lastWho = GetTime()
        return
    end
    WatchAnswers()
end

-- Guild members with La Taverne, online first then most recent: { name, class, level, seen,
-- online }. Online: in the roster as online and heard from lately.
function Players:GetGuildAddonUsers()
    local out, now = {}, GetServerTime()
    local memory = Memory() or {}
    -- Heard from before my guild's name was known (just after login): not saved yet.
    for key, p in pairs(present) do
        if not memory[key] and ns.Guild:IsMember(p.name) then
            local member = ns.Guild:GetMember(p.name)
            out[#out + 1] = { name = p.name, class = member.class or p.class, level = member.level or p.level,
                seen = p.seen, online = member.online and now - p.seen < PRESENCE_AGE or false }
        end
    end
    for key, item in pairs(memory) do
        local member = ns.Guild:GetMember(item.name)
        if member then
            local p = present[key]
            local seen = math.max(item.seen or 0, p and p.seen or 0)
            out[#out + 1] = { name = item.name, class = member.class or item.class, level = member.level or item.level,
                seen = seen, online = member.online and now - seen < PRESENCE_AGE or false }
        end
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return (a.seen or 0) > (b.seen or 0)
    end)
    return out
end

-- Messages ------------------------------------------------------------------------------------

OnBoth("AVAIL", function(sender, p, isSelf, scope)
    if isSelf then return end
    local key = ns.NameKey(sender)
    -- Allied: only when shared with the allied guilds.
    if scope == "ally" and p.vis ~= "ally" then
        if available[key] and available[key].scope == "ally" then
            available[key] = nil
            Changed()
        end
        return
    end
    local roles = ns.Groups.RoleSet(p.roles)
    if not roles then return end
    local dungeons
    if type(p.dungeons) == "table" then
        for _, k in ipairs(p.dungeons) do
            if type(k) == "string" and ns.DungeonByKey(k) then
                dungeons = dungeons or {}
                dungeons[k] = true
            end
        end
    end
    local previous = available[key]
    local a = {
        key = key, name = sender, class = type(p.class) == "string" and p.class or nil,
        level = tonumber(p.level), roles = roles, dungeons = dungeons,
        note = type(p.note) == "string" and p.note:sub(1, NOTE_MAX) or nil,
        afk = p.afk and true or nil, seen = GetServerTime(), scope = scope,
        tag = scope == "ally" and ns.Alliance:GetTag(p.g) or nil,
        unverified = scope == "ally" and ns.Vouch and ns.Vouch:GetState(sender) == "unverified" or nil,
    }
    available[key] = a
    if scope == "guild" then Players:NoteAddon(sender, a.class, a.level) end
    -- A leader with an open group hears about a player who just became available and fits.
    local mine = ns.Groups:GetMine()
    if not previous and not a.afk and mine and Players:FitsGroup(a, mine) then
        ns.Print(format(L["%s is available and fits your group (%s). Invite them from the Availability page."],
            sender .. (a.tag and (" [" .. a.tag .. "]") or ""), ns.DungeonName(mine.dungeon)))
    end
    Changed()
end)

OnBoth("AVAIL_OFF", function(sender, _, isSelf)
    if isSelf then return end
    local key = ns.NameKey(sender)
    if available[key] then
        available[key] = nil
        Changed()
    end
end)

ns.Comm:On("WHO", function(_, _, isSelf)
    if isSelf then return end
    -- Someone else asked: I hear the answers too.
    if GetTime() - lastWho >= WHO_EVERY then WatchAnswers() end
    -- Spread out, so a big guild's answers don't all arrive in the same second.
    C_Timer.After(WHO_SPREAD_MIN + math.random() * (WHO_SPREAD_MAX - WHO_SPREAD_MIN), function()
        local _, class = UnitClass("player")
        ns.Comm:Send("HERE", { class = class, level = UnitLevel("player") })
    end)
end)

ns.Comm:On("HERE", function(sender, p, isSelf)
    if isSelf then return end
    Players:NoteAddon(sender, p.class, p.level)
    Changed()
end)

-- Expiry popup ---------------------------------------------------------------------------------
-- A confirmation window at the top of the screen like a ready check (ns.ConfirmDialog, not the
-- game's dialog): "+15 min", "+1 h" (the length I chose last comes first) and "Stop". The time
-- left updates while it's open. Escape or doing nothing: it ends at the set time, and the chat
-- line offers to start again.

-- Add time to my availability (from its current end), and remember it as my usual length.
function Players:AddTime(seconds)
    if not state.active or not state.expires then return end
    Settings().duration = seconds
    state.expires = math.max(state.expires, GetServerTime()) + seconds
    state.warned = false
    self:Broadcast()
    Changed()
end

local function PopupText()
    local left = Players:Remaining() or 0
    return format(L["You're still available for %d min (until %s)."], math.max(1, math.ceil(left / 60)),
        date("%H:%M", state.expires or GetServerTime()))
end

local function ShowPopup()
    -- The length I chose last comes first.
    local last = Settings().duration
    local choices = (last == 3600 or last == 7200) and { 3600, 900 } or { 900, 3600 }
    ns.ConfirmDialog({
        kind = "avail",
        -- Only a click on a button adds time or stops: never Escape or the X.
        text = function() if state.active then return PopupText() end end,
        buttons = {
            { text = "+" .. Players.DurationText(choices[1]), onClick = function() Players:AddTime(choices[1]) end },
            { text = "+" .. Players.DurationText(choices[2]), onClick = function() Players:AddTime(choices[2]) end },
            { text = L["Stop"], onClick = function() Players:Stop(L["You're no longer available."]) end },
        },
    })
end

Players.HidePopup = function()
    ns.CloseConfirmDialog("avail")
end

-- Timers and events ------------------------------------------------------------------------------

local function Tick()
    local now = GetServerTime()
    -- Others: gone without heartbeat.
    local removed = false
    for key, a in pairs(available) do
        if now - a.seen > EXPIRE then
            available[key] = nil
            removed = true
        end
    end
    if removed then Changed() end
    -- Mine: warning, then the end.
    if state.active and state.expires then
        local left = state.expires - now
        if left <= 0 then
            -- The time ran out: a link in the chat line starts again with the same settings.
            Players:Stop(L["You're no longer available."]
                .. " |Haddon:LaTaverne:avail:start|h|cff71d5ff[" .. L["I'm available..."] .. "]|r|h")
        elseif left <= WARN_BEFORE and not state.warned then
            state.warned = true
            ShowPopup()
            ns.Sound("notice")
        end
    end
end

function Players:OnLogin()
    ns.PruneSeen("guildSeen")
    C_Timer.NewTicker(5, Tick)
    C_Timer.NewTicker(HEARTBEAT, function() if state.active then Players:Broadcast() end end)
    -- Joining any party ends it: in a party, post a group for the party instead.
    ns.On("GROUP_ROSTER_UPDATE", function()
        if state.active and ns.InParty() then
            Players:Stop(L["You joined a party: you're no longer available."])
        end
    end)
    -- AFK shows on my entry (the time keeps running).
    ns.On("PLAYER_FLAGS_CHANGED", function(unit)
        if unit == "player" and state.active then Players:Broadcast() end
    end)
    -- In a dungeon: paused (hidden), back when leaving.
    ns.On("PLAYER_ENTERING_WORLD", function()
        if state.active then Players:Broadcast() Changed() end
    end)
end
