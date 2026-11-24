-- The boat's phone rings once for both players, and whoever answers takes the
-- call: it stops ringing in the other game (user 2026-11-21). The phone rings
-- by chance (RingChance) and when a log fragment unlocks; each game rolled its
-- own chance and rang at other times. The host's chance rings for both; the
-- guest's chance is off, its fragment rings still go to the host.
-- IsRinging is polled; OnAnswerPhone tells an answer from a ring that ended.
local M = {}

local CLASS = "BP_Module_Boat_Phone_C"
local ANSWER_FN = "/Game/Blueprints/Modules/Utility/BP_Module_Boat_Phone.BP_Module_Boat_Phone_C:OnAnswerPhone"
local POLL, FIND_EVERY, QUIET = 0.25, 5, 1

local net, log, now, isHost
local phonePath, lastFind, lastPoll = nil, -100, -100
local seenRinging, seenCounter
local quietUntil, answeredAt = 0, -100
local hooked, chanceOff = false, false

local function phone()
    local a = phonePath and StaticFindObject(phonePath)
    if a and a:IsValid() then return a end
    phonePath = nil
    if now() - lastFind < FIND_EVERY then return nil end
    lastFind = now()
    for _, x in ipairs(FindObjects(0, CLASS, "", 0, 0x30, false) or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__", 1, true) then
            phonePath = x:GetFullName():match("%S+%s+(%S+)")
            seenRinging, seenCounter = nil, nil
            return x
        end
    end
end

local function hook()
    if hooked then return end
    hooked = true
    local ok, err = pcall(RegisterHook, ANSWER_FN, function() answeredAt = now() end)
    log("telefon: krok på svar %s", ok and "ok" or tostring(err))
end

local function poll()
    lastPoll = now()
    local a = phone()
    if not a then return end
    hook()
    if not isHost() and not chanceOff then
        a.RingChance = 0
        chanceOff = true
        log("telefon: gästens slumpringning av, värden ringer för båda")
    end
    local ringing, counter = a.IsRinging, a.PlayCounter
    local wasRinging, wasCounter = seenRinging, seenCounter
    seenRinging, seenCounter = ringing, counter
    if wasRinging == nil or now() < quietUntil then return end
    if ringing and not wasRinging then
        net.send("phone", "ring")
        log("telefon ringer här, skickas")
    elseif wasRinging and not ringing then
        if now() - answeredAt < 3 or counter ~= wasCounter then
            net.send("phone", "answer", counter, a.LastRinged)
            log("telefon: svarade här (samtal %d), tystas hos den andra", counter)
        else
            net.send("phone", "stop")
            log("telefon slutade ringa här")
        end
    elseif counter ~= wasCounter then
        net.send("phone", "answer", counter, a.LastRinged)
    end
end

function M.init(netModule, logFn, nowFn, isHostFn)
    net, log, now, isHost = netModule, logFn, nowFn, isHostFn
end

function M.reset()
    phonePath, lastFind, lastPoll = nil, -100, -100
    seenRinging, seenCounter, quietUntil, answeredAt, chanceOff = nil, nil, 0, -100, false
end

function M.tick()
    if now() - lastPoll >= POLL then poll() end
end

function M.handle(msg)
    if msg[1] ~= "phone" then return false end
    local a = phone()
    if not a then log("telefon: %s från den andra, ingen telefon här", tostring(msg[3])) return true end
    quietUntil = now() + QUIET
    if msg[3] == "ring" then
        if not a.IsRinging then
            local ok, err = pcall(function() a:StartRinging() end)
            log("telefon ringer hos den andra: %s", ok and "ringer här också" or tostring(err))
        end
    else
        if a.IsRinging then pcall(function() a:StopRinging() end) end
        if msg[3] == "answer" then
            pcall(function()
                a.PlayCounter = tonumber(msg[4]) or a.PlayCounter
                a.LastRinged = tonumber(msg[5]) or a.LastRinged
            end)
        end
        log("telefon: %s hos den andra, tyst här", msg[3] == "answer" and "besvarad" or "slutade ringa")
    end
    return true
end

return M
