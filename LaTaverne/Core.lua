local ADDON, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMeta and GetMeta(ADDON, "Version")) or "?"

-- The chat window chosen in Options (its number), when it still exists; nil: the main one.
function ns.ChatWindow()
    local i = ns.db and ns.db.chatWindow
    if not i or not GetChatWindowInfo then return nil end
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
    local f = _G["ChatFrame" .. i]
    if f and f.AddMessage and name and name ~= "" and (shown or docked) then return f end
    return nil
end

function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local text = "|cffd4a017La Taverne|r: " .. table.concat(parts, " ")
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

-- La Taverne's sounds. kind: "group" (a new group alert, if its sound is on), "request" (my
-- group: someone asks to join or accepts, if that sound is on), "notice" (invited, my
-- availability ends). None while quiet.
function ns.Sound(kind)
    if ns.Quiet() or not SOUNDKIT then return end
    if kind == "group" and not ns.db.alertSound then return end
    if kind == "request" and ns.db.requestSound == false then return end
    local id = kind == "group" and (SOUNDKIT.UI_GROUP_FINDER_RECEIVE_APPLICATION or SOUNDKIT.READY_CHECK)
        or SOUNDKIT.READY_CHECK
    if id then PlaySound(id) end
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

-- Comparison key for a name: trimmed, lowercase.
function ns.NameKey(name)
    if not name then return nil end
    return strtrim(name):lower()
end

function ns.IsMe(name)
    return ns.NameKey(name) == ns.NameKey(ns.FullName("player"))
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
    minimap = {},     -- LibDBIcon position and visibility
    chars = {},       -- per character: [fullName] = { listing = ... }
    allyChat = {
        enabled = true,  -- share guild chat with the allied guilds
        showTag = true,  -- allied guild's tag in front of the name
    },
    allyLog = {},
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

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    LaTaverneDB = LaTaverneDB or {}
    ApplyDefaults(LaTaverneDB, DEFAULTS)
    ns.db = LaTaverneDB
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
    textDialog = f
end

-- Close the text window if it's still showing that kind (opts.kind) of text.
function ns.CloseTextDialog(kind)
    if textDialog and textDialog:IsShown() and textDialog.kind == kind then textDialog:Hide() end
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
    -- The text box goes down to the bottom when there's no button under it.
    f.holder:SetPoint("BOTTOMRIGHT", -10, opts.button and 44 or 10)
    f:Show()
    f.edit:SetFocus()
    if opts.selectAll then f.edit:HighlightText() end
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
        ns.Print("/taverne dev - test mode (sandbox) status and settings")
        ns.Print("/taverne ally - allied guilds: what was read from the guild info")
        ns.Print("/taverne g <text> - fake guild chat (test mode)")
        ns.Print("/taverne test [all|env|api|names|guild|chan] - run diagnostics")
        ns.Print("/taverne who <name> - look a name up in the guild roster")
        ns.Print("/taverne autoinvite - turn keyword auto-invite on or off")
        ns.Print("/taverne errors [clear] - error report to send to the author")
        ns.Print("/taverne copy - reopen the output window")
    end
end
