-- The other player's backpack, opened with E on the puppet. Each side sends
-- its own backpack (the weight inventory) when it changes (pinv, full). The
-- receiver keeps a hidden player box attached to the puppet with those
-- contents, so the game's own E and inventory menu work on it. What the local
-- player takes out or puts in is sent to the owner as item +/- count (pinvd);
-- the owner applies it to its backpack and sends the new contents back.
-- Item state (ItemData: charge, durability) does not travel.
local M = {}

local BOX_CLASS = "/Game/Blueprints/Interactives/Containers/BP_Inventory_PlayerBox_Small.BP_Inventory_PlayerBox_Small_C"
local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local POLL_EVERY = 0.5
local SUMMON_AGAIN = 10
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

local function setBox(target)
    local a, inv = box()
    if not (a and inv and inv:IsValid()) then pendingPeer = target return end
    local d, any = boxes.diff(boxes.counts(inv), target)
    if any then
        local short = boxes.apply(inv, d)
        if short > 0 then log("kompisens ryggsäck: %d fick inte plats i lådan", short) end
    end
    peer.counts, peer.fp = boxes.counts(inv), fingerprint(inv)
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
    net.send("pinv", boxes.encode(own.counts))
end

local function pollBox()
    local a, inv = box()
    if not (a and inv and inv:IsValid()) or not peer.counts then return end
    local fp = fingerprint(inv)
    if fp == peer.fp then return end
    local c = boxes.counts(inv)
    local d, any = boxes.diff(peer.counts, c)
    peer.counts, peer.fp = c, fp
    if any then
        net.send("pinvd", boxes.encode(d))
        log("kompisens ryggsäck: jag ändrade %s", boxes.encode(d))
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

function M.reset()
    boxPath, lastSummon, own, peer, pendingPeer, lastPoll = nil, -100, { counts = {} }, {}, nil, -100
end

function M.tick()
    if now() - lastPoll < POLL_EVERY then return end
    lastPoll = now()
    pollOwn()
    local puppet = puppetFn()
    if not (puppet and puppet:IsValid()) then return end
    if not box() then
        makeBox(puppet)
        if box() and pendingPeer then setBox(pendingPeer) pendingPeer = nil end
        return
    end
    pollBox()
end

function M.handle(msg)
    if msg[1] == "pinv" then
        setBox(boxes.decode(msg[3]))
        return true
    elseif msg[1] == "pinvd" then
        local inv = backpack()
        if inv then
            local short = boxes.apply(inv, boxes.decode(msg[3]))
            log("kompisens ryggsäck: den andra ändrade min: %s%s", msg[3] or "", short > 0 and (" (" .. short .. " gick inte)") or "")
            -- Send the result even if nothing changed, so the other box is corrected.
            own.fp = nil
        end
        return true
    end
    return false
end

return M
