-- The invitation card: when a group invites me, a small box near the top of the screen with the
-- chat line's text and a View button that does what the line's [View] does (La Taverne opens on
-- that group, where I answer). Its [x] puts it away: the chat line and the minimap glow stay.
-- Opening the group (from the card, the chat, the minimap button...) or answering takes it away.
-- Only one card at a time ("+1 more" when other invitations wait). It can be dragged.
-- Also here: the invitation's sound, the flash of the game's icon in the taskbar, and one
-- reminder when I haven't answered after 2 minutes.
-- Held during a fight, and in dungeons and raids when Quiet is on (Options): shown after.
-- With a gamepad (or without a mouse): the "Show what's waiting" key binding does View.
local ADDON, ns = ...
local L = ns.L

local InviteCard = ns.NewModule("InviteCard")

local REMINDER_AFTER = 120 -- seconds after the sound, when I still haven't answered
local BINDING = "LATAVERNE_WAITING"

-- [listing id] = { at = GetTime() of the sound, sounded, reminded, closed }. An invitation that
-- stops waiting (answered, seen, gone) is forgotten: invited again later, it starts over.
local state = {}
local card

local function InFight()
    return ((InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))) and true or false
end

-- The card waits: a fight, or quiet in dungeons and raids (Options).
local function Held()
    return InFight() or ns.Quiet()
end

local function Flash()
    -- The game's icon flashes in the taskbar while the game is in the background (nothing otherwise).
    if FlashClientIcon then FlashClientIcon() end
end

-- Invitations already announced, kept over a /reload or a login (the listing comes again then,
-- as a new invitation): [listing id] = GetServerTime(). Forgotten when I'm no longer invited.
local KEEP_ALERTED = 3 * 3600

local function Alerted()
    ns.db.inviteAlerts = type(ns.db.inviteAlerts) == "table" and ns.db.inviteAlerts or {}
    return ns.db.inviteAlerts
end

-- The sound and the flash, once per invitation; while quiet, when quiet ends.
local function Alert(id, s)
    if s.sounded or ns.Quiet() then return end
    s.sounded = true
    s.at = GetTime()
    Alerted()[id] = GetServerTime()
    ns.Sound("invite")
    Flash()
end

-- "Key: Ctrl-I", when the key binding is set.
local function KeyText()
    local key = GetBindingKey and GetBindingKey(BINDING)
    if not key then return "" end
    return format(L["Key: %s"], (GetBindingText and GetBindingText(key)) or key)
end

-- Like the chat line's [View]: La Taverne on that group. The card goes in any case (the page
-- marks the invitation seen; closed, should it not).
local function View(id)
    if state[id] then state[id].closed = true end
    if card then card:Hide() end
    ns.UI:ShowGroup(id)
end

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then ns.db.inviteCardPos = { point = point, relPoint = relPoint, x = x, y = y } end
end

local WIDTH = 330

