-- Creatures with their own actor (the shark: BP_NPC_Shark_C under
-- BP_SimpleAIController_C) follow the host. The host sends position and
-- heading of its active NPCs 20 times a second and their list every 2 s. The
-- guest stops its NPC spawners, turns off the AI and movement of its copies
-- and moves them to the host's positions every frame; one it lacks is
-- summoned, one the host does not have is hidden. Saved NPCs have the same
-- save id in both games.
--
-- Hits: the guest's hits on its copy are sent (npchit) and the host deals
-- them to its NPC; the host sends each NPC's health, and one dead at the
-- host stays as a wreck at the guest where the host's fell (the loot drops once, at the host, and
-- drops.lua sends it).
--
-- The one who fights owns (arkiv.md pattern 4) is built but off (HANDOVER):
-- the host hands an NPC to the guest when the guest is near it and nearer
-- than the host (npcown), and the owner's game runs its AI. Tried on the
-- bench 2026-11-16: the guest's summoned copy has no health at all (0 of 0,
-- not settable with AddOrUpdateAttribute*/Init) and with its AI on it fell
-- through the world. It needs copies made like the game's spawner makes them.
local M = {}

local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local NPC_CLASS = "VoyageNPCBaseCharacter"
local SCAN_SECONDS, LIST_SECONDS = 2, 2
local RENDER_DELAY = 0.15

local net, log, localPC, now, console, isHost
local npcs, lastScan, lastList = {}, -100, -100      -- key -> actor (active ones)
local remote = {}            -- host key -> { buf, class, t }
local hostList, hostListAt = nil, nil
local copies = {}            -- host key -> local actor path (summoned)
local tamed, hidden = {}, {} -- local address -> true
local pending                -- { key, className, before, t }
local clockOffset = {}
local owner = {}             -- key -> "host" | "guest"; host when missing
local lastSwitch = {}        -- key -> time of the last hand-over
local healthSeen = {}        -- key -> { h, at } own health read for sending
local deadKeys = {}          -- key -> true once dead at the owner
local untame                 -- defined below tame

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end

-- Same as boat.relaxOffset: a hitching host's clock falls behind.
local function relaxOffset(offset, buf, dt)
    local m
    for _, e in ipairs(buf) do if e.off and (not m or e.off < m) then m = e.off end end
    if m and m > offset + 0.02 then return offset + math.min(m - offset - 0.02, 0.2 * dt) end
    return offset
end
local function f1(v) return string.format("%.1f", v or 0) end

local function keyOf(a)
    local pc = a:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then
        local id = pc.PersistentUniqueId
        if id and id ~= 0 then return "id" .. tostring(id) end
    end
    return "p" .. pathOf(a)
end

-- Active = ticking and possessed; the level also holds idle templates.
local function scan()
    if now() - lastScan < SCAN_SECONDS then return end
    lastScan = now()
    local ok, found = pcall(FindObjects, 0, NPC_CLASS, "", 0, 0x10, false)
    local fresh = {}
    for _, a in ipairs((ok and found) or {}) do
        pcall(function()
            if not a:IsValid() or a:GetFullName():find("Default__", 1, true) then return end
            local addr = a:GetAddress()
            local active = tamed[addr] or (a:IsActorTickEnabled() and a.Controller and a.Controller:IsValid())
            if active and not hidden[addr] then fresh[keyOf(a)] = a end
        end)
    end
    for key in pairs(fresh) do
        if not npcs[key] then log("npc: %s (%s) aktiv", key, fresh[key]:GetClass():GetFName():ToString()) end
    end
    npcs = fresh
end

local HEALTH_ATTR = 8          -- EVoyageAttributeType Health (death.lua)
local HEALTH_EVERY = 0.5

-- nil for an NPC without a health system (summoned copies: 0 of 0).
local function healthOf(a)
    local h, m = {}, {}
    if not a:GetHealth(h, m) or not ((tonumber(m.MaxHealth) or 0) > 0) then return nil end
    return tonumber(h.Health)
end

local function myRole() return isHost and "host" or "guest" end
local function iOwn(key) return (owner[key] or "host") == myRole() end
M.ownerOf = function(key) return owner[key] or "host" end
M.owners = function() return owner end

local localFor               -- defined in the guest part

