-- Charging player to player through a cable into the puppet's chest. The
-- giver takes the power out of its own battery and sends it (pwr); the
-- receiver adds what fits and sends back what did not (pwrback). J/K at the
-- puppet's head were removed (2026-11-24, not wanted).
local M = {}

local STEP = 0.5
local RESERVE = 0.05        -- the giver keeps 5 % of its battery
local ELECTRICITY = 0

local net, log, localPC, now, puppetFn, peerinv, T, console
local peerLevel, peerMax = nil, nil
local lastLevel = -100

local function battery()
    local pm = localPC().Pawn.PlayerModuleComponent
    return pm, pm:GetResourceAmount(ELECTRICITY), pm:GetMaxResourceAmount(ELECTRICITY)
end

-- Body socket on the puppet -------------------------------------------------
-- The puppet had nothing to plug a cable into. A hidden small battery sits in
-- the mesh's PowerSocket (where the player's own ElectricSocket is) and its own
-- socket takes the cable; its level follows the other player's battery (as a
-- fraction). Each game charges only its own player: the other game gets the
-- cable plugged into that player's real body (power.lua's "@du"/"@jag" keys),
-- so nothing is sent from here, which would count twice.
-- The battery is made with the game's runtime spawn: a summoned module has no
-- save id when it registers, the module subsystem drops it for good, and the
-- cable's socket search then skips it (ModuleAddressCached 0; disassembly
-- 2026-11-16). A virtual socket in front of it plugged in but moved no power.
local BAT_CLASS = "/Game/Blueprints/Modules/Storage/BP_Module_BatterySmall.BP_Module_BatterySmall_C"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local MODULE_CLASS = "/Script/Voyage.VoyageModuleComponent"
-- The puppet's mesh is turned against its actor: the character faces the
-- actor's right vector, and the actor's forward vector is the character's left
-- (tested 2026-11-16: the socket sat on the right and pointed right).
local POWERSOCKET_HEIGHT = 104 -- cm above the puppet actor, measured standing (1.6 cm in front)
local SOCKET_FORWARD = 14      -- cm in front of the actor; PowerSocket lies inside the chest
local SOCKET_UP = 12           -- cm above PowerSocket
local SOCKET_TILT = 15         -- degrees the socket's face is tilted down
local CHEST_BONE = "PowerSocket"
local function pathOf(a) return a:GetFullName():match("%S+%s+(%S+)") end
local body = {}                -- batPath, puppetAddr
local flowLog = { sent = 0, got = 0, at = 0 }
-- Power is decided in 0.5 s steps but moved a little every frame: added or
-- taken 25 units at a time, the game's charge rate swung between -120 and
-- -400 all the time (2026-11-24).
local pending = { inn = 0, out = 0 }
local lastFrame
local lastBody = -100

local function socketOf(bat)
    local s = body.sockComp and StaticFindObject(body.sockComp)
    if s and s:IsValid() then return s end
    for _, c in ipairs(FindObjects(0, "ModuleSocketComponent", "", 0, 0, false) or {}) do
        local ok, hit = pcall(function() return c:GetOwner():GetAddress() == bat:GetAddress() end)
        if ok and hit then body.sockComp = pathOf(c) return c end
    end
end

local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function cross(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end
local function comb(x, y, z, cx, cy, cz)
    return { X = x.X * cx + y.X * cy + z.X * cz, Y = x.Y * cx + y.Y * cy + z.Y * cz, Z = x.Z * cx + y.Z * cy + z.Z * cz }
end

local function socketMesh(bat)
    for _, e in ipairs(bat:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))) do
        local okG, c = pcall(function() return e:get() end)
        c = (okG and c) or e
        local ok, hit = pcall(function() return c.StaticMesh:GetFName():ToString():find("Socket", 1, true) end)
        if ok and hit then return c end
    end
end

