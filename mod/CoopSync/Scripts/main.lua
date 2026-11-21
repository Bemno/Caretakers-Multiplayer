-- UE4SS 4 names a rotator's pitch "pitch" both out and in, and ignores "Pitch" (3.0.1 used
-- "Pitch"), so since the move to UE4SS 4 every synced pitch was 0. Read and build rotators with these.
-- PITCH_FIX = false behaves as before the fix (control run on the bench, 2026-11-19).
-- Off from 19/11: on, the boat threw itself about when the guest took it over at the
-- quay. That was the stowed anchors (boat.lua restartRaisedAnchors); on again 21/11
-- after the same run with and without it gave the same tilt (11 and 10 degrees at speed).
PITCH_FIX = true
function RotP(r) if not PITCH_FIX then return r and r.Pitch end return r and (r.pitch or r.Pitch) end
function Rot(p, y, r) if not PITCH_FIX then return { Pitch = p, Yaw = y, Roll = r } end return { pitch = p, Pitch = p, Yaw = y, Roll = r } end

local UEHelpers = require("UEHelpers")
local net = require("net")
local spy = require("spy")
local doors = require("doors")
local props = require("props")
local drops = require("drops")
local power = require("power")
local lobby = require("lobby")
local friends = require("friends")
local hostlost = require("hostlost")
local menu = require("menu")
local death = require("death")
local pausemenu = require("pausemenu")
local prog = require("prog")
local inv = require("inv")
local build = require("build")
local boat = require("boat")
local weather = require("weather")
local ocean = require("ocean")
local swarms = require("swarms")
local npc = require("npc")
local loading = require("loading")
local rec = require("rec")
local boxes = require("boxes")
local machines = require("machines")
local repair = require("repair")
local vehicles = require("vehicles")
local lamp = require("lamp")
local paint = require("paint")
local gear = require("gear")
local zap = require("zap")
local drone = require("drone")
local anim = require("anim")
local mapicons = require("mapicons")
local terminals = require("terminals")
local peerinv = require("peerinv")
local peerpower = require("peerpower")
local text = require("text")

local function arg(cmdline, key)
    return cmdline:match("%-" .. key .. "=(%S+)")
end

local cmdline = UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString()
-- The test bench passes the role on the command line and gives each game its
-- own io folder; a normal start picks the role from the menu and uses "main".
local cmdRole = arg(cmdline, "coopRole")
local slot = arg(cmdline, "coopSlot")
local join = arg(cmdline, "coopJoin")
-- World names may contain spaces, so this one can be quoted.
local hostWorld = cmdline:match('"%-coopHost=([^"]+)"') or cmdline:match('%-coopHost="([^"]+)"') or arg(cmdline, "coopHost")
local ioName = cmdRole or arg(cmdline, "coopIo") or "main"
local role

local logPath = "ue4ss/Mods/CoopSync/coopsync_" .. ioName .. ".log"

local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print("[CoopSync] " .. line .. "\n")
    local f = io.open(logPath, "a")
    if f then
        f:write(os.date("%H:%M:%S "), line, "\n")
        f:close()
    end
end

-- Since UE4SS 4 calls inside pcall failed silently for days (the hull never
-- found, pitch always 0; 2026-11-15..18). The first error of each pcall site
-- is logged; the global is replaced, so every module's pcall goes through here.
local rawPcall = pcall
local pcallSeen, pcallLogged = {}, 0
local function pcallDone(ok, ...)
    if not ok and pcallLogged < 300 then
        local info = debug and debug.getinfo(2, "Sl")
        local site = info and ((info.short_src or "?"):match("[^/\\]+$") .. ":" .. tostring(info.currentline)) or "?"
        if not pcallSeen[site] then
            pcallSeen[site] = true
            pcallLogged = pcallLogged + 1
            rawPcall(log, "pcall-fel %s: %s", site, (tostring((...)):match("[^\n]*")))
        end
    end
    return ok, ...
end
function pcall(f, ...) return pcallDone(rawPcall(f, ...)) end


-- UEHelpers.GetPlayerController can return another player's controller, so
-- everything keys off the local one.
-- FindAllOf walks the whole object array, and every module asks for the
-- controller several times a tick (the boat once a frame), so it is cached.
local cachedPC, cachedPCAt = nil, -100
local function localPC()
    local t = os.clock()
    if cachedPC and t - cachedPCAt < 2 then
        local ok, valid = pcall(function() return cachedPC:IsValid() end)
        if ok and valid then return cachedPC end
    end
    cachedPCAt = t
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local ok, isLocal = pcall(function() return pc:IsValid() and pc:IsLocalController() end)
        if ok and isLocal then cachedPC = pc return pc end
    end
    cachedPC = nil
    return UEHelpers.GetPlayerController()
end

local function levelName()
    return UEHelpers.GetGameplayStatics():GetCurrentLevelName(localPC(), true):ToString()
end

local function realTime()
    return UEHelpers.GetGameplayStatics():GetRealTimeSeconds(localPC())
end

