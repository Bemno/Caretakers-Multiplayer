-- The photo drone. Flying it possesses the drone pawn while the character
-- stands where it was (main.lua keeps sending the character). The flier sends
-- the drone's meshes once (relative to the drone) and its place every frame;
-- the other game draws the same meshes on the puppet, placed in world space,
-- and takes them away when the drone has been silent a while.
local M = {}
local net, log, localPC, now

local MESH_CLASS = "/Script/Engine.MeshComponent"
local SKEL_CLASS = "/Script/Engine.SkeletalMeshComponent"
local STATIC_CLASS = "/Script/Engine.StaticMeshComponent"
local KML = "/Script/Engine.Default__KismetMathLibrary"
local LIST_KEEPALIVE, SILENT_SECONDS = 3, 0.6

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end
local function f1(v) return string.format("%.1f", v or 0) end
-- Pitch as UE4SS 4 names it, whatever PITCH_FIX says (that switch guards the boat).
local function pitchOf(r) return r.pitch or r.Pitch or 0 end
local function rot(p, y, r) return { pitch = p, Pitch = p, Yaw = y, Roll = r } end

function M.init(netModule, logFn, localPCFn, nowFn)
    net, log, localPC, now = netModule, logFn, localPCFn, nowFn
end

function M.isDrone(pawn)
    return pawn:GetClass():GetFName():ToString():find("Drone", 1, true) ~= nil
end

-- Flying.
local listFor, list, listSentAt = nil, nil, -100

local function meshList(pawn)
    local kml = StaticFindObject(KML)
    local t = pawn:GetTransform()
    local out = {}
    for _, e in ipairs(pawn:K2_GetComponentsByClass(StaticFindObject(MESH_CLASS)) or {}) do
        pcall(function()
            local c = e.get and e:get() or e
            if not c:IsVisible() then return end
            local kind, asset
            if c:IsA(StaticFindObject(SKEL_CLASS)) then
                kind, asset = "K", c:GetSkinnedAsset()
            elseif c:IsA(StaticFindObject(STATIC_CLASS)) then
                kind, asset = "S", c.StaticMesh
            end
            if not (kind and asset and asset:IsValid()) then return end
            local l = kml:InverseTransformLocation(t, c:K2_GetComponentLocation())
            local r = kml:InverseTransformRotation(t, c:K2_GetComponentRotation())
            local s = c:K2_GetComponentScale()
            out[#out + 1] = table.concat({ kind, pathOf(asset), f1(l.X), f1(l.Y), f1(l.Z), f1(pitchOf(r)), f1(r.Yaw), f1(r.Roll),
                string.format("%.3f", s.X), string.format("%.3f", s.Y), string.format("%.3f", s.Z) }, ",")
        end)
    end
    return table.concat(out, ";")
end

-- Called every frame from the position sending while the own pawn is a drone.
function M.send(pawn)
    local addr = pawn:GetAddress()
    if listFor ~= addr then
        listFor, list = addr, meshList(pawn)
        log("drönare: %s, delar %s", pawn:GetClass():GetFName():ToString(), list == "" and "-" or list:gsub("[^;]*/([^/.,]+)%.[^;]*", "%1"))
    end
    if list ~= "" and now() - listSentAt >= LIST_KEEPALIVE then
        listSentAt = now()
        net.send("dronm", list)
    end
    local l, r = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    net.send("dron", f1(l.X), f1(l.Y), f1(l.Z), f1(pitchOf(r)), f1(r.Yaw), f1(r.Roll))
end

function M.stopped()
    if listFor then listFor, listSentAt = nil, -100 end
end

-- Drawing at the other game.
local wanted, shown, shownFor = nil, {}, nil  -- shown: list of { path, rel loc, rel rot }
local target, heardAt = nil, -100
local cache = {}

local function load(path)
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

local function clear()
    for _, s in ipairs(shown) do
        local c = StaticFindObject(s.path)
        if c and c:IsValid() then pcall(function() c:K2_DestroyComponent(c) end) end
    end
    shown = {}
end

local function build(puppet)
    clear()
    shownFor = puppet:GetAddress()
    for entry in (wanted or ""):gmatch("[^;]+") do
        local ok, err = pcall(function()
            local kind, asset, lx, ly, lz, rp, ry, rr, sx, sy, sz = entry:match(
                "^(%a),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
            if not kind then return end
            local mesh = load(asset)
            if not mesh then log("drönare: hittar inte %s", asset) return end
            local c = puppet:AddComponentByClass(StaticFindObject(kind == "K" and SKEL_CLASS or STATIC_CLASS), true, IDENTITY, false)
            if kind == "K" then c:SetSkeletalMeshAsset(mesh) else c:SetStaticMesh(mesh) end
            pcall(function() c:SetCollisionEnabled(0) end)
            c:SetAbsolute(true, true, true)
            c:SetWorldScale3D({ X = tonumber(sx), Y = tonumber(sy), Z = tonumber(sz) })
            shown[#shown + 1] = { path = pathOf(c), loc = { X = tonumber(lx), Y = tonumber(ly), Z = tonumber(lz) },
                rot = rot(tonumber(rp), tonumber(ry), tonumber(rr)) }
        end)
        if not ok then log("drönare-fel: %s", tostring(err)) end
    end
    log("drönare: %d delar på dockan", #shown)
end

function M.handle(msg)
    if msg[1] == "dronm" then
        if msg[3] ~= wanted then wanted, shownFor = msg[3], nil end
        return true
    end
    if msg[1] ~= "dron" then return false end
    local n = {}
    for i = 3, 8 do n[#n + 1] = tonumber(msg[i]) or 0 end
    target = { loc = { X = n[1], Y = n[2], Z = n[3] }, rot = rot(n[4], n[5], n[6]) }
    heardAt = now()
    return true
end

-- Called every frame with the puppet.
function M.frame(puppet)
    if #shown > 0 and now() - heardAt > SILENT_SECONDS then
        clear()
        shownFor = nil
        return
    end
    if not (target and wanted and puppet and puppet:IsValid()) or now() - heardAt > SILENT_SECONDS then return end
    if shownFor ~= puppet:GetAddress() then build(puppet) end
    local kml = StaticFindObject(KML)
    local t = kml:MakeTransform(target.loc, target.rot, { X = 1, Y = 1, Z = 1 })
    for _, s in ipairs(shown) do
        local c = StaticFindObject(s.path)
        if c and c:IsValid() then
            c:K2_SetWorldLocationAndRotation(kml:TransformLocation(t, s.loc), kml:TransformRotation(t, s.rot), false, {}, true)
        end
    end
end

function M.reset()
    clear()
    wanted, shownFor, target, heardAt = nil, nil, nil, -100
    listFor, list, listSentAt = nil, nil, -100
end

return M
