-- La Taverne with a gamepad, when the game's gamepad UI is on. The window's elements are found
-- on their own: anything the mouse can hover or click (buttons, checkboxes, text boxes, list
-- rows, tooltip spots). The d-pad moves a highlight to the nearest one in that direction.
-- Not the game's gamepad navigation: registering an addon window with the gamepad manager makes
-- its protected calls run from addon code (ADDON_ACTION_FORBIDDEN).
local ADDON, ns = ...

local Gamepad = {}
ns.Gamepad = Gamepad

-- Geometry ----------------------------------------------------------------------------------

-- A frame's place on screen: { left, right, top, bottom }, nil while it has none.
local function Rect(f)
    local left, right, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (left and right and top and bottom) then return nil end
    local scale = f:GetEffectiveScale()
    return { left = left * scale, right = right * scale, top = top * scale, bottom = bottom * scale }
end

local function Center(r)
    return (r.left + r.right) / 2, (r.top + r.bottom) / 2
end

local function Contains(clip, x, y)
    return not clip or (x >= clip.left and x <= clip.right and y <= clip.top and y >= clip.bottom)
end

local function Intersect(a, b)
    if not a then return b end
    if not b then return a end
    return { left = math.max(a.left, b.left), right = math.min(a.right, b.right),
        top = math.min(a.top, b.top), bottom = math.max(a.bottom, b.bottom) }
end

-- Gap between two spans (0 when they overlap).
local function Gap(aMin, aMax, bMin, bMax)
    return math.max(0, bMin - aMax, aMin - bMax)
end

-- The nearest rectangle whose center lies in that direction ("UP", "DOWN", "LEFT", "RIGHT"),
-- within a cone around it. Distance: the gap between the edges along the direction, plus twice
-- the gap off its axis (0 for one in the same column or row); the smallest wins. nil: nothing
-- that way.
function Gamepad.Nearest(from, rects, dir)
    local fx, fy = Center(from)
    local best, bestScore
    for i, r in ipairs(rects) do
        local x, y = Center(r)
        local along, across, gapAlong, gapAcross
        if dir == "UP" or dir == "DOWN" then
            along, across = dir == "UP" and y - fy or fy - y, math.abs(x - fx)
            gapAlong, gapAcross = Gap(from.bottom, from.top, r.bottom, r.top), Gap(from.left, from.right, r.left, r.right)
        else
            along, across = dir == "RIGHT" and x - fx or fx - x, math.abs(y - fy)
            gapAlong, gapAcross = Gap(from.left, from.right, r.left, r.right), Gap(from.bottom, from.top, r.bottom, r.top)
        end
        if along > 1 and across <= 2 * along then
            -- Centers break ties (a row and the button in it).
            local score = gapAlong + 2 * gapAcross + 0.01 * (along + across)
            if not bestScore or score < bestScore then best, bestScore = i, score end
        end
    end
    return best
end

-- Elements ----------------------------------------------------------------------------------

local SCRIPTS = { "OnEnter", "OnClick", "OnMouseUp", "OnMouseDown" }

local function IsScrollBox(f)
    return f.FindFrameElementDataIndex ~= nil and f.ScrollToNearest ~= nil
end

local function IsScroller(f)
    return f:IsObjectType("ScrollFrame") or IsScrollBox(f)
end

-- Scroll bars move with the highlight (lists scroll to follow it): not stops of their own.
local function IsScrollBar(f)
    return f:IsObjectType("Slider") or f.GetThumb ~= nil
end

-- A script of the frame, nil when its type has none (GetScript only takes the ones it supports:
-- OnClick is a button's, not a plain frame's).
local function Script(f, name)
    return f:HasScript(name) and f:GetScript(name) or nil
end

local function Usable(f)
    if not f:IsMouseEnabled() then return false end
    if f:IsObjectType("EditBox") then return true end
    for _, script in ipairs(SCRIPTS) do
        if Script(f, script) then return true end
    end
    return false
end

