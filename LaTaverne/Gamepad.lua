-- La Taverne with a gamepad, when the game's gamepad UI is on. The window's elements are found
-- on their own: anything the mouse can hover or click (buttons, checkboxes, text boxes, list
-- rows, tooltip spots). The d-pad moves a highlight to the nearest one in that direction.
-- Not the game's gamepad navigation: registering an addon window with the gamepad manager makes
-- its protected calls run from addon code (ADDON_ACTION_FORBIDDEN).
local ADDON, ns = ...
local L = ns.L

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
-- within a cone around it or in the same column / row (a wide list row under a small button).
-- Distance: the gap between the edges along the direction, plus twice
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
        if along > 1 and (gapAcross == 0 or across <= 2 * along) then
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

-- A list with more than it shows. Not a text box's own scroll frame.
local function CanScroll(f)
    if IsScrollBox(f) then return f.HasScrollableExtent ~= nil and f:HasScrollableExtent() end
    local child = f:GetScrollChild()
    return not (child and child:IsObjectType("EditBox")) and (f:GetVerticalScrollRange() or 0) > 0
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
            local before = #frames
            Walk(child, (r and IsScroller(child)) and Intersect(clip, r) or clip, frames, rects)
            -- A list with nothing to click in it (text rows): the list itself, so it can scroll.
            if r and IsScroller(child) and #frames == before and CanScroll(child) and Contains(clip, Center(r)) then
                frames[#frames + 1] = child
                rects[child] = r
            end
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
local mainFrame, hints
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
-- The first-press guard: set only where the highlight jumps (new top layer, element gone or out
-- of view). Found by the follow-up or at the start of a press, the jump arms it: the next d-pad
-- or A press only confirms the highlight. Caused by the press's own action (A opened a menu, Y
-- closed a window), it disarms it: the player expects the new place.
local armed = false

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

-- The data a list row shows (ScrollBox rows), for an element or the row it's in.
local function DataOf(f)
    while f and f ~= layer do
        if f.GetElementData then return f:GetElementData() end
        f = f:GetParent()
    end
end

-- again: the same frame shows other data (a list row reused after scrolling).
local function Focus(f, again)
    if f == focus and not again then return end
    if focus then
        local leave = Script(focus, "OnLeave")
        if leave then leave(focus) end
    end
    focus = f
    -- Leaving a layer keeps what it had: back from a menu, the highlight is where it was.
    if layer and f then remembered[layer] = f end
    if not f then
        highlight:Hide()
        return
    end
    focusRect, focusData = Rect(f), DataOf(f)
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

local function InList(f)
    local p = f:GetParent()
    while p and p ~= layer do
        if IsScroller(p) then return true end
        p = p:GetParent()
    end
    return false
end

-- Follow the window: a new top layer gets the highlight on its element from before (still
-- shown) or its first one; a highlighted element gone (page refreshed, row hidden) passes it to
-- the nearest one shown. full: also check it's still among the elements in view (each press: a
-- list scrolled with the mouse leaves it shown but out of its box). byPlayer: what changed was
-- caused by the press's own action.
local function FollowLayer(full, byPlayer)
    local function Jumped()
        armed = not byPlayer
    end
    local top = Gamepad.ActiveLayer()
    if top ~= layer then
        layer = top
        local frames = layer and Gamepad.Collect(layer) or {}
        local before = remembered[layer]
        Focus(before and Find(frames, before) and before or frames[1])
        Jumped()
        return
    end
    if not layer then return end
    -- Still shown, out of any list: nothing to look for (the window is walked only when needed).
    if focus and not full and focus:IsVisible() and not InList(focus) then
        focusRect = Rect(focus) or focusRect
        -- A reused row now showing other data: its tooltip follows.
        if DataOf(focus) ~= focusData then Focus(focus, true) end
        return
    end
    local frames, rects = Gamepad.Collect(layer)
    if focus and rects[focus] then
        focusRect = rects[focus]
        if DataOf(focus) ~= focusData then Focus(focus, true) end
        return
    end
    local nearest = focusRect and Closest(focusRect, frames, rects) or frames[1]
    if nearest == focus then return end
    Focus(nearest)
    Jumped()
end

-- A text box of the top layer has the keyboard (not one under a window that opened on top).
local function TypingIn()
    local box = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    local f = box
    while f do
        if f == layer then return box end
        f = f:GetParent()
    end
end

