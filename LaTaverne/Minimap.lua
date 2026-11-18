-- Minimap button (LibDataBroker launcher + LibDBIcon).
-- Left-click opens La Taverne; right-click opens a short menu (available / stop, Options).
-- The tooltip says where I'm at: my group, my availability, auto-invite.
local ADDON, ns = ...
local Minimap = ns.NewModule("Minimap")
local L = ns.L

local function QuickMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("La Taverne")
        local P = ns.Players
        if P:IsActive() then
            root:CreateButton(L["Stop being available"], function() P:Stop(L["You're no longer available."]) end)
        else
            root:CreateButton(L["I'm available..."], function() ns.UI.OpenAvailability() end)
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

function Minimap:OnLogin()
    LibStub("LibDBIcon-1.0"):Register(ADDON, launcher, ns.db.minimap)
end
