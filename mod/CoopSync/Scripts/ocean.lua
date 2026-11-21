-- Loot floating in the water (crates, tyres, trash: dynamic mesh actors showing
-- a DA_ItemLoot item) is spawned at random by BP_OceanTrashArea in each game.
-- The host owns it: the guest's areas are stopped (MaxToSpawnActive 0) and
-- loot the guest spawns anyway is removed; new loot in the host's game is sent
-- as a drop, which the guest recreates and links by id like any dropped item.
-- Loot from the shared save has the same save id in both games.
--
-- Since 2026-11-16 the same goes for every loose item the game makes on its
-- own away from the players: an egg sack or crate bursting, a recycler on
-- land. Each game burst its own and the loot was there twice, appearing out
-- of nowhere in the other game. The host's is sent; the guest's is removed.
local M = {}

local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local SCAN_SECONDS = 2
local LOAD_GRACE = 60          -- loot already there or streaming in counts as the save's
local OWN_DROP_RADIUS = 500    -- drops.lua handles what a player drops
local GUEST_GRACE = 5          -- a copy of the host's loot gets linked within this

local net, log, localPC, now, props, isHost
local worldSince, lastScan = nil, -100
local known = {}               -- save id -> true: loot seen before
local suspects = {}            -- guest: save id -> first seen
local stoppedAreas = {}

local function f1(v) return string.format("%.1f", v or 0) end

-- Every loose item in the world is gone through: the class is looked up once
-- per scan, not per item (scans took up to 107 ms in new areas, 2026-11-21).
local function loot()
    local ok, found = pcall(FindObjects, 0, "VoyageDynamicMeshActor", "", 0, 0x10, false)
    local list = {}
    local persistCls = StaticFindObject(PERSIST_CLASS)
    if not (persistCls and persistCls:IsValid()) then return list end
    for _, a in ipairs((ok and found) or {}) do
        pcall(function()
            if not a:IsValid() then return end
            local it = a.CurrentVisualizeItem
            if not (it and it:IsValid()) then return end
            local pc = a:GetComponentByClass(persistCls)
            local id = pc and pc:IsValid() and pc.PersistentUniqueId
            if not id or id == 0 then return end
            list[#list + 1] = { actor = a, id = tostring(id), item = it }
        end)
    end
    return list
end

local function nearOwnPawn(a)
    local ok, near = pcall(function()
        local p, l = localPC().Pawn:K2_GetActorLocation(), a:K2_GetActorLocation()
        return (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < OWN_DROP_RADIUS ^ 2
    end)
    return ok and near
end

-- A copy made for the other player's drop is linked to their id.
local function isLinked(id) return props.isCopy(id) end

local function stopAreas()
    local ok, found = pcall(FindObjects, 0, "VoyageOceanTrashArea", "", 0, 0x10, false)
    for _, a in ipairs((ok and found) or {}) do
        pcall(function()
            if a:IsValid() and a.MaxToSpawnActive ~= 0 then
                local name = a:GetFName():ToString()
                if not stoppedAreas[name] then log("hav: stoppar eget skräpområde %s (max %d)", name, a.MaxToSpawnActive) end
                stoppedAreas[name] = true
                a.MaxToSpawnActive = 0
            end
        end)
    end
end

local function hostScan(baseline)
    local sent = 0
    for _, x in ipairs(loot()) do
        if not known[x.id] then
            known[x.id] = true
            if not baseline and not isLinked(x.id) and not props.sentDrops[x.id] and not nearOwnPawn(x.actor) then
                local l, r = x.actor:K2_GetActorLocation(), x.actor:K2_GetActorRotation()
                props.markOwn(x.id)
                net.send("drop", props.wire(x.id), x.item:GetFullName():match("%S+%s+(%S+)"), f1(l.X), f1(l.Y), f1(l.Z),
                    f1(RotP(r)), f1(r.Yaw), f1(r.Roll), 1, "w")
                sent = sent + 1
                log("värld: nytt föremål %s (id %s) skickat", x.item:GetFName():ToString(), x.id)
            end
        end
    end
    return sent
end

-- Egg sacks: both games hand out the same new save ids, so a guest's own sack
-- could carry the id of a host's sack elsewhere and was kept as the host's
-- (2026-11-17). Here only sacks from the save and the mod's copies stay.
local sackPaths = {}           -- guest: path -> true for sacks present at load

local function guestSacks(baseline, items)
    for _, x in ipairs(items) do
        pcall(function()
            if not x.actor:GetClass():GetFName():ToString():find("Eggsack", 1, true) then return end
            local path = x.actor:GetFullName():match("%S+%s+(%S+)")
            if baseline then sackPaths[path] = true return end
            if sackPaths[path] or props.claimedPaths[path] then return end
            suspects[path] = suspects[path] or now()
            if now() - suspects[path] > GUEST_GRACE then
                suspects[path] = nil
                sackPaths[path] = true
                -- Removed here: the scan below goes through the same list.
                known[x.id] = true
                props.suppressGone(x.id)
                log("värld: egen äggsäck (id %s) är inte värdens, tas bort", x.id)
                x.actor:K2_DestroyActor()
            end
        end)
    end
end

local function guestScan(baseline)
    local items = loot()
    pcall(guestSacks, baseline, items)
    for _, x in ipairs(items) do
        if not known[x.id] then
            if baseline or isLinked(x.id) or props.sentDrops[x.id] or nearOwnPawn(x.actor) then
                known[x.id] = true
            else
                suspects[x.id] = suspects[x.id] or now()
                if now() - suspects[x.id] > GUEST_GRACE then
                    known[x.id] = true
                    suspects[x.id] = nil
                    props.suppressGone(x.id)
                    log("värld: eget föremål %s (id %s) finns inte hos värden, tas bort", x.item:GetFName():ToString(), x.id)
                    pcall(function() x.actor:K2_DestroyActor() end)
                end
            end
        end
    end
end

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, host)
    net, log, localPC, now, props, isHost = netModule, logFn, localPCFn, nowFn, propsModule, host
end

function M.reset()
    worldSince, lastScan, known, suspects, stoppedAreas, sackPaths = nil, -100, {}, {}, {}, {}
end

function M.tick()
    worldSince = worldSince or now()
    if now() - lastScan < SCAN_SECONDS then return end
    lastScan = now()
    if not isHost then pcall(stopAreas) end
    local baseline = now() - worldSince < LOAD_GRACE
    if isHost then hostScan(baseline) else guestScan(baseline) end
end

return M
