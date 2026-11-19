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

function Invites:Start()
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

local function KeywordsText()
    local words = Invites:GetSet().words
    local shown = {}
    for i = 1, math.min(#words, 3) do shown[i] = words[i] end
    return table.concat(shown, ", ") .. (#words > 3 and ", ..." or "")
end

function ns.BuildInvitesPanel()
    local K = ns.UIKit
    local p = K.NewPanel()

    K.NewPageTitle(p, L["Auto-invite"], { L["Auto-invite"],
        L["Guild members who type a keyword alone in guild chat (or allied guild chat) get a group invite. Handy for big events: everyone types +1."],
        L["Always off when you log in, and it turns itself off after a while (Settings)."] })

    -- Start / Stop: the one thing most people come here for.
    local toggle = K.NewButton(p, "", 140, 24)
    toggle:SetPoint("TOPRIGHT", -2, -4)
    toggle:SetScript("OnClick", function() Invites:Toggle() end)
    -- The settings page, in place of this one (Back returns).
    local settings = K.NewButton(p, L["Settings"], 110, 24)
    settings:SetPoint("RIGHT", toggle, "LEFT", -8, 0)
    settings:SetScript("OnClick", function() ns.UI:ShowPage("autoinviteSettings") end)

    -- Right of the state line: the others inviting right now ("2 others are inviting"), who and
    -- with which keywords in its tooltip. Orange when one of them uses one of my keywords.
    local others = K.NewLabel(p, "", "GameFontHighlight")
    others:SetPoint("TOPRIGHT", -8, -40)
    local othersHit = CreateFrame("Frame", nil, p)
    othersHit:SetAllPoints(others)
    othersHit:EnableMouse(true)
    othersHit:SetScript("OnEnter", function(self)
        local list = Invites:GetRunners()
        if #list == 0 then return end
        local lines, overlap = { L["Inviting right now"] }, false
        for _, r in ipairs(list) do
            local words = #r.words > 0 and table.concat(r.words, ", ") or "?"
            lines[#lines + 1] = r.name .. (r.tag and (" |cff8fb8e8[" .. r.tag .. "]|r") or "") .. "  |cff808080" .. words .. "|r"
            if #r.shared > 0 then
                overlap = true
                lines[#lines + 1] = "|cffff9900   " .. format(L["also uses %s"], table.concat(r.shared, ", ")) .. "|r"
            end
        end
        if overlap then
            lines[#lines + 1] = L["Same keyword: whoever types it gets several invites and joins the first one accepted. Fine for a free-for-all; for separate groups, use different sets."]
        end
        K.ShowTooltip(self, lines)
    end)
    othersHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local state = K.NewLabel(p, "", "GameFontHighlight")
    state:SetPoint("TOPLEFT", 8, -40)
    state:SetPoint("RIGHT", others, "LEFT", -12, 0)
    state:SetJustifyH("LEFT")
    state:SetWordWrap(false)

    -- Row 1: how invites go out, and the keyword set in use.
    local auto = K.NewCheckbox(p, L["Invite right away"], function(self)
        ns.db.invites.auto = self:GetChecked() and true or false
        Changed()
    end)
    auto:SetPoint("TOPLEFT", 4, -60)
    auto:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Invite right away"], L["Ticked: the queue sends the invites on its own. Unticked: they wait for you to click Invite."] })
    end)
    auto:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local setLabel = K.NewLabel(p, L["Keywords"])
    setLabel:SetPoint("TOPLEFT", 300, -66)
    local setChoice = K.NewChoice(p, 200, function()
            local out = {}
            for i, set in ipairs(Sets()) do out[#out + 1] = { text = set.name, value = i } end
            return out
        end, function() return Settings().set end, function(i) Invites:UseSet(i) end,
        { L["Keywords"], L["The set of keywords you answer to. Each leader can use their own (+1 for one group, +2 for another), or all the same one. Edit them in Settings."] })
    setChoice:SetPoint("LEFT", setLabel, "RIGHT", 10, 0)

    -- Row 2: where to listen.
    local listenLabel = K.NewLabel(p, L["Listen to"])
    listenLabel:SetPoint("TOPLEFT", 8, -98)
    local guild = K.NewCheckbox(p, L["Guild chat"], function(self)
        ns.db.invites.guild = self:GetChecked() and true or false
        Changed()
    end)
    guild:SetPoint("LEFT", listenLabel, "RIGHT", 10, 0)
    local whispers = K.NewCheckbox(p, L["Whispers"], function(self)
        ns.db.invites.whispers = self:GetChecked() and true or false
        Changed()
    end)
    whispers:SetPoint("LEFT", guild.Text or guild, "RIGHT", 24, 0)
    -- Only with a Guild Alliance.
    local allied = K.NewCheckbox(p, L["Allied guilds"], function(self)
        ns.db.invites.allied = self:GetChecked() and true or false
        Changed()
    end)
    allied:SetPoint("LEFT", whispers.Text or whispers, "RIGHT", 24, 0)
    allied:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Allied guilds"],
            L["A keyword typed by an allied player in the shared guild chat puts them in the queue. Off: only your guild (their +1 may answer someone in their own guild)."] })
    end)
    allied:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local blocked = K.NewLabel(p, "", "GameFontRedSmall")
    blocked:SetPoint("TOPLEFT", 8, -124)
    blocked:SetPoint("RIGHT", p, "RIGHT", -8, 0)
    blocked:SetJustifyH("LEFT")

    -- Two columns, both the full height: the queue on the left (its buttons under it), the last
    -- results on the right.
    local SPLIT = 0.6 -- share of the width for the queue
    local left = CreateFrame("Frame", nil, p)
    left:SetPoint("TOPLEFT", 0, -142)
    left:SetPoint("BOTTOM", p, "BOTTOM", 0, 0)
    local right = CreateFrame("Frame", nil, p)
    right:SetPoint("TOPRIGHT", 0, -142)
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
    box:SetPoint("TOPLEFT", 0, -20)
    box:SetPoint("BOTTOMRIGHT", -20, 36)
    local empty = K.NewLabel(left, "", "GameFontDisable")
    empty:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -16)
    empty:SetPoint("RIGHT", box, "RIGHT", -10, 0)
    empty:SetJustifyH("LEFT")

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
    recentBox:SetPoint("TOPLEFT", 0, -20)
    recentBox:SetPoint("BOTTOMRIGHT", -20, 4)
    local nothing = K.NewLabel(right, "|cff808080" .. L["Nothing yet"] .. "|r", "GameFontDisable")
    nothing:SetPoint("TOPLEFT", recentBox, "TOPLEFT", 10, -16)

    function p:Refresh()
        local s = ns.db.invites
        local queued = 0
        for _, entry in ipairs(queue) do if entry.status == "queued" then queued = queued + 1 end end
        if active then
            toggle:SetText(L["Stop"])
            state:SetText("|cff40ff40" .. L["On"] .. "|r  \194\183  " .. L["turns itself off in %d min"]:format(Invites:MinutesLeft())
                .. "  \194\183  " .. L["keywords:"] .. " |cffffffff" .. KeywordsText() .. "|r")
        else
            toggle:SetText(L["Start"])
            state:SetText("|cff808080" .. L["Off"] .. "|r  \194\183  " .. L["always off when you log in"]
                .. (CountInvited() > 0 and ("  \194\183  " .. L["waiting for the last answers"]) or ""))
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
        empty:SetShown(#queue == 0)
        empty:SetText(active and L["Nobody yet."] or L["Start auto-invite: players who type a keyword show up here."])
        nextButton:SetEnabled(queued > 0)
        clear:SetEnabled(#queue > 0)
        K.SetListData(recentBox, recent)
        nothing:SetShown(#recent == 0)
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
