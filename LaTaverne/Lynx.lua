local _, ns = ...

-- The lynx in the band at the top of the window, beside the portrait: a 32 px pixel-art lynx
-- that lives in the right third of the band. It sits most of the time, now and then turns its
-- head to look at you or licks a paw, and sometimes walks to another spot. It only runs while
-- the window is open (the OnUpdate belongs to a child of the window).
--
-- media/lynx_sprites.tga: 256 x 128, cells of 32 x 32 in rows of 6 (only these are used):
--   row 0 walk:  2 legs apart, 4 legs crossed (a two-pose walk with a 1 px bounce)
--   row 1 sit:   1 standing, 2 lowering, 3 almost seated (sitting down; reversed to get up)
--   row 2 look:  1 sitting in profile (the resting pose), 2 three-quarters, 3 facing you
--   row 3 idle:  5 and 6 licking a paw
-- Every cell is drawn facing right; walking left mirrors it.

local Lynx = {}
ns.Lynx = Lynx

local TEXTURE = "Interface\\AddOns\\LaTaverne\\media\\lynx_sprites"
local CELL, SHEET_W, SHEET_H = 32, 256, 128

local SEAT = { 2, 0 }                        -- { row, column }
local LEGS_APART, LEGS_CROSSED = { 0, 1 }, { 0, 3 }
local SIT_DOWN = { { 1, 0 }, { 1, 1 }, { 1, 2 } }
local LOOK_34, LOOK_FRONT = { 2, 1 }, { 2, 2 }
local LICK_A, LICK_B = { 3, 4 }, { 3, 5 }

local STEP = 0.15        -- seconds per walking tick (a pose is held two ticks)
local SPEED = 12         -- pixels per second while walking
local MIN_WALK = 40      -- a walk goes at least this far

-- Seconds sitting still between two things. The Debug tab's "short pauses" divides them, not
-- the animations themselves.
local REST_MIN, REST_MAX = 15, 45
local FAST_DIVIDE = 12

local holder, tex
local x, facingLeft = nil, true
local queue, timer = {}, 0        -- poses still to show: { cell, seconds, lift }
local walking                     -- { target, t } while walking

local function Show(cell, lift)
    local left = cell[2] * CELL / SHEET_W
    local right = (cell[2] + 1) * CELL / SHEET_W
    local top = cell[1] * CELL / SHEET_H
    local bottom = (cell[1] + 1) * CELL / SHEET_H
    if facingLeft then left, right = right, left end
    tex:SetTexCoord(left, right, top, bottom)
    tex:ClearAllPoints()
    tex:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", math.floor(x + 0.5), 1 + (lift or 0))
end

local function Add(cell, seconds, lift)
    queue[#queue + 1] = { cell, seconds, lift }
end

local function Range()
    local width = holder:GetWidth() or 0
    return math.floor(width * 2 / 3), math.floor(width - CELL - 6)
end

local function Rest()
    local fast = ns.db and ns.db.dev and ns.db.dev.lynxFast
    local seconds = REST_MIN + math.random() * (REST_MAX - REST_MIN)
    Add(SEAT, fast and seconds / FAST_DIVIDE or seconds)
end

local function LookAround()
    Add(LOOK_34, 0.25)
    Add(LOOK_FRONT, 1.5 + math.random() * 1.5) -- looks at you
    Add(LOOK_34, 0.25)
    Add(SEAT, 0.25)
end

local function Lick()
    for _ = 1, math.random(2, 4) do
        Add(LICK_A, 0.22)
        Add(LICK_B, 0.22)
    end
    Add(SEAT, 0.25)
end

local function StartWalk()
    local lo, hi = Range()
    if hi - lo < MIN_WALK * 2 then return false end
    local target
    for _ = 1, 20 do
        target = math.random(lo, hi)
        if math.abs(target - x) >= MIN_WALK then break end
    end
    if math.abs(target - x) < MIN_WALK then return false end
    facingLeft = target < x
    for i = 3, 1, -1 do Add(SIT_DOWN[i], 0.14) end -- gets up
    queue[#queue + 1] = { walk = target }
    return true
end

local function SitDown()
    for i = 1, 3 do Add(SIT_DOWN[i], 0.14) end
    Add(SEAT, 0.14)
end

-- After each rest: a head turn or a paw lick more often than a walk. A walk ends with sitting
-- down and a rest (OnUpdate, on arrival).
local function Next()
    local roll = math.random()
    if roll >= 0.75 and StartWalk() then return end
    if roll < 0.45 then LookAround() else Lick() end
    Rest()
end

local WALK_POSES = { { LEGS_APART, 0 }, { LEGS_APART, 1 }, { LEGS_CROSSED, 0 }, { LEGS_CROSSED, 1 } }

local function OnUpdate(_, elapsed)
    if walking then
        walking.t = walking.t + elapsed
        local dir = walking.target < x and -1 or 1
        x = x + dir * SPEED * elapsed
        if (dir < 0 and x <= walking.target) or (dir > 0 and x >= walking.target) then
            x = walking.target
            walking = nil
            SitDown()
            Rest()
        else
            local pose = WALK_POSES[math.floor(walking.t / STEP) % 4 + 1]
            Show(pose[1], pose[2])
        end
        return
    end
    timer = timer - elapsed
    if timer > 0 then return end
    local step = table.remove(queue, 1)
    if not step then
        Next()
        return
    end
    if step.walk then
        walking = { target = step.walk, t = 0 }
        return
    end
    Show(step[1], step[3])
    timer = step[2]
end

local function Enabled() return not ns.db or ns.db.lynx ~= false end

-- Options: the lynx on or off (on by default).
function Lynx:SetEnabled(on)
    ns.db.lynx = on and true or false
    if holder then holder:SetShown(on and true or false) end
end

-- The Debug tab's switch: shorten the rest going on now too.
function Lynx:SetFast(on)
    if ns.db and ns.db.dev then ns.db.dev.lynxFast = on and true or false end
    if on and timer > 3 then timer = 1 end
end

-- Called once by the main window. anchor: the pages' frame; the lynx walks on its top edge.
function Lynx:Attach(frame, anchor)
    if holder then return end
    holder = CreateFrame("Frame", nil, frame)
    holder:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 0)
    holder:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 0)
    holder:SetHeight(CELL + 4)
    holder:EnableMouse(false)
    tex = holder:CreateTexture(nil, "ARTWORK")
    tex:SetSize(CELL, CELL)
    tex:SetTexture(TEXTURE, "CLAMP", "CLAMP", "NEAREST") -- sharp pixels
    if tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(true)
        tex:SetTexelSnappingBias(0)
    end
    tex:Hide()
    holder:SetShown(Enabled())
    holder:SetScript("OnUpdate", function(self, elapsed)
        if not x then
            -- First time the window is laid out: sitting in the right corner, facing the window.
            local _, hi = Range()
            if hi <= 0 then return end
            x, facingLeft = hi, true
            Show(SEAT)
            tex:Show()
            Rest()
            return
        end
        OnUpdate(self, elapsed)
    end)
end
