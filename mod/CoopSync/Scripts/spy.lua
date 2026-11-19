-- Finds out which game functions an action uses: hooks every function in
-- spion_funktioner.txt, learns what runs while idle, then logs only the rest.
local M = {}

local LIST = "ue4ss/Mods/CoopSync/spion_funktioner.txt"
local BASELINE_SECONDS = 20

local log
local phase = "av"
local baseline, counts, hooked, pending = {}, {}, {}, {}
local startedAt = 0

local function short(path)
    return (path:gsub("^/Script/Voyage%.", ""):gsub("^/Game/.-%.", ""))
end

local function onCall(path)
    local n = (counts[path] or 0) + 1
    counts[path] = n
    if phase == "baslinje" then
        baseline[path] = true
    elseif phase == "spanar" and not baseline[path] then
        if n <= 3 or n % 50 == 0 then log("SPY %s #%d", short(path), n) end
    end
end

local function tryHook(path)
    local fn = StaticFindObject(path)
    if not (fn and fn:IsValid()) then return false end
    local ok = pcall(RegisterHook, path, function() onCall(path) end)
    if ok then hooked[#hooked + 1] = path end
    return true
end

-- Blueprint classes load on demand (the placement component only when the
-- build tool is used), so missing functions are retried.
local function retryPending()
    local still = {}
    for _, path in ipairs(pending) do
        if not tryHook(path) then still[#still + 1] = path end
    end
    local added = #pending - #still
    pending = still
    if added > 0 then log("SPY: %d nya hookar (totalt %d, väntar %d)", added, #hooked, #pending) end
end

function M.start(logFn, list)
    if phase ~= "av" then return end
    log = logFn
    list = list or LIST
    local f = io.open(list, "r")
    if not f then log("SPY: hittar inte %s", list) return end
    for line in f:lines() do
        local path = line:match("^%s*(.-)%s*$")
        if path ~= "" and not tryHook(path) then pending[#pending + 1] = path end
    end
    f:close()
    phase, startedAt = "baslinje", os.time()
    log("SPY: %d hookade, %d väntar; baslinje i %d s", #hooked, #pending, BASELINE_SECONDS)
end

function M.tick()
    if phase == "av" then return end
    if phase == "baslinje" and os.time() - startedAt >= BASELINE_SECONDS then
        local n = 0
        for _ in pairs(baseline) do n = n + 1 end
        phase = "spanar"
        log("SPY: baslinje klar (%d funktioner körs i vila), spanar nu", n)
    end
    if os.time() % 10 == 0 and #pending > 0 then retryPending() end
end

function M.mark(text)
    if log then log("SPY ---- %s ----", text) end
end

return M
