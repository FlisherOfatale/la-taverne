-- Error report: La Taverne's own Lua errors (and blocked actions) are kept, so a player can copy
-- a report and send it to the author. Options tab > Error report, or /taverne errors.
-- With BugGrabber installed, it owns the game's error handler: we listen to its event instead.
local ADDON, ns = ...
local Errors = ns.NewModule("Errors")
local L = ns.L

local MAX = 30
local pending = {}   -- errors caught before the saved variables are loaded
local warned = false -- one chat notice per session
local gamepadSkipped = false -- gamepad UI and the game's error window on at load: its handler left alone (below)

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function List()
    return ns.db and ns.db.errors or pending
end

local function Ours(message, stack)
    local text = tostring(message or "") .. "\n" .. tostring(stack or "")
    return text:find("AddOns[/\\]LaTaverne[/\\]") ~= nil
end

local function Record(message, stack)
    if IsSecret(message) or IsSecret(stack) then return end
    message, stack = tostring(message or "?"), tostring(stack or "")
    if not Ours(message, stack) then return end
    local list = List()
    local now = time()
    for _, e in ipairs(list) do
        if e.message == message then
            e.count = (e.count or 1) + 1
            e.last = now
            return
        end
    end
    list[#list + 1] = { message = message, stack = stack, count = 1, first = now, last = now, version = ns.version }
    while #list > MAX do table.remove(list, 1) end
    if not warned and ns.db then
        warned = true
        ns.Print("|cffff4040" .. L["An error happened. You can send the error report to the author: Options tab, Error report."] .. "|r")
    end
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function Errors:Count()
    return #List()
end

function Errors:Clear()
    wipe(List())
end

function Errors:Report()
    local version, build, _, toc = GetBuildInfo()
    local lines = {
        "La Taverne " .. tostring(ns.version) .. " - " .. date("%Y-%m-%d %H:%M"),
        "Game " .. tostring(version) .. " (" .. tostring(build) .. ", toc " .. tostring(toc) .. "), " .. GetLocale(),
        "Debug mode: " .. ((ns.Guild and ns.Guild:IsSandbox()) and "on" or "off"),
        "",
    }
    if gamepadSkipped then
        table.insert(lines, 4, "Gamepad UI and Lua error display on: Lua errors not kept (the game shows them), blocked actions only")
    end
    local list = List()
    if #list == 0 then
        lines[#lines + 1] = "No errors."
    end
    for i, e in ipairs(list) do
        lines[#lines + 1] = ("#%d  x%d  %s - %s  (v%s)"):format(i, e.count or 1,
            date("%Y-%m-%d %H:%M", e.first or 0), date("%H:%M", e.last or 0), tostring(e.version))
        lines[#lines + 1] = e.message
        if e.stack and e.stack ~= "" then lines[#lines + 1] = e.stack end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

function Errors:Show()
    ns.TextDialog({
        title = L["Error report"],
        hint = L["Press Ctrl+C to copy the report, then send it to the author of La Taverne."],
        text = self:Report(),
        selectAll = true,
    })
end

ns.commands.errors = function(arg)
    if (arg or ""):lower() == "clear" then
        Errors:Clear()
        ns.Print(L["Error report cleared."])
        return
    end
    Errors:Show()
end

-- Catching -------------------------------------------------------------------------------------

if _G.BugGrabber and EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("BugGrabber.BugGrabbed", function(_, id)
        local ok, e = pcall(BugGrabber.GetErrorByID, BugGrabber, id)
        if ok and type(e) == "table" then pcall(Record, e.message, e.stack) end
    end, Errors)
-- Not with the gamepad UI and the game's error window (scriptErrors) both on. The game's handler
-- runs on the erroring code's stack: an error from an addon's code opens that window from the
-- addon's code anyway, with or without our handler, but ours would also taint the errors from the
-- game's own code (the gamepad manager follows the window: protected calls blocked). The window
-- only opens with scriptErrors on (Blizzard_ScriptErrorsFrame.lua, ShouldHideErrorFrame); with
-- it off (the default), the report keeps Lua errors, gamepad or not. Blocked actions are always
-- kept. Decided once, when this file loads: the sources don't prove the style is already known
-- then (C_InputInterfaceStyle), and changing the style or scriptErrors needs a /reload.
elseif geterrorhandler and seterrorhandler and ns.GamepadUI()
    and GetCVarBool and GetCVarBool("scriptErrors") then
    gamepadSkipped = true
elseif geterrorhandler and seterrorhandler then
    local previous = geterrorhandler()
    seterrorhandler(function(message, ...)
        pcall(Record, message, debugstack and debugstack(3) or "")
        if previous then return previous(message, ...) end
    end)
end

for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    ns.On(event, function(addon, fn)
        if addon == ADDON then
            Record(event .. ": " .. tostring(fn), "AddOns/LaTaverne/ (blocked action)\n" .. (debugstack and debugstack(2) or ""))
        end
    end)
end

function Errors:OnInit()
    ns.db.errors = ns.db.errors or {}
    -- A new version starts with an empty report: errors kept from another version are dropped.
    for i = #ns.db.errors, 1, -1 do
        if ns.db.errors[i].version ~= ns.version then table.remove(ns.db.errors, i) end
    end
    for _, e in ipairs(pending) do ns.db.errors[#ns.db.errors + 1] = e end
    wipe(pending)
end
