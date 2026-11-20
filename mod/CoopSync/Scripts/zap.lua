-- The electric pistol's lightning. A shot shows the weapon's ray spline meshes
-- (RaysCyl) for about 0.1 s, with start and end in world space (from the
-- muzzle to where the bolts strike; tested 2026-11-18). The firing game polls
-- them every frame and sends the rays of each shot; the other game draws the
-- same rays from spline meshes of its own for as long.
local M = {}
local net, log, localPC, now

local SPLINE_CLASS = "/Script/Engine.SplineMeshComponent"
local REFRESH_SECONDS, SHOW_SECONDS = 2, 0.12

local rays, lastRefresh = {}, -100   -- own weapon's ray component paths
local wasVisible = false
local lastSentAt = 0

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end
local UEHelpers = require("UEHelpers")
local function v3(v) return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z) end

function M.init(netModule, logFn, localPCFn, nowFn)
    net, log, localPC, now = netModule, logFn, localPCFn, nowFn
end

local function refresh()
    lastRefresh = now()
    rays = {}
    local okG, gear = pcall(require, "gear")
    if not okG then return end
    for _, path in ipairs(gear.weaponPaths or {}) do
        local a = StaticFindObject(path)
        if a and a:IsValid() then
            for _, e in ipairs(a:K2_GetComponentsByClass(StaticFindObject(SPLINE_CLASS)) or {}) do
                local c = e.get and e:get() or e
                rays[#rays + 1] = pathOf(c)
            end
        end
    end
end

-- Sending: every frame, cheap (a visibility read per ray).
local function poll()
    if now() - lastRefresh >= REFRESH_SECONDS then refresh() end
    if #rays == 0 then wasVisible = false return end
    local visible, parts, material, mesh = false, {}, nil, nil
    for _, path in ipairs(rays) do
        local c = StaticFindObject(path)
        if c and c:IsValid() and c:IsVisible() then
            visible = true
            -- The rays' thickness and axis too: without them the copies were
            -- drawn at scale 1, a broad sheet out of the puppet (2026-11-18).
            local ss, es, ws = c:GetStartScale(), c:GetEndScale(), c:K2_GetComponentScale()
            parts[#parts + 1] = table.concat({ v3(c:GetStartPosition()), v3(c:GetStartTangent()),
                v3(c:GetEndPosition()), v3(c:GetEndTangent()),
                string.format("%.4f,%.4f,%.4f,%.4f,%d", ss.X, ss.Y, es.X, es.Y, c:GetForwardAxis()),
                string.format("%.4f,%.4f,%.4f", ws.X, ws.Y, ws.Z) }, ",")
            if not mesh then
                mesh = c.StaticMesh and c.StaticMesh:IsValid() and pathOf(c.StaticMesh)
                local m = c:GetMaterial(0)
                material = m and m:IsValid() and pathOf(m)
            end
        end
    end
    -- A new shot, or the rays moved while the trigger is held.
    if visible and (not wasVisible or now() - lastSentAt >= 0.1) then
        lastSentAt = now()
        net.send("zap", mesh or "-", material or "-", table.concat(parts, ";"))
    end
    wasVisible = visible
end

-- Muzzle flashes of the projectile weapons. Each shot adds a sound component
-- to the held weapon (bolt sniper, 2026-11-18); the flash itself is a Niagara
-- system spawned loose in the world, so at a shot the effect next to the
-- weapon is looked up once per weapon class (a walk over all objects) and
-- remembered with its place relative to the weapon.
local AUDIO_CLASS = "/Script/Engine.AudioComponent"
local FX_RELEARN = 20
local held, heldSounds = nil, -1
local flashOf = {}         -- weapon class -> { path, loc, rot (relative to the weapon), t }

local function heldWeapon()
    local okG, gear = pcall(require, "gear")
    if not okG then return nil end
    for _, path in ipairs(gear.weaponPaths or {}) do
        local a = StaticFindObject(path)
        if a and a:IsValid() and a.RootComponent:GetAttachSocketName():ToString():find("hand", 1, true) then return a end
    end
end

local function learnFlash(a, cls)
    local kml = UEHelpers.GetKismetMathLibrary()
    local wt = a:GetTransform()
    local wl = a:K2_GetActorLocation()
    local best, bestD
    for _, c in ipairs(FindObjects(0, "NiagaraComponent", "", 0, 0x10, false) or {}) do
        pcall(function()
            if not c:IsValid() then return end
            local sys = c:GetAsset()
            local name = sys and sys:IsValid() and sys:GetFName():ToString() or ""
            if not (name:find("Muzzle", 1, true)) then return end
            local l = c:K2_GetComponentLocation()
            local d = math.sqrt((l.X - wl.X) ^ 2 + (l.Y - wl.Y) ^ 2 + (l.Z - wl.Z) ^ 2)
            if d < 300 and (not bestD or d < bestD) then
                best = { path = pathOf(sys), loc = kml:InverseTransformLocation(wt, l),
                    rot = kml:InverseTransformRotation(wt, c:K2_GetComponentRotation()), t = now() }
                bestD = d
            end
        end)
    end
    if best then
        flashOf[cls] = best
        log("blixt: %s mynning %s", cls, best.path:match("[^.]+$"))
    end
