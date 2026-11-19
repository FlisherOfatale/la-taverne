-- Group listings.
--
-- A listing describes a group being formed:
--   size, composition   5 players (default 1 tank, 1 healer, 3 DPS) or 10 players (default 2/2/6). The leader
--                       can change the mix (none of a role is fine). Fewer players than the size is fine.
--                       Debug mode also has a 2-player test dungeon (any role can be 0).
--   newbies, discord, discordChannel   "new players welcome", "Discord required" (and which channel)
--   started, reopened   the group became complete (in progress: no more requests). If someone leaves
--                       mid-run, the leader can look for players again: "already started".
--   members   mirror the leader's real party/raid (kept in sync on every roster change), each with a role.
--             Players who joined from outside the addon show up too; non-guild players are marked as guests.
--   pending   players who are not in the group yet:
--               "request"   asked to join through the addon, waiting for the leader (private to the leader)
--               "invited"   the leader invited them through the addon, waiting for their answer
--               "accepted"  agreed on both sides, waiting for them to join the group
-- Missing roles = composition minus members and accepted pending players with that role.
--
-- Messages (all broadcast through ns.Comm, which only accepts guild members):
--   LIST          leader  -> all   listing created or updated, repeated every minute as a heartbeat
--   DELIST        leader  -> all   listing removed
--   SYNC_REQ      anyone  -> all   "I just logged in": leaders answer with LIST
--   APPLY         player  -> all   request to join with the roles they offer (the leader picks one)
--                                  and whether they're a new player, addressed to the leader
--   APPLY_CANCEL  player  -> all   request withdrawn
--   DECIDE        leader  -> all   request accepted or declined, addressed to the player
--   INVITE_REPLY  invitee -> all   invitation accepted (with a role) or declined, addressed to the leader
--   ROLE_CHANGE   member  -> all   a member changes their own role, addressed to the leader
--
-- Guild Alliance (0.14): the same messages also travel on the alliance channel ("ally" scope).
--   Allied guilds count as the guild: every group goes on both (vis = "ally").
--   Players answer on the scope the listing came from; the leader answers allied players on
--   the alliance channel. Allied senders are checked by vouching (Vouch.lua) before we see them.
--   Members and pending players carry their allied guild's tag ("tag").
local ADDON, ns = ...
local Groups = ns.NewModule("Groups")
local L = ns.L

local HEARTBEAT = 60         -- leader re-sends the listing this often
local EXPIRE = 150           -- a listing without heartbeat for this long is gone (leader offline)
local MAX_AGE = 2 * 60 * 60  -- groups still forming close after 2 hours (in progress: as long as the party)
local REQUEST_TTL = 10 * 60  -- a join request nobody answered expires after 10 minutes
local MAX_SIZE = 10
local NOTE_MAX = 250
local CHANNEL_MAX = 40

Groups.ROLES = { "TANK", "HEALER", "DAMAGER" }
Groups.NOTE_MAX = NOTE_MAX
Groups.DEFAULT_COMPOSITION = {
    [2] = { TANK = 0, HEALER = 1, DAMAGER = 1 }, -- debug mode test dungeon
    [5] = { TANK = 1, HEALER = 1, DAMAGER = 3 },
    [10] = { TANK = 2, HEALER = 2, DAMAGER = 6 },
}
local ROLE_SET = { TANK = true, HEALER = true, DAMAGER = true }
local PENDING_STATUS = { request = true, invited = true, accepted = true }

local listings = {}        -- other leaders' listings: [id] = listing
local myApplications = {}  -- requests I sent: [id] = { role, status = "pending" | "accepted" | "declined" }
-- A request carries what was sent (payload), when (sent), how often (tries), and acked once the
-- leader's addon said it got it. The leader may be offline when I ask: an unacked request is sent
-- again when their group shows up again (their heartbeat), so it isn't lost.
local myInviteReplies = {} -- invitations I answered: [id] = "accepted" | "declined"
local seenInvitations = {} -- invitations I saw on the Invitations page: [id] = true
local seenRequests = {}    -- join requests to my group I saw on My group: [name key] = true
local callbacks = {}

