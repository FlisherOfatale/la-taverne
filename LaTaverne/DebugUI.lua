-- Test mode tools, so testers don't need slash commands:
-- - the "Debug" tab of the main window (only shown in test mode): diagnostics, chat watch,
--   invite and roster checks, leaving test mode;
-- - the test guild window: the simulated guild's name, members, Guild Info and guild chat.
-- In test mode everything La Taverne does goes to that test guild, never to the real one.
-- (The game's own guild chat, /g, still goes to the real guild: use the test guild chat here.)
local ADDON, ns = ...
local L = ns.L
local K -- ns.UIKit, filled when the window is first built

local MockGuild = ns.NewModule("MockGuild")

local CHAT_MAX = 200
local chatLines = {}  -- this session's test guild chat: { t, author, class, tag, text } or { t, system }
local allies = {}     -- [name] = { guild, time } allied testers seen this session

local window

-- Data from the rest of the addon ----------------------------------------------------------

local function TimeText(t)
    return "|cff808080" .. date("%H:%M", t) .. "|r "
end

local function FormatChat(line)
    if line.system then
        return TimeText(line.t) .. "|cffffd100" .. line.system .. "|r"
    end
    -- Same as the real chat: the lynx, then the tag if that option is on (Options, Shared guild chat).
    local tag = ns.AllyChat.TagText(line.tag)
    return TimeText(line.t) .. tag .. "[" .. K.ClassColored(line.author, line.class) .. "]: " .. line.text
end

local function Append(line)
    chatLines[#chatLines + 1] = line
    if #chatLines > CHAT_MAX then table.remove(chatLines, 1) end
    if window and window.chat then
        local info = ChatTypeInfo and ChatTypeInfo.GUILD
        window.chat:AddMessage(FormatChat(line), info and info.r or 0.25, info and info.g or 1, info and info.b or 0.25)
    end
end

function MockGuild:AddChat(author, class, text, tag)
    Append({ t = time(), author = author, class = class, text = text, tag = tag })
end

function MockGuild:AddSystem(text)
    Append({ t = time(), system = text })
end

function MockGuild:NoteAlly(name, guild)
    allies[name] = { guild = guild, time = GetServerTime() }
end

function MockGuild:Refresh()
    if not window then return end
    if not ns.Guild:IsSandbox() then
        window:Hide()
    elseif window:IsShown() then
        window:Refresh()
    end
end

-- Test guild window --------------------------------------------------------------------------

local function SeenText(seen)
    if not seen then return "|cff808080" .. L["not seen yet"] .. "|r" end
    return "|cff40ff40" .. L["seen %s"]:format(K.Ago(seen)) .. "|r"
end

local function BuildWindow()
    local f = CreateFrame("Frame", "LaTaverneTestGuildFrame", UIParent, "ButtonFrameTemplate")
    f:SetSize(1020, 580)
    f:SetPoint("CENTER", 60, -30)
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(f) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(f) end
    if ButtonFrameTemplate_HideAttic then ButtonFrameTemplate_HideAttic(f) end
    local title = L["La Taverne - test guild"]
    if f.SetTitle then f:SetTitle(title)
    elseif f.TitleText then f.TitleText:SetText(title) end
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    tinsert(UISpecialFrames, "LaTaverneTestGuildFrame")

    local p = CreateFrame("Frame", nil, f.Inset or f)
    p:SetPoint("TOPLEFT", 8, -8)
    p:SetPoint("BOTTOMRIGHT", -8, 8)

    local message = K.NewLabel(p, "", "GameFontHighlightSmall")
    message:SetPoint("BOTTOMLEFT", 4, 2)
    message:SetPoint("RIGHT", -4, 0)
    message:SetJustifyH("LEFT")
    local function Say(text, isError)
        message:SetText(text and ((isError and "|cffff4040" or "|cff40ff40") .. text .. "|r") or "")
    end

    -- Left column: name and members --------------------------------------------------------
    K.NewLabel(p, L["Guild name"], "GameFontNormal"):SetPoint("TOPLEFT", 4, -4)
    local nameBox = K.NewInput(p, 200, 40)
    nameBox:SetPoint("TOPLEFT", 10, -22)
    local nameSave = K.NewButton(p, L["Rename"], 80)
    nameSave:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    local function SaveName()
        local name = strtrim(nameBox:GetText())
        if name == "" then Say(L["Type a guild name."], true) return end
        ns.db.dev.guildName = name
        nameBox:ClearFocus()
        ns.Alliance:Refresh()
        Say(L["Test guild renamed."])
        f:Refresh()
    end
    nameSave:SetScript("OnClick", SaveName)
    nameBox:SetScript("OnEnterPressed", SaveName)

    K.NewLabel(p, L["Members"], "GameFontNormal"):SetPoint("TOPLEFT", 4, -54)
    local hint = K.NewLabel(p, L["Testers must be listed on both sides to see each other's groups."], "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 4, -70)
    hint:SetWidth(400)
    hint:SetJustifyH("LEFT")

    local members = K.NewScrollList(p, 34, function(row, data)
        if not row.init then
            row.init = true
            K.RowBackground(row)
            row.name = K.NewLabel(row, "")
            row.name:SetPoint("TOPLEFT", 6, -3)
            row.info = K.NewLabel(row, "", "GameFontHighlightSmall")
            row.info:SetPoint("TOPLEFT", 6, -18)
            row.remove = K.NewButton(row, L["Remove"], 80)
            row.remove:SetPoint("RIGHT", -4, 0)
            row.remove:SetScript("OnClick", function()
                ns.db.dev.roster[ns.NameKey(row.data.name)] = nil
                f:Refresh()
            end)
        end
        row.data = data
        row.name:SetText(ns.ClassIcon(data.class) .. " " .. K.ClassColored(data.name, data.class)
            .. (data.me and (" |cff808080(" .. L["You"] .. ")|r") or ""))
        local level = data.level and (L["Level %d"]:format(data.level) .. "  ") or ""
        row.info:SetText(data.me and level or (level .. SeenText(data.seen)))
        row.remove:SetShown(not data.me)
    end)
    members:SetPoint("TOPLEFT", 0, -96)
    members:SetSize(400, 34 * 7)

    local addBox = K.NewInput(p, 170, 60)
    addBox:SetPoint("TOPLEFT", 10, -344)
    local addButton = K.NewButton(p, L["Add"], 70)
    addButton:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    local addTarget = K.NewButton(p, L["Add my target"], 120)
    addTarget:SetPoint("LEFT", addButton, "RIGHT", 4, 0)
    local function AddMember(name)
        name = strtrim(name or "")
        if not name:find("%S+ %S+") then Say(L["Type the full name: Firstname Lastname."], true) return end
        if ns.IsMe(name) then Say(L["You're always in the test guild."], true) return end
        ns.db.dev.roster[ns.NameKey(name)] = ns.db.dev.roster[ns.NameKey(name)] or { name = name }
        ns.Groups:Resync()
        addBox:SetText("")
        Say(L["%s added to the test guild."]:format(name))
        f:Refresh()
    end
    addButton:SetScript("OnClick", function() AddMember(addBox:GetText()) end)
    K.SetPlaceholder(addBox, L["Firstname Lastname"])
    addBox:SetScript("OnEnterPressed", function() AddMember(addBox:GetText()) end)
    addTarget:SetScript("OnClick", function()
        if not UnitIsPlayer("target") then Say(L["Target a player first."], true) return end
        AddMember(ns.FullName("target"))
    end)

    local clearButton = K.NewButton(p, L["Remove everyone"], 180)
    clearButton:SetPoint("TOPLEFT", 10, -376)
    clearButton:SetScript("OnClick", function()
        wipe(ns.db.dev.roster)
        Say(L["Only you are left in the test guild."])
        f:Refresh()
    end)

    -- Allied testers seen this session
    K.NewLabel(p, L["Allied testers seen"], "GameFontNormal"):SetPoint("TOPLEFT", 4, -418)
    -- Vouching with 2 PCs: the only member of my test guild online is me, and nobody answers
    -- about themselves. This lets me answer questions about me, to test both answers.
    local VOUCH_SELF = {
        { key = nil, text = L["Stay quiet (normal)"] },
        { key = "yes", text = L["Answer: yes, in my guild"] },
        { key = "no", text = L["Answer: no, not in my guild"] },
    }
    local vouchSelf = ns.NewDropdown(p)
    vouchSelf:SetPoint("TOPLEFT", 250, -412)
    vouchSelf:SetWidth(150)
    vouchSelf:SetupMenu(function(_, root)
        root:CreateTitle(L["Questions about me"])
        for _, mode in ipairs(VOUCH_SELF) do
            root:CreateRadio(mode.text,
                function() return ns.db.dev.vouchSelf == mode.key end,
                function() ns.db.dev.vouchSelf = mode.key end)
        end
    end)
    vouchSelf:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Questions about me"],
            L["Allied testers ask whether you're in your test guild. Normally only another member online answers, never you. With 2 PCs there's nobody else: pick an answer here to test it."] })
    end)
    vouchSelf:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local vouchLabel = K.NewLabel(p, L["Questions about me"], "GameFontHighlightSmall")
    vouchLabel:SetPoint("RIGHT", vouchSelf, "LEFT", -6, 0)
    local alliesText = K.NewLabel(p, "", "GameFontHighlightSmall")
    alliesText:SetPoint("TOPLEFT", 8, -436)
    alliesText:SetWidth(400)
    alliesText:SetJustifyH("LEFT")

    -- Right column: guild info and chat ------------------------------------------------------
    local RIGHT = 440
    K.NewLabel(p, L["Guild Info"], "GameFontNormal"):SetPoint("TOPLEFT", RIGHT, -4)
    local info = K.NewTextArea(p, 440, 96)
    info:SetPoint("TOPLEFT", RIGHT, -22)
    local infoSave = K.NewButton(p, L["Save"], 100)
    infoSave:SetPoint("TOPLEFT", info, "TOPRIGHT", 6, 0)
    infoSave:SetScript("OnClick", function()
        ns.db.dev.infoText = info.edit:GetText()
        info.edit:ClearFocus()
        ns.Alliance:Refresh()
        Say(L["Guild Info saved."])
        f:Refresh()
    end)
    local allianceText = K.NewLabel(p, "", "GameFontHighlightSmall")
    allianceText:SetPoint("TOPLEFT", RIGHT, -122)
    allianceText:SetPoint("RIGHT", -4, 0)
    allianceText:SetJustifyH("LEFT")

    -- The test guild's own hidden channel (LT:t line): testers of one test guild share it.
    local testKeyButton = K.NewButton(p, L["New debug channel"], 220)
    testKeyButton:SetPoint("TOPLEFT", RIGHT, -140)
    testKeyButton:SetScript("OnClick", function()
        ns.db.dev.infoText = ns.Alliance.WithNewTestKey(ns.db.dev.infoText)
        info.edit:ClearFocus()
        ns.Alliance:Refresh()
        Say(L["New debug channel made. Copy the Guild Info (LT:t line) to the other testers of this test guild."])
        f:Refresh()
    end)
    local testKeyText = K.NewLabel(p, "", "GameFontHighlightSmall")
    testKeyText:SetPoint("LEFT", testKeyButton, "RIGHT", 10, 0)
    testKeyText:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    testKeyText:SetJustifyH("LEFT")

    K.NewLabel(p, L["Guild chat"], "GameFontNormal"):SetPoint("TOPLEFT", RIGHT, -172)
    local chatBg = CreateFrame("Frame", nil, p, "BackdropTemplate")
    chatBg:SetPoint("TOPLEFT", RIGHT, -190)
    -- Room under the chat for the input and its 2-line hint, above the status line.
    chatBg:SetPoint("BOTTOMRIGHT", -4, 96)
    if chatBg.SetBackdrop then
        chatBg:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        chatBg:SetBackdropColor(0, 0, 0, 0.5)
        chatBg:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end
    local chat = CreateFrame("ScrollingMessageFrame", nil, chatBg)
    chat:SetPoint("TOPLEFT", 8, -6)
    chat:SetPoint("BOTTOMRIGHT", -8, 6)
    chat:SetFontObject(ChatFontNormal)
    chat:SetJustifyH("LEFT")
    chat:SetFading(false)
    chat:SetMaxLines(CHAT_MAX)
    chat:SetHyperlinksEnabled(true)
    chat:EnableMouseWheel(true)
    chat:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    f.chat = chat
    for _, line in ipairs(chatLines) do
        local ci = ChatTypeInfo and ChatTypeInfo.GUILD
        chat:AddMessage(FormatChat(line), ci and ci.r or 0.25, ci and ci.g or 1, ci and ci.b or 0.25)
    end

    local chatInput = K.NewInput(p, 290, 255)
    chatInput:SetPoint("TOPLEFT", chatBg, "BOTTOMLEFT", 6, -6)
    local send = K.NewButton(p, L["Send"], 90)
    send:SetPoint("LEFT", chatInput, "RIGHT", 6, 0)
    local function Send()
        if ns.AllyChat:SendTestGuildChat(chatInput:GetText()) then chatInput:SetText("") end
    end
    send:SetScript("OnClick", Send)
    chatInput:SetScript("OnEnterPressed", Send)
    local ping = K.NewButton(p, L["Ping testers"], 150)
    ping:SetPoint("LEFT", send, "RIGHT", 6, 0)
    ping:SetScript("OnClick", function()
        local sent = ns.Comm:Send("DEV_PING", { text = "ping" })
        MockGuild:AddSystem(sent and L["Ping sent: testers running La Taverne answer."] or L["Debug channel not ready yet."])
    end)
    local chatHint = K.NewLabel(p, L["Stands in for guild chat: goes to the test guild and the allied test guilds. Your normal /g still goes to your real guild."], "GameFontDisableSmall")
    chatHint:SetPoint("TOPLEFT", chatInput, "BOTTOMLEFT", -6, -4)
    chatHint:SetPoint("RIGHT", -4, 0)
    chatHint:SetJustifyH("LEFT")

    local statusHolder = CreateFrame("Frame", nil, p)
    statusHolder:SetPoint("BOTTOMLEFT", message, "TOPLEFT", 0, 4)
    statusHolder:SetPoint("RIGHT", -4, 0)
    statusHolder:SetHeight(14)
    statusHolder:EnableMouse(true)
    statusHolder:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, {
            L["Hidden channels"],
            L["Debug channel: replaces the guild for your test guild (groups, invitations, guild chat). Made from the LT:t line."],
            L["Guild Alliance channel: talks with the allied guilds, in debug mode and for real. Made from the LT:k key that the Alliance Setup page saves."],
        })
    end)
    statusHolder:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local statusText = K.NewLabel(statusHolder, "", "GameFontHighlightSmall")
    statusText:SetAllPoints()
    statusText:SetJustifyH("LEFT")

    function f:Refresh()
        if not nameBox:HasFocus() then nameBox:SetText(ns.db.dev.guildName or "") end
        if not info.edit:HasFocus() then info.edit:SetText(ns.db.dev.infoText or "") end

        local list = {}
        local _, myClass = UnitClass("player")
        list[1] = { name = ns.FullName("player"), class = myClass, level = UnitLevel("player"), me = true }
        local others = {}
        for _, entry in pairs(ns.db.dev.roster) do others[#others + 1] = entry end
        table.sort(others, function(a, b) return a.name < b.name end)
        for _, entry in ipairs(others) do list[#list + 1] = entry end
        K.SetListData(members, list)

        local names = {}
        for name, a in pairs(allies) do
            local state = ns.Vouch and ns.Vouch:Describe(name)
            names[#names + 1] = name .. " |cff808080(" .. tostring(a.guild) .. ", " .. K.Ago(a.time) .. ")|r"
                .. (state and ("  " .. state) or "")

        end
        table.sort(names)
        if vouchSelf.GenerateMenu then vouchSelf:GenerateMenu() end
        alliesText:SetText(#names > 0 and table.concat(names, "\n") or ("|cff808080" .. L["nobody yet"] .. "|r"))

        local guilds = {}
        for _, entry in ipairs(ns.Alliance:GetGuilds()) do
            if not ns.Guild:IsMyGuild(entry.name) then guilds[#guilds + 1] = entry.name .. " [" .. entry.tag .. "]" end
        end
        if ns.Alliance:IsActive() then
            allianceText:SetText("|cff40ff40" .. L["Allied with: %s"]:format(table.concat(guilds, ", ")) .. "|r")
        else
            allianceText:SetText("|cff808080" .. L["No Guild Alliance: set it up on the Setup tab, or type LT: lines here."] .. "|r")
        end

        if ns.Alliance:GetTestKey() then
            testKeyText:SetText(L["Debug channel: on (LT:t line). Testers of this test guild need the same line."])
        else
            testKeyText:SetText("|cffff9900" .. L["No debug channel yet: click New debug channel, or paste another tester's LT:t line in the Guild Info."] .. "|r")
        end

        local function yes(v) return v and ("|cff40ff40" .. L["ready"] .. "|r") or ("|cffff4040" .. L["not ready"] .. "|r") end
        local s = ns.Comm.stats
        local parts = {
            L["Debug channel"] .. ": " .. (ns.Alliance:GetTestKey() and yes(ns.Comm:IsReady()) or ("|cff808080" .. L["off"] .. "|r")),
            L["Guild Alliance channel"] .. ": " .. (ns.Alliance:IsActive() and yes(ns.Comm:IsAllyReady()) or ("|cff808080" .. L["off"] .. "|r")),
            L["Messages sent %d, received %d, ignored %d"]:format(s.sent, s.received, s.rejected),
        }
        statusText:SetText(table.concat(parts, "    "))
    end

    f:SetScript("OnShow", function(self)
        self:Refresh()
        self.ticker = C_Timer.NewTicker(2, function() if self:IsShown() then self:Refresh() end end)
    end)
    f:SetScript("OnHide", function(self)
        if self.ticker then self.ticker:Cancel() self.ticker = nil end
    end)
    f:Hide()
    return f
end

function MockGuild:Toggle()
    K = K or ns.UIKit
    if not window then window = BuildWindow() end
    window:SetShown(not window:IsShown())
end

-- Message log window (Debug tab, /taverne msglog): Refresh reads it again, Clear starts over.
function ns.ShowMessageLog()
    ns.TextDialog({
        kind = "msglog",
        title = L["Message log"],
        hint = ns.Comm:IsLogging() and L["On: new messages show when you click Refresh. Copy with Ctrl+A, Ctrl+C."]
            or L["Off: start it on the Debug tab (or /taverne msglog on). Copy with Ctrl+A, Ctrl+C."],
        text = ns.Comm:LogText(),
        button = L["Refresh"],
        onButton = function() ns.ShowMessageLog() return false end,
        extra = { text = L["Clear"], fill = function() ns.Comm:ClearLog() return ns.Comm:LogText() end },
    })
end

-- Debug tab ----------------------------------------------------------------------------------

function ns.BuildDebugPanel()
    K = ns.UIKit
    local p = K.NewPanel()

    K.NewLabel(p, L["Test mode"], "GameFontNormalLarge"):SetPoint("TOPLEFT", 8, -8)
    local intro = K.NewLabel(p, L["La Taverne uses the test guild below instead of your real guild: groups, invitations and chat stay between testers. Nothing is sent to your real guild."], "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 8, -32)
    intro:SetPoint("RIGHT", -8, 0)
    intro:SetJustifyH("LEFT")

    local open = K.NewButton(p, L["Open the test guild"], 200, 28)
    open:SetPoint("TOPLEFT", 8, -64)
    open:SetScript("OnClick", function() MockGuild:Toggle() end)
    local guildText = K.NewLabel(p, "", "GameFontHighlight")
    guildText:SetPoint("LEFT", open, "RIGHT", 12, 0)

    local gameChat = K.NewCheckbox(p, L["Also show the test guild chat in the game's chat windows (only you see it)"], function(self)
        ns.db.dev.gameChat = self:GetChecked() and true or false
    end)
    gameChat:SetPoint("TOPLEFT", 4, -100)

    -- Diagnostics: each button runs a check and opens the output window (Ctrl+A, Ctrl+C to copy).
    local diagTitle = K.NewLabel(p, L["Diagnostics"], "GameFontNormal")
    diagTitle:SetPoint("TOPLEFT", 8, -140)
    local diagHint = K.NewLabel(p, L["Each check opens the output window: copy it with Ctrl+A, Ctrl+C."], "GameFontDisableSmall")
    diagHint:SetPoint("LEFT", diagTitle, "RIGHT", 12, 0)

    local buttons = {
        { L["All checks"], function() ns.commands.test("all") end },
        { L["Game version"], function() ns.commands.test("env") end },
        { L["Game functions"], function() ns.commands.test("api") end },
        { L["Names"], function() ns.commands.test("names") end },
        { L["Real guild"], function() ns.commands.test("guild") end },
        { L["UI templates"], function() ns.commands.test("ui") end },
        { L["Hidden channel"], function() ns.commands.test("chan") end },
        { L["Dungeon names"], function() ns.commands.test("lfg") end },
        { L["Test mode status"], function() ns.commands.dev("status") end },
        { L["Guild Alliance status"], function() ns.commands.ally() end },
        { L["Last output"], function() ns.ShowCopyWindow() end },
        { L["Make a test error"], function() error("La Taverne test error (Debug tab button)") end },
    }
    -- 3 wide columns: the French labels ("État de l'alliance de guildes") don't fit in 4.
    local COLS, W, H = 3, 236, 24
    for i, def in ipairs(buttons) do
        local b = K.NewButton(p, def[1], W, H)
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        b:SetPoint("TOPLEFT", 8 + col * (W + 8), -164 - row * (H + 6))
        b:SetScript("OnClick", def[2])
    end

    -- Fake people inviting (auto-invite page: "2 others are inviting" and its tooltip).
    local fakeRunners = K.NewButton(p, "", W, 24)
    fakeRunners:SetPoint("TOPLEFT", 8, -294)
    local fakeHint = K.NewLabel(p, L["Two made-up players inviting, one on +1 and inv, one on +2 (auto-invite page)."], "GameFontDisableSmall")
    fakeHint:SetPoint("LEFT", fakeRunners, "RIGHT", 10, 0)
    fakeRunners:SetScript("OnClick", function()
        ns.Invites:FakeRunners(not ns.Invites:HasFakeRunners())
        p:Refresh()
    end)

    -- Chat watch on/off, then the message log on/off and its window. Explained in tooltips.
    local watch = K.NewButton(p, "", W, 24)
    watch:SetPoint("TOPLEFT", 8, -324)
    K.WithTooltip(watch, { L["Chat watch"], L["Logs whether chat messages can be read by addons (never their text)."] })
    watch:SetScript("OnClick", function()
        ns.commands.chatwatch()
        p:Refresh()
    end)
    local msgLog = K.NewButton(p, "", W, 24)
    msgLog:SetPoint("LEFT", watch, "RIGHT", 8, 0)
    local MSGLOG_TIP = { L["Message log"],
        L["Logs every hidden La Taverne message, sent and received, and what happened to it (delivered, held, rejected...). Never what it says."],
        L["Unusual ones are marked !! and counted at the top: copy it into your bug report."],
        L["Test mode: the test guild and the alliance. Your real guild's messages are only counted."] }
    K.WithTooltip(msgLog, MSGLOG_TIP)
    msgLog:SetScript("OnClick", function()
        ns.Comm:SetLogging(not ns.Comm:IsLogging())
        p:Refresh()
    end)
    local showLog = K.NewButton(p, L["Show the message log"], W, 24)
    showLog:SetPoint("LEFT", msgLog, "RIGHT", 8, 0)
    K.WithTooltip(showLog, MSGLOG_TIP)
    showLog:SetScript("OnClick", function() ns.ShowMessageLog() end)

    -- Player checks
    -- Player checks: name on the first line, the two checks on the second.
    K.NewLabel(p, L["Player checks"], "GameFontNormal"):SetPoint("TOPLEFT", 8, -366)
    local playerBox = K.NewInput(p, 230, 60)
    playerBox:SetPoint("TOPLEFT", 14, -386)
    local playerHint = K.NewLabel(p, L["Firstname Lastname"], "GameFontDisable")
    playerHint:SetPoint("LEFT", playerBox, "LEFT", 1, 0)
    local function UpdateHint() playerHint:SetShown(playerBox:GetText() == "" and not playerBox:HasFocus()) end
    playerBox:HookScript("OnTextChanged", UpdateHint)
    playerBox:HookScript("OnEditFocusGained", UpdateHint)
    playerBox:HookScript("OnEditFocusLost", UpdateHint)
    local useTarget = K.NewButton(p, L["Fill with my target"], W)
    useTarget:SetPoint("LEFT", playerBox, "RIGHT", 10, 0)
    useTarget:SetScript("OnClick", function()
        if UnitIsPlayer("target") then playerBox:SetText(ns.FullName("target")) end
    end)
    local invite = K.NewButton(p, L["Send a group invite"], W)
    invite:SetPoint("TOPLEFT", 8, -418)
    invite:SetScript("OnClick", function() ns.commands.invite(strtrim(playerBox:GetText())) end)
    local lookup = K.NewButton(p, L["Find in the real roster"], W)
    lookup:SetPoint("LEFT", invite, "RIGHT", 8, 0)
    lookup:SetScript("OnClick", function() ns.commands.who(strtrim(playerBox:GetText())) end)
    -- Vouching: ask the allied guilds whether this name is theirs (answer in the Network tab).
    local ask = K.NewButton(p, L["Ask the allied guilds"], W)
    ask:SetPoint("LEFT", lookup, "RIGHT", 8, 0)
    ask:SetScript("OnClick", function()
        local name = strtrim(playerBox:GetText())
        if name == "" then return end
        if ns.Vouch:AskAbout(name) then
            ns.Print(L["Asked the allied guilds about %s: the answer shows in the Alliance tab."]:format(name))
        else
            ns.Print(L["No Guild Alliance: nobody to ask."])
        end
    end)
    ask:SetScript("OnEnter", function(self)
        K.ShowTooltip(self, { L["Ask the allied guilds"],
            L["Vouching test: each allied guild is asked whether this player is one of theirs. A member online answers from their roster."] })
    end)
    ask:SetScript("OnLeave", function() GameTooltip:Hide() end)


    -- The window's lynx: short pauses, to see all its moves without waiting (not faster moves).
    local lynxFast = K.NewCheckbox(p, L["Lynx: short pauses (to see all its moves quickly)"], function(self)
        ns.Lynx:SetFast(self:GetChecked())
    end)
    lynxFast:SetPoint("TOPLEFT", 4, -456)

    -- Leaving test mode
    local leave = K.NewButton(p, L["Leave test mode"], 160, 24)
    leave:SetPoint("BOTTOMLEFT", 8, 8)
    leave:SetScript("OnClick", function() ns.SetSandbox(false) end)
    local leaveHint = K.NewLabel(p, L["To come back: /taverne dev on"], "GameFontDisableSmall")
    leaveHint:SetPoint("LEFT", leave, "RIGHT", 10, 0)

    function p:Refresh()
        guildText:SetText(L["Test guild: %s"]:format(ns.db.dev.guildName or "?"))
        gameChat:SetChecked(ns.db.dev.gameChat)
        lynxFast:SetChecked(ns.db.dev.lynxFast)
        watch:SetText(ns.IsChatWatching() and L["Stop the chat watch"] or L["Start the chat watch"])
        msgLog:SetText(ns.Comm:IsLogging() and L["Stop the message log"] or L["Start the message log"])
        fakeRunners:SetText(ns.Invites:HasFakeRunners() and L["Remove the fake inviters"] or L["Fake others inviting"])
    end
    return p
end
