-- Carried objects: whatever the local player's PhysicsGrabComponent holds is
-- sent 20 times a second, and for a few seconds after release so the landing
-- matches. Objects are matched by their save id (VoyagePersistentActorComponent
-- .PersistentUniqueId), because the actors themselves get runtime names that
-- differ between the two games. The receiver places the object every frame
-- with physics off, eased between updates and relative to the boat it is on.
local M = {}

local GRAB_CLASS = "/Script/Voyage.PhysicsGrabComponent"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local MISC = "/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary"
local KML = "/Script/Engine.Default__KismetMathLibrary"
local REMOTE_TIMEOUT = 1.5

local net, log, localPC, now
local held, heldId = nil, nil
local HELD_INTERVAL = 1 / 30
local lastHeldSent = -100
local weldSent = false
local remote = {}   -- id -> { comp, lastUpdate, from, to, span, boatKey }
local current, place, loosen
-- Crates the guest lets go of are settled by the host. On the guest's boat,
-- which the mod moves every frame, they bounced around, knocked other crates
-- loose and never welded. So the guest freezes its crate and follows the
-- host's copy, which falls on the host's steady boat and is welded there.
local FREEZE_GRACE = 2
local LIFT_ON_RELEASE = 40
local WATCH_SECONDS = 15
local REST_MOVE, REST_TICKS = 3, 10
local WELD_IGNORE = { 6, 22 }
local WELDED_TYPE, LOOSE_TYPE = 22, 5
M.isHost = false
M.sentDrops = {}    -- own ids drops.lua sent, so ocean.lua does not send them again
M.claimedPaths = {} -- actor paths drops.lua made as copies of the peer's drops
local missing = {}
-- Poses, rest and weld for a drop whose copy is not made here yet: the owner's
-- grinder output landed and rested before the copy existed, which then hung at
-- the outlet (2026-11-19). Replayed when drops.lua links the copy (M.claimed).
local early = {}    -- id -> { t, pose, rest, weld }
local EARLY_SECONDS = 30
local function noteEarly(id, field, value)
    local e = early[id]
    if not e or now() - e.t > EARLY_SECONDS then e = { t = now() } early[id] = e end
    e[field] = value
end

-- Persistent components are looked up on demand. NotifyOnNewObject is not used
-- here: thousands of them are created on the streaming thread, and entering Lua
-- from there while the game thread runs the mod crashes UE4SS.
local persistComps, byId, lastScan = {}, {}, -100
local indexed = {}          -- component address -> true once in byId