end

local function pollShots()
    local a = heldWeapon()
    if not a then held, heldSounds = nil, -1 return end
    local n = #(a:K2_GetComponentsByClass(StaticFindObject(AUDIO_CLASS)) or {})
    local addr = a:GetAddress()
    if held ~= addr then held, heldSounds = addr, n return end
    if n <= heldSounds then heldSounds = n return end
    heldSounds = n
    local cls = a:GetClass():GetFName():ToString()
    if cls:find("Electric", 1, true) then return end
    local f = flashOf[cls]
    if not f or now() - f.t > FX_RELEARN then learnFlash(a, cls) f = flashOf[cls] end
    if not f then return end
    local kml = UEHelpers.GetKismetMathLibrary()
    local wt = a:GetTransform()
    local l = kml:TransformLocation(wt, f.loc)
    local r = kml:TransformRotation(wt, f.rot)
    -- UE4SS 4.0 returns a rotator's pitch as "pitch" (Yaw and Roll as named).
    net.send("fx", f.path, v3(l), string.format("%.1f,%.1f,%.1f", r.pitch or RotP(r) or 0, r.Yaw or 0, r.Roll or 0))
end

-- Effects on the held weapon (the flamethrower's flame, smoke and heat haze
-- are Niagara components on it, 2026-11-20): each one switching on or off
-- is sent with its place relative to the hand bone; the other game runs the
-- same system attached to the puppet's hand.
local NIAGARA_CLASS = "/Script/Niagara.NiagaraComponent"
-- Firing adds components of its own (the flame jet was not among those on the
-- weapon when drawn, 2026-11-20), so the list is read again now and then.
local FX_RESCAN = 0.3
local fxHeld, fxComps, fxOn, fxScanAt = nil, {}, {}, -100

