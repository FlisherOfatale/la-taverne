-- Guild and allied players on the world map.
--
-- Sharing (Options, on by default): every few seconds my place (a uiMapID and x, y on it) goes to
-- my guild (guild scope) and to the allied guilds (alliance channel), as hidden messages only
-- La Taverne reads. Every TICK while I move, every STILL_EVERY while I stand still, never from a
-- dungeon, raid or battleground ("off" then, and when sharing is turned off). Positions are never
-- queued: when the channel isn't ready, the next one goes instead.
-- Showing (Options: guild members, allied guilds): a class-coloured dot where each one stands,
-- on the game's world map, through its own map pin system (a data provider). With OpenMap's
-- stitched map, the dots are placed through OpenMap's public API (OpenMapAPI.WorldFromMap and
-- MapFromWorld), so they show from neighbouring zones and at any zoom too. Nothing else of
-- OpenMap's is used, except reading its saved "share" switches to avoid a second dot where
-- OpenMap already draws the same player (both share through it).
-- My party or raid is left to the game's own dots. A dot goes after GONE_AFTER without news.
local ADDON, ns = ...
local AllyMap = ns.NewModule("AllyMap")
local L = ns.L

local TICK = 2          -- seconds between looks at where I am
local SEND_EVERY = 10   -- seconds between places sent while I move (OpenMap's pace; dots glide in between)
local STILL_EVERY = 60  -- ... and while I stand still (a dot that's heard from stays)
local SLACK = 0.5       -- (timers aren't exact: 4.99 s is 5 s)
local GONE_AFTER = 150  -- seconds without news before a dot goes
local PRUNE_EVERY = 10  -- seconds between looks for dots gone stale
local MOVED = 0.002     -- a move this small on a zone's map isn't one
local DOT_SIZE = 14
local GLIDE = SEND_EVERY -- seconds a dot takes to slide to its new place
local JUMP = 0.1        -- a move this big on the shown map (a flight, a portal): placed at once, no slide
local FULL_EVERY = 60   -- seconds between messages that also carry class, level and character ID
local PIN = "LaTaverneAllyMapPin"
local TAG_COLOR = { 0.56, 0.72, 0.91 } -- allied guild ring (the tag's colour in allied chat)

AllyMap.stats = { sent = 0, offSent = 0, received = 0, rejected = 0, expired = 0, drawn = 0, skippedOpenMap = 0 }

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

local function Settings()
    return ns.db.allyMap
end

-- OpenMap ----------------------------------------------------------------------------------

-- OpenMap's account settings (its "worldmap" module), read only; nil without OpenMap.
local function OpenMapSettings()
    if not OpenMapAPI then return nil end
    local db = type(OpenMapDB) == "table" and OpenMapDB.worldmap
    return type(db) == "table" and db or nil
end

local function OpenMapStitched()
    if not (OpenMapAPI and OpenMapAPI.IsStitched) then return false end
    local ok, on = pcall(OpenMapAPI.IsStitched)
    return ok and on and true or false
end

-- OpenMap here, for Options: "on" (loaded, its map on), "off" (loaded, its map turned off in
-- its options), nil (not loaded).
function AllyMap:OpenMapState()
    if not OpenMapAPI then return nil end
    local db = OpenMapSettings()
    return (db and db.enabled == false) and "off" or "on"
end

-- Is my own OpenMap sharing my place too (to my guild and my friends who use it)?
local function OpenMapShares()
    local db = OpenMapSettings()
    return db and db.friendsShare == true or false
end

-- Where I am --------------------------------------------------------------------------------

local function InInstance()
    if not IsInInstance then return false end
    local inside = IsInInstance()
    if IsSecret(inside) then return true end
    return inside and true or false
end

local function XY(pos)
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and pos.GetXY then x, y = pos:GetXY() end
    if IsSecret(x) or IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

-- My place: a uiMapID and x, y on it (0..1); nil in an instance, or when the game won't say.
local function Here()
    if InInstance() or not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or IsSecret(mapID) or type(mapID) ~= "number" then return nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok2 then return nil end
    local x, y = XY(pos)
    if not x or (x <= 0 and y <= 0) or x > 1 or y > 1 then return nil end -- (0, 0: the game doesn't know)
    return mapID, x, y
end
AllyMap.Here = Here

-- Sending -----------------------------------------------------------------------------------

-- Small: the place as one short text, "map x y" (x and y in 1/10000 of the map), then " 1" when
-- my OpenMap shares my place too (in every message, so nobody draws a second dot over
-- OpenMap's). Class, level and character ID don't change while I walk: only in a full one (the
-- first, then once a minute); receivers keep them from the last full one.
local function MyPayload(m, x, y, full)
    local payload = { p = format("%d %d %d%s", m, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5),
        OpenMapShares() and " 1" or "") }
    if full then
        local _, class = UnitClass("player")
        local level = UnitLevel("player")
        local guid = UnitGUID("player")
        payload.c = (not IsSecret(class) and type(class) == "string") and class or nil
        payload.l = (not IsSecret(level) and type(level) == "number") and level or nil
        payload.id = (not IsSecret(guid) and type(guid) == "string") and guid or nil
    end
    return payload
end

-- One message for everyone: with a Guild Alliance, on the alliance channel only (my own guild
-- reads it there too, Comm lets my guild's positions through); without one, on the guild channel.
-- If the alliance channel isn't ready yet, the guild channel. Never queued. True if it went.
local function Broadcast(make, priority)
    if ns.Alliance:IsActive() and ns.Comm:SendAlly("POS", make(), priority, true) then return true end
    return ns.Guild:InGuild() and ns.Comm:Send("POS", make(), priority, true) or false
end

local last = { at = -math.huge, full = -math.huge } -- my place as last sent: m, x, y, at; full: last full one
local sharing = false            -- a place went out since sharing (re)started: "off" is owed when it stops

local function Tick()
    if not ns.db or not ns.Comm:IsLoggedIn() then return end
    if not Settings().share or InInstance() then
        -- "off" is owed until it goes out (a channel not ready: tried again next tick).
        if sharing and Broadcast(function() return { off = true } end, "NORMAL") then
            sharing = false
            last.m, last.at, last.full = nil, -math.huge, -math.huge
            AllyMap.stats.offSent = AllyMap.stats.offSent + 1
        end
        return
    end
    -- Nothing goes out before the player was told it's shared (the notice, OnLogin).
    if not Settings().told then return end
    local m, x, y = Here()
    if not m then return end
    local moved = m ~= last.m or math.abs(x - last.x) > MOVED or math.abs(y - last.y) > MOVED
    if GetTime() - last.at < (moved and SEND_EVERY or STILL_EVERY) - SLACK then return end
    local full = GetTime() - last.full >= FULL_EVERY - SLACK
    if Broadcast(function() return MyPayload(m, x, y, full) end, "BULK") then
        last.m, last.x, last.y, last.at = m, x, y, GetTime()
        if full then last.full = GetTime() end
        sharing = true
        AllyMap.stats.sent = AllyMap.stats.sent + 1
    end
end

-- Who's where -------------------------------------------------------------------------------

-- [nameKey] = { key, name, scope ("guild" | "ally"), guild, tag, m, x, y, c, l, guid, om, at }
local live = {}

local function InMyGroup(e)
    if not IsInGroup() then return false end
    local raid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if e.guid and not IsSecret(guid) and guid == e.guid then return true end
            local name = ns.FullName(unit)
            if name and not IsSecret(name) and ns.NameKey(name) == e.key then return true end
        end
    end
    return false
end

-- On my friends list, or a Battle.net friend (what OpenMap shares to besides the guild).
local function IsFriend(e)
    if e.guid then
        if C_FriendList and C_FriendList.IsFriend then
            local ok, yes = pcall(C_FriendList.IsFriend, e.guid)
            if ok and yes and not IsSecret(yes) then return true end
        end
        if C_BattleNet and C_BattleNet.GetAccountInfoByGUID then
            local ok, info = pcall(C_BattleNet.GetAccountInfoByGUID, e.guid)
            if ok and info and not IsSecret(info) then return true end
        end
    end
    if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
        for i = 1, C_FriendList.GetNumFriends() or 0 do
            local f = C_FriendList.GetFriendInfoByIndex(i)
            if f and type(f.name) == "string" and not IsSecret(f.name) and ns.NameKey(f.name) == e.key then return true end
        end
    end
    return false
end

-- OpenMap already draws this one itself (they share through it, and my OpenMap shows them):
-- a dot of ours would be a second one on top.
local function OpenMapDraws(e)
    if not e.om or not OpenMapStitched() then return false end
    local db = OpenMapSettings()
    if not db then return false end
    if e.scope == "guild" then return db.guild ~= false end
    return db.friends ~= false and IsFriend(e)
end

-- OpenMap's map is on and its own "Guild members on the map" is off: the player doesn't want
-- guild dots there, so ours hide too (instead of taking the place of OpenMap's), the allied
-- guilds' as well (they count as the guild, here as everywhere in La Taverne).
local function OpenMapHidesGuild()
    if not OpenMapStitched() then return false end
    local db = OpenMapSettings()
    return db ~= nil and db.guild == false
end

-- Whether a dot of ours shows for this one; false and "openmap" when OpenMap draws them already
-- (or OpenMap's guild switch is off).
local function Visible(e)
    local s = Settings()
    if e.scope == "guild" and not s.showGuild then return false end
    if e.scope == "ally" and not s.showAllies then return false end
    if OpenMapHidesGuild() then return false, "openmap" end
    if GetTime() - e.at > GONE_AFTER then return false end
    if InMyGroup(e) then return false end
    if OpenMapDraws(e) then return false, "openmap" end
    return true
end

-- Placing a dot on the map shown -----------------------------------------------------------

local function WorldPos(m, x, y)
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
    if not ok or IsSecret(cont) or type(cont) ~= "number" or not world then return nil end
    return cont, world
end

-- The game's own map: through the world position, on a map of the same continent.
local function GamePosition(e, shown)
    local cont, world = WorldPos(e.m, e.x, e.y)
    if not cont or WorldPos(shown, 0.5, 0.5) ~= cont or not C_Map.GetMapPosFromWorldPos then return nil end
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, shown)
    if not ok then return nil end
    local x, y = XY(pos)
    if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
    return nil
end

-- Where a dot goes on the shown map's canvas (0..1 its own rectangle, past it on OpenMap's
-- stitched view, which shows beyond it); nil when it isn't on this map.
local function PinPosition(e, shown)
    if e.m == shown then return e.x, e.y end
    if OpenMapStitched() then
        local ok, u, v = pcall(OpenMapAPI.WorldFromMap, e.m, e.x, e.y)
        if ok and u then
            local ok2, x, y = pcall(OpenMapAPI.MapFromWorld, shown, u, v)
            if ok2 and x and x > -2 and x < 3 and y > -2 and y < 3 then return x, y end
            -- (OpenMap couldn't place it on this map: the game's own placement below)
        end
    end
    return GamePosition(e, shown)
end

-- Map pins ----------------------------------------------------------------------------------

local function ClassColor(class)
    local c = class and ((C_ClassColor and C_ClassColor.GetClassColor(class)) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]))
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function GuildColor()
    local info = ChatTypeInfo and ChatTypeInfo.GUILD
    if info then return info.r, info.g, info.b end
    return 0.25, 1, 0.25
end

-- OpenMap's stitched art can sit over the map's pins: a dot is lifted above it (not in
-- combat, where frame levels on the map are best left alone; lifted again as it ends).
local function HoverScripts(pin)
    if pin and not pin:GetScript("OnEnter") then
        pin:SetScript("OnEnter", pin.OnMouseEnter)
        pin:SetScript("OnLeave", pin.OnMouseLeave)
    end
end

local function Lift(pin)
    HoverScripts(pin)
    if not pin or not OpenMapStitched() or InCombatLockdown() or not OpenMapAPI.ArtTopLevel then return end
    local ok, top = pcall(OpenMapAPI.ArtTopLevel)
    if ok and type(top) == "number" and pin:GetFrameLevel() <= top then pin:SetFrameLevel(top + 2) end
end

local function ShowTooltip(pin)
    local e = pin.entry
    if not e then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.name, ClassColor(e.c))
    if e.scope == "ally" then
        GameTooltip:AddLine((e.tag and ("[" .. e.tag .. "] ") or "") .. (e.guild or ""), TAG_COLOR[1], TAG_COLOR[2], TAG_COLOR[3])
    else
        GameTooltip:AddLine(GUILD or "Guild", GuildColor())
    end
    if e.l and e.l > 0 then GameTooltip:AddLine(L["Level %d"]:format(e.l), 1, 1, 1) end
    local info = C_Map.GetMapInfo(e.m)
    GameTooltip:AddLine(("%s  %.1f, %.1f"):format(info and info.name or "?", e.x * 100, e.y * 100), 1, 1, 1)
    local ago = math.floor(GetTime() - e.at)
    if ago >= 20 then GameTooltip:AddLine(L["Updated %d s ago"]:format(ago), 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

local PinMixin = {}

function PinMixin:OnLoad()
    if self.dot then return end -- (already set up)
    if self.UseFrameLevelType then self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI") end
    if self.SetScalingLimits then self:SetScalingLimits(1, 1.0, 1.2) end
    self:SetSize(DOT_SIZE, DOT_SIZE)
    self.ring = self:CreateTexture(nil, "BORDER")
    self.ring:SetPoint("CENTER")
    self.ring:SetSize(DOT_SIZE, DOT_SIZE)
    self.dot = self:CreateTexture(nil, "ARTWORK")
    self.dot:SetPoint("CENTER")
    self.dot:SetSize(DOT_SIZE - 4, DOT_SIZE - 4)
    local atlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("WhiteCircle-RaidBlips")
    for _, tex in ipairs({ self.ring, self.dot }) do
        if atlas then
            tex:SetAtlas("WhiteCircle-RaidBlips")
        else
            tex:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask") -- (a white disc)
        end
    end
    self:EnableMouse(true)
    if self.SetMouseClickEnabled then self:SetMouseClickEnabled(false) end -- (clicks go to the map)
    -- No OnEnter/OnLeave here: the map asserts a new pin has none ("assertion failed!" in
    -- AcquirePin), then sets them itself from OnMouseEnter/OnMouseLeave below. HoverScripts
    -- adds them after AcquirePin on clients whose map doesn't.
end

function PinMixin:OnMouseEnter() ShowTooltip(self) end
function PinMixin:OnMouseLeave() GameTooltip:Hide() end

function PinMixin:Look()
    local e = self.entry
    self.dot:SetVertexColor(ClassColor(e.c))
    if e.scope == "ally" then
        self.ring:SetVertexColor(TAG_COLOR[1], TAG_COLOR[2], TAG_COLOR[3])
    else
        self.ring:SetVertexColor(GuildColor())
    end
end

-- Sliding to a new place over GLIDE seconds, so a dot moves smoothly between two messages.
local function GlideUpdate(self)
    local t = (GetTime() - self.glideStart) / GLIDE
    if t >= 1 then
        self:SetScript("OnUpdate", nil)
        self.curX, self.curY = self.toX, self.toY
    else
        self.curX = self.fromX + (self.toX - self.fromX) * t
        self.curY = self.fromY + (self.toY - self.fromY) * t
    end
    self:SetPosition(self.curX, self.curY)
end

function PinMixin:PlaceAt(x, y)
    self:SetScript("OnUpdate", nil)
    self.curX, self.curY = x, y
    self:SetPosition(x, y)
end

function PinMixin:MoveTo(x, y)
    if not self.curX or math.abs(x - self.curX) > JUMP or math.abs(y - self.curY) > JUMP then
        self:PlaceAt(x, y)
        return
    end
    self.fromX, self.fromY, self.toX, self.toY = self.curX, self.curY, x, y
    self.glideStart = GetTime()
    self:SetScript("OnUpdate", GlideUpdate)
end

function PinMixin:OnAcquired(entry, x, y)
    self.entry = entry
    self:PlaceAt(x, y)
    self:Look()
end

function PinMixin:OnReleased()
    self:SetScript("OnUpdate", nil)
    self.entry, self.curX, self.curY = nil, nil, nil
end

local provider = CreateFromMixins(MapCanvasDataProviderMixin)
local registered = false

function provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN)
end

function provider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    local shown = map:GetMapID()
    local count, openMap = 0, 0
    if shown then
        for _, e in pairs(live) do
            local show, why = Visible(e)
            if show then
                local x, y = PinPosition(e, shown)
                if x then
                    Lift(map:AcquirePin(PIN, e, x, y))
                    count = count + 1
                end
            elseif why == "openmap" then
                openMap = openMap + 1
            end
        end
    end
    -- (as of the last full redraw)
    AllyMap.stats.drawn, AllyMap.stats.skippedOpenMap = count, openMap
end

-- One player's dot, moved, added or taken off (a full refresh would close the tooltip under the mouse).
function provider:UpdateOne(e)
    local map = self:GetMap()
    local shown = map:GetMapID()
    local pin
    for p in map:EnumeratePinsByTemplate(PIN) do
        if p.entry and p.entry.key == e.key then pin = p break end
    end
    local x, y
    if shown and live[e.key] == e and Visible(e) then x, y = PinPosition(e, shown) end
    if not x then
        if pin then map:RemovePin(pin) end
    elseif pin then
        pin.entry = e
        pin:MoveTo(x, y)
        pin:Look()
        if GameTooltip:GetOwner() == pin then ShowTooltip(pin) end
    else
        Lift(map:AcquirePin(PIN, e, x, y))
    end
end

local function MapShown()
    return registered and WorldMapFrame and WorldMapFrame:IsShown()
end

local function Refresh()
    if MapShown() then provider:RefreshAllData() end
end
AllyMap.Refresh = Refresh

local function Register()
    if registered or not (WorldMapFrame and WorldMapFrame.AddDataProvider and WorldMapFrame.pinPools and MapCanvasPinMixin) then return end
    -- Our pin pool, as HereBeDragons does: pins made in code, not from an XML template.
    local pool = CreateUnsecuredRegionPoolInstance and CreateUnsecuredRegionPoolInstance(PIN) or CreateFramePool("FRAME")
    pool.parent = WorldMapFrame:GetCanvas()
    pool.createFunc = function()
        local frame = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
        frame:SetSize(1, 1)
        local pin = Mixin(frame, MapCanvasPinMixin, PinMixin)
        pin:OnLoad() -- (made in code: no XML template calls it)
        return pin
    end
    pool.resetFunc = function(_, pin)
        pin:Hide()
        pin:ClearAllPoints()
        pin:OnReleased()
        pin.pinTemplate = nil
        pin.owningMap = nil
    end
    pool.creationFunc, pool.resetterFunc = pool.createFunc, pool.resetFunc -- (older clients' names)
    WorldMapFrame.pinPools[PIN] = pool
    WorldMapFrame:AddDataProvider(provider)
    registered = true
end

-- Receiving ---------------------------------------------------------------------------------

-- A number between lo and hi (not NaN: every comparison with it is false).
local function Between(v, lo, hi)
    return type(v) == "number" and v >= lo and v <= hi
end

-- The place in a message: "map x y" or "map x y 1" (p: 1 = their OpenMap shares too), or m, x,
-- y and om (the first version). Fills p.m, p.x, p.y, p.om.
local function ReadPlace(p)
    if type(p.p) == "string" and #p.p <= 32 then
        local m, x, y, om = p.p:match("^(%d+) (%d+) (%d+)( ?1?)$")
        if not m then return false end
        p.m, p.x, p.y = tonumber(m), tonumber(x) / 10000, tonumber(y) / 10000
        p.om = om == " 1" or nil
    end
    return true
end

local function ValidPayload(p)
    if not ReadPlace(p) then return false end
    if not Between(p.m, 1, 1000000) or p.m ~= math.floor(p.m) then return false end
    if not Between(p.x, 0, 1) or not Between(p.y, 0, 1) then return false end
    if p.c ~= nil and (type(p.c) ~= "string" or #p.c > 20 or not p.c:match("^%u+$")) then return false end
    if p.l ~= nil and not Between(p.l, 0, 200) then return false end
    if p.id ~= nil and (type(p.id) ~= "string" or #p.id > 64 or not p.id:match("^Player%-")) then return false end
    local ok, info = pcall(C_Map.GetMapInfo, p.m)
    return ok and info ~= nil
end

local function OnPosition(sender, p, isSelf, scope)
    if isSelf or type(sender) ~= "string" or type(p) ~= "table" then return end
    local key = ns.NameKey(sender)
    if p.off then
        local e = live[key]
        if e then
            live[key] = nil
            if MapShown() then provider:UpdateOne(e) end
        end
        return
    end
    if not ValidPayload(p) then
        AllyMap.stats.rejected = AllyMap.stats.rejected + 1
        return
    end
    AllyMap.stats.received = AllyMap.stats.received + 1
    -- Class, level and ID only come in a full message: kept from the last one. Until
    -- one arrives, the class from the guild roster when it's a guildmate.
    local old = live[key]
    if p.c == nil then
        p.c = old and old.c
        if not p.c and scope == "guild" then
            local member = ns.Guild:GetMember(sender)
            p.c = member and member.class or nil
        end
    end
    if p.l == nil then p.l = old and old.l end
    if p.id == nil then p.id = old and old.guid end
    local e = {
        -- (the guild's name is checked allied by Comm; shown as text, no "|" codes)
        key = key, name = sender, scope = scope,
        guild = scope == "ally" and type(p.g) == "string" and p.g:gsub("|", "||") or nil,
        tag = scope == "ally" and (ns.Alliance:GetTag(p.g) or "?") or nil,
        m = p.m, x = p.x, y = p.y, c = p.c, l = p.l, guid = p.id, om = p.om == true, at = GetTime(),
    }
    live[key] = e
    if MapShown() then provider:UpdateOne(e) end
end

ns.Comm:On("POS", function(sender, p, isSelf) OnPosition(sender, p, isSelf, "guild") end)
ns.Comm:OnAlly("POS", function(sender, p, isSelf) OnPosition(sender, p, isSelf, "ally") end)

local function Prune()
    local now, gone = GetTime(), false
    for key, e in pairs(live) do
        if now - e.at > GONE_AFTER then
            live[key] = nil
            gone = true
            AllyMap.stats.expired = AllyMap.stats.expired + 1
        end
    end
    if gone then Refresh() end
end

-- Settings ----------------------------------------------------------------------------------

-- After a switch changed (Options, OpenMap's menu): sent or stopped now, dots redrawn.
function AllyMap:SettingsChanged()
    Tick()
    Refresh()
end

function AllyMap:SetShow(scope, on)
    local s = Settings()
    if scope == "guild" then s.showGuild = on and true or false else s.showAllies = on and true or false end
    self:SettingsChanged()
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function AllyMap:Count()
    local n = 0
    for _ in pairs(live) do n = n + 1 end
    return n
end

-- OpenMap's menu: the two "show" switches, under a "La Taverne" heading (its public API).
local openMapHooked = false
local function AddOpenMapToggles()
    if openMapHooked or not (OpenMapAPI and OpenMapAPI.RegisterMenuToggle) then return end
    openMapHooked = true
    pcall(OpenMapAPI.RegisterMenuToggle, "LaTaverne", {
        id = "guild", label = L["Guild members (La Taverne)"], section = "La Taverne",
        get = function() return Settings().showGuild end,
        set = function(v) AllyMap:SetShow("guild", v) end,
    })
    pcall(OpenMapAPI.RegisterMenuToggle, "LaTaverne", {
        id = "allies", label = L["Allied guilds (La Taverne)"], section = "La Taverne",
        get = function() return Settings().showAllies end,
        set = function(v) AllyMap:SetShow("ally", v) end,
    })
    if OpenMapAPI.RegisterCallback then
        pcall(OpenMapAPI.RegisterCallback, AllyMap, "OpenMap_StitchedChanged", function() Refresh() end)
    end
end

-- Before a reload that changes the guild (test mode on or off): "off" now, on the side I'm
-- leaving, so my dot goes away there instead of after GONE_AFTER.
function AllyMap:StopSharing()
    if sharing then
        Broadcast(function() return { off = true } end, "ALERT")
        sharing = false
    end
end

function AllyMap:OnLogin()
    Register()
    if not registered then
        ns.On("ADDON_LOADED", function(name)
            if name == "Blizzard_WorldMap" then Register() end
        end)
    end
    AddOpenMapToggles()
    ns.On("ADDON_LOADED", function(name)
        if name == "OpenMap" then AddOpenMapToggles() end
    end)
    ns.On("PLAYER_REGEN_ENABLED", Refresh)                -- (dots lifted over OpenMap's art again)
    ns.On("GROUP_ROSTER_UPDATE", Refresh)                 -- (my group's own dots are the game's)
    C_Timer.NewTicker(TICK, Tick)
    C_Timer.NewTicker(PRUNE_EVERY, Prune)
    -- OpenMap's guild switch doesn't tell us when it changes: while the map is open, look each
    -- second, and redraw at once (otherwise each dot waited for its player's next position).
    local openMapHid = false
    C_Timer.NewTicker(1, function()
        if not MapShown() then return end
        local hid = OpenMapHidesGuild()
        if hid ~= openMapHid then
            openMapHid = hid
            Refresh()
        end
    end)
    -- Sharing is on by default: said once, so nobody shares without knowing it.
    C_Timer.After(15, function()
        local s = Settings()
        if s.share and not s.told then
            s.told = true
            ns.Print(L["Your position is now shared on the map with your guild and the allied guilds (players who run La Taverne). Options, Map: to turn it off."])
        end
    end)
end

-- /taverne map: what's shared and shown.
ns.commands.map = function()
    local s = Settings()
    local m, x, y = Here()
    ns.Print(format("map: sharing %s, showing guild %s, allies %s, OpenMap %s (stitched %s)",
        s.share and "on" or "off", s.showGuild and "on" or "off", s.showAllies and "on" or "off",
        OpenMapAPI and ("API v" .. tostring(OpenMapAPI.version)) or "absent", OpenMapStitched() and "yes" or "no"))
    ns.Print(m and format("map: here = map %d, %.1f, %.1f", m, x * 100, y * 100) or "map: here = unknown (instance, or the game won't say)")
    local st = AllyMap.stats
    ns.Print(format("map: sent %d, off %d, received %d, rejected %d, expired %d, drawn %d, left to OpenMap %d",
        st.sent, st.offSent, st.received, st.rejected, st.expired, st.drawn, st.skippedOpenMap))
    local om = OpenMapSettings()
    ns.Print(format("map: OpenMap %s, its map %s, its guild switch %s: La Taverne's guild and allied dots %s",
        OpenMapAPI and "loaded" or "not loaded", OpenMapStitched() and "on" or "off",
        om and (om.guild == false and "off" or "on") or "?", OpenMapHidesGuild() and "hidden" or "follow La Taverne's switches"))
    local now = GetTime()
    for _, e in pairs(live) do
        ns.Print(format("  %s (%s%s) map %d %.1f, %.1f, %d s ago", e.name, e.scope, e.tag and (" " .. e.tag) or "",
            e.m, e.x * 100, e.y * 100, math.floor(now - e.at)))
    end
end
