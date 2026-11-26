-- /taverne dev: sandbox mode, a simulated guild for testing without touching the real one.
local ADDON, ns = ...
local L = ns.Log

local function q(v) return "[" .. tostring(v) .. "]" end

local function Status()
    local dev = ns.db.dev
    wipe(ns.log)
    L("LaTaverne", ns.version, "dev status", date("%Y-%m-%d %H:%M:%S"))
    L("me", q(ns.FullName("player")))
    if dev.sandbox then
        L("sandbox: ON (nothing is sent to the real guild)")
        L("test channel", ns.Comm:GetChannelName(), "ready", ns.Comm:IsReady() and "yes" or "no",
            ns.Comm:JoinFailed() and "(join FAILED - wrong password or banned)" or "")
        L("fake guild", q(dev.guildName))
        L("fake guild info", q(dev.infoText))
        local names = {}
        for _, entry in pairs(dev.roster) do names[#names + 1] = entry.name end
        table.sort(names)
        L("fake roster (me +", #names .. "):", #names > 0 and table.concat(names, ", ") or "nobody else")
    else
        L("sandbox: OFF (real guild)")
        L("guild", q(ns.Guild:GetName()), "roster", ns.Guild:GetRosterCount())
    end
    local s = ns.Comm.stats
    L("messages sent", s.sent, "received", s.received, "rejected", s.rejected)
    ns.ShowCopyWindow()
end

-- Switching test mode on or off: asked first, then La Taverne reloads. My group, availability,
-- auto-invite and map position are saved per character, not per mode: they would follow me to
-- the other side (a test group answered to the real guild at the next login there). So they're
-- ended first, on the side I'm leaving, so that side stops showing them. The reload clears
-- the rest: other players' groups and dots, the queues, the channels.
local function EndForSwitch()
    if ns.Groups:GetMine() then ns.Groups:Delist() end
    ns.Players:Stop()
    ns.Invites:Stop()
    if ns.AllyMap.StopSharing then ns.AllyMap:StopSharing() end
end

-- Two steps. The game only lets a reload come from the player's click (ReloadUI is protected),
-- and that click reloads at once: messages sent in it were lost in the queues. So:
-- 1. the question; Continue ends my things and sends them;
-- 2. a second popup waits until nothing is left to send (at most WAIT_MAX seconds), then leaves
--    the channels (a reload keeps them otherwise), saves the new mode and shows Reload: a secure
--    button running the /reload macro, laid over the popup's button.
-- Secure buttons can't be shown or hidden in combat: no switching then, and combat starting
-- closes the popups (then /reload finishes it, if step 1 was done).
local ASK, DIALOG = "LaTaverneConfirm_switchTestMode", "LaTaverneConfirm_switchTestModeReload"
local WAIT_MIN, WAIT_MAX = 0.5, 6
local ready                      -- step 2: everything went out, Reload is showing
local prepared                   -- step 1 done (the mode is switched once ready)
local reloadButton

local function ReloadButton()
    if reloadButton then return reloadButton end
    local b = CreateFrame("Button", "LaTaverneReloadButton", UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    b:SetSize(120, 24)
    b:SetFrameStrata("FULLSCREEN_DIALOG") -- above the popup, even once a click raises it
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "/reload")
    b:RegisterForClicks("AnyUp", "AnyDown") -- the secure action picks the one the game uses
    b:SetText(ns.L["Reload"])
    b:Hide()
    b:SetScript("PreClick", function()
        -- If the reload didn't happen, say how to finish.
        C_Timer.After(2, function() ns.Print(ns.L["Type /reload to finish switching test mode."]) end)
    end)
    reloadButton = b
    return b
end

local function ShowReload(dialog)
    local slot = dialog.buttons and dialog.buttons[1]
    if not slot or InCombatLockdown() then return end
    local b = ReloadButton()
    slot:Hide()
    b:ClearAllPoints()
    b:SetPoint("CENTER", slot, "CENTER")
    b:SetFrameLevel(dialog:GetFrameLevel() + 20)
    b:Show()
end

-- Step 2: wait for the messages, then switch and offer the reload.
local function Prepare(on)
    local T = ns.L
    EndForSwitch()
    prepared, ready = true, false
    ns.ConfirmDialog({
        kind = "switchTestModeReload",
        text = function()
            return ready and T["Done: everything went out. Reload to finish switching test mode."]
                or T["Ending your group, availability and auto-invite on the side you're leaving..."]
        end,
        buttons = { { text = T["Reload"] } },
    })
    local dialog = _G[DIALOG]
    if not dialog then return end
    dialog.buttons[1]:Disable()
    if not dialog.reloadHooked then
        dialog.reloadHooked = true
        dialog:HookScript("OnHide", function()
            if reloadButton and not InCombatLockdown() then reloadButton:Hide() end
            if prepared then ns.Print(T["Type /reload to finish switching test mode."]) end
        end)
    end
    local started = GetTime()
    local function Check()
        local waited = GetTime() - started
        if waited < WAIT_MAX and (waited < WAIT_MIN or ns.Comm:Pending()) then
            C_Timer.After(0.25, Check)
            return
        end
        ns.Comm:LeaveAllChannels()
        ns.db.dev.sandbox = on
        ns.reloadPending = true -- nothing more goes out before the reload
        ready = true
        dialog.buttons[1]:Enable()
        if dialog:IsShown() then ShowReload(dialog) end
    end
    Check()
end

local function SetSandbox(on)
    on = on and true or false
    if (ns.db.dev.sandbox and true or false) == on then
        ns.Print(on and "test mode is already on." or "test mode is already off.")
        return
    end
    if InCombatLockdown() then
        ns.Print(ns.L["Test mode can't be switched during combat."])
        return
    end
    if prepared then
        ns.Print(ns.L["Type /reload to finish switching test mode."])
        return
    end
    local T = ns.L
    ns.ConfirmDialog({
        kind = "switchTestMode",
        text = on and T["Switch to test mode? La Taverne will reload and use the test guild. Your group, your availability and auto-invite end first, so they don't follow you there."]
            or T["Leave test mode? La Taverne will reload and use your REAL guild. Your test group, your availability and auto-invite end first, so they don't reach your real guild."],
        buttons = { { text = T["Continue"], onClick = function() Prepare(on) end }, { text = CANCEL } },
    })
end
ns.SetSandbox = SetSandbox

-- Combat starting: close the popups while the secure button can still be hidden.
ns.On("PLAYER_REGEN_DISABLED", function()
    for _, name in ipairs({ ASK, DIALOG }) do
        local dialog = _G[name]
        if dialog and dialog:IsShown() then dialog:Hide() end
    end
end)


local subcommands = {}

subcommands[""] = Status
subcommands.status = Status

subcommands.on = function()
    SetSandbox(true)
end

subcommands.off = function()
    SetSandbox(false)
end

subcommands.guild = function(arg)
    if arg == "" then
        ns.Print("usage: /taverne dev guild <fake guild name>")
        return
    end
    ns.db.dev.guildName = arg
    ns.Print("fake guild name: " .. arg)
    ns.Alliance:Refresh()
    if ns.MockGuild then ns.MockGuild:Refresh() end
end

subcommands.info = function(arg)
    ns.db.dev.infoText = arg
    ns.Print(arg == "" and "fake guild info cleared" or ("fake guild info: " .. arg))
    ns.Alliance:Refresh()
    if ns.MockGuild then ns.MockGuild:Refresh() end
end

subcommands.add = function(arg)
    if arg == "" then
        ns.Print("usage: /taverne dev add Firstname Lastname")
        return
    end
    ns.db.dev.roster[ns.NameKey(arg)] = { name = strtrim(arg) }
    ns.Groups:Resync()
    ns.Print("added to the fake roster: " .. strtrim(arg))
end

subcommands.remove = function(arg)
    local key = ns.NameKey(arg)
    if key and ns.db.dev.roster[key] then
        ns.db.dev.roster[key] = nil
        ns.Print("removed from the fake roster: " .. arg)
    else
        ns.Print("not in the fake roster: " .. arg)
    end
end

subcommands.clear = function()
    wipe(ns.db.dev.roster)
    ns.Print("fake roster cleared (only you are left)")
end

subcommands.ping = function(arg)
    local text = arg ~= "" and arg or "ping"
    local sent = ns.Comm:Send("DEV_PING", { text = text })
    L("DEV_PING", q(text), sent and "sent" or "queued (channel not ready yet)")
end

-- A test guild member without La Taverne says a line: the guild relay passes it on to the
-- allied test guilds (two PCs in two test guilds).
subcommands.say = function(arg)
    local name, text = arg:match("^([^:]+):%s*(.+)$")
    if not name or not ns.AllyChat:SendFakeMemberLine(name, text) then
        ns.Print("usage, test mode only: /taverne dev say Firstname Lastname: text (not your own name)")
    end
end

-- A test guild member without La Taverne shares their place through OpenMap, walking a circle
-- around you: the guild relay's map job passes it on to the allied test guilds. Again to stop.
subcommands.walk = function(arg)
    local ok, started = ns.Relay:FakeWalk(arg)
    if not ok then
        ns.Print("usage, test mode only, outside instances: /taverne dev walk Firstname Lastname (again to stop; not your own name)")
    else
        ns.Print((started and "walking around you: " or "stopped: ") .. strtrim(arg))
    end
end

subcommands.expiry = function()
    if ns.Players:DevExpireSoon() then
        ns.Print("availability now ends in 5 min: the popup shows within a few seconds")
    else
        ns.Print("become available first (Je suis disponible...), then try again")
    end
end

-- A made-up open group of any size (2 to 40) in Groups: how this version shows sizes only a later
-- version can post ("Other" with a size). Again with the same size, or 0, removes it.
subcommands.group = function(arg)
    local ok, shown = ns.Groups:FakeGroup(tonumber(arg))
    if not ok then
        ns.Print("usage, test mode only: /taverne dev group <size, 2 to 40> (again, or 0, to remove it)")
    else
        ns.Print(shown and ("a fake group of " .. arg .. " is in Groups") or "fake group removed")
    end
end

ns.commands.dev = function(arg)
    local sub, rest = arg:match("^(%S*)%s*(.-)$")
    local handler = subcommands[(sub or ""):lower()]
    if handler then
        handler(rest or "")
    else
        ns.Print("/taverne dev [status] - show test mode settings")
        ns.Print("/taverne dev on | off - sandbox on or off (off needs 'confirm')")
        ns.Print("/taverne dev guild <name> - fake guild name")
        ns.Print("/taverne dev info <text> - fake guild info text (empty to clear), lines separated by ;")
        ns.Print("/taverne dev add | remove <Firstname Lastname> - fake roster")
        ns.Print("/taverne dev clear - empty the fake roster")
        ns.Print("/taverne dev ping [text] - message the other testers, they answer back")
        ns.Print("/taverne dev say <Firstname Lastname>: <text> - a test guild member without La Taverne says a line (the guild relay passes it on)")
        ns.Print("/taverne dev walk <Firstname Lastname> - a test guild member without La Taverne shares their place through OpenMap (the guild relay passes it on); again to stop")
        ns.Print("/taverne dev expiry - show the availability expiry popup now (be available first)")
        ns.Print("/taverne dev group <size> - a fake open group of that size (2 to 40) in Groups; again, or 0, to remove it")
    end
end

-- Ping / pong between testers, through the real messaging layer.
ns.Comm:On("DEV_PING", function(sender, payload, isSelf)
    if isSelf then return end
    L("PING from", q(sender), q(payload.text))
    ns.Comm:Send("DEV_PONG", { to = sender, text = payload.text })
end)

ns.Comm:On("DEV_PONG", function(sender, payload, isSelf)
    if isSelf or not ns.IsMe(payload.to) then return end
    L("PONG from", q(sender), q(payload.text))
    if ns.MockGuild then ns.MockGuild:AddSystem("PONG from " .. sender) end
end)

-- /taverne clearcache: forget what La Taverne remembers about other players (vouching evidence,
-- guild rosters saved by my characters, players seen with La Taverne), then reload. Settings,
-- the error report and the allied chat history stay.
ns.commands.clearcache = function()
    ns.ClearCache()
    ns.Print(ns.L["Remembered players forgotten (vouching, guild rosters, players seen). Reloading..."])
    ReloadUI()
end

-- /taverne debug: everything useful to look into a problem, in one text to copy: version and
-- game, the error report, the alliance (as /taverne ally), the guild relay's report, the message
-- log (if it's recording), and which related addons are loaded. Never the text of chat lines.
ns.commands.debug = function()
    local out = {}
    local function Add(text) out[#out + 1] = text end
    local function Section(title)
        Add("")
        Add("===== " .. title .. " =====")
    end
    local function Try(fn)
        local ok, err = pcall(fn)
        if not ok then Add("(could not read: " .. tostring(err) .. ")") end
    end
    local version, build, _, toc = GetBuildInfo()
    Add(format("La Taverne %s debug report, %s", tostring(ns.version), date("%Y-%m-%d %H:%M:%S")))
    Add(format("Me: %s, guild [%s]%s; game %s (%s, toc %s), %s; gamepad UI %s",
        tostring(ns.FullName("player")), tostring(ns.Guild:GetName()), ns.Guild:IsSandbox() and " (test mode)" or "",
        tostring(version), tostring(build), tostring(toc), GetLocale(), ns.GamepadUI() and "on" or "off"))
    local addons = {}
    for _, name in ipairs({ "GuildUnion", "Chattynator", "OpenMap", "BugSack", "!BugGrabber" }) do
        local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name)
        if loaded then
            local v = C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(name, "Version")
            addons[#addons + 1] = name .. (v and (" " .. v) or "")
        end
    end
    Add("Related addons loaded: " .. (#addons > 0 and table.concat(addons, ", ") or "none"))
    Add(format("Remembered: vouching %d players, guild rosters %d, allied chat lines %d (not listed)",
        ns.db.vouchLedger and (function() local n = 0 for _ in pairs(ns.db.vouchLedger) do n = n + 1 end return n end)() or 0,
        ns.db.rosterSnapshots and (function() local n = 0 for _ in pairs(ns.db.rosterSnapshots) do n = n + 1 end return n end)() or 0,
        #(ns.db.allyLog or {})))

    Section("Errors")
    Try(function() Add(ns.Errors:Report()) end)
    Section("Alliance")
    Try(function()
        ns.Alliance.StatusLines(function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            Add(table.concat(parts, " "))
        end)
    end)
    Section("My group and sending")
    Try(function()
        Add(ns.Groups:ListingText())
        Add(ns.Comm:QueueText())
    end)
    if ns.Relay and ns.Relay.ReportText then
        Section("Guild relay")
        Try(function() Add(ns.Relay:ReportText()) end)
    end
    Section("Sent")
    Try(function() Add(ns.Comm:SentText()) end)
    Section("Message log")
    Try(function()
        if ns.Comm:IsLogging() then
            Add(ns.Comm:LogText({}, {}))
        else
            Add(ns.Comm:UnusualText())
            Add("The full log is off. To include it: /taverne msglog, tick Recording, let it run a few minutes, then /taverne debug again.")
        end
    end)

    ns.TextDialog({
        kind = "debug",
        title = ns.L["Debug report"],
        width = 760,
        hint = ns.L["Everything La Taverne can tell about a problem (no chat text). Copy selects it all: then Ctrl+C, and send it to the author."],
        text = table.concat(out, "\n"),
        button = ns.L["Copy"],
        onButton = function()
            ns.SelectTextDialog()
            return false
        end,
    })
end