local function pollWeaponFx()
    local a = heldWeapon()
    local addr = a and a:GetAddress()
    if addr ~= fxHeld then
        for key in pairs(fxOn) do net.send("wfx", key, "0") end
        fxHeld, fxComps, fxOn, fxScanAt = addr, {}, {}, -100
        if not a then return end
    end
    if not a then return end
    if now() - fxScanAt >= FX_RESCAN then
        fxScanAt = now()
        local seen = {}
        for _, f in ipairs(fxComps) do seen[f.path] = true end
        for _, e in ipairs(a:K2_GetComponentsByClass(StaticFindObject(NIAGARA_CLASS)) or {}) do
            local c = e.get and e:get() or e
            local p = pathOf(c)
            if not seen[p] then
                fxComps[#fxComps + 1] = { key = c:GetFName():ToString(), path = p }
                log("vapeneffekter: %s får %s", a:GetClass():GetFName():ToString(), c:GetFName():ToString())
            end
        end
    end
    for _, f in ipairs(fxComps) do
        local c = StaticFindObject(f.path)
        local on = c and c:IsValid() and c:IsActive() and c:IsVisible()
        if on and not fxOn[f.key] then
            local sys = c:GetAsset()
            if sys and sys:IsValid() then
                local root = a.RootComponent
                local socket = root:GetAttachSocketName():ToString()
                local body = root:GetAttachParent()
                local kml = UEHelpers.GetKismetMathLibrary()
                local st = body:GetSocketTransform(FName(socket), 0)
                local l = kml:InverseTransformLocation(st, c:K2_GetComponentLocation())
                local r = kml:InverseTransformRotation(st, c:K2_GetComponentRotation())
                net.send("wfx", f.key, "1", pathOf(sys), socket, v3(l), string.format("%.1f,%.1f,%.1f", r.pitch or r.Pitch or 0, r.Yaw or 0, r.Roll or 0))
                log("vapeneffekt på: %s", sys:GetFName():ToString())
            end
            fxOn[f.key] = true
        elseif not on and fxOn[f.key] then
            net.send("wfx", f.key, "0")
            fxOn[f.key] = nil
        end
    end
end

-- Drawing at the other game.
local drawn = {}           -- ray component paths on this side
local hideAt = 0
local drawnFor             -- puppet address the components belong to
local cache = {}

local function load(path)
    if not path or path == "-" then return nil end
    local o = cache[path]
    if o and o:IsValid() then return o end
    o = StaticFindObject(path)
    if not (o and o:IsValid()) then
        local ok, l = pcall(LoadAsset, path)
        o = ok and l or nil
    end
    if o and o:IsValid() then cache[path] = o return o end
end

local IDENTITY = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

local function rayComponent(puppet, i, mesh, material)
    local c = drawn[i] and StaticFindObject(drawn[i])
    if c and c:IsValid() then return c end
    c = puppet:AddComponentByClass(StaticFindObject(SPLINE_CLASS), true, IDENTITY, false)
    pcall(function() c:SetMobility(2) end)
    pcall(function() c:SetCollisionEnabled(0) end)
    if mesh then c:SetStaticMesh(mesh) end
    if material then c:SetMaterial(0, material) end
    drawn[i] = pathOf(c)
    return c
end

local function nums(s)
    local t = {}
    for n in s:gmatch("[^,]+") do t[#t + 1] = tonumber(n) or 0 end
    return t
end

local function playFx(msg)
    local sys = load(msg[3])
    if not sys then return end
    local l, r = {}, {}
    for n in (msg[4] or ""):gmatch("[^,]+") do l[#l + 1] = tonumber(n) or 0 end
    for n in (msg[5] or ""):gmatch("[^,]+") do r[#r + 1] = tonumber(n) or 0 end
    if #l < 3 or #r < 3 then return end
    StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary"):SpawnSystemAtLocation(localPC(), sys,
        { X = l[1], Y = l[2], Z = l[3] }, { pitch = r[1], Pitch = r[1], Yaw = r[2], Roll = r[3] }, { X = 1, Y = 1, Z = 1 }, true, true, 0, false)
end

local puppetFx, puppetFxFor = {}, nil   -- key -> component path on the puppet

local function handleWeaponFx(msg, puppet)
    if not (puppet and puppet:IsValid()) then return end
    local addr = puppet:GetAddress()
    if puppetFxFor ~= addr then puppetFx, puppetFxFor = {}, addr end
    local key = msg[3]
    local old = puppetFx[key] and StaticFindObject(puppetFx[key])
    if old and old:IsValid() then pcall(function() old:K2_DestroyComponent(old) end) end
    puppetFx[key] = nil
    if msg[4] ~= "1" then return end
    local sys = load(msg[5])
    if not sys then return end
    local l, r = nums(msg[7] or ""), nums(msg[8] or "")
    if #l < 3 or #r < 3 then return end
    local c = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary"):SpawnSystemAttached(sys,
        puppet.SkeletalMeshComponent, FName(msg[6]), { X = l[1], Y = l[2], Z = l[3] }, { pitch = r[1], Pitch = r[1], Yaw = r[2], Roll = r[3] },
        0, false, true, 0, true)
    if c and c:IsValid() then puppetFx[key] = pathOf(c) end
end

function M.handle(msg, puppet)
    if msg[1] == "wfx" then
        local ok, err = pcall(handleWeaponFx, msg, puppet)
        if not ok then log("vapeneffekt-fel: %s", tostring(err)) end
        return true
    end
    if msg[1] == "fx" then
        local ok, err = pcall(playFx, msg)
        if not ok then log("mynning-fel: %s", tostring(err)) end
        return true
    end
    if msg[1] ~= "zap" then return false end
    if not (puppet and puppet:IsValid()) then return true end
    local addr = puppet:GetAddress()
    if drawnFor ~= addr then drawn, drawnFor = {}, addr end
    local mesh, material = load(msg[3]), load(msg[4])
    local i = 0
    for ray in (msg[5] or ""):gmatch("[^;]+") do
        local n = nums(ray)
        if #n >= 12 then
            i = i + 1
            local ok, err = pcall(function()
                local c = rayComponent(puppet, i, mesh, material)
                if #n >= 20 then
                    c:SetWorldScale3D({ X = n[18], Y = n[19], Z = n[20] })
                    c:SetForwardAxis(math.floor(n[17]), false)
                    c:SetStartScale({ X = n[13], Y = n[14] }, false)
                    c:SetEndScale({ X = n[15], Y = n[16] }, false)
                end
                c:SetStartAndEnd({ X = n[1], Y = n[2], Z = n[3] }, { X = n[4], Y = n[5], Z = n[6] },
                    { X = n[7], Y = n[8], Z = n[9] }, { X = n[10], Y = n[11], Z = n[12] }, true)
                c:SetVisibility(true, false)
            end)
            if not ok then log("blixt-fel: %s", tostring(err)) end
        end
    end
    hideAt = now() + SHOW_SECONDS
    return true
end

-- Called every frame from the position sending.
function M.frame()
    local ok, err = pcall(poll)
    if not ok then log("blixt-fel: %s", tostring(err)) rays = {} end
    local okS, errS = pcall(pollShots)
    if not okS then log("skott-fel: %s", tostring(errS)) held = nil end
    local okF, errF = pcall(pollWeaponFx)
    if not okF then log("vapeneffekt-fel: %s", tostring(errF)) fxHeld = nil end
    if hideAt > 0 and now() >= hideAt then
        hideAt = 0
        for _, path in pairs(drawn) do
            local c = StaticFindObject(path)
            if c and c:IsValid() then pcall(function() c:SetVisibility(false, false) end) end
        end
    end
end

function M.reset()
    rays, lastRefresh, wasVisible, drawn, drawnFor, hideAt = {}, -100, false, {}, nil, 0
    held, heldSounds = nil, -1
    fxHeld, fxComps, fxOn, fxScanAt, puppetFx, puppetFxFor = nil, {}, {}, -100, {}, nil
end

return M
