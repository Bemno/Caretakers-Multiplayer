-- Items dropped from the inventory: the game spawns a new dynamic mesh actor
-- with a new save id. The dropper sees it begin play next to its pawn and sends
-- item type, transform and id; the other game spawns the same item with
-- VoyageInventoryUtils.SpawnActorsForItems and maps the sender's id to the id
-- of its own copy (props.alias), so carrying and picking it up stay in sync.
local M = {}

local DYN_CLASS = "/Script/Voyage.VoyageDynamicMeshActor"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local UTILS = "/Script/Voyage.Default__VoyageInventoryUtils"
local DROP_LIFT = 20   -- cm above the sender's spot on the boat, clear of the deck
local ARM_AFTER = 0         -- main.lua already waits until the world has settled
local DROP_RADIUS = 500
local MATCH_RADIUS = 400
local FOLLOW_SECONDS = 15
local REST_MOVE, REST_TICKS = 2, 10
local PENDING_TIMEOUT = 5
local MACHINE_RADIUS = 400

local net, log, localPC, now, props
local worldSince
local queue = {}            -- actors that began play, checked on the next tick
local pendingPeer = {}      -- spawns requested by the peer, waiting for their actor
local following = {}        -- own drops whose landing is streamed: { comp, id, untilT }

local armed = false

-- A crafted item appears next to the player and flies into the inventory
-- about a second later. Taken for a drop, it hovered frozen on the guest and
-- popped up and vanished in the other game (2026-11-15). Actors that begin
-- play while the player's own fabricator works are left alone; one still
-- there after CRAFT_WAIT (inventory full) counts as a drop.
local CRAFT_WAIT = 3
local lastCrafting = -100
local function noteCrafting()
    local ok, busy = pcall(function()
        local fab = localPC().Pawn.VoyageFabricator
        return fab:IsFabricating() or fab:GetQueueLength() > 0
    end)
    if ok and busy then lastCrafting = now() end
end

local dynClass
local function isDynamic(actor)
    dynClass = (dynClass and dynClass:IsValid()) and dynClass or StaticFindObject(DYN_CLASS)
    return dynClass and dynClass:IsValid() and actor:IsA(dynClass)
end

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