local function console(cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(localPC(), cmd, nil)
end

-- The other player is shown as a puppet: the player character mesh on a
-- SkeletalMeshActor placed at the positions they send. It has no controller,
-- so no game systems react to it.
local puppet, puppetPending, target, summonAt = nil, false, nil, 0
local PUPPET_MESH = "/Game/Characters/Mechanical_Light_01_A/SKM_PlayerCharacter.SKM_PlayerCharacter"
-- The pawn location is the capsule centre and the mesh faces +Y.
local PUPPET_Z_OFFSET, PUPPET_YAW_OFFSET = -102, -90
local PUPPET_FILE = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/puppet.txt"

-- Locomotion: the game's own sequences for the player skeleton (SK_Mannequin),
-- picked by how fast the other player moves. Speeds in cm/s.
local ANIMS = {
    idle = "/Game/Characters/Mannequins/Animations/Manny/MM_Idle.MM_Idle",
    walk = "/Game/Animations/UTA/AnimSeq_Traversal_Movement_Walk_Forward.AnimSeq_Traversal_Movement_Walk_Forward",
    run = "/Game/Animations/UTA/AnimSeq_Traversal_Movement_Run_Forward1.AnimSeq_Traversal_Movement_Run_Forward1",
    sprint = "/Game/Animations/UTA/AnimSeq_Traversal_Movement_Sprint.AnimSeq_Traversal_Movement_Sprint",
}
local ANIM_SPEED = { walk = 160, run = 380, sprint = 600 }
local speed, lastTarget, lastTargetT, lastSpeedLog = 0, nil, nil, 0
local animState

local function animAsset(name)
    local path = ANIMS[name]
    local a = StaticFindObject(path)
    if a and a:IsValid() then return a end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and loaded and loaded:IsValid() then return loaded end
end

local function stateFor(v)
    if v < 40 then return "idle" end
    if v < 270 then return "walk" end
    if v < 500 then return "run" end
    return "sprint"
end

local function trackSpeed(t)
    -- Switching between world and boat coordinates is not movement.
    if lastTarget and lastTarget.boat ~= t.boat then lastTarget = nil end
    if lastTarget and lastTargetT and t.st > lastTargetT then
        local dx, dy = t.x - lastTarget.x, t.y - lastTarget.y
        local v = math.sqrt(dx * dx + dy * dy) / (t.st - lastTargetT)
        if v < 3000 then speed = speed * 0.85 + v * 0.15 end
    end
    lastTarget, lastTargetT = t, t.st
end

-- Positions carry the sender's time and the puppet is placed every frame,
-- interpolated PUPPET_DELAY behind (like boat.lua and npc.lua). Placed per
-- tick, halfway toward the newest position, it jumped 15 times a second and
-- trailed behind.
local POS_INTERVAL = 1 / 30
-- 0.12 ran out when a position arrived 0.10-0.13 s after the last one (seen
-- in the docka log line) and the guest's puppet stopped for a moment.
local PUPPET_DELAY = 0.16
local MAX_EXTRAPOLATE = 0.2
local posBuf, posOffset, lastPosSent, posReady = {}, nil, -100, false
local posRelaxedAt

-- Gaps over 0.1 s, for the log: in the arrival times (transport) and in the
-- sender's stamps (the sender itself was late).
local posGap = { at = 0, n = 0, recvMax = 0, sendMax = 0, lastRecv = nil, lastSt = nil }

local function notePosGap(st)
    local r = realTime()
    local g = posGap
    if g.lastRecv then
        local dr, ds = r - g.lastRecv, st - g.lastSt
        if dr > 0.1 or ds > 0.1 then g.n = g.n + 1 end
        g.recvMax, g.sendMax = math.max(g.recvMax, dr), math.max(g.sendMax, ds)
    end
    g.lastRecv, g.lastSt = r, st
    if r - g.at >= 5 then
        if g.n > 0 then log("docka: %d luckor över 0,1 s, längsta ankomst %.0f ms, längsta avsändning %.0f ms", g.n, g.recvMax * 1000, g.sendMax * 1000) end
        g.at, g.n, g.recvMax, g.sendMax = r, 0, 0, 0
    end
end

local function addPosSample(t)
    notePosGap(t.st)
    local off = realTime() - t.st
    -- The smallest offset is the one with the least delay; a much larger one
    -- means the other game restarted and its clock with it.
    if not posOffset or off < posOffset or off - posOffset > 1 then posOffset = off end
    t.off = off
    if #posBuf > 0 and posBuf[#posBuf].boat ~= t.boat then posBuf = {} end
    posBuf[#posBuf + 1] = t
    if #posBuf > 30 then table.remove(posBuf, 1) end
end

local function wrapYaw(a) return (a + 180) % 360 - 180 end

local function puppetSample()
    local n = #posBuf
    if n == 0 or not posOffset then return target end
    local t = realTime()
    posOffset = boat.relaxOffset(posOffset, posBuf, t - (posRelaxedAt or t))
    posRelaxedAt = t
    local renderT = t - posOffset - PUPPET_DELAY
    for i = n - 1, 1, -1 do
        local a, b = posBuf[i], posBuf[i + 1]
        if a.st <= renderT and renderT <= b.st then
            local k = (renderT - a.st) / math.max(b.st - a.st, 0.001)
            return { x = a.x + (b.x - a.x) * k, y = a.y + (b.y - a.y) * k, z = a.z + (b.z - a.z) * k,
                yaw = a.yaw + wrapYaw(b.yaw - a.yaw) * k, boat = b.boat }
        end
    end
    local last = posBuf[n]
    if n >= 2 and renderT > last.st then
        local prev = posBuf[n - 1]
        local k = math.min(renderT - last.st, MAX_EXTRAPOLATE) / math.max(last.st - prev.st, 0.001)
        return { x = last.x + (last.x - prev.x) * k, y = last.y + (last.y - prev.y) * k, z = last.z + (last.z - prev.z) * k,
            yaw = last.yaw, boat = last.boat }
    end
    return renderT < posBuf[1].st and posBuf[1] or last
end

local function animatePuppet()
    if anim.apply(puppet.SkeletalMeshComponent) then return end
    local want = stateFor(speed)
    local skc = puppet.SkeletalMeshComponent
    if want ~= animState then
        local a = animAsset(want)
        if a then
            skc:PlayAnimation(a, true)
            animState = want
        end
    end
    local ref = ANIM_SPEED[animState]
    if ref then pcall(function() skc:SetPlayRate(math.max(0.6, math.min(1.6, speed / ref))) end) end
    if os.time() - lastSpeedLog >= 5 and speed > 40 then
        lastSpeedLog = os.time()
        log("docka: fart %.0f cm/s, %s", speed, tostring(animState))
    end
end

-- A copy of the boat's map/HUD marker on the puppet, so the other player can
-- be found through walls.
local LOCATOR_CLASS = "/Script/Voyage.VoyageLocatorComponent"
local MARKER_INDICATOR = "/Game/Data/Indicator/DA_Indicator_Basic.DA_Indicator_Basic"
local MARKER_RANGE = 30000
local function addMarker(actor)
    local ok, locs = pcall(FindObjects, 0, "VoyageLocatorComponent", "", 0, 0x10, false)
    local src
    for _, l in ipairs((ok and locs) or {}) do
        local okN, name = pcall(function() return l.properties.Name:ToString() end)
        if okN and name == "Mainboat" then
            local owner = l:GetOwner()
            if owner and owner:IsValid() then src = l break end
        end
    end
    if not src then log("markör: hittar ingen förlaga") return end
    local comp = actor:AddComponentByClass(StaticFindObject(LOCATOR_CLASS), false,
        { Translation = { X = 0, Y = 0, Z = 190 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    comp.properties = src.properties
    local name = lobby.peerName or "Kompis"
    comp.properties.Name = "Kompis"
    comp.properties.Group = "Kompis"
    comp.properties.DisplayName = FText(name)
    comp.LocationAsset = src.LocationAsset
    -- The game's plain dot with the friend's name, shown through walls up to
    -- 300 m, instead of the boat's own icon (user's choice 2026-11-18).
    local okI, errI = pcall(function()
        local ind = StaticFindObject(MARKER_INDICATOR)
        if not (ind and ind:IsValid()) then ind = LoadAsset(MARKER_INDICATOR) end
        if ind and ind:IsValid() then comp.OverrideIndicator = ind end
        local p = comp.properties
        p.bUseConfigAsset = false
        local c = p.Config
        c.VisibilityRange = { X = 0, Y = MARKER_RANGE }
        -- EVoyageLocatorStateFlag: 0 always, 1 never (1 hid the dot at first).
        c.Type = 1   -- EVoyageLocatorType::Player
        c.ShowInHud, c.ShowIconInHud, c.ShowNameInHud, c.ShowDistanceInHud = 0, 0, 0, 0
        c.ShowInMap, c.ShowIconInMap, c.ShowNameInMap = 0, 0, 0
        c.ShowGroupInHud, c.ShowGroupInMap = 1, 1
    end)
    if not okI then log("markör: pricken gick inte att sätta: %s", tostring(errI)) end
    comp:SetHashKey("CoopKompis")
    comp:BPRegisterLocator()
    log("markör på dockan")
end

-- Players must not walk or spawn into each other (tested 2026-11-17): a
-- player-sized capsule on the puppet, query only and answering nothing but
-- Pawn, so the local player's movement is blocked and pushed out while the
-- boat, crates and the E trace pass through it. The actor stands at its feet.
local function addBlocker(actor)
    local cap = actor:AddComponentByClass(StaticFindObject("/Script/Engine.CapsuleComponent"), false,
        { Translation = { X = 0, Y = 0, Z = 90 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    cap:SetCapsuleSize(34, 90, true)
    cap:SetCollisionObjectType(2)
    cap:SetCollisionResponseToAllChannels(0)
    cap:SetCollisionResponseToChannel(2, 2)
    cap:SetGenerateOverlapEvents(false)
    cap:SetCollisionEnabled(1)
    log("dockans kapsel: blockerar gubbar")
end

-- Swarm creatures go for the nearest player (tested 2026-11-17): the puppet
-- gets a swarm attractor like the player's, so in each game the creatures are
-- drawn to whichever is nearer. Damage only lands in a player's own game.
local function addSwarmAttractor(actor)
    local cls = StaticFindObject("/Script/Voyage.VoyageSwarmAttractorComponent")
    local src = localPC().Pawn:GetComponentByClass(cls)
    if not (src and src:IsValid()) then return end
    local dst = actor:AddComponentByClass(cls, false,
        { Translation = { X = 0, Y = 0, Z = 90 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    for _, f in ipairs({ "Enabled", "Multiplier", "UseWeaponAbilityAgainst", "AttractorTypes", "AttractorTypeOverrides" }) do
        pcall(function() dst[f] = src[f] end)
    end
    -- The attractor alone is never a target: the particles pick a spawner
    -- volume, and the handler makes a target dummy only for an actor that has
    -- one (the player, batteries; bench 2026-11-17).
    local volCls = StaticFindObject("/Script/Voyage.VoyageSpawnerVolume")
    local srcVol = localPC().Pawn:GetComponentByClass(volCls)
    local vol = actor:AddComponentByClass(volCls, false,
        { Translation = { X = 0, Y = 0, Z = 90 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    if srcVol and srcVol:IsValid() then
        pcall(function() vol.Radius = srcVol.Radius vol.bEnabled = srcVol.bEnabled end)
    end
    log("dockan lockar svärmdjur")
end

-- The summoned puppet is the SkeletalMeshActor without a mesh. It is found by
-- searching after the summon; a NotifyOnNewObject callback would enter Lua for
-- every such actor streamed in during loading, which has crashed UE4SS.
local candidates = {}
local function collectCandidates()
    local ok, found = pcall(FindObjects, 0, "SkeletalMeshActor", "", 0, 0, true)
    candidates = (ok and found) or {}
end

local function adoptPuppet()
    for i = #candidates, 1, -1 do
        local actor = candidates[i]
        local ok, meshless = pcall(function()
            if not actor:IsValid() then return false end
            local m = actor.SkeletalMeshComponent:GetSkinnedAsset()
            return not (m and m:IsValid())
        end)
        if ok and meshless then
            local skc = actor.SkeletalMeshComponent
            skc:SetSkeletalMeshAsset(StaticFindObject(PUPPET_MESH))
            pcall(function() skc:SetCollisionEnabled(0) end)
            local okS, errS = pcall(addSwarmAttractor, actor)
            if not okS then log("dockans svärmlockare: %s", tostring(errS)) end
            local okC, errC = pcall(addBlocker, actor)
            if not okC then
                log("dockans kapsel: %s", tostring(errC))
                actor:SetActorEnableCollision(false)
            end
            puppet, puppetPending, candidates = actor, false, {}
            animState = nil
            anim.reset()
            local okM, errM = pcall(addMarker, actor)
            if not okM then log("markör-fel: %s", tostring(errM)) end
            log("docka skapad: %s", actor:GetFullName())
            local f = io.open(PUPPET_FILE, "w")
            if f then
                f:write(actor:GetFullName():match("%S+%s+(%S+)") or "")
                f:close()
            end
            return
        end
    end
end

-- A hot reload starts a fresh Lua state, so the previous puppet is found by
-- the name saved when it was adopted and removed.
local function removeOldPuppet()
    local f = io.open(PUPPET_FILE, "r")
    if not f then return end
    local path = f:read("*l")
    f:close()
    os.remove(PUPPET_FILE)
    if not path or path == "" then return end
    local old = StaticFindObject(path)
    if old and old:IsValid() then
        old:K2_DestroyActor()
        log("gammal docka borttagen: %s", path)
    end
end

-- Every frame (boat.lua's frame hook) and every tick: the puppet where the
-- interpolated sample says, in the boat's frame when it is attached to one.
-- What it is attached to is decided in the tick (puppetOn: boat key or
-- false); a pose equal to the last one placed is not placed again.
local puppetOn, puppetPlaced = false, nil

local function placePuppet()
    if not (puppet and puppet:IsValid()) or (Coop and Coop.freezePuppet) then return end
    local s = puppetSample()
    if not s or (s.boat or false) ~= puppetOn then return end
    -- A player standing on a bobbing boat sends positions that wobble by
    -- hundredths of a centimetre; placing (about 85 µs) is skipped for those.
    local q = puppetPlaced
    if q and math.abs(q.x - s.x) < 0.3 and math.abs(q.y - s.y) < 0.3 and math.abs(q.z - s.z) < 0.3
        and math.abs(wrapYaw(q.yaw - s.yaw)) < 0.3 then return end
    puppetPlaced = s
    local rot = Rot(0, s.yaw + PUPPET_YAW_OFFSET, 0)
    local loc = { X = s.x, Y = s.y, Z = s.z + PUPPET_Z_OFFSET }
    if s.boat then
        -- Placed in the world from the boat's pose (the attachment stays): the
        -- relative setter has a hit result out parameter that leaks in UE4SS.
        local b = boat.find(s.boat)
        if not b then return end
        local kml = UEHelpers.GetKismetMathLibrary()
        loc = kml:TransformLocation(b:GetTransform(), loc)
        rot = kml:ComposeRotators(rot, b:K2_GetActorRotation())
    end
    boat.moveActor(puppet, loc, rot)
end

local function updatePuppet()
    if not target or (Coop and Coop.freezePuppet) then return end
    if not (puppet and puppet:IsValid()) then
        puppet = nil
        if puppetPending then collectCandidates() adoptPuppet() end
        -- A summon sent while the world is still loading is lost, so retry.
        if not puppet and (not puppetPending or os.time() - summonAt >= 5) then
            puppetPending, candidates, summonAt = true, {}, os.time()
            console("summon SkeletalMeshActor")
        end
        return
    end
    -- On a boat the puppet is attached to it and placed in the boat's frame,
    -- so it moves with the boat every frame and only deck movement animates.
    local deck = target.boat and boat.find(target.boat)
    local root = puppet.RootComponent
    local parent = root:GetAttachParent()
    local attachedTo = parent and parent:IsValid() and parent:GetOwner()
    if deck then
        if not (attachedTo and attachedTo:IsValid() and attachedTo:GetAddress() == deck:GetAddress()) then
            puppet:K2_AttachToActor(deck, FName("None"), 1, 1, 1, false)
            log("docka fäst på båten %s", target.boat)
        end
    elseif attachedTo and attachedTo:IsValid() then
        puppet:K2_DetachFromActor(1, 1, 1)
        log("docka lossad från båten")
    end
    local on = deck and target.boat or false
    if on ~= puppetOn then puppetOn, puppetPlaced = on, nil end
    placePuppet()
    local okA, errA = pcall(animatePuppet)
    if not okA then log("anim-fel: %s", tostring(errA)) end
end

local lastPosSeq, lastPosLog = 0, 0
local lastBaseName
local BOAT_HALF = { X = 2500, Y = 1200 }   -- measured on first use from the boat's bounds
local boatHalfMeasured = false
local onDeck   -- last position on a boat deck: { key, x, y, z, yaw } in the boat's frame

local function f1(v) return string.format("%.1f", v) end

-- Standing on a boat: the position in the boat's frame. While driving, the
-- pawn is the boat itself and the character stays where it stood, at the helm.
local function measureBoat()
    if boatHalfMeasured then return end
    for key, b in pairs(boat.list()) do
        if b:IsValid() then
            -- World-aligned bounds, so the longer side is used both ways.
            local okR, r = pcall(function()
                local o, e = {}, {}
                b:GetActorBounds(true, o, e, false)
                return (e.X and e) or e.BoxExtent
            end)
            if okR and r and r.X and r.X > 100 then
                BOAT_HALF = { X = math.max(r.X, r.Y), Y = math.min(r.X, r.Y) }
                boatHalfMeasured = true
                log("båtens gränser %s: %.0f x %.0f x %.0f", key, r.X, r.Y, r.Z)
                return
            end
        end
    end
end

local function deckPosition(pawn)
    pcall(measureBoat)
    if boat.isBoat(pawn) then
        if onDeck and onDeck.key == boat.keyOf(pawn) then return onDeck end
        return nil
    end
    -- pawn:GetMovementBase() is not callable here (UE4SS), so the base was
    -- never seen and the bounds below decided alone (2026-11-16).
    local okB, base = pcall(function() return pawn.CharacterMovement:GetMovementBase() end)
    local owner = okB and base and base:IsValid() and base:GetOwner()
    local baseName = owner and owner:IsValid() and (owner:GetClass():GetFName():ToString() .. "/" .. base:GetFName():ToString()) or "-"
    -- The deck may be a module actor attached to the boat.
    for _ = 1, 5 do
        if not (owner and owner:IsValid()) or boat.isBoat(owner) then break end
        owner = owner:GetAttachParentActor()
    end
    local l = pawn:K2_GetActorLocation()
    local how = "underlag"
    -- Standing on something that is not part of a boat (ground, the quay, its
    -- mooring socket) is never on board: next to a moored boat the puppets
    -- were inside its bounds and swayed with the waves on land (2026-11-16).
    -- The bounds below only count with nothing underfoot (jumping).
    local onLand = okB and base and base:IsValid() and not (owner and owner:IsValid() and boat.isBoat(owner))
    if onLand then owner = nil end
    if not onLand and not (owner and owner:IsValid() and boat.isBoat(owner)) then
        -- Otherwise: inside a boat's bounds counts as on board.
        owner = nil
        for _, b in pairs(boat.list()) do
            if b:IsValid() then
                local rel = UEHelpers.GetKismetMathLibrary():InverseTransformLocation(b:GetTransform(), l)
                local ax, ay = math.abs(rel.X), math.abs(rel.Y)
                local inside = (ax < BOAT_HALF.X and ay < BOAT_HALF.Y) or (ax < BOAT_HALF.Y and ay < BOAT_HALF.X)
                if inside and math.min(ax, ay) < BOAT_HALF.Y and rel.Z > -300 and rel.Z < 1500 then
                    owner, how = b, "inom båten"
                    break
                end
            end
        end
    end
    if baseName ~= lastBaseName then
        lastBaseName = baseName
        log("står på %s -> %s", baseName, owner and (boat.keyOf(owner) .. " (" .. how .. ")") or "ingen båt")
    end
    if not owner then onDeck = nil return nil end
    local rel = UEHelpers.GetKismetMathLibrary():InverseTransformLocation(owner:GetTransform(), l)
    local yaw = pawn:K2_GetActorRotation().Yaw - owner:K2_GetActorRotation().Yaw
    onDeck = { key = boat.keyOf(owner), x = rel.X, y = rel.Y, z = rel.Z, yaw = yaw }
    return onDeck
end

-- Which boat the local player is on is decided in the tick (deckPosition
-- makes many game calls); each send only works out the place on that boat.
local deckKey, deckDriving = nil, false

local function refreshDeck()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local okD, d = pcall(deckPosition, pawn)
    if not okD then log("däck-fel: %s", tostring(d)) end
    deckKey = okD and d and d.key or nil
    deckDriving = boat.isBoat(pawn)
end

-- Coop.deckMeasure (test bench): how much each way of finding the player's place on the
-- deck jumps between sends, and how far apart the two are, logged every 5 s.
local deckM = { at = 0, n = 0, jumpOld = 0, jumpBased = 0, apart = 0, noBase = 0 }
local function measureDeck(old, based)
    local m = deckM
    local function d(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    m.n = m.n + 1
    if m.lastOld then m.jumpOld = math.max(m.jumpOld, d(old, m.lastOld)) end
    m.lastOld = old
    if based then
        if m.lastBased then m.jumpBased = math.max(m.jumpBased, d(based, m.lastBased)) end
        m.lastBased = based
        m.apart = math.max(m.apart, d(old, based))
    else
        m.noBase, m.lastBased = m.noBase + 1, nil
    end
    if realTime() - m.at >= 5 then
        log("däck-mätning: %d prov, största hopp gammal %.1f cm, via bas %.1f cm, isär högst %.1f cm, utan bas %d",
            m.n, m.jumpOld, m.jumpBased, m.apart, m.noBase)
        deckM = { at = realTime(), n = 0, jumpOld = 0, jumpBased = 0, apart = 0, noBase = 0, lastOld = m.lastOld, lastBased = m.lastBased }
    end
end

local function onDeckNow(pawn, l, r)
    if not deckKey then return nil end
    if deckDriving then return onDeck end
    local b = boat.find(deckKey)
    if not b then return nil end
    local kml = UEHelpers.GetKismetMathLibrary()
    local rel = kml:InverseTransformLocation(b:GetTransform(), l)
    -- The character's location can be a frame behind the boat's (whichever moved last
    -- this frame), so at speed the puppet slid back and forth (user 2026-11-18). The
    -- location relative to the deck it stands on is saved together with the character.
    local okB, based = pcall(function()
        local bm = pawn.BasedMovement
        local base = bm.MovementBase
        if not (base and base:IsValid() and base:GetOwner():GetAddress() == b:GetAddress()) then return nil end
        -- Location is in the deck's frame without its scale, and a NetQuantize vector
        -- UE4SS will not pass on as a Vector.
        local frame = kml:MakeTransform(base:K2_GetComponentLocation(), base:K2_GetComponentRotation(), { X = 1, Y = 1, Z = 1 })
        local q = bm.Location
        return kml:InverseTransformLocation(b:GetTransform(), kml:TransformLocation(frame, { X = q.X, Y = q.Y, Z = q.Z }))
    end)
    if okB and based and math.abs(based.X - rel.X) + math.abs(based.Y - rel.Y) + math.abs(based.Z - rel.Z) > 100 then based = nil end
    if Coop and Coop.deckMeasure then measureDeck(rel, okB and based or nil) end
    if okB and based then rel = based end
    return { key = deckKey, x = rel.X, y = rel.Y, z = rel.Z, yaw = r.Yaw - b:K2_GetActorRotation().Yaw }
end

-- Flying the photo drone possesses the drone: its position was sent and the
-- puppet flew around (2026-11-18). The body stays where it stood, so for any
-- pawn that is neither the character nor a vehicle the character is sent.
local ownCharPath, bodyFor, bodyIsPawn, pawnIsChar
local function ownBody(pawn)
    local addr = pawn:GetAddress()
    if bodyFor ~= addr then
        bodyFor = addr
        local cls = pawn:GetClass():GetFName():ToString()
        pawnIsChar = cls:find("FirstPersonCharacter", 1, true) ~= nil
        if pawnIsChar then
            ownCharPath = pawn:GetFullName():match("%S+%s+(%S+)")
            bodyIsPawn = true
        else
            local veh = StaticFindObject("/Script/Voyage.VoyageVehiclePawn")
            -- The camera drone is a vehicle pawn too, but the body stays behind.
            bodyIsPawn = not cls:find("Drone", 1, true) and (boat.isBoat(pawn) or (veh and pawn:IsA(veh)) or not ownCharPath)
            if not bodyIsPawn then log("egen pawn %s: skickar gubbens läge i stället", cls) end
        end
    end
    -- At the wheel the boat is the pawn and the character rides mounted on it
    -- (bMountCharacterWithVehicle): the boat's own place was sent and the other
    -- saw the driver standing mid-deck (user 2026-11-21).
    if bodyIsPawn and not pawnIsChar and boat.isBoat(pawn) then
        local okD, d = pcall(function() return pawn:GetDriver() end)
        if okD and d and d:IsValid() then return d, true end
    end
    if bodyIsPawn then return pawn end
    local c = StaticFindObject(ownCharPath)
    if c and c:IsValid() then return c end
    return pawn
end

local function sendOwnPosition()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local own = pawn
    local driver
    pawn, driver = ownBody(pawn)
    if own ~= pawn and drone.isDrone(own) then
        local okDr, errDr = pcall(drone.send, own)
        if not okDr then log("drönare-sändfel: %s", tostring(errDr)) end
    else
        drone.stopped()
    end
    local l = pawn:K2_GetActorLocation()
    local r = pawn:K2_GetActorRotation()
    local okD, d = pcall(onDeckNow, pawn, l, r)
    lastPosSent = realTime()
    local st = string.format("%.3f", lastPosSent)
    if okD and d then
        net.send("pos", st, f1(l.X), f1(l.Y), f1(l.Z), f1(r.Yaw), d.key, f1(d.x), f1(d.y), f1(d.z), f1(d.yaw))
    else
        if not okD then log("däck-fel: %s", tostring(d)) end
        net.send("pos", st, f1(l.X), f1(l.Y), f1(l.Z), f1(r.Yaw))
    end
    -- At the wheel the sent body is the boat, which has no mesh: the error
    -- was logged every frame (2026-11-18).
    local isChar = pawnIsChar or not bodyIsPawn or driver
    if isChar then
        local okN, errN = pcall(anim.send, pawn, lastPosSent)
        if not okN then log("anim-sändfel: %s", tostring(errN)) end
    end
    zap.frame()
    local okDf, errDf = pcall(drone.frame, puppet)
    if not okDf then log("drönare-fel: %s", tostring(errDf)) end
    local now = os.time()
    if now - lastPosLog >= 5 then
        lastPosLog = now
        local p = puppet and puppet:IsValid() and puppet:K2_GetActorLocation()
        log("jag %.0f %.0f %.0f | docka %s", l.X, l.Y, l.Z, p and string.format("%.0f %.0f %.0f", p.X, p.Y, p.Z) or "-")
    end
end

-- Echo test: the host pings, the guest answers, the host reports round trips.
local pingSent, pongs, rttSum, rttMax, lastPing = 0, 0, 0, 0, 0

local worldSince
-- The guest keeps the host's world messages until its own world has settled
-- (the same 30 s the modules wait). Handled while the world was still loading,
-- the host's first burst (boat, weather, swarms) crashed the guest inside
-- UE4SS a few seconds later, every time the guest joined a world the host had
-- just made (LAN, 2026-11-17). Positions are dropped, the rest is replayed.
local early = {}
local EARLY_MAX = 20000
-- The world counts as settled once it has run calmly: at least SETTLE_MIN s in,
-- the own pawn there, and no tick later than HITCH for CALM_SECONDS (a world
-- still streaming in stalls the game). Never later than SETTLE_MAX, the fixed
-- 30 s used before (2026-11-21): a fast computer gets in sooner, a slow one
-- still waiting on streaming waits as before.
local SETTLE_MIN, SETTLE_MAX, CALM_SECONDS, HITCH = 15, 30, 5, 0.15
local settledAt, calmSince, lastTickAt
local function updateSettle()
    if settledAt then return end
    local t = realTime()
    if lastTickAt and t - lastTickAt > HITCH then calmSince = nil end
    lastTickAt = t
    calmSince = calmSince or t
    local since = t - worldSince
    local p = localPC().Pawn
    local pawnOk = p ~= nil and p:IsValid()
    if since >= SETTLE_MAX or (since >= SETTLE_MIN and pawnOk and t - calmSince >= CALM_SECONDS) then
        settledAt = t
        log("världen satt sig efter %.1f s (%s)", since, since >= SETTLE_MAX and "längsta väntan" or "lugnt i " .. CALM_SECONDS .. " s")
    end
end

local function guestSettled()
    return worldSince ~= nil and settledAt ~= nil and levelName() == "VoyageWorld2"
end

local function handle(msg)
    if msg[1] == "mouse" then pcall(death.mouse, msg) pcall(pausemenu.mouse, msg) end
    -- coopnet's own lines carry sequence 0; anything else came from the other game.
    if msg[2] ~= "0" then hostlost.heard() end
    if msg[1] == "hostbye" then hostlost.hostBye() return end
    if menu.handle(msg) or friends.handle(msg) or lobby.handle(msg) then return end
    if not role then return end
    if role == "guest" and not guestSettled() then
        if msg[1] ~= "pos" and #early < EARLY_MAX then early[#early + 1] = msg end
        return
    end
    if doors.handle(msg) or swarms.handle(msg) or props.handle(msg) or drops.handle(msg) or paint.handle(msg) or gear.handle(msg) or zap.handle(msg, puppet) or drone.handle(msg) or power.handle(msg) or prog.handle(msg) or build.handle(msg) or boat.handle(msg) or weather.handle(msg) or npc.handle(msg) or rec.handle(msg) or boxes.handle(msg) or machines.handle(msg) or repair.handle(msg) or vehicles.handle(msg) or lamp.handle(msg) or mapicons.handle(msg) or terminals.handle(msg) or peerinv.handle(msg) or peerpower.handle(msg) or anim.handle(msg) then return end
    local kind = msg[1]
    if kind == "pos" then
        local s = tonumber(msg[2])
        if s and s > lastPosSeq or (s and s < lastPosSeq - 50) then
            lastPosSeq = s
            local st = tonumber(msg[3])
            local t = { x = tonumber(msg[4]), y = tonumber(msg[5]), z = tonumber(msg[6]), yaw = tonumber(msg[7]) }
            local rel = { x = tonumber(msg[9]), y = tonumber(msg[10]), z = tonumber(msg[11]), yaw = tonumber(msg[12]) }
            if msg[8] and msg[8] ~= "" and rel.x and rel.y and rel.z and rel.yaw and boat.find(msg[8]) then
                rel.boat = msg[8]
                t = rel
            end
            if st and t.x and t.y and t.z and t.yaw then
                t.st = st
                target = t
                addPosSample(t)
                trackSpeed(target)
            end
        end
    elseif kind == "ping" and role == "guest" then
        net.send("pong", msg[3], msg[4])
    elseif kind == "pong" and role == "host" then
        local rtt = (realTime() - tonumber(msg[4])) * 1000
        pongs = pongs + 1
        rttSum = rttSum + rtt
        if rtt > rttMax then rttMax = rtt end
        if pongs % 20 == 0 then
            log("eko: %d skickade, %d svar, snitt %.0f ms, max %.0f ms (senaste 20)", pingSent, pongs, rttSum / 20, rttMax)
            rttSum, rttMax = 0, 0
        end
    end
end

local sectionCost, sectionAt = {}, os.time()
local function timed(name, fn, ...)
    local c0 = os.clock()
    local ok, err = pcall(fn, ...)
    local ms = (os.clock() - c0) * 1000
    local e = sectionCost[name] or { sum = 0, max = 0 }
    e.sum, e.max = e.sum + ms, math.max(e.max, ms)
    sectionCost[name] = e
    return ok, err
end

-- Messages are read every rendered frame once the world runs (boat.lua's
-- frame hook) and every tick otherwise; read only per tick they waited up to
-- 50 ms in each game. The frame hook runs inside an actor's tick, where a
-- handler's LoadAsset flushed async loading and the guest died with "Loading
-- is stuck, flush will never finish" (a drop of unloaded loot). There only
-- the timing-critical kinds are handled; the rest wait for the tick, which
-- UE4SS runs at the top of the engine tick.
local FRAME_KINDS = { pos = true, prop = true, boat = true, bctl = true, npc = true, doorpos = true, veh = true, ping = true, pong = true }
local backlog = {}
local NET_BUDGET = 6

local function pumpNet(fromFrame)
    local c0 = os.clock()
    local msgs = net.receive()
    local e = sectionCost["läsa"] or { sum = 0, max = 0 }
    local ms0 = (os.clock() - c0) * 1000
    e.sum, e.max = e.sum + ms0, math.max(e.max, ms0)
    sectionCost["läsa"] = e
    if fromFrame then
        local fast = {}
        for _, msg in ipairs(msgs) do
            if FRAME_KINDS[msg[1]] then fast[#fast + 1] = msg else backlog[#backlog + 1] = msg end
        end
        msgs = fast
    elseif #backlog > 0 then
        for _, msg in ipairs(msgs) do backlog[#backlog + 1] = msg end
        msgs, backlog = backlog, {}
    end
    -- Per tick the handling stops after NET_BUDGET ms and the rest waits for
    -- the next: a burst of messages took 51 ms in one tick (2026-11-17).
    for i, msg in ipairs(msgs) do
        if not fromFrame and i > 1 and (os.clock() - c0) * 1000 > NET_BUDGET then
            -- Put back in one pass: inserted one by one at the front, a backlog of
            -- thousands (loose items of a new area) cost 300 ms a tick and never
            -- drained, only for the guest (2026-11-21).
            local rest = {}
            for j = i, #msgs do rest[#rest + 1] = msgs[j] end
            for _, m in ipairs(backlog) do rest[#rest + 1] = m end
            backlog = rest
            break
        end
        local c1 = os.clock()
        local ok, err = pcall(handle, msg)
        if not ok then log("fel i %s: %s", msg[1], tostring(err)) end
        local name = "m:" .. tostring(msg[1])
        local k = sectionCost[name] or { sum = 0, max = 0 }
        local ms = (os.clock() - c1) * 1000
        k.sum, k.max = k.sum + ms, math.max(k.max, ms)
        sectionCost[name] = k
    end
end

-- Guest: the boat is placed by the mod every frame, and in high waves the
-- guest bounced on the deck and died (2026-11-15). Fall damage while the
-- guest stands on a boat is cancelled (impact velocity set to zero) and logged.
local FALL_HOOK = "/Script/Voyage.VoyageCombatBlueprintFunctionLibrary:ApplyCharacterFalldamage"
local fallGuarded = false
local function armFallGuard()
    if fallGuarded or role ~= "guest" then return end
    fallGuarded = true
    local ok, err = pcall(RegisterHook, FALL_HOOK, function(_, character, velocity)
        pcall(function()
            local c = character:get()
            local p = localPC().Pawn
            if not (c and c:IsValid() and p and p:IsValid() and c:GetAddress() == p:GetAddress()) then return end
            local v = velocity:get()
            local onBoat = props.onBoat(c:K2_GetActorLocation())
            if onBoat then velocity:set({ X = 0, Y = 0, Z = 0 }) end
            log("fallskada: fart %.0f %.0f %.0f, på båten %s%s", v.X or 0, v.Y or 0, v.Z or 0, tostring(onBoat), onBoat and ", nollad" or "")
        end)
    end)
    log("fallskydd på båten: %s", ok and "ok" or tostring(err))
end

-- name, function, error label, takes the time
local worldModules = {
    { "death", function() return death.tick() end, "död-fel" },
    { "pausemenu", function() return pausemenu.tick() end, "pausmeny-fel" },
    { "prog", function() return prog.tick() end, "progressions-fel" },
    { "inv", function(t) return inv.tick(t) end, "inventarie-fel", true },
    { "build", function() return build.tick() end, "bygge-fel" },
    { "weather", function() return weather.tick() end, "väder-fel" },
    { "ocean", function() return ocean.tick() end, "hav-fel" },
    { "npc", function() return npc.tick() end, "npc-fel" },
    { "swarms", function() return swarms.tick() end, "svärm-fel" },
    { "boxes", function() return boxes.tick() end, "lådor-fel" },
    { "machines", function() return machines.tick() end, "maskin-fel" },
    { "repair", function() return repair.tick() end, "lagnings-fel" },
    { "vehicles", function() return vehicles.tick() end, "fordons-fel" },
    { "lamp", function() return lamp.tick() end, "lamp-fel" },
    { "paint", function() return paint.tick() end, "färg-fel" },
    { "gear", function() return gear.tick() end, "utrustning-fel" },
    { "mapicons", function() return mapicons.tick() end, "karta-fel" },
    { "terminals", function() return terminals.tick() end, "terminal-fel" },
    { "peerinv", function() return peerinv.tick() end, "ryggsäck-fel" },
    { "peerpower", function() return peerpower.tick() end, "ström-fel" },
}
local WORLD_BUDGET = 4
local worldTurn, worldNext = 0, 0

local function tick()
    timed("lobby", lobby.tick)
    timed("vänner", friends.tick)
    if levelName() == "Empty" then
        local okMenu, errMenu = pcall(menu.tick)
        if not okMenu then log("meny-fel: %s", tostring(errMenu)) end
    else
        friends.setActive(false)
    end
    spy.tick()
    if rec.active then timed("rec", rec.tick) end
    timed("nät", pumpNet)
    timed("nivånamn", levelName)
    if not role then return end
    if levelName() == "Empty" and worldSince then
        -- Left a world (the guest follows the host to a reload or another world):
        -- nothing of the old world carries over into the next one.
        early = {}
        props.reset() power.reset() drops.reset() doors.reset() prog.reset()
    end
    if levelName() == "Empty" then settledAt, calmSince, lastTickAt = nil, nil, nil end
    if levelName() == "Empty" then worldSince = nil posReady, posBuf = false, {} death.reset() inv.reset() build.reset() boat.reset() weather.reset() ocean.reset() swarms.reset() npc.reset() loading.reset() boxes.reset() machines.reset() repair.reset() vehicles.reset() lamp.reset() paint.reset() gear.reset() zap.reset() drone.reset() mapicons.reset() terminals.reset() peerinv.reset() peerpower.reset() hostlost.reset() return end
    worldSince = worldSince or realTime()
    updateSettle()
    if role == "guest" and levelName() == "VoyageWorld2" then
        local since = realTime() - worldSince
        local p = localPC().Pawn
        -- Six seconds after settling (was a fixed 36 s), with the host's position in.
        local ready = (settledAt ~= nil and realTime() - settledAt >= 6 and target ~= nil and p ~= nil and p:IsValid()) or since >= 120
        local okL, errL = timed("laddvy", loading.tick, realTime(), ready)
        if not okL then log("laddvy-fel: %s", tostring(errL)) end
    end
    if not settledAt then return end
    timed("värdkoll", hostlost.tick, true)
    if #early > 0 then
        log("gäst: %d meddelanden från laddningen hanteras nu", #early)
        for _, msg in ipairs(early) do backlog[#backlog + 1] = msg end
        early = {}
    end
    props.arm()
    boat.arm()
    pcall(build.arm)
    armFallGuard()
    doors.flush()
    timed("däck", refreshDeck)
    posReady = true
    -- Sent from the frame hook; here only when that has stopped running.
    if realTime() - lastPosSent > 0.1 then timed("pos", sendOwnPosition) end
    local okProps, errProps = timed("props", props.tick)
    if not okProps then log("props-fel: %s", tostring(errProps)) end
    local okDrops, errDrops = true, nil
    if levelName() == "VoyageWorld2" then okDrops, errDrops = timed("drops", drops.tick) end
    if not okDrops then log("drops-fel: %s", tostring(errDrops)) end
    local okPower, errPower = true, nil
    if levelName() == "VoyageWorld2" then okPower, errPower = timed("power", power.tick) end
    if not okPower then log("power-fel: %s", tostring(errPower)) end
    timed("docka", updatePuppet)
    if levelName() == "VoyageWorld2" then
        -- The world modules run in turn, as many as fit in WORLD_BUDGET ms
        -- this tick, starting where the last tick stopped. All in one tick,
        -- their scans coincided and the guest's frame stood still for 20-57 ms
        -- several times every 5 s (2026-11-17); now each waits a tick or two.
        -- The boat's state goes out every tick.
        local okBoat, errBoat = timed("boat", boat.tick)
        if not okBoat then log("båt-fel: %s", tostring(errBoat)) end
        local t0 = os.clock()
        local n = #worldModules
        for k = 0, n - 1 do
            if k > 0 and (os.clock() - t0) * 1000 > WORLD_BUDGET then break end
            local m = worldModules[(worldTurn + k) % n + 1]
            local ok, err = timed(m[1], m[2], m[4] and realTime() or nil)
            if not ok then log("%s: %s", m[3], tostring(err)) end
            worldNext = (worldTurn + k + 1) % n
        end
        worldTurn = worldNext
    end
    if role == "host" then
        local now = realTime()
        if now - lastPing >= 0.5 then
            lastPing = now
            pingSent = pingSent + 1
            net.send("ping", pingSent, string.format("%.3f", now))
        end
    end
end

net.init(ioName)
log("laddad (%s), roll %s, sparplats %s, ansluter %s", ioName, tostring(cmdRole), tostring(slot), tostring(join))
doors.init(net, log)
props.init(net, log, localPC, realTime)
drops.init(net, log, localPC, realTime, props)
local npcFrameAdded = false
local function setRole(r)
    role = r
    props.isHost = r == "host"
    power.init(net, log, localPC, realTime, props, console, r == "host", function() return puppet end)
    boat.init(net, log, localPC, realTime, r == "host")
    vehicles.init(net, log, localPC, realTime, boat)
    if not npcFrameAdded then npcFrameAdded = true boat.addFrame(function() timed("nät", pumpNet, true) end) boat.addFrame(function()
        if posReady and realTime() - lastPosSent >= POS_INTERVAL then timed("pos", sendOwnPosition) end
        placePuppet()
    end) boat.addFrame(npc.frame) boat.addFrame(props.frame) boat.addFrame(vehicles.frame) end
    weather.init(net, log, localPC, realTime, props, console, r == "host")
    ocean.init(net, log, localPC, realTime, props, r == "host")
    swarms.init(net, log, localPC, realTime, r == "host", function() return puppet end)
    npc.init(net, log, localPC, realTime, console, r == "host")
    boxes.init(net, log, localPC, realTime, props, r == "host")
    machines.init(net, log, localPC, realTime, props, boxes, r == "host")
    drops.machines = machines
    repair.init(net, log, localPC, realTime, props, boxes)
    terminals.init(net, log, realTime, boxes, props)
    -- Recording (F7) is a test bench tool: only with a role from the command line.
    if cmdRole then rec.init(log, localPC, net, r == "host", ioName) rec.active = true end
    log("roll: %s", r)
end
lobby.init(net, log, levelName, setRole, ioName)
-- Back on the title screen after a session: the sync stops (a guest role left
-- on would, among other things, stop the swarm spawners in a singleplayer world).
lobby.onLeave = function() role = nil end
friends.init(net, log, lobby, ioName)
hostlost.init(log, localPC, lobby)
menu.init(lobby, log, localPC, friends)
death.init(log, localPC, function() return puppet end)
pausemenu.init(log, localPC, lobby)
prog.init(net, log, localPC, realTime)
inv.init(log, localPC, lobby, ioName, props)
build.init(net, log, realTime, props, console, localPC)
build.peerLocation = function() return puppet and puppet:IsValid() and puppet:K2_GetActorLocation() or nil end
npc.peer = function() return puppet end
loading.init(log, localPC, console)
mapicons.init(net, log, realTime)
peerinv.init(net, log, localPC, realTime, boxes, console, function() return puppet end)
boxes.skip = peerinv.isPuppetBox
peerpower.init(net, log, localPC, realTime, function() return puppet end, peerinv, text, console)
lamp.init(net, log, localPC, realTime, console, function() return puppet end)
anim.init(net, log)
paint.init(net, log, realTime, function() return role == "host" end)
gear.init(net, log, localPC, realTime, function() return puppet end)
-- The character even while driving: from the boat pawn the paint and gear came out
-- empty and the list was sent anew at every turn at the helm (pcall log 2026-11-19).
gear.body = function()
    local p = localPC().Pawn
    if not (p and p:IsValid()) then return p end
    ownBody(p)
    local c = ownCharPath and StaticFindObject(ownCharPath)
    return (c and c:IsValid()) and c or p
end
zap.init(net, log, localPC, realTime)
drone.init(net, log, localPC, realTime)
power.setPuppetSocket(peerpower.socketPath)
ExecuteInGameThread(function() pcall(removeOldPuppet) end)

-- Test bench hook: Mods/CoopSync/test_<role>.lua runs once per (re)load on the
-- game thread with access to the helpers below.
Coop = {
    log = log, net = net, localPC = localPC, console = console,
    puppet = function() return puppet end,
    -- For timing tests (testbank/motor/mikro.lua).
    sendOwnPosition = sendOwnPosition, placePuppet = placePuppet, refreshDeck = refreshDeck,
    spy = spy,
    props = props,
    drops = drops,
    power = power,
    lobby = lobby,
    death = death,
    boat = boat,
    world = function() return localPC():GetWorld() end,
    rec = rec,
    boxes = boxes,
    machines = machines,
    repair = repair,
    vehicles = vehicles,
    lamp = lamp,
    peerpower = peerpower,
}
-- Test engine: testbank2.ps1 kör drops io/<role>/cmd.lua into the running game
-- and waits for io/<role>/svar.txt. Runs in the live Lua state instead of
-- reloading the mod, which crashes once global hooks are registered.
local CMD_FILE = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/cmd.lua"
local REPLY_FILE = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/svar.txt"
local cmd = nil
local cmdCheck = 0
function Coop.say(fmt, ...)
    if not cmd then return end
    local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    cmd.out[#cmd.out + 1] = line
    log("kör: %s", line)
end
function Coop.done(err)
    if not cmd then return end
    cmd.out[#cmd.out + 1] = err and ("KLAR fel: " .. tostring(err)) or "KLAR ok"
    local tmp = REPLY_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(table.concat(cmd.out, "\n"), "\n")
        f:close()
        os.remove(REPLY_FILE)
        os.rename(tmp, REPLY_FILE)
    end
    cmd = nil
end
function Coop.wait(ms)
    if cmd then cmd.waiting, cmd.deadline = true, os.clock() + (ms or 120000) / 1000 end
end
function Coop.after(ms, fn)
    local token = cmd
    ExecuteInGameThreadWithDelay(ms, function()
        if cmd ~= token then return end
        local ok, err = pcall(fn)
        if not ok then Coop.done(err) end
    end)
end
local function pollCommand()
    if cmd then
        if cmd.waiting and os.clock() > cmd.deadline then Coop.done("tidsgräns") end
        return
    end
    local f = io.open(CMD_FILE, "r")
    if not f then return end
    local src = f:read("a")
    f:close()
    os.remove(CMD_FILE)
    cmd = { out = {} }
    local chunk, err = load(src, "=cmd")
    local ok, res = false, err
    if chunk then ok, res = pcall(chunk) end
    if not ok then Coop.done(res)
    elseif cmd and not cmd.waiting then
        if res ~= nil then Coop.say("retur: %s", tostring(res)) end
        Coop.done()
    end
end

ExecuteInGameThreadWithDelay(3000, function()
    local path = "ue4ss/Mods/CoopSync/test_" .. ioName .. ".lua"
    local f = io.open(path, "r")
    if not f then return end
    f:close()
    local ok, err = pcall(dofile, path)
    log("test_%s.lua: %s", ioName, ok and "ok" or tostring(err))
end)

local tickErrors = 0
-- The whole loop runs on the game thread: LoopAsync touched the Lua state from
-- its own thread while game-thread hooks ran in it, and the Lua GC crashed.
local tickCost = { at = os.time(), n = 0, sum = 0, max = 0 }
LoopInGameThreadWithDelay(50, function()
    cmdCheck = cmdCheck + 1
    if cmdCheck >= 10 then
        cmdCheck = 0
        local okc, errc = pcall(pollCommand)
        if not okc then log("kör-fel: %s", tostring(errc)) cmd = nil end
    end
    local c0 = os.clock()
    local ok, err = pcall(tick)
    local ms = (os.clock() - c0) * 1000
    tickCost.n, tickCost.sum = tickCost.n + 1, tickCost.sum + ms
    if ms > tickCost.max then tickCost.max = ms end
    if os.time() - tickCost.at >= 5 then
        local parts = {}
        for name, e in pairs(sectionCost) do
            if e.sum / tickCost.n > 0.3 or e.max > 5 then parts[#parts + 1] = string.format("%s %.1f/%.0f", name, e.sum / tickCost.n, e.max) end
        end
        sectionCost = {}
        log("diagnos: modens tick %.1f ms snitt, %.1f ms max (%d tick) %s", tickCost.sum / tickCost.n, tickCost.max, tickCost.n, table.concat(parts, ", "))
        tickCost = { at = os.time(), n = 0, sum = 0, max = 0 }
    end
    if not ok then
        tickErrors = tickErrors + 1
        if tickErrors <= 5 or tickErrors % 1000 == 0 then log("tick-fel #%d: %s", tickErrors, tostring(err)) end
    end
end)

if not cmdRole then lobby.startCoopnet() end
lobby.fromCommandLine(cmdRole, slot, join, hostWorld)
