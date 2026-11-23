-- The guild relay's page in La Taverne's window: its own small tab beside Alliance's, in
-- Advanced mode (Options); /taverne relay opens it too. The figures of Relay:WindowData(),
-- filled again every few seconds while it's shown:
-- - one card per guild of the alliance (mine first), a row per job: who holds it, their tier,
--   uptime this hour (a bar), budget, held back or refused; a line when one player holds several
--   jobs (their load, all jobs together); then the counts since login;
-- - below, folded until asked for: Your guild (me, each job's election as I see it, who can
--   relay), Your sending (what I send for the relay, the counts since login), Events.
-- Copy report: the same figures as text (Relay:ShowReport), to paste in a message.
-- Colors: green ok, orange worth a look, grey nobody / off. Tooltips give the details.
local ADDON, ns = ...
local L = ns.L

local COLORS = { ok = { 0.25, 1, 0.25 }, warn = { 1, 0.6, 0 }, off = { 0.6, 0.6, 0.6 } }
local function SetLevel(fs, level)
    local c = COLORS[level] or { 1, 1, 1 }
    fs:SetTextColor(c[1], c[2], c[3])
end

local function Kit() return ns.UIKit end

-- Tooltips: frame.tip = { title, lines... }.
local function TipEnter(self)
    if self.tip and #self.tip > 0 then Kit().ShowTooltip(self, self.tip) end
end
local function TipLeave() GameTooltip:Hide() end
local function WithTip(f)
    f:EnableMouse(true)
    f:SetScript("OnEnter", TipEnter)
    f:SetScript("OnLeave", TipLeave)
end

-- Pools: widgets made once, shown again at each fill.
local pools = {}
local function Take(kind, make)
    local pool = pools[kind]
    if not pool then
        pool = { list = {}, used = 0 }
        pools[kind] = pool
    end
    pool.used = pool.used + 1
    local w = pool.list[pool.used]
    if not w then
        w = make()
        pool.list[pool.used] = w
    end
    w:ClearAllPoints()
    w:Show()
    return w
end
local function ReleaseAll()
    for _, pool in pairs(pools) do
        for _, w in ipairs(pool.list) do w:Hide() end
        pool.used = 0
    end
end

-- Layout ---------------------------------------------------------------------------------------

local PAD, GAP = 4, 8
-- Job row columns inside a card: x and width.
local COL = { job = { 10, 100 }, holder = { 112, 250 }, up = { 368, 120 }, budget = { 500, 60 }, th = { 566, 110 } }
local ROW_H = 18

local function NewText(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(true)
    return fs
end

local function PlaceCol(fs, row, col)
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", row, "LEFT", COL[col][1], 0)
    fs:SetWidth(COL[col][2])
    fs:SetWordWrap(false)
end

local function MakeJobRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    WithTip(r)
    r.job = NewText(r)
    PlaceCol(r.job, r, "job")
    r.holder = NewText(r)
    PlaceCol(r.holder, r, "holder")
    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetPoint("LEFT", r, "LEFT", COL.up[1], 0)
    r.bar:SetSize(80, 8)
    r.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    r.bar:SetMinMaxValues(0, 100)
    local bg = r.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.1)
    r.upText = NewText(r)
    r.upText:SetPoint("LEFT", r.bar, "RIGHT", 6, 0)
    r.upText:SetWidth(COL.up[2] - 86)
    r.upText:SetWordWrap(false)
    r.budget = NewText(r)
    PlaceCol(r.budget, r, "budget")
    r.th = NewText(r)
    PlaceCol(r.th, r, "th")
    return r
end

local function MakeCard(parent)
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Kit().BoxBackdrop(c, { 0, 0, 0, 0.35 }, { 0.5, 0.5, 0.5, 1 })
    c.title = NewText(c, "GameFontNormal")
    c.title:SetPoint("TOPLEFT", 10, -9)
    c.badge = CreateFrame("Frame", nil, c)
    WithTip(c.badge)
    c.badge.text = NewText(c.badge, "GameFontHighlightSmall", "RIGHT")
    c.badge.text:SetPoint("RIGHT")
    c.badge:SetPoint("TOPRIGHT", -10, -9)
    c.badge:SetHeight(14)
    c.who = NewText(c)
    c.who:SetPoint("TOPLEFT", 10, -28)
    -- Column titles.
    c.head = CreateFrame("Frame", nil, c)
    c.head:SetHeight(14)
    c.head.cols = {}
    for key, text in pairs({ job = L["Job"], holder = L["Holder"], up = L["Up (this hour)"], budget = L["Budget"],
        th = L["Held back / refused"] }) do
        local fs = NewText(c.head, "GameFontDisableSmall")
        PlaceCol(fs, c.head, key)
        fs:SetText(text)
        c.head.cols[key] = fs
    end
    c.rows = {}
    return c
end

