-- Machines on the boat and in the world (not the player's own fabricator).
--
-- Whoever starts a job runs it (the one who handles owns, arkiv.md pattern 4):
-- the machine in their game hands out the result, the other game mirrors the
-- job for the look and empties its output just before its DropItem (a
-- pre-hook) and in the tick. The owner's output reaches the other as a drop
-- (drops.lua sends drops next to a machine it runs whatever the distance).
-- A machine nobody has used yet belongs to the host.
--
-- Fabricators: whoever queues pays for it in their own game; the queue is
-- mirrored to the other (fabq), whose game takes the materials at queue time,
-- so the mirror puts back exactly what was taken (and lends what was missing
-- for the queue to be accepted). Cancelling is mirrored the same way (fabx).
--
-- Recyclers: the one who puts something in runs it (recin tells the other,
-- whose copy then hands nothing out). Contents are not sent: both games sent
-- the whole input on every start and added what came, so it doubled each
-- round, to billions of scraps and fabric pouring out (2026-11-16). A
-- recycler working with no player near (its intake took something floating
-- by) belongs to the host's world; the guest's copy empties its intake.
local M = {}

local FAB_CLASS = "/Script/Voyage.VoyageFabricatorComponent"
local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"
local PAWN_CLASS = "/Script/Engine.Pawn"
local SCAN_EVERY = 3
local RECYCLER = "/Game/Blueprints/Modules/Utility/BP_Module_MasterRecycler.BP_Module_MasterRecycler_C"
local OUTPUT = "/Game/Blueprints/Fabrication/BP_Physical_Inventory_Output.BP_Physical_Inventory_Output_C"
local NEAR_RECYCLER = 800

local net, log, localPC, now, props, boxes, isHost
local applying = false
local hooked = false
local machinePaths, lastScan = {}, -100
local jobOwner = {}         -- machine actor path -> "me" | "peer"

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function setOwner(actor, who)
    if not (actor and actor:IsValid()) then return end
    local p = pathOf(actor)
    if jobOwner[p] ~= who then
        log("maskiner: %s körs nu hos %s", actor:GetFName():ToString(), who == "me" and "mig" or "den andra")
    end
    jobOwner[p] = who
end

local function runsJobAt(actorPath)
    local o = jobOwner[actorPath]
    if o then return o == "me" end
    return isHost
end

-- Blueprints are build.lua's: as machines the copy's queue was sent back and
-- the placer's queue went 1 -> 2 (petrol generator, 2026-11-20).
local function isMachine(owner)
    return owner and owner:IsValid() and not owner:IsA(StaticFindObject(PAWN_CLASS))
        and not owner:GetClass():GetFName():ToString():find("Location_Fabricator", 1, true)
end

local function fabOf(id)
    local pc = props.findById(id)
    if not (pc and pc:IsValid()) then return nil end
    local owner = pc:GetOwner()
    local fab = owner and owner:IsValid() and owner:GetComponentByClass(StaticFindObject(FAB_CLASS))
    if fab and fab:IsValid() then return fab, owner end
end

-- Every inventory the fabricator may take from or refund to: the player's own
-- and the ones it sees nearby (boxes, vaults).
local function inventoriesFor(fab)
    local list, seen = {}, {}
    local function add(inv)
        if not (inv and inv:IsValid()) then return end
        local a = inv:GetAddress()
        if seen[a] then return end
        seen[a] = true
        list[#list + 1] = inv
    end
    local pawn = localPC().Pawn
    for _, c in ipairs(pawn:K2_GetComponentsByClass(StaticFindObject(INV_CLASS)) or {}) do
        local okG, inv = pcall(function() return c:get() end)
        add((okG and inv) or c)
    end
    for _, field in ipairs({ "CurrentInventories", "CurrentVaults" }) do
        pcall(function()
            fab[field]:ForEach(function(_, e)
                local okG, inv = pcall(function() return e:get() end)
                inv = (okG and inv) or e
                local okW, inner = pcall(function() return inv:Get() end)
                add((okW and inner) or inv)
            end)
        end)
    end
    return list
end

local function snapshot(list)
    local s = {}
    for i, inv in ipairs(list) do s[i] = boxes.counts(inv) end
    return s
end

local function restore(list, before)
    local moved = 0
    for i, inv in ipairs(list) do
        if inv:IsValid() then
            local d, any = boxes.diff(boxes.counts(inv), before[i])
            if any then
                boxes.apply(inv, d)
                for _, n in pairs(d) do moved = moved + math.abs(n) end
            end
        end
    end
    return moved
end

local function entries(m)
    local list = {}
    local function add(k, v)
        local okK, key = pcall(function() return k:get() end)
        key = (okK and key) or k
        local okV, val = pcall(function() return v:get() end)
        val = (okV and val) or v
        if key and tonumber(val) then list[#list + 1] = { item = key, n = tonumber(val) } end
    end
    if type(m) == "table" then
        for k, v in pairs(m) do add(k, v) end
    else
        pcall(function() m:ForEach(add) end)
    end
    return list
end

-- What the queue needs, lent to the player's inventory so the game accepts it.
local function lend(fab, item, count)
    local inv = localPC():GetInventoryComponent(1)
    if not (inv and inv:IsValid()) then return end
    local r = {}
    fab:CalculateFabricationRequirements(item, r, count)
    local res = r.Result or r
    for _, field in ipairs({ "ItemsRequired", "MaterialsRequired" }) do
        for _, e in ipairs(entries(res[field])) do
            if e.n > 0 then inv:AddItems({ [e.item] = e.n }, true, false, 0) end
        end
    end
end

local function mirrorQueue(id, path, count)
    local fab, owner = fabOf(id)
    if not fab then log("maskiner: tillverkaren %s finns inte här", tostring(id)) return end
    setOwner(owner, "peer")
    local item = boxes.loadItem(path)
    if not item then log("maskiner: hittar inte %s", path) return end
    local list = inventoriesFor(fab)
    local before = snapshot(list)
    local q0 = fab:GetQueueLength()
    applying = true
    local ok, err = pcall(function()
        fab:QueueItem(item, count)
        if fab:GetQueueLength() <= q0 then
            lend(fab, item, count)
            fab:QueueItem(item, count)
        end
    end)
    applying = false
    local moved = restore(list, before)
    log("maskiner: köade %s x%d i %s som den andra: %s, kö %d -> %d, %d föremål tillbaka", path:match("[^%.]+$") or path,
        count, id, ok and "ok" or tostring(err), q0, fab:GetQueueLength(), moved)
end

local function mirrorCancel(id, what, index)
    local fab = fabOf(id)
    if not fab then return end
    local list = inventoriesFor(fab)
    local before = snapshot(list)
    applying = true
    local ok, err = pcall(function()
        if what == "current" then fab:CancelCurrentItem()
        elseif what == "all" then fab:RemoveAllFromQueue()
        elseif what == "index" then fab:RemoveFromQueue(index) end
    end)
    applying = false
    restore(list, before)
    log("maskiner: avbröt %s %s i %s som den andra: %s, kö %d", what, tostring(index or ""), id, ok and "ok" or tostring(err), fab:GetQueueLength())
end

local function sendFor(ctx, kind, ...)
    if applying then return end
    local fab = ctx:get()
    local owner = fab:GetOwner()
    if not isMachine(owner) then return end
    local id = boxes.idOfActor(owner)
    if not id then return end
    if kind == "fabq" then setOwner(owner, "me") end
    net.send(kind, props.wire(id), ...)
end

local hookedNames, lastArm = {}, -100

local function arm()
    if hooked or now() - lastArm < 10 then return end
    lastArm = now()
    local hooks = {
        { "QueueItem", function(ctx, item, count)
            local it = item:get()
            sendFor(ctx, "fabq", pathOf(it), count:get())
            log("maskiner: köade %s x%d", it:GetFName():ToString(), count:get())
        end },
        { "CancelCurrentItem", function(ctx) sendFor(ctx, "fabx", "current", 0) end },
        { "RemoveAllFromQueue", function(ctx) sendFor(ctx, "fabx", "all", 0) end },
        { "RemoveFromQueue", function(ctx, index) sendFor(ctx, "fabx", "index", index:get()) end },
    }
    hooks[#hooks + 1] = { RECYCLER .. ":RecycleFromInventory", function(ctx, inventory)
        local inv = inventory:get()
        local owner = ctx:get()
        local id = boxes.idOfActor(owner)
        if not (id and inv and inv:IsValid()) then return end
        local near = false
        pcall(function()
            local p, l = localPC().Pawn:K2_GetActorLocation(), owner:K2_GetActorLocation()
            near = (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < NEAR_RECYCLER ^ 2
        end)
        if near then
            if jobOwner[pathOf(owner)] ~= "me" then
                net.send("recin", props.wire(id))
                log("maskiner: kvarnen %s startad intill mig, körs här", id)
            end
            setOwner(owner, "me")
        elseif not isHost then
            inv:ClearItems(true)
        end
    end }
    hooks[#hooks + 1] = { OUTPUT .. ":DropItem", function(ctx)
        local owner = ctx:get():GetOwner()
        if not isMachine(owner) or runsJobAt(pathOf(owner)) then return end
        local out = owner.OutputInventoryNew
        if out and out:IsValid() and out:GetTotalNumItems() > 0 then
            local what = boxes.encode(boxes.counts(out))
            out:ClearItems(true)
            log("maskiner: min kopia av %s släpper inte %s (den andras kommer)", owner:GetFName():ToString(), what)
        end
    end }
    local left = 0
    for _, h in ipairs(hooks) do
        local fn = h[2]
        local target = h[1]:find(":", 1, true) and h[1] or (FAB_CLASS .. ":" .. h[1])
        if not hookedNames[target] then
            -- A blueprint function can only be hooked once its class is loaded.
            local ok, err = pcall(RegisterHook, target, function(...)
                local okH, errH = pcall(fn, ...)
                if not okH then log("maskiner: krok %s: %s", target:match("[^:]+$"), tostring(errH)) end
            end)
            if ok then hookedNames[target] = true else left = left + 1 end
            log("maskiner: krok %s %s", target:match("[^%.]+$"), ok and "ok" or tostring(err))
        end
    end
    hooked = left == 0
end

-- Machines that hand out items: fabricators (not the player's) and recyclers.
local machines = {}         -- { actor = path, out = output inventory path, fab = fabricator path }

local function scan()
    lastScan = now()
    machines, machinePaths = {}, {}
    local ok, comps = pcall(FindObjects, 0, "VoyageFabricatorComponent", "", 0, 0x10, false)
    for _, c in ipairs((ok and comps) or {}) do
        pcall(function()
            local owner = c:GetOwner()
            if isMachine(owner) then
                local out = owner.OutputInventoryNew
                local m = { actor = pathOf(owner), fab = pathOf(c) }
                if out and out:IsValid() then m.out = pathOf(out) machinePaths[#machinePaths + 1] = m.out end
                machines[#machines + 1] = m
            end
        end)
    end
    for _, a in ipairs(boxes.modulesNamed("Recycler")) do
        pcall(function()
            local out = a.OutputInventoryNew
            local m = { actor = pathOf(a), recycler = true }
            if out and out:IsValid() then m.out = pathOf(out) machinePaths[#machinePaths + 1] = m.out end
            machines[#machines + 1] = m
        end)
    end
end

function M.runsJob(m) return runsJobAt(m.actor) end

-- The machine within radius of a location.
function M.nearMachine(loc, radius)
    if now() - lastScan >= SCAN_EVERY then scan() end
    for _, m in ipairs(machines) do
        local a = StaticFindObject(m.actor)
        if a and a:IsValid() then
            local l = a:K2_GetActorLocation()
            local dx, dy, dz = l.X - loc.X, l.Y - loc.Y, l.Z - loc.Z
            if dx * dx + dy * dy + dz * dz < radius * radius then
                return m
            end
        end
    end
end

-- A machine whose job runs in the other game never hands anything out here.
local function emptyOutputs()
    if now() - lastScan >= SCAN_EVERY then scan() end
    for _, m in ipairs(machines) do
        if m.out and not runsJobAt(m.actor) then
            local out = StaticFindObject(m.out)
            if out and out:IsValid() and out:GetTotalNumItems() > 0 then
                local what = boxes.encode(boxes.counts(out))
                out:ClearItems(true)
                log("maskiner: tömde min kopias utdata (%s), den andras kommer som släpp", what)
            end
        end
    end
end

-- The other player started this recycler: its output comes from their game.
local function recyclerTaken(id)
    local pc = props.findById(id)
    local owner = pc and pc:IsValid() and pc:GetOwner()
    if not (owner and owner:IsValid()) then log("maskiner: kvarnen %s finns inte här", tostring(id)) return end
    setOwner(owner, "peer")
end

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, boxesModule, host)
    net, log, localPC, now, props, boxes, isHost = netModule, logFn, localPCFn, nowFn, propsModule, boxesModule, host
end

function M.reset() machinePaths, machines, lastScan, jobOwner = {}, {}, -100, {} end

function M.tick()
    arm()
    emptyOutputs()
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "recin" then
        recyclerTaken(msg[3])
        return true
    end
    if kind == "fabq" then
        mirrorQueue(msg[3], msg[4], tonumber(msg[5]) or 1)
        return true
    elseif kind == "fabx" then
        mirrorCancel(msg[3], msg[4], tonumber(msg[5]))
        return true
    end
    return false
end

return M
