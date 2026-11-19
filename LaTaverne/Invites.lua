-- Keyword auto-invite: guild members (and allied guild members) who type a keyword like "+1"
-- or "inv" in guild chat get a group invite, from a queue.
-- - Easy on/off, never left on by accident: off at every login, turns itself off after a while.
-- - The Auto-invite tab's Queue page is where you follow and send the invites; its side tab
--   shows how many are waiting, and "when I click" mode prints a chat line for each new one.
-- - "Right away" mode invites from the queue on its own; "When I click" mode waits for a click.
-- - Only whole messages count ("+1", "inv pls"), not words inside a sentence.
-- - Several people can be inviting at once: "already in a group" or a declined invite takes the
--   player off the queue. Typing the keyword again puts them back.
-- - The party becomes a raid when it fills up.
-- Debug mode: listens to the test guild chat only, never the real guild chat, and only invites
-- test guild members.
local ADDON, ns = ...
local Invites = ns.NewModule("Invites")
local L = ns.L

local THROTTLE = 0.6      -- seconds between two invites
local INVITE_TIMEOUT = 90 -- an invite with no answer leaves the queue after this
local RECENT_MAX = 12

local active = false
local activeUntil = 0
local queue = {}   -- { name, key, source, time, status = "queued" | "invited", invitedAt }
local recent = {}  -- last results: { name, result, time }
local lastInvite = 0
Invites.blocked = nil -- why invites can't go out right now (text), or nil

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function Settings() return ns.db.invites end