-- Kept minimal: it runs for every actor that begins play. Only the path is
-- queued: a UObject kept from a hook until a later tick crashed UE4SS when Lua
-- collected it.
local function onBeginPlay(ctx)
    if not armed then return end
    local actor = ctx:get()
    -- Test bench spies get every actor: a second BeginPlay hook never fired.
    if M.spy then M.spy(pathOf(actor)) end
    if not isDynamic(actor) then return end
    local entry = { path = pathOf(actor) }
    if now() - lastCrafting < 1.5 then
        entry.crafted = now()
        queue[#queue + 1] = entry
        return
    end
    -- A drop on a boat this game only follows (moved by the mod every frame)
    -- was flung metres away within one tick and lost. It is frozen where it
    -- appeared; the copy in the game that moves the boat falls on its steady
    -- boat and this one follows it (props.watch there, weld at the end).
    do
        pcall(function()
            local pawn = localPC().Pawn
            local l = actor:K2_GetActorLocation()
            local p = pawn and pawn:IsValid() and pawn:K2_GetActorLocation()
            local near = p and math.sqrt((l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2) <= DROP_RADIUS
            -- A machine's output appears wherever the player is; on the
            -- following boat it bounced around (2026-11-16).
            if not near and M.machines then near = M.machines.nearMachine(l, MACHINE_RADIUS) ~= nil end
            if near and props.onBoat(l) and not props.ownsPhysicsAt(l) then
                actor.RootComponent:SetSimulatePhysics(false)
                local r = actor:K2_GetActorRotation()
                entry.frozen = { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = Rot(RotP(r) or 0, r.Yaw or 0, r.Roll or 0) }
            end
        end)
    end
    queue[#queue + 1] = entry
end

local function itemOf(actor)
    local ok, item = pcall(function() return actor.CurrentVisualizeItem end)
    if ok and item and item:IsValid() then return item end
    local utils = StaticFindObject(UTILS)
    ok, item = pcall(function() return utils:FindItemForActor(actor) end)
    if ok and item and item:IsValid() then return item end
end

local function saveId(actor)
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if not (pc and pc:IsValid()) then return nil end
    local id = pc.PersistentUniqueId
    if not id or id == 0 then return nil end
    return tostring(id), pc
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function f1(v) return string.format("%.1f", v or 0) end

local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"

-- A dropped stack (a cable roll is one item with the length as its count)
-- keeps its items in the actor's own inventory.
local function inventoryOf(actor)
    local inv = actor:GetComponentByClass(StaticFindObject(INV_CLASS))
    if inv and inv:IsValid() then return inv end
end

local function countOf(actor, item)
    local ok, n = pcall(function() return inventoryOf(actor):GetNumItems(item) end)
    return (ok and n and n > 0) and n or 1
end

-- Copies without physics waiting for the sender's rest message. One never put
-- down (the message lost, or taken by another item with the same save id)
-- gets its place by the same rules as a rest after WAIT_FOR_REST.
local waiting = {}          -- { path, untilT }
-- The other game's machine output, let fall here one by one (MACHINE_GAP apart).
local machineQueue, lastMachineDrop = {}, -100
local MACHINE_GAP = 0.6

local function releaseMachineOutput()
    if #machineQueue == 0 or now() - lastMachineDrop < MACHINE_GAP then return end
    local m = table.remove(machineQueue, 1)
    local a = StaticFindObject(m.path)
    local root = a and a:IsValid() and a.RootComponent
    if not (root and root:IsValid()) then return end
    lastMachineDrop = now()
    root:SetSimulatePhysics(true)
    root:WakeAllRigidBodies()
    following[#following + 1] = { comp = root, id = m.id, untilT = now() + FOLLOW_SECONDS, still = 0 }
end
local WAIT_FOR_REST = FOLLOW_SECONDS + 10

local function putDownOrphans()
    for i = #waiting, 1, -1 do
        local w = waiting[i]
        if now() > w.untilT then
            table.remove(waiting, i)
            local a = StaticFindObject(w.path)
            local root = a and a:IsValid() and a.RootComponent
            if root and root:IsValid() and not root:IsSimulatingPhysics(FName("None")) then
                local pa = root:GetAttachParent()
                if not (pa and pa:IsValid()) then
                    local l = root:K2_GetComponentLocation()
                    if props.onBoat(l) then props.weldOnBoat(root, l)
                    else root:SetSimulatePhysics(true) end
                    log("släpp från andra: %s fick aldrig vila, läggs ner här", w.path:match("[^.]+$"))
                end
            end
        end
    end
end

-- Returns true when the actor is the copy of a peer drop.
local function claimForPeer(actor, item, loc)
    for i, p in ipairs(pendingPeer) do
        if (not item or p.item == pathOf(item)) and dist(loc, p.loc) < MATCH_RADIUS then
            table.remove(pendingPeer, i)
            local id, pc = saveId(actor)
            actor:K2_SetActorLocationAndRotation(p.loc, p.rot, false, {}, true)
            if id then props.alias(p.peerId, id, pc) end
            props.claimedPaths[pathOf(actor)] = true
            -- This game moves the boat: the other froze its drop; this copy
            -- falls and is streamed back until it rests, then welded there.
            -- Ocean trash the host found is never the boat's: floating under the hull
            -- it was welded into it and threw the boat over (2026-11-19).
            local root = actor.RootComponent
            if p.world then
                pcall(function() root:SetSimulatePhysics(true) end)
            elseif p.machineOut and props.onBoat(p.loc) and props.ownsPhysicsAt(p.loc) then
                -- Falls here like this game's own machine output; streamed until it rests.
                -- One at a time: arriving in a burst, five copies at the outlet at once
                -- got physics together and flew apart (2026-11-19).
                pcall(function() root:SetSimulatePhysics(false) end)
                machineQueue[#machineQueue + 1] = { path = pathOf(actor), id = p.peerId }
            elseif p.frozen and props.onBoat(p.loc) then
                -- The game freezes a drop on a boat and welds it where it lies; spawned
                -- with physics on the boat this game drives, several dropped at one spot
                -- burst apart and rolled the boat (2026-11-19, also 0.2.6). Welded here too.
                props.weldOnBoat(actor.RootComponent, p.loc)
            elseif props.onBoat(p.loc) and props.ownsPhysicsAt(p.loc) then
                pcall(function() root:SetSimulatePhysics(true) end)
                props.watch(p.peerId, root)
            else
                -- The sender streams it and its rest message puts it down (settle):
                -- no physics until then, here or on a boat that only follows.
                pcall(function() root:SetSimulatePhysics(false) end)
                waiting[#waiting + 1] = { path = pathOf(actor), untilT = now() + WAIT_FOR_REST }
            end
            local have = item and countOf(actor, item) or p.count
            if p.count > have then
                local ok, err = pcall(function() inventoryOf(actor):AddItems({ [item] = p.count - have }, true, true, 0) end)
                if not ok then log("släpp från andra: kunde inte fylla på antal: %s", tostring(err)) end
            end
            log("släpp från andra: %s som %s (id %s = deras %s), antal %d av %d%s", p.item, actor:GetFullName(),
                tostring(id), p.peerId, countOf(actor, item), p.count, p.machineOut and ", maskinutmatning" or "")
            pcall(props.claimed, p.peerId)
            return true
        end
    end
    return false
end

local function examine(entry)
    if entry.crafted then
        if now() - entry.crafted < CRAFT_WAIT then return "retry" end
        entry.crafted = nil
        entry.t = now()
    end
    if props.dropQuietUntil and os.time() < props.dropQuietUntil then return end
    local actor = StaticFindObject(entry.path)
    entry.t = entry.t or now()
    if not (actor and actor:IsValid() and isDynamic(actor)) then return end
    local item = itemOf(actor)
    -- An egg sack spawned for the host's never gets CurrentVisualizeItem, so
    -- it was never linked and the guest removed it as its own (2026-11-17).
    -- Without an item it is matched by place alone.
    if not item then
        if now() - entry.t < 1 then return "retry" end
        if not claimForPeer(actor, nil, actor:K2_GetActorLocation()) then
            log("släpp utan föremål: %s", actor:GetFullName())
        end
        return
    end
    if entry.frozen then
        pcall(function()
            actor.RootComponent:SetSimulatePhysics(false)
            actor:K2_SetActorLocationAndRotation(entry.frozen.loc, entry.frozen.rot, false, {}, true)
        end)
    end
    local loc = actor:K2_GetActorLocation()
    if claimForPeer(actor, item, loc) then return end
    for _, p in ipairs(pendingPeer) do
        if dist(loc, p.loc) < MATCH_RADIUS then
            log("okänd aktör vid väntande släpp, skickas inte: %s (%s)", actor:GetFullName(), pathOf(item))
            return
        end
    end
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local d = dist(loc, pawn:K2_GetActorLocation())
    -- Machines: only the game that runs the job hands anything out
    -- (machines.lua), and its output is sent wherever that player is.
    local machine = M.machines and M.machines.nearMachine(loc, MACHINE_RADIUS)
    local mine = machine and M.machines.runsJob(machine)
    if d > DROP_RADIUS and not mine then return end
    local id, ownPc = saveId(actor)
    if not id then
        -- The save id may be assigned a moment after BeginPlay.
        if now() - entry.t < 2 then return "retry" end
        log("släpp utan save-id: %s", actor:GetFullName())
        return
    end
    local r = actor:K2_GetActorRotation()
    -- On a boat also its place on the boat: the receiver's boat lies elsewhere (the
    -- follower shows it 0.12 s late), and spawned at the world spot the piece came
    -- inside the hull and the push threw the boat over (2026-11-19, also 0.2.6).
    local bkey, rel = "", nil
    local b = props.boatAt(loc)
    if b then
        bkey = require("boat").keyOf(b)
        rel = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):InverseTransformLocation(b:GetTransform(), loc)
    end
    -- "m": frozen output of this game's machine. The game that moves the boat lets
    -- its copy fall and streams it back (claimForPeer); welded at the outlet in both
    -- games, grinder output hung in the air there (2026-11-19).
    local kind = entry.frozen and (mine and "m" or "f") or ""
    net.send("drop", id, pathOf(item), f1(loc.X), f1(loc.Y), f1(loc.Z), f1(RotP(r)), f1(r.Yaw), f1(r.Roll), countOf(actor, item),
        kind, bkey, rel and f1(rel.X) or "", rel and f1(rel.Y) or "", rel and f1(rel.Z) or "")
    props.sentDrops[id] = true
    pcall(props.registerOwn, id, ownPc)
    -- A frozen drop is not streamed: the host's copy lands and the guest's follows.
    -- On a boat this game moves, it is watched like a let-go crate: streamed
    -- until it rests, then welded there in both games.
    -- A machine's output is not welded: welded into the hull at the outlet,
    -- still moving, the boat leaned until the piece was gone (2026-11-18).
    if entry.frozen then
        -- The game welds a frozen drop into the hull, which fails on the boat this
        -- game only follows (its physics off): the piece hung in the air as the boat
        -- moved on (2026-11-19). Fastened to the hull by the mod instead.
        if b and not props.ownsPhysicsAt(loc) then props.weldOnBoat(actor.RootComponent, loc) end
    elseif props.onBoat(loc) and props.ownsPhysicsAt(loc) and not machine then
        props.watch(id, actor.RootComponent)
    else
        following[#following + 1] = { comp = actor.RootComponent, id = id, untilT = now() + FOLLOW_SECONDS, still = 0 }
    end
    log("släppte %s (id %s, %.0f cm från mig, antal %d%s)", pathOf(item), id, d, countOf(actor, item), entry.frozen and ", fryst på båten" or "")
end

function M.init(netModule, logFn, localPCFn, nowFn, propsModule)
    net, log, localPC, now, props = netModule, logFn, localPCFn, nowFn, propsModule
end

-- Registered only once the world has settled: during loading BeginPlay runs
-- for thousands of actors, and entering Lua that often has crashed UE4SS.
local hooked = false
local function arm()
    if hooked then return end
    hooked = true
    local ok, err = pcall(RegisterBeginPlayPostHook, function(ctx) pcall(onBeginPlay, ctx) end)
    armed = ok
    log("släppsynk: %s", ok and "ok" or tostring(err))
end

function M.tick()
    worldSince = worldSince or now()
    if now() - worldSince < ARM_AFTER then return end
    arm()
    noteCrafting()
    local q = queue
    queue = {}
    for _, entry in ipairs(q) do
        local ok, res = pcall(examine, entry)
        if not ok then log("släpp-fel: %s", tostring(res))
        elseif res == "retry" then queue[#queue + 1] = entry end
    end
    for i = #following, 1, -1 do
        local f = following[i]
        if not f.comp:IsValid() then
            table.remove(following, i)
        else
            -- Relative to the boat with its key: in world coordinates the
            -- copy got physics back on a following boat and bounced.
            props.sendProp(f.id, f.comp)
            local l = f.comp:K2_GetComponentLocation()
            if f.last and dist(l, f.last) < REST_MOVE then f.still = f.still + 1 else f.still = 0 end
            f.last = { X = l.X, Y = l.Y, Z = l.Z }
            -- Followed until it rests (it was 3 s, and an item still rolling
            -- then ended elsewhere in the other game); the rest message makes
            -- the copy stay exactly there.
            if f.still >= REST_TICKS or now() > f.untilT then
                table.remove(following, i)
                net.send("rest", f.id)
            end
        end
    end
    local okM, errM = pcall(releaseMachineOutput)
    if not okM then log("släpp-fel (maskin): %s", tostring(errM)) end
    local okO, errO = pcall(putDownOrphans)
    if not okO then log("släpp-fel (väntande): %s", tostring(errO)) end
    for i = #pendingPeer, 1, -1 do
        if now() - pendingPeer[i].t > PENDING_TIMEOUT then
            log("släpp från andra kom aldrig fram: %s (deras id %s)", pendingPeer[i].item, pendingPeer[i].peerId)
            table.remove(pendingPeer, i)
        end
    end
end

local function findItem(path)
    local item = StaticFindObject(path)
    if item and item:IsValid() then return item end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and loaded and loaded:IsValid() then return loaded end
end

local function spawnForPeer(msg)
    local peerId, path = msg[3], msg[4]
    local loc = { X = tonumber(msg[5]), Y = tonumber(msg[6]), Z = tonumber(msg[7]) }
    local b = msg[13] and msg[13] ~= "" and require("boat").find(msg[13])
    if b and tonumber(msg[16]) then
        local rel = { X = tonumber(msg[14]), Y = tonumber(msg[15]), Z = tonumber(msg[16]) + ((msg[12] == "f" or msg[12] == "m") and 0 or DROP_LIFT) }
        loc = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):TransformLocation(b:GetTransform(), rel)
    end
    local rot = Rot(tonumber(msg[8]), tonumber(msg[9]), tonumber(msg[10]))
    local item = findItem(path)
    if not item then log("släpp från andra: hittar inte föremålet %s", path) return end
    pendingPeer[#pendingPeer + 1] = { peerId = peerId, item = path, loc = loc, rot = rot, t = now(), count = tonumber(msg[11]) or 1, world = msg[12] == "w", frozen = msg[12] == "f" or msg[12] == "m", machineOut = msg[12] == "m" }
    local transform = {
        Translation = loc,
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local items = {}
    items[item] = 1
    local ok, err = pcall(function()
        -- Without physics until claimForPeer decides: spawned with it inside the
        -- grinder (the drop often arrives seconds late), copies were shot out, bounced
        -- about and hit the hull until the boat rolled over (2026-11-19).
        StaticFindObject(UTILS):SpawnActorsForItems(localPC():GetWorld(), transform, items,
            { bSimulatePhysics = false, bAwake = true }, 0)
    end)
    log("släpp från andra: SpawnActorsForItems(%s) -> %s", path, ok and "ok" or tostring(err))
end

function M.handle(msg)
    if msg[1] ~= "drop" then return false end
    spawnForPeer(msg)
    return true
end

return M
