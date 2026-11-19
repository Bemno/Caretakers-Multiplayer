-- The head lamp. The game toggles it in C++ (no hookable function on the
-- key), so the own lamp's SpotLight is polled and its state sent (lamp); the
-- other game shows a spot light on the puppet's head, with the lamp's own
-- intensity, cone, reach and colour.
local M = {}

local POLL_EVERY = 0.25
local FIND_EVERY = 5
local HEAD_UP, HEAD_AHEAD, PITCH = 160, 20, -10

local net, log, localPC, now, console, puppetFn
local lampPath, lastFind, lastPoll = nil, -100, -100
local sentState
local shown = { path = nil, pending = nil, on = false, params = nil }

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

-- The own lamp: a SpotLightComponent on a headlight actor fastened to the
-- own pawn.
local function findLamp()
    lastFind = now()
    lampPath = nil
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local ok, found = pcall(FindObjects, 0, "SpotLightComponent", "", 0, 0x10, false)
    for _, c in ipairs((ok and found) or {}) do
        local okC, hit = pcall(function()
            if not c:IsValid() then return false end
            local o = c:GetOwner()
            if not (o and o:IsValid()) then return false end
            if not o:GetClass():GetFName():ToString():find("Headlight", 1, true) then return false end
            local pa = o:GetAttachParentActor()
            return pa and pa:IsValid() and pa:GetAddress() == pawn:GetAddress()
        end)
        if okC and hit then lampPath = pathOf(c) return end
    end
end

local function f2(v) return string.format("%.2f", tonumber(v) or 0) end

local function poll()
    lastPoll = now()
    if not lampPath or now() - lastFind >= FIND_EVERY then findLamp() end
    local c = lampPath and StaticFindObject(lampPath)
    local on, params = false, {}
    if c and c:IsValid() then
        local okV, v = pcall(function() return c:IsVisible() and (c.Intensity or 0) > 0 end)
        on = okV and v or false
        if on then
            pcall(function()
                local col = c.LightColor
                params = { f2(c.Intensity), f2(c.OuterConeAngle), f2(c.InnerConeAngle), f2(c.AttenuationRadius),
                    tostring(col.R or 255), tostring(col.G or 255), tostring(col.B or 255) }
            end)
        end
    end
    local state = on and ("1|" .. table.concat(params, "|")) or "0"
    if state ~= sentState then
        sentState = state
        if on then net.send("lamp", "1", table.unpack(params)) else net.send("lamp", "0") end
        log("lampa: %s", on and "på" or "av")
    end
end

-- The other player's lamp ----------------------------------------------------

local function listSpots()
    local set = {}
    local ok, found = pcall(FindObjects, 0, "SpotLight", "", 0, 0x10, false)
    for _, a in ipairs((ok and found) or {}) do pcall(function() set[a:GetAddress()] = a end) end
    return set
end

local function applyShown()
    local puppet = puppetFn()
    if not (puppet and puppet:IsValid()) then return end
    local a = shown.path and StaticFindObject(shown.path)
    if not (a and a:IsValid()) then
        if not shown.on then return end
        if shown.pending and now() - shown.pending.t < 3 then
            for addr, s in pairs(listSpots()) do
                if not shown.pending.before[addr] and not s:GetFullName():find("Default__", 1, true) then
                    shown.path, shown.pending = pathOf(s), nil
                    a = s
                    break
                end
            end
            if not a then return end
        else
            shown.pending = { before = listSpots(), t = now() }
            console("summon SpotLight")
            return
        end
    end
    local l = a.LightComponent or a.SpotLightComponent
    if not (l and l:IsValid()) then return end
    local pa
    pcall(function() pa = a:GetAttachParentActor() end)
    if not (pa and pa:IsValid() and pa:GetAddress() == puppet:GetAddress()) then
        pcall(function() l:SetMobility(2) end)
        pcall(function() a.RootComponent:SetMobility(2) end)
        a:K2_AttachToActor(puppet, FName("None"), 0, 0, 0, false)
        -- The puppet's character looks along the actor's right vector.
        a.RootComponent:K2_SetRelativeLocationAndRotation({ X = 0, Y = HEAD_AHEAD, Z = HEAD_UP },
            Rot(PITCH, 90, 0), false, {}, true)
        log("lampa: kompisens lampa fäst vid dockan")
    end
    local p = shown.params
    if p then
        pcall(function() l:SetIntensity(p[1]) end)
        pcall(function() l:SetOuterConeAngle(p[2]) end)
        pcall(function() l:SetInnerConeAngle(p[3]) end)
        pcall(function() l:SetAttenuationRadius(p[4]) end)
        pcall(function() l:SetLightColor({ R = p[5] / 255, G = p[6] / 255, B = p[7] / 255, A = 1 }, true) end)
    end
    pcall(function() l:SetVisibility(shown.on, false) end)
    shown.dirty = false
end

function M.init(netModule, logFn, localPCFn, nowFn, consoleFn, puppetFunction)
    net, log, localPC, now, console, puppetFn = netModule, logFn, localPCFn, nowFn, consoleFn, puppetFunction
end

function M.reset()
    lampPath, lastFind, lastPoll, sentState = nil, -100, -100, nil
    shown = { path = nil, pending = nil, on = false, params = nil }
end

function M.tick()
    if now() - lastPoll >= POLL_EVERY then poll() end
    if shown.dirty or shown.pending or (shown.on and not shown.path) then
        local ok, err = pcall(applyShown)
        if not ok then log("lampa-fel: %s", tostring(err)) shown.dirty = false end
    end
end

function M.handle(msg)
    if msg[1] ~= "lamp" then return false end
    shown.on = msg[3] == "1"
    if shown.on then
        shown.params = {}
        for i = 4, 10 do shown.params[#shown.params + 1] = tonumber(msg[i]) or 0 end
    end
    shown.dirty = true
    return true
end

return M