-- Keyword sets: several leaders can invite at once, each with their own words ("+1" for group
-- 1, "+2" for group 2), or all with the same ones (a free-for-all). Every set is editable.
-- sets = { { name, words = { ... } } }, set = the one in use.
local USUAL = { "+1", "inv", "invite", "inv pls", "inv plz", "inv svp", "invite moi", "invite me" }
local function Sets()
    local s = Settings()
    if type(s.sets) ~= "table" or #s.sets == 0 then
        -- First time (or an old version): the usual words, kept as they were edited, then two
        -- examples of a set per group.
        s.sets = {
            { name = L["Usual keywords"], words = type(s.keywords) == "table" and #s.keywords > 0 and s.keywords or CopyTable(USUAL) },
            { name = "+1", words = { "+1" } },
            { name = "+2", words = { "+2" } },
        }
        s.set = 1
    end
    s.keywords = nil
    if type(s.set) ~= "number" or not s.sets[s.set] then s.set = 1 end
    return s.sets
end
Invites.Sets = Sets

-- The set in use.
function Invites:GetSet()
    return Sets()[Settings().set]
end

function Invites:UseSet(i)
    if not Sets()[i] then return end
    Settings().set = i
    if self.onChange then self.onChange() end
    if self.SendRunning and self:IsActive() then self.SendRunning(true) end -- the others see my new words
end

local function Changed()
    if Invites.onChange then Invites.onChange() end
end

-- Keywords ---------------------------------------------------------------------------------

local function Normalize(text)
    text = strtrim(text or ""):lower():gsub("%s+", " ")
    text = text:gsub("[!%.%?]+$", "")
    return strtrim(text)
end

function Invites:IsKeyword(text)
    if type(text) ~= "string" or IsSecret(text) or #text > 40 then return false end
    local norm = Normalize(text)
    if norm == "" then return false end
    for _, word in ipairs(Invites:GetSet().words) do
        if Normalize(word) == norm then return true end
    end
    return false
end

-- Queue ------------------------------------------------------------------------------------

local function Find(key)
    for i, entry in ipairs(queue) do
        if entry.key == key then return entry, i end
    end
    return nil
end

local function Finish(entry, result)
    local _, index = Find(entry.key)
    if index then table.remove(queue, index) end
    table.insert(recent, 1, { name = entry.name, result = result, time = GetServerTime() })
    while #recent > RECENT_MAX do table.remove(recent) end
    Changed()
end

function Invites:GetQueue() return queue end
function Invites:GetRecent() return recent end

function Invites:Remove(name)
    local entry = Find(ns.NameKey(name))
    if entry then Finish(entry, "removed") end
end

function Invites:Clear()
    wipe(queue)
    Changed()
end

function Invites:ClearResults()
    wipe(recent)
    Changed()
end

local function Add(name, source)
    local key = ns.NameKey(name)
    local entry = Find(key)
    if entry then
        if entry.status ~= "invited" then entry.time = GetServerTime() end
    else
        queue[#queue + 1] = { name = name, key = key, source = source, time = GetServerTime(), status = "queued" }
        -- Waiting for my click: say so in chat, with a link to the queue.
        if not Settings().auto then
            ns.Print(format(L["%s wants an invite (queue: %d)."], name, #queue)
                .. " |Haddon:LaTaverne:autoinvite:queue|h|cff71d5ff[" .. L["View"] .. "]|r|h")
        end
    end
    Changed()
    Invites:Process()
end

-- Who is in my group right now (by name key).
local function GroupKeys()
    local keys = {}
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do
            local name = ns.FullName("raid" .. i)
            if name then keys[ns.NameKey(name)] = true end
        end
    else
        for i = 1, n - 1 do
            local name = ns.FullName("party" .. i)
            if name then keys[ns.NameKey(name)] = true end
        end
    end
    return keys
end

local function CountInvited()
    local n = 0
    for _, entry in ipairs(queue) do
        if entry.status == "invited" then n = n + 1 end
    end
    return n
end

local function CanInvite()
    if not IsInGroup() then return true end
    if UnitIsGroupLeader("player") then return true end
    if IsInRaid() and UnitIsGroupAssistant("player") then return true end
    return false
end

function Invites:InviteNow(entry)
    if not CanInvite() then
        self.blocked = L["Only the group leader (or a raid assistant) can invite."]
        Changed()
        return false
    end
    local capacity = IsInRaid() and 40 or 5
    local used = math.max(GetNumGroupMembers() or 0, 1) + CountInvited()
    if used >= capacity then
        if not IsInRaid() and IsInGroup() and UnitIsGroupLeader("player") and C_PartyInfo.ConvertToRaid then
            C_PartyInfo.ConvertToRaid()
            self.blocked = L["Turning the party into a raid..."]
        else
            self.blocked = IsInRaid() and L["The raid is full."] or L["The party is full: waiting for someone to join before making it a raid."]
        end
        Changed()
        return false
    end
    self.blocked = nil
    C_PartyInfo.InviteUnit(entry.name)
    entry.status = "invited"
    entry.invitedAt = GetTime()
    lastInvite = GetTime()
    Changed()
    return true
end

function Invites:InviteNext()
    for _, entry in ipairs(queue) do
        if entry.status == "queued" then return self:InviteNow(entry) end
    end
    return false
end

-- Right away mode: one invite at a time, a little apart.
function Invites:Process()
    if not active or not Settings().auto then return end
    if GetTime() - lastInvite < THROTTLE then return end
    self:InviteNext()
end

-- Listening --------------------------------------------------------------------------------

-- source: "guild", "ally" or "whisper". Allied senders are already checked by the messaging layer.
function Invites:OnChat(sender, text, source)
    if not active or type(sender) ~= "string" or IsSecret(sender) then return end
    if ns.IsMe(sender) or not self:IsKeyword(text) then return end
    if source ~= "ally" and not ns.Guild:IsMember(sender) then return end
    -- Allied players only when asked: their "+1" may answer a call in their own guild.
    if source == "ally" and not Settings().allied then return end
    if source == "guild" and Settings().guild == false then return end
    if GroupKeys()[ns.NameKey(sender)] then return end
    Add(sender, source)
end

ns.On("CHAT_MSG_GUILD", function(text, sender)
    if ns.Guild:IsSandbox() then return end -- debug mode: never the real guild chat
    Invites:OnChat(sender, text, "guild")
end)

ns.On("CHAT_MSG_WHISPER", function(text, sender)
    if not Settings().whispers then return end
    Invites:OnChat(sender, text, "whisper")
end)

-- System messages: answers to our invites. Built from the game's own (translated) texts.
local function Pattern(format)
    if type(format) ~= "string" then return nil end
    local s = format:gsub("%%s", "\001")                       -- the name goes where "%s" is
    s = s:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")         -- everything else is literal
    s = s:gsub("\001", "(.+)")
    return "^" .. s .. "$"
end

local RESULTS = {
    { "ERR_ALREADY_IN_GROUP_S", "busy" },
    { "ERR_DECLINE_GROUP_S", "declined" },
    { "ERR_BAD_PLAYER_NAME_S", "offline" },
    { "ERR_JOINED_GROUP_S", "joined" },
    { "ERR_RAID_MEMBER_ADDED_S", "joined" },
}

ns.On("CHAT_MSG_SYSTEM", function(text)
    if #queue == 0 or type(text) ~= "string" or IsSecret(text) then return end
    for _, def in ipairs(RESULTS) do
        local pattern = Pattern(_G[def[1]])
        local name = pattern and text:match(pattern)
        if name then
            local entry = Find(ns.NameKey(name))
            if entry then Finish(entry, def[2]) end
            return
        end
    end
end)

ns.On("GROUP_ROSTER_UPDATE", function()
    if #queue == 0 then return end
    local inGroup = GroupKeys()
    for i = #queue, 1, -1 do
        if inGroup[queue[i].key] then Finish(queue[i], "joined") end
    end
end)

-- On / off ---------------------------------------------------------------------------------

function Invites:IsActive() return active end

function Invites:MinutesLeft()
    return math.max(0, math.ceil((activeUntil - GetTime()) / 60))
end

-- Who else is inviting: each runner says so on the hidden addon channel (never in the guild
-- chat people read) when starting, every few minutes while on, when changing keywords and when
-- stopping. The queue page shows "2 others are inviting" (names and keywords in its tooltip).
local RUNNER_BEAT = 120   -- seconds between two "still inviting"
local RUNNER_GONE = 330   -- not heard from for this long: no longer inviting (closed the game)
local runners = {}        -- [nameKey] = { name, words, tag, seen }

local function SendRunning(on)
    local words = {}
    if on then
        for i, word in ipairs(Invites:GetSet().words) do
            if i > 8 then break end
            words[i] = word:sub(1, 20)
        end
    end
    local payload = { on = on or nil, w = on and words or nil }
    ns.Comm:Send("INVITING", payload)
    if ns.Alliance:IsActive() then ns.Comm:SendAlly("INVITING", payload) end
end

local function OnRunning(sender, p, isSelf, scope)
    if isSelf or type(p) ~= "table" then return end
    local key = ns.NameKey(sender)
    if not p.on then
        if runners[key] then runners[key] = nil Changed() end
        return
    end
    local words = {}
    for i, word in ipairs(type(p.w) == "table" and p.w or {}) do
        if i > 8 then break end
        if type(word) == "string" and word ~= "" then words[#words + 1] = word:sub(1, 20) end
    end
    runners[key] = { name = sender, words = words, seen = GetTime(),
        tag = scope == "ally" and ns.Alliance:GetTag(p.g) or nil }
    Changed()
end
ns.Comm:On("INVITING", function(sender, p, isSelf) OnRunning(sender, p, isSelf, "guild") end)
ns.Comm:OnAlly("INVITING", function(sender, p, isSelf) OnRunning(sender, p, isSelf, "ally") end)

-- Test mode: pretend two others are inviting, to see the queue page: one on "+1" and "inv"
-- (the usual set's words: the orange "also uses"), one on "+2" from an allied guild.
function Invites:FakeRunners(on)
    for key, r in pairs(runners) do
        if r.fake then runners[key] = nil end
    end
    if on then
        local tag = "ALLY"
        for _, g in ipairs(ns.Alliance:GetGuilds()) do
            if not ns.Guild:IsMyGuild(g.name) then tag = g.tag break end
        end
        runners["fake:1"] = { name = "Gaspard Lenoir", words = { "+1", "inv" }, seen = math.huge, fake = true }
        runners["fake:2"] = { name = "Ysolde Marchal", words = { "+2" }, tag = tag, seen = math.huge, fake = true }
    end
    Changed()
end

function Invites:HasFakeRunners()
    for _, r in pairs(runners) do
        if r.fake then return true end
    end
    return false
end

-- The others inviting right now: { name, words, tag, shared = the words they share with my set }.
function Invites:GetRunners()
    local out, mine = {}, {}
    for _, word in ipairs(self:GetSet().words) do mine[Normalize(word)] = true end
    for key, r in pairs(runners) do
        if GetTime() - r.seen > RUNNER_GONE then
            runners[key] = nil
        else
            local shared = {}
            for _, word in ipairs(r.words) do
                if mine[Normalize(word)] then shared[#shared + 1] = word end
            end
            out[#out + 1] = { name = r.name, words = r.words, tag = r.tag, shared = shared }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Who may use auto-invite: the officers decide in the Guild Info (LT:ai line: some ranks, or
-- nobody; no line: everyone). Players who can edit the Guild Info always may (they set it).
-- Test mode: the rule applies to everyone, with my real rank, so it can be tried.
function Invites:IsAllowed()
    if not ns.Guild:IsSandbox() and CanEditGuildInfo and CanEditGuildInfo() then return true end
    local rule = ns.Alliance:GetAutoInvite()
    if rule == nil then return true end
    if rule == "off" then return false end
    local _, _, rank = GetGuildInfo("player")
    -- Test mode outside a real guild: the test guild has no ranks, count me as guild master.
    if rank == nil and ns.Guild:IsSandbox() then rank = 0 end
    return rank ~= nil and rule[rank] == true
end

function Invites:Start()
    if not self:IsAllowed() then
        ns.Print(L["Your officers have turned auto-invite off for your rank."])
        return
    end
    active = true
    activeUntil = GetTime() + math.max(1, tonumber(Settings().autoOff) or 30) * 60
    self.blocked = nil
    ns.Print(L["Auto-invite started: guild members who type a keyword get an invite."])
    SendRunning(true)
    Changed()
end

function Invites:Stop(reason)
    if not active then return end
    active = false
    for i = #queue, 1, -1 do
        if queue[i].status == "queued" then table.remove(queue, i) end
    end
    ns.Print(reason or L["Auto-invite stopped."])
    SendRunning(false)
    Changed()
end

function Invites:Toggle()
    if active then self:Stop() else self:Start() end
end

ns.commands.autoinvite = function() Invites:Toggle() end

Invites.SendRunning = SendRunning

function Invites:OnLogin()
    -- The officers took it away while it runs: stop.
    ns.Alliance:OnChange(function()
        if active and not Invites:IsAllowed() then
            Invites:Stop(L["Auto-invite stopped: your officers have turned it off for your rank."])
        end
    end)
    -- Still inviting (so the others don't drop me), and forget runners who went quiet.
    C_Timer.NewTicker(RUNNER_BEAT, function()
        if active then SendRunning(true) end
        local before = 0
        for _ in pairs(runners) do before = before + 1 end
        if #Invites:GetRunners() ~= before then Changed() end
    end)
    C_Timer.NewTicker(0.3, function()
        -- Invites nobody answered (also after a stop: they'd wait forever otherwise)
        for i = #queue, 1, -1 do
            local entry = queue[i]
            if entry.status == "invited" and GetTime() - (entry.invitedAt or 0) > INVITE_TIMEOUT then
                Finish(entry, "noanswer")
            end
        end
        if not active then return end
        if GetTime() >= activeUntil then
            Invites:Stop(L["Auto-invite turned itself off (time limit)."])
            return
        end
        Invites:Process()
    end)
end

-- Auto-invite pages ----------------------------------------------------------------------------
-- Queue (the main one): start / stop, the session options, the queue and the last results.
-- Settings: keywords and the time limit. No separate window: while it's on, the side tab shows
-- how many are waiting, and in "when I click" mode each new player gets a chat line with a link.

local RESULT_TEXT = {
    joined = "joined", busy = "already in a group", declined = "declined",
    offline = "offline or not found", noanswer = "no answer", removed = "removed",
}
local SOURCE_TEXT = { guild = "guild chat", ally = "allied guild", whisper = "whisper" }

local listeners = {}
function Invites:OnChange(fn) listeners[#listeners + 1] = fn end
Invites.onChange = function()
    for _, fn in ipairs(listeners) do fn() end
end

-- "x min left" and "2 min ago" stay current while a page shows them.
local tickers = {}
C_Timer.NewTicker(15, function()
    for _, p in ipairs(tickers) do if p:IsShown() then p:Refresh() end end
end)

function ns.BuildInvitesPanel()
    local K = ns.UIKit
    local p = K.NewPanel()

    K.NewPageTitle(p, L["Auto-invite"], { L["Auto-invite"],
        L["Guild members who type a keyword alone in guild chat (or allied guild chat) get a group invite. Handy for big events: everyone types +1."],
        L["Always off when you log in, and it turns itself off after a while (Settings)."] })

    -- Start / Stop: the one thing most people come here for. While on it's green and counts
    -- down: "Stop (28 min)".
    local toggle = K.NewButton(p, "", 150, 24)
    toggle:SetPoint("TOPRIGHT", -2, -4)
    toggle:SetScript("OnClick", function() Invites:Toggle() end)
    -- The settings page, in place of this one (Back returns).
    local settings = K.NewButton(p, L["Settings"], 110, 24)
    settings:SetPoint("RIGHT", toggle, "LEFT", -8, 0)
    settings:SetScript("OnClick", function() ns.UI:ShowPage("autoinviteSettings") end)

    -- The options: a grid of two rows under the title. A gold label column (Keywords, Listen
    -- to), then three columns: the keyword list takes two, Invite right away the third, right
    -- above Whispers. A thin line under it, then the queue.
    local PAD_X, LABEL_W, COL_W = 8, 96, 165
    local ROW1_Y, ROW_H = -54, 34
    local ROW2_Y = ROW1_Y - ROW_H
    local function ColX(i) return PAD_X + LABEL_W + (i - 1) * COL_W end
    local function Place(widget, x, y)
        widget:ClearAllPoints()
        widget:SetPoint("LEFT", p, "TOPLEFT", x, y) -- LEFT: centered on the row
    end

    -- Right of the "Listen to" row: the others inviting right now ("2 others are inviting"), who
    -- and with which keywords in its tooltip. Orange when one of them uses one of my keywords.
    local others = K.NewLabel(p, "", "GameFontHighlight")
    others:SetPoint("RIGHT", p, "TOPRIGHT", -8, ROW2_Y)
    local othersHit = CreateFrame("Frame", nil, p)
    othersHit:SetAllPoints(others)
    othersHit:EnableMouse(true)
    othersHit:SetScript("OnEnter", function(self)
        local list = Invites:GetRunners()
        if #list == 0 then return end
        local lines, overlap = { L["Inviting right now"] }, false
        for _, r in ipairs(list) do
            local mine = {}
            for _, word in ipairs(r.shared) do mine[word] = true end
            local words = {}
            for i, word in ipairs(r.words) do
                words[i] = (mine[word] and "|cffff9900" or "|cff808080") .. word .. "|r"
            end
            overlap = overlap or #r.shared > 0
            lines[#lines + 1] = r.name .. (r.tag and (" |cff8fb8e8[" .. r.tag .. "]|r") or "")
                .. "   " .. (#words > 0 and table.concat(words, ", ") or "?")
        end
        if overlap then
            lines[#lines + 1] = "|cffff9900" .. L["Orange: your keywords too."] .. "|r"
        end
        K.ShowTooltip(self, lines)
    end)
    othersHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Row 1: how invites go out, and the keyword set in use.
    local auto = K.NewCheckbox(p, L["Invite right away"], function(self)
        ns.db.invites.auto = self:GetChecked() and true or false
        Changed()
    end)
    Place(auto, ColX(3) - 4, ROW1_Y)
    auto:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Invite right away"], L["Ticked: the queue sends the invites on its own. Unticked: they wait for you to click Invite."] })
    end)
    auto:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local setLabel = K.NewLabel(p, L["Keywords"], "GameFontNormal")
    Place(setLabel, PAD_X, ROW1_Y)
    local setChoice = K.NewChoice(p, COL_W * 2 - 16, function()
            local out = {}
            for i, set in ipairs(Sets()) do out[#out + 1] = { text = set.name, value = i } end
            return out
        end, function() return Settings().set end, function(i) Invites:UseSet(i) end,
        { L["Keywords"], L["The set of keywords you answer to. Each leader can use their own (+1 for one group, +2 for another), or all the same one. Edit them in Settings."] })
    Place(setChoice, ColX(1), ROW1_Y)

    -- Row 2: where to listen. Guild chat, the allied guilds (only with an alliance), whispers.
    local listenLabel = K.NewLabel(p, L["Listen to"], "GameFontNormal")
    Place(listenLabel, PAD_X, ROW2_Y)
    local guild = K.NewCheckbox(p, L["Guild chat"], function(self)
        ns.db.invites.guild = self:GetChecked() and true or false
        Changed()
    end)
    Place(guild, ColX(1) - 4, ROW2_Y)
    local allied = K.NewCheckbox(p, L["Allied guilds"], function(self)
        ns.db.invites.allied = self:GetChecked() and true or false
        Changed()
    end)
    Place(allied, ColX(2) - 4, ROW2_Y)
    local whispers = K.NewCheckbox(p, L["Whispers"], function(self)
        ns.db.invites.whispers = self:GetChecked() and true or false
        Changed()
    end)
    allied:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Allied guilds"],
            L["A keyword typed by an allied player in the shared guild chat puts them in the queue. Off: only your guild (their +1 may answer someone in their own guild)."] })
    end)
    allied:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Whispers in the third column, under Invite right away (also without an alliance).
    Place(whispers, ColX(3) - 4, ROW2_Y)

    local divider = p:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.42, 0.35, 0.23, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", p, "TOPLEFT", PAD_X, ROW2_Y - 24)
    divider:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD_X, ROW2_Y - 24)

    local blocked = K.NewLabel(p, "", "GameFontRedSmall")
    blocked:SetPoint("TOPLEFT", 8, ROW2_Y - 30)
    blocked:SetPoint("RIGHT", p, "RIGHT", -8, 0)
    blocked:SetJustifyH("LEFT")

    -- Two columns, both the full height: the queue on the left (its buttons under it), the last
    -- results on the right.
    local SPLIT = 0.6 -- share of the width for the queue
    -- A dark box with a border around a list (and its scroll bar): two clear columns, left blank
    -- when empty.
    local function Framed(column, list)
        local frame = CreateFrame("Frame", nil, column, "BackdropTemplate")
        frame:SetPoint("TOPLEFT", list, "TOPLEFT", -4, 4)
        frame:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 18, -4)
        frame:SetFrameLevel(column:GetFrameLevel())
        if frame.SetBackdrop then
            frame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            frame:SetBackdropColor(0, 0, 0, 0.35)
            frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        end
    end
    local left = CreateFrame("Frame", nil, p)
    left:SetPoint("TOPLEFT", 0, ROW2_Y - 46)
    left:SetPoint("BOTTOM", p, "BOTTOM", 0, 0)
    local right = CreateFrame("Frame", nil, p)
    right:SetPoint("TOPRIGHT", 0, ROW2_Y - 46)
    right:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 16, 0)
    p:SetScript("OnSizeChanged", function(self, w) if w and w > 0 then left:SetWidth(w * SPLIT) end end)
    left:SetWidth(440)

    -- Queue: one row per player, name on top and "invited · guild chat · 2 min ago" under it,
    -- Invite and ✕ on the right.
    local queueHeader = K.NewLabel(left, "", "GameFontNormal")
    queueHeader:SetPoint("TOPLEFT", 8, 0)
    local box = K.NewScrollList(left, 38, function(row, entry)
        if not row.init then
            row.init = true
            K.RowBackground(row)
            row.name = K.NewLabel(row, "")
            row.name:SetPoint("TOPLEFT", 8, -4)
            row.info = K.NewLabel(row, "", "GameFontDisableSmall")
            row.info:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
            row.remove = K.NewIconButton(row, "remove", L["Remove from the queue"])
            row.remove:SetPoint("RIGHT", -10, 0)
            row.invite = K.NewButton(row, L["Invite"], 80, 22)
            row.invite:SetPoint("RIGHT", row.remove, "LEFT", -10, 0)
            row.info:SetPoint("RIGHT", row.invite, "LEFT", -8, 0)
            row.info:SetJustifyH("LEFT")
            row.info:SetWordWrap(false)
            row.remove:SetScript("OnClick", function() Invites:Remove(row.entry.name) end)
            row.invite:SetScript("OnClick", function() Invites:InviteNow(row.entry) end)
        end
        row.entry = entry
        local member = ns.Guild:GetMember(entry.name)
        row.name:SetText(K.ClassColored(entry.name, member and member.class))
        local status = entry.status == "invited" and ("|cffffd100" .. L["invited"] .. "|r") or L["waiting"]
        local source = L[SOURCE_TEXT[entry.source] or entry.source]
        if entry.source == "ally" and ns.Vouch and ns.Vouch:GetState(entry.name) == "unverified" then
            source = source .. " |cffff9900(" .. L["not checked yet"] .. ")|r"
        end
        row.info:SetText(status .. "  \194\183  " .. source .. "  \194\183  " .. K.Ago(entry.time))
        row.invite:SetShown(entry.status == "queued")
    end)
    box:SetPoint("TOPLEFT", 4, -22)
    box:SetPoint("BOTTOMRIGHT", -20, 40)
    Framed(left, box)

    local nextButton = K.NewButton(left, L["Invite next"], 160)
    nextButton:SetPoint("BOTTOMLEFT", 2, 4)
    nextButton:SetScript("OnClick", function() Invites:InviteNext() end)
    local clear = K.NewButton(left, L["Clear the queue"], 160)
    clear:SetPoint("LEFT", nextButton, "RIGHT", 8, 0)
    clear:SetScript("OnClick", function() Invites:Clear() end)

    -- Last results: newest first, the result in color.
    local RESULT_COLOR = { joined = "20ff20", declined = "ff9900", busy = "ff9900", offline = "ff4040",
        noanswer = "808080", removed = "808080" }
    K.NewLabel(right, L["Last results"], "GameFontNormal"):SetPoint("TOPLEFT", 8, 0)
    local recentBox = K.NewScrollList(right, 34, function(row, r)
        if not row.init then
            row.init = true
            K.RowBackground(row)
            row.name = K.NewLabel(row, "")
            row.name:SetPoint("TOPLEFT", 8, -3)
            row.name:SetPoint("RIGHT", -8, 0)
            row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)
            row.result = K.NewLabel(row, "", "GameFontHighlightSmall")
            row.result:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        end
        local member = ns.Guild:GetMember(r.name)
        row.name:SetText(K.ClassColored(r.name, member and member.class))
        row.result:SetText("|cff808080" .. date("%H:%M", r.time) .. "|r  |cff" .. (RESULT_COLOR[r.result] or "ffffff")
            .. L[RESULT_TEXT[r.result] or r.result] .. "|r")
    end)
    recentBox:SetPoint("TOPLEFT", 4, -22)
    recentBox:SetPoint("BOTTOMRIGHT", -20, 40)
    Framed(right, recentBox)
    local clearResults = K.NewButton(right, L["Clear the results"], 160)
    clearResults:SetPoint("BOTTOMLEFT", 2, 4)
    clearResults:SetScript("OnClick", function() Invites:ClearResults() end)

    function p:Refresh()
        local s = ns.db.invites
        local queued = 0
        for _, entry in ipairs(queue) do if entry.status == "queued" then queued = queued + 1 end end
        if active then
            toggle:SetText("|cff20ff20" .. format(L["Stop (%d min)"], Invites:MinutesLeft()) .. "|r")
        else
            toggle:SetText(L["Start"])
        end
        auto:SetChecked(s.auto)
        if setChoice.GenerateMenu then setChoice:GenerateMenu() end
        local runners, overlap = Invites:GetRunners(), false
        for _, r in ipairs(runners) do overlap = overlap or #r.shared > 0 end
        local count = #runners == 1 and L["1 other is inviting"] or format(L["%d others are inviting"], #runners)
        others:SetText(#runners == 0 and "" or ((overlap and "|cffff9900" or "|cffd0d0d0") .. count .. "|r"))
        guild:SetChecked(s.guild ~= false)
        whispers:SetChecked(s.whispers)
        allied:SetShown(ns.Alliance:IsActive())
        allied:SetChecked(s.allied == true)
        -- Listening to nothing: say so (it's on, but nobody can get in).
        local deaf = s.guild == false and not s.whispers and not (s.allied and ns.Alliance:IsActive())
        local why = Invites.blocked or (deaf and L["Not listening anywhere: tick guild chat, whispers or allied guilds."]) or ""
        blocked:SetText(why)
        queueHeader:SetText(#queue > 0 and format(L["Queue (%d)"], #queue) or L["Queue"])
        K.SetListData(box, queue)
        nextButton:SetEnabled(queued > 0)
        clear:SetEnabled(#queue > 0)
        K.SetListData(recentBox, recent)
        clearResults:SetEnabled(#recent > 0)
    end
    Invites:OnChange(function() if p:IsShown() then p:Refresh() end end)
    tickers[#tickers + 1] = p
    return p
end

function ns.BuildInvitesSettingsPanel()
    local K = ns.UIKit
    local p = K.NewPanel()
    K.NewPageTitle(p, L["Auto-invite settings"])
    local back = K.NewButton(p, L["Back"], 100, 24)
    back:SetPoint("TOPRIGHT", -2, -4)
    back:SetScript("OnClick", function() ns.UI:ShowPage("autoinvite") end)
    -- Nothing applies while typing: Save applies the fields, Cancel puts the saved ones back.
    local dirty = false
    local editing = Settings().set or 1 -- the keyword set shown below
    local function Typed() dirty = true p:Refresh() end

    -- "Turn off after [30] minutes", on one line
    local offLabel = K.NewLabel(p, L["Turn off after"])
    offLabel:SetPoint("TOPLEFT", 16, -48)
    local minutes = K.NewInput(p, 40, 3)
    minutes:SetPoint("LEFT", offLabel, "RIGHT", 12, 0)
    minutes:SetNumeric(true)
    minutes:SetJustifyH("CENTER")
    minutes:SetScript("OnTextChanged", function(_, user) if user then Typed() end end)
    K.NewLabel(p, L["minutes"]):SetPoint("LEFT", minutes, "RIGHT", 6, 0)

    -- Keyword sets: pick one to edit, New, Delete; then its name and its words.
    local setsHeader = K.NewLabel(p, L["Keyword sets"], "GameFontNormal")
    setsHeader:SetPoint("TOPLEFT", 8, -86)
    local setsInfo = K.NewInfoIcon(p, { L["Keyword sets"],
        L["Several leaders can invite at once: each picks a set on the queue page. One set per group (+1, +2...), or everyone on the same set for a free-for-all."],
        L["Only a message made of the keyword alone counts: \"inv\" yes, \"who can inv Bob?\" no."],
        L["Not case-sensitive. A final ! or ? is ignored."] })
    setsInfo:SetPoint("LEFT", setsHeader, "RIGHT", 6, 0)
    local pick = K.NewChoice(p, 200, function()
            local out = {}
            for i, set in ipairs(Sets()) do out[#out + 1] = { text = set.name, value = i } end
            return out
        end, function() return editing end, function(i)
            -- Another set: unsaved changes to this one are dropped.
            editing = i
            dirty = false
            p:Refresh()
        end)
    pick:SetPoint("TOPLEFT", 12, -108)
    local newSet = K.NewButton(p, L["New set"], 110, 24)
    newSet:SetPoint("LEFT", pick, "RIGHT", 10, 0)
    newSet:SetScript("OnClick", function()
        local sets = Sets()
        sets[#sets + 1] = { name = format(L["Set %d"], #sets + 1), words = {} }
        editing = #sets
        dirty = false
        p:Refresh()
    end)
    local deleteSet = K.NewButton(p, L["Delete"], 100, 24)
    deleteSet:SetPoint("LEFT", newSet, "RIGHT", 6, 0)
    deleteSet:SetScript("OnClick", function()
        local sets = Sets()
        if #sets <= 1 then return end
        table.remove(sets, editing)
        -- The set in use moves with the list (or goes back to the first).
        local s = Settings()
        if s.set == editing then s.set = 1 elseif s.set > editing then s.set = s.set - 1 end
        editing = math.min(editing, #sets)
        dirty = false
        Changed()
        p:Refresh()
    end)
    K.WithTooltip(deleteSet, { L["Delete"], L["Deletes the set shown. The last one can't be deleted."] })

    local nameLabel = K.NewLabel(p, L["Name"])
    nameLabel:SetPoint("TOPLEFT", 16, -146)
    local name = K.NewInput(p, 200, 24)
    name:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
    name:SetScript("OnTextChanged", function(_, user) if user then Typed() end end)

    local wordsLabel = K.NewLabel(p, L["Keywords (one per line)"])
    wordsLabel:SetPoint("TOPLEFT", 16, -178)
    local words = K.NewTextArea(p, 260, 180)
    words:SetPoint("TOPLEFT", 12, -196)
    words.edit:SetScript("OnTextChanged", function(_, user) if user then Typed() end end)

    -- Bottom bar: unsaved changes (or "saved") on the left, Cancel and Save on the right.
    local save = K.NewButton(p, L["Save"], 140, 26)
    save:SetPoint("BOTTOMRIGHT", -2, 6)
    local cancel = K.NewButton(p, L["Cancel"], 120, 26)
    cancel:SetPoint("RIGHT", save, "LEFT", -8, 0)
    local message = K.NewLabel(p, "", "GameFontHighlightSmall")
    message:SetPoint("LEFT", p, "BOTTOMLEFT", 8, 19)
    message:SetPoint("RIGHT", cancel, "LEFT", -10, 0)
    message:SetJustifyH("LEFT")
    local savedAt

    save:SetScript("OnClick", function()
        local n = tonumber(minutes:GetText())
        if n and n >= 1 then ns.db.invites.autoOff = n end
        local set = Sets()[editing]
        if set then
            local list = {}
            for line in (words.edit:GetText() .. "\n"):gmatch("(.-)\r?\n") do
                line = strtrim(line)
                if line ~= "" then list[#list + 1] = line end
            end
            set.words = list
            local typed = strtrim(name:GetText() or "")
            if typed ~= "" then set.name = typed end
        end
        minutes:ClearFocus()
        name:ClearFocus()
        words.edit:ClearFocus()
        dirty = false
        savedAt = GetTime()
        if active and editing == Settings().set then SendRunning(true) end -- the others see my new words
        Changed()
        C_Timer.After(3.1, function() if p:IsShown() then p:Refresh() end end)
        p:Refresh()
    end)
    cancel:SetScript("OnClick", function()
        minutes:ClearFocus()
        name:ClearFocus()
        words.edit:ClearFocus()
        dirty = false
        p:Refresh()
    end)

    function p:Refresh()
        local s = ns.db.invites
        local sets = Sets()
        if not sets[editing] then editing = s.set or 1 end
        local set = sets[editing]
        if pick.GenerateMenu then pick:GenerateMenu() end
        deleteSet:SetEnabled(#sets > 1)
        -- The saved settings, unless I'm in the middle of changing them.
        if not dirty then
            minutes:SetText(tostring(s.autoOff))
            name:SetText(set.name or "")
            words.edit:SetText(table.concat(set.words, "\n"))
        end
        save:SetEnabled(dirty)
        cancel:SetEnabled(dirty)
        if dirty then
            message:SetText("|cffff9900" .. L["Changes not saved yet."] .. "|r")
        elseif #set.words == 0 then
            message:SetText("|cffff9900" .. L["This set has no keywords yet: nobody gets in with it."] .. "|r")
        elseif savedAt and GetTime() - savedAt < 3 then
            message:SetText("|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t |cff40ff40" .. L["Settings saved."] .. "|r")
        else
            message:SetText("")
        end
    end
    return p
end

-- Who may use auto-invite, a step of the Configuration page (players who can edit the Guild
-- Info): everyone, some ranks, or nobody. The page saves it with the rest (an LT:ai line).
-- box:GetRule() the choice shown, box:Reset() back to the Guild Info, box:Refresh();
-- onChange() when the player changes it. Its height follows the rank list.
function ns.NewAutoInviteRule(parent, onChange)
    local K = ns.UIKit
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(600, 40)

    local draft -- { mode = "all" | "ranks" | "off", ranks = { [rankIndex] = true } }, nil: the saved one
    local function Saved()
        local rule = ns.Alliance:GetAutoInvite()
        if rule == "off" then return { mode = "off", ranks = {} } end
        if type(rule) == "table" then return { mode = "ranks", ranks = CopyTable(rule) } end
        return { mode = "all", ranks = {} }
    end
    local function Draft()
        draft = draft or Saved()
        return draft
    end

    function box:GetRule()
        local d = Draft()
        return d.mode == "off" and "off" or (d.mode == "ranks" and d.ranks) or nil
    end
    function box:Reset() draft = nil end

    local mode = K.NewChoice(box, 220, {
            { text = L["Everyone"], value = "all" },
            { text = L["Only some ranks"], value = "ranks" },
            { text = L["Nobody"], value = "off" },
        }, function() return Draft().mode end, function(m)
            Draft().mode = m
            onChange()
        end)
    mode:SetPoint("TOPLEFT", 10, 0)

    -- One checkbox per guild rank (the game's names, guild master first), in two columns.
    local RANK_ROW, RANK_COL = 26, 200
    local rankChecks = {}
    for i = 1, 10 do
        local cb = K.NewCheckbox(box, "", function(self)
            Draft().ranks[i - 1] = self:GetChecked() and true or nil
            onChange()
        end)
        cb:SetPoint("TOPLEFT", 6 + ((i - 1) % 2) * RANK_COL, -30 - math.floor((i - 1) / 2) * RANK_ROW)
        cb:Hide()
        rankChecks[i] = cb
    end

    function box:Refresh()
        if mode.GenerateMenu then mode:GenerateMenu() end
        local d = Draft()
        local real = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
        -- Test mode outside a real guild: five plain ranks to try it with.
        if real == 0 and ns.Guild:IsSandbox() then real = 5 end
        local count = d.mode == "ranks" and math.min(10, real) or 0
        for i, cb in ipairs(rankChecks) do
            local shown = i <= count
            cb:SetShown(shown)
            if shown then
                local name = GuildControlGetRankName and GuildControlGetRankName(i) or ""
                if cb.Text then cb.Text:SetText(name ~= "" and name or format(L["Rank %d"], i - 1)) end
                cb:SetChecked(d.ranks[i - 1] == true)
            end
        end
        self:SetHeight(28 + math.ceil(count / 2) * RANK_ROW)
    end
    return box
end
