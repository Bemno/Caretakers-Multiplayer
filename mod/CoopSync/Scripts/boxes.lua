-- Containers (player boxes, buoys, the fishing box): the host owns what is in
-- them. Each side watches the containers near its own player. A change the
-- host makes is sent as the full contents (boxs); a change the guest makes is
-- sent as item +/- count (boxd), applied by the host, which answers with the
-- full contents for the guest to match. The guest asks for the contents the
-- first time a container comes into range (boxq), since loot can differ.
-- Contents are read with GetAllItems + GetNumItems: no out parameters (see
-- the memory leak in docs/arkiv.md). Item state (ItemData) does not travel.
local M = {}

local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"
local RANGE = 1200
local SCAN_EVERY = 2
local POLL_EVERY = 0.5
local ASK_AGAIN = 5

local net, log, localPC, now, props, isHost
local candidates, lastScan, lastPoll = {}, -100, -100
local known = {}            -- local id -> { counts, fp, pending, asked, closed }
local loaded = {}

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function loadItem(path)
    local item = loaded[path]
    if item and item:IsValid() then return item end
    item = StaticFindObject(path)
    if not (item and item:IsValid()) then
        pcall(LoadAsset, path:match("^(.-)%.") or path)
        item = StaticFindObject(path)
    end
    if item and item:IsValid() then loaded[path] = item return item end
    return nil
end

local function counts(inv)
    local out = {}
    for _, e in ipairs(inv:GetAllItems() or {}) do
        local okG, it = pcall(function() return e:get() end)
        it = (okG and it) or e
        if it:IsValid() then
            local p = pathOf(it)
            loaded[p] = it
            out[p] = inv:GetNumItems(it)
        end
    end
    return out
end

local function fingerprint(inv)
    return inv:GetTotalNumItems() .. ":" .. inv:GetNumOccupiedSlots()
end