local function FillCard(c, card, width)
    c:SetWidth(width)
    c:SetBackdropBorderColor(unpack(card.mine and { 0.35, 0.55, 0.95, 1 } or { 0.5, 0.5, 0.5, 1 }))
    c.title:SetText(card.title)
    c.badge.text:SetText(card.badge or "")
    SetLevel(c.badge.text, card.badgeLevel)
    c.badge:SetWidth(math.max(20, c.badge.text:GetStringWidth()))
    c.badge.tip = card.badgeTip
    local y = 28
    if card.who then
        c.who:SetWidth(width - 20)
        c.who:SetText(card.who)
        SetLevel(c.who, card.whoLevel)
        c.who:Show()
        y = y + c.who:GetStringHeight() + 4
    else
        c.who:Hide()
    end
    for _, r in ipairs(c.rows) do r:Hide() end
    if card.empty then
        c.head:Hide()
        c:SetHeight(30)
        return 30
    end
    c.head:ClearAllPoints()
    c.head:SetPoint("TOPLEFT", 0, -y)
    c.head:SetPoint("RIGHT")
    c.head:Show()
    y = y + 16
    for i, row in ipairs(card.rows) do
        local r = c.rows[i] or MakeJobRow(c)
        c.rows[i] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -y)
        r:SetPoint("RIGHT")
        r.tip = row.tip
        r.job:SetText(row.label)
        r.holder:SetText(row.holder or "")
        SetLevel(r.holder, row.holderLevel)
        if row.up then
            r.bar:SetValue(row.up)
            local col = COLORS[row.upLevel] or COLORS.ok
            r.bar:SetStatusBarColor(col[1], col[2], col[3])
            r.bar:Show()
            r.upText:SetText(row.up .. "%")
        else
            r.bar:Hide()
            r.upText:SetText("")
        end
        r.budget:SetText(row.budget or "-")
        r.th:SetText(row.th and tostring(row.th) or "-")
        SetLevel(r.th, row.thLevel)
        r:Show()
        y = y + ROW_H
    end
    y = y + 8
    c:SetHeight(y)
    return y
end

local function MakeTile(parent)
    local t = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Kit().BoxBackdrop(t, { 1, 1, 1, 0.06 }, { 0.4, 0.4, 0.4, 1 })
    WithTip(t)
    t.value = NewText(t, "GameFontHighlightLarge")
    t.value:SetPoint("TOPLEFT", 10, -8)
    t.label = NewText(t, "GameFontDisableSmall")
    t.label:SetPoint("TOPLEFT", t.value, "BOTTOMLEFT", 0, -3)
    t.label:SetPoint("RIGHT", -6, 0)
    t:SetHeight(48)
    return t
end