-- A text box showing its suggestions (a list of its own under it, moved with the arrow keys:
-- the guild name boxes). The pad goes through them with the box's own keys.
local function Suggesting(box)
    if not (box and Script(box, "OnArrowPressed")) then return false end
    for _, child in ipairs({ box:GetChildren() }) do
        -- Its list, shown with at least one suggestion (not the highlight, put on the box).
        if child ~= highlight and child:IsVisible() then
            for _, row in ipairs({ child:GetChildren() }) do
                if row:IsVisible() then return true end
            end
        end
    end
    return false
end

-- Button hints under the window: the game's icons for the pad in use, else the button's name.
local icons = {}

local function Icon(key, name)
    local ok, atlas = pcall(function() return InputIconTextureSetUtility.GetNormalActiveInputIconButtonTexture(key) end)
    if ok and type(atlas) == "string" and atlas ~= "" then return "|A:" .. atlas .. ":20:20|a" end
    return "[" .. name .. "]"
end

local function OnPage()
    return ns.UI and ns.UI.CurrentPanel and layer == ns.UI:CurrentPanel()
end

local function ShowHints()
    if not hints then return end
    local page = OnPage()
    local back = (page and not TypingIn()) and L["Close"] or L["Back"]
    local text = icons.PAD1 .. " " .. L["Choose"] .. "     " .. icons.PAD4 .. " " .. back
        .. "     " .. icons.PADLSHOULDER .. icons.PADRSHOULDER .. " " .. L["Sections"]
    if hints.text:GetText() ~= text then hints.text:SetText(text) end
    hints:Show()
end

local function Sync(full, byPlayer)
    FollowLayer(full, byPlayer)
    ShowHints()
end

local function Inside(f, ancestor)
    f = f:GetParent()
    while f do
        if f == ancestor then return true end
        f = f:GetParent()
    end
    return false
end

-- The list the element scrolls in: a list of rows (ScrollBox) or a scrolling area (Options,
-- Setup). Not a text box's own scroll frame: up and down leave the text box.
local function ScrollerOf(f)
    local p = f:GetParent()
    while p and p ~= layer do
        if IsScrollBox(p) or (p:IsObjectType("ScrollFrame") and p:GetScrollChild() ~= f) then return p end
        p = p:GetParent()
    end
end

