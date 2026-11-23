-- Minimap button (LibDataBroker launcher + LibDBIcon).
-- Left-click opens La Taverne; right-click opens a short menu. Idle: Create a group, I'm
-- available..., then Groups, Availability. In a group of the finder: just My group; available:
-- Groups and Availability (in green). Then the map's dots (guild members, allied guilds:
-- switched in place), the guild relay's window (in an alliance), auto-invite (Start, or its page
-- in green while it runs: the Stop button is there), Options.
-- The tooltip says where I'm at: my group, my availability, auto-invite.
-- On the button: a golden pulse with a count when something waits for my answer and I haven't
-- seen it yet (join requests to my group, invitations), a small steady green dot while
-- something of mine is on (my group looking for players, available, auto-invite), and a small
-- speech bubble while I relay my guild's chat for the allied guilds (Relay.lua).
local ADDON, ns = ...
local Minimap = ns.NewModule("Minimap")
local L = ns.L

-- Things that are on right now show in green, so it's clear they can be stopped.
local function On(text) return "|cff20ff20" .. text .. "|r" end

local function Divider(root)
    if root.CreateDivider then root:CreateDivider() end
end

local function OpenPage(page)
    ns.UI:Open()
    ns.UI:ShowPage(page)
end

local function QuickMenu(owner)
    ns.ContextMenu(owner, function(_, root)
        root:CreateTitle("La Taverne")
        local available = ns.Players:IsActive()
        local inGroup = ns.Groups:GetMine() or ns.Groups:GetJoined()
        if inGroup then
            -- Doing something already: only that.
            root:CreateButton(On(L["My group"]), function() OpenPage("mygroup") end)
        elseif available then
            root:CreateButton(L["Groups"], function() OpenPage("browse") end)
            root:CreateButton(On(L["Availability"]), function() OpenPage("players") end)
        else
            -- Idle: the two ways to start, then the two lists.
            root:CreateButton(L["Create a group"], function() OpenPage("mygroup") end)
            local avail = root:CreateButton(L["I'm available..."], function() ns.UI.OpenAvailability() end)
            if ns.InParty() and avail.SetEnabled then
                avail:SetEnabled(false)
                if avail.SetTooltip then
                    avail:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, L["I'm available..."])
                        GameTooltip_AddErrorLine(tooltip, L["You're in a party: post a group for your party instead."])
                    end)
                end
            end
            Divider(root)
            root:CreateButton(L["Groups"], function() OpenPage("browse") end)
            root:CreateButton(L["Availability"], function() OpenPage("players") end)
        end
        Divider(root)
        -- Dots on the map, switched here without opening the map or Options (allied guilds:
        -- only with an alliance).
        if ns.AllyMap and ns.db.allyMap then
            root:CreateCheckbox(L["Map: guild members"], function() return ns.db.allyMap.showGuild end,
                function() ns.AllyMap:SetShow("guild", not ns.db.allyMap.showGuild) end)
            if ns.Alliance:IsActive() then
                root:CreateCheckbox(L["Map: allied guilds"], function() return ns.db.allyMap.showAllies end,
                    function() ns.AllyMap:SetShow("ally", not ns.db.allyMap.showAllies) end)
            end
            Divider(root)
        end
        -- The guild relay's window (Relay.lua), while the guild is in an alliance.
        if ns.Relay and ns.Alliance:IsActive() then
            root:CreateButton(L["Guild relay"], function() ns.Relay:ShowWindow() end)
            Divider(root)
        end
        -- Auto-invite: start it, or (running) its page, where the Stop button is. Not at all
        -- when the officers turned it off for my rank.
        if not ns.Invites:IsAllowed() then
            -- nothing
        elseif ns.Invites:IsActive() then
            root:CreateButton(On(L["Auto-invite"]), function() ns.UI:ShowAutoInvite() end)
        else
            root:CreateButton(L["Start auto-invite"], function()
                ns.Invites:Toggle()
                ns.UI:ShowAutoInvite()
            end)
        end
        root:CreateButton(L["Options"], function() ns.UI:ShowSection("options") ns.UI:Open() end)
    end)