local function MakeHeading(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.text = NewText(f, "GameFontNormal")
    f.text:SetPoint("TOPLEFT")
    f.hint = NewText(f, "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -2)
    return f
end

local LABEL_W = 170
local function MakeLine(parent)
    local f = CreateFrame("Frame", nil, parent)
    WithTip(f)
    f.label = NewText(f)
    f.label:SetPoint("TOPLEFT", 10, 0)
    f.label:SetWidth(LABEL_W - 14)
    f.label:SetTextColor(0.7, 0.7, 0.7)
    f.value = NewText(f)
    f.value:SetPoint("TOPLEFT", LABEL_W, 0)
    return f
end

-- Fill -----------------------------------------------------------------------------------------

local content -- the scroll child

local function Heading(y, width, text, hint)
    local h = Take("heading", function() return MakeHeading(content) end)
    h:SetPoint("TOPLEFT", 0, -y)
    h:SetWidth(width)
    h.text:SetWidth(width)
    h.hint:SetWidth(width)
    h.text:SetText(text)
    h.hint:SetText(hint or "")
    local height = h.text:GetStringHeight() + (hint and (h.hint:GetStringHeight() + 2) or 0)
    h:SetHeight(height)
    return y + height + 6
end

local function Lines(y, width, rows)
    for _, row in ipairs(rows) do
        local f = Take("line", function() return MakeLine(content) end)
        f:SetPoint("TOPLEFT", 0, -y)
        f:SetWidth(width)
        -- Widths set, not only anchored: the height of wrapped text is read right after.
        f.value:SetWidth(width - LABEL_W - 6)
        f.label:SetText(row.label or "")
        f.value:SetText(row.value or "")
        SetLevel(f.value, row.level)
        f.tip = row.tip
        local height = math.max(f.label:GetStringHeight(), f.value:GetStringHeight(), 12) + 4
        f:SetHeight(height)
        y = y + height
    end
    return y
end

local function Tiles(y, width, tiles)
    local n = #tiles
    if n == 0 then return y end
    local w = (width - GAP * (n - 1)) / n
    for i, tile in ipairs(tiles) do
        local t = Take("tile", function() return MakeTile(content) end)
        t:SetPoint("TOPLEFT", (i - 1) * (w + GAP), -y)
        t:SetWidth(w)
        t.value:SetText(tile.value or "")
        SetLevel(t.value, tile.level)
        t.label:SetText(tile.label or "")
        t.tip = tile.tip
    end
    return y + 48 + GAP
end

local function Sections(y, width, sections)
    for i, sec in ipairs(sections) do
        if i > 1 then y = y + 6 end
        y = Heading(y, width, sec.title, sec.hint)
        y = Lines(y, width, sec.rows)
    end
    return y
end

local function FillGuilds(data, width)
    local y = PAD
    if not data.active then
        return Lines(y, width, { { label = L["Relays"], value = L["No Guild Alliance: nothing to relay."], level = "off" } })
    end
    for _, card in ipairs(data.guilds) do
        local c = Take("card", function() return MakeCard(content) end)
        c:SetPoint("TOPLEFT", 0, -y)
        y = y + FillCard(c, card, width) + GAP
    end
    y = Heading(y + 4, width, L["Since you logged in"],
        L["The other guilds' figures come from their relay's signal, once a minute: no details of what the game refused them."])
    return Tiles(y, width, data.tiles)
end

-- A foldable part of the page: a gold header with the Alliance page's +/- (click: open or
-- fold), a thin line under it. open[key]: kept while the game runs.
local FOLD_OPEN = "|TInterface\\Buttons\\UI-MinusButton-Up:16:16|t "
local FOLD_CLOSED = "|TInterface\\Buttons\\UI-PlusButton-Up:16:16|t "
local SECTION_FONT = _G.GameFontNormalMed2 and "GameFontNormalMed2" or "GameFontNormal"
local open = {}
local Fill

local function MakeFold(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(22)
    b.text = NewText(b, SECTION_FONT)
    b.text:SetPoint("LEFT")
    b.text:SetWordWrap(false)
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetColorTexture(1, 0.82, 0, 0.25)
    b.line:SetHeight(1)
    b.line:SetPoint("BOTTOMLEFT")
    b.line:SetPoint("BOTTOMRIGHT")
    b:SetScript("OnClick", function(self)
        open[self.key] = not open[self.key]
        Fill()
    end)
    WithTip(b)
    return b
end

local function Fold(y, width, key, title, summary)
    local b = Take("fold", function() return MakeFold(content) end)
    b:SetPoint("TOPLEFT", 0, -y)
    b:SetWidth(width)
    b.key = key
    b.text:SetText((open[key] and FOLD_OPEN or FOLD_CLOSED) .. title
        .. (summary and summary ~= "" and ("  |cff808080" .. summary .. "|r") or ""))
    b.tip = { title, open[key] and L["Click to fold."] or L["Click to open."] }
    return y + 22 + 6, open[key]
end

local panel -- the page

Fill = function()
    if not (panel and panel:IsVisible()) then return end
    local data = ns.Relay:WindowData()
    ReleaseAll()
    local width = math.max(300, panel.scroll:GetWidth() - 4)
    content:SetWidth(width)
    -- The guilds and the counts since login, then the details, folded until asked for.
    local y = FillGuilds(data, width) + 6
    local shown
    y, shown = Fold(y, width, "mine", L["Your guild"], data.mineSummary)
    if shown then y = Sections(y, width, data.mine) + 10 end
    y, shown = Fold(y, width, "sending", L["Your sending"], data.sendingSummary)
    if shown then
        y = Tiles(y, width, data.sending.tiles)
        y = Sections(y, width, data.sending.sections) + 10
    end
    y, shown = Fold(y, width, "events", L["Events"], data.events[1] and (data.events[1].time .. "  " .. data.events[1].text))
    if shown then
        local rows = {}
        for _, e in ipairs(data.events) do rows[#rows + 1] = { label = e.time, value = e.text } end
        if #rows == 0 then rows[1] = { label = "", value = L["none yet"], level = "off" } end
        y = Lines(y, width, rows)
    end
    content:SetHeight(math.max(1, y + PAD))
    -- A tooltip open over the page: filled again with the new figures.
    local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
    if owner and owner.tip and owner:IsVisible() and owner:IsMouseOver() then TipEnter(owner) end
end

-- The page ---------------------------------------------------------------------------------------

function ns.BuildRelayPanel()
    local K = Kit()
    local p = K.NewPanel()
    panel = p
    K.NewPageTitle(p, L["Guild relay"], { L["Guild relay"],
        L["One La Taverne player per guild passes on its guild chat and map positions to the allied guilds, for the members without La Taverne."],
        L["Green: fine. Orange: worth a look. Grey: nobody, or nothing to relay."],
        L["Hover a row, a badge or a count for the details."] })
    -- Top right: Copy report.
    local copy = K.NewButton(p, L["Copy report"], 140, 24)
    copy:SetPoint("TOPRIGHT", -2, -4)
    K.WithTooltip(copy, { L["Copy report"], L["The same figures as text, to copy and paste in a message (Ctrl+C)."] })
    copy:SetScript("OnClick", function() ns.Relay:ShowReport() end)

    local scroll = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -40)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(680, 1)
    scroll:SetScrollChild(content)
    p.scroll = scroll

    -- Filled when shown (UI:Refresh), when the relay changes (the same), and every few seconds.
    p.Refresh = function() Fill() end
    local wait = 0
    p:SetScript("OnUpdate", function(_, elapsed)
        wait = wait - elapsed
        if wait > 0 then return end
        wait = ns.Relay.LIVE_EVERY or 3
        Fill()
    end)
    return p
end
