-- Swarm creatures (crawling robots, slime, hatchlings, night swarms):
-- particles inside the world's BP_SwarmHandler_C, not actors, so npc.lua never
-- saw them and each game had its own (tested 2026-11-17: killing one left it
-- alive for the other).
-- The host owns them like the floating loot: every half second it lists the
-- particles around both players and sends new ones (swn: template, place,
-- speed, rotation, sleeping) and gone ones (swd). The guest makes a copy of
-- each. The guest's spawners are stopped, so a new particle of its own was
-- caused by the guest (a squid hatching when touched): it goes to the host
-- (swg), which makes the real one and answers with its key (swa).
-- A copy the guest killed is sent back (swk) and the host kills its own. The
-- guest's kills are read from the handler's OnParticleDeath_Event: a copy whose
-- Instigator is this player's controller. Until 2026-11-21 every copy near the
-- guest that vanished while KillCounters rose was taken for a kill; the counter
-- rises 0.2 for any death (night swarm dying by itself too), and the host's
-- creatures died in batches with no hit: monsters "died of one hit" from 2an.
-- The particles move by themselves in each game and cannot be moved from
-- Lua, and the guest's copies died or wandered off on their own (night
-- swarm: 90 at the host, 27 at the guest). So the host's simulation decides:
-- it sends where its particles are twice a second (swp) and the guest kills a
-- copy that is more than DRIFT off, or makes it again when it is missing.
-- KillParticle from the mod drops no loot.
-- SpawnParticle only works for a template the handler has registered (the
-- game does it when something spawns that kind); until then a copy waits.
local M = {}

local SCAN_SECONDS = 0.5
local RADIUS = 8000           -- host: sent around each player
local GUEST_RADIUS = 9000     -- guest: copies looked for around each player
local BASELINE_SECONDS = 20   -- the guest's own particles at load are removed
local PENDING_SECONDS = 30    -- a copy waiting for its template gives up
-- A copy is made again only when far off, and not often: fast hatchlings
-- drifted 4 m in half a second, were remade all the time (flicker) and lost
-- their target each time (2026-11-17). Both games draw them to the nearest
-- player (the puppet has an attractor), so they mostly agree anyway.
local DRIFT = 1500            -- cm a copy may be off before it is made again
local REMAKE_GAP = 5          -- seconds between remakes of one copy
local POS_BATCH = 40
local POS_PER_SCAN = 100
local posTurn = 0
local CAUSED_RADIUS = 1000    -- a guest's own new particle this near it was its doing
-- A stopped spawner still refills when one of its creatures dies (not on
-- tick): the guest's refill counted as its doing, the host made a real one
-- each time, and robots kept coming at a nest for minutes (tested 2026-11-17).
-- A new particle this near a spawner is the spawner's, never forwarded.
local SPAWNER_RADIUS = 1500
-- Kinds that multiply by themselves: the guest's copies multiplied too, their
-- young went to the host as the guest's doing and came back as copies, and
-- the slime grew from 45 to 236 in minutes (2026-11-17). Never forwarded.
local function breeds(path) return path and path:find("Growth", 1, true) ~= nil end
-- The night swarm's spawner follows the player, so the guest's stopped one
-- refilled right around the guest, out of reach of the spawner-place check:
-- each refill went to the host as the guest's doing and became one more real
-- creature, without end (2026-11-18). Only the host's own spawner makes them.
local function hostOnly(path) return breeds(path) or (path and path:find("Night", 1, true) ~= nil) end

local net, log, localPC, now, isHost, puppetFn
local lastScan, startedAt = -100, nil
local known = {}              -- host: key -> true (sent or adopted)
local copies = {}             -- guest: host key -> local key
local hostOf = {}             -- guest: local key -> host key
local pending = {}            -- guest: host key -> { tpl, loc, vel, rot, sleeping, t }
local sentOwn = {}            -- guest: local key -> time sent to the host
local myKills = {}            -- guest: host keys of copies this player killed, to send
local selfKilling = false     -- guest: the mod's own KillParticle is running
local deathHooked = false
local templates = {}          -- path -> template object (loaded)
local meta = {}               -- guest: host key -> particle as sent (to remake it)
local killedAt = {}           -- guest: host key -> time the guest killed it
local remadeAt = {}           -- guest: host key -> time its copy was last remade
local spawnersStopped = {}
-- guest: keys alive in the last scan. GetParticle on a key that is gone reads
-- a freed slot, and UE4SS crashed converting its weak pointers (0x18): a copy
-- made in a part of the world not loaded here is destroyed at once
-- (bDestroyOnUnload), and the next swp read it (LAN guest, new world, 2026-11-17).
local lastAround = {}
local spawnerPlaces = {}      -- guest: locations of the stopped spawners