local function CreateCard()
    local K = ns.UIKit
    local f = CreateFrame("Frame", "LaTaverneInviteCard", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(WIDTH, 84)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    local pos = ns.db.inviteCardPos
    if type(pos) == "table" and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
    -- Dragged anywhere on it (not the buttons); no keyboard: it never takes the keys.
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    local function DragEnd(self)
        if not self.moving then return end
        self.moving = nil
        self:StopMovingOrSizing()
        SavePosition(self)
    end
    f:SetScript("OnDragStart", function(self)
        self.moving = true
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", DragEnd)
    -- Hidden while dragged (a fight starts): the drag ends there, and the place is kept.
    f:SetScript("OnHide", DragEnd)
    K.BoxBackdrop(f, { 0.05, 0.04, 0.03, 0.92 }, { 1, 0.82, 0, 0.9 })

    local lynx = f:CreateTexture(nil, "ARTWORK")
    lynx:SetSize(32, 32)
    lynx:SetPoint("TOPLEFT", 10, -10)
    lynx:SetTexture("Interface\\AddOns\\LaTaverne\\media\\lynx_icon")

    local title = K.NewLabel(f, "La Taverne", "GameFontNormal")
    title:SetPoint("TOPLEFT", lynx, "TOPRIGHT", 8, 0)
    f.more = K.NewLabel(f, nil, "GameFontDisableSmall")
    f.more:SetPoint("LEFT", title, "RIGHT", 8, 0)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function()
        local s = f.id and state[f.id]
        if s then s.closed = true end
        InviteCard:Update()
    end)
    K.WithTooltip(close, { L["Later"], L["The invitation stays in La Taverne, and the minimap button keeps glowing."] })

    f.text = K.NewLabel(f, nil, "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    f.text:SetWidth(WIDTH - 10 - 32 - 8 - 28)
    f.text:SetJustifyH("LEFT")
    if f.text.SetWordWrap then f.text:SetWordWrap(true) end

    local view = K.NewButton(f, L["View"], 90, 22)
    view:SetPoint("BOTTOMRIGHT", -10, 10)
    view:SetScript("OnClick", function() if f.id then View(f.id) end end)
    K.WithTooltip(view, { L["View"], L["Opens La Taverne on this group, where you answer the invitation."] })

    f.key = K.NewLabel(f, nil, "GameFontDisableSmall")
    f.key:SetPoint("RIGHT", view, "LEFT", -8, 0)

    f:Hide()
    return f
end

-- Card up or down, the sounds of invitations held by quiet. Called when something changes, and
-- every few seconds (the end of a fight, a dungeon left).
function InviteCard:Update()
    if not ns.db then return end
    local waiting = ns.Groups:GetWaitingInvitations()
    local still = {}
    for _, l in ipairs(waiting) do still[l.id] = true end
    for id in pairs(state) do
        if not still[id] then state[id] = nil end
    end
    local first, others = nil, 0
    for _, l in ipairs(waiting) do
        local s = state[l.id]
        if not s then
            s = {}
            state[l.id] = s
        end
        Alert(l.id, s)
        if not s.closed then
            if first then others = others + 1 else first = l end
        end
    end
    if not first or ns.db.inviteCard == false or Held() then
        if card then card:Hide() end
        return
    end
    if not card then card = CreateCard() end
    card.id = first.id
    -- The chat line's text, with its warning when I'm in a party outside La Taverne.
    local text = ns.Groups:InvitationText(first)
    if not ns.Groups:GetMine() and ns.InParty() then
        text = text .. " |cffff9900" .. L["Leave your party first."] .. "|r"
    end
    card.text:SetText(text)
    card.more:SetText(others > 0 and format(L["+%d more"], others) or "")
    card.key:SetText(KeyText())
    -- Title, the text (one or two lines), the button row.
    card:SetHeight(math.max(84, 10 + 14 + 4 + (card.text:GetStringHeight() or 14) + 8 + 22 + 10))
    card:Show()
end

-- A new invitation (Groups.lua, after its chat line): it waits from now on. One already
-- announced before a /reload or a login: the card comes back, without the sound or the reminder.
function InviteCard:OnNewInvitation(l)
    local at = Alerted()[l.id]
    if at and GetServerTime() - at < KEEP_ALERTED then
        state[l.id] = { sounded = true, reminded = true, at = GetTime() }
    else
        state[l.id] = {}
    end
    self:Update()
end

-- I'm no longer invited to that group (cancelled, removed, group gone): invited again later,
-- it's announced again.
function InviteCard:Forget(id)
    if ns.db and type(ns.db.inviteAlerts) == "table" then ns.db.inviteAlerts[id] = nil end
end

-- One reminder per invitation, 2 minutes after its sound: the chat line again, and the sound.
-- Not while away, held, or when the game won't say whether I'm away.
local function Remind()
    if Held() or ns.IsAway() ~= false then return end
    local now = GetTime()
    for _, l in ipairs(ns.Groups:GetWaitingInvitations()) do
        local s = state[l.id]
        if s and s.sounded and not s.reminded and now - (s.at or now) >= REMINDER_AFTER then
            s.reminded = true
            ns.Print(format(L["Still waiting for your answer: %s"], ns.Groups:InvitationText(l)) .. " " .. ns.Groups.GroupLink(l))
            ns.Sound("invite")
            Flash()
        end
    end
end

-- Key binding (Bindings.xml): the card's View; without a card, the invitation I haven't answered,
-- or my group when someone asks to join it.
function InviteCard:ShowWaiting()
    if card and card:IsShown() and card.id then return View(card.id) end
    local G = ns.Groups
    for _, l in ipairs(G:GetInvitations()) do
        if not G:GetInviteReply(l.id) then return View(l.id) end
    end
    local mine = G:GetMine()
    for _, p in pairs(mine and mine.pending or {}) do
        if p.status == "request" then return ns.UI:ShowGroup(mine.id) end
    end
    ns.Print(L["Nothing is waiting for you in La Taverne."])
end

BINDING_NAME_LATAVERNE_WAITING = L["Show what's waiting (invitation, join request)"]
function LaTaverne_ShowWaiting()
    InviteCard:ShowWaiting()
end

function InviteCard:OnInit()
    ns.Groups:OnChange(function() InviteCard:Update() end)
end

function InviteCard:OnLogin()
    -- Old marks go (groups long gone).
    local alerted, now = Alerted(), GetServerTime()
    for id, at in pairs(alerted) do
        if type(at) ~= "number" or now - at >= KEEP_ALERTED then alerted[id] = nil end
    end
    local function Update() InviteCard:Update() end
    -- Hidden as a fight starts, back when it ends; a dungeon entered or left (quiet).
    ns.On("PLAYER_REGEN_DISABLED", Update)
    ns.On("PLAYER_REGEN_ENABLED", Update)
    ns.On("PLAYER_ENTERING_WORLD", Update)
    ns.On("ZONE_CHANGED_NEW_AREA", Update)
    -- The key binding shown on the card.
    ns.On("UPDATE_BINDINGS", function() if card and card:IsShown() then card.key:SetText(KeyText()) end end)
    C_Timer.NewTicker(5, function()
        InviteCard:Update()
        Remind()
    end)
end
