-- The other player's backpack, opened with E on the puppet. Each side sends
-- its own backpack (the weight inventory) when it changes (pinv, full). The
-- receiver keeps a hidden player box attached to the puppet with those
-- contents, so the game's own E and inventory menu work on it. What the local
-- player takes out or puts in is sent to the owner as item +/- count (pinvd);
-- the owner applies it to its backpack and sends the new contents back.
-- Item state (ItemData: charge, fill level, durability) travels beside the counts
-- as a list per item name in slot order; a battery handed over this way came full
-- or empty (todo 24/11).
local M = {}

local BOX_CLASS = "/Game/Blueprints/Interactives/Containers/BP_Inventory_PlayerBox_Small.BP_Inventory_PlayerBox_Small_C"
local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"
local MODULE_CLASS = "/Script/Voyage.VoyageModuleComponent"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local POLL_EVERY = 0.5
local SUMMON_AGAIN = 10
local MAX_STATE_BYTES = 4096
-- At the head: looking there shows the box's name (peerpower.lua's choices).
local OFFSET = { X = 0, Y = 0, Z = 155 }   -- the puppet actor stands at its feet; head bone at 160

local net, log, localPC, now, boxes, console, puppetFn
local boxPath, lastSummon = nil, -100
local own = { fp = nil, counts = {} }          -- our backpack as last sent
local peer = { fp = nil, counts = nil }         -- the box as last set from the peer
local pendingPeer = nil                         -- contents received before the box existed
local lastPoll = -100

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function backpack()
    local ok, inv = pcall(function() return localPC():GetInventoryComponent(1) end)
    if ok and inv and inv:IsValid() then return inv end
end

local function fingerprint(inv) return inv:GetTotalNumItems() .. ":" .. inv:GetNumOccupiedSlots() end

local function box()
    local a = boxPath and StaticFindObject(boxPath)
    if a and a:IsValid() then return a, a:GetComponentByClass(StaticFindObject(INV_CLASS)) end
end

local function boxesNow()
    local set = {}
    local ok, comps = pcall(FindObjects, 0, "VoyageBaseInventoryComponent", "", 0, 0x10, false)
    for _, c in ipairs((ok and comps) or {}) do
        pcall(function()
            local o = c:GetOwner()
            if o and o:IsValid() and o:GetClass():GetFName():ToString() == "BP_Inventory_PlayerBox_Small_C" then set[o:GetAddress()] = o end
        end)
    end
    return set
end

-- The box's name is what the game shows when the player looks at it. Defined
-- above makeBox: below it, makeBox called a nil and the name was never set
-- on a new box (pcall log 2026-11-19).
local wantedName
local function applyName()
    local a, inv = box()
    if not (a and inv and inv:IsValid() and wantedName) then return end
    pcall(function() a.MaxNameLength = 200 end)
    inv:SetInventoryName(FText(wantedName))
end

