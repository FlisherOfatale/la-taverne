-- La Taverne's own menus: a context menu at the cursor and a dropdown button. They take the same
-- generator functions as the game's menus (function(_, root) ... end) and understand what La
-- Taverne uses of them: root:CreateTitle, CreateButton, CreateRadio, CreateDivider, and on an
-- element SetEnabled and SetTooltip.
-- Why not the game's: a game menu opened or closed by an addon, with the gamepad UI on, makes
-- the gamepad manager call protected functions from addon code (ADDON_ACTION_FORBIDDEN).
local ADDON, ns = ...

local ROW_H, PAD = 18, 8

-- Menu description -----------------------------------------------------------------------------

local Element = {}
Element.__index = Element

-- Greyed: does nothing when clicked, still shows its tooltip.
function Element:SetEnabled(enabled) self.enabled = enabled and true or false end
-- fn(tooltip, element): fills GameTooltip on mouseover.
function Element:SetTooltip(fn) self.tooltip = fn end

local Root = {}
Root.__index = Root

local function Add(root, item)
    item.enabled = true
    root.items[#root.items + 1] = setmetatable(item, Element)
    return root.items[#root.items]
end

function Root:CreateTitle(text) return Add(self, { kind = "title", text = text }) end
function Root:CreateButton(text, onClick) return Add(self, { kind = "button", text = text, onClick = onClick }) end
function Root:CreateRadio(text, isSelected, setSelected)
    return Add(self, { kind = "radio", text = text, isSelected = isSelected, setSelected = setSelected })
end
function Root:CreateDivider() return Add(self, { kind = "divider" }) end

local function Describe(generator, owner)
    local root = setmetatable({ items = {} }, Root)
    generator(owner, root)
    return root
end

-- The menu window ------------------------------------------------------------------------------
-- One for the whole addon: opening a menu closes the one before.

local menu

local function Close()
    if menu and menu:IsShown() then menu:Hide() end
end

local function Choose(item)
    if not item.enabled then return end
    local dropdown = menu.dropdown
    Close()
    if item.kind == "radio" then
        if item.setSelected then item.setSelected() end
        if dropdown then dropdown:GenerateMenu() end
    elseif item.onClick then
        item.onClick()
    end
end

local function NewRow()
    local row = CreateFrame("Button", nil, menu)
    row:SetHeight(ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.check = row:CreateTexture(nil, "ARTWORK")
    row.check:SetSize(16, 16)
    row.check:SetPoint("LEFT", 0, 0)
    row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 18, 0)
    row.text:SetJustifyH("LEFT")
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.line:SetHeight(1)
    row.line:SetPoint("LEFT", 4, 0)
    row.line:SetPoint("RIGHT", -4, 0)
    row.line:SetColorTexture(0.5, 0.5, 0.5, 0.6)
    row:SetScript("OnClick", function(self) Choose(self.item) end)
    row:SetScript("OnEnter", function(self)
        if not self.item.tooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        self.item.tooltip(GameTooltip, self.item)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function BuildMenu()
    menu = CreateFrame("Frame", "LaTaverneMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    if menu.SetBackdrop then
        menu:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        menu:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    end
    menu.rows = {}
    -- A click anywhere else closes it (a click on its dropdown: the dropdown toggles it).
    menu:SetScript("OnEvent", function(self)
        if self:IsMouseOver() or (self.dropdown and self.dropdown:IsMouseOver()) then return end
        Close()
    end)
    menu:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    menu:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        self.owner, self.dropdown = nil, nil
    end)
    -- Its owner gone (window closed, row hidden): gone too.
    menu:SetScript("OnUpdate", function(self)
        if self.owner and not self.owner:IsVisible() then Close() end
    end)
    menu:Hide()
    tinsert(UISpecialFrames, "LaTaverneMenu")
end

-- Fill the window from a fresh description (the generator runs at each opening).
local function Fill(root, minWidth)
    local width = minWidth or 0
    for i, item in ipairs(root.items) do
        local row = menu.rows[i] or NewRow()
        menu.rows[i] = row
        row.item = item
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", -PAD, 0)
        local text, line = item.kind ~= "divider", item.kind == "divider"
        row.text:SetShown(text)
        row.line:SetShown(line)
        row.check:SetShown(item.kind == "radio" and item.isSelected and item.isSelected() and true or false)
        row.text:SetFontObject(item.kind == "title" and "GameFontNormalSmall"
            or (item.enabled and "GameFontHighlightSmall" or "GameFontDisableSmall"))
        row.text:SetText(item.text or "")
        -- Titles and dividers can't be clicked; greyed items still show their tooltip.
        row:EnableMouse(text and item.kind ~= "title")
        row:Show()
        if text then width = math.max(width, row.text:GetStringWidth() + 18 + 2 * PAD + 8) end
    end
    for i = #root.items + 1, #menu.rows do menu.rows[i]:Hide() end
    menu:SetSize(width, #root.items * ROW_H + 2 * PAD)
end

-- Context menu at the cursor. generator(owner, root) builds it, as for MenuUtil.CreateContextMenu.
function ns.ContextMenu(owner, generator)
    if not menu then BuildMenu() end
    Close()
    menu.owner = owner
    Fill(Describe(generator, owner))
    local x, y = GetCursorPosition()
    local scale = menu:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    menu:Show()
end

-- Dropdown button -----------------------------------------------------------------------------
-- dd:SetupMenu(generator), dd:SetDefaultText(text) (shown while nothing is checked),
-- dd:GenerateMenu() (shows the checked choice; its open menu is filled again, in place, like the
-- game's). A click opens the menu under it, a second closes it.

local Dropdown = {}

function Dropdown:SetupMenu(generator)
    self.generator = generator
    self:GenerateMenu()
end

function Dropdown:SetDefaultText(text)
    self.defaultText = text
    self:GenerateMenu()
end

function Dropdown:GenerateMenu()
    if not self.generator then
        self.text:SetText(self.defaultText or "")
        return
    end
    local root = Describe(self.generator, self)
    local chosen
    for _, item in ipairs(root.items) do
        if item.kind == "radio" and item.isSelected and item.isSelected() then chosen = item.text break end
    end
    self.text:SetText(chosen or self.defaultText or "")
    if self:IsMenuOpen() then Fill(root, self:GetWidth()) end
end

function Dropdown:IsMenuOpen()
    return menu and menu:IsShown() and menu.dropdown == self or false
end

local function ToggleDropdown(self)
    if self:IsMenuOpen() then Close() return end
    if not menu then BuildMenu() end
    Close()
    menu.owner, menu.dropdown = self, self
    Fill(Describe(self.generator, self), self:GetWidth())
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

-- Looks like the dungeon picker (dark box, arrow on the right). The caller sets its width and
-- place, and may set OnEnter / OnLeave: the click doesn't use them.
function ns.NewDropdown(parent)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(120, 25)
    if dd.SetBackdrop then
        dd:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        dd:SetBackdropColor(0, 0, 0, 0.7)
        dd:SetBackdropBorderColor(0.75, 0.6, 0.2, 1)
    end
    dd.arrow = dd:CreateTexture(nil, "ARTWORK")
    dd.arrow:SetSize(20, 20)
    dd.arrow:SetPoint("RIGHT", -4, -1)
    dd.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    dd.text = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dd.text:SetPoint("LEFT", 10, 0)
    dd.text:SetPoint("RIGHT", dd.arrow, "LEFT", -4, 0)
    dd.text:SetJustifyH("LEFT")
    dd.text:SetWordWrap(false)
    dd:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    for name, fn in pairs(Dropdown) do dd[name] = fn end
    dd:SetScript("OnClick", ToggleDropdown)
    return dd
end
