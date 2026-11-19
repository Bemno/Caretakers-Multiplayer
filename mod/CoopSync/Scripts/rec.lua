-- Recording an action for the test bench (testbank/motor/uppspela.lua). The
-- host hooks the functions in spion_funktioner.txt once the world has settled
-- and keeps track of what runs while nobody records. F7 starts at once: the
-- screen edge turns red and every call not seen in the last BASELINE_SECONDS
-- is recorded with its arguments and a snapshot of each object it touches. F7 again stops, writes
-- io/host/inspelning_<name>.txt (the calls, and per object the fields the
-- action changed) and tells the guest, which replays it on its own.
local M = {}

local LIST = "ue4ss/Mods/CoopSync/spion_funktioner.txt"
local BASELINE_SECONDS = 15
-- Learning the idle calls only after the key press left 15 s without any sign,
-- and a second press then cancelled (2026-11-15).
local HOOK_AFTER = 60
local MAX_CALLS, MAX_OBJECTS = 400, 60
local LOW_HEALTH = 3        -- EVoyageCharacterWarning: the red pulsing edge

local log, localPC, net, isHost, ioName
local R = { hooked = false, phase = "av", baseline = {}, calls = {}, before = {}, objects = {}, params = {}, nObjects = 0 }
M.state = R

local ACTOR, ACOMP, WIDGET, PERSIST, INV
local function classes()
    ACTOR = ACTOR or StaticFindObject("/Script/Engine.Actor")
    ACOMP = ACOMP or StaticFindObject("/Script/Engine.ActorComponent")
    WIDGET = WIDGET or StaticFindObject("/Script/UMG.Widget")
    PERSIST = PERSIST or StaticFindObject("/Script/Voyage.VoyagePersistentActorComponent")
    INV = INV or StaticFindObject("/Script/Voyage.VoyageBaseInventoryComponent")
end

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end

-- How the guest finds the same object: save id, else the level path (the same
-- in both games), with the component name for components; assets by path.
local function keyOf(o)
    if not (o and o:IsValid()) then return nil end
    local actor, comp = nil, nil
    if o:IsA(ACTOR) then actor = o elseif o:IsA(ACOMP) then actor, comp = o:GetOwner(), o end
    if actor and actor:IsValid() then
        local key
        local pc = actor:GetComponentByClass(PERSIST)
        local id = pc and pc:IsValid() and pc.PersistentUniqueId
        if id and id ~= 0 then key = "i" .. tostring(id) else key = "p" .. pathOf(actor) end
        if comp then key = key .. "#" .. comp:GetFName():ToString() end
        return key
    end
    local p = pathOf(o)
    if p:find(":PersistentLevel", 1, true) then return "o" .. p end
    return "a" .. p
end

local function scalar(v)
    local t = type(v)
    if t == "boolean" then return v and "b1" or "b0" end
    if t == "number" then return "n" .. tostring(v) end
    if t == "string" then return "s" .. v end
    if t == "userdata" then
        -- A struct comes back as its type (ScriptStruct ...); its value
        -- cannot be written down, and replaying the type crashed the guest.
        local okT, full = pcall(function() return v:GetFullName() end)
        if okT and type(full) == "string" and full:find("^ScriptStruct ") then return "?" end
        local okO, key = pcall(function() if v.IsValid and v:IsValid() and v.GetFullName then return keyOf(v) end end)
        if okO and key then return "u" .. key end
        local okV, vec = pcall(function()
            if v.Pitch ~= nil then return string.format("r%.3f,%.3f,%.3f", v.Pitch, v.Yaw, v.Roll) end
            if v.X ~= nil and v.Y ~= nil and v.Z ~= nil then return string.format("v%.3f,%.3f,%.3f", v.X, v.Y, v.Z) end
        end)
        if okV and vec then return vec end
        local okS, s = pcall(function() return v:ToString() end)
        if okS and type(s) == "string" then return "t" .. s end
    end
    return "?"
end