local function encode(c)
    local parts = {}
    for p, n in pairs(c) do if n ~= 0 then parts[#parts + 1] = p .. "=" .. n end end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function decode(s)
    local out = {}
    for p, n in (s or ""):gmatch("([^;=]+)=(%-?%d+)") do out[p] = tonumber(n) end
    return out
end

local function diff(from, to)
    local d, any = {}, false
    for p, n in pairs(to) do
        if n ~= (from[p] or 0) then d[p] = n - (from[p] or 0) any = true end
    end
    for p, n in pairs(from) do
        if to[p] == nil and n ~= 0 then d[p] = -n any = true end
    end
    return d, any
end

local function isContainer(owner)
    return owner:GetClass():GetFName():ToString():sub(1, 13) == "BP_Inventory_"
end

local function idOfActor(owner, persistCls)
    -- Placed in the level: the same name in both games, while the save id can
    -- be shared (props.idOf).
    local path = owner:GetFullName():match("%S+%s+(%S+)")
    if path and path:find("_UAID_", 1, true) then return path end
    local pc = owner:GetComponentByClass(persistCls or StaticFindObject("/Script/Voyage.VoyagePersistentActorComponent"))
    local id = pc and pc:IsValid() and pc.PersistentUniqueId
    if not id or id == 0 then return nil end
    return tostring(id)
end

-- 0x30 leaves out class defaults and templates (archetypes), exactly the ones
-- named Default__/_GEN_VARIABLE (measured, testbank/motor/skanpris.lua); with
-- the class looked up once, the scan took half the time (2026-11-21).
-- FindObjects takes 3 ms for 1800 inventories, the calls on each 41 ms, every
-- 2 s a stall (2026-11-24). What an inventory is, is kept by address and looked
-- at again after 20-40 s, spread out; one without a save id yet soon.
local invCache = {}         -- address -> { untilT, cand = { path, id }, owner } or { untilT }
local RECHECK, RECHECK_SPREAD, RECHECK_EMPTY = 20, 20, 2
local MAX_CHECKS = 300      -- after loading every inventory is new

local function scan()
    candidates = {}
    local persistCls = StaticFindObject("/Script/Voyage.VoyagePersistentActorComponent")
    local c0 = os.clock()
    local ok, comps = pcall(FindObjects, 0, "VoyageBaseInventoryComponent", "", 0, 0x30, false)
    local c1, checked = os.clock(), 0
    local t, cache = now(), {}
    for _, c in ipairs((ok and comps) or {}) do
        pcall(function()
            local addr = c:GetAddress()
            local e = invCache[addr]
            -- Over the cap an expired entry is used once more; a new one waits.
            if not (e and e.untilT > t) and checked >= MAX_CHECKS then
                if not e then return end
            elseif not (e and e.untilT > t) then
                checked = checked + 1
                e = { untilT = t + RECHECK + math.random() * RECHECK_SPREAD }
                local owner = c:GetOwner()
                if owner and owner:IsValid() and isContainer(owner) then
                    local id = idOfActor(owner, persistCls)
                    if id then e.cand, e.owner = { path = pathOf(c), id = id }, owner
                    else e.untilT = t + RECHECK_EMPTY end
                end
            end
            cache[addr] = e
            -- The puppet's box is told apart only after it is made.
            if e.cand and not (M.skip and M.skip(e.owner)) then candidates[#candidates + 1] = e.cand end
        end)
    end
    invCache = cache
    local c2 = os.clock()
    if (c2 - c0) * 1000 > 15 then
        log("lådor: genomgång %.0f ms (sökning %.0f, %d av %d kontrollerade)", (c2 - c0) * 1000, (c1 - c0) * 1000,
            checked, #((ok and comps) or {}))
    end
end

local function inventoryOf(id)
    local pc = props.findById(id)
    if not (pc and pc:IsValid()) then return nil end
    local owner = pc:GetOwner()
    if not (owner and owner:IsValid()) then return nil end
    local inv = owner:GetComponentByClass(StaticFindObject(INV_CLASS))
    if inv and inv:IsValid() then return inv, owner end
    return nil
end

-- Applies a per-item difference; returns how many items it could not move.
local function apply(inv, d)
    local short = 0
    for p, n in pairs(d) do
        local item = loadItem(p)
        if not item then
            short = short + math.abs(n)
            log("lådor: hittar inte föremålet %s", p)
        elseif n > 0 then
            local added = inv:AddItems({ [item] = n }, true, true, 0)
            if (added or 0) < n then short = short + n - (added or 0) end
        elseif n < 0 then
            local removed = inv:RemoveItem(item, -n, -1, true)
            if (removed or 0) < -n then short = short + (-n) - (removed or 0) end
        end
    end
    return short
end

local function closedOf(owner)
    local ok, v = pcall(function() return owner.IsClosed end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local function setLid(owner, closed)
    if closedOf(owner) == closed then return end
    -- Open/Close only play the lid; the state is the base class's IsClosed.
    pcall(function() owner.IsClosed = closed end)
    pcall(function() if closed then owner:Close() else owner:Open() end end)
end

local function sendFull(id, inv, k)
    local c = counts(inv)
    k.counts, k.fp = c, fingerprint(inv)
    net.send("boxs", props.wire(id), encode(c))
end

local function watch(id, inv, owner)
    local k = known[id]
    if not k then
        k = { counts = counts(inv), fp = fingerprint(inv), closed = closedOf(owner) }
        known[id] = k
        if not isHost then
            k.pending, k.asked = true, now()
            net.send("boxq", props.wire(id))
        end
        return
    end
    local closed = closedOf(owner)
    if closed ~= nil and closed ~= k.closed then
        k.closed = closed
        net.send("boxlid", props.wire(id), closed and 1 or 0)
    end
    if k.pending then
        if now() - k.asked > ASK_AGAIN then k.asked = now() net.send("boxq", props.wire(id)) end
        return
    end
    local fp = fingerprint(inv)
    if fp == k.fp then return end
    local c = counts(inv)
    local d, any = diff(k.counts, c)
    k.counts, k.fp = c, fp
    if not any then return end
    if isHost then
        net.send("boxs", props.wire(id), encode(c))
    else
        net.send("boxd", props.wire(id), encode(d))
    end
    log("lådor: %s ändrad hos mig: %s", id, encode(d))
end

-- Blueprint class names do not work in FindObjects; modules are found through
-- their C++ module component, filtered on the owner's class name.
function M.modulesNamed(match)
    local out = {}
    local ok, comps = pcall(FindObjects, 0, "VoyageModuleComponent", "", 0, 0x30, false)
    for _, c in ipairs((ok and comps) or {}) do
        pcall(function()
            local owner = c:GetOwner()
            if owner and owner:IsValid() and owner:GetClass():GetFName():ToString():find(match) then
                local full = pathOf(owner)
                if not (full:find("Default__", 1, true) or full:find("_GEN_VARIABLE", 1, true)) then out[#out + 1] = owner end
            end
        end)
    end
    return out
end

M.counts, M.diff, M.apply, M.encode, M.decode, M.loadItem, M.idOfActor = counts, diff, apply, encode, decode, loadItem, idOfActor

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, host)
    net, log, localPC, now, props, isHost = netModule, logFn, localPCFn, nowFn, propsModule, host
end

function M.reset()
    candidates, known, lastScan, lastPoll, invCache = {}, {}, -100, -100, {}
end

function M.tick()
    local t = now()
    if t - lastPoll < POLL_EVERY then return end
    lastPoll = t
    if t - lastScan >= SCAN_EVERY then lastScan = t scan() end
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local me = pawn:K2_GetActorLocation()
    for _, cand in ipairs(candidates) do
        local inv = StaticFindObject(cand.path)
        if inv and inv:IsValid() then
            local owner = inv:GetOwner()
            local l = owner:K2_GetActorLocation()
            local dx, dy, dz = l.X - me.X, l.Y - me.Y, l.Z - me.Z
            if dx * dx + dy * dy + dz * dz < RANGE * RANGE then
                local ok, err = pcall(watch, cand.id, inv, owner)
                if not ok then log("lådor-fel %s: %s", cand.id, tostring(err)) end
            end
        end
    end
end

function M.handle(msg)
    local kind = msg[1]
    if kind ~= "boxs" and kind ~= "boxd" and kind ~= "boxq" and kind ~= "boxlid" then return false end
    local id = msg[3]
    local inv, owner = inventoryOf(id)
    if not inv then
        log("lådor: %s %s finns inte här", kind, tostring(id))
        return true
    end
    local localId = idOfActor(owner) or id
    local k = known[localId]
    if not k then
        k = { counts = counts(inv), fp = fingerprint(inv), closed = closedOf(owner) }
        known[localId] = k
    end
    if kind == "boxlid" then
        local closed = msg[4] == "1"
        k.closed = closed
        setLid(owner, closed)
    elseif kind == "boxq" and isHost then
        sendFull(localId, inv, k)
    elseif kind == "boxd" and isHost then
        local d = decode(msg[4])
        -- The guest may have opened it first and spawned its own loot.
        pcall(function() owner.InitialLootSpawned = true end)
        local short = apply(inv, d)
        log("lådor: gästen ändrade %s: %s%s", localId, msg[4] or "", short > 0 and (" (" .. short .. " fick inte plats)") or "")
        sendFull(localId, inv, k)
    elseif kind == "boxs" and not isHost then
        local target = decode(msg[4])
        local d, any = diff(counts(inv), target)
        if any then
            local short = apply(inv, d)
            log("lådor: %s satt som värdens: %s%s", localId, encode(d), short > 0 and (" (" .. short .. " gick inte)") or "")
        end
        k.counts, k.fp, k.pending = counts(inv), fingerprint(inv), false
    end
    return true
end

return M