-- The handler placed in the world. FindFirstOf gave the class default object
-- (no particles) while the world's had 85 around the host (2026-11-17).
local handlerPath
local function handler()
    local h = handlerPath and StaticFindObject(handlerPath)
    if h and h:IsValid() then return h end
    handlerPath = nil
    for _, x in ipairs(FindObjects(0, "VoyageSwarmHandler", "", 0, 0, false) or {}) do
        local ok, path = pcall(function() return x:GetFullName():match("%S+%s+(%S+)") end)
        if ok and path and path:find(":PersistentLevel.", 1, true) and not path:find("Default__", 1, true) then
            handlerPath = path
            log("svärm: hanterare %s", path)
            return x
        end
    end
end

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end

local function f1(v) return string.format("%.1f", v or 0) end
local function f4(v) return string.format("%.4f", v or 0) end

local function myPlace()
    local ok, l = pcall(function() return localPC().Pawn:K2_GetActorLocation() end)
    if ok then return l end
end

local function centres()
    local list = {}
    local l = myPlace()
    if l then list[#list + 1] = l end
    pcall(function()
        local p = puppetFn()
        if p and p:IsValid() then list[#list + 1] = p:K2_GetActorLocation() end
    end)
    return list
end

local function keysAround(h, places, radius)
    local set = {}
    for _, c in ipairs(places) do
        local out = {}
        pcall(function() h:GetParticlesInSphere(c, radius, out, true) end)
        for _, k in ipairs(out) do
            local kk = k
            pcall(function() kk = k:get() end)
            set[kk] = true
        end
    end
    return set
end

local function particleFields(h, k)
    local p = h:GetParticle(k)
    local t = p.SwarmTemplate
    if not (t and t:IsValid()) then return nil end
    local l, v, r = p.Location, p.Velocity, p.Rotation
    return { pathOf(t), f1(l.X), f1(l.Y), f1(l.Z), f1(v.X), f1(v.Y), f1(v.Z), f4(r.X), f4(r.Y), f4(r.Z), f4(r.W or 1),
        p.bSleeping and "1" or "0" }
end

local function parseParticle(msg, at)
    local n = function(i, d) return tonumber(msg[at + i]) or d end
    return { tpl = msg[at], t = now(),
        loc = { X = n(1, 0), Y = n(2, 0), Z = n(3, 0) },
        vel = { X = n(4, 0), Y = n(5, 0), Z = n(6, 0) },
        rot = { X = n(7, 0), Y = n(8, 0), Z = n(9, 0), W = n(10, 1) },
        sleeping = msg[at + 11] == "1" }
end

local function template(path)
    local t = templates[path]
    if t and t:IsValid() then return t end
    t = StaticFindObject(path)
    if t and t:IsValid() then templates[path] = t return t end
end

local function spawn(h, p)
    local tpl = template(p.tpl)
    if not tpl then return nil end
    local ok, k = pcall(function()
        return h:SpawnParticle({ SwarmTemplate = tpl, Location = p.loc, Velocity = p.vel, Rotation = p.rot,
            SelectedVolumeID = -1, bDestroyOnUnload = true, bSleeping = p.sleeping })
    end)
    if ok and k and k ~= 0 then return k end
end

-- Host ---------------------------------------------------------------------

local function hostScan(h)
    local near = keysAround(h, centres(), RADIUS)
    for k in pairs(near) do
        if not known[k] then
            known[k] = true
            local ok, fields = pcall(particleFields, h, k)
            if ok and fields then net.send("swn", tostring(k), table.unpack(fields)) end
        end
    end
    for k in pairs(known) do
        if not near[k] then
            known[k] = nil
            net.send("swd", tostring(k))
        end
    end
    -- Reading every particle each scan made 30-40 ms stalls among large swarms
    -- (2026-11-24): over POS_PER_SCAN they take turns.
    local n = 0
    for _ in pairs(near) do n = n + 1 end
    local parts = math.max(1, math.ceil(n / POS_PER_SCAN))
    posTurn = (posTurn + 1) % parts
    local batch = {}
    for k in pairs(near) do
        if k % parts == posTurn then
            pcall(function()
                local l = h:GetParticle(k).Location
                batch[#batch + 1] = string.format("%d=%.0f,%.0f,%.0f", k, l.X, l.Y, l.Z)
            end)
            if #batch >= POS_BATCH then net.send("swp", table.concat(batch, ";")) batch = {} end
        end
    end
    if #batch > 0 then net.send("swp", table.concat(batch, ";")) end
end

-- Guest --------------------------------------------------------------------

-- The guest's swarm spawners stop making particles: whatever appears after
-- that was caused by the guest and becomes the host's.
local SPAWNER_CLASSES = { "VoyageSwarmSpawnerActor", "BP_Night_Swarm_Spawner_C", "LogicAction_BugSpawner_C" }
local function stopSpawners()
    for _, cls in ipairs(SPAWNER_CLASSES) do
        for _, s in ipairs(FindObjects(0, cls, "", 0, 0x10, false) or {}) do
            pcall(function()
                if not s:IsValid() then return end
                local p = pathOf(s)
                if spawnersStopped[p] then return end
                spawnersStopped[p] = true
                s:SetActorTickEnabled(false)
                local l = s:K2_GetActorLocation()
                spawnerPlaces[#spawnerPlaces + 1] = { X = l.X, Y = l.Y, Z = l.Z }
            end)
        end
    end
end

-- The mod removing a copy fires the death event too; it is never a kill.
local function killLocal(h, k)
    selfKilling = true
    pcall(function() h:KillParticle(k) end)
    selfKilling = false
end

local deathLogged = 0
local function onDeath(ctx, key)
    if isHost or selfKilling then return end
    local k = key:get()
    local hk = hostOf[k]
    if not hk then return end
    local mine, who = false, "-"
    pcall(function()
        local o = ctx:get():GetParticle(k).Instigator:Get()
        if o and o:IsValid() then
            local pc = localPC()
            who = o:GetFName():ToString()
            mine = pc and (o:GetAddress() == pc:GetAddress() or (pc.Pawn and o:GetAddress() == pc.Pawn:GetAddress()))
        end
    end)
    if deathLogged < 20 then
        deathLogged = deathLogged + 1
        log("svärm: kopia %s dog, skadad av %s%s", hk, who, mine and " (jag)" or "")
    end
    if mine then myKills[#myKills + 1] = hk end
end

local function hookDeath()
    if deathHooked then return end
    deathHooked = true
    local ok, err = pcall(RegisterHook, "/Game/Blueprints/AI/Swarm/BP_SwarmHandler.BP_SwarmHandler_C:OnParticleDeath_Event",
        function(ctx, _, key) pcall(onDeath, ctx, key) end)
    log("svärm: dödskrok %s", ok and "ok" or tostring(err))
end

-- Egg sacks hatch into the swarm when hit. The guest's hatchlings were taken for
-- its stopped spawner's and removed, and the host's sack was never hit: 2an saw
-- the creatures for a frame and nothing came (user 2026-11-21). The guest's hit
-- goes to the host's sack (same level path), whose hatchlings come back as copies.
local EGG_CLASSES = { "BP_EggSack01", "BP_EggSack02", "BP_EggSack02_Child" }
local eggHooked, eggHits, eggTry = {}, {}, -100
local function hookEggs()
    if #eggHooked == #EGG_CLASSES or now() - eggTry < 5 then return end
    eggTry = now()
    for _, n in ipairs(EGG_CLASSES) do
        local target = string.format("/Game/Blueprints/AI/Characters/%s.%s_C:ReceiveAnyDamage", n, n)
        if not eggHooked[n] and StaticFindObject(target) then
            local ok, err = pcall(RegisterHook, target, function(ctx, dmg)
                pcall(function()
                    local path = pathOf(ctx:get())
                    for _, e in ipairs(eggHits) do if e[1] == path then return end end
                    eggHits[#eggHits + 1] = { path, dmg:get() }
                end)
            end)
            eggHooked[n] = true
            eggHooked[#eggHooked + 1] = n
            log("svärm: äggkrok %s %s", n, ok and "ok" or tostring(err))
        elseif not eggHooked[n] and StaticFindObject(string.format("/Game/Blueprints/AI/Characters/%s.%s_C", n, n)) then
            eggHooked[n] = true
            eggHooked[#eggHooked + 1] = n
        end
    end
end

local function nearSpawner(x, y, z)
    for _, c in ipairs(spawnerPlaces) do
        if (c.X - x) ^ 2 + (c.Y - y) ^ 2 + (c.Z - z) ^ 2 <= SPAWNER_RADIUS ^ 2 then return true end
    end
    return false
end

local lastStop = -100
local function guestScan(h)
    -- FindObjects walks every object: the spawners are looked for now and then.
    if now() - lastStop > 10 then lastStop = now() pcall(stopSpawners) end
    local tries = 0
    for hk, p in pairs(pending) do
        tries = tries + 1
        if tries > 10 then break end
        local k = spawn(h, p)
        if k then
            pending[hk], copies[hk], hostOf[k] = nil, k, hk
        elseif now() - p.t > PENDING_SECONDS then
            pending[hk] = nil
            log("svärm: kopia av %s gick inte att skapa (mallen %s inte registrerad här)", hk, p.tpl)
        end
    end
    local me = myPlace()
    local around = keysAround(h, centres(), GUEST_RADIUS)
    lastAround = around
    hookDeath()
    hookEggs()
    for _, e in ipairs(eggHits) do
        net.send("swe", e[1], string.format("%.1f", e[2] or 0))
        log("svärm: slog äggsäck %s (%.1f), till värden", e[1]:match("[^.]+$"), e[2] or 0)
    end
    eggHits = {}
    for _, hk in ipairs(myKills) do
        local k = copies[hk]
        if k then hostOf[k] = nil end
        copies[hk], meta[hk], killedAt[hk] = nil, nil, now()
        net.send("swk", hk)
    end
    myKills = {}
    -- Copies that vanished without a kill are made again from the host's
    -- positions (swp).
    for hk, k in pairs(copies) do
        if not around[k] then copies[hk], hostOf[k] = nil, nil end
    end
    -- Own particles: at load the game's (removed); later the guest's doing
    -- (sent to the host once, adopted when it answers).
    local baseline = now() - startedAt < BASELINE_SECONDS
    for k in pairs(around) do
        if not hostOf[k] and not sentOwn[k] then
            local ok, fields = pcall(particleFields, h, k)
            local caused = false
            if not baseline and ok and fields and not hostOnly(fields[1]) and me then
                local x, y, z = tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
                local d = math.sqrt((x - me.X) ^ 2 + (y - me.Y) ^ 2 + (z - me.Z) ^ 2)
                caused = d <= CAUSED_RADIUS and not nearSpawner(x, y, z)
            end
            if caused then
                sentOwn[k] = now()
                net.send("swg", tostring(k), table.unpack(fields))
                log("svärm: eget djur %s (%s) till värden", tostring(k), tostring(fields[1]):match("([^/.]+)$"))
            else
                killLocal(h, k)
            end
        end
    end
    for k, t in pairs(sentOwn) do
        if hostOf[k] or now() - t > 10 then sentOwn[k] = nil end
    end
end

function M.init(netModule, logFn, localPCFn, nowFn, host, puppetFunction)
    net, log, localPC, now, isHost, puppetFn = netModule, logFn, localPCFn, nowFn, host, puppetFunction
end

function M.reset()
    lastScan, startedAt, known, copies, hostOf, pending = -100, nil, {}, {}, {}, {}
    sentOwn, myKills, spawnersStopped, handlerPath = {}, {}, {}, nil
    eggHits = {}
    spawnerPlaces = {}
    meta, killedAt, remadeAt, lastAround = {}, {}, {}, {}
end

function M.tick()
    if now() - lastScan < SCAN_SECONDS then return end
    lastScan = now()
    startedAt = startedAt or now()
    local h = handler()
    if not h then return end
    if isHost then hostScan(h) else guestScan(h) end
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "swn" then
        if isHost then return true end
        local hk = msg[3]
        if copies[hk] then return true end
        local p = parseParticle(msg, 4)
        local h = handler()
        local k = h and spawn(h, p)
        meta[hk] = p
        if k then copies[hk], hostOf[k] = k, hk else pending[hk] = p end
        return true
    elseif kind == "swd" then
        if isHost then return true end
        local hk = msg[3]
        pending[hk], meta[hk] = nil, nil
        local k = copies[hk]
        if k then
            copies[hk], hostOf[k] = nil, nil
            local h = handler()
            if h then killLocal(h, k) end
        end
        return true
    elseif kind == "swp" then
        if isHost then return true end
        local h = handler()
        if not h then return true end
        local remade = 0
        for hk, x, y, z in (msg[3] or ""):gmatch("(%d+)=([%-%d]+),([%-%d]+),([%-%d]+)") do
            local p = meta[hk]
            if p and not pending[hk] and not (killedAt[hk] and now() - killedAt[hk] < 3) and remade < 20 then
                local want = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
                local k = copies[hk]
                local off = math.huge
                if k and not lastAround[k] then
                    -- Not seen alive yet (made since the last scan, or gone):
                    -- left alone until a scan has seen it.
                    off = 0
                elseif k then
                    pcall(function()
                        local l = h:GetParticle(k).Location
                        off = math.sqrt((l.X - want.X) ^ 2 + (l.Y - want.Y) ^ 2 + (l.Z - want.Z) ^ 2)
                    end)
                end
                if off > DRIFT and now() - (remadeAt[hk] or -100) > REMAKE_GAP then
                    remadeAt[hk] = now()
                    if k then
                        killLocal(h, k)
                        copies[hk], hostOf[k] = nil, nil
                    end
                    p.loc = want
                    local nk = spawn(h, p)
                    if nk then copies[hk], hostOf[nk] = nk, hk remade = remade + 1 end
                end
            end
        end
        return true
    elseif kind == "swg" then
        -- The guest caused this one: made here for real, answered with its key.
        if not isHost then return true end
        if hostOnly(msg[4]) then return true end
        local h = handler()
        local k = h and spawn(h, parseParticle(msg, 4))
        if k then
            known[k] = true
            net.send("swa", msg[3], tostring(k))
        else
            log("svärm: gästens djur %s gick inte att skapa här (%s)", msg[3], tostring(msg[4]))
        end
        return true
    elseif kind == "swa" then
        if isHost then return true end
        local k, hk = tonumber(msg[3]), msg[4]
        if k then
            copies[hk], hostOf[k], sentOwn[k] = k, hk, nil
            local h = handler()
            if h and lastAround[k] then pcall(function()
                local q = h:GetParticle(k)
                meta[hk] = { tpl = pathOf(q.SwarmTemplate), vel = { X = 0, Y = 0, Z = 0 },
                    rot = { X = q.Rotation.X, Y = q.Rotation.Y, Z = q.Rotation.Z, W = q.Rotation.W }, sleeping = q.bSleeping, t = now() }
            end) end
        end
        return true
    elseif kind == "swe" then
        if not isHost then return true end
        local egg = StaticFindObject(msg[3])
        if egg and egg:IsValid() then
            local pc = localPC()
            local ok, err = pcall(function() egg:ReceiveAnyDamage(tonumber(msg[4]) or 1, nil, pc, pc.Pawn) end)
            log("svärm: den andra slog äggsäck %s: %s", msg[3]:match("[^.]+$"), ok and "ok" or tostring(err))
        else
            log("svärm: äggsäck %s finns inte här", tostring(msg[3]))
        end
        return true
    elseif kind == "swk" then
        if not isHost then return true end
        local k = tonumber(msg[3])
        local h = handler()
        if k and h then
            known[k] = nil
            pcall(function() h:KillParticle(k) end)
            log("svärm: djur %d dödat av den andra", k)
        end
        return true
    end
    return false
end

return M