-- The actor this game shows for a key: the host's own, the guest's copy.
local function actorFor(key)
    if isHost then
        local a = npcs[key]
        if a and a:IsValid() then return a end
        return nil
    end
    return localFor(key)
end

local function sendOne(key, a)
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    local hs = healthSeen[key]
    if not hs or now() - hs.at >= HEALTH_EVERY then
        local okH, h = pcall(healthOf, a)
        hs = { h = okH and h or (hs and hs.h), at = now() }
        healthSeen[key] = hs
    end
    net.send("npc", key, pathOf(a:GetClass()), f1(l.X), f1(l.Y), f1(l.Z), f1(r.Yaw), f1(RotP(r)),
        string.format("%.3f", now()), hs.h and f1(hs.h) or "", f1(r.Roll))
end

-- Host ---------------------------------------------------------------------

local function sendAll()
    for key, a in pairs(npcs) do
        if iOwn(key) then
            pcall(function()
                if not a:IsValid() then return end
                sendOne(key, a)
            end)
        end
    end
    if now() - lastList >= LIST_SECONDS then
        lastList = now()
        local keys = {}
        for key in pairs(npcs) do keys[#keys + 1] = key end
        net.send("npcs", table.concat(keys, ","))
    end
end

-- Damage to the guest. The host's AI attacks only what it perceives, and the
-- guest is a puppet it cannot see: given the puppet as target the shark swam
-- to it but never bit (2026-11-15). So the host keeps the puppet as the
-- target of a shark near the guest in the water and bites for it: within the
-- shark's melee range, at most every BITE_COOLDOWN s, it sends the shark's
-- melee damage, and the guest's game takes it through its combat subsystem
-- (its own health, effects and death).
-- Without perceiving the puppet the shark circles 7-9 m from it instead of
-- closing in, so it bites from up to its melee range plus BITE_SLACK.
-- The host's own shark took about 20 health per 5 s from the host; 75 every
-- 1.5 s killed the guest in two bites. To be tuned in play.
local HUNT_RADIUS, WATER_Z, BITE_COOLDOWN, BITE_SLACK, HUNT_EVERY = 3000, 0, 4, 600, 0.5
local LAND_RADIUS = 20000
local lastBite, lastHunt = {}, -100
-- A shark only goes for someone who hit it; left alone it swims off. Hunting
-- for the guest whenever the guest swam near made the shark chase both
-- players all the time (2026-11-18). So the host hunts for the guest only
-- this long after the guest's last hit on that shark.
local PROVOKED_SECONDS = 30
local provokedAt = {}        -- key -> time of the guest's last hit
M.peer = nil                 -- function returning the guest's puppet (set by main.lua)

local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

local function inWater(actor)
    local l = actor:K2_GetActorLocation()
    if l.Z > WATER_Z then return nil end
    local pa = actor.RootComponent:GetAttachParent()
    if pa and pa:IsValid() then return nil end     -- on a boat's deck
    return l
end

-- On land too: the rolling enemy (always hostile) and the big flying creatures never
-- went for 2an, since the host's AI perceives only the host (user 2026-11-24/25). A
-- creature already after the host turns to the guest when the guest is nearer, as it
-- would to the nearest player; one the guest hit goes for the guest as the shark does.
local fromHost = {}          -- key -> true: was after the host when turned to the puppet
local function targetOf(c)
    local okT, t = pcall(function() return c.CurrentTarget end)
    if okT and t and t:IsValid() then return t end
end

local function hunt()
    if now() - lastHunt < HUNT_EVERY then return end
    lastHunt = now()
    local doll = M.peer and M.peer()
    if not (doll and doll:IsValid()) then return end
    local dollAt = doll:K2_GetActorLocation()
    local dollWet = inWater(doll)
    local me = localPC().Pawn
    local meAt = me and me:IsValid() and me:K2_GetActorLocation()
    local ml = me and me:IsValid() and inWater(me)
    for key, a in pairs(npcs) do
        if owner[key] == "guest" then goto continue end
        pcall(function()
            if not a:IsValid() then return end
            local al = a:K2_GetActorLocation()
            local c = a.Controller
            local aquatic = al.Z <= WATER_Z
            -- The flying creatures keep 80-130 m up and 140 m off (bench 2026-11-27);
            -- neither they nor the rolling enemy have a melee ability.
            local melee = a.EnableMeleeAbility
            local provoked = now() - (provokedAt[key] or -1e9) <= PROVOKED_SECONDS
            local dl = aquatic and dollWet or (not aquatic and dollAt)
            local d = dl and dist(al, dl)
            local onHost = c and c:IsValid() and meAt and targetOf(c)
            onHost = onHost and onHost:GetAddress() == me:GetAddress()
            local wanted = d and d <= (aquatic and HUNT_RADIUS or LAND_RADIUS)
            if wanted and aquatic then
                -- The host in the water and nearer: the shark's own choice stands.
                wanted = provoked and not (ml and dist(al, ml) < d)
            elseif wanted then
                local nearer = not meAt or dist(al, meAt) > d
                local onDoll = c and c:IsValid() and targetOf(c)
                onDoll = onDoll and onDoll:GetAddress() == doll:GetAddress()
                wanted = (provoked or onHost or onDoll) and (nearer or provoked)
            end
            if not wanted then
                if lastBite[key] then
                    lastBite[key] = nil
                    -- Back to the host when it was turned to the puppet: the host's AI
                    -- may not pick its target again by itself.
                    local t = c and c:IsValid() and targetOf(c)
                    if fromHost[key] and t and t:GetAddress() == doll:GetAddress() and meAt then c:SetCurrentTarget(me) end
                    fromHost[key] = nil
                    log("npc: %s lämnar gästen", key)
                end
                return
            end
            if not lastBite[key] and onHost then fromHost[key] = true end
            if c and c:IsValid() then c:SetCurrentTarget(doll) end
            if not lastBite[key] then
                lastBite[key] = -100
                log("npc: %s jagar gästen (%.1f m, %s)", key, d / 100, aquatic and "vatten" or "land")
            end
            if melee and d <= a:GetMeleeAttackRange() + BITE_SLACK and now() - (lastBite[key] or -100) >= BITE_COOLDOWN then
                lastBite[key] = now()
                local dmg = a.MeleeAttack.Damage
                net.send("npcbite", key, f1(dmg), f1(al.X), f1(al.Y), f1(al.Z))
                log("npc: %s biter gästen (%.0f) på %.1f m", key, dmg, d / 100)
            end
        end)
        ::continue::
    end
end

-- Guest --------------------------------------------------------------------

local function stopSpawners()
    local ok, found = pcall(FindObjects, 0, "VoyageNPCSpawnerActor", "", 0, 0x10, false)
    for _, s in ipairs((ok and found) or {}) do
        pcall(function()
            if s:IsValid() and (s.MaxSpawn ~= 0 or s.ToSpawn ~= 0) then
                s.MaxSpawn, s.ToSpawn = 0, 0
            end
        end)
    end
end

-- The copy is moved by the mod: no AI, no movement of its own.
local function tame(a, key)
    local addr = a:GetAddress()
    if tamed[addr] then return end
    tamed[addr] = true
    local parts = {}
    pcall(function()
        local c = a.Controller
        if c and c:IsValid() then
            pcall(function() c:StopMovement() end)
            c:SetActorTickEnabled(false)
            parts[#parts + 1] = "ai av"
        end
    end)
    pcall(function() a.CharacterMovement:SetComponentTickEnabled(false) parts[#parts + 1] = "rörelse av" end)
    -- The rolling enemy (BP_NPC_RollerBoi_ProcWalk_C) moves by physics, not a movement
    -- component: its copy kept simulating against the mod's placing and flickered at
    -- the guest (user 2026-11-24).
    pcall(function()
        local n = 0
        for _, e in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent")) or {}) do
            local c = e
            pcall(function() c = e:get() end)
            if c:IsSimulatingPhysics(FName("None")) then
                c:SetSimulatePhysics(false)
                n = n + 1
            end
        end
        if n > 0 then parts[#parts + 1] = string.format("fysik av på %d delar", n) end
    end)
    -- Moved with K2_TeleportTo (boat.moveActor), which refused the copy near
    -- the sea floor (encroaching world geometry) 10-25 % of the time; the copy
    -- needs no collision with the world (channels 0 WorldStatic, 1 WorldDynamic).
    -- Nor with physics bodies and vehicles (5, 6, 7): moved into the guest's
    -- boat hull every frame it pushed the boat, which shook while the host's
    -- lay still (shark near the boat, 2026-11-18).
    for _, c in ipairs({ a.CapsuleComponent, a.Mesh }) do
        pcall(function()
            for _, ch in ipairs({ 0, 1, 5, 6, 7 }) do c:SetCollisionResponseToChannel(ch, 0) end
        end)
    end
    -- A summoned copy has no NPC component and no health (0 of 0); damage on
    -- it crashed the game (2026-11-16), so nothing may hit it.
    local h, m = {}, {}
    local okH, has = pcall(function() return a:GetHealth(h, m) and (m.MaxHealth or 0) > 0 end)
    if not (okH and has) then
        pcall(function() a:SetActorEnableCollision(false) end)
        parts[#parts + 1] = "utan liv: ingen kollision"
    end
    log("npc: %s styrs av värden (%s)", key, table.concat(parts, ", "))
end

untame = function(a, key)
    local addr = a:GetAddress()
    if not tamed[addr] then return end
    tamed[addr] = nil
    pcall(function()
        local c = a.Controller
        if c and c:IsValid() then c:SetActorTickEnabled(true) end
    end)
    pcall(function() a.CharacterMovement:SetComponentTickEnabled(true) end)
    for _, c in ipairs({ a.CapsuleComponent, a.Mesh }) do
        pcall(function()
            c:SetCollisionResponseToChannel(0, 2)
            c:SetCollisionResponseToChannel(1, 2)
        end)
    end
    log("npc: %s styrs här (ai på)", key)
end

local function hide(a, key)
    local addr = a:GetAddress()
    if hidden[addr] then return end
    hidden[addr] = true
    pcall(function() if a.Controller and a.Controller:IsValid() then a.Controller:SetActorTickEnabled(false) end end)
    pcall(function() a:SetActorTickEnabled(false) end)
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a:SetActorHiddenInGame(true) end)
    log("npc: egen %s finns inte hos värden, dold", key)
end

localFor = function(key)
    local path = copies[key]
    if path then
        local a = StaticFindObject(path)
        if a and a:IsValid() then return a end
        copies[key] = nil
    end
    local a = npcs[key]
    if a and a:IsValid() then return a end
end

local function adoptSummon()
    local p = pending
    if not p or now() - p.t < 0.5 then return end
    local ok, found = pcall(FindObjects, 0, p.className, "", 0, 0x10, false)
    for _, a in ipairs((ok and found) or {}) do
        if a:IsValid() and not p.before[a:GetAddress()] then
            pending = nil
            copies[p.key] = pathOf(a)
            tame(a, p.key)
            log("npc: kopia av %s skapad: %s", p.key, pathOf(a))
            return
        end
    end
    if now() - p.t > 5 then log("npc: summon %s gav ingen aktör", p.className) pending = nil end
end

local function mirror()
    stopSpawners()
    adoptSummon()
    if not hostList then return end
    local wanted = {}
    for key in pairs(hostList) do
        local r = remote[key]
        local a = localFor(key)
        if a then
            if iOwn(key) then untame(a, key) else tame(a, key) end
            wanted[a:GetAddress()] = true
        elseif r and not pending then
            local className = r.class:match("%.([^%.]+)$") or r.class
            local before = {}
            local ok, found = pcall(FindObjects, 0, className, "", 0, 0x10, false)
            for _, x in ipairs((ok and found) or {}) do before[x:GetAddress()] = true end
            if not StaticFindObject(r.class) then pcall(LoadAsset, (r.class:gsub("_C$", ""))) end
            pending = { key = key, className = className, before = before, t = now() }
            console("summon " .. className)
            log("npc: skapar kopia av värdens %s (%s)", key, className)
        end
    end
    for key, a in pairs(npcs) do
        if not wanted[a:GetAddress()] and not tamed[a:GetAddress()] then pcall(hide, a, key) end
    end
end

-- Host: who owns each NPC. The guest takes one when near it and nearer than
-- the host by SWITCH_MARGIN; the host takes it back the same way or when the
-- guest is far off. At most one hand-over per NPC every SWITCH_GAP s.
local HANDOVER = false
local ENGAGE, RELEASE, SWITCH_MARGIN, SWITCH_GAP, OWN_EVERY = 2000, 4000, 300, 5, 0.5
local lastOwn = -100

local function decideOwners()
    if not HANDOVER or now() - lastOwn < OWN_EVERY then return end
    lastOwn = now()
    local doll = M.peer and M.peer()
    local me = localPC().Pawn
    if not (doll and doll:IsValid() and me and me:IsValid()) then return end
    local dl, ml = doll:K2_GetActorLocation(), me:K2_GetActorLocation()
    for key, a in pairs(npcs) do
        pcall(function()
            if not a:IsValid() or deadKeys[key] then return end
            if now() - (lastSwitch[key] or -100) < SWITCH_GAP then return end
            local al = a:K2_GetActorLocation()
            local dg, dh = dist(al, dl), dist(al, ml)
            local cur = owner[key] or "host"
            local want = cur
            if cur == "host" and dg < ENGAGE and dg + SWITCH_MARGIN < dh then want = "guest"
            elseif cur == "guest" and (dg > RELEASE or (dh < ENGAGE and dh + SWITCH_MARGIN < dg)) then want = "host" end
            if want == cur then return end
            owner[key], lastSwitch[key] = want, now()
            local l, r = al, a:K2_GetActorRotation()
            net.send("npcown", key, want, f1(l.X), f1(l.Y), f1(l.Z), f1(r.Yaw))
            if want == "guest" then tame(a, key) else untame(a, key) remote[key] = nil end
            log("npc: %s ägs nu av %s (gästen %.1f m, jag %.1f m)", key, want == "guest" and "gästen" or "mig", dg / 100, dh / 100)
        end)
    end
end

-- Guest: hits on a copy go to the host. The hook only reads the copy's path
-- and the damage; a UObject kept to a later tick has crashed UE4SS.
local DAMAGE_HOOK = "/Script/Voyage.VoyageBaseCharacter:OnTakeAnyDamageHandler"
local damageHooked, dealing = false, false

-- Damage to an NPC without a damage type crashed the game (read 0x118,
-- 2026-11-16), also on a shark with health.
local DAMAGE_TYPE = "/Game/Blueprints/DamageTypes/BP_DamageTypePhysicalForce.BP_DamageTypePhysicalForce_C"
local function damageType()
    local c = StaticFindObject(DAMAGE_TYPE)
    if not (c and c:IsValid()) then pcall(LoadAsset, (DAMAGE_TYPE:gsub("%.[^%.]+$", ""))) c = StaticFindObject(DAMAGE_TYPE) end
    if c and c:IsValid() then return c end
end

-- A copy summoned here, or the same NPC loaded from the save (same key).
local function keyOfCopy(path)
    for key, p in pairs(copies) do if p == path then return key end end
    for key, a in pairs(npcs) do
        local ok, hit = pcall(function() return a:IsValid() and pathOf(a) == path end)
        if ok and hit and hostList and hostList[key] then return key end
    end
end

local function hookDamage()
    if damageHooked then return end
    damageHooked = true
    local ok, err = pcall(RegisterHook, DAMAGE_HOOK, function(_, damaged, damage)
        if dealing then return end
        pcall(function()
            local a = damaged:get()
            local d = damage:get()
            if not (a and a:IsValid() and d and d > 0) then return end
            local key = keyOfCopy(pathOf(a))
            if not key then return end
            net.send("npchit", key, f1(d))
            log("npc: jag träffade %s (%.0f), skickat", key, d)
        end)
    end)
    log("npc: träffkrok %s", ok and "ok" or tostring(err))
end

-- Host: the guest's hit, dealt to this game's NPC.
local function takeHit(key, dmg)
    local a = npcs[key]
    if not (a and a:IsValid()) then log("npc: träff på %s som inte finns här", key) return end
    provokedAt[key] = now()
    local doll = M.peer and M.peer()
    local dt = damageType()
    if not dt then log("npc: skadetypen saknas, träffen på %s tas inte", key) return end
    dealing = true
    local ok, err = pcall(function()
        local l = a:K2_GetActorLocation()
        FindFirstOf("VoyageCombatSubsystem"):DoDamage(a, (doll and doll:IsValid()) and doll or nil, (doll and doll:IsValid()) and doll or nil, dt, l,
            { X = 0, Y = 0, Z = -1 }, dmg)
    end)
    dealing = false
    local okH, h = pcall(healthOf, a)
    log("npc: gästen träffade %s (%.0f): %s, liv nu %s", key, dmg, ok and "ok" or tostring(err), okH and tostring(h) or "?")
end

-- Follower: health only goes down, by the game's own damage.
local function followHealth(key, a, h)
    if not h then return end
    if h <= 0 then
        -- Not hidden: the host's dead creature stays where it fell (a shot-down
        -- flyer crashed to the deck and lay there) and its place is still sent; hidden
        -- here, the wreck was never seen by 2an (user 2026-11-25, bench 2026-11-27).
        -- It goes when the host's list drops it.
        if not deadKeys[key] then
            deadKeys[key] = true
            log("npc: %s dog hos ägaren, ligger kvar som vrak", key)
        end
        return
    end
    local okH, mine = pcall(healthOf, a)
    local dt = damageType()
    if okH and mine and mine > h + 1 and dt then
        dealing = true
        pcall(function()
            local l = a:K2_GetActorLocation()
            FindFirstOf("VoyageCombatSubsystem"):DoDamage(a, nil, nil, dt, l, { X = 0, Y = 0, Z = -1 }, mine - h)
        end)
        dealing = false
    end
end

local function lerp(a, b, t) return a + (b - a) * t end
local function wrap(a) return (a + 180) % 360 - 180 end

-- Every frame: each copy between the two host states around the render time.
-- A copy far from the local player is placed every FAR_EVERY frames only:
-- finding and moving a character costs about 0.3 ms a frame.
local FAR_DIST, FAR_EVERY = 10000, 4
local frameNo = 0

function M.frame()
    frameNo = frameNo + 1
    local here
    for key, r in pairs(remote) do
        if frameNo % 15 == 0 or r.far == nil then
            local last = r.buf[#r.buf]
            pcall(function()
                here = here or localPC().Pawn:K2_GetActorLocation()
                r.far = last and ((last.x - here.X) ^ 2 + (last.y - here.Y) ^ 2) > FAR_DIST ^ 2 or false
            end)
        end
        local skip = r.far and frameNo % FAR_EVERY ~= 0
        local a = not skip and not iOwn(key) and (isHost or (hostList and hostList[key])) and actorFor(key)
        local buf = r.buf
        if a and #buf >= 1 and clockOffset[key] then
            pcall(function()
                local t = now()
                clockOffset[key] = relaxOffset(clockOffset[key], buf, t - (r.relaxedAt or t))
                r.relaxedAt = t
                local renderT = t - clockOffset[key] - RENDER_DELAY
                local s
                for i = #buf - 1, 1, -1 do
                    local x, y = buf[i], buf[i + 1]
                    if x.st <= renderT and renderT <= y.st then
                        local t = (renderT - x.st) / math.max(y.st - x.st, 0.001)
                        s = { x = lerp(x.x, y.x, t), y = lerp(x.y, y.y, t), z = lerp(x.z, y.z, t),
                            yaw = x.yaw + wrap(y.yaw - x.yaw) * t, pitch = lerp(x.pitch, y.pitch, t),
                            roll = x.roll + wrap(y.roll - x.roll) * t,
                            vx = (y.x - x.x) / math.max(y.st - x.st, 0.001), vy = (y.y - x.y) / math.max(y.st - x.st, 0.001),
                            vz = (y.z - x.z) / math.max(y.st - x.st, 0.001) }
                        break
                    end
                end
                s = s or buf[#buf]
                require("boat").moveActor(a, { X = s.x, Y = s.y, Z = s.z }, Rot(s.pitch or 0, s.yaw, s.roll or 0))
                -- The animation reads the movement component's velocity.
                pcall(function() a.CharacterMovement.Velocity = { X = s.vx or 0, Y = s.vy or 0, Z = s.vz or 0 } end)
            end)
        end
    end
end

-- --------------------------------------------------------------------------

function M.init(netModule, logFn, localPCFn, nowFn, consoleFn, host)
    net, log, localPC, now, console, isHost = netModule, logFn, localPCFn, nowFn, consoleFn, host
end

function M.reset()
    npcs, lastScan, lastList, remote, hostList, hostListAt = {}, -100, -100, {}, nil, nil
    copies, tamed, hidden, pending, clockOffset = {}, {}, {}, nil, {}
    owner, lastSwitch, healthSeen, deadKeys = {}, {}, {}, {}
end

local lastMirror = -100
function M.tick()
    scan()
    if isHost then
        sendAll()
        local ok, err = pcall(hunt)
        if not ok then log("npc-jakt-fel: %s", tostring(err)) end
        local okO, errO = pcall(decideOwners)
        if not okO then log("npc-ägar-fel: %s", tostring(errO)) end
        for key, a in pairs(npcs) do
            if owner[key] == "guest" and a:IsValid() then pcall(function() tame(a, key) end) end
        end
    else
        if now() - lastMirror >= 1 then
            lastMirror = now()
            mirror()
            hookDamage()
        end
        -- Owned here: position and health go to the host.
        for key, who in pairs(owner) do
            if who == "guest" and not deadKeys[key] then
                local a = localFor(key)
                if a then pcall(sendOne, key, a) end
            end
        end
    end
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "npcown" then
        if isHost then return true end
        local key, who = msg[3], msg[4]
        owner[key] = who
        local a = localFor(key)
        if a then
            if who == "guest" then
                pcall(function()
                    require("boat").moveActor(a, { X = tonumber(msg[5]), Y = tonumber(msg[6]), Z = tonumber(msg[7]) },
                        Rot(0, tonumber(msg[8]) or 0, 0))
                end)
                untame(a, key)
                remote[key] = nil
            else
                tame(a, key)
            end
        end
        log("npc: %s ägs nu av %s", key, who == "guest" and "mig" or "värden")
        return true
    elseif kind == "npc" then
        local key = msg[3]
        if iOwn(key) then return true end
        local st = tonumber(msg[10]) or now()
        local off = now() - st
        if not clockOffset[key] or off < clockOffset[key] then clockOffset[key] = off end
        local r = remote[key] or { buf = {}, class = msg[4] }
        remote[key] = r
        r.class, r.t = msg[4], now()
        r.buf[#r.buf + 1] = { st = st, off = off, x = tonumber(msg[5]), y = tonumber(msg[6]), z = tonumber(msg[7]),
            yaw = tonumber(msg[8]) or 0, pitch = tonumber(msg[9]) or 0, roll = tonumber(msg[12]) or 0 }
        while #r.buf > 20 do table.remove(r.buf, 1) end
        local h = tonumber(msg[11])
        if h then
            local a = actorFor(key)
            if a then followHealth(key, a, h) end
        end
        return true
    elseif kind == "npchit" then
        if isHost then takeHit(msg[3], tonumber(msg[4]) or 0) end
        return true
    elseif kind == "npcbite" then
        if isHost then return true end
        local dmg = tonumber(msg[4]) or 0
        local from = { X = tonumber(msg[5]) or 0, Y = tonumber(msg[6]) or 0, Z = tonumber(msg[7]) or 0 }
        local dead = false
        pcall(function()
            dead = localPC().Pawn:GetComponentByClass(StaticFindObject("/Script/Voyage.VoyageSurvivalComponent")):IsDead()
        end)
        if dead then return true end
        local ok, err = pcall(function()
            local pawn = localPC().Pawn
            local l = pawn:K2_GetActorLocation()
            local dx, dy, dz = l.X - from.X, l.Y - from.Y, l.Z - from.Z
            local len = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1)
            FindFirstOf("VoyageCombatSubsystem"):DoDamage(pawn, nil, localFor(msg[3]), nil, l,
                { X = dx / len, Y = dy / len, Z = dz / len }, dmg)
        end)
        log("npc: %s bet mig (%.0f): %s", msg[3], dmg, ok and "ok" or tostring(err))
        return true
    elseif kind == "npcs" then
        if isHost then return true end
        local list = {}
        for key in (msg[3] or ""):gmatch("[^,]+") do list[key] = true end
        for key in pairs(remote) do if not list[key] then remote[key] = nil end end
        hostList, hostListAt = list, now()
        return true
    end
    return false
end

return M