-- The socket's face is its mesh's +Y (it pointed up, 2026-11-16). The battery
-- is turned so that +Y points out of the character's chest with Z up.
local function turnBody(bat, puppet)
    local mesh = socketMesh(bat)
    if not mesh then return end
    local f, u = puppet:GetActorRightVector(), puppet:GetActorUpVector()
    local c, sn = math.cos(math.rad(SOCKET_TILT)), math.sin(math.rad(SOCKET_TILT))
    local yd = comb(f, u, f, c, -sn, 0)
    local zd = comb(u, f, u, c, sn, 0)
    local xd = cross(yd, zd)
    local xc, yc, zc = mesh:GetForwardVector(), mesh:GetRightVector(), mesh:GetUpVector()
    local function map(v) return comb(xd, yd, zd, dot(v, xc), dot(v, yc), dot(v, zc)) end
    local bf, br, bu = map(bat:GetActorForwardVector()), map(bat:GetActorRightVector()), map(bat:GetActorUpVector())
    local rot = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):MakeRotationFromAxes(bf, br, bu)
    bat:K2_SetActorRotation(rot, true)
end

local function placeBody(bat, puppet)
    -- Placed from the actor, not the PowerSocket bone: the bone moves with
    -- the animation, and the socket jumped a few cm sideways when the idle
    -- pose set in after a second of standing still (2026-11-16).
    local l, f, u = puppet:K2_GetActorLocation(), puppet:GetActorRightVector(), puppet:GetActorUpVector()
    local h = POWERSOCKET_HEIGHT + SOCKET_UP
    local chest = { X = l.X + f.X * SOCKET_FORWARD + u.X * h, Y = l.Y + f.Y * SOCKET_FORWARD + u.Y * h, Z = l.Z + f.Z * SOCKET_FORWARD + u.Z * h }
    -- The socket is moved onto the chest, not the battery: the battery's own
    -- origin is not where its socket sits.
    local sock = socketMesh(bat) or socketOf(bat)
    local at = bat:K2_GetActorLocation()
    if sock then
        local s = sock:K2_GetComponentLocation()
        at = { X = at.X + chest.X - s.X, Y = at.Y + chest.Y - s.Y, Z = at.Z + chest.Z - s.Z }
    else
        at = chest
    end
    bat:K2_SetActorLocation(at, false, {}, true)
end

