-- Main window, built from Blizzard's own templates so it looks like the default UI.
-- Side tabs (sections) on the right edge; a section's other pages open from a button on its page:
-- - Groups: open guild groups (invitations on top) and My group (post / manage / member view),
--           one page for the player: My group while in a group of the finder, the list otherwise
-- - Availability: my availability, the dungeons asked for, who's available
-- - Alliance: the Guild Alliance as members see it; Setup (a button, only for players who can
--             edit the Guild Info)
-- - Auto-invite: the queue, and its Settings (a button) (Invites.lua)
-- - Options: keyboard shortcut, minimap button, new group alerts, shared guild chat, errors
-- - Test mode: test mode only (DebugUI.lua)
-- Every page starts with the same header: title on the left (explanations in a ⓘ tooltip),
-- main actions on the right.
local ADDON, ns = ...
local UI = ns.NewModule("UI")
local L = ns.L

local TITLE = "La Taverne"
local BINDING = "LATAVERNE_TOGGLE"
local frame
local panels = {}

-- Helpers -----------------------------------------------------------------------------

local function ClassColored(name, class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. name .. "|r"
    end
    return name
end

-- Class icon from the class circles texture (exists on every client).
function ns.ClassIcon(class)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not coords then return "" end
    return format("|TInterface\\TargetingFrame\\UI-Classes-Circles:14:14:0:0:256:256:%d:%d:%d:%d|t",
        coords[1] * 256, coords[2] * 256, coords[3] * 256, coords[4] * 256)
end

local CROWN = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:12:12|t"

local function Ago(t)
    local seconds = GetServerTime() - (t or 0)
    if seconds < 60 then return L["just now"] end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return format(L["%d min ago"], minutes) end
    local hours = math.floor(minutes / 60)
    if hours < 48 then return format(L["%d h ago"], hours) end
    return format(L["%d d ago"], math.floor(hours / 24))
end

-- isGuest: true ("not in guild"), or an allied guild's tag ("[TA]"), or nothing.
local function GuestTag(isGuest)
    if type(isGuest) == "string" then return " |cff8fb8e8[" .. isGuest .. "]|r" end
    return isGuest and (" |cff808080(" .. L["not in guild"] .. ")|r") or ""
end

local function NameText(name, class, isGuest, isNewbie)
    return ns.ClassIcon(class) .. " " .. ClassColored(name, class) .. GuestTag(isGuest)
        .. (isNewbie and (" " .. ns.NewbieIcon(14)) or "")
end

local function RoleText(role)
    return role and (ns.RoleIcon(role) .. " " .. ns.RoleLabel(role)) or ""
end

local function MyClass()
    local _, class = UnitClass("player")
    return class
end

local function LeaderClass(l)
    local m = l.members[ns.NameKey(l.leader)]
    return m and m.class
end

-- Small icons for the group flags. The game's own atlases when the client has them.
local function AtlasIcon(atlas, fallback, size)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) and CreateAtlasMarkup then
        return CreateAtlasMarkup(atlas, size, size)
    end
    return "|T" .. fallback .. ":" .. size .. ":" .. size .. "|t"
end