function Groups:OnChange(fn)
    callbacks[#callbacks + 1] = fn
end

local function Changed()
    for _, fn in ipairs(callbacks) do fn() end
end

local function ValidRole(role)
    return ROLE_SET[role] and role or nil
end

-- Scopes ------------------------------------------------------------------------------

local function SendTo(scope, msgType, payload)
    if scope == "ally" then return ns.Comm:SendAlly(msgType, payload) end
    return ns.Comm:Send(msgType, payload)
end

-- Same handler for both scopes: fn(sender, payload, isSelf, scope).
local function OnBoth(msgType, fn)
    ns.Comm:On(msgType, function(sender, p, isSelf) fn(sender, p, isSelf, "guild") end)
    ns.Comm:OnAlly(msgType, function(sender, p, isSelf) fn(sender, p, isSelf, "ally") end)
end

-- Where to reach a player: my guild, or the alliance channel.
local function ScopeOf(name)
    return ns.Guild:IsMember(name) and "guild" or "ally"
end

-- The allied guild tag of a player who isn't in my guild (guild: what the game says, if known).
local function TagFor(name, guild)
    if not name or ns.Guild:IsMember(name) then return nil end
    if guild and ns.Alliance:IsAllied(guild) then return ns.Alliance:GetTag(guild) end
    local claimed = ns.Vouch and ns.Vouch:GetGuild(name)
    return claimed and ns.Alliance:GetTag(claimed) or nil
end
Groups.TagFor = TagFor

local function CleanTag(tag)
    return type(tag) == "string" and tag ~= "" and tag:gsub("[|%s]", ""):sub(1, 6) or nil
end

local function ValidSize(size)
    if size == 10 or size == 2 then return size end
    return 5
end

-- Roles a player offers: a set { TANK = true, ... } from a set or a list, unknown roles dropped.
local function RoleSet(value)
    local out, any = {}, false
    if type(value) == "table" then
        for k, v in pairs(value) do
            local role = (type(k) == "string" and v == true) and k or v
            if ROLE_SET[role] then out[role] = true any = true end
        end
    end
    return any and out or nil
end
Groups.RoleSet = RoleSet

local function RoleList(set)
    local out = {}
    for _, role in ipairs(Groups.ROLES) do
        if set and set[role] then out[#out + 1] = role end
    end
    return out
end
Groups.RoleList = RoleList

-- Smallest number of spots a role can have: none (a leader can post "no healer, 4 DPS").
function Groups:MinPerRole()
    return 0
end

-- A composition is valid when every role has its minimum and the total equals the size.
function Groups:ValidComposition(size, composition)
    size = ValidSize(size)
    if type(composition) ~= "table" then return CopyTable(self.DEFAULT_COMPOSITION[size]) end
    local out, total = {}, 0
    local min = self:MinPerRole(size)
    for _, role in ipairs(self.ROLES) do
        local n = math.floor(tonumber(composition[role]) or 0)
        if n < min then return CopyTable(self.DEFAULT_COMPOSITION[size]) end
        out[role] = n
        total = total + n
    end
    if total ~= size then return CopyTable(self.DEFAULT_COMPOSITION[size]) end
    return out
end

function Groups:GetSize(listing)
    return ValidSize(listing.size)
end

function Groups:GetComposition(listing)
    return listing.composition or self.DEFAULT_COMPOSITION[self:GetSize(listing)]
end

-- My own listing is saved per character, so it survives /reload and relog.
local function CharDB()
    local key = ns.FullName("player")
    ns.db.chars[key] = ns.db.chars[key] or {}
    return ns.db.chars[key]
end

local function MyKey()
    return ns.NameKey(ns.FullName("player"))
end

-- The role I took in the last group I posted (per character): the create form starts with it.
function Groups:GetLastRole()
    return CharDB().lastRole
end

function Groups:SetLastRole(role)
    CharDB().lastRole = role
end

function Groups:GetMine()
    return CharDB().listing
end

-- What I offer when joining a group, chosen at the top of the group list (per character):
-- my roles, and whether I'm a new player.
function Groups:GetMyRoles()
    local db = CharDB()
    local _, class = UnitClass("player")
    if not db.myRoles then
        -- First time: a class with a single role offers it right away.
        local possible = {}
        for _, role in ipairs(self.ROLES) do
            if ns.CanTakeRole(class, role) then possible[#possible + 1] = role end
        end
        db.myRoles = {}
        if #possible == 1 then db.myRoles[possible[1]] = true end
    end
    local out = {}
    for role in pairs(db.myRoles) do
        if ROLE_SET[role] and ns.CanTakeRole(class, role) then out[role] = true end
    end
    return out
end

function Groups:SetMyRole(role, on)
    self:GetMyRoles()
    CharDB().myRoles[role] = on and true or nil
    Changed()
end

-- Group list filters, per character. All off by default: everything shows.
function Groups:GetFilters()
    local db = CharDB()
    db.filters = db.filters or {}
    db.filters.dungeons = db.filters.dungeons or {}
    db.filters.myGuild = nil -- filter removed in 0.23
    return db.filters
end

-- How many filters are on ("Hide groups in progress" counts as one).
function Groups:CountFilters()
    local f = self:GetFilters()
    local n = (next(f.dungeons) and 1 or 0) + (f.role and 1 or 0) + (f.level and 1 or 0)
    return n + (ns.db.hideRunning and 1 or 0)
end

function Groups:ClearFilters()
    local f = self:GetFilters()
    wipe(f.dungeons)
    f.role, f.level = nil, nil
    ns.db.hideRunning = false
    Changed()
end

function Groups:SetFilter(name, on)
    self:GetFilters()[name] = on and true or nil
    Changed()
end

function Groups:SetDungeonFilter(key, on)
    self:GetFilters().dungeons[key] = on and true or nil
    Changed()
end

-- Does a group pass my filters? ("In progress" is handled by the list itself.)
function Groups:PassesFilters(l)
    local f = self:GetFilters()
    if next(f.dungeons) and not f.dungeons[l.dungeon] then return false end
    if f.role and not self:NeedsMyRole(l) then return false end
    if f.level and not self:AtMyLevel(l) then return false end

    return true
end

function Groups:IsNewPlayer()

    return CharDB().newbie == true
end

function Groups:SetNewPlayer(on)
    CharDB().newbie = on and true or nil
    Changed()
end

function Groups:IsMine(listing)
    local mine = self:GetMine()
    return mine ~= nil and listing.id == mine.id
end

function Groups:GetApplication(id)
    return myApplications[id]
end

-- The leader of someone else's group looks offline: the guild roster says so, or their group
-- missed its last heartbeat.
function Groups:IsLeaderAway(l)
    if not l or self:IsMine(l) then return false end
    local member = ns.Guild:GetMember(l.leader)
    if member and member.online == false then return true end
    return GetServerTime() - (l.seen or 0) > HEARTBEAT + 20
end

-- Someone else's listing I'm a member of (I'm in their group).
function Groups:GetJoined()
    local key = MyKey()
    for _, l in pairs(listings) do
        if l.members[key] then return l end
    end
    return nil
end

-- The real party ------------------------------------------------------------------------

-- Everyone in my party or raid, me included: [key] = { name, class, level, assignedRole }
local function CurrentParty()
    local out = {}
    local function add(unit)
        if not UnitExists(unit) then return end
        local name = ns.FullName(unit)
        if not name or name == UNKNOWNOBJECT then return end -- name not loaded yet, next update fixes it
        local _, class = UnitClass(unit)
        local assigned = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
        -- The game's guild for players around (not the test guilds in debug mode).
        local guild = not ns.Guild:IsSandbox() and GetGuildInfo(unit) or nil
        out[ns.NameKey(name)] = { name = name, class = class, level = UnitLevel(unit), assignedRole = ValidRole(assigned),
            guild = guild }
    end
    add("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i) end
    else
        for i = 1, 4 do add("party" .. i) end
    end
    return out
end
Groups.CurrentParty = CurrentParty

-- Party invite; a 10-player group turns the party into a raid when the party is full.
-- Only the party leader can invite (see "Party lead" below).
local function InvitePlayer(listing, name)
    if not Groups:IsLeading() then
        ns.Print(format(L["Can't invite %s: you're not the party leader any more."], name))
        return
    end
    if Groups:GetSize(listing) > 5 and not IsInRaid() and GetNumGroupMembers() >= 5
        and C_PartyInfo and C_PartyInfo.ConvertToRaid then
        -- The party becomes a raid a moment later: invite once it has (up to 5 s).
        C_PartyInfo.ConvertToRaid()
        local tries = 0
        C_Timer.NewTicker(0.25, function(ticker)
            tries = tries + 1
            if IsInRaid() or tries >= 20 then
                ticker:Cancel()
                C_PartyInfo.InviteUnit(name)
            end
        end)
        return
    end
    C_PartyInfo.InviteUnit(name)
end

-- roles: the roles the player offered (set, or nil when unknown: then any role of their class).
-- guest: not in my guild; tag: their allied guild's tag, when they're from an allied guild.
local function NewMember(name, class, level, role, roles, newbie, tag)
    return {
        key = ns.NameKey(name),
        name = name,
        class = type(class) == "string" and class or nil,
        level = tonumber(level),
        role = ValidRole(role),
        roles = RoleSet(roles),
        newbie = newbie and true or nil,
        guest = not ns.Guild:IsMember(name),
        tag = tag or TagFor(name),
    }
end

local function NewPending(name, class, level, role, status, roles, newbie, tag)
    return {
        tag = tag or TagFor(name),
        key = ns.NameKey(name),
        name = name,
        class = type(class) == "string" and class or nil,
        level = tonumber(level),
        role = ValidRole(role),
        roles = RoleSet(roles),
        newbie = newbie and true or nil,
        status = PENDING_STATUS[status] and status or "invited",
        time = GetServerTime(),
    }
end

-- Can this member or pending player take that role? Their offered roles if known, else their class.
function Groups:CanPlay(entry, role)
    if not ROLE_SET[role] or not entry then return false end
    if entry.roles then return entry.roles[role] == true end
    return ns.CanTakeRole(entry.class, role)
end

-- Lists and counts ------------------------------------------------------------------------

local function SortedValues(t, less)
    local out = {}
    for _, v in pairs(t or {}) do out[#out + 1] = v end
    table.sort(out, less)
    return out
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Members: leader first, then by role (tank, healer, DPS), then by name.
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }
function Groups:GetMembers(listing)
    local leaderKey = ns.NameKey(listing.leader)
    return SortedValues(listing.members, function(a, b)
        if (a.key == leaderKey) ~= (b.key == leaderKey) then return a.key == leaderKey end
        local ra, rb = ROLE_ORDER[a.role] or 9, ROLE_ORDER[b.role] or 9
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
end

-- Pending players: requests first, then invited, then accepted; oldest first.
function Groups:GetPending(listing)
    local order = { request = 1, invited = 2, accepted = 3 }
    return SortedValues(listing.pending, function(a, b)
        if a.status ~= b.status then return order[a.status] < order[b.status] end
        return (a.time or 0) < (b.time or 0)
    end)
end

-- Places taken: members, plus invited and accepted players (requests don't take a place yet).
function Groups:CountTaken(listing)
    local n = Count(listing.members)
    for _, p in pairs(listing.pending or {}) do
        if p.status ~= "request" then n = n + 1 end
    end
    return n
end

-- [role] = how many are still missing.
function Groups:MissingRoles(listing)
    local missing = CopyTable(self:GetComposition(listing))
    local function take(role)
        if role and missing[role] then missing[role] = math.max(0, missing[role] - 1) end
    end
    for _, m in pairs(listing.members) do take(m.role) end
    for _, p in pairs(listing.pending or {}) do
        if p.status == "accepted" then take(p.role) end
    end
    return missing
end

function Groups:IsFull(listing)
    if self:CountTaken(listing) >= self:GetSize(listing) then return true end
    for _, n in pairs(self:MissingRoles(listing)) do
        if n > 0 then return false end
    end
    return true
end

-- Complete: every spot is taken by a member or an accepted player (invites still waiting for an
-- answer don't count). That's when the group starts.
function Groups:IsComplete(listing)
    local n = Count(listing.members)
    for _, p in pairs(listing.pending or {}) do
        if p.status == "accepted" then n = n + 1 end
    end
    if n >= self:GetSize(listing) then return true end
    for _, missing in pairs(self:MissingRoles(listing)) do
        if missing > 0 then return false end
    end
    return true
end

-- "open": looking for players. "midrun": looking again, already started. "running": in progress
-- (complete, or started and not reopened by the leader). "full": every spot is taken or invited.
-- Only "open" and "midrun" take join requests.
function Groups:GetState(listing)
    if listing.started and not listing.reopened then return "running" end
    if self:IsFull(listing) then return listing.started and "running" or "full" end
    return listing.started and "midrun" or "open"
end

function Groups:IsOpen(listing)
    local state = self:GetState(listing)
    return state == "open" or state == "midrun"
end

function Groups:IsInvited(listing)
    local p = listing.pending and listing.pending[MyKey()]
    return p ~= nil and p.status == "invited"
end

-- Am I already part of this listing (member, or invited/accepted)?
function Groups:IsInvolved(listing)
    local key = MyKey()
    local p = listing.pending and listing.pending[key]
    return listing.members[key] ~= nil or (p ~= nil and p.status ~= "request")
end

-- My listing has nobody but me: no other member, nobody invited, no request. Then joining
-- another group is fine (mine is removed once I'm accepted there).
function Groups:IsAloneInMine()
    local l = self:GetMine()
    if not l then return false end
    return Count(l.members) <= 1 and next(l.pending or {}) == nil
end

-- Joining another group: my own listing goes, when I'm alone in it.
local function DropMineForOther()
    local mine = Groups:GetMine()
    if mine and Groups:IsAloneInMine() then
        Groups:Delist()
        ns.Print(L["Your group was removed: you're joining another one."])
    end
end

-- Wire format ------------------------------------------------------------------------

-- Shared with the allied guilds: always, when there is a Guild Alliance (allied guilds count
-- as the guild).
function Groups:IsShared(l)
    return l ~= nil and ns.Alliance:IsActive()
end

local function Public(l)
    local members, pending = {}, {}
    for _, m in pairs(l.members) do
        members[#members + 1] = { name = m.name, class = m.class, level = m.level, role = m.role, guest = m.guest, newbie = m.newbie, tag = m.tag }
    end
    for _, p in pairs(l.pending) do
        if p.status ~= "request" then -- requests stay private to the leader
            pending[#pending + 1] = { name = p.name, class = p.class, level = p.level, role = p.role, status = p.status, newbie = p.newbie, tag = p.tag }
        end
    end
    return {
        id = l.id, leader = l.leader, dungeon = l.dungeon, note = l.note, created = l.created,
        size = l.size, composition = l.composition,
        newbies = l.newbies, discord = l.discord, discordChannel = l.discordChannel,
        started = l.started, reopened = l.reopened,
        members = members, pending = pending,
        vis = Groups:IsShared(l) and "ally" or nil,
    }
end

-- Rebuild a received listing from known fields only. The sender must be the leader.
-- scope: where it came from. Guest marks and tags are made relative to me: someone of my guild
-- has none, someone of the leader's allied guild gets that guild's tag.
local function Sanitize(p, sender, scope)
    local listTag = scope == "ally" and ns.Alliance:GetTag(p.g) or nil
    local function Relative(entry, guest, tag)
        if ns.Guild:IsMember(entry.name) then
            entry.guest, entry.tag = false, nil
        elseif CleanTag(tag) then
            entry.guest, entry.tag = true, CleanTag(tag)
        elseif listTag and not guest then
            entry.guest, entry.tag = true, listTag -- in the leader's guild
        else
            entry.guest = guest and true or false
        end
        return entry
    end
    if type(p.id) ~= "string" or type(p.dungeon) ~= "string" then return nil end
    if ns.NameKey(p.leader) ~= ns.NameKey(sender) then return nil end
    local function valid(entry)
        return type(entry) == "table" and type(entry.name) == "string" and entry.name ~= ""
    end
    local size = ValidSize(tonumber(p.size))
    local members, pending = {}, {}
    local count = 0
    for _, m in ipairs(type(p.members) == "table" and p.members or {}) do
        if count >= 40 then break end
        if valid(m) then
            local member = Relative({
                key = ns.NameKey(m.name), name = m.name:sub(1, 40),
                class = type(m.class) == "string" and m.class or nil,
                level = tonumber(m.level), role = ValidRole(m.role),
                newbie = m.newbie and true or nil,
            }, m.guest, m.tag)
            members[member.key] = member
            count = count + 1
            if not member.guest then ns.Guild:NoteClass(member.name, member.class, member.level) end
        end
    end
    for _, e in ipairs(type(p.pending) == "table" and p.pending or {}) do
        if count >= 50 then break end
        if valid(e) and (e.status == "invited" or e.status == "accepted") then
            local entry = Relative(NewPending(e.name:sub(1, 40), e.class, e.level, e.role, e.status, nil, e.newbie), e.guest, e.tag)
            pending[entry.key] = entry
            count = count + 1
        end
    end
    local leaderKey = ns.NameKey(sender)
    if not members[leaderKey] then
        members[leaderKey] = Relative({ key = leaderKey, name = sender }, false, nil)
    end
    return {
        id = p.id,
        leader = sender,
        scope = scope,                          -- where to answer
        tag = listTag,                          -- the leader's allied guild, if not mine
        shared = scope == "ally" and p.vis == "ally" or nil,
        dungeon = p.dungeon:sub(1, 20),
        note = type(p.note) == "string" and p.note:sub(1, NOTE_MAX) or "",
        created = tonumber(p.created) or GetServerTime(),
        size = size,
        composition = Groups:ValidComposition(size, p.composition),
        newbies = p.newbies and true or nil,
        discord = p.discord and true or nil,
        discordChannel = type(p.discordChannel) == "string" and p.discordChannel:sub(1, CHANNEL_MAX) or nil,
        started = p.started and true or nil,
        reopened = p.reopened and true or nil,
        members = members,
        pending = pending,
        seen = GetServerTime(),
    }
end

-- Listings -----------------------------------------------------------------------------

-- All open listings: mine first, then newest first.
function Groups:GetListings()
    local out = {}
    local mine = self:GetMine()
    if mine then out[1] = mine end
    for _, l in ipairs(SortedValues(listings, function(a, b) return a.created > b.created end)) do
        if not ns.IsIgnored(l.leader) then out[#out + 1] = l end -- my ignore list: not their groups
    end
    return out
end

function Groups:CountOpen()
    return (self:GetMine() and 1 or 0) + Count(listings)
end

-- Groups I'm invited to (or accepted and waiting to join).
function Groups:GetInvitations()
    local out = {}
    for id, l in pairs(listings) do
        local p = l.pending[MyKey()]
        if p and not ns.IsIgnored(l.leader) and myInviteReplies[id] ~= "declined" and (p.status == "invited" or myInviteReplies[id] == "accepted") then
            out[#out + 1] = l
        end
    end
    table.sort(out, function(a, b) return a.created > b.created end)
    return out
end

function Groups:GetInviteReply(id)
    return myInviteReplies[id]
end

-- The Invitations page was shown: the invitations on it are seen.
function Groups:MarkInvitationsSeen()
    for _, l in ipairs(self:GetInvitations()) do seenInvitations[l.id] = true end
end

-- My group page was shown: the join requests on it are seen (the minimap button stops glowing).
function Groups:MarkRequestsSeen()
    local mine = self:GetMine()
    for key, p in pairs(mine and mine.pending or {}) do
        if p.status == "request" then seenRequests[key] = true end
    end
end

-- Things waiting for my answer that I haven't seen yet: join requests to my group, invitations.
function Groups:CountUnseen()
    local n = 0
    local mine = self:GetMine()
    for key, p in pairs(mine and mine.pending or {}) do
        if p.status == "request" and not seenRequests[key] then n = n + 1 end
    end
    for _, l in ipairs(self:GetInvitations()) do
        if not myInviteReplies[l.id] and not seenInvitations[l.id] then n = n + 1 end
    end
    return n
end

-- An invitation I haven't answered and haven't seen yet (opening La Taverne goes there).
function Groups:HasUnseenInvitation()
    for _, l in ipairs(self:GetInvitations()) do
        if not myInviteReplies[l.id] and not seenInvitations[l.id] then return true end
    end
    return false
end

-- Matching -------------------------------------------------------------------------------

-- The dungeon isn't too high (red) or too low (gray) for my level. Unknown or no range: yes.
function Groups:AtMyLevel(l)
    local kind = ns.DungeonDifficulty(ns.DungeonByKey(l.dungeon))
    return kind ~= "impossible" and kind ~= "trivial"
end

-- The group still needs one of the roles I ticked at the top of the group list (none ticked: yes).
function Groups:NeedsMyRole(l)
    local mine = self:GetMyRoles()
    if not next(mine) then return true end
    local missing = self:MissingRoles(l)
    for role in pairs(mine) do
        if (missing[role] or 0) > 0 then return true end
    end
    return false
end

-- A group that fits me: open, needs one of my roles, at my level. Used by alerts.
function Groups:FitsMe(l)
    return self:IsOpen(l) and self:NeedsMyRole(l) and self:AtMyLevel(l)
end

-- "Tell me about new groups": "all", "fit" (only those that fit me) or "none".
function Groups:AlertMode()
    if ns.db.alerts then return ns.db.alerts end
    return ns.db.notify == false and "none" or "all" -- before 0.12: a plain on/off
end

-- "[View]" in chat: clicking it opens La Taverne on that group (see UI:OnLogin).
local function GroupLink(l)
    return "|Haddon:LaTaverne:group:" .. l.id .. "|h|cff71d5ff[" .. L["View"] .. "]|r|h"
end

-- "The Hall of Thanes 13-20", the range colored for my level.
local function DungeonWithRange(key)
    local range = ns.DungeonRange(ns.DungeonByKey(key))
    return ns.DungeonName(key) .. (range ~= "" and (" " .. range) or "")
end

local function AlertNewGroup(l)
    if ns.IsIgnored(l.leader) then return end
    local mode = Groups:AlertMode()
    -- Available players want a group: they hear about the ones that fit them, whatever the setting.
    local P = ns.Players
    if mode == "none" and P and P:IsActive() then mode = "fit" end
    if mode == "none" or (mode == "fit" and not (Groups:FitsMe(l) and (not P or P:WantsDungeon(l.dungeon)))) then return end
    ns.Print(format(L["New group: %s by %s"], DungeonWithRange(l.dungeon), l.leader .. (l.tag and (" [" .. l.tag .. "]") or ""))
        .. " " .. GroupLink(l))
    if ns.db.alertSound and SOUNDKIT and SOUNDKIT.UI_GROUP_FINDER_RECEIVE_APPLICATION then
        PlaySound(SOUNDKIT.UI_GROUP_FINDER_RECEIVE_APPLICATION)
    elseif ns.db.alertSound and SOUNDKIT and SOUNDKIT.READY_CHECK then
        PlaySound(SOUNDKIT.READY_CHECK)
    end
end

-- Guild chat line, on demand (My group, "Post in guild chat"): short, e.g.
-- "[La Taverne] LFM 1 Tank, 2 DPS - Hall of Thanes". The tag says the group is listed in the
-- addon. At most once a minute, so a double click doesn't flood the chat. In debug mode it goes
-- to the test guild chat, never to the real guild.
Groups.GUILD_POST_COOLDOWN = 60
local lastGuildPost

function Groups:MissingText(l)
    local parts = {}
    local missing = self:MissingRoles(l)
    for _, role in ipairs(Groups.ROLES) do
        local n = missing[role] or 0
        if n > 0 then parts[#parts + 1] = n .. " " .. ns.RoleLabel(role) end
    end
    return table.concat(parts, ", ")
end

function Groups:GuildPostText(l)
    local missing = self:MissingText(l)
    if missing == "" then return nil end
    return format(L["[La Taverne] LFM %s - %s"], missing, ns.DungeonName(l.dungeon))
end

-- Seconds before the next line can go out (0: now).
function Groups:GuildPostWait()
    if not lastGuildPost then return 0 end
    return math.max(0, math.ceil(lastGuildPost + self.GUILD_POST_COOLDOWN - GetTime()))
end

-- Can I post my group's line now? Returns ok, reason.
function Groups:CanPostInGuild()
    local l = self:GetMine()
    if not l or not self:IsOpen(l) or not self:GuildPostText(l) then
        return false, L["Only while the group is looking for players."]
    end
    local wait = self:GuildPostWait()
    if wait > 0 then return false, format(L["Wait %d s before posting again."], wait) end
    return true
end

function Groups:PostInGuild()
    if not self:CanPostInGuild() then return end
    local l = self:GetMine()
    local text = self:GuildPostText(l)
    lastGuildPost = GetTime()
    C_Timer.After(self.GUILD_POST_COOLDOWN + 0.1, function() if ns.UI then ns.UI:Refresh() end end)
    -- The line reaches the allied guilds too (shared guild chat) only when the group is shared.
    local relay = self:IsShared(l)
    if ns.Guild:IsSandbox() then
        ns.AllyChat:SendTestGuildChat(text, not relay)
    elseif IsInGuild() then
        if not relay then ns.AllyChat:SkipRelay(text) end
        SendChatMessage(text, "GUILD")
    end
    if ns.UI then ns.UI:Refresh() end
end


function Groups:CountNewInvitations()
    local n = 0
    for _, l in ipairs(self:GetInvitations()) do
        if not myInviteReplies[l.id] then n = n + 1 end
    end
    return n
end

-- Join requests waiting for my answer.
function Groups:CountRequests()
    local mine = self:GetMine()
    local n = 0
    for _, p in pairs(mine and mine.pending or {}) do
        if p.status == "request" then n = n + 1 end
    end
    return n
end

-- Leader side ---------------------------------------------------------------------

-- Send my listing. Changes often come in bursts (a party forming fires several roster updates),
-- so they're gathered: one message at most every second.
local broadcastPending = false
function Groups:Broadcast()
    if broadcastPending then return end
    broadcastPending = true
    C_Timer.After(1, function()
        broadcastPending = false
        local l = Groups:GetMine()
        if not l then return end
        ns.Comm:Send("LIST", Public(l))
        -- Allied guilds: always, with a Guild Alliance.
        if ns.Alliance:IsActive() then
            l.allySent = true
            ns.Comm:SendAlly("LIST", Public(l))
        end
    end)
end

-- Leader side: start the group when it becomes complete, close "looking again" when it's
-- complete again.
-- The role mix follows the players: when more players have a role than the group looks for
-- (the leader put a second tank in, or accepted someone as a role already complete), the
-- group now looks for that many, and a spot is taken from a role that still has free spots:
-- the one the player left first (from), then DPS, healer, tank. The total stays the size.
local function FitComposition(l, from)
    local wanted = CopyTable(Groups:GetComposition(l))
    local have = {}
    for _, m in pairs(l.members) do
        if m.role then have[m.role] = (have[m.role] or 0) + 1 end
    end
    for _, p in pairs(l.pending or {}) do
        if p.status == "accepted" and p.role then have[p.role] = (have[p.role] or 0) + 1 end
    end
    local changed = false
    for _, role in ipairs(Groups.ROLES) do
        while (have[role] or 0) > (wanted[role] or 0) do
            local took
            for _, r in ipairs({ from or "", "DAMAGER", "HEALER", "TANK" }) do
                if r ~= role and wanted[r] and wanted[r] > (have[r] or 0) then took = r break end
            end
            if not took then break end
            wanted[took] = wanted[took] - 1
            wanted[role] = (wanted[role] or 0) + 1
            changed = true
        end
    end
    if changed then l.composition = wanted end
    return changed
end

local function UpdateState(l, from)
    FitComposition(l, from)
    if not Groups:IsComplete(l) then return end
    if not l.started then
        l.started = true
        ns.Print(L["Your group is complete: it now shows as in progress."])
    end
    l.reopened = nil
end

-- The party leader's name, when it isn't me (nil when unknown).
local function PartyLeader()
    local raid = IsInRaid()
    for i = 1, raid and GetNumGroupMembers() or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and UnitIsGroupLeader(unit) then return ns.FullName(unit) end
    end
end

-- I joined a party led by someone who isn't in my group (a normal invite, outside La Taverne)?
-- Then my listing isn't this party.
local function JoinedOtherParty(l)
    if Groups:IsLeading() then return false end
    local leader = PartyLeader()
    return leader ~= nil and not ns.IsMe(leader) and not l.members[ns.NameKey(leader)]
end

-- Mirror my real party into the listing's members. Players who join get their role from
-- the pending entry (what they chose), or the game's assigned role; players who leave are removed.
function Groups:SyncParty(quiet)
    local l = self:GetMine()
    if not l then return end
    if JoinedOtherParty(l) then
        self:Delist()
        ns.Print(L["You joined another party: your group was removed from La Taverne."])
        return
    end
    local current = CurrentParty()
    local changed = false
    for key in pairs(l.members) do
        if not current[key] then
            l.members[key] = nil
            changed = true
        end
    end
    for key, info in pairs(current) do
        local member = l.members[key]
        if not member then
            local p = l.pending[key]
            l.members[key] = NewMember(info.name, info.class or (p and p.class), info.level,
                (p and p.role) or info.assignedRole, p and p.roles, p and p.newbie,
                TagFor(info.name, info.guild) or (p and p.tag))
            l.pending[key] = nil
            changed = true
        elseif member.class ~= info.class or member.level ~= info.level then
            member.class, member.level = info.class, info.level
        end
    end
    if changed then
        UpdateState(l)
        if not quiet then self:Broadcast() end
        Changed()
    end
end

-- roles: [key] = role for me and my party members; invites: array of { name, class, level }
-- composition: only used when the size isn't 5. options: { newbies, discord, discordChannel }
function Groups:Create(dungeon, roles, invites, note, composition, options)
    options = options or {}
    if not self:CanPost() then return end
    if self:GetMine() then self:Delist() end
    if ns.Players then ns.Players:Stop(L["You posted a group: you're no longer available."]) end
    local now = GetServerTime()
    local me = ns.FullName("player")
    local size = ns.DungeonSize(dungeon)
    local listing = {
        id = me .. "#" .. now,
        leader = me,
        dungeon = dungeon,
        note = (note or ""):sub(1, NOTE_MAX),
        created = now,
        size = size,
        composition = self:ValidComposition(size, composition),
        newbies = options.newbies and true or nil,
        discord = options.discord and true or nil,
        discordChannel = options.discord and options.discordChannel and strtrim(options.discordChannel):sub(1, CHANNEL_MAX) or nil,
        members = {},
        pending = {},
    }
    local myKey = MyKey()
    for key, info in pairs(CurrentParty()) do
        local member = NewMember(info.name, info.class, info.level, roles[key] or info.assignedRole, nil, nil,
            TagFor(info.name, info.guild))
        if key == myKey then member.newbie = self:IsNewPlayer() or nil end
        listing.members[key] = member
    end
    for _, i in ipairs(invites or {}) do
        local entry = NewPending(i.name, i.class, i.level, nil, "invited", nil, nil, i.tag)
        if not listing.members[entry.key] then listing.pending[entry.key] = entry end
    end
    CharDB().listing = listing
    UpdateState(listing)
    self:Broadcast()
    -- The game's group finder sound when a group gets listed (joining a queue).
    if SOUNDKIT and SOUNDKIT.PVP_ENTER_QUEUE then PlaySound(SOUNDKIT.PVP_ENTER_QUEUE) end
    -- Same notice as the other guild members get, so the leader sees the group went out.
    if self:AlertMode() ~= "none" then
        ns.Print(format(L["New group: %s by %s"], DungeonWithRange(listing.dungeon), listing.leader))
    end
    Changed()
end

function Groups:Delist()
    local l = self:GetMine()
    if not l then return end
    ns.Comm:Send("DELIST", { id = l.id })
    if l.allySent and ns.Alliance:IsActive() then ns.Comm:SendAlly("DELIST", { id = l.id }) end
    CharDB().listing = nil
    Changed()
end

-- Party lead ---------------------------------------------------------------------------------
-- Only the party leader can invite, so only the leader (or someone solo) can post. When I pass
-- the lead with a group posted, the group goes to the new leader if they run La Taverne
-- (HANDOVER, answered by HANDOVER_OK). Otherwise I keep it, and I'm told I can't invite.

-- Can I invite (party leader, or solo)?
function Groups:IsLeading()
    return not IsInGroup() or UnitIsGroupLeader("player") and true or false
end

-- May I post a group? Returns ok, reason.
function Groups:CanPost()
    if self:IsLeading() then return true end
    return false, L["Only the party leader can post a group."]
end

local handover -- { id, to }: waiting for the new leader's HANDOVER_OK

function Groups:LeaderChanged()
    local l = self:GetMine()
    if not l or self:IsLeading() then return end
    local leader = PartyLeader()
    if not leader or ns.IsMe(leader) then return end
    -- Only to someone already in my group; joining another party is SyncParty's business.
    if not l.members[ns.NameKey(leader)] then return end
    local roles, invites = {}, {}
    for key, m in pairs(l.members) do roles[key] = m.role end
    for _, p in pairs(l.pending) do
        if p.status ~= "request" then
            invites[#invites + 1] = { name = p.name, class = p.class, level = p.level }
        end
    end
    handover = { id = l.id, to = ns.NameKey(leader) }
    SendTo(ScopeOf(leader), "HANDOVER", {
        id = l.id, to = leader, dungeon = l.dungeon, note = l.note, composition = l.composition,
        newbies = l.newbies, discord = l.discord, discordChannel = l.discordChannel,
        roles = roles, invites = invites,
    })
    local id = l.id
    C_Timer.After(5, function()
        local mine = Groups:GetMine()
        if not handover or handover.id ~= id or not mine or mine.id ~= id then return end
        handover = nil
        if not Groups:IsLeading() then
            ns.Print(format(L["%s leads the party now and doesn't have La Taverne: you can't invite any more. Get the lead back, or remove your group."], leader))
            Changed()
        end
    end)
end

-- The leader passed me the lead with a group posted: it's mine now.
OnBoth("HANDOVER", function(sender, p, isSelf, scope)
    if isSelf or not ns.IsMe(p.to) or not UnitIsGroupLeader("player") then return end
    if Groups:GetMine() or not ns.DungeonByKey(p.dungeon) then return end
    if not CurrentParty()[ns.NameKey(sender)] then return end -- only from someone in my party
    local roles = {}
    for key, role in pairs(type(p.roles) == "table" and p.roles or {}) do
        if type(key) == "string" then roles[key] = ValidRole(role) end
    end
    local invites = {}
    for _, i in ipairs(type(p.invites) == "table" and p.invites or {}) do
        if type(i) == "table" and type(i.name) == "string" then
            invites[#invites + 1] = { name = i.name, class = i.class, level = i.level }
        end
    end
    Groups:Create(p.dungeon, roles, invites, type(p.note) == "string" and p.note or "",
        type(p.composition) == "table" and p.composition or nil, {
            newbies = p.newbies, discord = p.discord,
            discordChannel = type(p.discordChannel) == "string" and p.discordChannel or nil,
        })
    SendTo(scope, "HANDOVER_OK", { id = p.id, to = sender })
    ns.Print(format(L["%s gave you the party lead: the group is yours in La Taverne now."], sender))
end)

OnBoth("HANDOVER_OK", function(sender, p, isSelf)
    local l = Groups:GetMine()
    if isSelf or not ns.IsMe(p.to) or not l or p.id ~= l.id then return end
    if not handover or handover.id ~= l.id or handover.to ~= ns.NameKey(sender) then return end
    handover = nil
    Groups:Delist()
    ns.Print(format(L["Your group passed to %s, the new party leader."], sender))
end)

-- Change the role mix after posting. Players already in the group (members and accepted) keep
-- their spot: no role can go below them. Returns ok, error text.
function Groups:SetComposition(values)
    local l = self:GetMine()
    if not l or type(values) ~= "table" then return false end
    local size = self:GetSize(l)
    local total = 0
    for _, role in ipairs(self.ROLES) do total = total + (tonumber(values[role]) or 0) end
    if total ~= size then return false, format(L["The roles must add up to %d players."], size) end
    local taken = {}
    for _, m in pairs(l.members) do
        if m.role then taken[m.role] = (taken[m.role] or 0) + 1 end
    end
    for _, p in pairs(l.pending) do
        if p.status == "accepted" and p.role then taken[p.role] = (taken[p.role] or 0) + 1 end
    end
    for _, role in ipairs(self.ROLES) do
        local n = taken[role] or 0
        if n > (tonumber(values[role]) or 0) then
            return false, format(L["Already %d %s in the group: keep at least that many."], n, ns.RoleLabel(role))
        end
    end
    l.composition = self:ValidComposition(size, values)
    UpdateState(l)
    self:Broadcast()
    Changed()
    return true
end

-- A player to invite by name: a guild member, or an allied player we heard from (not denied).
-- Returns { name, class, level, tag } or nil.
function Groups:FindPlayer(name)
    local member = ns.Guild:GetMember(name)
    if member then return member end
    if not ns.Alliance:IsActive() then return nil end
    local tag = TagFor(name)
    if tag and ns.Vouch then
        local known = ns.Vouch:Find(name)
        return { name = known and known.name or name, tag = tag }
    end
    return nil
end

-- Name autocomplete: guild members, then allied players seen recently (with their tag).
function Groups:SearchPlayers(text, limit)
    local results = ns.Guild:Search(text, limit)
    if ns.Alliance:IsActive() and ns.Vouch and #results < (limit or 8) then
        for _, p in ipairs(ns.Vouch:Search(text, (limit or 8) - #results)) do
            results[#results + 1] = { name = p.name, tag = ns.Alliance:GetTag(p.guild), online = p.online }
        end
    end
    return results
end

function Groups:SetNote(note)
    local l = self:GetMine()
    if not l then return end
    note = (note or ""):sub(1, NOTE_MAX)
    if note == l.note then return end
    l.note = note
    self:Broadcast()
    Changed()
end

-- "New players welcome", "Discord required" and its channel, changed after posting.
function Groups:SetOptions(newbies, discord, discordChannel)
    local l = self:GetMine()
    if not l then return end
    l.newbies = newbies and true or nil
    l.discord = discord and true or nil
    l.discordChannel = discord and discordChannel and strtrim(discordChannel):sub(1, CHANNEL_MAX) or nil
    self:Broadcast()
    Changed()
end

-- Someone left mid-run: look for players again ("already started").
function Groups:Reopen()
    local l = self:GetMine()
    if not l or not l.started or self:IsComplete(l) then return end
    l.reopened = true
    self:Broadcast()
    Changed()
end

-- Changed my mind: stop looking for a replacement, the group shows as in progress again.
function Groups:StopReopen()
    local l = self:GetMine()
    if not l or not l.reopened then return end
    l.reopened = nil
    self:Broadcast()
    Changed()
end

-- The leader picks a member's role among the roles that player offered.
function Groups:SetMemberRole(key, role)
    local l = self:GetMine()
    local m = l and l.members[key]
    if not m or not self:CanPlay(m, role) then return end
    local from = m.role
    m.role = role
    UpdateState(l, from)
    self:Broadcast()
    Changed()
end

-- Invite a guild member after the group is posted.
function Groups:InviteMember(name, class, level)
    local l = self:GetMine()
    if not l then return false end
    local key = ns.NameKey(name)
    if l.members[key] or self:CountTaken(l) >= self:GetSize(l) then return false end
    local existing = l.pending[key]
    if existing and existing.status ~= "request" then return false end
    l.pending[key] = NewPending(name, class, level, existing and existing.role, "invited", nil, nil, existing and existing.tag)
    self:Broadcast()
    Changed()
    return true
end

-- Accept a join request as one of the roles they offered: they're in the pending list as
-- accepted, and get the party invite.
function Groups:Accept(key, role)
    local l = self:GetMine()
    local p = l and l.pending[key]
    if not p or p.status ~= "request" or not self:CanPlay(p, role) then return end
    p.status = "accepted"
    p.role = role
    InvitePlayer(l, p.name)
    SendTo(ScopeOf(p.name), "DECIDE", { id = l.id, to = p.name, accepted = true, role = role })
    UpdateState(l)
    self:Broadcast()
    Changed()
end

-- Send the party invite again (accepted players who missed it).
function Groups:InviteAgain(key)
    local l = self:GetMine()
    local p = l and l.pending[key]
    if p then InvitePlayer(l, p.name) end
end

-- Decline a request, cancel an invitation, or drop an accepted player who never joined.
function Groups:RemovePending(key)
    local l = self:GetMine()
    local p = l and l.pending[key]
    if not p then return end
    l.pending[key] = nil
    if p.status == "request" or p.status == "accepted" then
        SendTo(ScopeOf(p.name), "DECIDE", { id = l.id, to = p.name, accepted = false })
    end
    if p.status ~= "request" then self:Broadcast() end
    Changed()
end

-- Player side ---------------------------------------------------------------------------

-- Ask to join with the roles chosen at the top of the group list; the leader picks one.
function Groups:Apply(id)
    local l = listings[id]
    local roles = RoleList(self:GetMyRoles())
    if not l or #roles == 0 or not self:IsOpen(l) then return end
    if self:GetMine() and not self:IsAloneInMine() then return end -- remove my group first
    if not self:GetMine() and IsInGroup() then return end -- leave my party first
    local _, class = UnitClass("player")
    local payload = {
        id = id, to = l.leader, roles = roles, role = roles[1], newbie = self:IsNewPlayer() or nil,
        class = class, level = UnitLevel("player"),
    }
    local now = GetServerTime()
    myApplications[id] = { roles = roles, status = "pending", time = now, sent = now, tries = 1, payload = payload }
    SendTo(l.scope, "APPLY", payload)
    Changed()
end

function Groups:CancelApply(id)
    local l = listings[id]
    myApplications[id] = nil
    if l then SendTo(l.scope, "APPLY_CANCEL", { id = id, to = l.leader }) end
    Changed()
end

-- Answer an invitation. When accepting: role is where I'd go first; roles is everything I offer
-- (the leader can move me to another of those).
function Groups:ReplyInvitation(id, accepted, role, roles)
    local l = listings[id]
    if not l then return end
    if accepted and not ROLE_SET[role] then return end
    if accepted and self:GetMine() and not self:IsAloneInMine() then return end -- remove my group first
    if accepted and not self:GetMine() and IsInGroup() then return end -- leave my party first
    local _, class = UnitClass("player")
    myInviteReplies[id] = accepted and "accepted" or "declined"
    if accepted and ns.Players then ns.Players:Stop(L["You accepted an invitation: you're no longer available."]) end
    if accepted then DropMineForOther() end

    local offered = RoleList(RoleSet(roles) or { [role or "DAMAGER"] = true })
    SendTo(l.scope, "INVITE_REPLY", {
        id = id, to = l.leader, accepted = accepted and true or false,
        role = role, roles = offered, newbie = self:IsNewPlayer() or nil,
        class = class, level = UnitLevel("player"),
    })
    Changed()
end

-- Change my own role in a group I joined (the leader's addon applies it and tells everyone).
function Groups:ChangeMyRole(id, role)
    local l = listings[id]
    if not l or not ROLE_SET[role] then return end
    local me = l.members[MyKey()]
    if me then me.role = role end -- shown right away; the leader's next update confirms it
    SendTo(l.scope, "ROLE_CHANGE", { id = id, to = l.leader, role = role })
    Changed()
end

-- Message handlers -------------------------------------------------------------------

OnBoth("LIST", function(sender, p, isSelf, scope)
    if isSelf then return end
    local l = Sanitize(p, sender, scope)
    if not l then return end
    -- An allied group that isn't shared: only for the allied players who are part of it.
    if scope == "ally" and not l.shared and not Groups:IsInvolved(l) and not myApplications[l.id] then
        if listings[l.id] then
            listings[l.id] = nil
            Changed()
        end
        return
    end
    -- One listing per leader: drop older ones.
    for id, other in pairs(listings) do
        if id ~= l.id and ns.NameKey(other.leader) == ns.NameKey(sender) then listings[id] = nil end
    end
    local previous = listings[l.id]
    local now = GetServerTime()
    -- Their group had gone quiet (leader offline) before this update.
    local wasAway = not previous or now - (previous.seen or 0) > HEARTBEAT + 20
    listings[l.id] = l
    if not previous then AlertNewGroup(l) end
    -- My request didn't reach them (no receipt): send it again. Once at their next update (a
    -- /reload, a lost message), then each time they come back after being away.
    local app = myApplications[l.id]
    -- Back from away: a waiting request gets its full time again (10 min to answer).
    if app and app.status == "pending" and wasAway then app.time = now end
    if app and app.status == "pending" and not app.acked and app.payload
        and now - (app.sent or 0) > 20 and (wasAway or (app.tries or 1) < 2) and (app.tries or 1) < 6 then
        app.sent, app.time, app.tries = now, now, (app.tries or 1) + 1
        SendTo(l.scope, "APPLY", app.payload)
        ns.Print(format(L["Your request to %s was sent again: their addon hadn't received it."], l.leader))
    end
    -- New invitation for me? A new one replaces my answer to an earlier one (invited again
    -- after leaving, or after the leader cancelled), and isn't "seen" yet.
    local wasInvited = previous and Groups:IsInvited(previous)
    local newInvite = Groups:IsInvited(l) and not wasInvited
    if newInvite or not Groups:IsInvolved(l) then
        myInviteReplies[l.id] = nil
        seenInvitations[l.id] = nil
    end
    if newInvite then
        ns.Print(format(L["%s invites you to %s."], sender, DungeonWithRange(l.dungeon)) .. " " .. GroupLink(l)
            .. ((not Groups:GetMine() and IsInGroup()) and (" |cffff9900" .. L["Leave your party first."] .. "|r") or ""))
        if SOUNDKIT and SOUNDKIT.READY_CHECK then PlaySound(SOUNDKIT.READY_CHECK) end
    end
    Changed()
end)

OnBoth("DELIST", function(sender, p)
    local l = type(p.id) == "string" and listings[p.id]
    if not l or ns.NameKey(l.leader) ~= ns.NameKey(sender) then return end
    listings[p.id] = nil
    local app = myApplications[p.id]
    if app and app.status == "pending" then
        ns.Print(format(L["The group %s was closed."], ns.DungeonName(l.dungeon)))
    end
    myApplications[p.id] = nil
    myInviteReplies[p.id] = nil
    Changed()
end)

OnBoth("SYNC_REQ", function(_, _, isSelf)
    if isSelf or not Groups:GetMine() then return end
    C_Timer.After(math.random() * 3, function() Groups:Broadcast() end)
end)

OnBoth("APPLY", function(sender, p, isSelf, scope)
    local l = Groups:GetMine()
    if isSelf or not l or p.id ~= l.id or not ns.IsMe(p.to) then return end
    if not Groups:IsOpen(l) then return end -- in progress or full: no more requests
    if ns.IsIgnored(sender) then return end -- on my ignore list
    if scope == "ally" and not Groups:IsShared(l) then return end -- "My guild" only
    local key = ns.NameKey(sender)
    if l.members[key] or (l.pending[key] and l.pending[key].status ~= "request") then return end
    -- Tell them it arrived (they send it again otherwise). Already here: nothing more to do.
    SendTo(scope, "APPLY_ACK", { id = l.id, to = sender })
    if l.pending[key] then return end
    ns.Guild:NoteClass(sender, p.class, p.level)
    -- Prefer what the guild roster says about class and level.
    local member = ns.Guild:GetMember(sender)
    local class = (member and member.class) or p.class
    -- Offered roles (older versions send a single role), only those their class can take.
    local offered = RoleSet(p.roles) or RoleSet({ p.role })
    if offered then
        for role in pairs(offered) do
            if not ns.CanTakeRole(class, role) then offered[role] = nil end
        end
    end
    if not offered or not next(offered) then return end
    local list = RoleList(offered)
    local tag = scope == "ally" and ns.Alliance:GetTag(p.g) or nil
    local entry = NewPending(sender, class, (member and member.level) or p.level,
        #list == 1 and list[1] or nil, "request", offered, p.newbie, tag)
    -- Nobody from their guild could confirm them: the leader sees it on the request.
    entry.unverified = scope == "ally" and ns.Vouch and ns.Vouch:GetState(sender) == "unverified" or nil
    l.pending[key] = entry
    seenRequests[key] = nil -- a new request: not seen yet
    local labels = {}
    for _, role in ipairs(list) do labels[#labels + 1] = ns.RoleLabel(role) end
    ns.Print(format(L["%s wants to join as %s."], sender .. (tag and (" [" .. tag .. "]") or ""), table.concat(labels, " / ")))
    if SOUNDKIT and SOUNDKIT.READY_CHECK then PlaySound(SOUNDKIT.READY_CHECK) end
    Changed()
end)

-- The leader's addon got my request.
OnBoth("APPLY_ACK", function(sender, p, isSelf)
    if isSelf or not ns.IsMe(p.to) then return end
    local app = myApplications[p.id]
    local l = listings[p.id]
    if not app or not l or ns.NameKey(l.leader) ~= ns.NameKey(sender) then return end
    if not app.acked then
        app.acked = true
        Changed()
    end
end)

OnBoth("APPLY_CANCEL", function(sender, p, isSelf)
    local l = Groups:GetMine()
    if isSelf or not l or p.id ~= l.id then return end
    local key = ns.NameKey(sender)
    local entry = l.pending[key]
    if entry and entry.status == "request" then
        l.pending[key] = nil
        Changed()
    end
end)

OnBoth("DECIDE", function(sender, p, isSelf)
    if isSelf or not ns.IsMe(p.to) then return end
    local app = myApplications[p.id]
    local l = listings[p.id]
    if not app or not l or ns.NameKey(l.leader) ~= ns.NameKey(sender) then return end
    app.status = p.accepted and "accepted" or (p.expired and "expired") or "declined"
    if p.expired then
        ns.Print(format(L["No answer from %s: your request expired. You can ask again."], sender))
    elseif p.accepted and ROLE_SET[p.role] then
        app.role = p.role
        ns.Print(format(L["%s accepted you as %s: watch for the invite."], sender, ns.RoleLabel(p.role)))
        DropMineForOther()
    elseif p.accepted then
        ns.Print(format(L["%s accepted you: watch for the invite."], sender))
        DropMineForOther()
    else
        ns.Print(format(L["%s declined your request."], sender))
    end
    Changed()
end)

OnBoth("INVITE_REPLY", function(sender, p, isSelf)
    local l = Groups:GetMine()
    if isSelf or not l or p.id ~= l.id or not ns.IsMe(p.to) then return end
    local key = ns.NameKey(sender)
    local entry = l.pending[key]
    if not entry or entry.status ~= "invited" then return end
    if p.accepted and ROLE_SET[p.role] then
        entry.status = "accepted"
        entry.role = p.role
        entry.roles = RoleSet(p.roles) or { [p.role] = true }
        entry.roles[p.role] = true
        entry.newbie = p.newbie and true or nil
        if type(p.class) == "string" then entry.class = p.class end
        entry.level = tonumber(p.level) or entry.level
        ns.Guild:NoteClass(sender, p.class, p.level)
        -- The leader already chose this player: send the party invite right away.
        InvitePlayer(l, sender)
        ns.Print(format(L["%s accepted your invitation as %s."], sender, ns.RoleLabel(p.role)))
        if SOUNDKIT and SOUNDKIT.READY_CHECK then PlaySound(SOUNDKIT.READY_CHECK) end
    else
        l.pending[key] = nil
        ns.Print(format(L["%s declined your invitation."], sender))
    end
    UpdateState(l)
    Groups:Broadcast()
    Changed()
end)

OnBoth("ROLE_CHANGE", function(sender, p, isSelf)
    local l = Groups:GetMine()
    if isSelf or not l or p.id ~= l.id or not ns.IsMe(p.to) or not ROLE_SET[p.role] then return end
    local m = l.members[ns.NameKey(sender)]
    if not m or not ns.CanTakeRole(m.class, p.role) then return end
    local from = m.role
    m.role = p.role
    -- Choosing a role yourself means you offer it.
    if m.roles then m.roles[p.role] = true end
    UpdateState(l, from)

    Groups:Broadcast()
    Changed()
end)

-- Timers and events -------------------------------------------------------------------

-- Ask the guild for its open groups again, and re-send mine. Used when the way to talk to the
-- guild changes after login (debug channel ready, test guild member added), so nobody waits
-- for the next heartbeat. Several calls close together count as one.
local resyncPending = false
function Groups:Resync()
    if resyncPending then return end
    resyncPending = true
    C_Timer.After(2, function()
        resyncPending = false
        ns.Comm:Send("SYNC_REQ", {})
        if ns.Alliance:IsActive() then ns.Comm:SendAlly("SYNC_REQ", {}) end
        if Groups:GetMine() then Groups:Broadcast() end
    end)
end

function Groups:OnLogin()
    ns.On("GROUP_ROSTER_UPDATE", function() Groups:SyncParty() end)
    ns.On("PARTY_LEADER_CHANGED", function() Groups:LeaderChanged() end)
    ns.Comm.onReady = function(role)
        if role == "sandbox" or role == "ally" then Groups:Resync() end
    end


    -- Messages sent before the channel is ready are queued by ns.Comm.
    C_Timer.After(10, function()
        ns.Comm:Send("SYNC_REQ", {})
        local mine = Groups:GetMine()
        if mine and (not mine.pending or (not mine.started and GetServerTime() - mine.created > MAX_AGE)) then
            -- Expired (a group in progress lasts as long as the party), or saved by an older
            -- version of the addon.
            Groups:Delist()
        elseif mine then
            mine.size = ns.DungeonSize(mine.dungeon)
            mine.composition = Groups:ValidComposition(mine.size, mine.composition)
            Groups:SyncParty(true)
            Groups:Broadcast()
        end
    end)

    C_Timer.NewTicker(HEARTBEAT, function() Groups:Broadcast() end)

    C_Timer.NewTicker(15, function()
        local now = GetServerTime()
        local removed = false
        for id, l in pairs(listings) do
            local tooOld = not l.started and now - l.created > MAX_AGE
            if now - l.seen > EXPIRE or tooOld then
                listings[id] = nil
                -- Leader offline: a pending request waits for their return (sent again then).
                local app = myApplications[id]
                if tooOld or not (app and app.status == "pending") then myApplications[id] = nil end
                myInviteReplies[id] = nil
                removed = true
            end
        end
        -- My requests nobody answered: expired, I can ask again. Not while the leader is away
        -- (it waits for them); a request for a group gone for good goes after MAX_AGE.
        for id, app in pairs(myApplications) do
            local l = listings[id]
            if app.status == "pending" and app.time then
                if not l then
                    if now - app.time > MAX_AGE then myApplications[id] = nil end
                elseif not Groups:IsLeaderAway(l) and now - app.time > REQUEST_TTL + 30 then
                    app.status = "expired"
                    removed = true
                    ns.Print(format(L["No answer from %s: your request expired. You can ask again."], l.leader))
                end
            end
        end
        local mine = Groups:GetMine()
        if mine and not mine.started and now - mine.created > MAX_AGE then
            Groups:Delist()
            ns.Print(L["Your group listing expired."])
            return
        end
        -- Requests I left unanswered: expired, and the player is told.
        for key, p in pairs(mine and mine.pending or {}) do
            if p.status == "request" and p.time and now - p.time > REQUEST_TTL then
                mine.pending[key] = nil
                SendTo(ScopeOf(p.name), "DECIDE", { id = mine.id, to = p.name, accepted = false, expired = true })
                removed = true
            end
        end
        if removed then Changed() end
    end)
end