local function Walk(parent, clip, frames, rects)
    for _, child in ipairs({ parent:GetChildren() }) do
        if child:IsVisible() and not IsScrollBar(child) then
            local r = Rect(child)
            if r and Usable(child) and Contains(clip, Center(r)) then
                frames[#frames + 1] = child
                rects[child] = r
            end
            -- A list shows only what's inside its box: the rest is scrolled away.
            Walk(child, (r and IsScroller(child)) and Intersect(clip, r) or clip, frames, rects)
        end
    end
end

-- La Taverne's frames laid over a layer without being its children: the test mode's secure
-- Reload button (Dev.lua), under UIParent and anchored on the popup's button it covers. Found by
-- name (walking UIParent's children costs too much), kept when anchored in that layer.
local OVER = { "LaTaverneReloadButton" }

local function AnchoredIn(f, root)
    local anchor = select(2, f:GetPoint(1))
    while anchor do
        if anchor == root then return true end
        anchor = anchor:GetParent()
    end
    return false
end

-- The usable elements under root, shown and in view, in reading order (top, then left).
-- Returns the frames and their places ([frame] = rect).
function Gamepad.Collect(root)
    local frames, rects = {}, {}
    Walk(root, nil, frames, rects)
    for _, name in ipairs(OVER) do
        local f = _G[name]
        local r = f and f:IsVisible() and Usable(f) and Rect(f)
        if r and AnchoredIn(f, root) then
            frames[#frames + 1] = f
            rects[f] = r
        end
    end
    table.sort(frames, function(a, b)
        local ra, rb = rects[a], rects[b]
        if ra.top ~= rb.top then return ra.top > rb.top end
        return ra.left < rb.left
    end)
    return frames, rects
end

-- Pad buttons ---------------------------------------------------------------------------------
-- While the window is open, the pad's buttons are taken with override bindings to hidden
-- buttons (SetOverrideBindingClick: allowed to addons out of combat), and given back when it
-- closes. B and X stay the game's (B closes the chat). Only the main window takes them: a
-- window that opens on its own (availability ending) never does, so A can't click it mid-fight.
-- A fight gives them back as it starts (before the game locks bindings), and takes them again
-- when it ends if the window is still open.

Gamepad.KEYS = { "PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT", "PAD1", "PAD4", "PADLSHOULDER", "PADRSHOULDER" }

local owner = CreateFrame("Frame", "LaTavernePadOwner", UIParent)
local mainFrame
local bound, pendingClear, fighting = false, false, false

-- Highlight and layers -------------------------------------------------------------------------
-- The d-pad goes through the top layer only: a menu, the dungeon list, a confirmation, the text
-- or copy window, else the page shown. Each layer remembers its highlighted element.

local highlight = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
if highlight.SetBackdrop then
    highlight:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    highlight:SetBackdropBorderColor(1, 0.82, 0, 1)
end
highlight:Hide()

local layer, focus, focusRect, focusData
local remembered = {} -- [layer] = element

local TOP_LAYERS = { "LaTaverneMenu", "LaTaverneDungeonPicker" }
local UNDER_CONFIRM = { "LaTaverneTextDialog", "LaTaverneCopyFrame" }

local function Shown(name)
    local f = _G[name]
    return f and f:IsShown() and f or nil
end

function Gamepad.ActiveLayer()
    for _, name in ipairs(TOP_LAYERS) do
        if Shown(name) then return Shown(name) end
    end
    -- Confirmations (ns.ConfirmDialog) are named LaTaverneConfirm_<kind>, closed by Escape.
    for _, name in ipairs(UISpecialFrames) do
        if name:find("^LaTaverneConfirm_") and Shown(name) then return Shown(name) end
    end
    for _, name in ipairs(UNDER_CONFIRM) do
        if Shown(name) then return Shown(name) end
    end
    return ns.UI and ns.UI.CurrentPanel and ns.UI:CurrentPanel()
end

function Gamepad.Focused()
    return focus
end

function Gamepad.Highlight()
    return highlight
end

local function Focus(f)
    if f == focus then return end
    if focus then
        local leave = focus:GetScript("OnLeave")
        if leave then leave(focus) end
    end
    focus = f
    if layer then remembered[layer] = f end
    if not f then
        highlight:Hide()
        return
    end
    focusRect = Rect(f)
    -- On the element, above it: hidden with it.
    highlight:SetParent(f)
    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", -4, 4)
    highlight:SetPoint("BOTTOMRIGHT", 4, -4)
    highlight:SetFrameLevel(f:GetFrameLevel() + 10)
    highlight:Show()
    -- Its tooltip, as with the mouse (greyed buttons too: they say why).
    local enter = Script(f, "OnEnter")
    if enter then enter(f, true) end
end

local function Find(list, item)
    for i, v in ipairs(list) do
        if v == item then return i end
    end
end

local function Closest(from, frames, rects)
    local fx, fy = Center(from)
    local best, bestDistance
    for _, f in ipairs(frames) do
        local x, y = Center(rects[f])
        local distance = (x - fx) ^ 2 + (y - fy) ^ 2
        if not bestDistance or distance < bestDistance then best, bestDistance = f, distance end
    end
    return best
end

-- Follow the window: a new top layer gets the highlight on its element from before (still
-- shown) or its first one; a highlighted element gone (page refreshed, row hidden) passes it to
-- the nearest one shown. Returns true when the highlight moved.
local function Sync()
    local top = Gamepad.ActiveLayer()
    if top ~= layer then
        if focus then Focus(nil) end
        layer = top
        local frames = layer and Gamepad.Collect(layer) or {}
        local before = remembered[layer]
        Focus(before and Find(frames, before) and before or frames[1])
        return true
    end
    if not layer then return false end
    local frames, rects = Gamepad.Collect(layer)
    if focus and rects[focus] then
        focusRect = rects[focus]
        return false
    end
    local nearest = focusRect and Closest(focusRect, frames, rects) or frames[1]
    if nearest == focus then return false end
    Focus(nearest)
    return true
end

-- A text box of La Taverne has the keyboard.
local function TypingIn()
    local box = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    local f = box
    while f do
        if f == mainFrame or f == layer then return box end
        f = f:GetParent()
    end
end

local function Move(dir)
    local typing = TypingIn()
    if typing then typing:ClearFocus() end
    if not focus then return end
    local frames, rects = Gamepad.Collect(layer)
    local list = {}
    for i, f in ipairs(frames) do list[i] = rects[f] end
    local i = Gamepad.Nearest(rects[focus] or focusRect, list, dir)
    if i then Focus(frames[i]) end
end

-- A: like a click. A greyed button does nothing (its tooltip says why); a tooltip spot neither.
local function Activate(f)
    if f:IsObjectType("EditBox") then
        f:SetFocus()
    elseif f:IsObjectType("Button") then
        if f:IsEnabled() then f:Click("LeftButton") end
    else
        local down, up = Script(f, "OnMouseDown"), Script(f, "OnMouseUp")
        if down then down(f, "LeftButton") end
        if up then up(f, "LeftButton") end
    end
end

-- Y: one step back. Leaves a text box, else closes the top layer, else the window.
local function Back()
    local typing = TypingIn()
    if typing then
        typing:ClearFocus()
    elseif layer and not (ns.UI and ns.UI.CurrentPanel and layer == ns.UI:CurrentPanel()) then
        layer:Hide()
    else
        mainFrame:Hide()
    end
end

local ACTIONS = {
    PADDUP = function() Move("UP") end,
    PADDDOWN = function() Move("DOWN") end,
    PADDLEFT = function() Move("LEFT") end,
    PADDRIGHT = function() Move("RIGHT") end,
    PAD1 = Use,
    PAD4 = Back,
}

-- A press that only found the highlight a new place (the element gone or out of view, or a
-- layer that opened on its own since the last press) does nothing else: A never clicks what the
-- player hasn't seen highlighted.
local LANDING = { PADDUP = true, PADDDOWN = true, PADDLEFT = true, PADDRIGHT = true, PAD1 = true }
local active = false -- navigating (in a fight, the game may keep the bindings a while longer)
local landed = false -- the follow-up moved the highlight to a layer that opened on its own

function Gamepad.OnButton(key)
    if not active then return end
    if not Gamepad.CanTake() then Gamepad.Release() return end
    local moved = Sync(true)
    if LANDING[key] and (moved or landed) then
        landed = false
        return
    end
    landed = false
    local action = ACTIONS[key]
    if action then action() end
    if active then Sync() end
end

local elapsed = 0
local function OnUpdate(_, delta)
    elapsed = elapsed + delta
    if elapsed < 0.1 then return end
    elapsed = 0
    Sync()
end

local function Start()
    layer, focus, focusRect, remembered = nil, nil, nil, {}
    owner:SetScript("OnUpdate", OnUpdate)
    Sync()
end

local function Stop()
    owner:SetScript("OnUpdate", nil)
    Focus(nil)
    layer, focusRect = nil, nil
end

for _, key in ipairs(Gamepad.KEYS) do
    local button = CreateFrame("Button", "LaTavernePad" .. key, UIParent)
    button:Hide()
    button:SetScript("OnClick", function() Gamepad.OnButton(key) end)
end

local function Bind(on)
    -- Navigation stops at once, even when the game keeps the bindings until a fight ends.
    if not on and active then Stop() end
    if InCombatLockdown() then
        -- The game refuses binding changes in combat: giving them back waits for its end.
        pendingClear = pendingClear or (bound and not on)
        return
    end
    if on then
        if not bound then
            for _, key in ipairs(Gamepad.KEYS) do
                SetOverrideBindingClick(owner, true, key, "LaTavernePad" .. key)
            end
            bound = true
        end
        pendingClear = false
        if not active then Start() end
        return
    elseif bound or pendingClear then
        ClearOverrideBindings(owner)
        bound = false
    end
    pendingClear = false
end

function Gamepad.Release()
    Bind(false)
end

-- The pad drives La Taverne right now.
function Gamepad.IsActive()
    return active
end

-- Only while the window can be seen (not with the whole interface hidden), with the gamepad UI
-- on, out of a fight.
function Gamepad.CanTake()
    return mainFrame ~= nil and mainFrame:IsVisible() and not fighting and ns.GamepadUI()
end

local function Take()
    if Gamepad.CanTake() then Bind(true) end
end

-- The main window (UI.lua): its buttons follow it.
function Gamepad.Attach(frame)
    mainFrame = frame
    frame:HookScript("OnShow", Take)
    frame:HookScript("OnHide", function() Bind(false) end)
end

ns.On("PLAYER_REGEN_DISABLED", function()
    fighting = true
    Bind(false)
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    fighting = false
    if pendingClear then Bind(false) end
    Take()
end)