local function makeBody(puppet)
    local cls = StaticFindObject(BAT_CLASS)
    if not (cls and cls:IsValid()) then pcall(LoadAsset, (BAT_CLASS:gsub("_C$", ""))) cls = StaticFindObject(BAT_CLASS) end
    if not (cls and cls:IsValid()) then log("kroppsuttag: batteriklassen saknas") return end
    local l = puppet:K2_GetActorLocation()
    local ok, bat = pcall(function()
        return StaticFindObject("/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary"):SpawnRuntimeActorFromClass(puppet:GetWorld(), cls,
            { Translation = { X = l.X, Y = l.Y, Z = l.Z + 120 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } },
            { Value = 0 }, nil, nil)
    end)
    if not (ok and bat and bat:IsValid()) then log("kroppsuttag: runtime-skapandet misslyckades (%s)", tostring(bat)) return end
    -- The battery simulates physics: it fell and was flung 40-300 m between
    -- placements, dragging the plugged cable along, and could not be attached.
    pcall(function() bat.RootComponent:SetSimulatePhysics(false) end)
    pcall(function() bat.RootComponent:SetMobility(2) end)
    -- Everything but the socket is hidden; the cable plugs into the socket.
    -- The battery's own components: going through every primitive in the
    -- world stalled the game 117-134 ms each time the body was made (2026-11-21).
    for _, e in ipairs(bat:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent")) or {}) do
        pcall(function()
            local c = e
            pcall(function() c = e:get() end)
            if c:GetOwner():GetAddress() == bat:GetAddress() then
                -- The socket's mesh (SM_Socket_Electrical_Output) sits in an
                -- unnamed StaticMeshComponent, so the mesh name counts too.
                local name = c:GetFName():ToString()
                pcall(function() name = name .. " " .. c.StaticMesh:GetFName():ToString() end)
                -- Only the socket keeps collision, as query only and ignoring
                -- pawns: the player's plug trace has to reach it.
                if name:find("Socket", 1, true) then
                    c:SetCollisionEnabled(1)
                    c:SetCollisionResponseToChannel(2, 0)
                else
                    c:SetVisibility(false, false)
                    c:SetCollisionEnabled(0)
                end
            end
        end)
    end
    local okT, errT = pcall(turnBody, bat, puppet)
    if not okT then log("kroppsuttag: vridning misslyckades: %s", tostring(errT)) end
    placeBody(bat, puppet)
    -- On the chest bone, so the socket moves with the body: on the actor it
    -- stayed put while the body leaned and swayed in the walk and run blend
    -- spaces, and seemed to trail behind (2026-11-18). Placed once, keeping
    -- the offset; the regular re-placement from the actor is skipped then.
    local okA = pcall(function()
        bat:K2_AttachToComponent(puppet.SkeletalMeshComponent, FName(CHEST_BONE), 1, 1, 1, false)
    end)
    body.onBone = okA
    if not okA then
        okA = pcall(function() bat:K2_AttachToComponent(puppet.RootComponent, FName("None"), 1, 1, 1, false) end)
    end
    local parent
    pcall(function() parent = bat:GetAttachParentActor() end)
    body.attached = okA and parent and parent:IsValid() and parent:GetAddress() == puppet:GetAddress()
    body.batPath, body.puppetAddr, body.made = pathOf(bat), puppet:GetAddress(), now()
    log("kroppsuttag: batteri %s vid dockans bröst, fäst %s", body.batPath, tostring(body.attached))
end

local function removeBody()
    local a = body.batPath and StaticFindObject(body.batPath)
    if a and a:IsValid() then pcall(function() a:K2_DestroyActor() end) end
    body = {}
end

-- Player to player cable. The hidden battery shows the LOCAL player's own
-- level, so the game sees equal levels at both ends and moves nothing; the
-- host then balances the two real batteries itself while the cable is in.
-- Letting the game's cable move power between a player and a battery that
-- mirrored the other player made power appear, vanish and swing between plus
-- and minus whatever was counted (2026-11-17, five attempts).
local BALANCE_RATE = 50     -- battery units per second
local function ownLevel(cap)
    local okB, _, have, max = pcall(battery)
    if not (okB and max and max > 0) then return 0 end
    return math.max(0, math.min(cap, have / max * cap))
end

-- The cable between the local body and the hidden battery, when that is the
-- battery's only cable: returns the cable and whether the body is its A end.
local function myCable(bat)
    local pawn = localPC().Pawn
    local found, bodyIsA, other = nil, nil, false
    for _, c in ipairs(FindObjects(0, "ModulesConnectCable", "", 0, 0x10, false) or {}) do
        pcall(function()
            if not c:IsValid() then return end
            local a, b = c:GetSocket(c.ConnectorMeshA), c:GetSocket(c.ConnectorMeshB)
            local oa = a and a:IsValid() and a:GetOwner()
            local ob = b and b:IsValid() and b:GetOwner()
            local function is(o, x) return o and o:IsValid() and x and o:GetAddress() == x:GetAddress() end
            if is(oa, bat) and is(ob, pawn) then found, bodyIsA = c, false
            elseif is(ob, bat) and is(oa, pawn) then found, bodyIsA = c, true
            elseif is(oa, bat) or is(ob, bat) then other = true end
        end)
    end
    if found and not other then return found, bodyIsA end
end

-- Cable mode is the cable's DirectionA/DirectionB (one per end: 0 balance,
-- 1 in, 2 out; found by diffing a switch, 2026-11-17). It is read where it
-- was set and sent as "give"/"take"/"balance" from the sender's side; the
-- other side turns it round and sets its copy the same way.
local MODE_OF = { give = 1, take = -1, balance = 0 }
local modeSeen = nil         -- my side's mode as last read, sent or applied
local hostDir = 0            -- host: 1 host gives, -1 guest gives, 0 balance

local function readMode(c, bodyIsA)
    local bodyDir = bodyIsA and c.DirectionA or c.DirectionB
    local batDir = bodyIsA and c.DirectionB or c.DirectionA
    if bodyDir == 2 or batDir == 1 then return "give" end
    if bodyDir == 1 or batDir == 2 then return "take" end
    return "balance"
end

local function writeMode(c, bodyIsA, mode)
    local bodyDir = mode == "give" and 2 or mode == "take" and 1 or 0
    local batDir = mode == "give" and 1 or mode == "take" and 2 or 0
    local da, db = bodyDir, batDir
    if not bodyIsA then da, db = batDir, bodyDir end
    -- Through the socket as F does it: written straight into the fields, the
    -- arrow and the flow animation kept the old way (diesel, 2026-11-24).
    local sa, sb = c:GetSocket(c.ConnectorMeshA), c:GetSocket(c.ConnectorMeshB)
    if sa and sa:IsValid() and (da ~= 0 or db == 0 or not (sb and sb:IsValid())) then pcall(function() sa:SetSocketDirectionType(da) end)
    elseif sb and sb:IsValid() then pcall(function() sb:SetSocketDirectionType(db) end) end
    if c.DirectionA ~= da or c.DirectionB ~= db then c.DirectionA, c.DirectionB = da, db end
