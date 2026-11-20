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

-- The nearest rectangle whose center lies in that direction ("UP", "DOWN", "LEFT", "RIGHT"):
-- within a cone around it, the distance along the direction plus twice the distance off its
-- axis, the smallest wins. nil: nothing that way.
function Gamepad.Nearest(from, rects, dir)
    local fx, fy = Center(from)
    local best, bestScore
    for i, r in ipairs(rects) do
        local x, y = Center(r)
        local along, across
        if dir == "UP" then along, across = y - fy, x - fx
        elseif dir == "DOWN" then along, across = fy - y, x - fx
        elseif dir == "RIGHT" then along, across = x - fx, y - fy
        else along, across = fx - x, y - fy end
        across = math.abs(across)
        if along > 1 and across <= 2 * along then
            local score = along + 2 * across
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
