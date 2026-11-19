-- Minimap button (LibDataBroker launcher + LibDBIcon).
-- Left-click opens La Taverne; right-click opens a short menu. Idle: Create a group, I'm
-- available..., then Groups, Availability. In a group of the finder: just My group; available:
-- Groups and Availability (in green). Then auto-invite (Start, or its page in green while it
-- runs: the Stop button is there), Options.
-- The tooltip says where I'm at: my group, my availability, auto-invite.
-- On the button: a golden pulse with a count when something waits for my answer and I haven't
-- seen it yet (join requests to my group, invitations), and a small steady green dot while
-- something of mine is on (my group looking for players, available, auto-invite).
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
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
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
            if IsInGroup() and avail.SetEnabled then
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
        -- Auto-invite: start it, or (running) its page, where the Stop button is.
        if ns.Invites:IsActive() then
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
    icon = "Interface\\AddOns\\LaTaverne\\icon",
    OnClick = function(self, button)
        if button == "RightButton" then
            QuickMenu(self)
        else
            ns.UI:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("La Taverne")
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

    local function Update()
        local unseen = ns.Groups:CountUnseen()
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
    end
    C_Timer.NewTicker(1, Update)
    Update()
end

function Minimap:OnLogin()
    local icon = LibStub("LibDBIcon-1.0")
    icon:Register(ADDON, launcher, ns.db.minimap)
    local button = icon.GetMinimapButton and icon:GetMinimapButton(ADDON)
    if button then Decorate(button) end
end