end

local function setHostDir(mode, fromHostSide)
    local d = MODE_OF[mode] or 0
    hostDir = fromHostSide and d or -d
end

local function syncMode(c, bodyIsA)
    local mode = readMode(c, bodyIsA)
    if mode == modeSeen then return end
    modeSeen = mode
    net.send("pwrmode", mode)
    setHostDir(mode, Coop.props.isHost)
    log("kroppsuttag: kabelläge %s (ställt här)", mode)
end

local function applyPeerMode(mode)
    local mine = mode == "give" and "take" or mode == "take" and "give" or "balance"
    modeSeen = mine
    setHostDir(mode, not Coop.props.isHost)
    local bat = body.batPath and StaticFindObject(body.batPath)
    local c, bodyIsA
    if bat and bat:IsValid() then c, bodyIsA = myCable(bat) end
    if c then pcall(writeMode, c, bodyIsA, mine) end
    log("kroppsuttag: kabelläge %s (från kompisen)", mine)
end

-- The cable's flow animation: the game sets FlowStrength from real flow
-- every frame, so while the mod moves power it is set again each frame
-- (frame hook). fromBody: power leaves the local body.
local function markFlow(fromBody)
    if not body.cablePath then return end
    body.flowUntil, body.flowFromBody = now() + 0.8, fromBody
end

local frameHooked = false
local function spread()
    local t = now()
    local dt = lastFrame and math.min(t - lastFrame, 0.1) or 0
    lastFrame = t
    if pending.inn <= 0 and pending.out <= 0 then return end
    local pm = localPC().Pawn.PlayerModuleComponent
    for _, k in ipairs({ "inn", "out" }) do
        local p = pending[k]
        if p > 0 then
            -- One step's amount (25) lasts its 0.5 s; a backlog goes faster.
            local x = math.min(p, math.max(BALANCE_RATE, p * 2) * dt)
            pending[k] = p - x
            if k == "inn" then pm:ForceAddResource(ELECTRICITY, x) else pm:AddResource(ELECTRICITY, -x) end
        end
    end
end

local function flowFrame()
    pcall(spread)
    if not (body.flowUntil and now() < body.flowUntil and body.cablePath) then return end
    local c = StaticFindObject(body.cablePath)
    if not (c and c:IsValid()) then body.cablePath = nil return end
    -- From the A end to the B end is negative (tested 2026-11-17: it ran backwards).
    local fromA = (body.flowFromBody and body.bodyIsA) or (not body.flowFromBody and not body.bodyIsA)
    c.FlowStrength = 1
    c.FlowDirection = fromA and -1 or 1
end

-- Host: while the players are cabled together, move power the way the cable
-- is set; balancing goes from the fuller battery (as a fraction) to the
-- emptier one until they match. pwr adds what fits and returns the rest
-- (pwrback); pwrpull asks the guest to give.
local function balance(bat)
    local c, bodyIsA = myCable(bat)
    if not c then modeSeen, body.cablePath = nil, nil return end
    body.cablePath, body.bodyIsA = c:GetFullName():match("%S+%s+(%S+)"), bodyIsA
    if not frameHooked then
        frameHooked = true
        pcall(function() require("boat").addFrame(flowFrame) end)
    end
    local okM, errM = pcall(syncMode, c, bodyIsA)
    if not okM then log("kroppsuttag-läge: %s", tostring(errM)) end
    if not Coop.props.isHost then return end
    if not (peerLevel and peerMax and peerMax > 0) then return end
    local pm, have, max = battery()
    have = have + pending.inn - pending.out
    if not (max and max > 0) then return end
    local amount, hostGives
    if hostDir == 0 then
        local mine, theirs = have / max, peerLevel / peerMax
        if math.abs(mine - theirs) < 0.01 then return end
        -- Half the gap in units, so both end at the same fraction.
        local gap = math.abs(mine - theirs) / (1 / max + 1 / peerMax) / 2
        amount, hostGives = math.min(BALANCE_RATE * STEP, gap), mine > theirs
    elseif hostDir > 0 then
        amount, hostGives = math.min(BALANCE_RATE * STEP, have - max * RESERVE, peerMax - peerLevel), true
    else
        amount, hostGives = math.min(BALANCE_RATE * STEP, peerLevel - peerMax * RESERVE, max - have), false
    end
    if amount < 0.5 then return end
    if hostGives then
        pending.out = pending.out + amount
        net.send("pwr", string.format("%.2f", amount))
        flowLog.sent = flowLog.sent + amount
        markFlow(true)
    else
        net.send("pwrpull", string.format("%.2f", amount))
        flowLog.got = flowLog.got + amount
        markFlow(false)
    end
