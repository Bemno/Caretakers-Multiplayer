-- Vehicles other than the boat: forklift, gyrocopter, jet ski and any other
-- VoyageVehiclePawn (the crane too if it is one). The one who handles owns
-- (arkiv.md pattern 4): whoever drives a vehicle owns it, its physics run in
-- their game and the position is sent (veh) every frame while driving and
-- until it comes to rest. The other game turns its copy's physics off and
-- places it where the owner's is, 0.1 s late and eased. A vehicle nobody has
-- driven is left to each game.
local M = {}

local VEHICLE_CLASS = "/Script/Voyage.VoyageVehiclePawn"
local BOAT_CLASS = "/Script/Voyage.VoyageBoatPawn"
local DRONE_CLASS = "/Script/Voyage.VoyageVehicleCameraDronePawn"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local SCAN_EVERY = 5
local SEND_EVERY = 0.05
local REST_SPEED = 5        -- cm/s
local REST_SECONDS = 2
local DELAY = 0.1

local net, log, localPC, now, boat
local vehicles = {}         -- key -> path
local owner = {}            -- key -> "me" | "peer"
local sent = {}             -- key -> { t, l, still }
local remote = {}           -- key -> { buf = { {t, l, r} } }
local physicsOff = {}       -- key -> true while this game's copy follows
local lastScan = -100
local driving               -- key of the vehicle this player drives

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function keyOf(a)
    local pc = a:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local id = pc and pc:IsValid() and pc.PersistentUniqueId
    if id and id ~= 0 then return "v" .. tostring(id) end
end

local function scan()
    lastScan = now()
    local fresh = {}
    local boatCls, droneCls = StaticFindObject(BOAT_CLASS), StaticFindObject(DRONE_CLASS)
    local ok, found = pcall(FindObjects, 0, "VoyageVehiclePawn", "", 0, 0x10, false)
    for _, a in ipairs((ok and found) or {}) do
        pcall(function()
            if not a:IsValid() then return end
            local p = pathOf(a)
            if p:find("Default__", 1, true) or p:find("_GEN_VARIABLE", 1, true) then return end
            if boatCls and boatCls:IsValid() and a:IsA(boatCls) then return end
            if droneCls and droneCls:IsValid() and a:IsA(droneCls) then return end
            local key = keyOf(a)
            if key then
                if not vehicles[key] then log("fordon: %s (%s)", key, a:GetClass():GetFName():ToString()) end
                fresh[key] = p
            end
        end)
    end
    vehicles = fresh
end

local function actorOf(key)
    local p = vehicles[key]
    local a = p and StaticFindObject(p)
    if a and a:IsValid() then return a end
end

local function setPhysics(key, a, on)
    local root = a.RootComponent
    if not (root and root:IsValid()) then return end
    if on then
        if physicsOff[key] then
            pcall(function() root:SetSimulatePhysics(true) end)
            pcall(function() root:WakeAllRigidBodies() end)
            physicsOff[key] = nil
        end
    elseif not physicsOff[key] then
        local okS, sim = pcall(function() return root:IsSimulatingPhysics(FName("None")) end)
        if okS and sim then pcall(function() root:SetSimulatePhysics(false) end) end
        physicsOff[key] = true
    end
end

local function f1(v) return string.format("%.1f", v or 0) end

local function send(key, a)
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    local t = now()
    local s = sent[key]
    if s and t - s.t < SEND_EVERY then return end
    local still = 0
    if s then
        local d = math.sqrt((l.X - s.l.X) ^ 2 + (l.Y - s.l.Y) ^ 2 + (l.Z - s.l.Z) ^ 2)
        if d / math.max(t - s.t, 0.001) < REST_SPEED then still = s.still + (t - s.t) end
    end
    sent[key] = { t = t, l = { X = l.X, Y = l.Y, Z = l.Z }, still = still }
    net.send("veh", key, f1(l.X), f1(l.Y), f1(l.Z), f1(r.Pitch), f1(r.Yaw), f1(r.Roll), driving == key and "1" or "0",
        string.format("%.3f", t))
