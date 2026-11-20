-- What the player wears on the body (the backpack: a skeletal mesh following
-- the character's skeleton, added to the pawn at run time). The sender lists
-- the pawn's visible meshes beyond the fixed ones and sends them when they
-- change; the other game puts the same meshes on the puppet, skeletal ones
-- driven by the puppet's own skeleton.
local M = {}
local net, log, localPC, now, puppetFn

local POLL_SECONDS, KEEPALIVE = 1, 10
-- The crowbar is always there but hidden until held; visible it is sent.
local FIXED = { CharacterMesh0 = true, SK_Head = true, SK_LeftArm = true, SK_RightArm = true, SK_Foot = true }
local KML = "/Script/Engine.Default__KismetMathLibrary"
local weaponPaths = {}
local MESH_CLASS = "/Script/Engine.MeshComponent"
local SKEL_CLASS = "/Script/Engine.SkeletalMeshComponent"
local STATIC_CLASS = "/Script/Engine.StaticMeshComponent"

local lastPoll, lastSent, sent = -100, -100, nil
local wanted, shownFor, shownList = nil, nil, nil
local added = {}        -- entry -> path of the component added to the puppet for it

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end
-- "-0" and "0" flip while the hand moves, and the list was sent anew each second.
local function noNegZero(s) return (s:gsub("^%-(0%.?0*)$", "%1")) end
local function f1(v) return noNegZero(string.format("%.1f", v or 0)) end
local function f0(v) return noNegZero(string.format("%.0f", v or 0)) end

function M.init(netModule, logFn, localPCFn, nowFn, puppetFunction)
    net, log, localPC, now, puppetFn = netModule, logFn, localPCFn, nowFn, puppetFunction
end

-- The mesh's materials, so a painted or skinned weapon looks the same (the
-- copies came out in the default colours, 2026-11-18). A material made at
-- run time is not an asset; its parent is sent.
local function matsOf(c)
    local parts = {}
    for i = 0, c:GetNumMaterials() - 1 do
        local m = c:GetMaterial(i)
        if m and m:IsValid() and m:GetClass():GetFName():ToString() == "MaterialInstanceDynamic" then m = m.Parent end
        parts[#parts + 1] = (m and m:IsValid()) and pathOf(m) or "-"
    end
    return table.concat(parts, "+")
end

local function entryOf(c)
    if FIXED[c:GetFName():ToString()] or not c:IsVisible() then return nil end
    local parent = c:GetAttachParent()
    if not (parent and parent:IsValid() and parent:GetFName():ToString() == "CharacterMesh0") then return nil end
    local kind, asset
    if c:IsA(StaticFindObject(SKEL_CLASS)) then
        kind, asset = "K", c:GetSkinnedAsset()
    elseif c:IsA(StaticFindObject(STATIC_CLASS)) then
        kind, asset = "S", c.StaticMesh
    end
    if not (kind and asset and asset:IsValid()) then return nil end
    local l, r, s = c.RelativeLocation, c.RelativeRotation, c.RelativeScale3D
    return table.concat({ kind, pathOf(asset), c:GetAttachSocketName():ToString(), f1(l.X), f1(l.Y), f1(l.Z),
        f1(RotP(r)), f1(r.Yaw), f1(r.Roll), f1(s.X), f1(s.Y), f1(s.Z), matsOf(c) }, ",")
end

-- Everything fastened to the character, at any depth: weapons and tools at
-- a hand or holster bone, the backpack at PowerSocket, modules on the
-- backpack's socket, a scope on a weapon. Each actor's meshes are placed
-- relative to the bone its chain hangs on. Cables are power.lua's.
local EQUIP_CLASS = "/Script/Voyage.VoyageEquipmentActor"

local function anchorSocket(a, body)
    local c = a.RootComponent
    for _ = 1, 12 do
        local parent = c:GetAttachParent()
        if not (parent and parent:IsValid()) then return nil end
        if parent:GetAddress() == body:GetAddress() then return c:GetAttachSocketName():ToString() end
        c = parent
    end
end

M.weaponInHand = false
local function weaponEntries(pawn, out)
    local inHand = false
    local body = pawn.Mesh
    local kml = StaticFindObject(KML)
    local equipCls = StaticFindObject(EQUIP_CLASS)
    local attached = {}
    pawn:GetAttachedActors(attached, true, true)
    weaponPaths = {}
    for _, x in ipairs(attached) do
        pcall(function()
            local a = x.get and x:get() or x
            if not a:IsValid() or a.bHidden then return end
            local cls = a:GetClass():GetFName():ToString()
            if cls:find("Cable", 1, true) then return end
            local socket = anchorSocket(a, body)
            if not socket then return end
            local isEquip = equipCls and a:IsA(equipCls)
            if isEquip then weaponPaths[#weaponPaths + 1] = pathOf(a) end
            if isEquip and socket:find("hand", 1, true) then inHand = true end
            local st = body:GetSocketTransform(FName(socket), 0)
            for _, e in ipairs(a:K2_GetComponentsByClass(StaticFindObject(MESH_CLASS)) or {}) do
                pcall(function()
                    local c = e.get and e:get() or e
                    if not c:IsVisible() or c:GetClass():GetFName():ToString():find("Spline", 1, true) then return end
                    local kind, asset
                    if c:IsA(StaticFindObject(SKEL_CLASS)) then
                        kind, asset = "K", c:GetSkinnedAsset()
                    elseif c:IsA(StaticFindObject(STATIC_CLASS)) then
                        kind, asset = "S", c.StaticMesh
                    end
                    if not (kind and asset and asset:IsValid()) then return end
                    local l = kml:InverseTransformLocation(st, c:K2_GetComponentLocation())
                    local r = kml:InverseTransformRotation(st, c:K2_GetComponentRotation())
                    -- Scale relative to the bone: the badge's world scale sat
                    -- at 1.25 and flipped between 1.2 and 1.3 each second.
                    local s, bs = c:K2_GetComponentScale(), st.Scale3D
                    local function rs(v, b0) return string.format("%.2f", v / ((b0 and b0 ~= 0) and b0 or 1)) end
                    -- Whole cm and degrees: read while the hand moves, tenths
                    -- changed every second and the list was sent anew each time.
                    out[#out + 1] = table.concat({ kind, pathOf(asset), socket, f0(l.X), f0(l.Y), f0(l.Z),
                        f0(RotP(r)), f0(r.Yaw), f0(r.Roll), rs(s.X, bs.X), rs(s.Y, bs.Y), rs(s.Z, bs.Z), matsOf(c) }, ",")
                end)
            end
        end)
    end
    M.weaponPaths = weaponPaths
    M.weaponInHand = inHand
end

-- The body to read: main.lua sets it (the character, also while a drone is flown).
M.body = function() return localPC().Pawn end

local function ownList()
    local pawn = M.body()
    if not (pawn and pawn:IsValid()) then return nil end
    local out = {}
    for _, e in ipairs(pawn:K2_GetComponentsByClass(StaticFindObject(MESH_CLASS)) or {}) do
        local c = e.get and e:get() or e
        local ok, entry = pcall(entryOf, c)
        if ok and entry then out[#out + 1] = entry end
    end
    local okW, errW = pcall(weaponEntries, pawn, out)
    if not okW then log("utrustning: vapen-fel %s", tostring(errW)) end
    -- The body's paint: the materials on the character mesh.
    pcall(function()
        local body = pawn.Mesh
        for i = 0, body:GetNumMaterials() - 1 do
            local m = body:GetMaterial(i)
            if m and m:IsValid() then out[#out + 1] = "M," .. i .. "," .. pathOf(m) end
        end
    end)
    table.sort(out)
    return table.concat(out, ";")
end

local function removeAdded(path)
    local c = StaticFindObject(path)
    if c and c:IsValid() then pcall(function() c:K2_DestroyComponent(c) end) end
end

local IDENTITY = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

local function setMaterial(puppet, entry)
    local i, path = entry:match("^M,(%d+),(.+)$")
    if not i then return false end
    local m = StaticFindObject(path)
    if not (m and m:IsValid()) then
        local ok, loaded = pcall(LoadAsset, path)
        m = ok and loaded or nil
    end
    -- A material made at run time (a painted copy) is not an asset; the
    -- puppet keeps the default for that slot.
    if m and m:IsValid() then puppet.SkeletalMeshComponent:SetMaterial(tonumber(i), m) end
    return true
end

local function addOne(puppet, entry)
    if setMaterial(puppet, entry) then return end
    local kind, asset, socket, lx, ly, lz, rp, ry, rr, sx, sy, sz, mats = entry:match(
        "^(%a),([^,]+),([^,]*),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),?([^,]*)$")
    if not kind then return end
    local mesh = StaticFindObject(asset)
    if not (mesh and mesh:IsValid()) then
        local ok, loaded = pcall(LoadAsset, asset)
        mesh = ok and loaded or nil
    end
    if not (mesh and mesh:IsValid()) then log("utrustning: hittar inte %s", asset) return end
    local body = puppet.SkeletalMeshComponent
    local c = puppet:AddComponentByClass(StaticFindObject(kind == "K" and SKEL_CLASS or STATIC_CLASS), true, IDENTITY, false)
    if kind == "K" then c:SetSkeletalMeshAsset(mesh) else c:SetStaticMesh(mesh) end
    c:K2_AttachToComponent(body, FName(socket), 0, 0, 0, false)
    c:K2_SetRelativeLocationAndRotation({ X = tonumber(lx), Y = tonumber(ly), Z = tonumber(lz) },
        Rot(tonumber(rp), tonumber(ry), tonumber(rr)), false, {}, true)
    c:SetRelativeScale3D({ X = tonumber(sx), Y = tonumber(sy), Z = tonumber(sz) })
    pcall(function() c:SetCollisionEnabled(0) end)
    local slot = 0
    for mp in (mats or ""):gmatch("[^+]+") do
        if mp ~= "-" then
            local m = StaticFindObject(mp)
            if not (m and m:IsValid()) then
                local ok, loaded = pcall(LoadAsset, mp)
                m = ok and loaded or nil
            end
            if m and m:IsValid() then pcall(function() c:SetMaterial(slot, m) end) end
        end
        slot = slot + 1
    end
    -- Worn meshes share the body's skeleton; a weapon at a bone has its own.
    if kind == "K" and socket == "None" then pcall(function() c:SetLeaderPoseComponent(body, false, false) end) end
    log("utrustning: %s på dockan", asset:match("[^.]+$"))
    return pathOf(c)
end

local function showOnPuppet()
    local puppet = puppetFn()
    if not (wanted and puppet and puppet:IsValid()) then return end
    local addr = puppet:GetAddress()
    if shownFor == addr and shownList == wanted then return end
    if shownFor ~= addr then added = {} end
    shownFor, shownList = addr, wanted
    -- Only what changed is swapped: rebuilding everything each time flickered.
    local want = {}
    for entry in wanted:gmatch("[^;]+") do want[entry] = true end
    for entry, path in pairs(added) do
        if not want[entry] then if path then removeAdded(path) end added[entry] = nil end
    end
    for entry in pairs(want) do
        if not added[entry] then
            local ok, res = pcall(addOne, puppet, entry)
            if not ok then log("utrustning-fel: %s", tostring(res)) end
            added[entry] = (ok and res) or false
        end
    end
end

function M.tick()
    if now() - lastPoll < POLL_SECONDS then return end
    lastPoll = now()
    local list = ownList()
    if list and (list ~= sent or now() - lastSent >= KEEPALIVE) then
        if list ~= sent then log("utrustning: skickar %s", list == "" and "-" or list:gsub("[^;]*/([^/.,]+)%.[^;]*", "%1")) end
        sent, lastSent = list, now()
        net.send("gear", list == "" and "-" or list)
    end
    showOnPuppet()
end

-- Where a cable from the other player's weapon should end on the puppet: the
-- weapon's own socket mesh, else the right hand.
function M.weaponSocketPoint(puppet)
    for entry, path in pairs(added) do
        if path and entry:find("Socket_Electrical", 1, true) and entry:find("hand", 1, true) then
            local c = StaticFindObject(path)
            if c and c:IsValid() then return c:K2_GetComponentLocation() end
        end
    end
    local ok, l = pcall(function() return puppet.SkeletalMeshComponent:GetSocketLocation(FName("hand_r")) end)
    if ok then return l end
end

function M.handle(msg)
    if msg[1] ~= "gear" then return false end
    wanted = (msg[3] == "-" or not msg[3]) and "" or msg[3]
    return true
end

function M.reset()
    lastPoll, lastSent, sent, shownFor, shownList, added = -100, -100, nil, nil, nil, {}
end

return M