end

local function bodyStep()
    local bat = body.batPath and StaticFindObject(body.batPath)
    if not (bat and bat:IsValid()) then body = {} return end
    -- Not saved: the save component goes once the module has registered
    -- (it needs the save id for that).
    if body.made and now() - body.made > 3 then
        body.made = nil
        local pc = bat:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
        if pc and pc:IsValid() then pcall(function() pc:K2_DestroyComponent(bat) end) end
    end
    -- The puppet's mesh turns a little against its actor after the battery
    -- is attached (23 degrees, 6 cm off to the side), so it is set again.
    local puppet = puppetFn()
    if puppet and puppet:IsValid() and not body.onBone then
        pcall(turnBody, bat, puppet)
        pcall(placeBody, bat, puppet)
    end
    local module = bat:GetComponentByClass(StaticFindObject(MODULE_CLASS))
    local cur, cap = module:GetResourceAmount(ELECTRICITY), module:GetMaxResourceAmount(ELECTRICITY)
    if cap <= 0 then return end
    -- Closed to the game's cable flow: even at equal fractions the game moved
    -- power from it into the player (capacities differ) and both players
    -- filled up while balancing (2026-11-17). Only balance() moves power.
    if not body.closed then
        local okC = pcall(function()
            module:SetOfferResourcesState(false)
            module:SetReceiveResourcesState(false)
        end)
        body.closed = true
        log("kroppsuttag: dockans batteri stängt för kabelflöde: %s", tostring(okC))
    end
    -- AddResource moves exactly and at once (RemoveResource took less).
    local want = ownLevel(cap)
    if math.abs(want - cur) > 0.01 then module:AddResource(ELECTRICITY, want - cur) end
    local okB, errB = pcall(balance, bat)
    if not okB then log("kroppsuttag-utjämning: %s", tostring(errB)) end
    if now() - flowLog.at >= 5 then
        if flowLog.sent ~= 0 or flowLog.got ~= 0 then
            local okL, _, have = pcall(battery)
            log("kroppsuttag: utjämning gav %.1f, bad om %.1f, mitt batteri %s", flowLog.sent, flowLog.got,
                okL and string.format("%.1f", have) or "?")
        end
        flowLog.sent, flowLog.got, flowLog.at = 0, 0, now()
    end
end

-- Fastened to the bone in whatever pose the puppet had when it was made: made
-- while the other player sat at the wheel, it ended up at the knees pointing
-- up once they stood (27 cm up instead of 116, 2026-11-23). While the puppet
-- stands still and upright, a socket off its place is fastened again.
local REANCHOR_CHECK = 2
local REANCHOR_OFF = 6         -- cm
local REANCHOR_FACE = 0.95     -- dot product with the wanted face direction

local function reanchor(puppet)
    local bat = StaticFindObject(body.batPath)
    local sock = bat and bat:IsValid() and socketMesh(bat)
    if not sock then return end
    local l, f, u = puppet:K2_GetActorLocation(), puppet:GetActorRightVector(), puppet:GetActorUpVector()
    local last = body.lastPos
    body.lastPos = l
    if not last or (l.X - last.X) ^ 2 + (l.Y - last.Y) ^ 2 + (l.Z - last.Z) ^ 2 > 4 then return end
    local bone = puppet.SkeletalMeshComponent:GetSocketLocation(FName(CHEST_BONE))
    local boneUp = dot({ X = bone.X - l.X, Y = bone.Y - l.Y, Z = bone.Z - l.Z }, u)
    if math.abs(boneUp - POWERSOCKET_HEIGHT) > 10 then return end
    local s = sock:K2_GetComponentLocation()
    local d = { X = s.X - l.X, Y = s.Y - l.Y, Z = s.Z - l.Z }
    local r = puppet:GetActorForwardVector()
    local off = math.sqrt((dot(d, f) - SOCKET_FORWARD) ^ 2 + dot(d, r) ^ 2 + (dot(d, u) - POWERSOCKET_HEIGHT - SOCKET_UP) ^ 2)
    local c, sn = math.cos(math.rad(SOCKET_TILT)), math.sin(math.rad(SOCKET_TILT))
    local face = dot(sock:GetRightVector(), comb(f, u, f, c, -sn, 0))
    if off <= REANCHOR_OFF and face >= REANCHOR_FACE then return end
    bat:K2_DetachFromActor(1, 1, 1)
    turnBody(bat, puppet)
    placeBody(bat, puppet)
    bat:K2_AttachToComponent(puppet.SkeletalMeshComponent, FName(CHEST_BONE), 1, 1, 1, false)
    log("kroppsuttag: fäst om, satt %.0f cm fel och yta %.2f", off, face)
