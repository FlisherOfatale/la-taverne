-- Runs the relay simulator's scenarios (tests/sim). From the repo root:
--   luajit tests/run.lua                 every scenario, seeds 1 to 3
--   luajit tests/run.lua --seeds 10      seeds 1 to 10
--   luajit tests/run.lua --seed 7 --only "busy" --trace    one seed, one scenario, every event
-- Needs Lua 5.1 or LuaJIT (the game's Lua). Exit code 1 when a scenario fails.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/sim/?.lua;" .. package.path

local seeds, first, only, trace, verbose = 3, 1, nil, false, false
local i = 1
while arg and arg[i] do
    local a = arg[i]
    if a == "--seeds" then seeds = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--seed" then first, seeds = tonumber(arg[i + 1]), 1; i = i + 1
    elseif a == "--only" then only = arg[i + 1]:lower(); i = i + 1
    elseif a == "--trace" then trace = true
    elseif a == "-v" then verbose = true
    else
        io.stderr:write("unknown option " .. a .. "\n")
        os.exit(2)
    end
    i = i + 1
end

local scenarios = require("scenarios")
local addonDir = here .. "/../LaTaverne"
local failed, known = 0, 0
local started = os.clock()

local function Figures(rec)
    local keys = {}
    for k in pairs(rec.by) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local r = rec.by[k]
        print(string.format("      %-12s two holders max %3d s, no holder max %3d s (%4.1f %%), split max %3d s, "
            .. "unseen by allies max %3d s, changes %d", k, r.maxDual, r.maxGap,
            r.eligibleTotal > 0 and 100 * r.gapTotal / r.eligibleTotal or 0, r.maxSplit, r.maxHidden, r.changes))
        -- When each longest streak ended (simulated time, as --trace prints it).
        print(string.format("      %-12s ended at: two holders %s, no holder %s, split %s, unseen %s", "",
            tostring(r.maxDualAt), tostring(r.maxGapAt), tostring(r.maxSplitAt), tostring(r.maxHiddenAt)))
    end
end

for _, s in ipairs(scenarios) do
    if not only or s.name:lower():find(only, 1, true) then
        for seed = first, first + seeds - 1 do
            local ok, fails, rec = pcall(s.run, seed, { addonDir = addonDir, trace = trace })
            local crashed = not ok
            if crashed then fails, rec = { "crashed: " .. tostring(fails) }, nil end
            local bad = #fails > 0
            local isKnown = s.known and not crashed -- a crash always fails
            local label = not bad and "ok   " or (isKnown and "KNOWN" or "FAIL ")
            print(string.format("%s %s (seed %d)", label, s.name, seed))
            if bad then
                if isKnown then known = known + 1 else failed = failed + 1 end
                if isKnown and seed == first then print("      " .. s.about) end
                for _, f in ipairs(fails) do print("      " .. f) end
            end
            if rec and (verbose or (bad and not isKnown)) then Figures(rec) end
        end
    end
end

print(string.format("\n%d failed, %d known limitations (%.1f s)", failed, known, os.clock() - started))
os.exit(failed > 0 and 1 or 0)