local function makeBox(puppet)
    if now() - lastSummon < SUMMON_AGAIN then return end
    lastSummon = now()
    local cls = StaticFindObject(BOX_CLASS)
    if not (cls and cls:IsValid()) then pcall(LoadAsset, BOX_CLASS:match("^(.-)%.")) end
    local before = boxesNow()
    console("summon BP_Inventory_PlayerBox_Small_C")
    local made
    for addr, o in pairs(boxesNow()) do if not before[addr] then made = o end end
    if not made then log("kompisens ryggsäck: lådan kunde inte skapas") return end
    -- Never saved into the world, never pushed around.
    local pc = made:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then pcall(function() pc:K2_DestroyComponent(made) end) end
    pcall(function() made.RootComponent:SetSimulatePhysics(false) end)
    pcall(function() made:K2_AttachToActor(puppet, FName("None"), 1, 1, 1, false) end)
    pcall(function() made.RootComponent:K2_SetRelativeLocationAndRotation(OFFSET, Rot(0, 0, 0), false, {}, true) end)
    pcall(function() made:SetActorHiddenInGame(true) end)
    -- Query only, like peerpower's battery: with full collision the hidden box,
    -- teleported with the puppet into the deck and the recycler, shoved the
    -- moored boat until it rolled onto the quay (2026-11-17). E still hits it.
    -- Standing in a recycler, its intake (CheckOverlaps) swallowed the box and
    -- spat out copies of the other player's backpack. It skips object type 22,
    -- the type of welded crates (bench 2026-11-17).
    for _, c in ipairs(made:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent")) or {}) do
        pcall(function()
            local comp = c
            pcall(function() comp = c:get() end)
            comp:SetCollisionEnabled(1)
            comp:SetCollisionObjectType(22)
            comp:SetCollisionResponseToChannel(2, 0)
            comp:SetGenerateOverlapEvents(false)
        end)
    end
    -- A small box holds far less than a backpack (22 items did not fit).
    pcall(function()
        local inv = made:GetComponentByClass(StaticFindObject(INV_CLASS))
        inv.bAllowBeyondWeightLimit = true
        inv:SetMaxWeightLimit(100000)
    end)
    boxPath = pathOf(made)
    peer.fp, peer.counts = nil, nil
    pcall(applyName)
    log("kompisens ryggsäck: låda %s på dockan", boxPath)
end

-- name -> { "hex/flags/map", ... } for the slots that carry state, in slot order
-- (map: boxes.mapEncode, the fuel of a petrol backpack).
local function slotStates(inv)
    local out = {}
    inv.Items:ForEach(function(_, v)
        pcall(function()
            local s = v:get()
            local arr = s.Data.ItemData
            local len = arr:GetArrayNum()
            local okM, map = pcall(boxes.mapEncode, s.Data)
            map = okM and map or ""
            -- The whole backpack goes in one message line.
            if (len == 0 and map == "") or len + #map / 2 > MAX_STATE_BYTES then return end
            local hex = {}
            arr:ForEach(function(_, b) hex[#hex + 1] = string.format("%02x", b:get()) end)
            local name = s.AssetName:ToString()
            out[name] = out[name] or {}
            table.insert(out[name], table.concat(hex) .. "/" .. tostring(s.Data.Flags) .. "/" .. map)
        end)
    end)
    return out
end

local function encodeStates(st)
    local parts = {}
    for name, list in pairs(st) do parts[#parts + 1] = name .. ":" .. table.concat(list, ",") end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function decodeStates(s)
    local out = {}
    for name, list in (s or ""):gmatch("([^;:]+):([^;]*)") do
        out[name] = {}
        for e in list:gmatch("[^,]+") do table.insert(out[name], e) end
    end
    return out
end

-- Writes the listed states into the slots of each item in order. only: a set of slot
-- indexes to write (the slots AddItems just made), or nil for all.
local function writeStates(inv, st, only)
    local used, n = {}, 0
    inv.Items:ForEach(function(k, v)
        pcall(function()
            if only and not only[k:get()] then return end
            local s = v:get()
            local name = s.AssetName:ToString()
            local list = st[name]
            if not list then return end
            local arr = s.Data.ItemData
            local j = (used[name] or 0) + 1
            local hex, flags, map = (list[j] or ""):match("^(%x*)/(%-?%d+)/?(.*)$")
            if not hex then return end
            used[name] = j
            local i = 0
            for h in hex:gmatch("%x%x") do
                i = i + 1
                arr[i] = tonumber(h, 16)
            end
            if tonumber(flags) then s.Data.Flags = tonumber(flags) end
            if map ~= "" then pcall(boxes.mapWrite, s.Data, map) end
            n = n + 1
        end)
    end)
    return n
end

-- AddItems gives a new slot a blank state a moment later (a petrol backpack's empty
-- Comp0), over what was written at once: the fuel was lost (bench 2026-11-25). The
-- state is written again after LATE_WRITE.
local LATE_WRITE = 1
local lateWrites = {}       -- { inv = function, states, only, at }

local function slotKeys(inv)
    local set = {}
    inv.Items:ForEach(function(k) set[k:get()] = true end)
    return set
end

local function runLateWrites()
    for i = #lateWrites, 1, -1 do
        local w = lateWrites[i]
        if now() >= w.at then
            table.remove(lateWrites, i)
            local inv = w.inv()
            if inv and inv:IsValid() then
                local okW, n = pcall(writeStates, inv, w.states, w.only)
                log("kompisens ryggsäck: tillstånd skrivet igen i %d platser%s", okW and n or 0, okW and "" or (": " .. tostring(n)))
            end
        end
    end
end

-- Entries in now that are not in before (both lists per name): what was put in.
local function addedStates(before, now_)
    local out = {}
    for name, list in pairs(now_) do
        local left = {}
        for _, e in ipairs(before[name] or {}) do left[e] = (left[e] or 0) + 1 end
        for _, e in ipairs(list) do
            if (left[e] or 0) > 0 then left[e] = left[e] - 1
            else out[name] = out[name] or {} table.insert(out[name], e) end
        end
    end
    return out
end

local function setBox(target, states)
    local a, inv = box()
    if not (a and inv and inv:IsValid()) then pendingPeer = { counts = target, states = states } return end
    local d, any = boxes.diff(boxes.counts(inv), target)
    if any then
        local short = boxes.apply(inv, d)
        if short > 0 then log("kompisens ryggsäck: %d fick inte plats i lådan", short) end
    end
    if states then
        pcall(writeStates, inv, states, nil)
        lateWrites[#lateWrites + 1] = { inv = function() local _, i = box() return i end, states = states, at = now() + LATE_WRITE }
    end
    peer.counts, peer.fp = boxes.counts(inv), fingerprint(inv)
    local okS, st = pcall(slotStates, inv)
    peer.states = okS and st or {}
end

-- Sent again now and then: the first one can arrive while the other still
-- loads (and resets this module).
local RESEND_EVERY = 10
local lastOwnSent = -100

local function pollOwn()
    local inv = backpack()
    if not inv then return end
    local fp = fingerprint(inv)
    if fp == own.fp and now() - lastOwnSent < RESEND_EVERY then return end
    own.fp, lastOwnSent = fp, now()
    own.counts = boxes.counts(inv)
    local okS, st = pcall(slotStates, inv)
    net.send("pinv", boxes.encode(own.counts), okS and encodeStates(st) or "")
end

local function pollBox()
    local a, inv = box()
    if not (a and inv and inv:IsValid()) or not peer.counts then return end
    local fp = fingerprint(inv)
    if fp == peer.fp then return end
    local c = boxes.counts(inv)
    local d, any = boxes.diff(peer.counts, c)
    local okS, st = pcall(slotStates, inv)
    st = okS and st or {}
    local added = encodeStates(addedStates(peer.states or {}, st))
    peer.counts, peer.fp, peer.states = c, fp, st
    if any then
        net.send("pinvd", boxes.encode(d), added)
        log("kompisens ryggsäck: jag ändrade %s%s", boxes.encode(d), added ~= "" and (", tillstånd " .. added) or "")
    end
end

function M.setName(text)
    wantedName = text
    pcall(applyName)
end

-- The puppet's box is not a world container (boxes.lua leaves it alone).
function M.isPuppetBox(actor)
    return boxPath ~= nil and pathOf(actor) == boxPath
end

function M.init(netModule, logFn, localPCFn, nowFn, boxesModule, consoleFn, puppetFunction)
    net, log, localPC, now, boxes, console, puppetFn = netModule, logFn, localPCFn, nowFn, boxesModule, consoleFn, puppetFunction
end

local wornSeen = {}         -- worn item actor address -> time to check it, or true when done

function M.reset()
    wornSeen = {}
    boxPath, lastSummon, own, peer, pendingPeer, lastPoll = nil, -100, { counts = {} }, {}, nil, -100
    lateWrites = {}
end

-- A petrol backpack given by the other player carries its fuel in the slot data
-- (Comp0 in ItemDataMap, 106 = 106 on the bench), yet put on, its module started at 0;
-- an own backpack kept its fuel (user 2026-11-25). A worn item's module that starts
-- empty is filled once from its slot data, a second after it appears.
local RESOURCES = { Electricity = 0, Petrol = 1, Oil = 2, SaltWater = 3, FreshWater = 4, Methane = 10,
    Oxygen = 11, Diesel = 16 }
local WORN_DELAY = 1

local function amountsIn(hex)
    local out = {}
    for name, v in pairs(RESOURCES) do
        local marker = ("EModuleResourceType::" .. name):gsub(".", function(c) return string.format("%02x", c:byte()) end)
        local i = hex:find(marker .. "00", 1, true)
        if i then
            local h = hex:sub(i + #marker + 2, i + #marker + 17)
            local b = {}
            for x in h:gmatch("%x%x") do b[#b + 1] = tonumber(x, 16) end
            local ok, amount = pcall(function() return string.unpack("<d", string.char(table.unpack(b))) end)
            if ok and amount == amount and amount > 0 and amount < 1e7 then out[v] = amount end
        end
    end
    return out
end

local function slotAmounts(daName)
    local pc = localPC()
    for _, owner in ipairs({ pc.Pawn, pc }) do
        for _, e in ipairs(owner:K2_GetComponentsByClass(StaticFindObject("/Script/Voyage.VoyageBaseInventoryComponent")) or {}) do
            local inv = e
            pcall(function() inv = e:get() end)
            local found
            inv.Items:ForEach(function(_, v)
                if found then return end
                local sl = v:get()
                if sl.AssetName:ToString():find(daName, 1, true) then
                    local okM, map = pcall(boxes.mapEncode, sl.Data)
                    if okM and map ~= "" then found = amountsIn(map) end
                end
            end)
            if found and next(found) then return found end
        end
    end
end

local function fillWorn()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local attached = {}
    pawn:GetAttachedActors(attached, true, true)
    local cls = StaticFindObject(MODULE_CLASS)
    for _, e in ipairs(attached) do
        local a = e
        pcall(function() a = e:get() end)
        local addr = a:IsValid() and a:GetAddress()
        local daName = addr and a:GetFName():ToString():match("(DA_[%w_]+)")
        if daName and wornSeen[addr] ~= true then
            if not wornSeen[addr] then
                wornSeen[addr] = now() + WORN_DELAY
            elseif now() >= wornSeen[addr] then
                wornSeen[addr] = true
                local m = a:GetComponentByClass(cls)
                local want = m and m:IsValid() and slotAmounts(daName)
                for t, amount in pairs(want or {}) do
                    local cur = m:GetResourceAmount(t)
                    -- Only an empty module: slot data that lags behind a worn item's use
                    -- must not top it up.
                    if cur < 0.5 and amount > 0.5 then
                        m:ForceAddResource(t, amount - cur)
                        log("utrustning %s: modulen hade %.1f av resurs %d, fylld till %.1f ur platsens data", daName, cur, t, m:GetResourceAmount(t))
                    end
                end
            end
        end
    end
end

function M.tick()
    if now() - lastPoll < POLL_EVERY then return end
    lastPoll = now()
    runLateWrites()
    local okF, errF = pcall(fillWorn)
    if not okF and not M.fillErrLogged then M.fillErrLogged = true log("utrustningsfyllning: %s", tostring(errF)) end
    pollOwn()
    local puppet = puppetFn()
    if not (puppet and puppet:IsValid()) then return end
    if not box() then
        makeBox(puppet)
        if box() and pendingPeer then setBox(pendingPeer.counts, pendingPeer.states) pendingPeer = nil end
        return
    end
    pollBox()
end

function M.handle(msg)
    if msg[1] == "pinv" then
        setBox(boxes.decode(msg[3]), msg[4] and decodeStates(msg[4]) or nil)
        return true
    elseif msg[1] == "pinvd" then
        local inv = backpack()
        if inv then
            local okB, before = pcall(slotKeys, inv)
            local short = boxes.apply(inv, boxes.decode(msg[3]))
            local written = 0
            if msg[4] and msg[4] ~= "" and okB then
                local okA, after = pcall(slotKeys, inv)
                local fresh = {}
                for k in pairs(okA and after or {}) do if not before[k] then fresh[k] = true end end
                local st = decodeStates(msg[4])
                local okW, n = pcall(writeStates, inv, st, fresh)
                written = okW and n or 0
                lateWrites[#lateWrites + 1] = { inv = backpack, states = st, only = fresh, at = now() + LATE_WRITE }
            end
            log("kompisens ryggsäck: den andra ändrade min: %s%s, %d tillstånd", msg[3] or "", short > 0 and (" (" .. short .. " gick inte)") or "", written)
            -- Send the result even if nothing changed, so the other box is corrected.
            own.fp = nil
        end
        return true
    end
    return false
end

return M