end

local function bodyTick(puppet)
    if body.puppetAddr and body.puppetAddr ~= puppet:GetAddress() then removeBody() end
    if not body.batPath then
        if now() - lastBody >= 5 then
            lastBody = now()
            local ok, err = pcall(makeBody, puppet)
            if not ok then log("kroppsuttag-fel: %s", tostring(err)) end
        end
        return
    end
    if not body.attached then
        local bat = StaticFindObject(body.batPath)
        if bat and bat:IsValid() then pcall(placeBody, bat, puppet) end
    elseif now() - (body.checked or 0) >= REANCHOR_CHECK then
        body.checked = now()
        local ok, err = pcall(reanchor, puppet)
        if not ok then log("kroppsuttag-omfästning: %s", tostring(err)) end
    end
    if now() - lastBody >= STEP then
        lastBody = now()
        local ok, err = pcall(bodyStep)
        if not ok then log("kroppsuttag-fel: %s", tostring(err)) end
    end
end

function M.init(netModule, logFn, localPCFn, nowFn, puppetFunction, peerinvModule, textFn, consoleFn)
    net, log, localPC, now, puppetFn, peerinv, T, console = netModule, logFn, localPCFn, nowFn, puppetFunction, peerinvModule, textFn, consoleFn
end

function M.socketPath() return body.batPath end

function M.reset()
    peerLevel, peerMax = nil, nil
    pending.inn, pending.out, lastFrame = 0, 0, nil
    body, lastBody = {}, -100
end

function M.tick()
    local puppet = puppetFn()
    if not (puppet and puppet:IsValid()) then
        if body.batPath then pcall(removeBody) end
        return
    end
    bodyTick(puppet)
    if now() - lastLevel >= 2 then
        lastLevel = now()
        local ok, _, have, max = pcall(battery)
        if ok then net.send("pwrlvl", string.format("%.1f", have + pending.inn - pending.out), string.format("%.1f", max)) end
    end
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "pwr" then
        local amount = tonumber(msg[3]) or 0
        local ok, err = pcall(function()
            local _, have, max = battery()
            local fits = math.max(0, math.min(amount, max - have - pending.inn))
            if fits > 0 then pending.inn = pending.inn + fits markFlow(false) end
            if fits < amount then net.send("pwrback", string.format("%.2f", amount - fits)) end
        end)
        if not ok then log("ström-fel: %s", tostring(err)) end
        return true
    elseif kind == "pwrmode" then
        local ok, err = pcall(applyPeerMode, msg[3])
        if not ok then log("kroppsuttag-läge: %s", tostring(err)) end
        return true
    elseif kind == "pwrpull" then
        -- The host balancing a player-to-player cable asks for this much.
        local amount = tonumber(msg[3]) or 0
        local ok, err = pcall(function()
            local _, have = battery()
            local give = math.min(amount, have - pending.out)
            if give > 0 then
                pending.out = pending.out + give
                net.send("pwr", string.format("%.2f", give))
                markFlow(true)
            end
        end)
        if not ok then log("ström-fel (utjämning): %s", tostring(err)) end
        return true
    elseif kind == "pwrback" then
        local amount = tonumber(msg[3]) or 0
        pending.inn = pending.inn + amount
        return true
    elseif kind == "pwrlvl" then
        peerLevel, peerMax = tonumber(msg[3]), tonumber(msg[4])
        return true
    end
    return false
end

return M