local function scanPersistent()
    if now() - lastScan < 2 then return false end
    lastScan = now()
    local ok, found = pcall(FindObjects, 0, "VoyagePersistentActorComponent", "", 0, 0, false)
    if not ok or not found then
        ok, found = pcall(FindAllOf, "VoyagePersistentActorComponent")
    end
    persistComps = (ok and found) or {}
    log("sökte föremål: %d hittade", #persistComps)
    return true
end

-- Only the save id is shared; runtime ids differ between the two games.
-- Actors placed in the level (_UAID_ in the name) go by their path, the same
-- in both games: three quay solar panels shared one save id (2026-11-16), and
-- cables and repairs went to the wrong one.
local function idOf(pc)
    local id = pc.PersistentUniqueId
    if not id or id == 0 then return nil end
    local okP, path = pcall(function() return pc:GetOwner():GetFullName():match("%S+%s+(%S+)") end)
    if okP and path and path:find("_UAID_", 1, true) then return path end
    return tostring(id)
end

local DOOR_CLASS = "/Game/Blueprints/Modules/Utility/Door/BP_DoorBase.BP_DoorBase_C"

-- Both games start from the same save, so they hand out the same new save
-- ids: the guest's copy of one host drop got the id of another host drop, and
-- the scan below let it answer for that one (2026-11-15). Paired ids win.
local aliased = {}          -- peer id -> our component
local pairedLocal = {}      -- our ids that are copies of a peer object

local function findById(id)
    local paired = aliased[id]
    if paired and paired:IsValid() then return paired end
    -- Our copy of some other peer object that happens to carry this id. Checked
    -- before the index too: there the peer's pose for its own new item moved our
    -- unrelated copy, and the two games removed each other's items (2026-11-19).
    if pairedLocal[id] then return nil end
    local hit = byId[id]
    if hit and hit:IsValid() then return hit end
    -- Each component is indexed once it has its id, and only after a fresh
    -- scan: going through all of them on every miss took up to 28 ms, and a
    -- charge message with many unknown modules 19 ms (2026-11-17).
    for _, pc in ipairs(scanPersistent() and persistComps or {}) do
        -- Keyed by address and raw id together: a freed address is reused.
        local okA, addr, raw = pcall(function() return pc:IsValid() and pc:GetAddress(), pc.PersistentUniqueId end)
        if okA and addr and raw and raw ~= 0 and indexed[addr] ~= raw then
            local okId, pid = pcall(idOf, pc)
            if okId and pid then byId[pid] = pc indexed[addr] = raw end
        end
    end
    hit = byId[id]
    if hit and hit:IsValid() then return hit end
    return nil
end

-- Objects that disappear for real (picked up into the inventory, demolished)
-- end play with reason Destroyed; streaming out uses other reasons. The other
-- game removes the same object. Ids removed on request are not echoed back.
local END_DESTROYED = 0
local removedByPeer = {}

-- Items dropped by one player get a different save id in each game; toPeer
-- translates our id to theirs when sending, byId maps theirs to our component.
local toPeer = {}
local function wire(id) return toPeer[id] or id end

M.wire = wire
function M.suppressGone(localId) removedByPeer[localId] = true end
-- Local clean-ups (the guest emptying its copy of the host's inventory) are
-- not removals the peer should mirror.
local muteUntil = 0
function M.muteGone(seconds) muteUntil = os.time() + seconds end
M.findById = function(id) return findById(id) end

-- drops.lua: an own drop just sent. The index is refreshed only every 2 s, and the
-- other game's poses for it came first: "saknas här", and the grinder's output hung
-- at the outlet in this game (2026-11-19).
function M.registerOwn(id, pc)
    byId[id] = pc
    local ok, addr, raw = pcall(function() return pc:GetAddress(), pc.PersistentUniqueId end)
    if ok then indexed[addr] = raw end
end

function M.alias(peerId, localId, pc)
    toPeer[localId] = peerId
    aliased[peerId] = pc
    if localId ~= peerId then pairedLocal[localId] = true end
end

local function onEndPlay(ctx, reason)
    local okR, r = pcall(function() return reason:get() end)
    if not okR or r ~= END_DESTROYED then return end
    if os.time() < muteUntil then return end
    local actor = ctx:get()
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if not (pc and pc:IsValid()) then return end
    local id = idOf(pc)
    if not id then return end
    if removedByPeer[id] then removedByPeer[id] = nil return end
    net.send("gone", wire(id))
    log("borta: %s (id %s)", actor:GetFullName(), id)
end

function M.init(netModule, logFn, localPCFn, nowFn)
    net, log, localPC, now = netModule, logFn, localPCFn, nowFn
end

-- Guest: bumping a welded crate on the boat unwelds it (the game detaches
-- crates on impact). Loose on the guest's boat it bounced or fell through,
-- and the host never knew; it is welded back where it was.
local DETACH_HOOK = "/Script/Voyage.VoyageLocatorSubsystem:OnActorDetached"
local detached = {}   -- { child = path, parent = path }, queued by the hook

-- Registered once the world has settled; during loading EndPlay runs for many
-- actors and entering Lua that often has crashed UE4SS.
local armed = false
function M.arm()
    if armed then return end
    armed = true
    local ok, err = pcall(RegisterEndPlayPreHook, function(ctx, reason)
        local okCb, errCb = pcall(onEndPlay, ctx, reason)
        if not okCb then log("endplay-fel: %s", tostring(errCb)) end
    end)
    log("borttagningssynk: %s", ok and "ok" or tostring(err))
    local okD, errD = pcall(RegisterHook, DETACH_HOOK, function(_, child, parent)
        pcall(function()
            local c, p = child:get(), parent:get()
            if c and c:IsValid() and p and p:IsValid() and p:GetFName():ToString() == "VehicleMesh"
                and not M.ownsBoat(p:GetOwner()) then
                detached[#detached + 1] = { child = c:GetFullName():match("%S+%s+(%S+)"), parent = p:GetFullName():match("%S+%s+(%S+)") }
            end
        end)
    end)
    log("lossningskrok: %s", okD and "ok" or tostring(errD))
end

-- Returns the grabbed primitive component and the save id of its actor.
local function grabbed()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return nil end
    local grab = pawn:GetComponentByClass(StaticFindObject(GRAB_CLASS))
    if not (grab and grab:IsValid()) then return nil end
    local ok, comp = pcall(function() return grab.GrabbedComponent:Get() end)
    if not ok or not (comp and comp:IsValid()) then return nil end
    local owner = comp:GetOwner()
    if not (owner and owner:IsValid()) then return nil end
    -- Doors are grabbed too, but they are synced by doors.lua.
    local door = StaticFindObject(DOOR_CLASS)
    if door and door:IsValid() and owner:IsA(door) then return nil end
    -- Cables are synced by power.lua; moving the whole actor would tear them.
    local cable = StaticFindObject("/Script/Voyage.ModulesConnectCable")
    if cable and cable:IsValid() and owner:IsA(cable) then return nil end
    -- Levers (the wheel, the throttle) are grabbed to turn them; carried like
    -- a crate, the other game's wheel was turned 90 degrees (2026-11-18).
    -- boat.lua and power.lua sync their values.
    local lever = StaticFindObject("/Script/Voyage.VoyageModuleGenericSwitchActor")
    if lever and lever:IsValid() and owner:IsA(lever) then return nil end
    local pc = owner:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if not (pc and pc:IsValid()) then return comp, nil end
    return comp, idOf(pc)
end

local function f1(v) return string.format("%.1f", v or 0) end

-- The game welds a crate to whatever it lands on (bAutoWeld). The welded
-- position is sent relative to the parent's component, both matched by save
-- id and component name, so the other game welds its copy the same way.
local function sendWeld(comp, id)
    local parent = comp:GetAttachParent()
    if not (parent and parent:IsValid()) then log("svetsad id %s men utan förälder", id) return end
    local owner = parent:GetOwner()
    local ppc = owner and owner:IsValid() and owner:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local pid = ppc and ppc:IsValid() and idOf(ppc)
    if not pid then log("svetsad id %s på %s utan spar-id, skickas inte", id, owner and owner:GetFullName() or "?") return end
    local rel = StaticFindObject(KML):MakeRelativeTransform(comp:K2_GetComponentToWorld(), parent:K2_GetComponentToWorld())
    local l = rel.Translation
    local r = StaticFindObject(KML):Quat_Rotator(rel.Rotation)
    net.send("weld", wire(id), wire(pid), parent:GetFName():ToString(),
        f1(l.X), f1(l.Y), f1(l.Z), f1(RotP(r)), f1(r.Yaw), f1(r.Roll))
    log("svetsad id %s på %s/%s, skickad", id, owner:GetFullName(), parent:GetFName():ToString())
end

-- GetActorBounds has out parameters, which UE4SS 3.0.1 never frees (see
-- boat.moveActor), and it ran 30 times a second while a crate was carried:
-- each boat's bounds are kept for BOUNDS_SECONDS.
local BOUNDS_SECONDS = 1
local boundsCache = {}      -- actor address -> { at, c, x }

local function bounds(actor)
    local key = actor:GetAddress()
    local b = boundsCache[key]
    if b and now() - b.at < BOUNDS_SECONDS then return b.c, b.x end
    local o, e = {}, {}
    actor:GetActorBounds(true, o, e, false)
    local c, x = (o.X and o) or o.Origin, (e.X and e) or e.BoxExtent
    boundsCache[key] = { at = now(), c = { X = c.X, Y = c.Y, Z = c.Z }, x = { X = x.X, Y = x.Y, Z = x.Z } }
    return c, x
end

-- The boat whose bounds hold the location, and not under its deck: the bounds reach
-- 7 m below the root, and trash floating under the hull counted as on board and was
-- welded into it (2026-11-19). On the barge, crates on deck rest at -330.
local DECK_MIN_Z = -420
local function boatAt(l)
    for _, b in pairs(require("boat").list()) do
        local c, x = bounds(b)
        if math.abs(l.X - c.X) <= x.X and math.abs(l.Y - c.Y) <= x.Y and l.Z >= c.Z - x.Z and l.Z <= c.Z + x.Z + 200
            and StaticFindObject(KML):InverseTransformLocation(b:GetTransform(), l).Z >= DECK_MIN_Z then
            return b
        end
    end
end

-- Physics on a boat runs in the game that moves the boat (whoever drives or
-- moored last, boat.lua); the other game places its boat every frame and
-- crates there bounce metres. Off a boat the host keeps it, as before.
-- (Was always the host until 2026-11-16; the boat can now be the guest's.)
local function ownsBoatPhysics(b)
    local boat = require("boat")
    local ok, mine = pcall(function() return not boat.peerControls(boat.keyOf(b)) end)
    if ok then return mine end
    return M.isHost
end

M.ownsBoat = ownsBoatPhysics

function M.ownsPhysicsAt(l)
    local b = boatAt(l)
    if b then return ownsBoatPhysics(b) end
    return M.isHost
end

local function ownsPhysicsForKey(key)
    local b = key and require("boat").find(key)
    if b then return ownsBoatPhysics(b) end
    return M.isHost
end

-- The game welds crates to the boat's VehicleMesh.
local function hullOf(b)
    local comps = b:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    for _, el in ipairs(comps or {}) do
        local cc = el
        pcall(function() cc = el:get() end)
        local okN, n = pcall(function() return cc:GetFName():ToString() end)
        if okN and n == "VehicleMesh" then return cc end
    end
end

-- Where a crate is, for the log: in the boat's frame when it is on one.
local function where(comp)
    if not (comp and comp:IsValid()) then return "borta" end
    local l = comp:K2_GetComponentLocation()
    local b = boatAt(l)
    if not b then return string.format("världen %.0f %.0f %.0f, ingen båt", l.X, l.Y, l.Z) end
    local r = StaticFindObject(KML):InverseTransformLocation(b:GetTransform(), l)
    return string.format("på båten %.0f %.0f %.0f", r.X, r.Y, r.Z)
end
M.where = where

-- Collision and physics state, for the log: the host's copy of a crate the
-- guest let go of fell through the boat and the sea floor.
local function physState(comp)
    local parts = {}
    local function add(label, fn)
        local ok, v = pcall(fn)
        parts[#parts + 1] = label .. " " .. (ok and tostring(v) or "?")
    end
    add("aktörskollision", function() return comp:GetOwner():GetActorEnableCollision() end)
    add("kollision", function() return comp:GetCollisionEnabled() end)
    add("profil", function() return comp:GetCollisionProfileName():ToString() end)
    add("typ", function() return comp:GetCollisionObjectType() end)
    add("fysik", function() return comp:IsSimulatingPhysics(FName("None")) end)
    add("skala", function() local sc = comp:K2_GetComponentScale() return string.format("%.2f/%.2f/%.2f", sc.X, sc.Y, sc.Z) end)
    add("förälder", function() local pa = comp:GetAttachParent() return pa and pa:IsValid() and pa:GetFName():ToString() or "-" end)
    add("massa", function() return string.format("%.1f", comp:GetMass()) end)
    add("aktörsfysik", function() local o = comp:GetOwner() return tostring(o.bSimulatePhysics) .. "/" .. tostring(o.bAwake) end)
    -- Responses per channel (0 WorldStatic, 1 WorldDynamic, 2 Pawn,
    -- 3 Visibility, 4 Camera, 5 PhysicsBody, 6 Vehicle, 7 Destructible, then
    -- the game's own): 0 ignore, 1 overlap, 2 block.
    add("svar", function()
        local r = {}
        for ch = 0, 31 do r[#r + 1] = tostring(comp:GetCollisionResponseToChannel(ch)) end
        return table.concat(r)
    end)
    add("objekt", function() return comp:GetFName():ToString() end)
    return table.concat(parts, ", ")
end
M.physState = physState

-- Positions are sent relative to the boat the crate is on: the boats are a
-- little apart in the two games, and moving, world positions put the crate
-- inside the hull.
local function sendProp(id, comp)
    local l = comp:K2_GetComponentLocation()
    local b = boatAt(l)
    if b then
        local kml = StaticFindObject(KML)
        local rel = kml:MakeRelativeTransform(comp:K2_GetComponentToWorld(), b:GetTransform())
        local t, r = rel.Translation, kml:Quat_Rotator(rel.Rotation)
        net.send("prop", id, f1(t.X), f1(t.Y), f1(t.Z), f1(RotP(r)), f1(r.Yaw), f1(r.Roll), require("boat").keyOf(b),
            string.format("%.3f", now()))
    else
        local r = comp:K2_GetComponentRotation()
        net.send("prop", id, f1(l.X), f1(l.Y), f1(l.Z), f1(RotP(r)), f1(r.Yaw), f1(r.Roll), "", string.format("%.3f", now()))
    end
end
M.sendProp = sendProp

-- A welded crate differs from a loose one in its collision object type (the
-- game's welded type 22 instead of PhysicsBody 5) and in ignoring channels 6
-- (Vehicle, the hull) and 22; the game switches back when its own player
-- grabs the crate. Set loose as welded, the host's copy fell through the boat
-- and the sea floor. (The PhysicsActor profile also changed the game's other
-- channels, and the guest's crates could then be grabbed only once.)
-- The game's weld also tags the actor Detachable and WeldChain and its grab
-- removes them; without Detachable the grab refuses a welded crate
-- (GetGrabbableComponent gave nil), so a crate the mod welded went up only once.
local WELD_TAGS = { "Detachable", "WeldChain" }

local function setWeldTags(actor, welded)
    local keep, has = {}, {}
    actor.Tags:ForEach(function(_, e)
        local n = e:get():ToString()
        has[n] = true
        local isWeldTag = n == WELD_TAGS[1] or n == WELD_TAGS[2]
        if welded or not isWeldTag then keep[#keep + 1] = n end
    end)
    if welded then
        for _, t in ipairs(WELD_TAGS) do
            if not has[t] then actor.Tags[#actor.Tags + 1] = FName(t) end
        end
    elseif #keep < #actor.Tags then
        actor.Tags:Empty()
        for i, n in ipairs(keep) do actor.Tags[i] = FName(n) end
    end
end

local function setWelded(comp, welded)
    pcall(function() comp:SetCollisionObjectType(welded and WELDED_TYPE or LOOSE_TYPE) end)
    for _, ch in ipairs(WELD_IGNORE) do
        pcall(function() comp:SetCollisionResponseToChannel(ch, welded and 0 or 2) end)
    end
    local ok, err = pcall(setWeldTags, comp:GetOwner(), welded)
    if not ok then log("svetstaggar: %s", tostring(err)) end
end
M.setWelded = setWelded

loosen = function(comp)
    setWelded(comp, false)
    pcall(function() comp:SetCollisionEnabled(3) end)
end

-- Welded with the game's own function. Its second
-- argument is welded into the first: (crate, hull) welded the boat into the
-- crate and the guest fell through the whole boat.
local fastenWithoutWeld

local function weldInto(comp, parent)
    pcall(function() comp:GetOwner():SetActorEnableCollision(true) end)
    -- On a boat whose physics runs in the other game the hull is placed every
    -- frame; each piece welded in shifted its body and the whole boat shook
    -- until the piece was picked up (2026-11-18). Fastened without welding.
    local okO, foreign = pcall(function() return not ownsBoatPhysics(parent:GetOwner()) end)
    if okO and foreign then
        fastenWithoutWeld(comp, parent)
        local pa = comp:GetAttachParent()
        return pa ~= nil and pa:IsValid() and pa:GetAddress() == parent:GetAddress(), false
    end
    pcall(function() comp:SetCollisionEnabled(3) end)
    pcall(function() comp:SetSimulatePhysics(true) end)
    local ok, res = pcall(function() return StaticFindObject(MISC):WeldPrimitive(parent, comp) end)
    local welded = StaticFindObject(MISC):IsPrimitiveWelded(comp)
    if not welded then
        log("WeldPrimitive gav %s, fäster med Unreals svetsning", ok and tostring(res) or tostring(res))
        pcall(function() comp:K2_AttachToComponent(parent, FName("None"), 1, 1, 1, true) end)
        welded = StaticFindObject(MISC):IsPrimitiveWelded(comp)
    end
    -- WeldPrimitive leaves the collision as it was.
    setWelded(comp, true)
    local pa = comp:GetAttachParent()
    local hp = parent:GetAttachParent()
    log("svetsning: lådans förälder %s, skrovets förälder %s", pa and pa:IsValid() and pa:GetFName():ToString() or "-",
        hp and hp:IsValid() and hp:GetFName():ToString() or "-")
    return pa ~= nil and pa:IsValid() and pa:GetAddress() == parent:GetAddress(), welded
end

function M.weldOnBoat(comp, l)
    local b = boatAt(l)
    local hull = b and hullOf(b)
    if not hull then return end
    local attached, welded = weldInto(comp, hull)
    log("fryst släpp svetsat direkt på båten (fäst %s, svetsad %s)", tostring(attached), tostring(welded))
end

-- Follows the boat without becoming part of the hull's body and without
-- physics: loose on the guest's boat, which the mod places every frame, a
-- piece shook until picked up (2026-11-18).
fastenWithoutWeld = function(comp, hull)
    pcall(function() comp:SetSimulatePhysics(false) end)
    pcall(function() comp:K2_AttachToComponent(hull, FName("None"), 1, 1, 1, false) end)
    setWelded(comp, true)
    -- Query only: seen, aimed at and picked up, but it cannot push. With full
    -- collision, grinder output fastened at the outlet kept shoving the hull once
    -- this game moved the boat (2026-11-19).
    pcall(function() comp:SetCollisionEnabled(1) end)
end

-- Host: the other player's crate after they let go falls with physics on
-- the host's steady boat, its position streamed back to them, and once it
-- rests in the boat's frame it is welded there like the game does on release.
local watching = {}  -- id -> { comp, untilT, still, last }

-- Anything within SUPPORT_DEPTH under the piece (the piece itself ignored). A trace
-- that fails counts as supported, so the old behaviour stays.
local SUPPORT_DEPTH = 120
local function supported(comp)
    local ok, hit = pcall(function()
        local l = comp:K2_GetComponentLocation()
        local col = { R = 0, G = 0, B = 0, A = 0 }
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LineTraceSingle(comp:GetOwner(), l,
            { X = l.X, Y = l.Y, Z = l.Z - SUPPORT_DEPTH }, 0, false, {}, 0, {}, true, col, col, 0)
    end)
    return not ok or hit == true
end

local function watchTick(id, w)
    local comp = w.comp
    if not comp:IsValid() then watching[id] = nil return end
    if StaticFindObject(MISC):IsPrimitiveWelded(comp) then
        watching[id] = nil
        sendWeld(comp, id)
        log("låda %s svetsad av spelet under bevakning", id)
        return
    end
    sendProp(id, comp)
    if not w.logAt or now() - w.logAt >= 1 then
        w.logAt = now()
        log("låda %s bevakas: %s, %s", id, where(comp), physState(comp))
    end
    local l = comp:K2_GetComponentLocation()
    local b = boatAt(l)
    local p = b and StaticFindObject(KML):InverseTransformLocation(b:GetTransform(), l) or l
    local moved = 1e9
    if w.last then
        local dx, dy, dz = p.X - w.last.X, p.Y - w.last.Y, p.Z - w.last.Z
        moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    w.last = { X = p.X, Y = p.Y, Z = p.Z }
    if moved < REST_MOVE then w.still = w.still + 1 else w.still = 0 end
    -- A crate that landed askew on others may keep trembling; at the end of
    -- the watch it is welded where it is.
    if w.still < REST_TICKS and now() <= w.untilT then return end
    -- Still with nothing under it is not at rest: thrown things were welded 8 m above
    -- the deck (2026-11-19). It gets woken and watched on; at the end it is left loose.
    local floating = not supported(comp)
    if floating and now() <= w.untilT then
        w.still = 0
        if not w.floatLogged then
            w.floatLogged = true
            log("låda %s står still i luften, väcks och bevakas vidare: %s, %s", id, where(comp), physState(comp))
        end
        pcall(function() comp:SetSimulatePhysics(true) end)
        pcall(function() comp:WakeAllRigidBodies() end)
        return
    end
    watching[id] = nil
    if floating then
        log("låda %s ligger fortfarande i luften efter bevakningen, svetsas inte: %s", id, where(comp))
        sendProp(id, comp)
        net.send("rest", id)
        return
    end
    log("låda %s slutar bevakas efter %s: %s", id, w.still >= REST_TICKS and "stilla" or "tiden", where(comp))
    local hull = b and hullOf(b)
    -- Attached with welding, like the game's own welded crates. WeldPrimitive
    -- welded its second argument into the first: the boat into the crate.
    if hull and weldInto(comp, hull) then
        sendWeld(comp, id)
        log("den andras låda %s ligger still och är svetsad", id)
    else
        sendProp(id, comp)
        net.send("rest", id)
        log("den andras låda %s ligger still %s", id, hull and "men svetsades inte" or "utanför båten")
    end
end

-- drops.lua: whether a place is on a boat, and (host) streaming a copy of the
-- guest's frozen drop until it rests and is welded.
function M.onBoat(l) return boatAt(l) ~= nil end
M.boatAt = boatAt
function M.watch(id, comp)
    watching[id] = { comp = comp, untilT = now() + WATCH_SECONDS, still = 0 }
end

-- The other player stopped carrying. On the host, a crate the guest let go
-- of is set down; otherwise physics comes back on.
function M.takeOver(id)
    local rem = remote[id]
    if not rem then return end
    remote[id] = nil
    -- The game merges piles of the same material; the merged-away one stays
    -- valid without an owner at the origin and was welded into the hull.
    local okR, alive = pcall(function()
        local o = rem.comp:GetOwner()
        return rem.comp:IsValid() and o ~= nil and o:IsValid() and not rem.comp:IsBeingDestroyed()
    end)
    if not (okR and alive) then log("låda %s finns inte längre här, tas inte över", id) return end
    -- Shown RENDER_DELAY late; physics takes over from the newest pose.
    if rem.to then pcall(function() rem.buf, rem.from = nil, nil place(rem, now()) end) end
    if ownsPhysicsForKey(rem.boatKey) then
        loosen(rem.comp)
        pcall(function() rem.comp:GetOwner():SetActorEnableCollision(true) end)
        pcall(function() rem.comp:SetSimulatePhysics(true) end)
        pcall(function() rem.comp:WakeAllRigidBodies() end)
        if rem.throw then pcall(function() rem.comp:SetPhysicsLinearVelocity(rem.throw, false, FName("None")) end) end
        watching[id] = { comp = rem.comp, untilT = now() + WATCH_SECONDS, still = 0 }
        log("tar över den andras låda %s: %s (senast %s), %s", id, where(rem.comp), rem.boatKey and "relativt båten" or "i världen", physState(rem.comp))
        return
    end
    -- On the guest's boat, which the mod places every frame, physics never
    -- settles (measured: crates kept bouncing and sliding metres while the
    -- host's came to rest in a second). The crate stays where the host's
    -- copy ended, fixed to the hull; on land it gets physics back.
    local b = rem.boatKey and require("boat").find(rem.boatKey)
    local hull = b and hullOf(b)
    pcall(function() rem.comp:GetOwner():SetActorEnableCollision(true) end)
    if hull then
        local attached, welded = weldInto(rem.comp, hull)
        log("låda %s: svetsad där värden lämnade den (fäst %s, svetsad %s), %s", id, tostring(attached), tostring(welded), physState(rem.comp))
        return
    end
    loosen(rem.comp)
    pcall(function()
        local l = rem.comp:K2_GetComponentLocation()
        rem.comp:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + LIFT_ON_RELEASE }, false, {}, true)
    end)
    pcall(function() rem.comp:SetSimulatePhysics(true) end)
end

-- The owner's copy came to rest (rest message after its last pose): this copy
-- is put exactly there and stays without physics, welded when on a boat. With
-- physics back on it fell again on its own and ended elsewhere, and on the
-- boat the mod moves every frame it bounced (2026-11-16).
function M.settle(id)
    local rem = remote[id]
    if not rem then return end
    remote[id] = nil
    pcall(function() rem.buf, rem.from = nil, nil place(rem, now()) end)
    pcall(function() rem.comp:GetOwner():SetActorEnableCollision(true) end)
    local b = rem.boatKey and require("boat").find(rem.boatKey)
    local hull = b and hullOf(b)
    -- At a machine's outlet a piece welded into the hull pushed against the
    -- machine: the guest's boat bounced, threw the guest off and tore the
    -- recycler loose (2026-11-18). Fastened without physics and without
    -- collision against the hull, it follows the boat but cannot push it.
    local atMachine = false
    pcall(function() atMachine = require("machines").nearMachine(rem.comp:K2_GetComponentLocation(), 400) ~= nil end)
    if hull and atMachine then
        fastenWithoutWeld(rem.comp, hull)
        log("föremål %s vilar hos ägaren vid en maskin, fäst utan svetsning: %s", id, physState(rem.comp))
        return
    end
    if hull then
        local attached, welded = weldInto(rem.comp, hull)
        log("föremål %s vilar hos ägaren, svetsat här (fäst %s, svetsad %s)", id, tostring(attached), tostring(welded))
        return
    end
    -- On land the copy keeps physics: frozen, the game's grab could not lift it
    -- (2026-11-17). Only the guest's boat is too unsteady for physics.
    pcall(function() rem.comp:SetCollisionEnabled(3) end)
    pcall(function() rem.comp:SetSimulatePhysics(true) end)
    log("föremål %s vilar hos ägaren, ligger här med fysik: %s", id, where(rem.comp))
end

local lastReweld = {}   -- id -> time
local REWELD_GAP = 5

local function reweld(d, grabbedNow)
    local actor, parent = StaticFindObject(d.child), StaticFindObject(d.parent)
    if not (actor and actor:IsValid() and parent and parent:IsValid()) then return end
    -- A module the game detaches is being dismantled or moved; welded back,
    -- the recycler being dismantled shook the guest's boat (2026-11-16).
    local mod = actor:GetComponentByClass(StaticFindObject("/Script/Voyage.VoyageModuleComponent"))
    if mod and mod:IsValid() then return end
    local root = actor.RootComponent
    if not (root and root:IsValid()) then return end
    if grabbedNow and grabbedNow:GetOwner():GetAddress() == actor:GetAddress() then return end
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local id = pc and pc:IsValid() and idOf(pc)
    if not id or remote[wire(id)] then return end
    local pa = root:GetAttachParent()
    if pa and pa:IsValid() then return end
    -- Welded into the hull right where the guest stood picking it up, a
    -- material threw the guest hundreds of metres (2026-11-15). Things next
    -- to the own player are left loose.
    local near = false
    pcall(function()
        local p, l = localPC().Pawn:K2_GetActorLocation(), actor:K2_GetActorLocation()
        near = (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < 250 ^ 2
    end)
    if near then
        fastenWithoutWeld(root, parent)
        log("låda %s stöttes loss intill mig, fäst utan svetsning", id)
        return
    end
    -- Knocked loose again right after a weld: something overlaps it, and each
    -- weld shoved the boat (five in a second, 2026-11-16).
    if lastReweld[id] and now() - lastReweld[id] < REWELD_GAP then
        fastenWithoutWeld(root, parent)
        log("låda %s stöttes loss igen inom %d s, fäst utan svetsning", id, REWELD_GAP)
        return
    end
    lastReweld[id] = now()
    pcall(function() root:SetSimulatePhysics(false) end)
    local attached, welded = weldInto(root, parent)
    log("låda %s stöttes loss, svetsad tillbaka (fäst %s, svetsad %s)", id, tostring(attached), tostring(welded))
end

function M.tick()
    local comp, id = grabbed()
    if comp then
        if not held or held:GetAddress() ~= comp:GetAddress() then
            held, heldId, weldSent = comp, id, false
            -- A crate the mod welded keeps the welded collision when grabbed
            -- (the game's grab restores what it saw at its own weld) and
            -- would pass through the hull in the hand.
            local okT, t = pcall(function() return comp:GetCollisionObjectType() end)
            if okT and t == WELDED_TYPE then setWelded(comp, false) end
            -- A piece fastened query-only (fastenWithoutWeld) gets full collision in the hand.
            pcall(function() comp:SetCollisionEnabled(3) end)
            log("håller %s (id %s), %s", comp:GetOwner():GetFullName(), tostring(id), physState(comp))
        end
    elseif held and not (function()
        local ok, mine = pcall(function() return M.ownsPhysicsAt(held:K2_GetComponentLocation()) end)
        return ok and mine
    end)() then
        if heldId and held:IsValid() then
            local root = held:GetOwner().RootComponent
            -- A throw: the speed goes along so the host's copy flies the same.
            local okV, v = pcall(function() return held:GetPhysicsLinearVelocity(FName("None")) end)
            v = okV and v or { X = 0, Y = 0, Z = 0 }
            pcall(function() root:SetSimulatePhysics(false) end)
            pcall(function() held:GetOwner():SetActorEnableCollision(false) end)
            remote[wire(heldId)] = { comp = root, lastUpdate = now() + FREEZE_GRACE }
            net.send("letgo", wire(heldId), f1(v.X), f1(v.Y), f1(v.Z))
            log("släpper id %s: %s", tostring(heldId), where(root))
        end
        log("släppt id %s, den andra tar över fysiken", tostring(heldId))
        held, heldId = nil, nil
    elseif held then
        -- The host's own crate is streamed until it rests or the game welds
        -- it, so the guest's copy ends exactly where it lies here.
        if heldId and held:IsValid() and not weldSent then
            watching[wire(heldId)] = { comp = held, untilT = now() + WATCH_SECONDS, still = 0, own = true }
        end
        log("släppt id %s, svetsad %s", tostring(heldId), tostring(weldSent))
        held, heldId = nil, nil
    end
    if held and not comp and heldId and not weldSent and held:IsValid() then
        local okW, welded = pcall(function() return StaticFindObject(MISC):IsPrimitiveWelded(held) end)
        if okW and welded then
            weldSent = true
            local okS, errS = pcall(sendWeld, held, heldId)
            if not okS then log("svets-fel: %s", tostring(errS)) end
        end
    end
    -- Sent from the frame hook (M.frame); here only when that has stopped.
    if held and heldId and held:IsValid() and now() - lastHeldSent > 0.1 then
        lastHeldSent = now()
        sendProp(wire(heldId), held)
    end

    if #detached > 0 then
        local list = detached
        detached = {}
        for _, d in ipairs(list) do
            local okR, errR = pcall(reweld, d, comp)
            if not okR then log("återsvetsning: %s", tostring(errR)) end
        end
    end

    for id, rem in pairs(remote) do
        if now() - rem.lastUpdate > REMOTE_TIMEOUT then
            M.takeOver(id)
        end
    end
    for id, w in pairs(watching) do
        local okW, err = pcall(watchTick, id, w)
        if not okW then watching[id] = nil log("bevakning %s: %s", id, tostring(err)) end
    end
end

-- Test bench helper: the item shown by some loaded dynamic mesh actor.
function M.sampleItem()
    for _, pc in ipairs(persistComps) do
        local ok, item = pcall(function()
            local owner = pc:GetOwner()
            local it = owner.CurrentVisualizeItem
            if it and it:IsValid() then return it end
        end)
        if ok and item then return item end
    end
end

-- A pose that arrives after the item went at its owner found another item
-- with the same new save id here (both games hand out the same ones) and
-- moved that (2026-11-16).
local goneAt = {}

local function handleGone(id)
    goneAt[id] = now()
    local pc = findById(id)
    local owner = pc and pc:GetOwner()
    if not (owner and owner:IsValid()) then
        if M.missingGoneHook then pcall(M.missingGoneHook, id) end
        log("borta-meddelande för %s, finns inte här", id)
        return
    end
    local okH, heldNow = pcall(function()
        local grab = localPC().Pawn:GetComponentByClass(StaticFindObject(GRAB_CLASS))
        local comp = grab.GrabbedComponent:Get()
        return comp and comp:IsValid() and comp:GetOwner():GetAddress() == owner:GetAddress()
    end)
    if okH and heldNow then
        log("borta-meddelande för %s ignoreras, jag håller den", id)
        return
    end
    if M.goneHook and M.goneHook(owner, id) then return end
    -- The bench world lost its boat on 2026-11-15 without a known cause.
    if owner:GetClass():GetFName():ToString():find("Boat", 1, true) then
        log("borta-meddelande för båten %s (id %s) ignoreras", owner:GetFullName(), id)
        return
    end
    removedByPeer[idOf(pc) or id] = true
    remote[id] = nil
    log("tar bort %s (id %s)", owner:GetFullName(), id)
    owner:K2_DestroyActor()
end

local function componentNamed(actor, name)
    local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    for _, e in ipairs(comps or {}) do
        local c = e
        pcall(function() c = e:get() end)
        local ok, n = pcall(function() return c:GetFName():ToString() end)
        if ok and n == name then return c end
    end
end

local function handleWeld(msg)
    local id, pid, compName = msg[3], msg[4], msg[5]
    local pc = findById(id)
    local owner = pc and pc:GetOwner()
    local root = owner and owner:IsValid() and owner.RootComponent
    local ppc = findById(pid)
    local powner = ppc and ppc:GetOwner()
    local parent = powner and powner:IsValid() and componentNamed(powner, compName)
    if not (root and root:IsValid() and parent) then
        if not root then noteEarly(id, "weld", msg) end
        log("svetsning %s på %s/%s: hittar inte %s", id, pid, compName, root and "föräldern" or "föremålet")
        return
    end
    remote[id] = nil
    local kml = StaticFindObject(KML)
    local loc = { X = tonumber(msg[6]), Y = tonumber(msg[7]), Z = tonumber(msg[8]) }
    local rot = Rot(tonumber(msg[9]), tonumber(msg[10]), tonumber(msg[11]))
    -- Never WeldPrimitive(crate, hull): it welded the boat into the crate and
    -- the guest fell through the whole boat.
    pcall(function() root:SetSimulatePhysics(false) end)
    root:K2_SetWorldLocationAndRotation(kml:TransformLocation(parent:K2_GetComponentToWorld(), loc),
        kml:ComposeRotators(rot, parent:K2_GetComponentRotation()), false, {}, true)
    local attached, welded = weldInto(root, parent)
    log("svetsar %s på %s/%s: fäst %s, svetsad %s, %s", id, powner:GetFullName(), compName, tostring(attached), tostring(welded), physState(root))
end

local function lerp(a, b, k) return a + (b - a) * k end
local function lerpAngle(a, b, k) return a + ((b - a + 180) % 360 - 180) * k end

-- The pose to show at time t, in the boat's frame when it is on one.
current = function(rem, t)
    local to, from = rem.to, rem.from
    if not from then return to end
    local k = math.max(math.min((t - rem.lastUpdate) / rem.span, 1), 0)
    return {
        loc = { X = lerp(from.loc.X, to.loc.X, k), Y = lerp(from.loc.Y, to.loc.Y, k), Z = lerp(from.loc.Z, to.loc.Z, k) },
        rot = Rot(lerpAngle(RotP(from.rot), RotP(to.rot), k), lerpAngle(from.rot.Yaw, to.rot.Yaw, k), lerpAngle(from.rot.Roll, to.rot.Roll, k)),
    }
end

-- Poses stamped with the sender's clock are played back RENDER_DELAY late,
-- between the two around that time (like the puppet and the boat), so the
-- arrival jitter of the file queue and the network never shows. Messages
-- without a stamp (tests, drops.lua) use the eased pose above.
local RENDER_DELAY, MAX_EXTRAPOLATE = 0.12, 0.2
local stampOffset

local function stamped(rem, t)
    local buf = rem.buf
    local n = buf and #buf or 0
    if n == 0 or not stampOffset then return nil end
    local renderT = t - stampOffset - RENDER_DELAY
    for i = n - 1, 1, -1 do
        local a, b = buf[i], buf[i + 1]
        if a.st <= renderT and renderT <= b.st then
            local k = (renderT - a.st) / math.max(b.st - a.st, 0.001)
            return {
                loc = { X = lerp(a.loc.X, b.loc.X, k), Y = lerp(a.loc.Y, b.loc.Y, k), Z = lerp(a.loc.Z, b.loc.Z, k) },
                rot = Rot(lerpAngle(RotP(a.rot), RotP(b.rot), k), lerpAngle(a.rot.Yaw, b.rot.Yaw, k), lerpAngle(a.rot.Roll, b.rot.Roll, k)),
            }
        end
    end
    local last = buf[n]
    if n >= 2 and renderT > last.st then
        local prev = buf[n - 1]
        local k = 1 + math.min(renderT - last.st, MAX_EXTRAPOLATE) / math.max(last.st - prev.st, 0.001)
        return { loc = { X = lerp(prev.loc.X, last.loc.X, k), Y = lerp(prev.loc.Y, last.loc.Y, k), Z = lerp(prev.loc.Z, last.loc.Z, k) },
            rot = last.rot }
    end
    return renderT < buf[1].st and buf[1] or last
end

place = function(rem, t)
    local p = stamped(rem, t) or current(rem, t)
    local boat = require("boat")
    local b = rem.boatKey and boat.find(rem.boatKey)
    local loc, rot = p.loc, p.rot
    if b then
        local kml = StaticFindObject(KML)
        -- Location and rotation only: a whole transform built from Lua may
        -- carry a broken scale, and a crate scaled to nothing fell through.
        loc, rot = kml:TransformLocation(b:GetTransform(), p.loc), kml:ComposeRotators(p.rot, b:K2_GetActorRotation())
    end
    -- The comp is the crate's root, so moving the actor moves it (without the
    -- hit result out parameter that leaks in UE4SS, see boat.moveActor).
    rem.owner = rem.owner or rem.comp:GetOwner()
    boat.moveActor(rem.owner, loc, rot)
end

-- Every frame (from boat.lua, after the boat has been placed), so a crate
-- moves with the boat between updates instead of being left behind.
function M.frame()
    local t = now()
    if held and heldId and t - lastHeldSent >= HELD_INTERVAL then
        lastHeldSent = t
        pcall(function() if held:IsValid() then sendProp(wire(heldId), held) end end)
    end
    for id, rem in pairs(remote) do
        if rem.to and t >= (rem.lastUpdate or 0) then
            local ok = pcall(function()
                if rem.comp:IsValid() then place(rem, t) else remote[id] = nil end
            end)
            if not ok then remote[id] = nil end
        end
    end
end

-- drops.lua: the copy of the peer's drop is linked; what came before it is applied.
function M.claimed(id)
    local e = early[id]
    early[id], missing[id] = nil, nil
    if not e or now() - e.t > EARLY_SECONDS then return end
    log("föremål %s: tillämpar det som kom före kopian (%s%s%s)", id, e.pose and "läge " or "",
        e.rest and "vila " or "", e.weld and "svetsning" or "")
    if e.pose then M.handle(e.pose) end
    if e.weld then handleWeld(e.weld) elseif e.rest then M.settle(id) end
end

function M.handle(msg)
    if msg[1] == "gone" then handleGone(msg[3]) return true end
    if msg[1] == "weld" then handleWeld(msg) return true end
    if msg[1] == "rest" then
        if not remote[msg[3]] and not findById(msg[3]) then noteEarly(msg[3], "rest", true) end
        M.settle(msg[3])
        return true
    end
    if msg[1] == "letgo" then
        local rem = remote[msg[3]]
        if rem then rem.throw = { X = tonumber(msg[4]) or 0, Y = tonumber(msg[5]) or 0, Z = tonumber(msg[6]) or 0 } end
        M.takeOver(msg[3])
        return true
    end
    if msg[1] ~= "prop" then return false end
    local id = msg[3]
    local rem = remote[id]
    if not rem and goneAt[id] and now() - goneAt[id] < 10 then return true end
    if not rem then
        local pc = findById(id)
        local owner = pc and pc:GetOwner()
        local root = owner and owner:IsValid() and owner.RootComponent
        if not (root and root:IsValid()) then
            noteEarly(id, "pose", msg)
            if not missing[id] then missing[id] = true log("föremål %s saknas här", id) end
            return true
        end
        -- A welded crate is attached to what it sat on; lifting it unwelds.
        pcall(function()
            local pa = root:GetAttachParent()
            if pa and pa:IsValid() then root:K2_DetachFromComponent(1, 1, 1, false) end
        end)
        pcall(function() root:SetSimulatePhysics(false) end)
        -- Moved by teleport through the boat it shoved the boat; no collision
        -- while the other player carries it.
        pcall(function() owner:SetActorEnableCollision(false) end)
        rem = { comp = root }
        remote[id] = rem
        log("tar emot föremål %s: %s", id, owner:GetFullName())
    end
    local t = now()
    local loc = { X = tonumber(msg[4]), Y = tonumber(msg[5]), Z = tonumber(msg[6]) }
    local rot = Rot(tonumber(msg[7]), tonumber(msg[8]), tonumber(msg[9]))
    local key = msg[10] ~= "" and msg[10] or nil
    local st = tonumber(msg[11])
    if st then
        local off = t - st
        -- The smallest offset has the least delay; a much larger one means
        -- the other game restarted.
        if not stampOffset or off < stampOffset or off - stampOffset > 1 then stampOffset = off end
        if not rem.buf or rem.boatKey ~= key then rem.buf = {} end
        rem.buf[#rem.buf + 1] = { st = st, loc = loc, rot = rot }
        if #rem.buf > 20 then table.remove(rem.buf, 1) end
    else
        rem.buf = nil
    end
    -- Eased from where it is shown now towards the new pose over the time
    -- between the last two updates.
    rem.from = rem.to and rem.boatKey == key and current(rem, t) or nil
    rem.span = math.min(math.max(t - (rem.lastUpdate or t), 0.02), 0.2)
    rem.to, rem.boatKey, rem.lastUpdate = { loc = loc, rot = rot }, key, t
    place(rem, t)
    return true
end

return M