end

local function wrap(a) return (a + 180) % 360 - 180 end

local function lerp(a, b, k) return a + (b - a) * k end

-- Every frame: copies of vehicles the other player owns.
function M.frame()
    local t = now()
    for key, rem in pairs(remote) do
        local a = owner[key] == "peer" and actorOf(key)
        if a and #rem.buf > 0 then
            local show = t - (rem.offset or 0) - DELAY
            local p0, p1 = rem.buf[1], rem.buf[#rem.buf]
            for i = 1, #rem.buf - 1 do
                if rem.buf[i].st <= show and rem.buf[i + 1].st >= show then p0, p1 = rem.buf[i], rem.buf[i + 1] break end
            end
            local k = (p1.st > p0.st) and math.min(math.max((show - p0.st) / (p1.st - p0.st), 0), 1) or 1
            local loc = { X = lerp(p0.l.X, p1.l.X, k), Y = lerp(p0.l.Y, p1.l.Y, k), Z = lerp(p0.l.Z, p1.l.Z, k) }
            local rot = { Pitch = p0.r.Pitch + wrap(p1.r.Pitch - p0.r.Pitch) * k, Yaw = p0.r.Yaw + wrap(p1.r.Yaw - p0.r.Yaw) * k,
                Roll = p0.r.Roll + wrap(p1.r.Roll - p0.r.Roll) * k }
            pcall(boat.moveActor, a, loc, rot)
        end
    end
end

function M.init(netModule, logFn, localPCFn, nowFn, boatModule)
    net, log, localPC, now, boat = netModule, logFn, localPCFn, nowFn, boatModule
end

function M.reset()
    vehicles, owner, sent, remote, physicsOff, lastScan, driving = {}, {}, {}, {}, {}, -100, nil
end

function M.tick()
    if now() - lastScan >= SCAN_EVERY then scan() end
    local pawn = localPC().Pawn
    local mine
    if pawn and pawn:IsValid() then
        local vc = StaticFindObject(VEHICLE_CLASS)
        if vc and vc:IsValid() and pawn:IsA(vc) then mine = keyOf(pawn) end
        if mine and not vehicles[mine] then vehicles[mine] = pathOf(pawn) end
    end
    if mine ~= driving then
        log("fordon: %s", mine and ("jag kör " .. mine) or ("lämnade " .. tostring(driving)))
        driving = mine
    end
    if mine and owner[mine] ~= "me" then
        owner[mine] = "me"
        remote[mine] = nil
        local a = actorOf(mine)
        if a then setPhysics(mine, a, true) end
        log("fordon %s: jag kör, jag äger", mine)
    end
    for key, who in pairs(owner) do
        if who == "me" then
            local a = actorOf(key)
            if a then
                local s = sent[key]
                if key == driving or not s or s.still < REST_SECONDS then pcall(send, key, a) end
            end
        end
    end
end

function M.handle(msg)
    if msg[1] ~= "veh" then return false end
    local key = msg[3]
    if key == driving then return true end      -- the driver keeps it
    local l = { X = tonumber(msg[4]), Y = tonumber(msg[5]), Z = tonumber(msg[6]) }
    local r = { Pitch = tonumber(msg[7]) or 0, Yaw = tonumber(msg[8]) or 0, Roll = tonumber(msg[9]) or 0 }
    if not (l.X and l.Y and l.Z) then return true end
    if owner[key] ~= "peer" then
        owner[key] = "peer"
        sent[key] = nil
        log("fordon %s: den andra %s, den andra äger", key, msg[10] == "1" and "kör" or "flyttar")
    end
    local a = actorOf(key)
    if a then setPhysics(key, a, false) end
    local st = tonumber(msg[11]) or now()
    local rem = remote[key] or { buf = {} }
    local off = now() - st
    if not rem.offset or off < rem.offset then rem.offset = off end
    rem.buf[#rem.buf + 1] = { st = st, l = l, r = r }
    while #rem.buf > 20 do table.remove(rem.buf, 1) end
    remote[key] = rem
    return true
end

return M