end

local launcher = LibStub("LibDataBroker-1.1"):NewDataObject(ADDON, {
    type = "launcher",
    text = "La Taverne",
    icon = "Interface\\AddOns\\LaTaverne\\media\\lynx_icon",
    OnClick = function(self, button)
        if button == "RightButton" then
            QuickMenu(self)
        else
            ns.UI:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("La Taverne")
        tooltip:AddLine("Nation du Québec", 0.83, 0.63, 0.09)
        local G = ns.Groups
        -- Me first: my group, the group I'm in, my availability, auto-invite.
        local mine = G:GetMine()
        local joined = not mine and G:GetJoined()
        if mine then
            local requests = G:CountRequests()
            tooltip:AddLine(format(L["Your group: %s"], ns.DungeonName(mine.dungeon))
                .. (requests > 0 and (", " .. format(L["%d requests"], requests)) or ""), 1, 0.82, 0)
        elseif joined then
            tooltip:AddLine(format(L["In a group: %s"], ns.DungeonName(joined.dungeon)), 1, 0.82, 0)
        end
        local P = ns.Players
        if P:IsActive() then
            local left = P:Remaining()
            tooltip:AddLine(left and format(L["Available for %d more min"], math.max(1, math.ceil(left / 60)))
                or L["Available until you log out"], 0.1, 1, 0.1)
        end
        if ns.Invites:IsActive() then
            tooltip:AddLine(format(L["Auto-invite: %d in the queue"], #ns.Invites:GetQueue()), 0.1, 1, 0.1)
        end
        local invitations = G:CountNewInvitations()
        if invitations > 0 then
            tooltip:AddLine(format(L["Invitations: %d"], invitations), 0.1, 1, 0.1)
        end
        tooltip:AddLine(format(L["Open groups: %d"], G:CountOpen()), 1, 1, 1)
        -- The allied guilds' channel, when the guild is in an alliance (same as the Alliance page).
        if ns.Alliance:IsActive() then
            tooltip:AddLine(L["Alliance channel:"] .. " " .. ns.Comm:AllyStatusText(), 1, 1, 1)
            -- Who passes on each guild's chat for its members without La Taverne (Relay.lua),
            -- and whether I do.
            for _, entry in ipairs(ns.Alliance:GetGuilds()) do
                tooltip:AddLine("|cff8fb8e8[" .. (entry.tag or "?") .. "]|r " .. L["Relay:"] .. " "
                    .. ns.Relay:StatusText(entry.name, "chat"), 1, 1, 1)
            end
            if ns.Relay:IsHolding("chat") then tooltip:AddLine(ns.Relay:MyStateText()) end
        end
        if ns.Guild:IsSandbox() then
            tooltip:AddLine(format(L["Test guild: %s"], ns.Guild:GetName() or "?"), 1, 0.6, 0)
        end
        tooltip:AddLine(L["Click to open or close. Right-click: quick menu."], 0.6, 0.6, 0.6)
    end,
})

-- Something of mine others can see right now.
local function SomethingOn()
    local mine = ns.Groups:GetMine()
    if mine then
        local state = ns.Groups:GetState(mine)
        if state ~= "running" and state ~= "full" then return true end
    end
    return ns.Players:IsActive() or ns.Invites:IsActive()
end

local function Decorate(button)
    local glow = button:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.82, 0)
    glow:SetSize(58, 58)
    glow:SetPoint("CENTER", 0, 0)
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.8)

    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", 2, -1)
    count:SetTextColor(1, 0.82, 0)

    local dot = button:CreateTexture(nil, "OVERLAY")
    dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online")
    dot:SetSize(12, 12)
    dot:SetPoint("TOPRIGHT", 1, 1)
    dot:Hide()

    -- While I relay my guild's chat (Relay.lua): a small speech bubble, bottom left.
    local badge = button:CreateTexture(nil, "OVERLAY")
    badge:SetTexture("Interface\\GossipFrame\\GossipGossipIcon")
    badge:SetSize(12, 12)
    badge:SetPoint("BOTTOMLEFT", 1, 1)
    badge:Hide()

    local function Update()
        -- The glow and count can be turned off in Options.
        local unseen = ns.db.minimapGlow ~= false and ns.Groups:CountUnseen() or 0
        if unseen > 0 then
            glow:Show()
            if not pulse:IsPlaying() then pulse:Play() end
            count:SetText(unseen)
        else
            pulse:Stop()
            glow:Hide()
            count:SetText("")
        end
        dot:SetShown(SomethingOn() and true or false)
        badge:SetShown(ns.Relay:IsHolding("chat") and true or false)
    end
    -- Updated when something changes (my group, requests, invitations, availability,
    -- auto-invite, relaying, or the page that shows them opening), plus a slow check in case
    -- something changes without saying so (a group's state with time).
    Minimap.Update = Update
    ns.Groups:OnChange(Update)
    ns.Players:OnChange(Update)
    ns.Invites:OnChange(Update)
    ns.Relay:OnChange(Update)
    C_Timer.NewTicker(10, Update)
    Update()
end

function Minimap:OnLogin()
    local icon = LibStub("LibDBIcon-1.0")
    icon:Register(ADDON, launcher, ns.db.minimap)
    local button = icon.GetMinimapButton and icon:GetMinimapButton(ADDON)
    if button then Decorate(button) end
    Minimap:SetInDrawer(ns.db.inDrawer ~= false)
    Minimap:RegisterSettings()
end

-- The game's add-on drawer (the button by the minimap that lists add-ons), when the game has one.
function Minimap:HasDrawer()
    local icon = LibStub("LibDBIcon-1.0")
    return icon.IsButtonCompartmentAvailable and icon:IsButtonCompartmentAvailable() or false
end

function Minimap:SetInDrawer(on)
    ns.db.inDrawer = on and true or false
    if not self:HasDrawer() then return end
    local icon = LibStub("LibDBIcon-1.0")
    if on then
        icon:AddButtonToCompartment(ADDON)
        local object = icon.objects and icon.objects[ADDON]
        if object and object.compartmentData then
            object.compartmentData.text = "La Taverne" -- the folder name otherwise
            if AddonCompartmentFrame and AddonCompartmentFrame.UpdateDisplay then AddonCompartmentFrame:UpdateDisplay() end
        end
    else
        icon:RemoveButtonFromCompartment(ADDON)
    end
end

-- A page in the game's options (Options, AddOns): the name, the version, and a button to the
-- options in the La Taverne window.
function Minimap:RegisterSettings()
    local panel = CreateFrame("Frame")
    panel.name = "La Taverne"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("La Taverne")
    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    version:SetText(ns.version or "")
    local by = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    by:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    by:SetText(L["by the Nation du Québec"])
    local logo = panel:CreateTexture(nil, "ARTWORK")
    logo:SetSize(128, 128)
    logo:SetPoint("TOPRIGHT", -16, -16)
    logo:SetTexture("Interface\\AddOns\\LaTaverne\\media\\lynx_logo")
    local notes = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    notes:SetPoint("TOPLEFT", by, "BOTTOMLEFT", 0, -10)
    -- Wraps left of the logo instead of running under it: as wide as the page minus the logo.
    notes:SetJustifyH("LEFT")
    notes:SetWordWrap(true)
    notes:SetWidth(360)
    panel:SetScript("OnSizeChanged", function(_, width)
        if width and width > 0 then notes:SetWidth(math.max(200, width - 16 - 16 - 128 - 16)) end
    end)
    notes:SetText(L["Guild dungeon group finder. Its options are in the La Taverne window."])
    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(220, 24)
    open:SetPoint("TOPLEFT", notes, "BOTTOMLEFT", 0, -16)
    open:SetText(L["Open La Taverne options"])
    open:SetScript("OnClick", function() ns.UI:OpenOverSettings("options") end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "La Taverne")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end