-- The nearest element of that list in view, that way.
local function NearestIn(scroller, from, dir)
    local frames, rects = Gamepad.Collect(layer)
    local list, map = {}, {}
    for _, f in ipairs(frames) do
        if f ~= focus and Inside(f, scroller) then
            list[#list + 1] = rects[f]
            map[#list] = f
        end
    end
    local i = Gamepad.Nearest(from, list, dir)
    return i and map[i]
end

-- Rows: scrolled one data row at a time, the highlight in the same column of the next row.
local function NextRow(box, dir)
    if box.HasDataProvider and not box:HasDataProvider() then return end
    local row, index = focus, nil
    while row and row ~= box do
        index = box:FindFrameElementDataIndex(row)
        if index then break end
        row = row:GetParent()
    end
    if not index then return end
    local x = Center(Rect(focus) or focusRect)
    local step = dir == "DOWN" and 1 or -1
    local i = index + step
    while box:FindElementData(i) do
        box:ScrollToNearest(i, 0, true)
        local target = box:FindFrame(box:FindElementData(i))
        if target then
            local frames, rects = Gamepad.Collect(layer)
            local best, bestDistance
            for _, f in ipairs(frames) do
                if f == target or Inside(f, target) then
                    local distance = math.abs(Center(rects[f]) - x)
                    if not bestDistance or distance < bestDistance then best, bestDistance = f, distance end
                end
            end
            if best then return best end
        end
        i = i + step
    end
end

-- A scrolling area: half its height at a time, until something shows up that way. Blizzard's
-- scroll frame caps the position to its bar, whose top is the range rounded down: a scroll that
-- did not move is the end.
local function NextInArea(scroll, dir)
    local range, step = scroll:GetVerticalScrollRange() or 0, math.max(20, (scroll:GetHeight() or 0) / 2)
    while true do
        local current = scroll:GetVerticalScroll()
        local target = dir == "DOWN" and math.min(current + step, range) or math.max(current - step, 0)
        if target == current then return end
        scroll:SetVerticalScroll(target)
        if math.abs(scroll:GetVerticalScroll() - current) < 1 then return end
        local found = NearestIn(scroll, Rect(focus) or focusRect, dir)
        if found then return found end
    end
end

-- A list that is itself the stop (nothing to click in it): a row (ScrollBox) or half its
-- height at a time. false at its end.
local function ScrollList(list, dir)
    if IsScrollBox(list) then
        if (dir == "DOWN" and list:IsAtEnd()) or (dir == "UP" and list:IsAtBegin()) then return false end
        local step = list:CalculatePanExtentPercentage()
        if not step or step <= 0 then step = 0.1 end
        local target = list:GetScrollPercentage() + (dir == "DOWN" and step or -step)
        list:SetScrollPercentage(math.max(0, math.min(1, target)), true)
        return true
    end
    local current, range = list:GetVerticalScroll(), list:GetVerticalScrollRange() or 0
    local step = math.max(20, (list:GetHeight() or 0) / 2)
    local target = dir == "DOWN" and math.min(current + step, range) or math.max(current - step, 0)
    if target == current then return false end
    list:SetVerticalScroll(target)
    return math.abs(list:GetVerticalScroll() - current) >= 1
end

local function Move(dir)
    local typing = TypingIn()
    local vertical = dir == "UP" or dir == "DOWN"
    if vertical and Suggesting(typing) then
        Script(typing, "OnArrowPressed")(typing, dir)
        return
    end
    if typing then typing:ClearFocus() end
    if not focus then return end
    if vertical and IsScroller(focus) and ScrollList(focus, dir) then return end
    -- In a list: its next element, scrolled into view; past its end, on to the rest of the page.
    local scroller = (dir == "UP" or dir == "DOWN") and ScrollerOf(focus)
    if scroller then
        local found = NearestIn(scroller, Rect(focus) or focusRect, dir)
        if found then Focus(found) return end
        if IsScrollBox(scroller) then found = NextRow(scroller, dir) else found = NextInArea(scroller, dir) end
        if found then Focus(found, true) return end
    end
    local frames, rects = Gamepad.Collect(layer)
    local list = {}
    for i, f in ipairs(frames) do list[i] = rects[f] end
    local i = Gamepad.Nearest(rects[focus] or Rect(focus) or focusRect, list, dir)
    if i then Focus(frames[i]) end
end

-- A: like a click. A greyed button does nothing (its tooltip says why); a tooltip spot neither.
-- A protected frame neither: clicked from addon code, its secure action is refused. A reaches it
-- through PAD1 bound to it (see AimA).
local function Activate(f)
    if f:IsProtected() then return end
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
    elseif layer and not OnPage() then
        layer:Hide()
    else
        mainFrame:Hide()
    end
end

-- LB / RB: on the page only (a menu or a window on top waits for its answer).
local function Section(delta)
    if OnPage() then ns.UI:CycleSection(delta) end
end

-- A: in a box showing suggestions, its Enter (picks the selected one); else a click.
local function Use()
    local typing = TypingIn()
    local enter = Suggesting(typing) and Script(typing, "OnEnterPressed")
    if enter then
        enter(typing)
    elseif focus then
        Activate(focus)
    end
end

local ACTIONS = {
    PADLSHOULDER = function() Section(-1) end,
    PADRSHOULDER = function() Section(1) end,
    PADDUP = function() Move("UP") end,
    PADDDOWN = function() Move("DOWN") end,
    PADDLEFT = function() Move("LEFT") end,
    PADDRIGHT = function() Move("RIGHT") end,
    PAD1 = Use,
    PAD4 = Back,
}

-- Armed (see armed), a d-pad or A press only confirms the highlight: A never clicks what the
-- player hasn't seen highlighted. Y, LB and RB act as usual and don't lift the guard by
-- themselves; only the layer change their action causes does (Y closing the window on top).
local LANDING = { PADDUP = true, PADDDOWN = true, PADDLEFT = true, PADDRIGHT = true, PAD1 = true }
local active = false -- navigating (in a fight, the game may keep the bindings a while longer)
-- The highlight's first place after the window opened is set (see Start).
local placed = false
local opened = 0 -- counts the openings: a late first placement never lands on a newer one

-- What PAD1 clicks: the hidden LaTavernePadPAD1, or the highlighted protected frame itself (the
-- test mode's Reload button): a press of the pad is then the player's own click, which a secure
-- action needs. Only with the buttons taken, out of combat, the guard down, on a named frame.
local padA -- the button PAD1 is bound to now (nil: not bound)

local function AimA()
    if not bound or InCombatLockdown() then return end
    local target = "LaTavernePadPAD1"
    if not armed and focus and focus:IsProtected() and focus:GetName() then target = focus:GetName() end
    if target ~= padA then
        SetOverrideBindingClick(owner, true, "PAD1", target, "LeftButton")
        padA = target
    end
end

-- The first place after the player opened the window: the player's (disarms).
local function Place()
    placed = true
    Sync(false, true)
end

function Gamepad.OnButton(key)
    if not active then return end
    if not Gamepad.CanTake() then Gamepad.Release() return end
    if placed then Sync(true) else Place() end
    if armed and LANDING[key] then
        armed = false
        AimA()
        return
    end
    local action = ACTIONS[key]
    if action then action() end
    if active then Sync(false, true) end
    AimA()
end

local elapsed = 0
local function OnUpdate(_, delta)
    elapsed = elapsed + delta
    if elapsed < 0.1 then return end
    elapsed = 0
    -- Window hidden, gamepad UI turned off: the buttons go back at once.
    if not Gamepad.CanTake() then Gamepad.Release() return end
    if placed then Sync() else Place() end
    AimA()
end

-- cause: "open", the player showed the window: its first place is set once the code that opened
-- it has picked its page (next frame; a press before sets it itself), as the player's. "resume",
-- anything else (end of a fight, the interface shown again): the first place arms the guard, a
-- window may have opened on its own meanwhile.
local function Start(cause)
    active, armed, placed = true, false, false
    layer, focus, focusRect, focusData, remembered = nil, nil, nil, nil, {}
    icons = { PAD1 = Icon("PAD1", "A"), PAD4 = Icon("PAD4", "Y"),
        PADLSHOULDER = Icon("PADLSHOULDER", "LB"), PADRSHOULDER = Icon("PADRSHOULDER", "RB") }
    elapsed = 0
    owner:SetScript("OnUpdate", OnUpdate)
    if cause == "open" then
        opened = opened + 1
        local this = opened
        local nextFrame = RunNextFrame or function(fn) C_Timer.After(0, fn) end
        nextFrame(function()
            if active and not placed and this == opened then Place() end
        end)
    else
        placed = true
        Sync()
    end
end

local function Stop()
    active, armed = false, false
    owner:SetScript("OnUpdate", nil)
    Focus(nil)
    layer, focusRect, focusData = nil, nil, nil
    if hints then hints:Hide() end
end

for _, key in ipairs(Gamepad.KEYS) do
    local button = CreateFrame("Button", "LaTavernePad" .. key, UIParent)
    button:Hide()
    button:SetScript("OnClick", function() Gamepad.OnButton(key) end)
end

local function Bind(on, cause)
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
            bound, padA = true, "LaTavernePadPAD1"
        end
        pendingClear = false
        if not active then Start(cause) end
        return
    elseif bound or pendingClear then
        ClearOverrideBindings(owner)
        bound, padA = false, nil
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

local function Take(cause)
    if Gamepad.CanTake() then Bind(true, cause) end
end

-- The main window (UI.lua): its buttons follow it.
function Gamepad.Attach(frame)
    mainFrame = frame
    -- The hints line, under the window's bottom edge: nothing on the pages moves.
    hints = CreateFrame("Frame", "LaTavernePadHints", frame, "BackdropTemplate")
    hints:SetHeight(28)
    hints:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
    hints:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -2)
    if hints.SetBackdrop then
        hints:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        hints:SetBackdropColor(0, 0, 0, 0.8)
        hints:SetBackdropBorderColor(0.75, 0.6, 0.2, 1)
    end
    hints.text = hints:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hints.text:SetPoint("CENTER")
    hints:Hide()
    -- Shown by the player, or again with the whole interface (hidden with it: still IsShown).
    local hiddenWithParent = false
    frame:HookScript("OnShow", function() Take(hiddenWithParent and "resume" or "open") end)
    frame:HookScript("OnHide", function()
        hiddenWithParent = frame:IsShown()
        Bind(false)
    end)
end

ns.On("PLAYER_REGEN_DISABLED", function()
    fighting = true
    Bind(false)
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    fighting = false
    if pendingClear then Bind(false) end
    Take("resume")
end)

-- The gamepad UI turned back on (InputUtil.lua listens to the same event) with the window open:
-- a resume. Turned off, the follow-up gives the buttons back.
ns.On("INPUT_DEVICE_INTERFACE_TRANSITION", function()
    Take("resume")
end)