-- New player (the newcomer leaf of the game's guide system), Discord (headset).
function ns.NewbieIcon(size)
    return AtlasIcon("newplayerchat-chaticon-newcomer", "Interface\\Icons\\INV_Misc_Herb_Peacebloom", size or 14)
end

function ns.DiscordIcon(size)
    return AtlasIcon("voicechat-icon-headphone-on", "Interface\\Common\\VoiceChat-Speaker", size or 14)
end

-- Where the group is at, as a short colored tag ("" while it's simply looking for players).
-- In progress: grey when complete, orange while it looks for a replacement (still joinable).
local function StateTag(l)
    local state = ns.Groups:GetState(l)
    if state == "running" then return "|cff808080" .. L["In progress"] .. "|r" end
    if state == "full" then return "|cff808080" .. L["Full"] .. "|r" end
    if state == "midrun" then return "|cffff9900" .. L["In progress"] .. "|r" end
    return ""
end

-- The group's flags, as icons, and the lines for their tooltip.
local function FlagIcons(l)
    local icons = ""
    if l.newbies then icons = icons .. ns.NewbieIcon(16) .. " " end
    if l.discord then icons = icons .. ns.DiscordIcon(16) .. " " end
    return icons
end

local function FlagLines(l)
    local lines = {}
    if l.newbies then lines[#lines + 1] = ns.NewbieIcon(14) .. " " .. L["New players welcome"] end
    if l.discord then
        local channel = l.discordChannel and l.discordChannel ~= "" and (": |cffffffff" .. l.discordChannel .. "|r") or ""
        lines[#lines + 1] = ns.DiscordIcon(14) .. " " .. L["Discord required"] .. channel
    end
    return lines
end

local function DungeonTitle(l)
    local size = ns.Groups:GetSize(l)
    local sizeText = size ~= 5 and (" |cffffd100(" .. size .. ")|r") or ""
    local range = ns.DungeonRange(ns.DungeonByKey(l.dungeon))
    local state = StateTag(l)
    return ns.DungeonName(l.dungeon) .. sizeText .. (range ~= "" and (" " .. range) or "")
        .. "  |cff808080" .. Ago(l.created) .. "|r"
        .. (state ~= "" and ("  " .. state) or "")
end

local function MissingLine(l)
    local parts = {}
    local missing = ns.Groups:MissingRoles(l)
    for _, role in ipairs(ns.Groups.ROLES) do
        local n = missing[role] or 0
        if n > 0 then
            parts[#parts + 1] = ns.RoleIcon(role) .. " " .. ns.RoleLabel(role) .. (n > 1 and (" x" .. n) or "")
        end
    end
    if #parts == 0 then return "|cff20ff20" .. L["Complete"] .. "|r" end
    return "|cffffd100" .. L["Missing:"] .. "|r " .. table.concat(parts, "  ")
end

local function GuildLine()
    local name = ns.Guild:GetName() or "?"
    if ns.Guild:IsSandbox() then
        return "|cffff9900" .. format(L["Test guild: %s"], name) .. "|r"
    end
    return format(L["Guild: %s"], name)
end

local function NewPanel()
    local p = CreateFrame("Frame", nil, frame.Inset)
    p:SetPoint("TOPLEFT", 8, -8)
    p:SetPoint("BOTTOMRIGHT", -8, 8)
    p:Hide()
    return p
end

local function NewButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, height or 22)
    b:SetText(text)
    return b
end

local function NewLabel(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if text then fs:SetText(text) end
    return fs
end

local function NewCheckbox(parent, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    local label = cb.Text or cb.text
    if not label then
        label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        cb.Text = label
    end
    -- Same size as the other labels (the template's text is smaller).
    label:SetFontObject(GameFontHighlight)
    -- The label is part of the checkbox: clicking or hovering it works like the box itself.
    -- Kept up to date when the label changes (the width depends on the text).
    local function CoverLabel()
        cb:SetHitRectInsets(0, -(label:GetStringWidth() + 4), 0, 0)
    end
    hooksecurefunc(label, "SetText", CoverLabel)
    label:SetText(text)
    cb:SetScript("OnClick", onClick)
    return cb
end

-- Puts a checkbox (or any widget) right after another checkbox's label, whatever the
-- label's length in the player's language.
local function PlaceAfterLabel(widget, checkbox, gap)
    local label = checkbox.Text or checkbox.text
    widget:ClearAllPoints()
    if label then
        widget:SetPoint("LEFT", label, "RIGHT", gap or 24, 0)
    else
        widget:SetPoint("LEFT", checkbox, "RIGHT", 200, 0)
    end
end

local function NewInput(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters or 80)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

-- Grey hint inside an empty input (instead of a hint line next to it).
local function SetPlaceholder(box, text)
    local ph = box:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    if box:IsMultiLine() then
        ph:SetPoint("TOPLEFT", 1, -1)
    else
        ph:SetPoint("LEFT", 1, 0)
    end
    ph:SetPoint("RIGHT", -4, 0)
    ph:SetJustifyH("LEFT")
    ph:SetWordWrap(false)
    ph:SetText(text)
    local function Update() ph:SetShown((box:GetText() or "") == "" and not box:HasFocus()) end
    box:HookScript("OnEditFocusGained", Update)
    box:HookScript("OnEditFocusLost", Update)
    box:HookScript("OnTextChanged", Update)
    Update()
    return ph
end

-- Several lines of text in a box with a scroll bar (notes, setup lines).
local function NewTextArea(parent, width, height, maxLetters)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(width, height)
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
    edit:SetWidth(width - 36)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(maxLetters or 1000)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    -- Anchored on both sides (full-width note): the text follows the box's width.
    holder:SetScript("OnSizeChanged", function(_, w) if w and w > 40 then edit:SetWidth(w - 36) end end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() edit:SetFocus() end)
    holder.edit = edit
    return holder
end

local function RowBackground(row)
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 0, -1)
    bg:SetPoint("BOTTOMRIGHT", 0, 1)
    bg:SetColorTexture(1, 1, 1, 0.04)
end

-- Scrolling list with the modern scroll bar. The caller anchors the returned box.
local function NewScrollList(parent, rowHeight, initializer)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    -- rowHeight: a number, or function(elementData) for rows of different heights.
    if type(rowHeight) == "function" and view.SetElementExtentCalculator then
        view:SetElementExtentCalculator(function(_, data) return rowHeight(data) end)
    else
        view:SetElementExtent(type(rowHeight) == "function" and rowHeight({}) or rowHeight)
    end
    view:SetElementInitializer("Frame", initializer)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    -- The scroll bar only shows when the list is longer than its box.
    if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
        ScrollUtil.AddManagedScrollBarVisibilityBehavior(box, bar)
    end
    return box
end

local function SetListData(box, list)
    box:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
end

-- Tooltip: a title, then lines. Paragraphs (a long line, or the one after it) get an empty line
-- between them so they read apart; short lines (a list of dungeons, roles) stay together.
local PARAGRAPH = 50 -- letters (color codes count too: close enough)
local function ShowTooltip(owner, lines)
    if not lines or #lines == 0 then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do
        if i > 2 and (#lines[i] > PARAGRAPH or #lines[i - 1] > PARAGRAPH) then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine(lines[i], 1, 1, 1, true)
    end
    GameTooltip:Show()
end

-- Role icons (the dungeon finder texture) ----------------------------------------------

local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"
local ROLE_COORDS = {
    TANK = { 0, 0.26171875, 0.26171875, 0.5234375 },
    HEALER = { 0.26171875, 0.5234375, 0, 0.26171875 },
    DAMAGER = { 0.26171875, 0.5234375, 0.26171875, 0.5234375 },
}
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function SetRoleTexture(texture, role)
    local coords = role and ROLE_COORDS[role]
    if coords then
        texture:SetTexture(ROLE_TEXTURE)
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        texture:SetTexture(QUESTION_ICON)
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

-- Role spots: one per place in the composition (tanks, healers, then DPS). Members and accepted
-- players fill the spot of their role (accepted at half opacity). Free spots are drawn small and
-- grey, so taken and free read apart at a glance; "1/5" after the spots says it in words.
-- Invited players who haven't answered don't take a spot here.
local MAX_SLOTS = 10
local SLOT_SIZE = 26      -- a taken spot
local FREE_SIZE = 20      -- a free spot, centered in the same cell, greyed
local SLOT_STEP = 29

local function NewSlot(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(SLOT_SIZE, SLOT_SIZE)
    s:EnableMouse(true)
    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetAllPoints()
    s:SetScript("OnEnter", function(self) ShowTooltip(self, self.tooltip) end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return s
end

local function BuildSlots(l)
    local slots = {}
    local composition = ns.Groups:GetComposition(l)
    for _, role in ipairs(ns.Groups.ROLES) do
        for _ = 1, composition[role] or 0 do slots[#slots + 1] = { role = role } end
    end
    local people = {}
    for _, m in ipairs(ns.Groups:GetMembers(l)) do people[#people + 1] = { entry = m, kind = "member" } end
    for _, p in ipairs(ns.Groups:GetPending(l)) do
        if p.status == "accepted" then people[#people + 1] = { entry = p, kind = "accepted" } end
    end
    -- Each player takes a spot of their role; players without a matching spot take any free one.
    local leftovers = {}
    for _, person in ipairs(people) do
        local placed = false
        if person.entry.role then
            for _, s in ipairs(slots) do
                if not s.person and s.role == person.entry.role then
                    s.person = person
                    placed = true
                    break
                end
            end
        end
        if not placed then leftovers[#leftovers + 1] = person end
    end
    for _, person in ipairs(leftovers) do
        for _, s in ipairs(slots) do
            if not s.person then
                s.person = person
                s.role = person.entry.role
                break
            end
        end
    end
    return slots
end

local function RenderSlots(frames, l)
    local leaderKey = ns.NameKey(l.leader)
    local slots = BuildSlots(l)
    for i, f in ipairs(frames) do
        local s = slots[i]
        f:SetShown(s ~= nil)
        if s then
            local person = s.person
            if not person then
                SetRoleTexture(f.icon, s.role)
                f.icon:ClearAllPoints()
                f.icon:SetPoint("CENTER")
                f.icon:SetSize(FREE_SIZE, FREE_SIZE)
                f.icon:SetDesaturated(true)
                f.icon:SetAlpha(0.3)
                f.tooltip = { RoleText(s.role), "|cff808080" .. L["Free spot"] .. "|r" }
            else
                local e = person.entry
                SetRoleTexture(f.icon, e.role)
                f.icon:ClearAllPoints()
                f.icon:SetAllPoints()
                f.icon:SetDesaturated(false)
                f.icon:SetAlpha(person.kind == "member" and 1 or 0.5)
                -- Role first, like a free spot: the header never changes, the player is under it
                local name = NameText(e.name, e.class, e.tag or e.guest)
                if e.key == leaderKey then name = name .. " " .. CROWN end
                f.tooltip = { e.role and RoleText(e.role) or L["Role unknown"], name }
                if person.kind == "accepted" then
                    f.tooltip[#f.tooltip + 1] = L["Accepted, waiting to join"]
                end
            end
        end
    end
    local taken = 0
    for _, s in ipairs(slots) do if s.person then taken = taken + 1 end end
    return #slots, taken
end

-- Role pickers --------------------------------------------------------------------------

local function RoleMenu(owner, title, roles, onPick)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(title)
        for _, role in ipairs(roles) do
            root:CreateButton(RoleText(role), function() onPick(role) end)
        end
    end)
end

-- Missing roles my class can take. Invitations (allIfNone): if none of those fits,
-- offer every role my class can take.
local function RolesForMe(l, allIfNone)
    local missing = ns.Groups:MissingRoles(l)
    local class = MyClass()
    local out, any = {}, {}
    for _, role in ipairs(ns.Groups.ROLES) do
        if ns.CanTakeRole(class, role) then
            any[#any + 1] = role
            if (missing[role] or 0) > 0 then out[#out + 1] = role end
        end
    end
    if #out == 0 and allIfNone then return any end
    return out
end

-- Role picker for a player. getClass returns their class: roles it can't take are disabled.
-- canPlay(role), when given, decides instead (e.g. only the roles the player offered).
local function NewRoleDropdown(parent, width, getRole, setRole, getClass, canPlay)
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(width)
    if dd.SetDefaultText then dd:SetDefaultText(L["Choose a role"]) end
    dd:SetupMenu(function(_, root)
        local class = getClass and getClass()
        for _, role in ipairs(ns.Groups.ROLES) do
            local option = root:CreateRadio(RoleText(role),
                function() return getRole() == role end,
                function() setRole(role) end)
            local allowed
            if canPlay then allowed = canPlay(role) else allowed = ns.CanTakeRole(class, role) end
            if option and option.SetEnabled then option:SetEnabled(allowed) end
        end
    end)
    return dd
end

local function RefreshDropdown(dd)
    if dd.GenerateMenu then dd:GenerateMenu() end
end

-- Big role button like the dungeon finder: role icon with a checkbox in the bottom-left corner,
-- role name on mouseover. Disabled (greyed) when the class can't take the role.
local function NewRoleButton(parent, role, size, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    SetRoleTexture(b.icon, role)
    b.check = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
    b.check:SetSize(24, 24)
    b.check:SetPoint("BOTTOMLEFT", -6, -6)
    -- One element: the icon button takes all the mouse (its hit area covers the checkbox
    -- corner too), and hovering anywhere lights the checkbox, like hovering the box itself.
    b.check:EnableMouse(false)
    b:SetHitRectInsets(-6, 0, 0, -6)

    b:SetScript("OnEnter", function(self)
        if self.allowed then self.check:LockHighlight() end
        local lines = { RoleText(role) }
        if not self.allowed then lines[2] = "|cffff4040" .. L["Your class can't take this role."] .. "|r" end
        ShowTooltip(self, lines)
    end)
    b:SetScript("OnLeave", function(self)
        self.check:UnlockHighlight()
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function(self, ...)
        if SOUNDKIT then
            PlaySound(self.check:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
        onClick(self, ...)
    end)

    -- allowed: the class can take the role.
    function b:SetAllowed(allowed)
        self.allowed = allowed
        self.icon:SetDesaturated(not allowed)
        self.icon:SetAlpha(allowed and 1 or 0.4)
        self:SetEnabled(allowed)
        self.check:SetEnabled(allowed)
    end
    function b:SetChecked(checked)
        self.check:SetChecked(checked)
    end
    b:SetAllowed(true)
    return b
end

-- Sets the first texture of the list the client has (SetTexture says false when a file is
-- missing). Returns true when one was found.
-- Each choice is a file path, { atlas = name }, or { file = path, coords = { l, r, t, b } }
-- (one picture out of a sheet).
local function SetFirstTexture(texture, ...)
    for i = 1, select("#", ...) do
        local choice = select(i, ...)
        if type(choice) == "table" and choice.atlas then
            if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(choice.atlas) and texture.SetAtlas then
                texture:SetAtlas(choice.atlas)
                return true
            end
        else
            local file = type(choice) == "table" and choice.file or choice
            local ok = texture:SetTexture(file)
            if ok ~= false then
                local c = type(choice) == "table" and choice.coords
                if c then texture:SetTexCoord(c[1], c[2], c[3], c[4]) else texture:SetTexCoord(0, 1, 0, 1) end
                return true
            end
        end
    end
    return false
end

-- Small icon button for row actions (whisper, remove...), with a tooltip. The red text buttons
-- stay for the one or two things a page is for.
local ICON_PATHS = {
    whisper = { "Interface\\ChatFrame\\UI-ChatIcon-Chat-Up" },
    remove = { "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Interface\\Buttons\\UI-StopButton" },
    again = { "Interface\\Buttons\\UI-RefreshButton", "Interface\\Buttons\\UI-RotationRight-Button-Up" },
}
local function NewIconButton(parent, kind, tooltip, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 20, size or 20)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    SetFirstTexture(b.icon, unpack(ICON_PATHS[kind]))
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetMotionScriptsWhileDisabled(true)
    b.tooltip = tooltip
    b:SetScript("OnEnter", function(self)
        ShowTooltip(self, type(self.tooltip) == "table" and self.tooltip or { self.tooltip })
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function b:SetUsable(on)
        self:SetEnabled(on)
        self.icon:SetDesaturated(not on)
        self.icon:SetAlpha(on and 1 or 0.4)
    end
    return b
end

-- Small ⓘ next to a title: the explanations live in its tooltip instead of paragraphs of text.
local function NewInfoIcon(parent, lines)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 16)
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    if not SetFirstTexture(tex, "Interface\\FriendsFrame\\InformationIcon", "Interface\\Common\\help-i") then
        local q = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        q:SetPoint("CENTER")
        q:SetText("(?)")
    end
    b.lines = lines
    b:SetScript("OnEnter", function(self) ShowTooltip(self, self.lines) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- A section of a page: a gold header, smaller than the page title, with a thin line under it
-- across the page (header.line, shown and hidden with ShowSection).
local SECTION_FONT = _G.GameFontNormalMed2 and "GameFontNormalMed2" or "GameFontNormal"
local function NewSectionHeader(parent, text)
    local header = NewLabel(parent, text, SECTION_FONT)
    header.line = parent:CreateTexture(nil, "ARTWORK")
    header.line:SetColorTexture(1, 0.82, 0, 0.25)
    header.line:SetHeight(1)
    header.line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    header.line:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    return header
end
local function ShowSection(header, on)
    header:SetShown(on and true or false)
    header.line:SetShown(on and true or false)
end

-- Page title, the same on every page: large, top left. info: tooltip lines for a ⓘ after it.
local function NewPageTitle(parent, text, info)
    local title = NewLabel(parent, text, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 8, -8)
    if info then
        title.info = NewInfoIcon(parent, info)
        title.info:SetPoint("LEFT", title, "RIGHT", 6, 0)
    end
    return title
end

-- "Looking for" row: how many of each role the group needs, with what's still missing.
-- Tank and healer have arrows; DPS takes the rest, so the total always equals the group size.
-- onStep(values) gets the new mix after a click (nil from "Default": the default mix).
local function StepMix(values, role, delta)
    local v = CopyTable(values)
    if delta > 0 then
        if (v.DAMAGER or 0) < 1 then return nil end
        v[role] = (v[role] or 0) + 1
        v.DAMAGER = v.DAMAGER - 1
    else
        if (v[role] or 0) < 1 then return nil end
        v[role] = v[role] - 1
        v.DAMAGER = (v.DAMAGER or 0) + 1
    end
    return v
end

local function SameMix(a, b)
    for _, role in ipairs(ns.Groups.ROLES) do
        if (a[role] or 0) ~= (b[role] or 0) then return false end
    end
    return true
end

local function ArrowButton(parent, which)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. which .. "Page-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. which .. "Page-Down")
    b:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. which .. "Page-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return b
end

-- Columns: the row starts at the form's input column; each role is "icon  ‹ 1/3 ›": how many
-- of that role the group has, out of how many it looks for (the arrows change the second one).
-- Fixed widths, so every role starts at the same place.
local MIX_X, MIX_STEP, MIX_ICON, MIX_COUNT = 140, 140, 30, 44
local function NewMixRow(parent, onStep)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(34)
    local label = NewLabel(row, L["Looking for"])
    label:SetPoint("LEFT", 8, 0)
    local info = NewInfoIcon(row, { L["Looking for"],
        L["For each role: how many the group has / how many it looks for. Green: complete, orange: still missing."],
        L["Tank and healer: the arrows change how many the group looks for, DPS takes the rest. None is fine (for example no healer, 4 DPS)."],
        L["Default: 1 tank, 1 healer, 3 DPS (2, 2, 6 for 10 players)."] })
    info:SetPoint("LEFT", label, "RIGHT", 4, 0)
    row.parts = {}
    for i, role in ipairs(ns.Groups.ROLES) do
        local part = CreateFrame("Frame", nil, row)
        part:SetSize(MIX_STEP - 8, 34)
        part:SetPoint("LEFT", MIX_X + (i - 1) * MIX_STEP, 0)
        part.icon = part:CreateTexture(nil, "ARTWORK")
        part.icon:SetSize(MIX_ICON, MIX_ICON)
        part.icon:SetPoint("LEFT", 0, 0)
        SetRoleTexture(part.icon, role)
        part.minus = ArrowButton(part, "Prev")
        part.minus:SetPoint("LEFT", part.icon, "RIGHT", 4, 0)
        part.count = NewLabel(part, "", "GameFontHighlightLarge")
        part.count:SetPoint("LEFT", part.minus, "RIGHT", 0, 0)
        part.count:SetWidth(MIX_COUNT)
        part.count:SetJustifyH("CENTER")
        part.plus = ArrowButton(part, "Next")
        part.plus:SetPoint("LEFT", part.count, "RIGHT", 0, 0)
        -- DPS: no arrows, it's what the other roles leave (the count stays in place).
        part.minus:SetShown(role ~= "DAMAGER")
        part.plus:SetShown(role ~= "DAMAGER")
        part.minus:SetScript("OnClick", function()
            local v = row.values and StepMix(row.values, role, -1)
            if v then onStep(v) end
        end)
        part.plus:SetScript("OnClick", function()
            local v = row.values and StepMix(row.values, role, 1)
            if v then onStep(v) end
        end)
        row.parts[role] = part
    end
    row.default = NewButton(row, L["Default"], 90, 20)
    row.default:SetPoint("LEFT", MIX_X + 3 * MIX_STEP, 0)
    row.default:SetScript("OnClick", function() onStep(nil) end)

    -- values: the mix; size: the group size; missing: [role] = still missing.
    -- Each role reads "have/wanted": grey when the group wants none, green when complete,
    -- orange while some are missing.
    function row:SetMix(values, size, missing)
        self.values = values
        for role, part in pairs(self.parts) do
            local n = values[role] or 0
            local m = (missing and missing[role]) or 0
            local color = (n == 0 and "808080") or (m > 0 and "ff9900") or "20ff20"
            part.count:SetText("|cff" .. color .. (n - m) .. "/" .. n .. "|r")
            part.minus:SetEnabled(n > 0)
            part.plus:SetEnabled((values.DAMAGER or 0) > 0)
        end
        local default = ns.Groups.DEFAULT_COMPOSITION[size] or ns.Groups.DEFAULT_COMPOSITION[5]
        self.default:SetShown(not SameMix(values, default))
    end
    return row
end

-- The mix grown to fit the players already there (a list of roles): a role with more players
-- than wanted takes a spot from one with free spots (DPS first). Same rule as the listing.
local function FitMix(values, taken)
    local have = {}
    for _, role in ipairs(taken) do have[role] = (have[role] or 0) + 1 end
    local v = CopyTable(values)
    for _, role in ipairs(ns.Groups.ROLES) do
        while (have[role] or 0) > (v[role] or 0) do
            local took
            for _, r in ipairs({ "DAMAGER", "HEALER", "TANK" }) do
                if r ~= role and (v[r] or 0) > (have[r] or 0) then took = r break end
            end
            if not took then break end
            v[took] = v[took] - 1
            v[role] = (v[role] or 0) + 1
        end
    end
    return v
end

-- [role] = still missing, for a mix and the roles already taken (a list of roles).
local function MissingFor(values, taken)
    local missing = CopyTable(values)
    for _, role in ipairs(taken) do
        if missing[role] then missing[role] = math.max(0, missing[role] - 1) end
    end
    return missing
end

-- Dungeon lists ---------------------------------------------------------------------------
-- One line per dungeon: the name on the left, the level range on the right edge, the whole
-- line in the difficulty color for my level. The game's menus can't align text right, so
-- the pickers use their own list.

-- Fills a dungeon line: row.name and row.range, two font strings across the row.
local function SetDungeonLine(row, d)
    row.name:SetText(ns.DungeonColoredName(d))
    row.range:SetText(d.min and ("|cff" .. ns.DungeonColor(d) .. d.min .. "-" .. d.max .. "|r") or "")
end

local function NewDungeonLine(row, left)
    row.range = NewLabel(row, nil, "GameFontHighlight")
    row.range:SetPoint("RIGHT", -8, 0)
    row.range:SetJustifyH("RIGHT")
    row.name = NewLabel(row, nil, "GameFontHighlight")
    row.name:SetPoint("LEFT", left, 0)
    row.name:SetPoint("RIGHT", row.range, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
end

-- A dungeon's tooltip: its name in the other languages switched on in Options. Nothing when
-- none is on (or the name is the same). head: the first line instead of the dungeon's name
-- (a group's whole title, which can be cut on screen); then the tooltip always shows.
local function DungeonTip(owner, d, head)
    if type(d) == "string" then d = ns.DungeonByKey(d) end
    local others = d and ns.DungeonOtherNames(d) or {}
    if not head and #others == 0 then return end
    local lines = { head or ns.DungeonLabel(d) }
    for _, line in ipairs(others) do lines[#lines + 1] = line end
    ShowTooltip(owner, lines)
end

-- A hover area over a text that starts with a dungeon's name (titles): as wide as the text.
-- Set hit.dungeon (and hit.listing for a group's title: its whole title in the tooltip), then hit:Fit() after
-- changing the text.
local function NewDungeonHover(parent, fontString)
    local hit = CreateFrame("Frame", nil, parent)
    hit:SetPoint("TOPLEFT", fontString, "TOPLEFT")
    hit:SetPoint("BOTTOMLEFT", fontString, "BOTTOMLEFT")
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self)
        local full = self.listing and DungeonTitle(self.listing)
        if self.dungeon or full then DungeonTip(self, self.dungeon, full) end
    end)
    hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function hit:Fit()
        local textWidth, lineWidth = fontString:GetStringWidth() or 0, fontString:GetWidth() or 0
        self:SetWidth(math.max(20, (lineWidth > 0 and math.min(textWidth, lineWidth)) or textWidth))
    end
    return hit
end

-- The dungeons I can pick (test dungeon in test mode, my faction's).
local function PickableDungeons(withTest)
    local out = {}
    for _, d in ipairs(ns.Dungeons) do
        if ns.DungeonShown(d) and (withTest or not d.test) then out[#out + 1] = d end
    end
    return out
end

-- The popup list, shared by every picker: opens under its button, one line per dungeon.
-- opts: multi (checkboxes, stays open) or not (pick one, closes); isSelected(key); onPick(key);
-- clearText (multi: a first line that unticks everything, via onClear).
local PICK_ROW, PICK_ROWS = 24, 14
local picker
local function BuildPicker()
    local f = CreateFrame("Frame", "LaTaverneDungeonPicker", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetClampedToScreen(true)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    end
    f:EnableMouse(true)
    f.list = NewScrollList(f, PICK_ROW, function(row, item)
        if not row.built then
            row:EnableMouse(true)
            row.hl = row:CreateTexture(nil, "HIGHLIGHT")
            row.hl:SetAllPoints()
            row.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.hl:SetBlendMode("ADD")
            row.check = row:CreateTexture(nil, "ARTWORK")
            row.check:SetSize(20, 20)
            row.check:SetPoint("LEFT", 4, 0)
            NewDungeonLine(row, 28)
            row:SetScript("OnMouseUp", function(self) if self.onClick then self.onClick() end end)
            row:SetScript("OnEnter", function(self) if self.dungeon then DungeonTip(self, self.dungeon) end end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.built = true
        end
        local opts = f.opts
        row.dungeon = item.dungeon
        if item.clear then
            row.check:Hide()
            row.name:SetText(opts.clearText)
            row.range:SetText("")
            row.onClick = function() opts.onClear() f:Refresh() end
            return
        end
        local d = item.dungeon
        SetDungeonLine(row, d)
        local selected = opts.isSelected(d.key)
        row.check:Show()
        if opts.multi then
            row.check:SetTexture(selected and "Interface\\Buttons\\UI-CheckBox-Check" or "Interface\\Buttons\\UI-CheckBox-Up")
        else
            row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            row.check:SetShown(selected)
        end
        row.onClick = function()
            opts.onPick(d.key)
            if opts.multi then f:Refresh() else f:Hide() end
        end
    end)
    f.list:SetPoint("TOPLEFT", 6, -6)
    f.list:SetPoint("BOTTOMRIGHT", -24, 6)
    -- Closes on a click outside it (or on its button again), and with Escape.
    f:SetScript("OnUpdate", function(self)
        if IsMouseButtonDown() and not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)
    tinsert(UISpecialFrames, "LaTaverneDungeonPicker")
    function f:Refresh()
        local items = {}
        if self.opts.clearText then items[1] = { clear = true } end
        for _, d in ipairs(PickableDungeons(self.opts.withTest)) do items[#items + 1] = { dungeon = d } end
        self:SetHeight(math.min(#items, PICK_ROWS) * PICK_ROW + 12)
        SetListData(self.list, items)
        if self.owner and self.owner.Update then self.owner:Update() end
    end
    f:Hide()
    return f
end

local function TogglePicker(owner, opts)
    picker = picker or BuildPicker()
    if picker:IsShown() and picker.owner == owner then picker:Hide() return end
    picker.owner, picker.opts = owner, opts
    picker:ClearAllPoints()
    picker:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    picker:SetWidth(math.max(owner:GetWidth(), 340))
    picker:Refresh()
    picker:Show()
end

-- The button that opens the list: looks like the game's dropdowns (dark, arrow on the right).
-- getText() gives its text; opts as above.
local function NewDungeonPicker(parent, width, getText, opts)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 26)
    if b.SetBackdrop then
        b:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        b:SetBackdropColor(0, 0, 0, 0.7)
        b:SetBackdropBorderColor(0.75, 0.6, 0.2, 1)
    end
    b.arrow = b:CreateTexture(nil, "ARTWORK")
    b.arrow:SetSize(20, 20)
    b.arrow:SetPoint("RIGHT", -4, -1)
    b.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    b.text = NewLabel(b, "", "GameFontHighlight")
    b.text:SetPoint("LEFT", 10, 0)
    b.text:SetPoint("RIGHT", b.arrow, "LEFT", -4, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetWordWrap(false)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnClick", function(self) TogglePicker(self, opts) end)
    b:SetScript("OnHide", function(self) if picker and picker.owner == self then picker:Hide() end end)
    -- The chosen dungeon (single choice): its name in the other languages.
    b:SetScript("OnEnter", function(self)
        if not opts.multi and opts.selected then DungeonTip(self, opts.selected()) end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function b:Update() self.text:SetText(getText()) end
    b:Update()
    return b
end

-- Name field with guild autocomplete. onPick(member) gets { name, class, level, online }.
local function NewNameInput(parent, width, onPick)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(40)

    local list = CreateFrame("Frame", nil, box, "BackdropTemplate")
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, 2)
    list:SetWidth(width + 12)
    list:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    list:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    list:Hide()

    local matches = {}
    local selected = 1 -- suggestion picked by Enter or Tab, moved with Up / Down
    local function Pick(member)
        matches = {}
        list:Hide()
        box:SetText("")
        box:ClearFocus()
        onPick(member)
    end

    local buttons = {}
    for i = 1, 6 do
        local b = CreateFrame("Button", nil, list)
        b:SetHeight(18)
        b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
        b:SetPoint("RIGHT", -6, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 4, 0)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function()
            if matches[i] then Pick(matches[i]) end
        end)
        buttons[i] = b
    end

    local function Update()
        matches = ns.Groups:SearchPlayers(box:GetText(), #buttons)
        for i, b in ipairs(buttons) do
            local m = matches[i]
            if m then
                local offline = m.online and "" or (" |cff808080(" .. L["offline"] .. ")|r")
                b.text:SetText(NameText(m.name, m.class, m.tag) .. offline)
                b:Show()
            else
                b:Hide()
            end
            if i == selected and m then b:LockHighlight() else b:UnlockHighlight() end
        end
        list:SetHeight(12 + #matches * 18)
        list:SetShown(#matches > 0 and box:HasFocus())
    end

    box:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            selected = 1
            Update()
        end
    end)
    -- Keyboard: Up / Down move in the suggestions, Tab or Enter picks, Escape closes.
    box:SetScript("OnArrowPressed", function(_, key)
        if not list:IsShown() or #matches == 0 then return end
        if key == "UP" then
            selected = selected > 1 and selected - 1 or #matches
        elseif key == "DOWN" then
            selected = selected < #matches and selected + 1 or 1
        else
            return
        end
        Update()
    end)
    box:SetScript("OnTabPressed", function()
        if list:IsShown() and matches[selected] then Pick(matches[selected]) end
    end)
    box:SetScript("OnEnterPressed", function()
        if list:IsShown() and matches[selected] then
            Pick(matches[selected])
        elseif matches[1] then
            Pick(matches[1])
        else
            local text = strtrim(box:GetText() or "")
            if text ~= "" then Pick({ name = text }) end
        end
    end)
    box:SetScript("OnEscapePressed", function()
        list:Hide()
        box:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function()
        -- Wait a moment so a click on a suggestion still counts.
        C_Timer.After(0.2, function() list:Hide() end)
    end)
    return box
end

-- Shared list rows ----------------------------------------------------------------------

-- Group row, two lines: dungeon, level range, age and state; then the leader, the note (cut
-- short) and the option icons. Role spots on the right, before the row's button. The tooltip
-- on the second line has the full note and the options.
local FILL_WIDTH = 34 -- "1/5" after the spots
local function BuildListingRow(row, rightMargin)
    RowBackground(row)
    row.rightMargin = rightMargin
    row.slots = {}
    for i = 1, MAX_SLOTS do row.slots[i] = NewSlot(row) end
    row.fill = NewLabel(row, nil, "GameFontHighlightSmall")
    row.title = NewLabel(row, nil, "GameFontNormal")
    row.title:SetPoint("TOPLEFT", 8, -9)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.titleHit = NewDungeonHover(row, row.title)
    row.leader = NewLabel(row, nil, "GameFontHighlightSmall")
    row.leader:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -6)
    row.leader:SetJustifyH("LEFT")
    row.leader:SetWordWrap(false)
    -- The hover area covers the text itself (sized in FillListingRow), not the whole line up
    -- to the role spots: the tooltip then opens right next to the text.
    row.leaderHit = CreateFrame("Frame", nil, row)
    row.leaderHit:SetPoint("TOPLEFT", row.leader, "TOPLEFT")
    row.leaderHit:SetPoint("BOTTOMLEFT", row.leader, "BOTTOMLEFT")
    row.leaderHit:EnableMouse(true)
    row.leaderHit:SetScript("OnEnter", function(self) ShowTooltip(self, self.tooltip) end)
    row.leaderHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function FillListingRow(row, l)
    local count, taken = RenderSlots(row.slots, l)
    -- Spots right-aligned before the button, "1/5" after them.
    for i, slot in ipairs(row.slots) do
        slot:ClearAllPoints()
        slot:SetPoint("RIGHT", row, "RIGHT", -(row.rightMargin + FILL_WIDTH + (count - i) * SLOT_STEP), 0)
    end
    local first = row.slots[1]
    row.fill:ClearAllPoints()
    row.fill:SetPoint("LEFT", row.slots[math.max(1, count)], "RIGHT", 6, 0)
    row.fill:SetText(count > 0 and ((taken >= count and "|cff808080" or "|cffffffff") .. taken .. "/" .. count .. "|r") or "")
    row.title:SetPoint("RIGHT", first, "LEFT", -12, 0)
    row.leader:SetPoint("RIGHT", first, "LEFT", -12, 0)

    row.title:SetText(DungeonTitle(l))
    row.titleHit.dungeon = l.dungeon
    row.titleHit.listing = l
    row.titleHit:Fit()
    -- An allied leader nobody from their guild could confirm yet: said in the tooltip only.
    local unverified = l.tag and ns.Vouch and ns.Vouch:GetState(l.leader) == "unverified"
    local note = (l.note and l.note ~= "") and ("  |cffb0b0b0\194\171 " .. l.note:gsub("\n", " ") .. " \194\187|r") or ""
    local icons = FlagIcons(l)
    row.leader:SetText(NameText(l.leader, LeaderClass(l), l.tag) .. " " .. CROWN
        .. (icons ~= "" and ("  " .. icons) or "") .. note)
    local tip = { NameText(l.leader, LeaderClass(l), l.tag) .. " " .. CROWN }
    if unverified then tip[#tip + 1] = format(L["Not checked yet: nobody from [%s] was online to confirm this player is a member."], l.tag) end
    if l.note and l.note ~= "" then tip[#tip + 1] = "|cffffd100" .. L["Note"] .. ":|r " .. l.note end
    for _, line in ipairs(FlagLines(l)) do tip[#tip + 1] = line end
    row.leaderHit.tooltip = tip
    -- As wide as the text (cut at the line's width when the note is shortened).
    local textWidth = row.leader:GetStringWidth() or 0
    local lineWidth = row.leader:GetWidth() or 0
    row.leaderHit:SetWidth(math.max(20, (lineWidth > 0 and math.min(textWidth, lineWidth)) or textWidth))
end

local LISTING_ROW_HEIGHT = 58

-- Member row: name, status, role (dropdown when editable). Invited and accepted players are in
-- the member list too (they take a spot): pendingStatus "invited" / "accepted", with the
-- leader's small buttons (cancel / remove, invite again).
-- canEdit(member) says if the role dropdown is shown; setRole(member, role) applies it;
-- canManage says if the leader's buttons show.
local function MemberRowInitializer(canEdit, setRole, canManage)
    return function(row, m)
        if not row.built then
            RowBackground(row)
            row.name = NewLabel(row)
            row.name:SetPoint("LEFT", 8, 0)
            row.status = NewLabel(row, nil, "GameFontDisableSmall")
            row.status:SetPoint("LEFT", 270, 0)
            row.roleText = NewLabel(row)
            row.roleText:SetPoint("LEFT", 400, 0)
            -- Only the roles this player offered (or their class's roles when unknown).
            row.roleDropdown = NewRoleDropdown(row, 150,
                function() return row.member and row.member.role end,
                function(role) if row.member then setRole(row.member, role) end end,
                function() return row.member and row.member.class end,
                function(role) return ns.Groups:CanPlay(row.member, role) end)
            row.roleDropdown:SetPoint("LEFT", 394, 0)
            row.remove = NewIconButton(row, "remove", "")
            row.remove:SetPoint("RIGHT", -10, 0)
            row.remove:SetScript("OnClick", function() if row.member then ns.Groups:RemovePending(row.member.key) end end)
            row.again = NewIconButton(row, "again", L["Invite again"])
            row.again:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
            row.again:SetScript("OnClick", function() if row.member then ns.Groups:InviteAgain(row.member.key) end end)
            row.built = true
        end
        row.member = m
        row.name:SetText(NameText(m.name, m.class, m.tag or m.guest, m.newbie))
        local pending = m.pendingStatus
        if pending == "invited" then
            row.status:SetText("|cffb0b0b0" .. L["Invited, no answer yet"] .. "|r")
        elseif pending == "accepted" then
            row.status:SetText("|cff20ff20" .. L["Accepted, on the way"] .. "|r")
        else
            row.status:SetText(m.statusText or "")
        end
        local editable = not pending and canEdit(m)
        row.roleDropdown:SetShown(editable)
        row.roleText:SetShown(not editable)
        if pending == "invited" and not m.role then
            row.roleText:SetText("")
        else
            row.roleText:SetText(m.role and RoleText(m.role) or ("|cff808080" .. L["Role unknown"] .. "|r"))
        end
        if editable then RefreshDropdown(row.roleDropdown) end
        local manage = pending ~= nil and canManage ~= nil and canManage(m)
        row.remove:SetShown(manage and true or false)
        row.again:SetShown(manage and pending == "accepted" or false)
        row.remove.tooltip = pending == "invited" and L["Cancel the invitation"] or L["Remove from the group"]
    end
end

-- "Accept as..." for a request: the roles they offered, the ones the group still needs first,
-- each with how many are missing; roles already full stay possible but say so.
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

local function SortedOffer(p)
    local offered = ns.Groups.RoleList(p.roles or (p.role and { [p.role] = true }))
    if #offered == 0 then -- unknown (older version): the roles of their class
        for _, role in ipairs(ns.Groups.ROLES) do
            if ns.CanTakeRole(p.class, role) then offered[#offered + 1] = role end
        end
    end
    local mine = ns.Groups:GetMine()
    local missing = mine and ns.Groups:MissingRoles(mine) or {}
    table.sort(offered, function(a, b)
        local ma, mb = (missing[a] or 0) > 0, (missing[b] or 0) > 0
        if ma ~= mb then return ma end
        return ROLE_ORDER[a] < ROLE_ORDER[b]
    end)
    return offered, missing
end

local function AcceptMenu(owner, p)
    local offered, missing = SortedOffer(p)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(format(L["Accept %s as..."], ClassColored(p.name, p.class)))
        for _, role in ipairs(offered) do
            local n = missing[role] or 0
            local hint = n > 0 and ("  |cff9fdf7f" .. format(L["%d missing"], n) .. "|r")
                or ("  |cff808080" .. L["already full"] .. "|r")
            root:CreateButton(RoleText(role) .. hint, function() ns.Groups:Accept(p.key, role) end)
        end
    end)
end

-- Pending row, in the member list's columns: name (level and "new player" under it), status,
-- role(s), then the leader's buttons.
local function InitPendingRow(row, p)
    if not row.built then
        RowBackground(row)
        row.name = NewLabel(row)
        row.name:SetPoint("TOPLEFT", 8, -6)
        row.detail = NewLabel(row, nil, "GameFontDisableSmall")
        row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 18, -3)
        row.status = NewLabel(row, nil, "GameFontHighlightSmall")
        row.status:SetPoint("LEFT", 270, 0)
        -- Roles: one icon per role offered. For a request, clicking one accepts in that role.
        row.roleButtons = {}
        for i = 1, 3 do
            local b = CreateFrame("Button", nil, row)
            b:SetSize(22, 22)
            b:SetPoint("LEFT", 398 + (i - 1) * 28, 0)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b:SetScript("OnEnter", function(self) ShowTooltip(self, self.tooltip) end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.roleButtons[i] = b
        end
        row.roleLabel = NewLabel(row)
        row.roleLabel:SetPoint("LEFT", row.roleButtons[1], "RIGHT", 6, 0)
        row.second = NewButton(row, L["Decline"], 90)
        row.second:SetPoint("RIGHT", -6, 0)
        row.first = NewButton(row, L["Accept"], 100)
        row.first:SetPoint("RIGHT", row.second, "LEFT", -4, 0)
        row.built = true
    end

    -- Allied players show their guild's tag, and "not checked yet" when nobody from that guild
    -- could confirm them.
    row.name:SetText(NameText(p.name, p.class, p.tag)
        .. (p.unverified and (" |cffff9900(" .. L["not checked yet"] .. ")|r") or ""))
    -- Under the name: level, and "new player" once, as words (a leader wants to know).
    local detail = {}
    if p.level then detail[#detail + 1] = format(L["Level %d"], p.level) end
    if p.newbie then detail[#detail + 1] = ns.NewbieIcon(12) .. " |cff9fdf7f" .. L["New player"] .. "|r" end
    row.detail:SetText(table.concat(detail, "   "))

    if p.status == "request" then
        row.status:SetText("|cffffd100" .. L["Wants to join"] .. "|r")
    elseif p.status == "invited" then
        row.status:SetText("|cffb0b0b0" .. L["Invited, no answer yet"] .. "|r")
    else
        row.status:SetText("|cff20ff20" .. L["Accepted, on the way"] .. "|r")
    end

    -- A request: every role offered, the ones the group needs first (greyed when that role is
    -- full). Otherwise the role they'll take. One role also gets its name.
    local canAccept = p.readOnly ~= true and p.status == "request"
    local roles, missing = {}, {}
    if p.status == "request" then roles, missing = SortedOffer(p)
    elseif p.role then roles = { p.role } end
    for i, b in ipairs(row.roleButtons) do
        local role = roles[i]
        b:SetShown(role ~= nil)
        if role then
            SetRoleTexture(b.icon, role)
            local needed = p.status ~= "request" or (missing[role] or 0) > 0
            b.icon:SetDesaturated(not needed)
            b.icon:SetAlpha(needed and 1 or 0.6)
            b:EnableMouse(true)
            if canAccept then
                b.tooltip = { RoleText(role), format(L["Click: accept as %s"], ns.RoleLabel(role)) }
                b:SetScript("OnClick", function() ns.Groups:Accept(p.key, role) end)
            else
                b.tooltip = { RoleText(role) }
                b:SetScript("OnClick", nil)
            end
        end
    end
    row.roleLabel:SetText(#roles == 1 and ns.RoleLabel(roles[1]) or "")

    local key = p.key
    local leader = p.readOnly ~= true
    row.first:SetShown(leader and p.status ~= "invited")
    row.second:SetShown(leader)
    if not leader then return end
    if p.status == "request" then
        row.first:SetText(L["Accept"])
        row.first:SetScript("OnClick", function(button)
            local offered = SortedOffer(p)
            if #offered == 1 then
                ns.Groups:Accept(key, offered[1])
            else
                AcceptMenu(button, p)
            end
        end)
        row.second:SetText(L["Decline"])
    elseif p.status == "invited" then
        row.second:SetText(L["Cancel"])
    else
        row.first:SetText(L["Invite again"])
        row.first:SetScript("OnClick", function() ns.Groups:InviteAgain(key) end)
        row.second:SetText(L["Remove"])
    end
    row.second:SetScript("OnClick", function() ns.Groups:RemovePending(key) end)
end

-- Groups tab --------------------------------------------------------------------------

-- Accept an invitation with the roles ticked at the top of the list: the one this group needs
-- most goes first, the leader can move me to another of them. Nothing ticked: ask.
local function AcceptInvitation(button, l)
    local offered = ns.Groups:GetMyRoles()
    local missing = ns.Groups:MissingRoles(l)
    local first
    for _, role in ipairs(ns.Groups.ROLES) do
        if offered[role] and (missing[role] or 0) > 0 then first = role break end
    end
    first = first or ns.Groups.RoleList(offered)[1]
    if first then
        ns.Groups:ReplyInvitation(l.id, true, first, offered)
    else
        RoleMenu(button, L["Join as..."], RolesForMe(l, true), function(role)
            ns.Groups:ReplyInvitation(l.id, true, role)
        end)
    end
end

-- Why I can't join or accept another group right now, or nil. My own group is listed: alone in
-- it, joining another group is fine (mine is removed once I'm accepted); with anyone else in it
-- (member, invited, request), remove it first. In a party outside the finder: leave it first,
-- the game won't let the leader invite me.
local function JoinBlocked()
    if ns.Groups:GetMine() then
        return not ns.Groups:IsAloneInMine() and L["Remove your group first."] or nil
    end
    if ns.InParty() then return L["Leave your party first."] end
    return nil
end

local function InitGroupRow(row, l, invite)
    if not row.built then
        BuildListingRow(row, 116)
        row.button = NewButton(row, L["Join"], 100)
        row.button:SetPoint("RIGHT", -8, 0)
        row.button:SetMotionScriptsWhileDisabled(true)
        row.button:SetScript("OnEnter", function(self) if self.tooltip then ShowTooltip(self, self.tooltip) end end)
        row.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Invitations: Accept, then Decline at the right end.
        row.decline = NewButton(row, L["Decline"], 100)
        row.decline:SetPoint("RIGHT", -8, 0)
        -- Status right above the button it explains.
        row.status = NewLabel(row, nil, "GameFontHighlightSmall")
        row.status:SetPoint("BOTTOMRIGHT", row.button, "TOPRIGHT", 0, 3)
        row.built = true
    end

    local reply = ns.Groups:GetInviteReply(l.id)
    local asInvite = invite and reply ~= "declined"
    row.rightMargin = (asInvite and reply ~= "accepted") and 216 or 116
    row.button:ClearAllPoints()
    if asInvite and reply ~= "accepted" then
        row.button:SetPoint("RIGHT", row.decline, "LEFT", -6, 0)
    else
        row.button:SetPoint("RIGHT", -8, 0)
    end
    FillListingRow(row, l)
    row.status:SetText("")
    row.status:ClearAllPoints()
    row.status:SetPoint("BOTTOMRIGHT", row.button, "TOPRIGHT", 0, 3)
    row.button:Show()
    row.button:Enable()
    row.button.tooltip = nil
    row.button:SetScript("OnClick", nil)
    row.decline:Hide()

    -- My group, or the one I'm in: just said, in the button's place (the green My group button
    -- at the top right of the list goes there).
    local function JustSay(text)
        row.button:Hide()
        row.status:ClearAllPoints()
        row.status:SetPoint("RIGHT", row.button, "RIGHT", 0, 0)
        row.status:SetText(text)
    end
    if ns.Groups:IsMine(l) then
        JustSay("|cff20ff20" .. L["Your group"] .. "|r")
        return
    end

    if asInvite then
        if reply == "accepted" then
            row.status:SetText("|cff20ff20" .. L["Accepted: the leader will invite you"] .. "|r")
            row.button:Hide()
            return
        end
        row.button:SetText(L["Accept"])
        row.decline:Show()
        row.decline:SetScript("OnClick", function() ns.Groups:ReplyInvitation(l.id, false) end)
        local blocked = JoinBlocked()
        if blocked then
            row.button:Disable()
            row.button.tooltip = { L["Accept"], "|cffff4040" .. blocked .. "|r" }
            row.status:SetText("|cffff9900" .. blocked .. "|r")
        else
            row.button:SetScript("OnClick", function(button) AcceptInvitation(button, l) end)
            if ns.Groups:GetMine() then
                row.button.tooltip = { L["Accept"], "|cffff9900" .. L["Your group will be removed if you're accepted."] .. "|r" }
            end
        end
        return
    end

    if ns.Groups:IsInvolved(l) then
        JustSay("|cff20ff20" .. L["You're in this group"] .. "|r")
        return
    end

    local app = ns.Groups:GetApplication(l.id)
    if app and app.status == "pending" then
        -- Received: the leader's addon has it. Not yet and they're offline: it waits for them.
        if app.acked then
            row.status:SetText("|cffffd100" .. L["Request received"] .. "|r")
        elseif ns.Groups:IsLeaderAway(l) then
            row.status:SetText("|cffff9900" .. L["Request waiting: leader offline"] .. "|r")
        else
            row.status:SetText("|cffffd100" .. L["Request sent"] .. "|r")
        end
        row.button:SetText(L["Cancel"])
        row.button:SetScript("OnClick", function() ns.Groups:CancelApply(l.id) end)
        return
    end
    if app and app.status == "declined" then
        row.status:SetText("|cffff4040" .. L["Declined"] .. "|r")
    elseif app and app.status == "expired" then
        row.status:SetText("|cff808080" .. L["No answer"] .. "|r")
    end
    local state = ns.Groups:GetState(l)
    row.button:SetText(L["Join"])
    if state == "running" or state == "full" then
        -- Nothing to do with it: no greyed-out button, the state says it.
        row.status:SetText("|cff808080" .. (state == "running" and L["In progress"] or L["Full"]) .. "|r")
        row.button:Hide()
    elseif not next(ns.Groups:GetMyRoles()) then
        -- Roles are chosen once, at the top of the list.
        row.status:SetText("|cff808080" .. L["Choose your roles at the top"] .. "|r")
        row.button:Disable()
    elseif JoinBlocked() then
        row.button:Disable()
        row.button.tooltip = { L["Join"], "|cffff4040" .. JoinBlocked() .. "|r" }
    else
        row.button:SetScript("OnClick", function() ns.Groups:Apply(l.id) end)
        if ns.Groups:GetMine() then
            row.status:SetText("|cffff9900" .. L["Your group will be removed if you're accepted."] .. "|r")
        elseif ns.Groups:IsLeaderAway(l) then
            -- A request still works: it's sent again when they're back.
            row.status:SetText("|cff808080" .. L["Leader offline"] .. "|r")
        end
    end
end

-- Browse list rows: a group, an invitation (gold frame), or a line that starts a part of the
-- list ("You're invited", "In progress or full"). Groups in progress or full are dimmed, and
-- come back to full brightness under the mouse.
local SEPARATOR_HEIGHT = 30
local DIMMED = 0.45

local function DimOnHover(self)
    self.body:SetAlpha(self:IsMouseOver() and 1 or DIMMED)
end

local function InitBrowseRow(row, data)
    if not row.body then
        row.body = CreateFrame("Frame", nil, row)
        row.body:SetAllPoints()
        row.gold = CreateFrame("Frame", nil, row, "BackdropTemplate")
        row.gold:SetPoint("TOPLEFT", 0, 1)
        row.gold:SetPoint("BOTTOMRIGHT", 0, -1)
        if row.gold.SetBackdrop then
            row.gold:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            row.gold:SetBackdropBorderColor(1, 0.82, 0, 1)
            row.gold:SetBackdropColor(1, 0.82, 0, 0.07)
        end
        row.gold:SetFrameLevel(math.max(0, row.body:GetFrameLevel() - 1))
        row.sep = CreateFrame("Frame", nil, row)
        row.sep:SetAllPoints()
        row.sep.text = NewLabel(row.sep, nil, "GameFontNormal")
        row.sep.text:SetPoint("BOTTOMLEFT", 8, 6)
        local line = row.sep:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(1, 0.82, 0, 0.25)
        line:SetHeight(1)
        line:SetPoint("LEFT", row.sep.text, "RIGHT", 10, 0)
        line:SetPoint("RIGHT", row.sep, "RIGHT", -8, 0)
    end
    if data.separator then
        row.body:Hide()
        row.gold:Hide()
        row.sep:Show()
        row.sep.text:SetText(data.text)
        row:SetScript("OnUpdate", nil)
        return
    end
    row.sep:Hide()
    row.body:Show()
    row.gold:SetShown(data.invite == true)
    InitGroupRow(row.body, data.listing, data.invite)
    row.body:SetAlpha(data.dim and DIMMED or 1)
    row:SetScript("OnUpdate", data.dim and DimOnHover or nil)
end

local function BrowseRowHeight(data)
    return data.separator and SEPARATOR_HEIGHT or LISTING_ROW_HEIGHT
end

-- Availability page (Groups, next to My group): everything leaders will see, chosen first,
-- then started in one click. Roles (the same as the roles bar), dungeons (any at my level, or
-- a list), duration, note, and a preview of my row. Already available: the same page saves
-- the changes, or stops.

-- Dungeons an available player asked for, short enough for one line: two names, then "+2".
-- dungeons: a set; empty or nil means any dungeon at their level (anyText).
local function DungeonsShort(dungeons, anyText)
    if not dungeons or not next(dungeons) then return anyText end
    local names = {}
    for key in pairs(dungeons) do names[#names + 1] = ns.DungeonName(key) end
    table.sort(names)
    if #names <= 2 then return table.concat(names, ", ") end
    return names[1] .. ", " .. names[2] .. " " .. format(L["+%d more"], #names - 2)
end

-- The second line of a player in the Players list: roles, dungeons (short), note.
local function AvailDetail(roles, dungeons, note, anyText)
    local icons = ""
    for _, role in ipairs(ns.Groups.ROLES) do
        if roles and roles[role] then icons = icons .. ns.RoleIcon(role) .. " " end
    end
    note = note and strtrim(note) ~= "" and ("  |cffffffff\"" .. strtrim(note) .. "\"|r") or ""
    return icons .. "|cff9fdf7f" .. DungeonsShort(dungeons, anyText) .. "|r" .. note
end

-- Why I can't be available while in a party, said for where I am: leading my posted group,
-- in someone's group of the finder, or just in a party. onList: the Availability list (where
-- my posted group's fitting players show below).
local function InPartyText(onList)
    local mine = ns.Groups:GetMine()
    if mine then
        return onList and format(L["Your group is posted (%s): the available players who fit it are below."], ns.DungeonName(mine.dungeon))
            or format(L["Your group is posted (%s): no need to be available."], ns.DungeonName(mine.dungeon))
    end
    local joined = ns.Groups:GetJoined()
    if joined then
        return format(L["You're in %s's group (%s)."], joined.leader, ns.DungeonName(joined.dungeon))
    end
    return L["You're in a party: post a group for your party instead."]
end

-- Tooltip lines with everything: roles, every dungeon, the note.
local function AvailTooltip(title, roles, dungeons, note, anyText)
    local lines = { title }
    local roleNames = {}
    for _, role in ipairs(ns.Groups.ROLES) do
        if roles and roles[role] then roleNames[#roleNames + 1] = ns.RoleIcon(role) .. " " .. ns.RoleLabel(role) end
    end
    if #roleNames > 0 then lines[#lines + 1] = table.concat(roleNames, "   ") end
    if dungeons and next(dungeons) then
        local keys = {}
        for key in pairs(dungeons) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return ns.DungeonName(a) < ns.DungeonName(b) end)
        lines[#lines + 1] = "|cffffd100" .. L["Dungeons"] .. ":|r"
        for _, key in ipairs(keys) do
            -- With the name in the other languages switched on in Options, in grey.
            local others = {}
            local d = ns.DungeonByKey(key)
            for _, lang in ipairs(ns.OtherDungeonLanguages()) do
                local name = d and lang.get(d)
                if name and (ns.db.dungeonLanguages or {})[lang.key] then
                    others[#others + 1] = name
                end
            end
            lines[#lines + 1] = "|cff9fdf7f" .. ns.DungeonName(key) .. "|r"
                .. (#others > 0 and ("  |cff808080(" .. table.concat(others, ", ") .. ")|r") or "")
        end
    else
        lines[#lines + 1] = "|cff9fdf7f" .. anyText .. "|r"
    end
    if note and strtrim(note) ~= "" then lines[#lines + 1] = "\"" .. strtrim(note) .. "\"" end
    return lines
end

local function NewRadio(parent, text, onClick)
    local b = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    b:SetSize(18, 18)
    local label = b.text or b.Text
    if not label then
        label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", b, "RIGHT", 4, 0)
    end
    label:SetFontObject(GameFontHighlight)
    label:SetText(text)
    b:SetHitRectInsets(0, -(label:GetStringWidth() + 6), 0, 0)
    b:SetScript("OnClick", onClick)
    return b
end

-- parent: the Availability page; onDone() goes back to its list (after Save, Stop or Back).
local function BuildAvailabilityForm(parent, onDone)
    local P = ns.Players
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:Hide()
    local inner = f
    local back = NewButton(f, L["Back"], 110)
    back:SetPoint("TOPRIGHT", -2, -4)
    back:SetScript("OnClick", function() onDone() end)
    NewPageTitle(f, L["I'm available"], { L["I'm available"],
        L["Tell the guild you want a group: leaders see your roles and the dungeons you want, and can invite you."] })
    -- Where I'm at, under the title.
    f.status = NewLabel(f, "", "GameFontHighlight")
    f.status:SetPoint("TOPLEFT", 8, -38)
    f.status:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    f.status:SetJustifyH("LEFT")
    local TOP = -62  -- the form starts here
    local LEFT = 110 -- x of the input column

    local draft -- { roles = {}, any = bool, dungeons = {}, duration, note }

    -- Roles
    NewLabel(inner, L["Roles"]):SetPoint("TOPLEFT", 8, TOP - 18)
    f.roleButtons = {}
    for i, role in ipairs(ns.Groups.ROLES) do
        local button = NewRoleButton(inner, role, 36, function()
            draft.roles[role] = not draft.roles[role] or nil
            f:Refresh()
        end)
        button:SetPoint("TOPLEFT", LEFT + 6 + (i - 1) * 52, TOP - 6)
        f.roleButtons[role] = button
    end
    local rolesHint = NewLabel(inner, L["The same as the roles bar of the Groups tab."], "GameFontDisableSmall")
    rolesHint:SetPoint("TOPLEFT", LEFT + 6 + 3 * 52 + 8, TOP - 20)

    -- Dungeons: any at my level, or the ones ticked in the list (ticking one picks "chosen").
    NewLabel(inner, L["Dungeons"]):SetPoint("TOPLEFT", 8, TOP - 62)
    f.any = NewRadio(inner, L["Any dungeon at my level"], function() draft.any = true f:Refresh() end)
    f.any:SetPoint("TOPLEFT", LEFT, TOP - 60)
    f.chosen = NewRadio(inner, L["Chosen dungeons"], function() draft.any = false f:Refresh() end)
    f.chosen:SetPoint("TOPLEFT", LEFT, TOP - 84)
    f.list = NewScrollList(inner, 22, function(row, d)
        if not row.built then
            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetSize(22, 22)
            row.check:SetPoint("LEFT", 4, 0)
            NewDungeonLine(row, 30)
            row.check:SetHitRectInsets(0, -360, 0, 0)
            row.built = true
        end
        SetDungeonLine(row, d)
        row.check:SetChecked(draft.dungeons[d.key] == true)
        row.check:SetScript("OnEnter", function() DungeonTip(row, d) end)
        row.check:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.check:SetScript("OnClick", function(self)
            draft.dungeons[d.key] = self:GetChecked() and true or nil
            draft.any = false
            f:Refresh()
        end)
    end)
    f.list:SetPoint("TOPLEFT", LEFT + 16, TOP - 108)
    f.list:SetPoint("RIGHT", inner, "RIGHT", -24, 0)
    f.list:SetHeight(22 * 7)

    -- Duration: one button per length, the chosen one lit.
    NewLabel(inner, L["Duration"]):SetPoint("TOPLEFT", 8, TOP - 280)
    f.durations = {}
    local previous
    for _, seconds in ipairs(P.DURATIONS) do
        -- "Until I log out" is too long for a button: "No time limit", the full words in its tooltip.
        local b = NewButton(inner, seconds == 0 and L["No time limit"] or P.DurationText(seconds), 64, 22)
        b:SetWidth(math.max(64, (b.GetTextWidth and b:GetTextWidth() or 60) + 28))
        if seconds == 0 then
            b:SetScript("OnEnter", function(self) ShowTooltip(self, { L["No time limit"], L["Until I log out"] }) end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", LEFT, TOP - 276) end
        b:SetScript("OnClick", function() draft.duration = seconds f:Refresh() end)
        b.seconds = seconds
        f.durations[#f.durations + 1] = b
        previous = b
    end

    -- Note
    NewLabel(inner, L["Note"]):SetPoint("TOPLEFT", 8, TOP - 316)
    f.note = NewInput(inner, 380, 80)
    f.note:SetPoint("TOPLEFT", LEFT + 4, TOP - 310)
    SetPlaceholder(f.note, L["Note (optional), e.g. quests in BFD"])
    f.note:HookScript("OnTextChanged", function(self, user) if user then draft.note = self:GetText() f:Refresh() end end)

    -- What leaders will see: my row as the Players page shows it (hover it for everything).
    NewLabel(inner, L["Leaders will see:"], "GameFontNormal"):SetPoint("TOPLEFT", 8, TOP - 350)
    local preview = CreateFrame("Frame", nil, inner)
    preview:SetPoint("TOPLEFT", 4, TOP - 368)
    preview:SetPoint("RIGHT", inner, "RIGHT", -4, 0)
    preview:SetHeight(40)
    RowBackground(preview)
    preview.name = NewLabel(preview)
    preview.name:SetPoint("TOPLEFT", 8, -4)
    preview.detail = NewLabel(preview, nil, "GameFontHighlightSmall")
    preview.detail:SetPoint("TOPLEFT", preview.name, "BOTTOMLEFT", 0, -3)
    preview.detail:SetPoint("RIGHT", preview, "RIGHT", -8, 0)
    preview.detail:SetJustifyH("LEFT")
    preview.detail:SetWordWrap(false)
    preview:EnableMouse(true)
    preview:SetScript("OnEnter", function(self) ShowTooltip(self, self.tooltip) end)
    preview:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.preview = preview

    -- Bottom bar: what's left to do on the left, the main action on the right (like the
    -- create form).
    f.confirm = NewButton(inner, "", 180, 26)
    f.confirm:SetPoint("BOTTOMRIGHT", -2, 6)
    -- Greyed out: why, in its tooltip.
    f.confirm:SetMotionScriptsWhileDisabled(true)
    f.confirm:SetScript("OnEnter", function(self)
        if self.why then ShowTooltip(self, { self:GetText(), "|cffff4040" .. self.why .. "|r" }) end
    end)
    f.confirm:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.second = NewButton(inner, "", 200, 26)
    f.second:SetPoint("RIGHT", f.confirm, "LEFT", -8, 0)
    f.message = NewLabel(inner, "", "GameFontHighlightSmall")
    f.message:SetPoint("LEFT", inner, "BOTTOMLEFT", 8, 19)
    f.message:SetPoint("RIGHT", f.second, "LEFT", -10, 0)
    f.message:SetJustifyH("RIGHT")

    -- The form starts from my saved choices each time the page opens (and after Save / Stop).
    function f:Load()
        local s = P.Settings()
        draft = { roles = CopyTable(ns.Groups:GetMyRoles()), dungeons = CopyTable(s.dungeons),
            duration = s.duration or P.DEFAULT_DURATION, note = s.note or "" }
        draft.any = not next(draft.dungeons)
        self.note:SetText(draft.note)
    end
    f:SetScript("OnShow", function(self) self:Load() end)

    function f:Refresh()
        if not draft then self:Load() end
        local active = P:IsActive()
        local class = MyClass()
        if active then
            local left = P:Remaining()
            self.status:SetText("|cff20ff20" .. (left and format(L["Available for %d more min"], math.max(1, math.ceil(left / 60)))
                or L["Available until you log out"]) .. "|r"
                .. (P:IsPaused() and ("  |cffffd100" .. L["(paused: in a dungeon)"] .. "|r") or ""))
        else
            self.status:SetText("|cff808080" .. L["You're not available."] .. "|r")
        end
        for role, button in pairs(self.roleButtons) do
            button:SetAllowed(ns.CanTakeRole(class, role))
            button:SetChecked(draft.roles[role] == true)
        end
        self.any:SetChecked(draft.any)
        self.chosen:SetChecked(not draft.any)
        SetListData(self.list, PickableDungeons(false))
        self.list:SetAlpha(draft.any and 0.45 or 1)
        for _, b in ipairs(self.durations) do
            if b.seconds == draft.duration then b:LockHighlight() else b:UnlockHighlight() end
        end

        -- Preview: the same two lines as in the Players list (and its tooltip with everything).
        local dungeons = (not draft.any) and draft.dungeons or nil
        local me = ns.FullName("player")
        self.preview.name:SetText(NameText(me, class) .. " |cff808080" .. format(L["Level %d"], UnitLevel("player")) .. "|r")
        self.preview.detail:SetText(AvailDetail(draft.roles, dungeons, draft.note, L["any dungeon at their level"]))
        self.preview.tooltip = AvailTooltip(NameText(me, class), draft.roles, dungeons, draft.note, L["any dungeon at their level"])

        -- Buttons: start (or save), and stop while available.
        local why
        if not next(draft.roles) then
            why = L["Tick at least one role you can play first."]
        elseif not draft.any and not next(draft.dungeons) then
            why = L["Choose at least one dungeon, or any dungeon at my level."]
        elseif not active and (ns.InParty() or ns.Groups:GetMine()) then
            why = InPartyText(false)
        end
        -- Why the button is greyed out: in its tooltip. The bottom line is for errors only.
        self.message:SetText("")
        self.confirm.why = why
        self.confirm:SetText(active and L["Save"] or L["I'm available"])
        self.confirm:SetEnabled(why == nil)
        self.second:SetText(L["Remove my availability"]) -- like "Remove group" on My group
        self.second:SetShown(active)
    end

    f.confirm:SetScript("OnClick", function()
        local active = P:IsActive()
        local d = CopyTable(draft)
        if d.any then wipe(d.dungeons) end
        local ok, err = P:Apply(d, not active)
        if ok then
            f:Load()
            onDone()
        elseif err then
            f.message:SetText("|cffff4040" .. err .. "|r")
        end
    end)
    f.second:SetScript("OnClick", function()
        P:Stop(L["You're no longer available."])
        f:Load()
        onDone()
    end)
    return f
end

-- "I'm available..." buttons (Availability page, minimap menu): the Availability form.
local function OpenAvailability()
    UI:Open()
    UI:ShowPage("players")
    if panels.players then panels.players:ShowForm(true) end
end
UI.OpenAvailability = OpenAvailability

local function AvailabilityTooltip(owner)
    local P = ns.Players
    local lines = { L["I'm available"],
        L["Tell the guild you want a group: leaders see your roles (ticked in the group list) and the dungeons you want, and can invite you."] }
    if not P:IsActive() and (ns.InParty() or ns.Groups:GetMine()) then
        -- Why the button is greyed out.
        lines[#lines + 1] = "|cffff4040" .. InPartyText(false) .. "|r"
    elseif P:IsPaused() then
        lines[#lines + 1] = "|cffffd100" .. L["Paused while you're in a dungeon."] .. "|r"
    end
    ShowTooltip(owner, lines)
end

-- In a group of the finder (mine, or someone else's I joined)? Then Groups opens on My group,
-- and Browse is a look around, with a way back.
local function InFinderGroup()
    return (ns.Groups:GetMine() or ns.Groups:GetJoined()) and true or false
end

-- The page the Groups tab opens: My group while in one, Browse otherwise.
local function GroupsHome()
    return InFinderGroup() and "mygroup" or "browse"
end

local function BuildGroupsPanel()
    local p = NewPanel()
    p.header = NewPageTitle(p, "")
    p.hidden = NewLabel(p, nil, "GameFontDisableSmall")
    p.hidden:SetPoint("LEFT", p.header, "RIGHT", 10, 0)
    -- Shortcut to the create form, only when I'm not already in a group of the finder.
    -- (Groups is for groups; "I'm available" lives on the Availability tab.)
    p.create = NewButton(p, L["Create a group"], 160)
    p.create:SetPoint("TOPRIGHT", -2, -4)
    p.create:SetScript("OnClick", function() UI:ShowPage("mygroup") end)
    -- In a group of the finder: back to it, top right (where "Create a group" is otherwise),
    -- green like the minimap menu's entry.
    p.back = NewButton(p, "|cff20ff20" .. L["My group"] .. "|r", 160)
    p.back:SetPoint("TOPRIGHT", -2, -4)
    p.back:SetScript("OnClick", function() UI:ShowPage("mygroup") end)

    -- What I offer, like the game's group finder: every role I can play (the leader picks one
    -- when accepting), and whether I'm a new player. Saved per character.
    local bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", 0, -36)
    bar:SetPoint("RIGHT", p, "RIGHT", -2, 0)
    bar:SetHeight(46)
    if bar.SetBackdrop then
        bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        bar:SetBackdropColor(1, 1, 1, 0.04)
    end
    NewLabel(bar, L["I can play:"]):SetPoint("LEFT", 10, 0)
    p.roleButtons = {}
    for i, role in ipairs(ns.Groups.ROLES) do
        local button = NewRoleButton(bar, role, 34, function()
            local mine = ns.Groups:GetMyRoles()
            ns.Groups:SetMyRole(role, not mine[role])
        end)
        button:SetPoint("LEFT", 110 + (i - 1) * 52, 2)
        p.roleButtons[role] = button
    end
    p.newbie = NewCheckbox(bar, ns.NewbieIcon(16) .. " " .. L["I'm a new player"], function(self)
        ns.Groups:SetNewPlayer(self:GetChecked())
    end)
    p.newbie:SetPoint("LEFT", 284, 0)
    p.newbie:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["I'm a new player"], L["Leaders see it with your request."] })
    end)
    p.newbie:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Filters of the list, not something about me: the button at the right end of the bar opens
    -- a row of filters right under it, above the list (open or closed is remembered).
    -- All off by default.
    local G = ns.Groups
    p.filters = NewButton(bar, L["Filters"], 130)
    p.filters:SetPoint("RIGHT", -8, 0)
    p.filters:SetScript("OnClick", function()
        ns.db.filtersOpen = not ns.db.filtersOpen or nil
        p:Refresh()
    end)
    p.filters:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["Filters"], L["Off by default: every group shows."] })
    end)
    p.filters:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local fp = CreateFrame("Frame", nil, p, "BackdropTemplate")
    fp:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
    fp:SetPoint("RIGHT", p, "RIGHT", -2, 0)
    fp:SetHeight(66)
    -- Set apart from the roles bar above and the list below: a gold frame and a warmer tint.
    if fp.SetBackdrop then
        fp:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        fp:SetBackdropColor(1, 0.82, 0, 0.12)
        fp:SetBackdropBorderColor(1, 0.82, 0, 0.8)
    end
    p.filterPanel = fp

    -- First line: three switches, short labels (the full meaning in their tooltips).
    local function FilterCheck(text, tip, get, set)
        local cb = NewCheckbox(fp, text, function(self) set(self:GetChecked()) end)
        cb:SetScript("OnEnter", function(self) ShowTooltip(self, { text, tip }) end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cb.get = get
        return cb
    end
    fp.role = FilterCheck(L["Needs one of my roles"], L["Groups that need a role I can play"],
        function() return G:GetFilters().role == true end, function(on) G:SetFilter("role", on) end)
    fp.role:SetPoint("TOPLEFT", 6, -4)
    fp.level = FilterCheck(L["At my level"], L["Dungeons at my level"],
        function() return G:GetFilters().level == true end, function(on) G:SetFilter("level", on) end)
    PlaceAfterLabel(fp.level, fp.role, 24)
    fp.running = FilterCheck(L["Hide groups in progress"], L["Groups that are complete or already running don't show."],
        function() return ns.db.hideRunning == true end, function(on) ns.db.hideRunning = on or nil UI:Refresh() end)
    PlaceAfterLabel(fp.running, fp.level, 24)

    -- Second line: the dungeons, in a dropdown of checkboxes (it scrolls, and stays open while
    -- ticking), then "Show everything".
    local dungeonsLabel = NewLabel(fp, L["Dungeons"])
    dungeonsLabel:SetPoint("TOPLEFT", 12, -42)
    -- Its text: "All dungeons", the one chosen, or "3 dungeons".
    fp.dungeons = NewDungeonPicker(fp, 320, function()
        local names = {}
        for key in pairs(G:GetFilters().dungeons) do names[#names + 1] = ns.DungeonName(key) end
        return (#names == 0 and L["All dungeons"]) or (#names == 1 and names[1]) or format(L["%d dungeons"], #names)
    end, {
        multi = true, withTest = true,
        isSelected = function(key) return G:GetFilters().dungeons[key] == true end,
        onPick = function(key) G:SetDungeonFilter(key, not G:GetFilters().dungeons[key]) end,
        clearText = L["All dungeons"],
        onClear = function()
            for key in pairs(G:GetFilters().dungeons) do G:SetDungeonFilter(key, false) end
        end,
    })
    fp.dungeons:SetPoint("LEFT", dungeonsLabel, "RIGHT", 12, 0)
    function fp:DungeonsText() self.dungeons:Update() end
    local clear = NewButton(fp, L["Show everything"], 140, 22)
    clear:SetPoint("BOTTOMRIGHT", -8, 8)
    clear:SetScript("OnClick", function() G:ClearFilters() end)
    fp.clear = clear

    function fp:Refresh()
        for _, cb in ipairs({ self.role, self.level, self.running }) do cb:SetChecked(cb.get()) end
        self:DungeonsText()
        self.clear:SetEnabled(G:CountFilters() > 0)
    end

    p.empty = NewLabel(p, L["No open groups right now."], "GameFontDisable")
    p.empty:SetPoint("CENTER", 0, -10)
    p.emptyHint = NewLabel(p, L["Post yours: the whole guild sees it here."], "GameFontDisableSmall")
    p.emptyHint:SetPoint("TOP", p.empty, "BOTTOM", 0, -6)
    p.box = NewScrollList(p, BrowseRowHeight, InitBrowseRow)
    p.box:SetPoint("BOTTOMRIGHT", -20, 0)

    -- The list starts under the filters when they're open.
    function p:PlaceList()
        local open = ns.db.filtersOpen == true
        if self.filtersShown == open then return end
        self.filtersShown = open
        fp:SetShown(open)
        self.box:SetPoint("TOPLEFT", 0, open and -156 or -88)
        if open then self.filters:LockHighlight() else self.filters:UnlockHighlight() end
    end

    function p:Refresh()
        self:PlaceList()
        if fp:IsShown() then fp:Refresh() end
        local myRoles = ns.Groups:GetMyRoles()
        local class = MyClass()
        for role, button in pairs(self.roleButtons) do
            button:SetAllowed(ns.CanTakeRole(class, role))
            button:SetChecked(myRoles[role] == true)
        end
        self.newbie:SetChecked(ns.Groups:IsNewPlayer())
        local filterCount = ns.Groups:CountFilters()
        self.filters:SetText(filterCount > 0 and format(L["Filters (%d)"], filterCount) or L["Filters"])

        -- Invitations first, in a gold frame. Then groups I can join (and mine, and the ones
        -- I'm in); groups in progress or full after a separator, dimmed: still there to see,
        -- out of the way. Filters never hide my group, the ones I'm in, or invitations.
        local invitations = ns.Groups:GetInvitations()
        local invited = {}
        for _, l in ipairs(invitations) do invited[l.id] = true end
        local active, busy, filtered = {}, {}, 0
        for _, l in ipairs(ns.Groups:GetListings()) do
            local state = ns.Groups:GetState(l)
            local mineOrIn = ns.Groups:IsMine(l) or ns.Groups:IsInvolved(l)
            if invited[l.id] then
                -- shown at the top
            elseif mineOrIn then
                active[#active + 1] = { listing = l }
            elseif not ns.Groups:PassesFilters(l) or (ns.db.hideRunning and state == "running") then
                filtered = filtered + 1
            elseif state ~= "running" and state ~= "full" then
                active[#active + 1] = { listing = l }
            else
                busy[#busy + 1] = { listing = l, dim = true }
            end
        end
        local openCount = #active
        local list = {}
        if #invitations > 0 then
            list[1] = { separator = true, text = L["You're invited"] }
            for _, l in ipairs(invitations) do list[#list + 1] = { listing = l, invite = true } end
            if #active > 0 then list[#list + 1] = { separator = true, text = format(L["Open groups (%d)"], openCount) } end
        end
        for _, entry in ipairs(active) do list[#list + 1] = entry end
        if #busy > 0 then
            list[#list + 1] = { separator = true, text = format(L["In progress or full (%d)"], #busy) }
            for _, entry in ipairs(busy) do list[#list + 1] = entry end
        end
        self.header:SetText(format(L["Open groups (%d)"], openCount))
        self.hidden:SetText(filtered > 0 and format(L["(%d hidden by the filters)"], filtered) or "")
        local free = not ns.Groups:GetMine() and not ns.Groups:GetJoined()
        self.create:SetShown(free and true or false)
        self.back:SetShown(not free)
        self.empty:SetShown(#list == 0)
        self.emptyHint:SetShown(#list == 0 and free and true or false)
        SetListData(self.box, list)
    end
    return p
end


-- My group tab: create form -------------------------------------------------------------

local COL = 140        -- x of the input column
local MEMBER_ROW = 30  -- member rows height
local VISIBLE_MEMBERS = 5

local function BuildCreateForm(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f.partyRoles = {} -- [key] = role, for party members
    f.extra = {}      -- typed players to invite: { name, class, level }

    local formTitle = NewPageTitle(f, L["Create a group"])
    -- The form keeps the last group's choices on purpose (you often post the same again);
    -- this starts it from empty.
    local reset = NewButton(f, L["Reset"], 110, 20)
    reset:SetPoint("LEFT", formTitle, "RIGHT", 14, 0)
    reset:SetScript("OnClick", function() f:Reset() end)
    local back = NewButton(f, L["Back"], 110)
    back:SetPoint("TOPRIGHT", -2, -4)
    back:SetScript("OnClick", function() UI:ShowPage("browse") end)

    -- Dungeon
    NewLabel(f, L["Dungeon"]):SetPoint("TOPLEFT", 8, -50)
    -- The chosen dungeon shows with its range, in its difficulty color.
    local dropdown = NewDungeonPicker(f, 360, function()
        local d = f.dungeon and ns.DungeonByKey(f.dungeon)
        return d and ns.DungeonLabel(d) or ("|cff808080" .. L["Choose a dungeon"] .. "|r")
    end, {
        withTest = true,
        isSelected = function(key) return f.dungeon == key end,
        selected = function() return f.dungeon end,
        onPick = function(key) f.dungeon = key; f.error = nil; f:Refresh() end,
    })
    dropdown:SetPoint("TOPLEFT", COL, -44)

    -- My role: big role icons with a checkbox. Starts with the role of the last group I posted
    -- (none the first time); clicking it again unpicks it. Picking one ticks it in the roles bar of the group list too (it
    -- replaces the role ticked there when there's only one, it's added when there are several).
    NewLabel(f, L["My role"]):SetPoint("TOPLEFT", 8, -98)
    f.roleButtons = {}
    for i, role in ipairs(ns.Groups.ROLES) do
        local button = NewRoleButton(f, role, 44, function()
            f.error = nil
            if f.myRole == role then -- unpick (the group still needs one before posting)
                f.myRole = nil
                f:Refresh()
                return
            end
            local ticked = ns.Groups.RoleList(ns.Groups:GetMyRoles())
            f.myRole = role
            if #ticked == 1 and ticked[1] ~= role then ns.Groups:SetMyRole(ticked[1], false) end
            ns.Groups:SetMyRole(role, true)
            f:Refresh()
        end)
        button:SetPoint("TOPLEFT", COL + 8 + (i - 1) * 64, -80)
        f.roleButtons[role] = button
    end

    -- Looking for: the role mix, the default for the size until changed with the arrows.
    local function Size()
        return f.dungeon and ns.DungeonSize(f.dungeon) or 5
    end
    f.mixRow = NewMixRow(f, function(values)
        f.mix = values or CopyTable(ns.Groups.DEFAULT_COMPOSITION[Size()])
        f:Refresh()
    end)
    f.mixRow:SetPoint("TOPLEFT", 0, -132)
    f.mixRow:SetPoint("RIGHT", f, "RIGHT", -8, 0)

    -- Note, a few lines
    local Y = -176
    NewLabel(f, L["Note"]):SetPoint("TOPLEFT", 8, Y - 6)
    local noteArea = NewTextArea(f, 460, 64, ns.Groups.NOTE_MAX)
    noteArea:SetPoint("TOPLEFT", COL, Y)
    noteArea:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    local note = noteArea.edit
    SetPlaceholder(note, L["Example: chain runs, quests welcome"])

    -- Group options: new players welcome, Discord required (and which channel)
    f.newbies = NewCheckbox(f, ns.NewbieIcon(16) .. " " .. L["New players welcome"], function() f:Refresh() end)
    f.newbies:SetPoint("TOPLEFT", COL - 4, Y - 70)
    f.discord = NewCheckbox(f, ns.DiscordIcon(16) .. " " .. L["Discord required"], function() f:Refresh() end)
    PlaceAfterLabel(f.discord, f.newbies, 28)
    f.discordChannel = NewInput(f, 180, 40)
    PlaceAfterLabel(f.discordChannel, f.discord, 14)
    SetPlaceholder(f.discordChannel, L["Channel name"])

    -- Reset only shows when there's something to clear: a dungeon, my role, players added,
    -- roles given to party members, a changed mix, a note, an option.
    local function UpdateReset()
        local dirty = f.dungeon or f.myRole ~= ns.Groups:GetLastRole() or next(f.extra) or next(f.partyRoles) or f.mixChanged
            or f.newbies:GetChecked() or f.discord:GetChecked()
            or strtrim(note:GetText() or "") ~= "" or strtrim(f.discordChannel:GetText() or "") ~= ""
        reset:SetShown(dirty and true or false)
    end
    note:HookScript("OnTextChanged", UpdateReset)
    f.discordChannel:HookScript("OnTextChanged", UpdateReset)

    -- Group members: me, my party (role to choose), players to invite (remove button).
    -- Adding a player sits on the header row, right above the list it fills.
    f.membersHeader = NewLabel(f, L["Group members"], "GameFontNormal")
    f.membersHeader:SetPoint("TOPLEFT", 8, Y - 114)
    f.nameInput = NewNameInput(f, 240, function(picked) f:AddExtra(picked) end)
    f.nameInput:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.nameInput:SetPoint("BOTTOM", f.membersHeader, "BOTTOM", 0, -4)
    SetPlaceholder(f.nameInput, L["Add a guild member..."])

    f.members = NewScrollList(f, MEMBER_ROW, function(row, e)
        if not row.built then
            RowBackground(row)
            row.name = NewLabel(row)
            row.name:SetPoint("LEFT", 8, 0)
            row.status = NewLabel(row, nil, "GameFontDisableSmall")
            row.status:SetPoint("LEFT", 270, 0)
            row.roleText = NewLabel(row)
            row.roleText:SetPoint("LEFT", 400, 0)
            row.roleDropdown = NewRoleDropdown(row, 150,
                function() return row.entry and f.partyRoles[row.entry.key] end,
                function(role) if row.entry then f.partyRoles[row.entry.key] = role; f:Refresh() end end,
                function() return row.entry and row.entry.class end)
            row.roleDropdown:SetPoint("LEFT", 394, 0)
            row.remove = NewIconButton(row, "remove", L["Remove"])
            row.remove:SetPoint("RIGHT", -10, 0)
            row.remove:SetScript("OnClick", function()
                for idx, x in ipairs(f.extra) do
                    if row.entry and ns.NameKey(x.name) == row.entry.key then table.remove(f.extra, idx) break end
                end
                f:Refresh()
            end)
            row.built = true
        end
        row.entry = e
        row.name:SetText(NameText(e.name, e.class, e.tag or e.guest))
        row.roleDropdown:SetShown(e.kind == "party")
        row.roleText:SetShown(e.kind ~= "party")
        row.remove:SetShown(e.kind == "extra")
        if e.kind == "me" then
            row.status:SetText(L["You"])
            row.roleText:SetText(f.myRole and RoleText(f.myRole) or ("|cff808080" .. L["Choose your role above"] .. "|r"))
        elseif e.kind == "party" then
            row.status:SetText(L["In your party"])
            RefreshDropdown(row.roleDropdown)
        else
            row.status:SetText(L["Will be invited"])
            row.roleText:SetText("")
        end
    end)
    f.members:SetPoint("TOPLEFT", f.membersHeader, "BOTTOMLEFT", -8, -10)
    f.members:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 46)

    -- Bottom bar: what's still missing on the left, the main action on the right.
    local post = NewButton(f, L["Post group"], 180, 26)
    post:SetPoint("BOTTOMRIGHT", -2, 6)
    -- Greyed out: what's still missing, in its tooltip.
    post:SetMotionScriptsWhileDisabled(true)
    post:SetScript("OnEnter", function(self)
        if self.why then ShowTooltip(self, { L["Post group"], "|cffff4040" .. self.why .. "|r" }) end
    end)
    post:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.message = NewLabel(f, nil, "GameFontHighlightSmall")
    f.message:SetPoint("LEFT", f, "BOTTOMLEFT", 8, 19)
    f.message:SetPoint("RIGHT", post, "LEFT", -12, 0)
    f.message:SetJustifyH("RIGHT")
    f.message:SetWordWrap(false)
    -- An error about the player just typed stays until the form changes.
    local function Error(text)
        f.error = text
        f.message:SetText("|cffff4040" .. text .. "|r")
    end

    -- Me, then my party (mirrors the real party), then players to invite.
    local function Entries()
        local entries = {}
        local myKey = ns.NameKey(ns.FullName("player"))
        local party = ns.Groups.CurrentParty()
        local me = party[myKey]
        entries[1] = { kind = "me", key = myKey, name = me.name, class = me.class }
        local others = {}
        for key, info in pairs(party) do
            if key ~= myKey then
                if not f.partyRoles[key] and info.assignedRole then f.partyRoles[key] = info.assignedRole end
                if f.partyRoles[key] and not ns.CanTakeRole(info.class, f.partyRoles[key]) then f.partyRoles[key] = nil end
                others[#others + 1] = {
                    kind = "party", key = key, name = info.name, class = info.class,
                    guest = not ns.Guild:IsMember(info.name), tag = ns.Groups.TagFor(info.name, info.guild),
                }
            end
        end
        table.sort(others, function(a, b) return a.name < b.name end)
        for _, e in ipairs(others) do entries[#entries + 1] = e end
        for _, e in ipairs(f.extra) do
            local key = ns.NameKey(e.name)
            if not party[key] then -- they joined the party meanwhile: already listed above
                entries[#entries + 1] = { kind = "extra", key = key, name = e.name, class = e.class, tag = e.tag }
            end
        end
        return entries
    end

    function f:AddExtra(picked)
        local member = ns.Groups:FindPlayer(picked.name)
        if not member then
            Error(format(ns.Alliance:IsActive() and L["%s is not in the guild or the Guild Alliance."]
                or L["%s is not in the guild."], picked.name))
            return
        end
        local entries = Entries()
        local key = ns.NameKey(member.name)
        for _, e in ipairs(entries) do
            if e.key == key then
                Error(format(L["%s is already in the list."], member.name))
                return
            end
        end
        if #entries >= Size() then
            Error(format(L["This group has %d places at most."], Size()))
            return
        end
        self.extra[#self.extra + 1] = { name = member.name, class = member.class, level = member.level, tag = member.tag }
        self.error = nil
        self:Refresh()
    end

    function f:Refresh()
        -- "Create this group" from the Players page: start on that dungeon.
        if UI.presetDungeon then
            self.dungeon = UI.presetDungeon
            UI.presetDungeon = nil
            self.error = nil
        end
        dropdown:Update()
        local myClass = MyClass()
        -- The first time the form shows: the role of the last group I posted.
        if not self.roleLoaded then
            self.roleLoaded = true
            self.myRole = self.myRole or ns.Groups:GetLastRole()
        end
        if self.myRole and not ns.CanTakeRole(myClass, self.myRole) then self.myRole = nil end
        for role, button in pairs(self.roleButtons) do
            button:SetAllowed(ns.CanTakeRole(myClass, role))
            button:SetChecked(self.myRole == role)
        end

        local size = Size()
        -- A new size (5 / 10 / test) starts from its default mix.
        if self.mixSize ~= size then
            self.mixSize = size
            self.mix = CopyTable(ns.Groups.DEFAULT_COMPOSITION[size] or ns.Groups.DEFAULT_COMPOSITION[5])
        end
        self.discordChannel:SetShown(self.discord:GetChecked())

        local entries = Entries()
        SetListData(self.members, entries)
        local taken = { self.myRole }
        for _, e in ipairs(entries) do
            if e.kind == "party" and self.partyRoles[e.key] then taken[#taken + 1] = self.partyRoles[e.key] end
        end
        self.mix = FitMix(self.mix, taken)
        self.mixRow:SetMix(self.mix, size, MissingFor(self.mix, taken))
        local default = ns.Groups.DEFAULT_COMPOSITION[size] or ns.Groups.DEFAULT_COMPOSITION[5]
        self.mixChanged = not SameMix(self.mix, FitMix(default, taken))
        UpdateReset()

        -- Validation
        local err
        local canPost, why = ns.Groups:CanPost()
        if not canPost then
            err = why
        elseif not self.dungeon then
            err = L["Choose a dungeon."]
        elseif not self.myRole then
            err = L["Choose your role."]
        elseif #entries > size then
            err = format(L["This group has %d places at most."], size)
        else
            for _, e in ipairs(entries) do
                if e.kind == "party" and not self.partyRoles[e.key] then
                    err = format(L["Choose a role for %s."], e.name)
                    break
                end
            end
        end
        -- What's left to do: in the greyed button's tooltip. The bottom line only shows an
        -- error (a player that can't be added).
        self.message:SetText(self.error and ("|cffff4040" .. self.error .. "|r") or "")
        post.why = err
        post:SetEnabled(err == nil)
    end

    function f:Reset()
        self.dungeon = nil
        self.myRole = ns.Groups:GetLastRole() -- back to the role of my last group
        self.error = nil
        wipe(self.extra)
        wipe(self.partyRoles)
        self.mixSize = nil -- back to the default mix
        self.newbies:SetChecked(false)
        self.discord:SetChecked(false)
        self.discordChannel:SetText("")
        note:SetText("")
        note:ClearFocus()
        dropdown:Update()
        self:Refresh()
    end

    post:SetScript("OnClick", function()
        local roles = CopyTable(f.partyRoles)
        roles[ns.NameKey(ns.FullName("player"))] = f.myRole
        local default = ns.Groups.DEFAULT_COMPOSITION[Size()]
        local composition = (default and not SameMix(f.mix, default)) and CopyTable(f.mix) or nil

        local posted = ns.Groups:Create(f.dungeon, roles, f.extra, strtrim(note:GetText() or ""), composition, {
            newbies = f.newbies:GetChecked(),
            discord = f.discord:GetChecked(),
            discordChannel = f.discordChannel:GetText(),
        })
        if not posted then return end
        ns.Groups:SetLastRole(f.myRole) -- the next form starts with it
        -- My group says it went out (see BuildManageView).
        UI.justPosted = GetTime()

        wipe(f.extra)
        f.error = nil
        note:SetText("")
        note:ClearFocus()
    end)

    return f
end

-- My group tab: leader view -----------------------------------------------------------------

local function MemberEntries(l)
    local leaderKey = ns.NameKey(l.leader)
    local out = {}
    for _, m in ipairs(ns.Groups:GetMembers(l)) do
        local entry = CopyTable(m)
        entry.statusText = m.key == leaderKey and (CROWN .. " " .. L["Leader"]) or L["In the group"]
        out[#out + 1] = entry
    end
    -- Invited and accepted players take a spot: they're listed with the members.
    for _, p in ipairs(ns.Groups:GetPending(l)) do
        if p.status ~= "request" then
            local entry = CopyTable(p)
            entry.pendingStatus = p.status
            out[#out + 1] = entry
        end
    end
    return out
end

local function Requests(l)
    local out = {}
    for _, p in ipairs(ns.Groups:GetPending(l)) do
        if p.status == "request" then out[#out + 1] = p end
    end
    return out
end

-- The member list is as tall as the group (up to 5 rows, it scrolls for a raid).
local function MemberRows(entries)
    return math.max(1, math.min(#entries, VISIBLE_MEMBERS))
end


local function BuildManageView(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetAllPoints()

    -- Header: the group on the left, "See the other groups" (My group panel) and Remove group
    -- on the right.
    local delist = NewButton(m, L["Remove group"], 150)
    delist:SetPoint("TOPRIGHT", -2, -4)
    delist:SetScript("OnClick", function() ns.Groups:Delist() end)
    m.delist = delist
    -- One short line in guild chat, on demand (at most once a minute): bottom left (away from
    -- where Post group was, under the mouse right after posting).
    m.guildPost = NewButton(m, L["Announce in chat"], 180)
    m.guildPost:SetPoint("BOTTOMLEFT", 2, 2)
    m.guildPost:SetMotionScriptsWhileDisabled(true)
    m.guildPost:SetScript("OnClick", function() ns.Groups:PostInGuild() end)
    m.guildPost:SetScript("OnEnter", function(self)
        local mine = ns.Groups:GetMine()
        local lines = { L["Announce in chat"],
            L["One short line in guild chat. The [La Taverne] tag tells it's listed in the addon. Once a minute at most."] }
        local text = mine and ns.Groups:GuildPostText(mine)
        if text then lines[#lines + 1] = "|cffffffff" .. text .. "|r" end
        local ok, why = ns.Groups:CanPostInGuild()
        if not ok then lines[#lines + 1] = "|cffff4040" .. why .. "|r" end

        ShowTooltip(self, lines)
    end)
    m.guildPost:SetScript("OnLeave", function() GameTooltip:Hide() end)

    m.title = NewLabel(m, nil, "GameFontNormalLarge")
    m.titleHit = NewDungeonHover(m, m.title)
    m.title:SetPoint("TOPLEFT", 8, -8)
    m.title:SetPoint("RIGHT", delist, "LEFT", -10, 0) -- then left of "See the other groups"
    m.title:SetJustifyH("LEFT")
    m.title:SetWordWrap(false)

    -- State notice, under the title, only once the group has started: icon, what happened,
    -- what it means, and the action in the box itself.
    local banner = CreateFrame("Frame", nil, m, "BackdropTemplate")
    banner:SetPoint("TOPLEFT", 2, -36)
    banner:SetPoint("RIGHT", m, "RIGHT", -2, 0)
    banner:SetHeight(58)
    if banner.SetBackdrop then
        banner:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
    end
    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetSize(26, 26)
    banner.icon:SetPoint("LEFT", 12, 0)
    banner.action = NewButton(banner, "", 210, 24)
    banner.action:SetPoint("RIGHT", -10, 0)
    banner.title = NewLabel(banner, "", "GameFontNormal")
    banner.title:SetPoint("TOPLEFT", 48, -9)
    banner.text = NewLabel(banner, "", "GameFontHighlightSmall")
    banner.text:SetPoint("TOPLEFT", banner.title, "BOTTOMLEFT", 0, -4)
    banner.text:SetPoint("RIGHT", banner.action, "LEFT", -12, 0)
    banner.text:SetJustifyH("LEFT")
    banner.text:SetWordWrap(true)
    if banner.text.SetMaxLines then banner.text:SetMaxLines(2) end
    m.banner = banner

    -- kind: "left" (someone left a started group), "looking" (looking for a replacement),
    -- "complete" (started, everyone's there), nil (not started: no notice).
    local BANNERS = {
        left = { icon = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew", border = { 1, 0.55, 0 }, bg = { 1, 0.5, 0, 0.10 },
            title = "Someone left the group",
            text = "Look for a replacement: the group shows as in progress, open to requests. Say in the note where you're at.",
            action = "Find a replacement", onClick = function() ns.Groups:Reopen() end },
        looking = { icon = "Interface\\Icons\\INV_Misc_Spyglass_02", border = { 1, 0.82, 0 }, bg = { 1, 0.82, 0, 0.06 },
            title = "Looking for a replacement",
            text = "Your group shows as in progress, open to requests. Say in the note where you're at.",
            action = "Stop looking", onClick = function() ns.Groups:StopReopen() end },
        complete = { icon = "Interface\\RaidFrame\\ReadyCheck-Ready", border = { 0.5, 0.5, 0.5 }, bg = { 1, 1, 1, 0.03 },
            title = "Group complete",
            text = "It shows as in progress and takes no more requests." },
    }
    function m:SetBanner(kind)
        local b = kind and BANNERS[kind]
        banner:SetShown(b ~= nil)
        if not b then return end
        banner.icon:SetTexture(b.icon)
        if banner.SetBackdrop then
            banner:SetBackdropBorderColor(b.border[1], b.border[2], b.border[3], 1)
            banner:SetBackdropColor(b.bg[1], b.bg[2], b.bg[3], b.bg[4])
        end
        banner.title:SetText(L[b.title])
        banner.text:SetText(L[b.text])
        banner.action:SetShown(b.action ~= nil)
        if b.action then
            banner.action:SetText(L[b.action])
            banner.action:SetScript("OnClick", b.onClick)
        end
    end

    -- Bottom line: errors (red, a few seconds), or "Group posted" right after posting (green).
    m.message = NewLabel(m, nil, "GameFontHighlightSmall")
    m.message:SetPoint("LEFT", m.guildPost, "RIGHT", 16, 0)
    m.message:SetPoint("RIGHT", m, "RIGHT", -8, 0)
    m.message:SetJustifyH("LEFT")
    local function ShowError(text)
        m.errorText, m.errorAt = text, GetTime()
        C_Timer.After(6.1, function() if m:IsShown() then UI:Refresh() end end)
        UI:Refresh()
    end

    -- Looking for: the role mix, changed right away with the arrows.
    m.mixRow = NewMixRow(m, function(values)
        local mine = ns.Groups:GetMine()
        if not mine then return end
        values = values or CopyTable(ns.Groups.DEFAULT_COMPOSITION[ns.Groups:GetSize(mine)])
        local ok, err = ns.Groups:SetComposition(values)
        if not ok and err then ShowError(err) end
    end)

    -- Note, a few lines, editable. Saving shows: a Save button (under the "Note" label) while
    -- there are unsaved changes, then "Note saved" for a moment. Leaving the field still saves;
    -- Escape puts the saved note back.
    local noteLabel = NewLabel(m, L["Note"])
    local noteArea = NewTextArea(m, 460, 52, ns.Groups.NOTE_MAX)
    m.note = noteArea.edit

    local saveNote = NewButton(m, L["Save"], 110, 22)
    saveNote:SetPoint("TOPLEFT", noteLabel, "BOTTOMLEFT", -2, -8)
    saveNote:Hide()
    local savedText = NewLabel(m, "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t |cff40ff40" .. L["Note saved"] .. "|r", "GameFontHighlightSmall")
    savedText:SetPoint("LEFT", saveNote, "LEFT", 2, 0)
    savedText:Hide()
    local savedAt = 0

    local function SavedNote()
        local mine = ns.Groups:GetMine()
        return mine and mine.note or ""
    end
    local function Typed() return strtrim(m.note:GetText() or "") end
    local function UpdateSave()
        local dirty = Typed() ~= SavedNote()
        saveNote:SetShown(dirty)
        if dirty then savedText:Hide() end
    end
    local function SaveNote()
        if Typed() == SavedNote() then return end
        ns.Groups:SetNote(Typed())
        saveNote:Hide()
        savedText:Show()
        savedAt = GetTime()
        local stamp = savedAt
        C_Timer.After(3, function() if savedAt == stamp then savedText:Hide() end end)
    end

    m.note:SetScript("OnEditFocusLost", SaveNote)
    m.note:SetScript("OnEscapePressed", function(self)
        self:SetText(SavedNote())
        self:ClearFocus()
    end)
    saveNote:SetScript("OnClick", function()
        SaveNote()
        m.note:ClearFocus()
    end)
    -- (after SetScript: SetScript would drop the hooks)
    m.note:HookScript("OnTextChanged", UpdateSave)
    SetPlaceholder(m.note, L["Example: chain runs, quests welcome"])

    -- Options, changed right away
    local function SaveOptions()
        ns.Groups:SetOptions(m.newbies:GetChecked(), m.discord:GetChecked(), m.discordChannel:GetText())
    end
    m.newbies = NewCheckbox(m, ns.NewbieIcon(16) .. " " .. L["New players welcome"], SaveOptions)
    m.discord = NewCheckbox(m, ns.DiscordIcon(16) .. " " .. L["Discord required"], SaveOptions)
    PlaceAfterLabel(m.discord, m.newbies, 28)
    m.discordChannel = NewInput(m, 180, 40)
    PlaceAfterLabel(m.discordChannel, m.discord, 14)
    m.discordChannel:SetScript("OnEditFocusLost", SaveOptions)
    m.discordChannel:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    SetPlaceholder(m.discordChannel, L["Channel name"])

    -- Members (with invited and accepted players): mirror of the real party, role editable by
    -- the leader. Inviting someone sits on the header row, like in the create form.
    m.membersHeader = NewLabel(m, nil, "GameFontNormal")
    m.nameInput = NewNameInput(m, 240, function(picked)
        local member = ns.Groups:FindPlayer(picked.name)
        if not member then
            ShowError(format(ns.Alliance:IsActive() and L["%s is not in the guild or the Guild Alliance."]
                or L["%s is not in the guild."], picked.name))
        elseif not ns.Groups:InviteMember(member.name, member.class, member.level) then
            ShowError(format(L["Can't invite %s: already listed, or the group is full."], member.name))
        end
    end)
    m.nameInput:SetPoint("RIGHT", m, "RIGHT", -24, 0)
    m.nameInput:SetPoint("BOTTOM", m.membersHeader, "BOTTOM", 0, -4)
    SetPlaceholder(m.nameInput, L["Invite a guild member..."])

    m.members = NewScrollList(m, MEMBER_ROW, MemberRowInitializer(
        function() return true end,
        function(member, role) ns.Groups:SetMemberRole(member.key, role) end,
        function() return true end))

    -- Requests: players asking to join, waiting for my answer.
    m.requestsHeader = NewLabel(m, L["Requests"], "GameFontNormal")
    m.empty = NewLabel(m, L["No requests yet. Guild members can see your group now."], "GameFontDisable")
    m.box = NewScrollList(m, 40, InitPendingRow)

    -- Everything under the title moves down when there's a state notice to show, and the
    -- requests follow the member list, which is as tall as the group.
    function m:Place(withHint, rows)
        if self.placed == withHint and self.placedRows == rows then return end
        self.placed, self.placedRows = withHint, rows
        local y = withHint and -100 or -38
        self.mixRow:ClearAllPoints()
        self.mixRow:SetPoint("TOPLEFT", 0, y)
        self.mixRow:SetPoint("RIGHT", self, "RIGHT", -8, 0)
        y = y - 40
        noteLabel:ClearAllPoints()
        noteLabel:SetPoint("TOPLEFT", 8, y - 6)
        noteArea:ClearAllPoints()
        noteArea:SetPoint("TOPLEFT", COL, y)
        noteArea:SetPoint("RIGHT", self, "RIGHT", -24, 0)
        self.newbies:ClearAllPoints()
        self.newbies:SetPoint("TOPLEFT", COL - 4, y - 56)
        self.membersHeader:ClearAllPoints()
        self.membersHeader:SetPoint("TOPLEFT", 8, y - 96)
        local listTop = y - 116
        self.members:ClearAllPoints()
        self.members:SetPoint("TOPLEFT", 0, listTop)
        self.members:SetPoint("RIGHT", self, "RIGHT", -20, 0)
        self.members:SetHeight(MEMBER_ROW * rows)
        local after = listTop - MEMBER_ROW * rows
        self.requestsHeader:ClearAllPoints()
        self.requestsHeader:SetPoint("TOPLEFT", 8, after - 14)
        self.box:ClearAllPoints()
        self.box:SetPoint("TOPLEFT", 0, after - 34)
        self.box:SetPoint("BOTTOMRIGHT", -20, 30) -- clear of "Announce in chat" below
    end
    m.empty:SetPoint("TOP", m.box, "TOP", 0, -16)

    function m:Refresh(mine)
        self.title:SetText(DungeonTitle(mine))
        self.titleHit.dungeon = mine.dungeon
        self.titleHit.listing = mine
        self.titleHit:Fit()
        if not self.note:HasFocus() then self.note:SetText(mine.note or "") end
        self.newbies:SetChecked(mine.newbies == true)
        self.discord:SetChecked(mine.discord == true)
        self.discordChannel:SetShown(mine.discord == true)
        if not self.discordChannel:HasFocus() then self.discordChannel:SetText(mine.discordChannel or "") end

        local state = ns.Groups:GetState(mine)
        local kind
        if mine.started and not mine.reopened and not ns.Groups:IsComplete(mine) then
            kind = "left"
        elseif state == "midrun" then
            kind = "looking"
        elseif state == "running" then
            kind = "complete"
        end
        self:SetBanner(kind)
        local size = ns.Groups:GetSize(mine)
        self.mixRow:SetMix(ns.Groups:GetComposition(mine), size, ns.Groups:MissingRoles(mine))

        local entries = MemberEntries(mine)
        self:Place(kind ~= nil, MemberRows(entries))
        self.membersHeader:SetText(format(L["Members (%d/%d)"], #entries, size))
        SetListData(self.members, entries)

        local full = ns.Groups:CountTaken(mine) >= size
        self.nameInput:SetShown(not full)
        self.guildPost:SetEnabled(ns.Groups:CanPostInGuild())

        -- Bottom line: not leading (stays), a recent error, or "posted" right after posting.
        if not ns.Groups:IsLeading() then
            self.message:SetText("|cffff4040" .. L["You're not the party leader: La Taverne can't invite. Get the lead back, or remove your group."] .. "|r")
        elseif self.errorText and GetTime() - self.errorAt < 6 then
            self.message:SetText("|cffff4040" .. self.errorText .. "|r")
        elseif UI.justPosted and GetTime() - UI.justPosted < 8 then
            self.message:SetText("|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t |cff40ff40" .. L["Group posted: the guild sees it in Groups."] .. "|r")
            if not self.postedTimer then
                self.postedTimer = true
                C_Timer.After(8.1, function() self.postedTimer = nil UI:Refresh() end)
            end
        else
            self.message:SetText("")
        end

        local requests = Requests(mine)
        self.requestsHeader:SetText(#requests > 0 and format(L["Requests (%d)"], #requests) or L["Requests"])
        self.empty:SetShown(#requests == 0)
        SetListData(self.box, requests)
    end
    return m
end

-- My group tab: member view (someone else's group I'm in) -------------------------------------

local function BuildMemberView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    v.title = NewLabel(v, nil, "GameFontNormalLarge")
    v.titleHit = NewDungeonHover(v, v.title)
    v.title:SetPoint("TOPLEFT", 8, -8)
    v.title:SetPoint("RIGHT", v, "RIGHT", -8, 0)
    v.title:SetJustifyH("LEFT")
    v.title:SetWordWrap(false)
    v.leader = NewLabel(v)
    v.leader:SetPoint("TOPLEFT", v.title, "BOTTOMLEFT", 0, -6)
    v.note = NewLabel(v, nil, "GameFontDisable")
    v.note:SetPoint("TOPLEFT", v.leader, "BOTTOMLEFT", 0, -6)
    v.note:SetPoint("RIGHT", v, "RIGHT", -8, 0)
    v.note:SetJustifyH("LEFT")
    v.note:SetMaxLines(2)

    -- My role, the only thing a member changes. Follows the note, which takes 0 to 2 lines.
    v.roleDropdown = NewRoleDropdown(v, 160,
        function()
            local me = v.listing and v.listing.members[ns.NameKey(ns.FullName("player"))]
            return me and me.role
        end,
        function(role) if v.listing then ns.Groups:ChangeMyRole(v.listing.id, role) end end,
        MyClass)
    v.roleDropdown:SetPoint("TOP", v.note, "BOTTOM", 0, -12)
    v.roleDropdown:SetPoint("LEFT", v, "LEFT", COL, 0)
    NewLabel(v, L["My role"]):SetPoint("LEFT", v.roleDropdown, "LEFT", -(COL - 8), 0)
    NewLabel(v, L["You can change your role. The leader manages the rest of the group."], "GameFontDisableSmall")
        :SetPoint("LEFT", v.roleDropdown, "RIGHT", 12, 0)

    -- Members, with invited and accepted players. Requests are the leader's business: just
    -- how many, as a line.
    v.membersHeader = NewLabel(v, nil, "GameFontNormal")
    v.membersHeader:SetPoint("TOP", v.roleDropdown, "BOTTOM", 0, -16)
    v.membersHeader:SetPoint("LEFT", v, "LEFT", 8, 0)
    v.members = NewScrollList(v, MEMBER_ROW, MemberRowInitializer(function() return false end, function() end))
    v.members:SetPoint("TOP", v.membersHeader, "BOTTOM", 0, -8)
    v.members:SetPoint("LEFT", v, "LEFT", 0, 0)
    v.members:SetPoint("RIGHT", v, "RIGHT", -20, 0)
    v.requests = NewLabel(v, "", "GameFontDisable")
    v.requests:SetPoint("TOPLEFT", v.members, "BOTTOMLEFT", 8, -10)

    function v:Refresh(l)
        self.listing = l
        self.title:SetText(DungeonTitle(l) .. "  " .. FlagIcons(l))
        self.titleHit.dungeon = l.dungeon
        self.titleHit.listing = l
        self.titleHit:Fit()
        self.leader:SetText(NameText(l.leader, LeaderClass(l), l.tag) .. " " .. CROWN)

        self.note:SetText(l.note or "")
        RefreshDropdown(self.roleDropdown)
        local entries = MemberEntries(l)
        self.membersHeader:SetText(format(L["Members (%d/%d)"], #entries, ns.Groups:GetSize(l)) .. "   " .. MissingLine(l))
        self.members:SetHeight(MEMBER_ROW * math.max(1, math.min(#entries, 10)))
        SetListData(self.members, entries)
        local requests = #Requests(l)
        self.requests:SetText(requests > 0 and format(L["%d requests waiting for the leader"], requests) or "")
    end
    return v
end

local function BuildMyGroupPanel()
    local p = NewPanel()
    p.form = BuildCreateForm(p)
    p.manage = BuildManageView(p)
    p.member = BuildMemberView(p)

    -- In the header, top right: the other groups, and the invitations waiting there (leader:
    -- left of Remove group; member: in the corner). Browse has "My group" in that corner.
    p.others = NewButton(p, "", 180)
    p.others:SetScript("OnClick", function() UI:ShowPage("browse") end)
    p.others:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["See the other groups"],
            L["Open groups and invitations. Your group stays as it is."] })
    end)
    p.others:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.manage.title:SetPoint("RIGHT", p.others, "LEFT", -10, 0)
    p.member.title:SetPoint("RIGHT", p.others, "LEFT", -10, 0)

    function p:Refresh()
        local mine = ns.Groups:GetMine()
        -- (only look for a joined group when I don't lead one: "false" here would count as shown)
        local joined = (not mine) and ns.Groups:GetJoined() or nil
        self.manage:SetShown(mine ~= nil)
        self.member:SetShown(joined ~= nil)
        self.form:SetShown(mine == nil and joined == nil)
        self.others:SetShown(mine ~= nil or joined ~= nil)
        self.others:ClearAllPoints()
        if mine then
            self.others:SetPoint("RIGHT", self.manage.delist, "LEFT", -6, 0)
        else
            self.others:SetPoint("TOPRIGHT", -2, -4)
        end
        local invites = #ns.Groups:GetInvitations()
        self.others:SetText(invites > 0
            and ("|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t " .. format(L["Invitations waiting (%d): see the groups"], invites))
            or L["See the other groups"])
        self.others:SetWidth(math.max(170, self.others:GetFontString():GetStringWidth() + 30))
        if mine then
            self.manage:Refresh(mine)
        elseif joined then
            self.member:Refresh(joined)
        else
            self.form:Refresh()
        end
    end
    return p
end

-- Players tab -----------------------------------------------------------------------------------
-- Who can I ask: my availability, the dungeons available players want, and the online guild
-- members: available players first, the others folded away, with Invite and Whisper.

local function Whisper(name)
    local tell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
    if tell then tell(name) end
end

-- Can I invite this player through La Taverne right now? Returns ok, reason.
local function CanInvite(entry)
    local mine = ns.Groups:GetMine()
    if not mine then return false, L["Post a group first: the invitation is for your group."] end
    if mine.members[entry.key] or (mine.pending[entry.key] and mine.pending[entry.key].status ~= "request") then
        return false, L["Already in your group or invited."]
    end
    if ns.Groups:CountTaken(mine) >= ns.Groups:GetSize(mine) then return false, L["Your group is full."] end
    return true
end

local function RoleIcons(roles)
    local out = ""
    for _, role in ipairs(ns.Groups.ROLES) do
        if roles and roles[role] then out = out .. ns.RoleIcon(role) .. " " end
    end
    return out
end

-- Rows: a player, the "Other members online (n)" line that folds the rest, or a message.
-- Section header rows get room above them (spacing before a section, none after it).
local PLAYER_ROW, TOGGLE_ROW, MESSAGE_ROW = 38, 40, 24

local function InitPlayerRow(row, e)
    if not row.built then
        row.player = CreateFrame("Frame", nil, row)
        row.player:SetAllPoints()
        RowBackground(row.player)
        row.name = NewLabel(row.player)
        row.name:SetPoint("TOPLEFT", 8, -4)
        row.detail = NewLabel(row.player, nil, "GameFontHighlightSmall")
        row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.detail:SetPoint("RIGHT", row.player, "RIGHT", -150, 0)
        row.detail:SetJustifyH("LEFT")
        row.detail:SetWordWrap(false)
        -- Their La Taverne version, in the tooltip of the name.
        row.nameHit = CreateFrame("Frame", nil, row.player)
        row.nameHit:SetAllPoints(row.name)
        row.nameHit:EnableMouse(true)
        row.nameHit:SetScript("OnEnter", function(self) if self.tooltip then ShowTooltip(self, self.tooltip) end end)
        row.nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- The second line is cut short: its tooltip has every dungeon and the whole note.
        row.detailHit = CreateFrame("Frame", nil, row.player)
        row.detailHit:SetPoint("TOPLEFT", row.detail, "TOPLEFT")
        row.detailHit:SetPoint("BOTTOMLEFT", row.detail, "BOTTOMLEFT")
        row.detailHit:EnableMouse(true)
        row.detailHit:SetScript("OnEnter", function(self) if self.tooltip then ShowTooltip(self, self.tooltip) end end)
        row.detailHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.whisper = NewIconButton(row.player, "whisper", L["Whisper"], 22)
        row.whisper:SetPoint("RIGHT", -12, 0)
        row.invite = NewButton(row.player, L["Invite"], 90, 22)
        row.invite:SetPoint("RIGHT", row.whisper, "LEFT", -10, 0)
        row.invite:SetMotionScriptsWhileDisabled(true)
        row.invite:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.toggle = CreateFrame("Button", nil, row)
        row.toggle:SetAllPoints()
        -- A section header that folds the list under it ("Available players", "Other members
        -- online"): its text at the bottom of the row, the room above it.
        row.toggle.text = NewLabel(row.toggle, "", SECTION_FONT)
        row.toggle.text:SetPoint("BOTTOMLEFT", 8, 8)
        row.toggle.line = row.toggle:CreateTexture(nil, "ARTWORK")
        row.toggle.line:SetColorTexture(1, 0.82, 0, 0.25)
        row.toggle.line:SetHeight(1)
        row.toggle.line:SetPoint("TOPLEFT", row.toggle.text, "BOTTOMLEFT", 0, -4)
        row.toggle.line:SetPoint("RIGHT", row.toggle, "RIGHT", 0, 0)
        row.toggle:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        -- "Only those who fit my group", on the Available players header (with my group open).
        row.toggle.fit = NewCheckbox(row.toggle, L["Only those who fit my group"], function(self)
            if row.onFit then row.onFit(self:GetChecked() and true or false) end
        end)
        row.toggle.fit:SetPoint("LEFT", row.toggle.text, "RIGHT", 16, 0)

        row.message = NewLabel(row, "", "GameFontDisable")
        row.message:SetPoint("TOPLEFT", 12, -4)
        row.built = true
    end
    row.player:SetShown(e.kind == "player")
    row.toggle:SetShown(e.kind == "toggle")
    row.message:SetShown(e.kind == "message")
    if e.kind == "toggle" then
        -- The game's own +/- icons (the font has no arrow characters).
        row.toggle.text:SetText((e.open and "|TInterface\\Buttons\\UI-MinusButton-Up:16:16|t "
            or "|TInterface\\Buttons\\UI-PlusButton-Up:16:16|t ")
            .. format(e.label, e.count))
        row.toggle:SetScript("OnClick", e.onClick)
        row.onFit = e.onFit
        row.toggle.fit:SetShown(e.onFit ~= nil)
        row.toggle.fit:SetChecked(e.fitChecked == true)
        return
    elseif e.kind == "message" then
        row.message:SetText(e.text)
        return
    end

    local a = e.avail
    local tag = e.tag or (a and a.tag)
    local level = e.level and (" |cff808080" .. format(L["Level %d"], e.level) .. "|r") or ""
    local afk = a and a.afk and (" |cffff9900" .. L["(AFK)"] .. "|r") or ""
    -- Their La Taverne version: shown only when it's older than mine; always in the tooltip.
    local ver = ns.Comm:GetVersion(e.name)
    local verText = ""
    if ver and ns.version ~= "?" and ns.CompareVersions(ver, ns.version) < 0 then
        verText = "  |cffff9900" .. L["(old version)"] .. "|r"
    end
    row.name:SetText(NameText(e.name, e.class, tag) .. level .. afk .. verText)
    row.nameHit.tooltip = { NameText(e.name, e.class, tag),
        ver and ("La Taverne v" .. ver) or ("|cff808080" .. L["Doesn't have the La Taverne addon"] .. "|r") }
    if e.tier == "available" then

        row.detail:SetText(AvailDetail(a.roles, a.dungeons, a.note, L["any dungeon at their level"]))
        row.detailHit.tooltip = AvailTooltip(NameText(e.name, e.class, tag), a.roles, a.dungeons, a.note, L["any dungeon at their level"])
    elseif e.tier == "addon" then
        row.detailHit.tooltip = nil
        row.detail:SetText("|cffb0b0b0" .. L["At the tavern, but not looking for a group right now"] .. "|r")
    else
        row.detailHit.tooltip = nil
        row.detail:SetText("|cff808080" .. L["Not at the tavern: whisper them"] .. "|r")
    end
    row.player:SetAlpha((a and a.afk) and 0.5 or 1)
    -- The hover area covers the text, not the empty end of the line.
    local textWidth, lineWidth = row.detail:GetStringWidth() or 0, row.detail:GetWidth() or 0
    row.detailHit:SetWidth(math.max(20, (lineWidth > 0 and math.min(textWidth, lineWidth)) or textWidth))
    row.invite:SetShown(e.tier ~= "none")
    local ok, reason = CanInvite(e)
    row.invite:SetEnabled(ok)
    row.invite:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["Invite"], ok and L["Sends a La Taverne invitation to your group."] or reason })
    end)
    row.invite:SetScript("OnClick", function()
        ns.Groups:InviteMember(e.name, e.class, e.level)
    end)
    row.whisper:SetScript("OnClick", function() Whisper(e.name) end)
end

local function PlayerRowHeight(e)
    if e.kind == "toggle" then return TOGGLE_ROW end
    if e.kind == "message" then return MESSAGE_ROW end
    return PLAYER_ROW
end

local function InitDemandRow(row, d)
    if not row.built then
        RowBackground(row)
        row.name = NewLabel(row)
        row.name:SetPoint("LEFT", 8, 0)
        row.roles = NewLabel(row, nil, "GameFontHighlightSmall")
        row.roles:SetPoint("LEFT", 300, 0)
        row.create = NewButton(row, L["Create this group"], 150, 20)
        row.create:SetPoint("RIGHT", -4, 0)
        row.built = true
    end
    row.name:SetText(ns.DungeonName(d.dungeon))
    row.nameHit = row.nameHit or NewDungeonHover(row, row.name)
    row.nameHit.dungeon = d.dungeon
    row.nameHit:Fit()
    local parts = {}
    for _, role in ipairs(ns.Groups.ROLES) do
        if (d[role] or 0) > 0 then parts[#parts + 1] = ns.RoleIcon(role) .. " " .. d[role] end
    end
    row.roles:SetText(table.concat(parts, "   ") .. "   |cff808080" .. format(L["(%d players)"], d.total) .. "|r")
    local free = not ns.Groups:GetMine() and not ns.Groups:GetJoined()
    row.create:SetShown(free and true or false)
    row.create:SetScript("OnClick", function()
        UI.presetDungeon = d.dungeon
        UI:ShowPage("mygroup")
    end)
end

-- The Availability page: the list below (my status, wanted dungeons, players), or the
-- "I'm available" form in its place.
local function BuildPlayersPanel()
    local panel = NewPanel()
    local p = CreateFrame("Frame", nil, panel)
    p:SetAllPoints()
    NewPageTitle(p, L["Availability"])

    -- My availability: one status line, and its buttons on the right of the title.
    -- Not available: "I'm available...". Available: "Change..." (the same menu) and "Stop".
    p.avail = NewButton(p, L["I'm available..."], 170)
    p.avail:SetPoint("TOPRIGHT", -2, -4)
    p.avail:SetMotionScriptsWhileDisabled(true) -- the tooltip says why it's greyed out
    p.avail:SetScript("OnClick", function() OpenAvailability() end)
    p.avail:SetScript("OnEnter", function(self) AvailabilityTooltip(self) end)
    p.avail:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Available: "My availability" in green at the top right (the form, like My group on the
    -- Groups tab); stopping is done from there ("Remove my availability").
    p.change = NewButton(p, "|cff20ff20" .. L["My availability"] .. "|r", 160)
    p.change:SetPoint("TOPRIGHT", -2, -4)
    p.change:SetScript("OnClick", function() OpenAvailability() end)

    -- While available: a "My availability" section (status line, note). In a group: the status
    -- line alone. Otherwise nothing: the page starts with the lists.
    p.mineHeader = NewSectionHeader(p, L["My availability"])
    p.mineHeader:SetPoint("TOPLEFT", 8, -40)
    p.status = NewLabel(p, "", "GameFontHighlight")
    p.status:SetPoint("RIGHT", p, "RIGHT", -8, 0)
    p.status:SetJustifyH("LEFT")
    p.status:SetWordWrap(false)

    -- Note: only while available (that's when others see it).
    p.noteLabel = NewLabel(p, L["Note"])
    p.noteLabel:SetPoint("TOPLEFT", 8, -98)
    p.note = NewInput(p, 360, 80)
    p.note:SetPoint("TOPLEFT", 80, -94)
    SetPlaceholder(p.note, L["Note (optional), e.g. quests in BFD"])
    p.note:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    p.note:HookScript("OnEditFocusLost", function() ns.Players:SetNote(p.note:GetText()) end)

    -- Wanted dungeons: what available players asked for. Hidden when nobody asked.
    p.demandHeader = NewSectionHeader(p, L["Wanted dungeons"])
    p.anyLine = NewLabel(p, "", "GameFontDisableSmall")
    p.anyLine:SetPoint("LEFT", p.demandHeader, "RIGHT", 12, 0)
    p.demand = NewScrollList(p, 24, InitDemandRow)

    -- Players: two folding sections in one list, available players (open) then the others
    -- (folded).
    p.list = NewScrollList(p, PlayerRowHeight, InitPlayerRow)
    p.showAvailable = true
    p.showOthers = false

    function p:Layout(available, demandRows, showDemand)
        -- Available: my section (header, status line, note). Otherwise the status line only
        -- when it says something (in a group); not available, it's empty and takes no room.
        ShowSection(self.mineHeader, available)
        self.status:ClearAllPoints()
        self.status:SetPoint("TOPLEFT", 8, available and -68 or -40)
        self.status:SetPoint("RIGHT", self, "RIGHT", -8, 0)
        local y = available and -132 or ((self.status:GetText() or "") ~= "" and -72 or -40)
        ShowSection(self.demandHeader, showDemand)
        self.anyLine:SetShown(showDemand)
        self.demand:SetShown(showDemand and demandRows > 0)
        if showDemand then
            self.demandHeader:ClearAllPoints()
            self.demandHeader:SetPoint("TOPLEFT", 8, y)
            y = y - 26
            if demandRows > 0 then
                self.demand:ClearAllPoints()
                self.demand:SetPoint("TOPLEFT", 0, y)
                self.demand:SetPoint("RIGHT", self, "RIGHT", -20, 0)
                self.demand:SetHeight(24 * demandRows)
                y = y - 24 * demandRows
            end
            y = y - 18
        end
        -- The list starts with the Available players header row, its text where y is.
        self.list:ClearAllPoints()
        self.list:SetPoint("TOPLEFT", 0, y + (TOGGLE_ROW - 28)) -- (clear of the buttons at the top)
        self.list:SetPoint("BOTTOMRIGHT", -20, 0)
    end

    function p:Refresh()
        local P = ns.Players
        P:AskWho() -- who runs La Taverne (at most every 30 s)
        local active = P:IsActive()
        self.avail:SetShown(not active)
        self.avail:SetEnabled(not ns.InParty() and not ns.Groups:GetMine())
        self.change:SetShown(active)
        local s = P.Settings()
        local forText = DungeonsShort(s.dungeons, L["any dungeon at my level"])
        if active then
            local left = P:Remaining()
            local timeText = left and format(L["Available for %d more min"], math.max(1, math.ceil(left / 60)))
                or L["Available until you log out"]
            self.status:SetText("|cff20ff20" .. timeText .. "|r  \194\183  " .. RoleIcons(ns.Groups:GetMyRoles())
                .. " \194\183  " .. forText
                .. (P:IsPaused() and ("  |cffffd100" .. L["(paused: in a dungeon)"] .. "|r") or ""))
        elseif ns.Groups:GetMine() or ns.Groups:GetJoined() then
            -- In a group of the finder it's normal (gold). Just in a party: the greyed-out
            -- button's tooltip says why.
            self.status:SetText("|cffffd100" .. InPartyText(true) .. "|r")
        else
            self.status:SetText("") -- not available: nothing to say
        end
        self.noteLabel:SetShown(active)
        self.note:SetShown(active)
        if not self.note:HasFocus() then self.note:SetText(s.note or "") end

        local demand, anyCount = P:GetDemand()
        SetListData(self.demand, demand)
        self.anyLine:SetText(anyCount > 0 and format(L["%d available for any dungeon at their level"], anyCount) or "")
        self:Layout(active, math.min(#demand, 3), #demand > 0 or anyCount > 0)

        -- Available players first (only those who fit my open group, when ticked), the rest
        -- behind "Other members online (n)".
        local mine = ns.Groups:GetMine()
        local canFit = mine ~= nil and ns.Groups:IsOpen(mine)
        local fitOnly = canFit and ns.db.playersFitOnly ~= false
        local shown, others = {}, {}
        for _, e in ipairs(P:GetOnline()) do
            e.kind = "player"
            if e.tier == "available" and (not fitOnly or P:FitsGroup(e.avail, mine)) then
                shown[#shown + 1] = e
            else
                others[#others + 1] = e
            end
        end
        local list = { { kind = "toggle", label = L["Available players (%d)"], count = #shown,
            open = self.showAvailable,
            onClick = function() self.showAvailable = not self.showAvailable self:Refresh() end,
            onFit = canFit and function(on) ns.db.playersFitOnly = on self:Refresh() end or nil,
            fitChecked = ns.db.playersFitOnly ~= false } }
        if self.showAvailable then
            for _, e in ipairs(shown) do list[#list + 1] = e end
            if #shown == 0 then
                list[#list + 1] = { kind = "message", text = fitOnly and L["Nobody available fits your group right now."]
                    or L["Nobody is available right now."] }
            end
        end
        if #others > 0 then
            list[#list + 1] = { kind = "toggle", label = L["Other members online (%d)"], count = #others,
                open = self.showOthers,
                onClick = function() self.showOthers = not self.showOthers self:Refresh() end }
            if self.showOthers then
                for _, e in ipairs(others) do list[#list + 1] = e end
            end
        end
        SetListData(self.list, list)
    end
    -- The list, or the form in its place. Coming back to the page shows the list.
    panel.view = p
    panel.form = BuildAvailabilityForm(panel, function() panel:ShowForm(false) end)
    function panel:ShowForm(on)
        self.form:SetShown(on)
        self.view:SetShown(not on)
        self:Refresh()
    end
    function panel:Refresh()
        if self.form:IsShown() then self.form:Refresh() else self.view:Refresh() end
    end
    panel:HookScript("OnHide", function(self) self.form:Hide() self.view:Show() end)
    return panel
end

-- Officers tab --------------------------------------------------------------------------------
-- Shown only to players who can edit the Guild Info (everyone in sandbox). Sets up the allied
-- guilds without typing anything in the Guild Info by hand.

local function BuildOfficerPanel()
    local p = NewPanel()
    local TAG_X = 350 -- x of the "Tag" column in the guild rows
    local draft
    local dirty = false
    local imported = false -- the list shows an imported setup, not saved yet

    local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t "
    -- Steps 1, 2, 3: the number stays, a green check comes in front once the step is done.
    local function StepTitle(number, text, done)
        if done then return CHECK .. "|cff40ff40" .. number .. ".|r " .. text end
        return "|cffffd100" .. number .. ".|r " .. text
    end

    NewPageTitle(p, L["Guild Alliance setup"], { L["Guild Alliance setup"],
        L["Only players who can edit the Guild Info see this page."],
        L["Set up the guilds once, then send the setup to an officer of each allied guild (Export, then Import on their side)."] })
    local back = NewButton(p, L["Back"], 100, 24)
    back:SetPoint("TOPRIGHT", -2, -4)
    back:SetScript("OnClick", function() UI:ShowPage("network") end)



    -- Import / Export sit on step 1's line: they fill the guild list, and send it to the others.
    local exportButton = NewButton(p, L["Export"], 100)
    exportButton:SetPoint("TOPRIGHT", -26, -64)
    -- Import: a window to paste a setup in (or fill it from GuildUnion).
    local importButton = NewButton(p, L["Import..."], 110)
    importButton:SetPoint("RIGHT", exportButton, "LEFT", -6, 0)

    local message = NewLabel(p, "", "GameFontHighlightSmall")
    local function Say(text, isError)
        message:SetText(text and ((isError and "|cffff4040" or "|cff40ff40") .. text .. "|r") or "")
    end

    local function Changed()
        dirty = true
        p:RefreshDraft()
    end

    -- Step 1: the guilds ---------------------------------------------------------------------
    local step1 = NewLabel(p, "", "GameFontNormal")
    step1:SetPoint("TOPLEFT", 8, -70)
    local status = NewLabel(p, "", "GameFontHighlightSmall")
    status:SetPoint("LEFT", step1, "RIGHT", 16, 0)
    status:SetPoint("RIGHT", importButton, "LEFT", -12, 0)
    status:SetWordWrap(false)
    status:SetJustifyH("LEFT")

    local list = NewScrollList(p, 26, function(row, data)
        if not row.init then
            row.init = true
            RowBackground(row)
            row.name = NewLabel(row, "")
            row.name:SetPoint("LEFT", 6, 0)
            row.name:SetWidth(330)
            row.name:SetJustifyH("LEFT")
            NewLabel(row, L["Tag"], "GameFontNormalSmall"):SetPoint("LEFT", TAG_X, 0)
            row.tag = NewInput(row, 70, 6)
            row.tag:SetPoint("LEFT", TAG_X + 35, 0)
            row.tag:SetScript("OnTextChanged", function(self, user)
                if user and row.data then
                    row.data.tag = strtrim(self:GetText())
                    Changed()
                end
            end)
            row.remove = NewIconButton(row, "remove", L["Remove"])
            row.remove:SetPoint("RIGHT", -10, 0)
            row.remove:SetScript("OnClick", function()
                for i, entry in ipairs(draft.guilds) do
                    if entry == row.data then table.remove(draft.guilds, i) break end
                end
                Changed()
                p:Refresh()
            end)
        end
        row.data = data
        row.name:SetText(data.name .. (data.mine and (" |cff808080(" .. L["your guild"] .. ")|r") or ""))
        if not row.tag:HasFocus() then row.tag:SetText(data.tag or "") end
        row.remove:SetShown(not data.mine)
    end)
    list:SetPoint("TOPLEFT", 20, -90)
    list:SetPoint("RIGHT", -20, 0)
    list:SetHeight(26 * 3)

    -- Add a guild: an empty row under the list, same columns (name, tag, button).
    local addName = NewInput(p, 300, 60)
    addName:SetPoint("TOPLEFT", 32, -176)
    SetPlaceholder(addName, L["Add a guild..."])
    NewLabel(p, L["Tag"], "GameFontNormalSmall"):SetPoint("LEFT", addName, "LEFT", 20 + TAG_X - 32, 0)
    local addTag = NewInput(p, 70, 6)
    addTag:SetPoint("LEFT", addName, "LEFT", 20 + TAG_X + 35 - 32, 0)
    local addButton = NewButton(p, L["Add"], 90)
    addButton:SetPoint("TOPRIGHT", -26, -176)
    local addHint = NewInfoIcon(p, { L["Add a guild..."],
        L["Exact guild name, as the game writes it. Tag: up to 6 letters, shown in chat."] })
    addHint:SetPoint("RIGHT", addButton, "LEFT", -8, 0)
    addButton:SetScript("OnClick", function()
        local name, tag = strtrim(addName:GetText()), strtrim(addTag:GetText())
        if not ns.Alliance.ValidName(name) then Say(L["Type the guild's name."], true) return end
        if not ns.Alliance.ValidTag(tag) then Say(L["The tag must be 1 to 6 letters, no spaces."], true) return end
        for _, entry in ipairs(draft.guilds) do
            if entry.name:lower() == name:lower() then Say(L["This guild is already in the list."], true) return end
        end
        draft.guilds[#draft.guilds + 1] = { name = name, tag = tag }
        addName:SetText("")
        addTag:SetText("")
        Say(nil)
        Changed()
        p:Refresh()
    end)
    addName:SetScript("OnEnterPressed", function() addTag:SetFocus() end)
    addTag:SetScript("OnEnterPressed", function(self) self:ClearFocus() addButton:Click() end)
    -- GuildUnion's allied guilds as setup lines: the guilds already in the list, plus the ones
    -- GuildUnion knows (with its tags), and the current key. They go in the Import window's text
    -- box, to check and import like a pasted setup.
    local function GuildUnionText()
        local guilds = {}
        for _, entry in ipairs(draft.guilds) do guilds[#guilds + 1] = { name = entry.name, tag = entry.tag, mine = entry.mine } end
        for _, gu in ipairs(ns.Alliance.ReadGuildUnion()) do
            local found = false
            for _, entry in ipairs(guilds) do
                if entry.name:lower() == gu.name:lower() then
                    found = true
                    if not entry.tag or entry.tag == "" then entry.tag = gu.tag end
                end
            end
            if not found then guilds[#guilds + 1] = { name = gu.name, tag = gu.tag } end
        end
        return table.concat(ns.Alliance.BuildLines(guilds, draft.key), "\n")
    end

    -- Step 2: the shared key -----------------------------------------------------------------
    local step2 = NewLabel(p, "", "GameFontNormal")
    step2:SetPoint("TOPLEFT", 8, -226)
    local keyText = NewLabel(p, "", "GameFontHighlight")
    keyText:SetPoint("TOPLEFT", 26, -250)
    local keyButton = NewButton(p, "", 170)
    keyButton:SetPoint("LEFT", keyText, "RIGHT", 24, 0)
    keyButton:SetScript("OnClick", function()
        draft.key = ns.Alliance.NewKey()
        Say(nil)
        Changed()
    end)
    local keyHint = NewInfoIcon(p, {})
    keyHint:SetPoint("LEFT", step2, "RIGHT", 6, 0)

    -- Step 3: save, with a preview of La Taverne's lines -------------------------------------
    local step3 = NewLabel(p, "", "GameFontNormal")
    step3:SetPoint("TOPLEFT", 8, -292)
    local previewLabel = NewLabel(p, "", "GameFontDisableSmall")
    previewLabel:SetPoint("TOPLEFT", 26, -312)
    previewLabel:SetPoint("RIGHT", -8, 0)
    previewLabel:SetJustifyH("LEFT")
    local preview = CreateFrame("Frame", nil, p, "BackdropTemplate")
    preview:SetPoint("TOPLEFT", 24, -328)
    preview:SetPoint("RIGHT", -8, 0)
    preview:SetHeight(76)
    if preview.SetBackdrop then
        preview:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        preview:SetBackdropColor(0, 0, 0, 0.35)
        preview:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    local previewText = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    previewText:SetPoint("TOPLEFT", 8, -7)
    previewText:SetPoint("BOTTOMRIGHT", -8, 6)
    previewText:SetJustifyH("LEFT")
    previewText:SetJustifyV("TOP")

    local saveButton = NewButton(p, L["Save"], 160, 24)
    saveButton:SetPoint("TOPLEFT", 24, -414)
    local cancelButton = NewButton(p, L["Cancel"], 160, 24)
    cancelButton:SetPoint("LEFT", saveButton, "RIGHT", 8, 0)
    local countText = NewLabel(p, "", "GameFontDisableSmall")
    countText:SetPoint("LEFT", cancelButton, "RIGHT", 12, 0)
    -- Under Save: unsaved changes or an imported setup, then the result of the last action
    local banner = NewLabel(p, "", "GameFontHighlightSmall")
    banner:SetPoint("TOPLEFT", 26, -446)
    banner:SetPoint("RIGHT", -8, 0)
    banner:SetJustifyH("LEFT")
    message:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -4)
    message:SetPoint("RIGHT", -8, 0)
    message:SetJustifyH("LEFT")

    local function Problem()
        local others = 0
        for _, entry in ipairs(draft.guilds) do
            if not ns.Alliance.ValidTag(entry.tag) then return L["The tag must be 1 to 6 letters, no spaces."] .. " (" .. entry.name .. ")" end
            if not entry.mine then others = others + 1 end
        end
        if others > 0 and not draft.key then return L["Create the key first (step 2)."] end
        return nil
    end

    saveButton:SetScript("OnClick", function()
        local problem = Problem()
        if problem then Say(problem, true) return end
        local ok, err, paste = ns.Alliance:Save(draft.guilds, draft.key)
        if not ok then
            Say(err, true)
        elseif paste then
            -- Real guild: the game won't let addons write the Guild Info, the officer pastes it.
            -- The page follows on its own once the new lines are in the Guild Info.
            dirty, imported = false, false
            Say(L["Paste the text into the Guild Info: La Taverne reads it on its own a few seconds later."])
            ns.TextDialog({
                title = L["Paste into the Guild Info"],
                hint = L["The game doesn't let addons change the Guild Info. Press Ctrl+C to copy this text: it's your Guild Info with La Taverne's lines (LT:) updated, the rest unchanged. Then in the guild window, open the Guild Info, select all of it (Ctrl+A), paste (Ctrl+V) and accept."],
                text = paste,
                selectAll = true,
            })
        else
            dirty, imported = false, false
            Say(L["Saved to the test guild's Guild Info."])
            C_Timer.After(2.2, function() if p:IsShown() then p:Refresh() end end)
        end
        p:Refresh()
    end)
    cancelButton:SetScript("OnClick", function()
        draft = ns.Alliance:GetDraft()
        dirty, imported = false, false
        Say(nil)
        p:Refresh()
    end)

    -- Export / Import dialogs ----------------------------------------------------------------
    exportButton:SetScript("OnClick", function()
        ns.TextDialog({
            title = L["Export the Guild Alliance setup"],
            hint = L["Press Ctrl+C to copy, then send it to an officer of each allied guild (whisper, Discord...). In their guild they open La Taverne, Alliance tab, Setup page, Import, paste it, then Save. They can also paste these lines at the end of their Guild Info by hand."],
            text = table.concat(ns.Alliance.BuildLines(draft.guilds, draft.key), "\n"),
            selectAll = true,
        })
    end)

    local function ImportPasted()
        ns.TextDialog({
            title = L["Import a Guild Alliance setup"],
            hint = L["Paste the setup an officer of an allied guild exported (Ctrl+V), then click Import. The Setup page then shows it, but nothing changes until you click Save."],
            text = "",
            button = L["Import"],
            -- GuildUnion's guilds, written in the text box like a pasted setup.
            extra = {
                text = L["From GuildUnion"],
                fill = GuildUnionText,
                enabled = #ns.Alliance.ReadGuildUnion() > 0,
                tooltip = { L["From GuildUnion"], #ns.Alliance.ReadGuildUnion() > 0
                    and L["Writes the allied guilds GuildUnion knows (with their tags) in the box, added to the ones already in the list. Check them, then Import."]
                    or L["GuildUnion has no allied guilds to import."] },
            },
            onButton = function(text)
                local parsed = ns.Alliance.Parse(text)
                if parsed.count == 0 and not parsed.key then
                    Say(L["No La Taverne lines (LT:) found in the text."], true)
                    return
                end
                local fresh = { guilds = {}, key = parsed.key or draft.key }
                local mineEntry
                for _, entry in pairs(parsed.guilds) do
                    local item = { name = entry.name, tag = entry.tag, mine = ns.Guild:IsMyGuild(entry.name) }
                    if item.mine then mineEntry = item else fresh.guilds[#fresh.guilds + 1] = item end
                end
                table.sort(fresh.guilds, function(a, b) return a.name < b.name end)
                if not mineEntry then
                    for _, entry in ipairs(draft.guilds) do if entry.mine then mineEntry = entry end end
                end
                if mineEntry then table.insert(fresh.guilds, 1, mineEntry) end
                draft = fresh
                imported = true
                Say(nil)
                Changed()
                p:Refresh()
            end,
        })
    end
    importButton:SetScript("OnClick", function() ImportPasted() end)

    -- Display ------------------------------------------------------------------------------------
    function p:RefreshDraft()
        local others = 0
        for _, entry in ipairs(draft.guilds) do
            if not entry.mine then others = others + 1 end
        end
        local saved = not dirty and ns.Alliance:IsActive() and ns.Alliance:GetKey() == draft.key
        step1:SetText(StepTitle(1, L["Guilds of the Guild Alliance"], others > 0))
        step2:SetText(StepTitle(2, L["Shared key"], draft.key ~= nil))
        step3:SetText(StepTitle(3, L["Save to your Guild Info"], saved))

        if imported then
            banner:SetText("|cffff9900" .. L["Imported setup shown below. It is not applied yet: click Save to apply it, or Cancel."] .. "|r")
        elseif dirty then
            banner:SetText("|cffff9900" .. L["Changes not saved yet: click Save to apply them, or Cancel."] .. "|r")
        else
            banner:SetText("")
        end

        if draft.key then
            keyText:SetText(draft.key)
            keyButton:SetText(L["Change the key"])
            keyHint.lines = { L["Shared key"], L["Every guild of the Guild Alliance uses the same key. La Taverne makes one for you."],
                L["Members who leave the guild lose access on their own: La Taverne only reads the key from their current guild's Guild Info. Someone who wrote the key down could still listen with a modified addon, so change it if that matters (for example someone left on bad terms). Then export the new setup to the other guilds."] }
        else
            keyText:SetText("|cff808080" .. L["No key yet."] .. "|r")
            keyButton:SetText(L["Create the key"])
            keyHint.lines = { L["Shared key"], L["Every guild of the Guild Alliance uses the same key. La Taverne makes one for you."] }
        end

        local lines = ns.Alliance.BuildLines(draft.guilds, draft.key)
        previewText:SetText(#lines > 0 and table.concat(lines, "\n") or ("|cff808080" .. L["nothing"] .. "|r"))
        if dirty then
            previewLabel:SetText(L["Preview of La Taverne's lines in the Guild Info. The rest of the Guild Info stays as it is."])
        else
            previewLabel:SetText(L["La Taverne's lines in the Guild Info now:"])
        end

        if ns.Guild:IsSandbox() then
            countText:SetText("")
        else
            local total = #ns.Alliance.ReplaceLines(GetGuildInfoText and GetGuildInfoText() or "", lines)
            countText:SetText(L["Guild Info: %d / %d letters"]:format(total, ns.Alliance.INFO_MAX))
        end
        saveButton:SetEnabled(dirty)
        cancelButton:SetEnabled(dirty)
        exportButton:SetEnabled(saved)
    end

    function p:Refresh()
        if not draft or not dirty then draft = ns.Alliance:GetDraft() end


        local names = {}
        for _, entry in ipairs(ns.Alliance:GetGuilds()) do
            if not ns.Guild:IsMyGuild(entry.name) then names[#names + 1] = entry.name end
        end
        if ns.Alliance:IsActive() then
            status:SetText("|cff40ff40" .. L["Active"] .. "|r - " .. L["Allied with: %s"]:format(table.concat(names, ", ")))
        else
            status:SetText("|cff808080" .. L["Not set up"] .. "|r")
        end
        SetListData(list, draft.guilds)
        self:RefreshDraft()
    end
    return p
end

-- Alliance tab ------------------------------------------------------------------------------
-- The Guild Alliance itself, nothing that belongs to Groups: one card per guild (mine first),
-- and in each allied guild's card the players heard from, with whether their guild confirmed
-- them. The channel's state and my shared chat setting at the top. Officers change the
-- alliance on the Setup page; the shared chat switch is in Options.

local READY_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
local WAIT_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t"
local NO_ICON = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t"

-- A player's vouching state as an icon and one word, plus the full line for the tooltip.
local VOUCH_SHORT = {
    confirmed = { READY_ICON, "20ff20", "confirmed" },
    unverified = { WAIT_ICON, "ff9900", "not checked: nobody from their guild online" },
    denied = { NO_ICON, "ff4040", "not in this guild" },
}

local CARD_HEADER, CARD_ROW, CARD_GAP = 34, 24, 12

local FOLD_OPEN = "|TInterface\\Buttons\\UI-MinusButton-Up:16:16|t "
local FOLD_CLOSED = "|TInterface\\Buttons\\UI-PlusButton-Up:16:16|t "

-- Rows: a guild's card header (folds the card), a player, the "n offline" line that folds the
-- players not heard from lately, a note, or the gap between two cards.
local function InitAllianceRow(row, item)
    if not row.built then
        row.card = CreateFrame("Frame", nil, row, "BackdropTemplate")
        row.card:SetPoint("TOPLEFT", 0, 0)
        row.card:SetPoint("BOTTOMRIGHT", 0, 2)
        if row.card.SetBackdrop then
            row.card:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            row.card:SetBackdropColor(1, 0.82, 0, 0.08)
            row.card:SetBackdropBorderColor(1, 0.82, 0, 0.7)
        end
        row.title = NewLabel(row, nil, "GameFontNormalLarge")
        row.title:SetPoint("LEFT", 10, 1)
        row.side = NewLabel(row, nil, "GameFontHighlightSmall")
        row.side:SetPoint("RIGHT", -12, 1)
        row.name = NewLabel(row)
        row.name:SetPoint("LEFT", 26, 0)
        row.seen = NewLabel(row, nil, "GameFontDisableSmall")
        row.seen:SetPoint("RIGHT", -12, 0)
        row.state = NewLabel(row, nil, "GameFontHighlightSmall")
        row.state:SetPoint("LEFT", 260, 0)
        row.state:SetPoint("RIGHT", row.seen, "LEFT", -10, 0) -- a long state is cut, never over the time
        row.state:SetJustifyH("LEFT")
        row.state:SetWordWrap(false)
        row.note = NewLabel(row, nil, "GameFontDisable")
        row.note:SetPoint("LEFT", 26, 0)
        row.hit = CreateFrame("Button", nil, row)
        row.hit:SetAllPoints()
        row.hit:SetScript("OnEnter", function(self) if self.tooltip then ShowTooltip(self, self.tooltip) end end)
        row.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.hit:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
        row.built = true
    end
    local header, player = item.kind == "guild", item.kind == "player"
    local note = item.kind == "note" or item.kind == "fold"
    row.card:SetShown(header)
    row.title:SetShown(header)
    row.side:SetShown(header)
    row.name:SetShown(player)
    row.state:SetShown(player)
    row.seen:SetShown(player)
    row.note:SetShown(note)
    row.hit:EnableMouse(header or player or item.kind == "fold")
    row.hit.tooltip = nil
    row.hit.onClick = item.onClick
    if header then
        row.title:SetText((item.open and FOLD_OPEN or FOLD_CLOSED) .. item.name
            .. "  |cff8fb8e8[" .. (item.tag or "?") .. "]|r"
            .. (item.mine and ("  |cff808080" .. L["your guild"] .. "|r") or ""))
        row.side:SetText(item.side or "")
        row.hit.tooltip = item.tooltip
    elseif player then
        local p = item.player
        -- Not heard from lately (or only seen before this session): greyed.
        if item.mine then
            row.name:SetText(p.online and NameText(p.name, p.class) or ("|cff9d9d9d" .. p.name .. "|r"))
            local ver = ns.Comm:GetVersion(p.name)
            local old = ver and ns.version ~= "?" and ns.CompareVersions(ver, ns.version) < 0
            row.state:SetText(not p.online and ("|cff808080" .. L["offline"] .. "|r")
                or old and ("|cffff9900" .. L["(old version)"] .. "|r")
                or ("|cff808080" .. (ver and ("La Taverne v" .. ver) or "La Taverne") .. "|r"))
            row.hit.tooltip = { NameText(p.name, p.class),
                ver and ("La Taverne v" .. ver) or "La Taverne",
                p.seen and (L["Last heard from:"] .. " " .. Ago(p.seen)) or nil }
        else
            local short = VOUCH_SHORT[p.state]
            row.name:SetText(p.online and p.name or ("|cff9d9d9d" .. p.name .. "|r"))
            if p.remembered then
                row.state:SetText("|cff808080" .. L["Not heard since you logged in"] .. "|r")
            else
                row.state:SetText(short and (short[1] .. " |cff" .. short[2] .. L[short[3]] .. "|r")
                    or ("|cff808080" .. (p.state and L["Checking..."] or L["online, not checked yet"]) .. "|r"))
            end
            row.hit.tooltip = { p.name .. "  |cff8fb8e8[" .. (p.tag or p.guild or "?") .. "]|r",
                p.remembered and L["Seen before, not heard from since you logged in."] or ns.Vouch.StateText(p),
                p.seen and (L["Last heard from:"] .. " " .. Ago(p.seen)) or nil }
        end
        row.seen:SetText(p.seen and Ago(p.seen) or "")
    elseif item.kind == "fold" then
        row.note:SetText((item.open and FOLD_OPEN or FOLD_CLOSED) .. format(L["%d offline"], item.count))
    else
        row.note:SetText(item.text)
    end
end

local function AllianceRowHeight(item)
    if item.kind == "guild" then return CARD_HEADER end
    if item.kind == "gap" then return CARD_GAP end
    return CARD_ROW
end

local function BuildNetworkPanel()
    local p = NewPanel()
    NewPageTitle(p, L["Guild Alliance"], { L["Guild Alliance"],
        L["Guilds linked together: their groups, available players and guild chat are shared, as if it were one guild."],
        L["Members of their guild confirm who they are. Players their guild doesn't know are ignored."],
        L["Not checked yet: nobody from their guild was online to confirm them. They still get through, and are checked again later."] })
    -- Top right: Setup (players who can edit the Guild Info), then the channel left of it.
    local setupPage = NewButton(p, L["Setup"], 130, 24)
    setupPage:SetPoint("TOPRIGHT", -2, -4)
    setupPage:SetScript("OnClick", function() UI:ShowPage("officers") end)
    local status = NewLabel(p, "", "GameFontHighlight")
    local statusHit = CreateFrame("Frame", nil, p)
    statusHit:SetAllPoints(status)
    statusHit:EnableMouse(true)
    statusHit:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["Guild Alliance channel"],
            L["The hidden channel the allied guilds talk on. Ready: groups, availability and shared chat go through."] })
    end)
    statusHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Folded cards and "n offline" lines, per guild (lowercased name).
    p.open, p.offlineOpen = {}, {}
    local list = NewScrollList(p, AllianceRowHeight, InitAllianceRow)
    list:SetPoint("TOPLEFT", 0, -44)
    list:SetPoint("BOTTOMRIGHT", -20, 0)

    -- Not set up yet: a short explanation, and the way to the setup for officers.
    local empty = NewLabel(p, L["Your guild isn't linked to other guilds yet."], "GameFontDisable")
    empty:SetPoint("TOP", 0, -120)
    local emptyHint = NewLabel(p, L["Officers set it up on the Setup page."], "GameFontDisableSmall")
    emptyHint:SetPoint("TOP", empty, "BOTTOM", 0, -6)
    local setup = NewButton(p, L["Set up the Guild Alliance"], 220)
    setup:SetPoint("TOP", emptyHint, "BOTTOM", 0, -12)
    setup:SetScript("OnClick", function() UI:ShowPage("officers") end)

    function p:Refresh()
        local active = ns.Alliance:IsActive()
        local officer = ns.Guild:IsOfficer() and active
        setupPage:SetShown(officer)
        status:ClearAllPoints()
        if officer then status:SetPoint("RIGHT", setupPage, "LEFT", -14, 0) else status:SetPoint("TOPRIGHT", -8, -12) end
        list:SetShown(active)
        status:SetShown(active)
        empty:SetShown(not active)
        emptyHint:SetShown(not active)
        -- Just after login the Guild Info isn't read yet: say so, not "not linked".
        if not ns.Alliance:IsLoaded() then
            empty:SetText(L["Reading the Guild Info..."])
            emptyHint:SetText(L["A few seconds after logging in."])
            setup:Hide()
            return
        end
        empty:SetText(L["Your guild isn't linked to other guilds yet."])
        setup:SetShown(not active and ns.Guild:IsOfficer() and true or false)
        emptyHint:SetText(ns.Guild:IsOfficer() and L["You can set it up: you can edit the Guild Info."]
            or L["Officers set it up on the Setup page."])
        if not active then return end

        status:SetText(L["Channel:"] .. " " .. ns.Comm:AllyStatusText())
        ns.Players:AskWho() -- my guild's members with La Taverne (at most every 30 s)

        -- Players heard from, by guild (mine: my guild's members with La Taverne).
        local byGuild = {}
        for _, pl in ipairs(ns.Vouch:GetPlayers()) do
            local key = (pl.guild or ""):lower()
            byGuild[key] = byGuild[key] or {}
            table.insert(byGuild[key], pl)
        end
        -- Activity per guild: open groups and available players (mine: no tag).
        local byTag = {}
        for _, entry in ipairs(ns.Alliance:GetGuilds()) do
            if entry.tag then byTag[entry.tag:lower()] = entry.name:lower() end
        end
        local mineKey = (ns.Guild:GetName() or ""):lower()
        local activity = {}
        local function Count(tag, field)
            local key = tag and byTag[tag:lower()] or mineKey
            activity[key] = activity[key] or { groups = 0, available = 0 }
            activity[key][field] = activity[key][field] + 1
        end
        for _, l in ipairs(ns.Groups:GetListings()) do
            if ns.Groups:IsOpen(l) then Count(l.tag, "groups") end
        end
        for _, a in ipairs(ns.Players:GetAvailable()) do Count(a.tag, "available") end
        if ns.Players:IsActive() then Count(nil, "available") end

        -- My guild first, then the others in the setup's order.
        local guilds = {}
        for _, entry in ipairs(ns.Alliance:GetGuilds()) do
            local item = { kind = "guild", name = entry.name, tag = entry.tag, mine = ns.Guild:IsMyGuild(entry.name) }
            if item.mine then table.insert(guilds, 1, item) else guilds[#guilds + 1] = item end
        end
        local rows = {}
        for i, g in ipairs(guilds) do
            if i > 1 then rows[#rows + 1] = { kind = "gap" } end
            local key = g.name:lower()
            local seen = g.mine and ns.Players:GetGuildAddonUsers() or byGuild[key] or {}
            local online, offline = {}, {}
            for _, pl in ipairs(seen) do
                if pl.online then online[#online + 1] = pl else offline[#offline + 1] = pl end
            end
            -- Header: what's going on (groups, available), then who's there.
            local parts = {}
            local act = activity[key]
            if act and act.groups > 0 then
                parts[#parts + 1] = "|cff20ff20" .. (act.groups == 1 and L["1 group"] or format(L["%d groups"], act.groups)) .. "|r"
            end
            if act and act.available > 0 then
                parts[#parts + 1] = "|cff20ff20" .. (act.available == 1 and L["1 available"] or format(L["%d available"], act.available)) .. "|r"
            end
            if #seen > 0 then parts[#parts + 1] = format(L["%d online, %d known"], #online, #seen) end
            g.side = table.concat(parts, "  ·  ")
            -- Folded: my guild by default (its members are on Availability too), the others open.
            if self.open[key] == nil then self.open[key] = not g.mine end
            g.open = self.open[key]
            g.onClick = function() self.open[key] = not self.open[key] self:Refresh() end
            g.tooltip = { g.name .. "  |cff8fb8e8[" .. (g.tag or "?") .. "]|r",
                g.mine and L["Allied players see you with this tag."] or nil }
            rows[#rows + 1] = g
            if g.open then
                if #seen == 0 then
                    rows[#rows + 1] = { kind = "note", text = g.mine and L["Nobody else from your guild with La Taverne heard from yet."]
                        or L["Nobody from this guild heard from yet."] }
                end
                for _, pl in ipairs(online) do rows[#rows + 1] = { kind = "player", player = pl, mine = g.mine } end
                -- The others (not heard from lately, or only before this session): folded.
                if #offline > 0 then
                    local showOffline = self.offlineOpen[key] == true
                    rows[#rows + 1] = { kind = "fold", count = #offline, open = showOffline,
                        onClick = function() self.offlineOpen[key] = not showOffline self:Refresh() end }
                    if showOffline then
                        for _, pl in ipairs(offline) do rows[#rows + 1] = { kind = "player", player = pl, mine = g.mine } end
                    end
                end
            end
        end
        SetListData(list, rows)
    end
    return p
end

-- Options tab ---------------------------------------------------------------------------------

local function BindingText()
    local key = GetBindingKey(BINDING)
    if not key then return "|cff808080" .. L["Not set"] .. "|r" end
    return GetBindingText and GetBindingText(key) or key
end

local function ClearBinding()
    local keys = { GetBindingKey(BINDING) }
    for _, key in ipairs(keys) do SetBinding(key) end
end

local function SaveKeyBindings()
    if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
end

-- Options: one column of sections (General, Minimap, Alerts, Shared guild chat), labels on the
-- left and their control at CONTROL_X; the error report and the version on the bottom line.
local CONTROL_X = 280
local OPTION_ROW, OPTION_GAP = 30, 56 -- between two rows; between a section's last row and the next header (room to breathe: the page scrolls)

-- A dropdown of the game's style: choices = { { text, value } }, get() and set(value).
local function NewChoice(parent, width, choices, get, set, tooltip)
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(width)
    dd:SetupMenu(function(_, root)
        for _, choice in ipairs(type(choices) == "function" and choices() or choices) do
            root:CreateRadio(choice.text, function() return get() == choice.value end, function() set(choice.value) end)
        end
    end)
    if tooltip then
        dd:SetScript("OnEnter", function(self) ShowTooltip(self, tooltip) end)
        dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return dd
end

local function WithTooltip(widget, lines)
    widget:SetScript("OnEnter", function(self) ShowTooltip(self, lines) end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return widget
end

-- The chat windows a line can go to: the main one, then each other window that exists.
local function ChatWindowChoices()
    local out = { { text = L["Main chat window"], value = 0 } }
    for i = 2, (NUM_CHAT_WINDOWS or 10) do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        if name and name ~= "" and (shown or docked) then out[#out + 1] = { text = name, value = i } end
    end
    return out
end

local SCALES = { 0.8, 0.9, 1, 1.1, 1.2, 1.3 }

local function BuildOptionsPanel()
    local p = NewPanel()
    NewPageTitle(p, L["Options"])
    -- The options scroll between the title and the bottom line (error report, version), with a
    -- scroll bar only once they don't fit. The bar's room is always kept: nothing moves.
    local scroll = CreateFrame("ScrollFrame", "LaTaverneOptionsScroll", p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -32)
    scroll:SetPoint("BOTTOMRIGHT", -26, 40)
    local bar = scroll.ScrollBar or _G["LaTaverneOptionsScrollScrollBar"]
    if bar then bar:Hide() end
    local c = CreateFrame("Frame", nil, scroll)
    c:SetSize(1, 1)
    scroll:SetScrollChild(c)
    scroll:SetScript("OnSizeChanged", function(self, width) c:SetWidth(width) end)
    scroll:HookScript("OnScrollRangeChanged", function(_, _, yRange)
        if bar then bar:SetShown((yRange or 0) > 0.5) end
    end)
    local y = -8

    -- Section helpers: a header, then rows going down.
    local function Section(text)
        local header = NewSectionHeader(c, text)
        header:SetPoint("TOPLEFT", 8, y)
        y = y - 32
        return header
    end
    local function Row(label)
        local rowY = y
        if label then NewLabel(c, label):SetPoint("TOPLEFT", 16, rowY - 4) end
        y = y - OPTION_ROW
        return rowY
    end
    local function EndSection() y = y - (OPTION_GAP - OPTION_ROW) end

    -- General ------------------------------------------------------------------
    Section(L["General"])

    -- Keyboard shortcut: click, then press a key. Dark like the game's key binding buttons.
    local rowY = Row(L["Shortcut to open La Taverne"])
    local bind = CreateFrame("Button", nil, c, "BackdropTemplate")
    bind:SetSize(180, 24)
    bind:SetPoint("TOPLEFT", CONTROL_X, rowY)
    if bind.SetBackdrop then
        bind:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        bind:SetBackdropColor(0, 0, 0, 0.7)
        bind:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    local bindText = bind:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bindText:SetPoint("CENTER")
    bind:SetFontString(bindText)
    bind:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    bind:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    WithTooltip(bind, { L["Shortcut to open La Taverne"], L["Click to change, right-click to remove. Escape cancels."] })

    local function StopWaiting()
        bind.waiting = false
        bind:EnableKeyboard(false)
        bind:SetText(BindingText())
        if bind.SetBackdropBorderColor then bind:SetBackdropBorderColor(0.6, 0.6, 0.6, 1) end
    end
    bind:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ClearBinding()
            SaveKeyBindings()
            StopWaiting()
            return
        end
        self.waiting = true
        self:EnableKeyboard(true)
        if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
        self:SetText(L["Press a key..."])
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(1, 0.82, 0, 1) end
    end)
    bind:SetScript("OnKeyDown", function(self, key)
        if not self.waiting then return end
        if key == "ESCAPE" then StopWaiting() return end
        -- A modifier on its own: wait for the actual key.
        if key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then return end
        local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
            .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
        ClearBinding()
        SetBinding(combo, BINDING)
        SaveKeyBindings()
        StopWaiting()
    end)
    bind:SetScript("OnHide", StopWaiting)

    -- Window size, and back to the middle of the screen.
    rowY = Row(L["Window size"])
    local scaleChoices = {}
    for _, s in ipairs(SCALES) do scaleChoices[#scaleChoices + 1] = { text = format("%d %%", math.floor(s * 100 + 0.5)), value = s } end
    local scale = NewChoice(c, 110, scaleChoices, function() return ns.db.scale or 1 end,
        function(s) UI:SetScale(s) end)
    scale:SetPoint("TOPLEFT", CONTROL_X, rowY + 2)
    local resetPos = NewButton(c, L["Recenter the window"], 160)
    resetPos:SetPoint("LEFT", scale, "RIGHT", 10, 0)
    resetPos:SetScript("OnClick", function() UI:ResetPosition() end)

    -- Which chat window gets La Taverne's lines.
    rowY = Row(L["La Taverne messages in"])
    local chatWindow = NewChoice(c, 180, ChatWindowChoices, function() return ns.ChatWindow() and ns.db.chatWindow or 0 end,
        function(i)
            ns.db.chatWindow = i ~= 0 and i or nil
            ns.Print(L["La Taverne messages show here."])
        end,
        { L["La Taverne messages in"], L["New groups, join requests, invitations... Chat windows you made yourself are listed too."] })
    chatWindow:SetPoint("TOPLEFT", CONTROL_X, rowY + 2)

    -- Dungeon names in the other languages (one switch per language, not the client's own).
    local langChecks = {}
    for _, lang in ipairs(ns.OtherDungeonLanguages()) do
        rowY = Row()
        local cb = NewCheckbox(c, format(L["Also show dungeon names in %s, in tooltips"], L[lang.name]), function(self)
            ns.db.dungeonLanguages = ns.db.dungeonLanguages or {}
            ns.db.dungeonLanguages[lang.key] = self:GetChecked() and true or nil
        end)
        cb:SetPoint("TOPLEFT", 12, rowY + 2)
        WithTooltip(cb, { cb.Text and cb.Text:GetText() or "",
            L["Hover a dungeon (lists, group titles, players) to see its name there too. Handy with players who use the game in another language."] })
        cb.key = lang.key
        langChecks[#langChecks + 1] = cb
    end
    EndSection()

    -- Minimap ------------------------------------------------------------------
    Section(L["Minimap"])
    rowY = Row()
    local minimap = NewCheckbox(c, L["Show the minimap button"], function(self)
        ns.db.minimap.hide = not self:GetChecked()
        local icon = LibStub("LibDBIcon-1.0")
        if ns.db.minimap.hide then icon:Hide(ADDON) else icon:Show(ADDON) end
    end)
    minimap:SetPoint("TOPLEFT", 12, rowY + 2)
    -- The game's add-on drawer by the minimap (only when the game has one).
    local drawer = NewCheckbox(c, L["Show in the add-on drawer"], function(self)
        ns.Minimap:SetInDrawer(self:GetChecked())
    end)
    drawer:SetPoint("TOPLEFT", CONTROL_X - 4, rowY + 2)
    WithTooltip(drawer, { L["Show in the add-on drawer"], L["The game's button by the minimap that lists your add-ons."] })
    rowY = Row()
    local glow = NewCheckbox(c, L["Glow and count on the button when something waits for you"], function(self)
        ns.db.minimapGlow = self:GetChecked() and true or false
        if ns.Minimap.Update then ns.Minimap.Update() end
    end)
    glow:SetPoint("TOPLEFT", 12, rowY + 2)
    WithTooltip(glow, { L["Glow and count on the button when something waits for you"],
        L["Someone asks to join your group, or a group invites you. Opening the page that shows it stops the glow."] })
    EndSection()

    -- Alerts -------------------------------------------------------------------
    Section(L["Alerts"])
    -- New groups: a chat line for all of them, only those that fit me, or none
    rowY = Row(L["Tell me about new groups"])
    local alerts = NewChoice(c, 220, {
            { text = L["All groups"], value = "all" },
            { text = L["Only groups that fit me"], value = "fit" },
            { text = L["None"], value = "none" },
        }, function() return ns.Groups:AlertMode() end, function(mode) ns.db.alerts = mode end,
        { L["Tell me about new groups"],
            L["A chat line when a guild member posts a group. Fit me: it needs one of the roles you ticked in the group list, and the dungeon is at your level."] })
    alerts:SetPoint("TOPLEFT", CONTROL_X, rowY + 2)
    local alertSound = NewCheckbox(c, L["With a sound"], function(self)
        ns.db.alertSound = self:GetChecked() and true or nil
    end)
    alertSound:SetPoint("LEFT", alerts, "RIGHT", 12, 0)
    rowY = Row()
    local requestSound = NewCheckbox(c, L["A sound when someone asks to join my group"], function(self)
        ns.db.requestSound = self:GetChecked() and true or false
    end)
    requestSound:SetPoint("TOPLEFT", 12, rowY + 2)
    WithTooltip(requestSound, { L["A sound when someone asks to join my group"],
        L["Also when a player accepts your invitation. The chat line is always there."] })
    rowY = Row()
    local quiet = NewCheckbox(c, L["Quiet in dungeons, raids and combat"], function(self)
        ns.db.quiet = self:GetChecked() and true or nil
    end)
    quiet:SetPoint("TOPLEFT", 12, rowY + 2)
    WithTooltip(quiet, { L["Quiet in dungeons, raids and combat"],
        L["No new group alerts and no sounds there. Join requests and invitations still show in the chat."] })
    EndSection()

    -- Shared guild chat: always on. The tag option, and (only while GuildUnion is loaded too)
    -- a switch to stop it, so allied lines don't show twice --------------------------------
    local chatHeader = Section(L["Shared guild chat"])
    local chatInfo = NewInfoIcon(c, { L["Shared guild chat"],
        L["Messages from the allied guilds show up in your guild chat, and yours in theirs."],
        L["Only with a Guild Alliance."] })
    chatInfo:SetPoint("LEFT", chatHeader, "RIGHT", 6, 0)
    local chatOff = NewLabel(c, L["Only with a Guild Alliance."], "GameFontDisableSmall")
    chatOff:SetPoint("LEFT", chatInfo, "RIGHT", 10, 0)
    rowY = Row()
    local allyTag = NewCheckbox(c, L["Show the guild tag on allied messages"], function(self)
        ns.db.allyChat.showTag = self:GetChecked() and true or false
    end)
    allyTag:SetPoint("TOPLEFT", 12, rowY + 2)
    -- Only with GuildUnion loaded (see Refresh): its own row, under the tag.
    rowY = Row()
    local allyChat = NewCheckbox(c, L["Share guild chat with the allied guilds"], function(self)
        ns.db.allyChat.enabled = self:GetChecked() and true or false
        allyTag:SetEnabled(ns.db.allyChat.enabled)
    end)
    allyChat:SetPoint("TOPLEFT", 12, rowY + 2)
    WithTooltip(allyChat, { L["Share guild chat with the allied guilds"],
        L["Shown because GuildUnion is installed: it shares guild chat too. Keep only one of the two sharing, or allied lines show twice."] })
    local contentHeight = -y + 8

    -- Bottom line: the error report (always there, so players know where to look), and the
    -- version (to say which one you have when reporting a problem).
    local errorCount = NewLabel(p, "", "GameFontHighlightSmall")
    errorCount:SetPoint("BOTTOMLEFT", 16, 12)
    local showErrors = NewButton(p, L["Show the error report"], 180)
    showErrors:SetPoint("LEFT", errorCount, "RIGHT", 12, 0)
    showErrors:SetScript("OnClick", function() ns.Errors:Show() end)
    local clearErrors = NewButton(p, L["Clear"], 80)
    clearErrors:SetPoint("LEFT", showErrors, "RIGHT", 6, 0)
    clearErrors:SetScript("OnClick", function()
        ns.Errors:Clear()
        p:Refresh()
    end)
    local version = NewLabel(p, "La Taverne " .. (ns.version or "?"), "GameFontDisableSmall")
    version:SetPoint("BOTTOMRIGHT", -12, 12)

    function p:Refresh()
        if not bind.waiting then bind:SetText(BindingText()) end
        for _, dd in ipairs({ scale, chatWindow, alerts }) do
            if dd.GenerateMenu then dd:GenerateMenu() end
        end
        minimap:SetChecked(not ns.db.minimap.hide)
        drawer:SetShown(ns.Minimap:HasDrawer())
        drawer:SetChecked(ns.db.inDrawer ~= false)
        glow:SetChecked(ns.db.minimapGlow ~= false)
        alertSound:SetChecked(ns.db.alertSound == true)
        requestSound:SetChecked(ns.db.requestSound ~= false)
        quiet:SetChecked(ns.db.quiet == true)
        for _, cb in ipairs(langChecks) do cb:SetChecked((ns.db.dungeonLanguages or {})[cb.key] == true) end

        local active = ns.Alliance:IsActive()
        chatOff:SetShown(not active)
        allyChat:SetShown(ns.AllyChat:CanTurnOff())
        -- The scroll height: without the GuildUnion switch, its row isn't there.
        c:SetHeight(contentHeight - (ns.AllyChat:CanTurnOff() and 0 or OPTION_ROW))
        allyChat:SetChecked(ns.db.allyChat.enabled)
        allyTag:SetChecked(ns.db.allyChat.showTag)
        allyChat:SetEnabled(active)
        allyTag:SetEnabled(active and ns.AllyChat.Enabled())

        local errors = ns.Errors:Count()
        showErrors:SetEnabled(errors > 0)
        clearErrors:SetEnabled(errors > 0)
        errorCount:SetText(errors > 0 and L["Errors recorded: %d"]:format(errors) or L["No errors recorded."])
    end
    return p
end

-- Shared with DebugUI.lua (test mode tab and test guild window).
ns.UIKit = {
    NewPanel = NewPanel, NewButton = NewButton, NewLabel = NewLabel, NewCheckbox = NewCheckbox,
    NewInput = NewInput, NewScrollList = NewScrollList, SetListData = SetListData,
    RowBackground = RowBackground, ClassColored = ClassColored, NewTextArea = NewTextArea,
    SetPlaceholder = SetPlaceholder,
    ShowTooltip = ShowTooltip, Ago = Ago,
    NewIconButton = NewIconButton, NewInfoIcon = NewInfoIcon, NewPageTitle = NewPageTitle, NewChoice = NewChoice, WithTooltip = WithTooltip,
}

-- Window --------------------------------------------------------------------------------
-- Navigation:
-- - side tabs (right edge, like the spellbook / group finder): the sections;
-- - inside a section, its other pages open from a button on the page (Settings, Setup,
--   Create a group), with Back to return.
-- Sections and pages a player can't use are hidden, not greyed out.

local SECTIONS = {
    -- Icons: the first file the client has (see SetFirstTexture). Groups: the dungeon finder's
    -- eye, like the game's own group finder.
    { key = "groups", label = "Groups",
      icon = {
          -- The eye of the queue button (first picture of its animation sheet, 8 x 4 eyes).
          { atlas = "groupfinder-eye-single" },
          { file = "Interface\\LFGFrame\\LFG-Eye", coords = { 0, 0.125, 0, 0.25 } },
          "Interface\\LFGFrame\\UI-LFG-PORTRAIT",
          "Interface\\Icons\\INV_Misc_GroupNeedMore",
      },
      -- Browse and My group are one page for the player: My group while in a group of the finder.
      pages = { "browse", "mygroup" } },
    -- Availability: my availability and who's available. A pocket watch: it lasts a set time.
    { key = "availability", label = "Availability",
      icon = { "Interface\\Icons\\INV_Misc_PocketWatch_01", "Interface\\Icons\\INV_Misc_Note_01" },
      pages = { "players" } },
    -- The Guild Alliance; its Setup page only for players who can edit the Guild Info.
    { key = "network", label = "Alliance", icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
      pages = { "network", "officers" } },
    -- Auto-invite: a horn, calling people in.
    { key = "autoinvite", label = "Auto-invite",
      icon = { "Interface\\Icons\\INV_Misc_Horn_01", "Interface\\Icons\\Ability_Warrior_BattleShout" },
      pages = { "autoinvite", "autoinviteSettings" } },
    -- Pinned to the bottom of the side bar, last one lowest.
    { key = "options", label = "Options", icon = "Interface\\Icons\\INV_Misc_Gear_01",
      pages = { "options" }, bottom = true },
    -- Not a page: opens (or closes) the test guild window, one click away. Test mode only.
    -- Test mode tools, set apart: small buttons sitting on top of the window's right corner
    -- (not side tabs), left to right.
    { key = "testguild", label = "Test guild", icon = "Interface\\Icons\\INV_BannerPVP_02",
      pages = {}, tool = true, sandboxOnly = true,
      action = function() ns.MockGuild:Toggle() end },
    { key = "debug", label = "Test mode", icon = "Interface\\Icons\\INV_Misc_Wrench_01",
      pages = { "debug" }, tool = true },
}


local PAGE_BUILDERS -- filled in CreateMainFrame (some builders live in files loaded after this one)

local currentPage = "browse"
local lastPage = {}       -- [sectionKey] = last page shown in that section
local sectionOf = {}      -- [pageKey] = section
for _, section in ipairs(SECTIONS) do
    for _, page in ipairs(section.pages) do sectionOf[page] = section end
end

local function PageAllowed(page)
    if page == "officers" then return ns.Guild:IsOfficer() and true or false end
    if page == "debug" then return ns.Guild:IsSandbox() and true or false end
    if page == "autoinvite" or page == "autoinviteSettings" then return ns.Invites:IsAllowed() end
    return true
end

local function VisiblePages(section)
    local out = {}
    for _, page in ipairs(section.pages) do
        if PageAllowed(page) then out[#out + 1] = page end
    end
    return out
end

local function PageBadge(page)
    if page == "browse" then return ns.Groups:CountNewInvitations() end
    if page == "mygroup" then return ns.Groups:CountRequests() end
    if page == "players" then return ns.Players:CountFitting() end
    if page == "autoinvite" then return #ns.Invites:GetQueue() end
    return 0
end

local function SectionBadge(section)
    local total = 0
    for _, page in ipairs(VisiblePages(section)) do total = total + (PageBadge(page) or 0) end
    return total
end

-- Something of mine running in that section (a green dot on its side tab): my group (posted,
-- or one I'm in), my availability, auto-invite.
local function SectionActive(section)
    if section.key == "groups" then return (ns.Groups:GetMine() or ns.Groups:GetJoined()) and true or false end
    if section.key == "availability" then return ns.Players:IsActive() and true or false end
    if section.key == "autoinvite" then return ns.Invites:IsActive() and true or false end
    return false
end

-- The side tab's tooltip: what's going on there (white), what waits for me (green).
local function SectionStatus(section)
    local lines = {}
    local G, P = ns.Groups, ns.Players
    if section.key == "groups" then
        local mine, joined = G:GetMine(), G:GetJoined()
        if mine then
            lines[#lines + 1] = { format(L["Your group: %s"], ns.DungeonName(mine.dungeon)), 1, 1, 1 }
            local requests = G:CountRequests()
            if requests > 0 then lines[#lines + 1] = { format(L["%d requests"], requests), 0.1, 1, 0.1 } end
        elseif joined then
            lines[#lines + 1] = { format(L["In a group: %s"], ns.DungeonName(joined.dungeon)), 1, 1, 1 }
        end
        local invitations = G:CountNewInvitations()
        if invitations > 0 then lines[#lines + 1] = { format(L["Invitations: %d"], invitations), 0.1, 1, 0.1 } end
        lines[#lines + 1] = { format(L["Open groups: %d"], G:CountOpen()), 0.8, 0.8, 0.8 }
    elseif section.key == "availability" then
        if P:IsActive() then
            local left = P:Remaining()
            lines[#lines + 1] = { left and format(L["Available for %d more min"], math.max(1, math.ceil(left / 60)))
                or L["Available until you log out"], 1, 1, 1 }
        end
        local fitting = P:CountFitting()
        if fitting > 0 then lines[#lines + 1] = { format(L["Players who fit your group: %d"], fitting), 0.1, 1, 0.1 } end
        lines[#lines + 1] = { format(L["Available players: %d"], P:CountAvailable()), 0.8, 0.8, 0.8 }
    elseif section.key == "autoinvite" and ns.Invites:IsActive() then
        lines[#lines + 1] = { format(L["Auto-invite: %d in the queue"], #ns.Invites:GetQueue()), 1, 1, 1 }
    end
    return lines
end

-- Side tab: the spellbook's skill line tab look, the section's icon, a count in the corner.
-- Icon size and spacing; the tab's frame texture scales with the icon (64 px for a 32 px icon).
local SIDE_SIZE, SIDE_STEP = 42, 58
local SIDE_SCALE = SIDE_SIZE / 32
local TOOL_SIZE = 26 -- test mode tools, above the title bar
local TOOL_RIGHT = 40 -- their gap from the window's right edge (clear of the close button)

local function NewSideTab(section)
    -- A plain button with its own icon and selection glow: a CheckButton's checked texture
    -- was drawn over the icon and left the selected tab blank.
    local b = CreateFrame("Button", nil, frame, section.tool and "BackdropTemplate" or nil)
    if section.tool then
        -- A small icon in a thin dark frame: a tool, not a section of the addon.
        b:SetSize(TOOL_SIZE, TOOL_SIZE)
        if b.SetBackdrop then
            b:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 } })
            b:SetBackdropBorderColor(1, 0.6, 0, 1)
        end
    else
        b:SetSize(SIDE_SIZE, SIDE_SIZE)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        bg:SetSize(64 * SIDE_SCALE, 64 * SIDE_SCALE)
        bg:SetPoint("TOPLEFT", -3 * SIDE_SCALE, 11 * SIDE_SCALE)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    if section.tool then
        b.icon:SetPoint("TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    else
        b.icon:SetAllPoints()
    end
    if type(section.icon) == "table" then
        SetFirstTexture(b.icon, unpack(section.icon))
    else
        b.icon:SetTexture(section.icon)
    end
    b.selected = b:CreateTexture(nil, "OVERLAY")
    b.selected:SetAllPoints()
    b.selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    b.selected:SetBlendMode("ADD")
    b.selected:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    function b:SetChecked(on) self.selected:SetShown(on and true or false) end
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -1, 2)
    -- Something of mine running there: a green dot, top right (like the minimap button's).
    b.dot = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online")
    b.dot:SetSize(24, 24)
    b.dot:SetPoint("TOPRIGHT", 8, 8)
    b.dot:Hide()
    b:SetScript("OnClick", function()
        if section.action then section.action() else UI:ShowSection(section.key) end
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L[section.label])
        for _, line in ipairs(SectionStatus(section)) do GameTooltip:AddLine(line[1], line[2], line[3], line[4]) end
        if section.key == "testguild" then
            GameTooltip:AddLine(L["Opens the test guild window."], 1, 1, 1, true)
        elseif section.key == "debug" then
            GameTooltip:AddLine(L["Test mode only."], 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.section = section
    return b
end

local function LayoutSideTabs()
    local currentSection = sectionOf[currentPage]
    local y = -36
    local shownBottom, shownTools = {}, {}
    for _, b in ipairs(frame.SideTabs) do
        local section = b.section
        local shown
        if section.action then
            shown = (not section.sandboxOnly or ns.Guild:IsSandbox()) and true or false
        else
            shown = #VisiblePages(section) > 0
        end
        b:SetShown(shown)
        b:SetChecked(section == currentSection)
        local badge = shown and SectionBadge(section) or 0
        b.count:SetText(badge > 0 and badge or "")
        if b.dot then b.dot:SetShown(shown and SectionActive(section)) end
        if shown then
            b:ClearAllPoints()
            if section.tool then
                shownTools[#shownTools + 1] = b
            elseif section.bottom then
                shownBottom[#shownBottom + 1] = b
            else
                b:SetPoint("TOPLEFT", frame, "TOPRIGHT", -1, y)
                y = y - SIDE_STEP
            end
        end
    end
    -- Bottom group, stacked upwards from the bottom of the frame.
    local by = 24
    for i = #shownBottom, 1, -1 do
        shownBottom[i]:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", -1, by)
        by = by + SIDE_STEP
    end
    -- Test tools, on top of the window's right corner, the last one rightmost.
    local tx = -TOOL_RIGHT
    for i = #shownTools, 1, -1 do
        shownTools[i]:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", tx, 1)
        tx = tx - TOOL_SIZE - 4
    end
end

local function CreateMainFrame()
    frame = CreateFrame("Frame", "LaTaverneFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(780, 580)
    frame:SetPoint("CENTER", -20, 0)
    frame:SetScale(ns.db.scale or 1) -- window size, from Options
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    -- Keep the side tabs and test tools (above the title bar) on screen too.
    if frame.SetClampRectInsets then frame:SetClampRectInsets(0, SIDE_SIZE + 6, TOOL_SIZE + 2, 0) end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(frame) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end
    -- Remove the empty band under the title.
    if ButtonFrameTemplate_HideAttic then
        ButtonFrameTemplate_HideAttic(frame)
    elseif frame.Inset then
        frame.Inset:SetPoint("TOPLEFT", 4, -24)
    end

    local titleText = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText)
    if frame.SetTitle then
        frame:SetTitle(TITLE)
    elseif titleText then
        titleText:SetText(TITLE)
    end
    -- The template's close button goes through the panel manager, which may ignore addon frames.
    if frame.CloseButton then
        frame.CloseButton:SetScript("OnClick", function() frame:Hide() end)
    end
    tinsert(UISpecialFrames, "LaTaverneFrame")

    -- Test mode, said once for the whole addon: an orange banner on top of the window, left
    -- of the test tools. No other page repeats it.
    local badge = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    badge:SetHeight(TOOL_SIZE)
    badge:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -(TOOL_RIGHT + 2 * (TOOL_SIZE + 4)), 1)
    if badge.SetBackdrop then
        badge:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        badge:SetBackdropColor(0.1, 0.05, 0, 0.85)
        badge:SetBackdropBorderColor(1, 0.6, 0, 1)
    end
    badge.text = NewLabel(badge, "|cffff9900" .. L["Test mode: everything stays in the test guild, nothing reaches your real guild."] .. "|r", "GameFontNormal")
    badge.text:SetPoint("CENTER")
    badge:SetWidth(badge.text:GetStringWidth() + 24)
    badge:EnableMouse(true)
    badge:SetScript("OnEnter", function(self)
        ShowTooltip(self, { L["Test mode"], GuildLine(),
            L["Nothing goes to your real guild: groups, players and chat stay in the test guild."] })
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:Hide()
    frame.TestBadge = badge

    PAGE_BUILDERS = {
        browse = BuildGroupsPanel,
        mygroup = BuildMyGroupPanel,
        players = BuildPlayersPanel,
        autoinvite = ns.BuildInvitesPanel,
        autoinviteSettings = ns.BuildInvitesSettingsPanel,
        network = BuildNetworkPanel,
        officers = BuildOfficerPanel,
        options = BuildOptionsPanel,
        debug = ns.BuildDebugPanel,
    }

    -- Pages: one side tab per section; a section's other pages open from a button on its page
    -- (Settings, Setup, Create a group), with Back to return. No bottom tabs.
    frame.SideTabs = {}
    for _, section in ipairs(SECTIONS) do
        frame.SideTabs[#frame.SideTabs + 1] = NewSideTab(section)
        for _, page in ipairs(section.pages) do panels[page] = PAGE_BUILDERS[page]() end
    end

    frame:SetScript("OnShow", function() UI:Refresh() end)
    frame:Hide()
end

-- The page to land on when the current one isn't allowed anymore.
local function Fallback(page)
    local section = sectionOf[page]
    local visible = section and VisiblePages(section) or {}
    return visible[1] or "browse"
end

local wasInGroup -- in a group of the finder at the last refresh (nil before the first one)

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    -- Last invitation gone while looking at it, officer rank lost, test mode left...
    if not PageAllowed(currentPage) then
        self:ShowPage(Fallback(currentPage))
        return
    end
    -- Just joined, posted, left or removed a group: Groups goes to My group or Browse.
    local inGroup = InFinderGroup()
    local changed = wasInGroup ~= nil and wasInGroup ~= inGroup
    wasInGroup = inGroup
    if changed and (currentPage == "browse" or currentPage == "mygroup") and currentPage ~= GroupsHome() then
        self:ShowPage(GroupsHome())
        return
    end
    LayoutSideTabs()
    frame.TestBadge:SetShown(ns.Guild:IsSandbox() and true or false)
    -- Title bar: "La Taverne · Groups", the section I'm in.
    local section = sectionOf[currentPage]
    local title = TITLE .. (section and ("  \194\183  " .. L[section.label]) or "")
    if frame.SetTitle then
        frame:SetTitle(title)
    else
        local titleText = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText)
        if titleText then titleText:SetText(title) end
    end
    local panel = panels[currentPage]
    if panel then panel:Refresh() end
    -- Looking at Browse: the invitations on top won't pull me there again.
    if currentPage == "browse" then ns.Groups:MarkInvitationsSeen() end
    if currentPage == "mygroup" then ns.Groups:MarkRequestsSeen() end
end

function UI:ShowPage(page)
    if not frame then CreateMainFrame() end
    if not sectionOf[page] then page = "browse" end
    if not PageAllowed(page) then page = Fallback(page) end
    currentPage = page
    lastPage[sectionOf[page].key] = page
    for key, panel in pairs(panels) do
        panel:SetShown(key == page)
    end
    self:Refresh()
end

-- A section opens on the page last seen there.
function UI:ShowSection(key)
    for _, section in ipairs(SECTIONS) do
        if section.key == key then
            local page = lastPage[key]
            -- Groups: back on My group while in one (not a Browse look around from before).
            if page == "browse" or page == "mygroup" then page = GroupsHome() end
            if not page or not PageAllowed(page) then page = VisiblePages(section)[1] end
            if page then self:ShowPage(page) end
            return
        end
    end
end

-- From the chat's [View] link: Browse, scrolled to that group (My group when it's mine).
function UI:ShowGroup(id)
    if not frame then CreateMainFrame() end
    frame:Show()
    local mine = ns.Groups:GetMine()
    if mine and mine.id == id then
        self:ShowPage("mygroup")
        return
    end
    self:ShowPage("browse")
    local box = panels.browse and panels.browse.box
    if box and box.ScrollToElementDataByPredicate then
        box:ScrollToElementDataByPredicate(function(e) return e.listing and e.listing.id == id end,
            ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
    end
end

function UI:Open()
    if not frame then CreateMainFrame() end
    frame:Show()
end

-- Window size (Options): the scale, kept. The window stays centered on the same point.
function UI:SetScale(scale)
    ns.db.scale = scale ~= 1 and scale or nil
    if not frame then return end
    local x, y = frame:GetCenter()
    local old = frame:GetEffectiveScale()
    frame:SetScale(scale)
    if x and y then
        local ratio = old / frame:GetEffectiveScale()
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * ratio, y * ratio)
    end
end

-- Back to the middle of the screen (Options).
function UI:ResetPosition()
    if not frame then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", -20, 0)
    if frame.SetUserPlaced then frame:SetUserPlaced(false) end
end

function UI:ShowAutoInvite()
    if not frame then CreateMainFrame() end
    frame:Show()
    self:ShowPage("autoinvite")
end

function UI:Toggle()
    if not frame then CreateMainFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        -- A new invitation I haven't seen yet: open on Browse, where it's on top (once).
        -- Otherwise Groups opens on My group while in one.
        local page = currentPage
        if page == "browse" or page == "mygroup" then page = GroupsHome() end
        self:ShowPage(ns.Groups:HasUnseenInvitation() and "browse" or page)
    end
end

-- Key binding (Bindings.xml): shown in the game's Key Bindings under AddOns, and set from the Options tab.
BINDING_HEADER_LATAVERNE = TITLE
BINDING_NAME_LATAVERNE_TOGGLE = L["Open / close La Taverne"]
function LaTaverne_Toggle()
    UI:Toggle()
end

function UI:OnInit()
    ns.Groups:OnChange(function() UI:Refresh() end)
    ns.Players:OnChange(function() UI:Refresh() end)
    -- The Auto-invite side tab shows the queue count.
    ns.Invites:OnChange(function() UI:Refresh() end)
    -- The alliance is read a few seconds after login, and its channel gets ready later still:
    -- an open window follows both.
    ns.Alliance:OnChange(function() UI:Refresh() end)
    ns.Comm:OnReady(function() UI:Refresh() end)
end


function UI:OnLogin()
    -- Party changes update the member list of the create form.
    ns.On("GROUP_ROSTER_UPDATE", function() UI:Refresh() end)
    -- Keep "3 min ago" texts current while the window is open.
    C_Timer.NewTicker(30, function() UI:Refresh() end)
    -- Our chat links: |Haddon:LaTaverne:group:<id>|h. Recent UIs hand "addon" links to
    -- EventRegistry, others only to SetItemRef: listen to both, and handle a click only once
    -- (the same link again within half a second is that same click).
    local lastLink, lastTime
    local function OnLink(link)
        if type(link) ~= "string" then return end
        local kind, data = link:match("^addon:LaTaverne:(%a+):(.+)$")
        if not kind then return end
        if link == lastLink and GetTime() - lastTime < 0.5 then return end
        lastLink, lastTime = link, GetTime()
        if kind == "group" then
            UI:ShowGroup(data)
        elseif kind == "autoinvite" then
            UI:ShowAutoInvite()
        elseif kind == "avail" then
            local ok, err = ns.Players:Start()
            if not ok and err then ns.Print(err) end
        end
    end
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("SetItemRef", function(_, link) OnLink(link) end, UI)
    end
    if SetItemRef then
        hooksecurefunc("SetItemRef", function(link) OnLink(link) end)
    end
end
