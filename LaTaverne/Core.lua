local ADDON, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMeta and GetMeta(ADDON, "Version")) or "?"

-- Chattynator replaces the chat windows with its own and only collects the lines written to the
-- main one: its tabs pick what they show (a tab's settings, Add-ons).
function ns.UsingChattynator()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return loaded and loaded("Chattynator") and true or false
end

-- The chat window chosen in Options (its number), when it still exists; nil: the main one
-- (always with Chattynator: a line written to another window would be lost).
function ns.ChatWindow()
    local i = ns.db and ns.db.chatWindow
    if not i or not GetChatWindowInfo or ns.UsingChattynator() then return nil end
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
    local f = _G["ChatFrame" .. i]
    if f and f.AddMessage and name and name ~= "" and (shown or docked) then return f end
    return nil
end

function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    -- The Nation du Québec lynx, then the addon's name.
    local text = "|TInterface\\AddOns\\LaTaverne\\media\\lynx_icon:0|t |cffd4a017La Taverne|r: " .. table.concat(parts, " ")
    local f = ns.ChatWindow()
    if f then f:AddMessage(text) else print(text) end
end

-- Quiet in dungeons, raids and combat (Options): no new group alerts, no sounds.
function ns.Quiet()
    if not (ns.db and ns.db.quiet) then return false end
    if (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) then return true end
    local inside, kind = IsInInstance()
    return (inside and (kind == "party" or kind == "raid")) and true or false
end

-- The gamepad UI is on. Then La Taverne doesn't open or close the game's windows: the gamepad
-- manager follows them, and its protected calls from addon code get blocked (ADDON_ACTION_FORBIDDEN).
function ns.GamepadUI()
    return InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() and true or false
end

-- La Taverne's sounds. kind: "group" (a new group alert, if its sound is on), "request" (my
-- group: someone asks to join or accepts, if that sound is on), "notice" (invited, my
-- availability ends), "posted" (I listed a group: the game's joining a queue sound), "invite"
-- (a group invites me, if that sound is on: on the Master channel, like the game's ready
-- check, so it's heard with sound effects turned down). None while quiet.
function ns.Sound(kind)
    if ns.Quiet() or not SOUNDKIT then return end
    if kind == "group" and not ns.db.alertSound then return end
    if kind == "request" and ns.db.requestSound == false then return end
    if kind == "invite" and ns.db.inviteSound == false then return end
    local id
    if kind == "group" then id = SOUNDKIT.UI_GROUP_FINDER_RECEIVE_APPLICATION or SOUNDKIT.READY_CHECK
    elseif kind == "posted" then id = SOUNDKIT.PVP_ENTER_QUEUE
    elseif kind == "invite" then id = SOUNDKIT.LFG_ROLE_CHECK or SOUNDKIT.READY_CHECK
    else id = SOUNDKIT.READY_CHECK end
    if not id then return end
    if kind == "invite" then PlaySound(id, "Master") else PlaySound(id) end
end

-- Names ----------------------------------------------------------------------
-- Forever has no realms: UnitName returns first name and last name, and the game
-- writes a player as "Firstname Lastname" (roster, addon message sender, invites).

function ns.FullName(unit)
    local name, last = UnitName(unit or "player")
    if not name then return nil end
    if last and last ~= "" then
        return name .. " " .. last
    end
    return name
end

-- Am I away (AFK)? true / false, or nil when the game won't say: in some states (a fight, an
-- encounter) it gives a secret value that an addon can't even test.
function ns.IsAway()
    if not UnitIsAFK then return false end
    local afk = UnitIsAFK("player")
    if issecretvalue and issecretvalue(afk) then return nil end
    return afk and true or false
end

-- Comparison key for a name: trimmed, lowercase.
function ns.NameKey(name)
    if not name then return nil end
    return strtrim(name):lower()
end

function ns.IsMe(name)
    return ns.NameKey(name) == ns.NameKey(ns.FullName("player"))
end

-- Players seen with La Taverne, remembered two weeks so the Alliance page lists them while
-- they're offline: ns.db[field][guild of mine][nameKey] = { name, seen, ... }, test guilds
-- apart. field: "guildSeen" (my guild's members), "allySeen" (allied players). Nothing in it
-- is trusted, it's only a name and a time. nil while my guild isn't known yet.
ns.SEEN_KEEP = 14 * 24 * 3600
function ns.SeenMemory(field)
    local mine = ns.Guild:GetName()
    if not mine or mine == "" then return nil end
    local key = (ns.Guild:IsSandbox() and "test:" or "") .. mine:lower()
    ns.db[field] = ns.db[field] or {}
    ns.db[field][key] = ns.db[field][key] or {}
    return ns.db[field][key]
end

-- Forget the ones not seen for two weeks (left, changed guild, stopped playing). At login.
function ns.PruneSeen(field)
    local now = GetServerTime()
    for _, memory in pairs(ns.db[field] or {}) do
        for key, item in pairs(memory) do
            if type(item) ~= "table" or not item.seen or now - item.seen > ns.SEEN_KEEP then memory[key] = nil end
        end
    end
end

-- In a party or raid I made (not a battleground or the game's dungeon finder group).
function ns.InParty()
    return IsInGroup(LE_PARTY_CATEGORY_HOME or 1) and true or false
end

-- On my in-game ignore list (the game's list, compared by name).
function ns.IsIgnored(name)
    if not name or not C_FriendList or not C_FriendList.GetNumIgnores then return false end
    local key = ns.NameKey(name)
    for i = 1, C_FriendList.GetNumIgnores() or 0 do
        local ignored = C_FriendList.GetIgnoreName(i)
        if ignored and ns.NameKey(ignored) == key then return true end
    end
    return false
end

-- Versions: -1, 0 or 1 when a is older, the same, or newer than b ("0.21.0").
function ns.CompareVersions(a, b)
    local pa, pb = {}, {}
    for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
    for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

-- Events and modules -----------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function ns.On(event, fn)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(eventHandlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(eventHandlers[event]) do
        fn(...)
    end
end)

-- Modules get OnInit (saved variables loaded) and OnLogin (player in the world).
ns.modules = {}

function ns.NewModule(name)
    local module = { name = name }
    ns.modules[#ns.modules + 1] = module
    ns[name] = module
    return module
end

-- Saved variables ----------------------------------------------------------------

local DEFAULTS = {
    notify = true,    -- chat line when a new group is posted
    advanced = false, -- Advanced mode (Options): the guild relay's tab, beside Alliance
    showAnnounces = true, -- chat line when a leader clicks "Announce in chat"
    minimap = {},     -- LibDBIcon position and visibility
    chars = {},       -- per character: [fullName] = { listing = ... }
    allyChat = {
        enabled = true,  -- share guild chat with the allied guilds
        showTag = true,  -- allied guild's tag in front of the name
        showLynx = true, -- the lynx in front of allied lines
        markRelayed = true, -- relayed lines (authors without La Taverne): grey lynx, or a grey dot
        markTold = false,   -- the line explaining that mark was shown once
    },
    allyLog = {},
    allyMap = {       -- guild and allied players on the world map (AllyMap.lua)
        share = true,      -- my position goes to my guild and the allied guilds
        showGuild = true,  -- dots for my guild's members
        showAllies = true, -- dots for the allied guilds' members
        button = true,     -- the lynx button on the game's map (not with OpenMap's map)
        told = false,      -- the "your position is shared" line was shown once
    },
    relay = {         -- guild relay (Relay.lua)
        help = true,         -- I may relay my guild for the allied guilds
        told = false,        -- the "you're relaying" line was shown once
    },
    invites = {       -- keyword auto-invite (always off at login)
        auto = true,      -- invite right away, or wait for a click
        whispers = false, -- also listen to whispers
        allied = false,   -- also listen to the allied guilds (shared guild chat)
        autoOff = 30,     -- minutes before it turns itself off
        -- Keyword sets (sets, set: the one in use) are made in Invites.lua: an array of sets
        -- here would come back after the player deletes one.
        guild = true,     -- listen to guild chat
    },     -- recent allied lines, for the guild window: { t, a, c, g, tag, m }
    dev = {
        -- Sandbox: all traffic goes to a private test channel instead of the guild,
        -- and the guild is simulated (fake name, info text and roster). Off for a new install;
        -- once switched on it's saved and stays on until switched off.
        sandbox = false,
        guildName = "Taverne Test",
        infoText = "",
        roster = {}, -- [nameKey] = { name = "Firstname Lastname", class, level, seen }
        gameChat = true, -- test guild chat also shown in the game's chat windows (only to me)
        lynxFast = false, -- the window's lynx: short pauses between its moves (Debug tab)
        -- Message log window: types and senders not listed ({ [key] = true }), auto-refresh.
        msgLogHiddenTypes = {},
        msgLogHiddenSenders = {},
        msgLogAuto = false,
        msgLogAlways = false, -- the message log records from every login (not only in test mode)
    },
}

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            if type(value) == "table" then
                target[key] = {}
                ApplyDefaults(target[key], value)
            else
                target[key] = value
            end
        elseif type(value) == "table" and type(target[key]) == "table" then
            ApplyDefaults(target[key], value)
        end
    end
end

-- What La Taverne remembers about other players (vouching evidence, guild rosters saved by my
-- characters, players seen with La Taverne): forgotten by /taverne clearcache (Dev.lua), and once
-- by itself when CACHE_VERSION changes. Raise CACHE_VERSION only in a release that changes how
-- these are stored, or when what older versions saved is known to be wrong; not at every version
-- (the vouching evidence takes time to gather again).
ns.CACHE_FIELDS = { "vouchLedger", "rosterSnapshots", "allySeen", "guildSeen" }
local CACHE_VERSION = 1

function ns.ClearCache()
    for _, field in ipairs(ns.CACHE_FIELDS) do ns.db[field] = nil end
end

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    LaTaverneDB = LaTaverneDB or {}
    ApplyDefaults(LaTaverneDB, DEFAULTS)
    ns.db = LaTaverneDB
    -- Saved before cache versions existed: taken as the current one (nothing known to be wrong).
    if ns.db.cacheVersion ~= nil and ns.db.cacheVersion ~= CACHE_VERSION then ns.ClearCache() end
    ns.db.cacheVersion = CACHE_VERSION
    for _, module in ipairs(ns.modules) do
        if module.OnInit then module:OnInit() end
    end
end)

ns.On("PLAYER_LOGIN", function()
    for _, module in ipairs(ns.modules) do
        if module.OnLogin then module:OnLogin() end
    end
end)

-- Log buffer: every line is printed to chat and kept for the copy window.
ns.log = {}

function ns.Log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    local line = table.concat(parts, " ")
    ns.log[#ns.log + 1] = line
    ns.Print(line)
    ns.UpdateCopyWindow()
end

-- Copy window: a selectable text box so test output can be copied with Ctrl+A, Ctrl+C.
local copyFrame

local function BuildCopyWindow()
    local f = CreateFrame("Frame", "LaTaverneCopyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(600, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("La Taverne - test output (Ctrl+A, Ctrl+C)")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", "LaTaverneCopyScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -40)
    scroll:SetPoint("BOTTOMRIGHT", -36, 18)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(540)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)

    f.edit = edit
    tinsert(UISpecialFrames, "LaTaverneCopyFrame")
    copyFrame = f
end

function ns.ShowCopyWindow()
    if not copyFrame then BuildCopyWindow() end
    copyFrame.edit:SetText(table.concat(ns.log, "\n"))
    copyFrame:Show()
    copyFrame.edit:SetFocus()
    copyFrame.edit:HighlightText()
end

function ns.UpdateCopyWindow()
    if copyFrame and copyFrame:IsShown() then
        copyFrame.edit:SetText(table.concat(ns.log, "\n"))
        copyFrame.edit:HighlightText()
    end
end

-- Text dialog: a title, a hint, a text box (to copy from or paste into) and an optional button.
-- opts = { title, hint, text, button, onButton(text), selectAll }
local textDialog

local function BuildTextDialog()
    local f = CreateFrame("Frame", "LaTaverneTextDialog", UIParent, "ButtonFrameTemplate")
    f:SetSize(600, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(f) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(f) end
    if ButtonFrameTemplate_HideAttic then ButtonFrameTemplate_HideAttic(f) end
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    tinsert(UISpecialFrames, "LaTaverneTextDialog")

    local inner = f.Inset or f
    f.hint = inner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.hint:SetPoint("TOPLEFT", 12, -10)
    f.hint:SetPoint("RIGHT", -12, 0)
    f.hint:SetJustifyH("LEFT")

    local holder = CreateFrame("Frame", nil, inner, "BackdropTemplate")
    holder:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", -2, -10)
    holder:SetPoint("BOTTOMRIGHT", -10, 44)
    if holder.SetBackdrop then
        holder:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        holder:SetBackdropColor(0, 0, 0, 0.5)
        holder:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end
    local scroll = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(530)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() edit:SetFocus() end)
    f.edit = edit

    f.button = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    f.button:SetSize(160, 24)
    f.button:SetPoint("BOTTOMRIGHT", -10, 12)
    f.button:SetScript("OnClick", function()
        local fn = f.onButton
        if fn and fn(edit:GetText()) ~= false then f:Hide() end
    end)
    -- No Close button: the X in the corner (and Escape) close it.
    f.holder = holder
    f.scroll = scroll
    -- Auto-fill (see TextDialog): a key in the text box pauses it a moment (Ctrl+A, Ctrl+C), and
    -- a text box scrolled to the bottom stays at the bottom when the text grows.
    if edit:HasScript("OnKeyDown") then
        edit:HookScript("OnKeyDown", function() f.keyAt = GetTime() end)
    end
    if scroll:HasScript("OnScrollRangeChanged") then
        scroll:HookScript("OnScrollRangeChanged", function(self, _, yrange)
            if f.followBottom then self:SetVerticalScroll(yrange or self:GetVerticalScrollRange()) end
        end)
    end
    textDialog = f
end

local AUTO_EVERY, AUTO_PAUSE = 2, 5 -- seconds

local function AutoFill(f, elapsed)
    f.autoWait = f.autoWait - elapsed
    if f.autoWait > 0 then return end
    f.autoWait = f.autoEvery or AUTO_EVERY
    -- Not while the player is selecting, scrolling or copying.
    if f.holder:IsMouseOver() or (f.keyAt and GetTime() - f.keyAt < AUTO_PAUSE) then return end
    local text = f.autoFill() or ""
    if text == f.edit:GetText() then return end
    local scroll = f.scroll
    f.followBottom = scroll:GetVerticalScroll() >= scroll:GetVerticalScrollRange() - 2
    f.edit:SetText(text)
end

-- A row under the hint (message log): dropdowns (Menu.lua) and checkboxes.
local function SetupTools(f, opts)
    local menus = opts.menus or {}
    local checks = opts.checks or (opts.check and { opts.check }) or {}
    local tools = f.tools
    if not tools then
        if #menus == 0 and #checks == 0 then return false end
        tools = CreateFrame("Frame", nil, f.Inset or f)
        tools:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", -2, -8)
        tools:SetPoint("RIGHT", -12, 0)
        tools:SetHeight(26)
        tools.menus = {}
        tools.checks = {}
        f.tools = tools
    end
    for i, def in ipairs(menus) do
        local dd = tools.menus[i]
        if not dd then
            dd = ns.NewDropdown(tools)
            dd:SetScript("OnEnter", function(self)
                if self.tooltip and ns.UIKit then ns.UIKit.ShowTooltip(self, self.tooltip) end
            end)
            dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
            tools.menus[i] = dd
        end
        dd:ClearAllPoints()
        if i == 1 then dd:SetPoint("LEFT", 0, 0) else dd:SetPoint("LEFT", tools.menus[i - 1], "RIGHT", 8, 0) end
        dd:SetWidth(def.width or 160)
        dd.tooltip = def.tooltip
        dd:SetDefaultText(def.text)
        dd:SetupMenu(def.generator)
        dd:Show()
    end
    for i = #menus + 1, #tools.menus do tools.menus[i]:Hide() end
    -- Checkboxes after the dropdowns, each after the label of the one before.
    local after = tools.menus[#menus]
    for i, def in ipairs(checks) do
        local cb = tools.checks[i]
        if not cb and ns.UIKit then
            cb = ns.UIKit.NewCheckbox(tools, "", function(self)
                if self.onCheck then self.onCheck(self:GetChecked() and true or false) end
            end)
            cb:SetScript("OnEnter", function(self)
                if self.tip then ns.UIKit.ShowTooltip(self, self.tip) end
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            tools.checks[i] = cb
        end
        if cb then
            cb:ClearAllPoints()
            local label = after and (after.Text or after.text)
            if label and i > 1 then
                cb:SetPoint("LEFT", label, "RIGHT", 16, 0)
            elseif after then
                cb:SetPoint("LEFT", after, "RIGHT", 12, 0)
            else
                cb:SetPoint("LEFT", 0, 0)
            end
            cb.Text:SetText(def.text)
            cb:SetChecked(def.checked and true or false)
            cb.onCheck, cb.tip = def.onClick, def.tooltip
            cb:Show()
            after = cb
        end
    end
    for i = #checks + 1, #tools.checks do tools.checks[i]:Hide() end
    local shown = #menus > 0 or #checks > 0
    tools:SetShown(shown)
    return shown
end

-- Is the text window showing that kind of text?
function ns.TextDialogShown(kind)
    return textDialog ~= nil and textDialog:IsShown() and textDialog.kind == kind
end

-- Close the text window if it's still showing that kind (opts.kind) of text.
function ns.CloseTextDialog(kind)
    if textDialog and textDialog:IsShown() and textDialog.kind == kind then textDialog:Hide() end
end

-- Select all of the text window's text, ready for Ctrl+C (a Copy button). Its auto-fill waits a
-- moment, as after a key in it, so the selection stays.
function ns.SelectTextDialog()
    if not (textDialog and textDialog:IsShown()) then return end
    textDialog.keyAt = GetTime()
    textDialog.edit:SetFocus()
    textDialog.edit:HighlightText()
end

function ns.TextDialog(opts)
    if not textDialog then BuildTextDialog() end
    local f = textDialog
    f.kind = opts.kind
    if f.SetTitle then f:SetTitle(opts.title or "La Taverne") end
    f.hint:SetText(opts.hint or "")
    f.edit:SetText(opts.text or "")
    f.onButton = opts.onButton
    f.button:SetShown(opts.button ~= nil)
    if opts.button then f.button:SetText(opts.button) end
    -- A checkbox left of that button (message log: Auto-refresh, next to Refresh):
    -- opts.buttonCheck = { text, checked, onClick = function(checked), tooltip = { lines } }.
    local bc = opts.buttonCheck
    if bc and not f.buttonCheck and ns.UIKit then
        f.buttonCheck = ns.UIKit.NewCheckbox(f.button:GetParent(), "", function(self)
            if self.onCheck then self.onCheck(self:GetChecked() and true or false) end
        end)
        f.buttonCheck:SetScript("OnEnter", function(self)
            if self.tip then ns.UIKit.ShowTooltip(self, self.tip) end
        end)
        f.buttonCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if f.buttonCheck then
        f.buttonCheck:SetShown(bc ~= nil and opts.button ~= nil)
        if bc then
            f.buttonCheck.Text:SetText(bc.text)
            f.buttonCheck:SetChecked(bc.checked and true or false)
            f.buttonCheck.onCheck, f.buttonCheck.tip = bc.onClick, bc.tooltip
            -- Its label ends a little before the button, and the box sits left of its label:
            -- anchored that way, nothing needs measuring (a hidden label can read 0 wide).
            local label = f.buttonCheck.Text
            label:ClearAllPoints()
            label:SetPoint("RIGHT", f.button, "LEFT", -12, 0)
            f.buttonCheck:ClearAllPoints()
            f.buttonCheck:SetPoint("RIGHT", label, "LEFT", -2, 0)
            -- (its label clicks like the box: the area is measured again once the window is shown)
            C_Timer.After(0, function()
                local w = label:GetStringWidth() or 0
                if w > 0 then f.buttonCheck:SetHitRectInsets(0, -(w + 4), 0, 0) end
            end)
        end
    end
    -- A second button, bottom left, that fills the text box (e.g. "From GuildUnion"):
    -- opts.extra = { text, fill = function() return text end, enabled, tooltip = { lines } }.
    if not f.extra then
        f.extra = CreateFrame("Button", nil, f.Inset or f, "UIPanelButtonTemplate")
        f.extra:SetSize(180, 24)
        f.extra:SetPoint("BOTTOMLEFT", 10, 12)
        f.extra:SetMotionScriptsWhileDisabled(true)
        f.extra:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local extra = opts.extra
    f.extra:SetShown(extra ~= nil)
    if extra then
        f.extra:SetText(extra.text)
        f.extra:SetEnabled(extra.enabled ~= false)
        f.extra:SetScript("OnClick", function()
            f.edit:SetText(extra.fill() or "")
            f.edit:SetFocus()
        end)
        f.extra:SetScript("OnEnter", function(self)
            if extra.tooltip and ns.UIKit then ns.UIKit.ShowTooltip(self, extra.tooltip) end
        end)
    end
    -- A row of tools under the hint (message log): opts.menus = { { text, generator, width,
    -- tooltip = { lines } } } (dropdowns, text: the label), opts.check = { text, checked,
    -- onClick = function(checked), tooltip = { lines } }.
    f:SetWidth(opts.width or 600) -- (the message log asks for more: its row of tools)
    f.edit:SetWidth((opts.width or 600) - 70) -- (the text wraps at the window's width)
    if SetupTools(f, opts) then
        f.holder:SetPoint("TOPLEFT", f.tools, "BOTTOMLEFT", 0, -6)
    else
        f.holder:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", -2, -10)
    end
    -- opts.autoFill = function() return text end: the text box is filled again every AUTO_EVERY
    -- seconds (opts.autoEvery: another period) when the text changed (message log's auto-refresh).
    f.autoEvery = opts.autoEvery
    f.autoFill, f.autoWait, f.followBottom = opts.autoFill, opts.autoEvery or AUTO_EVERY, false
    f:SetScript("OnUpdate", opts.autoFill and AutoFill or nil)
    -- The text box goes down to the bottom when there's no button under it.
    f.holder:SetPoint("BOTTOMRIGHT", -10, opts.button and 44 or 10)
    f:Show()
    f.edit:SetFocus()
    if opts.selectAll then f.edit:HighlightText() end
end

-- Confirmation window: the text window's frame with a message and buttons instead of the text
-- box, at the top of the screen like the game's. Not the game's own dialogs: opened by an addon,
-- they break the gamepad UI (ADDON_ACTION_FORBIDDEN). One window per kind, so one can't replace
-- another. opts = { kind, text, buttons = { { text, onClick } } }; text can be a function, read
-- again while the window is open. A button runs its onClick (if any) and closes the window;
-- Escape and the X only close it.
local confirmDialogs = {}

-- Escape closes every frame of UISpecialFrames at once: with a menu or a confirm window open
-- over La Taverne's window, Escape closed both. While one of them is open, the main window
-- leaves that list, so Escape closes only the menu or the confirm window.
local escapeHolds = 0
local function MainOnEscape(on)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == "LaTaverneFrame" then tremove(UISpecialFrames, i) end
    end
    if on and _G.LaTaverneFrame then tinsert(UISpecialFrames, "LaTaverneFrame") end
end
function ns.EscapeFirst(f)
    f:HookScript("OnShow", function()
        escapeHolds = escapeHolds + 1
        MainOnEscape(false)
    end)
    f:HookScript("OnHide", function()
        escapeHolds = math.max(0, escapeHolds - 1)
        if escapeHolds == 0 then MainOnEscape(true) end
    end)
end

local function BuildConfirmDialog(kind)
    local f = CreateFrame("Frame", "LaTaverneConfirm_" .. kind, UIParent, "ButtonFrameTemplate")
    f:SetWidth(440)
    f:SetPoint("TOP", 0, -135)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(f) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(f) end
    if ButtonFrameTemplate_HideAttic then ButtonFrameTemplate_HideAttic(f) end
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    if f.SetTitle then f:SetTitle("La Taverne") end
    tinsert(UISpecialFrames, f:GetName())
    ns.EscapeFirst(f)

    local inner = f.Inset or f
    f.text = inner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOP", 0, -14)
    f.text:SetWidth(400)
    f.buttons = {}
    f:SetScript("OnUpdate", function(self)
        local text = type(self.getText) == "function" and self.getText()
        if text then self.text:SetText(text) end
    end)
    confirmDialogs[kind] = f
    return f
end

function ns.ConfirmDialog(opts)
    local f = confirmDialogs[opts.kind] or BuildConfirmDialog(opts.kind)
    f.getText = opts.text
    local text = opts.text
    if type(text) == "function" then text = text() end
    f.text:SetText(text or "")
    local inner = f.Inset or f
    local n = #opts.buttons
    for i, spec in ipairs(opts.buttons) do
        local b = f.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
            b:SetSize(120, 24)
            f.buttons[i] = b
        end
        b:SetText(spec.text)
        b:ClearAllPoints()
        b:SetPoint("BOTTOM", (i - (n + 1) / 2) * 128, 12)
        b:SetScript("OnClick", function()
            f:Hide()
            if spec.onClick then spec.onClick() end
        end)
        b:Show()
    end
    for i = n + 1, #f.buttons do f.buttons[i]:Hide() end
    f:SetHeight(f.text:GetStringHeight() + 96)
    f:Show()
end

function ns.CloseConfirmDialog(kind)
    local f = confirmDialogs[kind]
    if f and f:IsShown() then f:Hide() end
end

-- Slash commands: modules add handlers to ns.commands.
ns.commands = {}

SLASH_LATAVERNE1 = "/taverne"
SlashCmdList.LATAVERNE = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    local handler = ns.commands[cmd]
    if handler then
        handler(rest or "")
    elseif cmd == "" then
        ns.UI:Toggle()
    else
        ns.Print("v" .. ns.version .. " - commands:")
        ns.Print("/taverne - open or close the window")
        ns.Print("/taverne autoinvite - turn keyword auto-invite on or off")
        ns.Print("/taverne errors [clear] - error report to send to the author")
        ns.Print("/taverne relay - guild relay report: who relays for each guild, and how it goes")
        ns.Print("/taverne debug - everything useful about a problem, in one text to copy and send")
        ns.Print("/taverne clearcache - forget remembered players (vouching, guild rosters), then reload")
        -- Testing and diagnostics: listed only in test mode (they still work outside it).
        if ns.db and ns.db.dev and ns.db.dev.sandbox then
            ns.Print("Test mode:")
            ns.Print("/taverne dev - test mode (sandbox) status and settings")
            ns.Print("/taverne g <text> - fake guild chat")
            ns.Print("/taverne ally - allied guilds: what was read from the guild info")
            ns.Print("/taverne map - positions on the map: what's shared and shown")
            ns.Print("/taverne test [all|env|api|names|guild|chan] - run diagnostics")
            ns.Print("/taverne who <name> - look a name up in the guild roster")
            ns.Print("/taverne probe - relay measurements (list)")
            ns.Print("/taverne copy - reopen the output window")
        end
    end
end
