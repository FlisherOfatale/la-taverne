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

local function SetSandbox(on)
    ns.db.dev.sandbox = on
    if on then
        ns.Comm:JoinSandbox()
        ns.Print("sandbox ON: traffic goes to the private test channel, guild is simulated")
    else
        ns.Comm:LeaveSandbox()
        ns.Print("sandbox OFF: LaTaverne now uses your real guild")
    end
    if ns.Vouch then ns.Vouch:Forget() end -- answers about test guilds mean nothing for real ones
    ns.Alliance:Refresh()
    if ns.MockGuild then ns.MockGuild:Refresh() end
    ns.UI:Refresh()
end
ns.SetSandbox = SetSandbox


local subcommands = {}

subcommands[""] = Status
subcommands.status = Status

subcommands.on = function()
    SetSandbox(true)
end

subcommands.off = function(arg)
    if arg ~= "confirm" then
        ns.Print("this switches LaTaverne to your REAL guild. Type /taverne dev off confirm to do it.")
        return
    end
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

subcommands.expiry = function()
    if ns.Players:DevExpireSoon() then
        ns.Print("availability now ends in 5 min: the popup shows within a few seconds")
    else
        ns.Print("become available first (Je suis disponible...), then try again")
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
        ns.Print("/taverne dev expiry - show the availability expiry popup now (be available first)")
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