-- Maps (an item -> count list, as AddItems takes) and arrays are written out
-- element by element.
local function encode(v)
    if type(v) == "userdata" then
        local parts, isMap = {}, nil
        local okM = pcall(function()
            v:ForEach(function(k, val)
                if type(k) == "number" then
                    -- TArray: (index, element)
                    local ev
                    pcall(function() ev = val:get() end)
                    parts[#parts + 1] = scalar(ev)
                    return
                end
                local kv, vv
                pcall(function() kv = k:get() end)
                pcall(function() vv = val:get() end)
                if vv ~= nil then
                    isMap = true
                    parts[#parts + 1] = scalar(kv) .. "=" .. scalar(vv)
                else
                    parts[#parts + 1] = scalar(kv)
                end
            end)
        end)
        if okM and #parts > 0 then return (isMap and "m" or "l") .. table.concat(parts, ";") end
    end
    return scalar(v)
end

-- Simple reflected fields of an object, and for actors their inventories.
local function snapshot(o)
    local out, seen = {}, {}
    local cls = o:GetClass()
    while cls and cls:IsValid() do
        pcall(function()
            cls:ForEachProperty(function(prop)
                local name = prop:GetFName():ToString()
                if seen[name] then return end
                seen[name] = true
                local ok, v = pcall(function() return o[name] end)
                if not ok then return end
                local tv = type(v)
                if tv == "boolean" or tv == "string" then out[name] = tostring(v)
                elseif tv == "number" then out[name] = string.format("%.2f", v)
                elseif tv == "userdata" then
                    local okS, s = pcall(function()
                        if v.IsValid and v:IsValid() and v.GetFullName then return keyOf(v) end
                        if v.ToString then return v:ToString() end
                    end)
                    if okS and s then out[name] = tostring(s) end
                end
            end)
        end)
        local okS, sup = pcall(function() return cls:GetSuperStruct() end)
        cls = okS and sup or nil
    end
    if o:IsA(ACTOR) then
        pcall(function()
            for _, e in ipairs(o:K2_GetComponentsByClass(INV) or {}) do
                local inv = e
                pcall(function() inv = e:get() end)
                local okA, all = pcall(function() return inv:GetAllItems() end)
                for _, ie in ipairs((okA and type(all) == "table" and all) or {}) do
                    local it = ie
                    pcall(function() it = ie:get() end)
                    if it:IsValid() then
                        out["inv:" .. inv:GetFName():ToString() .. ":" .. it:GetFName():ToString()] = tostring(inv:GetNumItems(it))
                    end
                end
            end
        end)
    end
    return out
end

local function note(o)
    local key = keyOf(o)
    if not key or R.before[key] or R.nObjects >= MAX_OBJECTS then return end
    if key:sub(1, 1) == "a" then return end
    R.nObjects = R.nObjects + 1
    R.before[key] = snapshot(o)
    R.objects[key] = pathOf(o)
end

local lastSeen = {}

local function onCall(path, ctx, ...)
    if R.phase ~= "in" then lastSeen[path] = os.clock() return end
    if R.phase ~= "in" or R.baseline[path] or #R.calls >= MAX_CALLS then return end
    local self = ctx:get()
    if not (self and self:IsValid()) or (WIDGET and self:IsA(WIDGET)) then return end
    local key = keyOf(self)
    if not key then return end
    -- UE4SS 4 has no property flags in Lua; the hook hands over exactly the
    -- parameters, in order (out parameters with their incoming value).
    local args, raw = {}, { ... }
    for i = 1, select("#", ...) do
        local v
        pcall(function() v = raw[i]:get() end)
        args[i] = encode(v)
        if type(v) == "userdata" then pcall(note, v) end
    end
    pcall(note, self)
    R.calls[#R.calls + 1] = { t = os.clock() - R.t0, fn = path, self = key, args = args }
end

-- Blueprint classes load when first used (the scanner only once it is
-- equipped), so functions not found yet are tried again now and then.
local pending = {}
local function tryHook(path)
    local fn = StaticFindObject(path)
    if not (fn and fn:IsValid()) then return false end
    local ok = pcall(RegisterHook, path, function(ctx, ...) pcall(onCall, path, ctx, ...) end)
    if ok then R.nHooked = R.nHooked + 1 end
    return true
end

local function hookAll()
    if R.hooked then return R.nHooked end
    R.hooked, R.nHooked, R.hookedAt = true, 0, os.clock()
    local f = io.open(LIST, "r")
    if not f then return 0 end
    for line in f:lines() do
        local path = line:match("^%s*(.-)%s*$")
        if path ~= "" and not path:find("Tick", 1, true) and not tryHook(path) then pending[#pending + 1] = path end
    end
    f:close()
    return R.nHooked
end

-- Looking all of them up at once froze the host for 2 s every 10 s; a few
-- are tried each second instead.
local lastRetry, cursor = 0, 1
local RETRY_BATCH = 2
local function retryPending()
    -- Each try registers a hook (about 17 ms); the ones still failing after two
    -- minutes never load, and retrying them stalled the host's frame every
    -- second for the whole session (2026-11-17).
    if #pending == 0 or os.clock() - lastRetry < 1 or os.clock() - R.hookedAt > 120 then return end
    lastRetry = os.clock()
    local added, i, tried = 0, cursor, 0
    while tried < RETRY_BATCH and #pending > 0 do
        if i > #pending then i = 1 end
        if tryHook(pending[i]) then
            table.remove(pending, i)
            added = added + 1
        else
            i = i + 1
        end
        tried = tried + 1
    end
    cursor = i
    if added > 0 then log("inspelning: %d nya funktioner hookade (totalt %d, väntar %d)", added, R.nHooked, #pending) end
end

local function edge(on)
    pcall(function()
        local p = localPC().Pawn
        if on then p:AddOrUpdateCharacterWarning(LOW_HEALTH, 1.0)
        elseif p:HasCharacterWarning(LOW_HEALTH) then p:RemoveCharacterWarning(LOW_HEALTH) end
    end)
end

local function begin()
    R.baseline = {}
    local b = 0
    for path, t in pairs(lastSeen) do
        if os.clock() - t < BASELINE_SECONDS then R.baseline[path] = true b = b + 1 end
    end
    R.calls, R.before, R.objects, R.nObjects, R.t0 = {}, {}, {}, 0, os.clock()
    R.phase = "in"
    edge(true)
    log("inspelning %s: %d körs i vila och räknas bort, SPELAR IN", R.name, b)
end

function M.start(name)
    classes()
    R.name = name or os.date("%H%M%S")
    if R.hooked and os.clock() - R.hookedAt >= BASELINE_SECONDS then return begin() end
    -- Pressed before the background hooks had learned anything.
    local n = hookAll()
    R.phase, R.baseAt = "bas", os.clock()
    log("inspelning %s: %d funktioner hookade, lär mig vad som körs i vila i %d s", R.name, n, BASELINE_SECONDS)
end

function M.stop()
    if R.phase == "av" then return end
    local wasRecording = R.phase == "in"
    R.phase = "av"
    edge(false)
    if not wasRecording then log("inspelning %s: avbruten under baslinjen", R.name) return end
    local lines = { "# inspelning " .. R.name }
    local fnCount, order = {}, {}
    for _, c in ipairs(R.calls) do
        lines[#lines + 1] = table.concat({ "C", string.format("%.2f", c.t), c.fn, c.self, table.concat(c.args, "\t") }, "|")
        local short = c.fn:match("[^%.]+$")
        if not fnCount[short] then order[#order + 1] = short end
        fnCount[short] = (fnCount[short] or 0) + 1
    end
    local changed = 0
    for key, before in pairs(R.before) do
        local o = StaticFindObject(R.objects[key])
        local after = (o and o:IsValid()) and snapshot(o) or { ["(borta)"] = "true" }
        for field, v in pairs(after) do
            if before[field] ~= v then
                lines[#lines + 1] = table.concat({ "S", key, field, tostring(before[field]), v }, "|")
                changed = changed + 1
            end
        end
        for field, v in pairs(before) do
            if after[field] == nil and not after["(borta)"] then
                lines[#lines + 1] = table.concat({ "S", key, field, v, "nil" }, "|")
                changed = changed + 1
            end
        end
    end
    local path = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/inspelning_" .. R.name .. ".txt"
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(lines, "\n"), "\n")
        f:close()
    end
    log("inspelning klar %s: %d anrop, %d föremål, %d ändrade fält -> %s", R.name, #R.calls, R.nObjects, changed, path)
    for i = 1, math.min(#order, 30) do log("inspelning %s:   %3d  %s", R.name, fnCount[order[i]], order[i]) end
    net.send("recdone", R.name)
    return #R.calls, changed
end

local pawnSince
function M.tick()
    if isHost and not R.hooked then
        local ok, valid = pcall(function() return localPC().Pawn:IsValid() end)
        if ok and valid then
            pawnSince = pawnSince or os.clock()
            if os.clock() - pawnSince >= HOOK_AFTER then
                classes()
                log("inspelning: %d funktioner hookade, F7 spelar in direkt", hookAll())
            end
        else
            pawnSince = nil
        end
    end
    if R.hooked and R.phase ~= "in" then retryPending() end
    if R.phase == "bas" and os.clock() - R.baseAt >= BASELINE_SECONDS then begin() end
    -- The game clears the warning when health is fine; it is put back.
    if R.phase == "in" then edge(true) end
end

-- Guest: replays with the bench's uppspela.lua (put in Mods\CoopSync\bank by
-- installera-testkopia.cmd) through the mod's own command file.
local function replay(name)
    local function read(p)
        local f = io.open("ue4ss/Mods/CoopSync/bank/" .. p, "r")
        if not f then return nil end
        local s = f:read("a")
        f:close()
        return s
    end
    local steg, upp = read("steg.lua"), read("uppspela.lua")
    if not (steg and upp) then log("uppspelning %s: bank/steg.lua eller uppspela.lua saknas", name) return end
    local src = "ONLY = ''\nNAMN = '" .. name:gsub("'", "") .. "'\n" .. steg .. "\n" .. upp
    local cmdPath = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/cmd.lua"
    local f = io.open(cmdPath .. ".tmp", "w")
    if not f then return end
    f:write(src)
    f:close()
    os.remove(cmdPath)
    os.rename(cmdPath .. ".tmp", cmdPath)
    log("uppspelning %s startad", name)
end

function M.handle(msg)
    if msg[1] ~= "recdone" then return false end
    if not isHost then replay(msg[3]) end
    return true
end

-- Key presses reach every running copy of the game, whichever has focus; only
-- the host records.
local function toggle()
    if not isHost then return end
    if R.phase == "av" then M.start() else M.stop() end
end

function M.init(logFn, localPCFn, netModule, host, io)
    log, localPC, net, isHost, ioName = logFn, localPCFn, netModule, host, io
    if M.keyBound then return end
    M.keyBound = true
    local ok, err = pcall(RegisterKeyBind, Key.F7, function()
        ExecuteInGameThread(function()
            local okT, errT = pcall(toggle)
            if not okT then log("inspelning: %s", tostring(errT)) end
        end)
    end)
    log("inspelning: F7 %s", ok and "ok" or tostring(err))
end

return M
