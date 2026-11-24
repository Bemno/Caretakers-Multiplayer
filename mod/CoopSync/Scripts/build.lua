-- Building. A blueprint (BP_Location_Fabricator_C) is real only in the game of
-- whoever placed it; the other game shows a ghost: the module itself, summoned
-- without collision and without its persistent component (so it is never saved
-- as a free module). When the blueprint is built the ghost (or the same
-- blueprint, when it came with the save) is removed and the module is summoned
-- in its place with the ids paired. A blueprint is never created by the mod:
-- summon and deferred spawn both left it half set up and crashed the game.
local M = {}

local FAB = "BP_Location_Fabricator_C"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local POLL_SECONDS = 1
local NEAR = 400            -- cm: a new module this close to a vanished blueprint is what it became

local net, log, now, props, console, localPC
local lastPoll = 0
local fabs                  -- path -> { key, item, loc, rot, near } for blueprints in this game
local ghosts = {}           -- key -> path of a ghost module shown for the peer's blueprint
local classOf = {}          -- item path -> module class path, learnt from finished builds

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function persistOf(actor)
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then return pc end
end

local function idOf(actor)
    local pc = persistOf(actor)
    local id = pc and pc.PersistentUniqueId
    if id and id ~= 0 then return tostring(id) end
end

local function listOf(className)
    local ok, found = pcall(FindObjects, 0, className, "", 0, 0, false)
    local list = {}
    for _, a in ipairs((ok and found) or {}) do
        local okV, v = pcall(function() return a:IsValid() and not a:GetFullName():find("Default__", 1, true) end)
        if okV and v then list[#list + 1] = a end
    end
    return list
end

local function dist(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

-- Paths of modules within NEAR of loc. Only modules can be what a blueprint
-- became; going through every saved object took 200-370 ms for each new
-- blueprint (2026-11-24).
local function actorsNear(loc)
    local set = {}
    for _, mc in ipairs(listOf("VoyageModuleComponent")) do
        pcall(function()
            local a = mc:GetOwner()
            if a and a:IsValid() and dist(a:K2_GetActorLocation(), loc) < NEAR then set[pathOf(a)] = a end
        end)
    end
    return set
end

local mountOf   -- defined further down, next to place
local notModule -- defined further down, next to learn

local function describe(fab)
    local item = fab.FabricationItemOrPattern
    local v, r = fab:K2_GetActorLocation(), fab:K2_GetActorRotation()
    return {
        key = props.wire(idOf(fab) or ""), item = (item and item:IsValid()) and pathOf(item) or nil,
        loc = { X = v.X, Y = v.Y, Z = v.Z }, rot = Rot(RotP(r) or 0, r.Yaw or 0, r.Roll or 0),
        near = actorsNear(v), mount = { mountOf(fab) },
    }
end

-- The module class for an item, learnt from an earlier finished build. The
-- item itself does not name it: its DroppedActor is the parts box a dropped
-- module turns into, so the first blueprint of a kind shows no ghost.
local function moduleClass(itemPath)
    if classOf[itemPath] then return classOf[itemPath] end
    log("bygge: ingen modulklass känd för %s än (spöke visas efter första bygget)", itemPath)
end

-- Summons a class and returns the new actor (summon only finds loaded classes).
local function summon(classPath)
    local cls = StaticFindObject(classPath)
    if not (cls and cls:IsValid()) then
        pcall(LoadAsset, classPath:gsub("_C$", ""))
        pcall(LoadAsset, classPath:match("^(.-)%.") or classPath)
    end
    local name = classPath:match("%.([^%.]+)$") or classPath
    local before = {}
    for _, a in ipairs(listOf(name)) do before[a:GetAddress()] = true end
    console("summon " .. name)
    for _, a in ipairs(listOf(name)) do
        if not before[a:GetAddress()] then return a end
    end
end

local function runtimeSpawn(classPath, loc, rot)
    local cls = StaticFindObject(classPath)
    if not (cls and cls:IsValid()) then
        pcall(LoadAsset, (classPath:gsub("_C$", "")))
        cls = StaticFindObject(classPath)
    end
    if not (cls and cls:IsValid()) then return end
    local half = math.rad(rot.Yaw or 0) / 2
    local ok, a = pcall(function()
        local pc = localPC()
        return StaticFindObject("/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary"):SpawnRuntimeActorFromClass(pc.Pawn:GetWorld(), cls,
            { Translation = { X = loc.X, Y = loc.Y, Z = loc.Z }, Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
              Scale3D = { X = 1, Y = 1, Z = 1 } },
            { Value = 0 }, nil, nil)
    end)
    if ok and a and a:IsValid() then
        log("bygge: %s skapad som runtime-aktör", classPath)
        return a
    end
    log("bygge: runtime-skapande av %s misslyckades (%s), summon i stället", classPath, tostring(a))
end

-- What an actor is fastened to (a module built on the boat sits on the boat)
-- and where relative to it, as seven message fields. The boat floats a little
-- differently in the two games, so a world position put it off the deck, and
-- it stayed behind when the boat moved.
mountOf = function(actor)
    local ok, fields = pcall(function()
        local parent = actor:GetAttachParentActor()
        if not (parent and parent:IsValid()) then return nil end
        local id = idOf(parent)
        local key = id and ("i" .. props.wire(id)) or ("p" .. pathOf(parent))
        local root = actor.RootComponent
        local l, r = root.RelativeLocation, root.RelativeRotation
        return { key, string.format("%.1f", l.X), string.format("%.1f", l.Y), string.format("%.1f", l.Z),
            string.format("%.2f", RotP(r)), string.format("%.2f", r.Yaw), string.format("%.2f", r.Roll) }
    end)
    if ok and fields then return table.unpack(fields) end
    return "-", "0", "0", "0", "0", "0", "0"
end

local function resolveMount(key)
    if key:sub(1, 1) == "i" then
        local pc = props.findById(key:sub(2))
        local owner = pc and pc:GetOwner()
        if owner and owner:IsValid() then return owner end
    elseif key:sub(1, 1) == "p" then
        local a = StaticFindObject(key:sub(2))
        if a and a:IsValid() then return a end
    end
end

-- m: the seven mount fields from the message, starting at index i.
local function place(actor, loc, rot, m, i)
    local key = m and m[i]
    local parent = key and key ~= "-" and resolveMount(key)
    if parent then
        local n = function(k) return tonumber(m[i + k]) or 0 end
        -- A runtime-spawned player box did not attach (static root), and its
        -- deck offset became a world position far off the map (2026-11-16).
        pcall(function() actor.RootComponent:SetMobility(2) end)
        -- A simulating root is not attached: the large player box stayed loose,
        -- was put at the world spot and bounced off out of sight (2026-11-19).
        pcall(function() actor.RootComponent:SetSimulatePhysics(false) end)
        actor:K2_AttachToActor(parent, FName("None"), 0, 0, 0, false)
        local pa = actor:GetAttachParentActor()
        if pa and pa:IsValid() and pa:GetAddress() == parent:GetAddress() then
            actor.RootComponent:K2_SetRelativeLocationAndRotation({ X = n(1), Y = n(2), Z = n(3) },
                Rot(n(4), n(5), n(6)), false, {}, true)
            return
        end
        log("bygge: %s gick inte att fästa vid %s, lägger på världsposition", pathOf(actor), key)
    end
    if key and key ~= "-" and not parent then log("bygge: hittar inte %s att fästa vid, lägger på världsposition", key) end
    actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
end

local function destroyLocal(path)
    local a = StaticFindObject(path)
    if not (a and a:IsValid()) then return end
    local id = idOf(a)
    if id then props.suppressGone(id) end
    a:K2_DestroyActor()
end

-- Remote blueprints -----------------------------------------------------------

-- A real blueprint draws every part with one dynamic instance of this
-- material: Color is blue (DefaultColor) or red (PausedColor, materials
-- missing), Fade runs while it is being built, Origin/HalfHeight place the
-- fade on the module.
local OVERLAY = "/Game/Materials/Crafting/FX_DissolveOverlay_Mat.FX_DissolveOverlay_Mat"
local BLUE = { R = 0, G = 0.75, B = 1, A = 1 }

local function setOrigin(mid, a)
    local o, e = {}, {}
    a:GetActorBounds(true, o, e, false)
    local c, x = (o.X and o) or o.Origin, (e.X and e) or e.BoxExtent
    mid:SetVectorParameterValue(FName("Origin"), { R = c.X, G = c.Y, B = c.Z, A = 1 })
    mid:SetScalarParameterValue(FName("HalfHeight"), x.Z)
end

local function blueprintMaterial(a)
    local parent = StaticFindObject(OVERLAY)
    if not (parent and parent:IsValid()) then
        pcall(LoadAsset, OVERLAY)
        parent = StaticFindObject(OVERLAY)
    end
    if not (parent and parent:IsValid()) then return nil end
    local mid = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary"):CreateDynamicMaterialInstance(localPC(), parent, FName("None"), 0)
    if not (mid and mid:IsValid()) then return nil end
    mid:SetVectorParameterValue(FName("Color"), BLUE)
    mid:SetVectorParameterValue(FName("BaseColor"), { R = 0.1, G = 0.1, B = 0.1, A = 1 })
    mid:SetScalarParameterValue(FName("Fade"), 0)
    setOrigin(mid, a)
    return mid
end

-- The ghost's material, looked up again each time (a UObject kept between
-- ticks has crashed UE4SS).
local function ghostMaterial(key)
    local a = ghosts[key] and StaticFindObject(ghosts[key])
    if not (a and a:IsValid()) then return nil end
    local comps = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    for _, c in ipairs(comps or {}) do
        local okG, comp = pcall(function() return c:get() end)
        comp = (okG and comp) or c
        local ok, mat = pcall(function() return comp:GetMaterial(0) end)
        if ok and mat and mat:IsValid() and mat:GetFName():ToString():find("FX_DissolveOverlay", 1, true) then return mat, a end
    end
end

local function applyLook(key, r, g, b, fade)
    for path, f in pairs(fabs or {}) do
        if f.copy and f.key == key then
            local fab = StaticFindObject(path)
            local mid = fab and fab:IsValid() and fab.DynamicMaterialInstOverlay
            if mid and mid:IsValid() then
                mid:SetVectorParameterValue(FName("Color"), { R = r, G = g, B = b, A = 1 })
                -- Without Fade the copy kept the material's default and looked
                -- dull next to the placer's own, which has Fade 0 (2026-11-15).
                mid:SetScalarParameterValue(FName("Fade"), fade)
            end
            return
        end
    end
    local mat, a = ghostMaterial(key)
    if not mat then return end
    mat:SetVectorParameterValue(FName("Color"), { R = r, G = g, B = b, A = 1 })
    mat:SetScalarParameterValue(FName("Fade"), fade)
    -- The ghost rides on the boat; the fade is placed where it is now.
    setOrigin(mat, a)
end

-- Placer: the colour and fade of each own blueprint, sent when they change.
local LOOK_SECONDS = 0.25
local lastLook, sentLook = 0, {}
local function sendLooks()
    if now() - lastLook < LOOK_SECONDS then return end
    lastLook = now()
    for path, f in pairs(fabs or {}) do
        if not f.fromSave and not f.copy then
            local fab = StaticFindObject(path)
            local mid = fab and fab:IsValid() and fab.DynamicMaterialInstOverlay
            if mid and mid:IsValid() then
                local c = mid:K2_GetVectorParameterValue(FName("Color"))
                local fade = mid:K2_GetScalarParameterValue(FName("Fade"))
                local s = string.format("%.2f|%.2f|%.2f|%.2f", c.R or 0, c.G or 0, c.B or 0, fade or 0)
                if sentLook[f.key] ~= s then
                    sentLook[f.key] = s
                    net.send("bplook", f.key, string.format("%.2f", c.R or 0), string.format("%.2f", c.G or 0),
                        string.format("%.2f", c.B or 0), string.format("%.2f", fade or 0))
                end
            end
        end
    end
end

-- A real blueprint for the peer's, owned by the boat: owned by a player it
-- would take that player's materials and build by itself, owned by the boat
-- it waits, like one loaded from the save. The player here can remove it
-- (bpgone goes back) or build it by interacting (built goes back); a ghost
-- module could do neither.
local FACTORY = "/Game/Blueprints/Fabrication/BP_Physical_Fabricator_Factory.BP_Physical_Fabricator_Factory_C"

local function hullOf(b)
    for _, e in ipairs(b:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent")) or {}) do
        local okG, c = pcall(function() return e:get() end)
        c = (okG and c) or e
        if c:GetFName():ToString() == "VehicleMesh" then return c end
    end
end

local function realCopy(key, itemPath, loc, rot, m)
    local item = StaticFindObject(itemPath)
    if not (item and item:IsValid()) then pcall(LoadAsset, itemPath:match("^(.-)%.") or itemPath) item = StaticFindObject(itemPath) end
    local factory = StaticFindObject(FACTORY)
    if not (factory and factory:IsValid()) then pcall(LoadAsset, FACTORY:gsub("_C$", "")) factory = StaticFindObject(FACTORY) end
    local sub = FindFirstOf("VoyageEffectSubsystem")
    local mount = m[9] and m[9] ~= "-" and resolveMount(m[9])
    local owner, hull = mount, nil
    if mount and require("boat").isBoat(mount) then hull = hullOf(mount) end
    if not owner then for _, b in pairs(require("boat").list()) do owner = b break end end
    if not (item and item:IsValid() and factory and factory:IsValid() and sub and sub:IsValid() and owner) then
        log("bygge: riktig kopia av %s går inte (föremål %s, fabrik %s, ägare %s)", key, tostring(item ~= nil), tostring(factory ~= nil), tostring(owner ~= nil))
        return false
    end
    local wl = loc
    if mount then
        local n = function(k) return tonumber(m[9 + k]) or 0 end
        wl = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):TransformLocation(mount:GetTransform(), { X = n(1), Y = n(2), Z = n(3) })
    end
    local half = math.rad(rot.Yaw or 0) / 2
    local transform = { Translation = { X = wl.X, Y = wl.Y, Z = wl.Z }, Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
        Scale3D = { X = 1, Y = 1, Z = 1 } }
    local before = {}
    for _, a in ipairs(listOf(FAB)) do before[pathOf(a)] = true end
    local ok, fab = pcall(function() return sub:Fabricate(owner, item, transform, hull, factory) end)
    if not (ok and fab and fab:IsValid()) then
        log("bygge: riktig kopia av %s misslyckades: %s", key, tostring(fab))
        return false
    end
    local path = pathOf(fab)
    -- Fabricate leaves it without parts (invisible); placing one in the game
    -- builds them with this.
    local okV, errV = pcall(function() fab:UpdateVisualizationItem(item) end)
    if not okV then log("bygge: kopians utseende: %s", tostring(errV)) end
    if mount and not hull then pcall(place, fab, loc, rot, m, 9) end
    fabs = fabs or {}
    local okD, f = pcall(describe, fab)
    f = okD and f or { loc = wl, near = {}, mount = { "-", "0", "0", "0", "0", "0", "0" } }
    f.key, f.item, f.copy = key, itemPath, true
    fabs[path] = f
    log("bygge: riktig kopia %s av den andras blueprint %s (%s)", path, key, itemPath)
    return true
end

local function showGhost(key, itemPath, loc, rot, m)
    if ghosts[key] then return end
    for _, f in pairs(fabs or {}) do
        if f.key == key then return end      -- this game has it too (came with the save, or a real copy)
    end
    local okR, made = pcall(realCopy, key, itemPath, loc, rot, m)
    if okR and made then return end
    if not okR then log("bygge-fel (riktig kopia): %s", tostring(made)) end
    local cls = moduleClass(itemPath)
    if not cls then return end
    local a = summon(cls)
    if not a then log("bygge: spöke för %s kunde inte skapas", key) return end
    local pc = persistOf(a)
    if pc then pcall(function() pc:K2_DestroyComponent(a) end) end
    pcall(function() a:SetActorEnableCollision(false) end)
    place(a, loc, rot, m, 9)
    -- Looks like a blueprint: the blueprint's own overlay material, coloured
    -- and faded as the placer's (bplook); without it the placement material.
    local okM, errM = pcall(function()
        local mat = blueprintMaterial(a) or localPC().Pawn.LocationFabricatorPlacementComponent.Material
        local comps = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
        for _, c in ipairs(comps) do
            local okG, comp = pcall(function() return c:get() end)
            comp = (okG and comp) or c
            pcall(function()
                for i = 0, comp:GetNumMaterials() - 1 do comp:SetMaterial(i, mat) end
            end)
        end
    end)
    if not okM then log("bygge: spökets material: %s", tostring(errM)) end
    ghosts[key] = pathOf(a)
    log("bygge: spöke %s för den andras blueprint %s (%s)", pathOf(a), key, itemPath)
end

local function removeRemote(key, why)
    if ghosts[key] then
        local a = StaticFindObject(ghosts[key])
        if a and a:IsValid() then a:K2_DestroyActor() end
        ghosts[key] = nil
    end
    for path, f in pairs(fabs or {}) do
        if f.key == key then
            destroyLocal(path)
            fabs[path] = nil
        end
    end
    log("bygge: blueprint %s borta här (%s)", key, why)
end

-- On a boat the copy is welded into the hull like the game's own modules
-- (props.weldOnBoat). Only attached, with full collision after the half second,
-- it shoved the hull once this game ran the boat's physics: a lamp built at the
-- bow by the other player spun the boat round its bow (2026-11-24). Where the
-- other game runs the physics weldOnBoat fastens query only, and so do the
-- module's other parts, so it cannot push when the physics moves here later.
local function boatAbove(a)
    local boat = require("boat")
    local p = a:GetAttachParentActor()
    for _ = 1, 5 do
        if not (p and p:IsValid()) then return nil end
        if boat.isBoat(p) then return p end
        p = p:GetAttachParentActor()
    end
end

local function fastenOnBoat(a)
    local root = a.RootComponent
    local l = root:K2_GetComponentLocation()
    local b = boatAbove(a)
    if not (b or props.onBoat(l)) then return false end
    props.weldOnBoat(root, l, b)
    if not StaticFindObject("/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary"):IsPrimitiveWelded(root) then
        for _, e in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent")) or {}) do
            local okG, c = pcall(function() return e:get() end)
            c = (okG and c) or e
            pcall(function() c:SetCollisionEnabled(1) end)
        end
    end
    return true
end

local function buildRemote(key, classPath, loc, rot, peerModuleId, itemPath, m)
    removeRemote(key, "byggd hos den andra")
    if M.notModule(classPath) then log("bygge: %s är ingen modul, skapas inte", classPath) return end
    if itemPath and itemPath ~= "" then M.learn(itemPath, classPath) end
    -- A summoned module registers before it has a save id, gets address 0 and
    -- never joins the power grid: cables to the peer's modules never plugged
    -- in (no power on land, 2026-11-16). The runtime spawn gives the id at once.
    local a = runtimeSpawn(classPath, loc, rot) or summon(classPath)
    if not a then log("bygge: modul %s kunde inte skapas", classPath) return end
    -- Summon puts it in front of the player, often inside the boat; with
    -- collision on it shoved the boat before it was moved.
    pcall(function() a:SetActorEnableCollision(false) end)
    place(a, loc, rot, m, 13)
    local placed = pathOf(a)
    local okB, onBoat = pcall(fastenOnBoat, a)
    if not okB then log("bygge: fästa på båten: %s", tostring(onBoat)) end
    log("bygge: %s på båten: %s", placed, tostring(okB and onBoat))
    if okB and onBoat then placed = nil end
    if placed then ExecuteInGameThreadWithDelay(500, function()
        local m2 = StaticFindObject(placed)
        if m2 and m2:IsValid() then pcall(function() m2:SetActorEnableCollision(true) end) end
    end) end
    -- The save id is set a moment after spawning; pair it once it is there.
    local path = pathOf(a)
    local tries = 0
    local function pair()
        tries = tries + 1
        local m = StaticFindObject(path)
        if not (m and m:IsValid()) then return end
        local id = idOf(m)
        if id then
            props.alias(peerModuleId, id, persistOf(m))
            local v = m:K2_GetActorLocation()
            log("bygge: modul %s byggd här som %s (id %s = deras %s) vid %.0f %.0f %.0f, skulle vara %.0f %.0f %.0f",
                classPath, path, id, peerModuleId, v.X, v.Y, v.Z, loc.X, loc.Y, loc.Z)
        elseif tries < 20 then
            ExecuteInGameThreadWithDelay(1000, pair)
        else
            log("bygge: modul %s fick inget id", path)
        end
    end
    ExecuteInGameThreadWithDelay(500, pair)
end

-- Own blueprints --------------------------------------------------------------

-- What each blueprint turned into, from a pre-hook on its AttachSpawnedActor
-- (Child = the new module). Guessing by "a new actor with a save id near the
-- blueprint" matched a door when the module had no save id yet, and taught
-- byggklasser.txt wrong classes.
local SPAWN_HOOK = "/Game/Blueprints/Fabrication/BP_Location_Fabricator.BP_Location_Fabricator_C:AttachSpawnedActor"
local spawnedBy = {}        -- blueprint path -> module path
local waitingId = {}        -- blueprint path -> { f, since }: module known, save id not yet set
local WAIT_ID_SECONDS = 20
local hooked = false

function M.arm()
    if hooked then return end
    local ok, err = pcall(RegisterHook, SPAWN_HOOK, function(ctx, child)
        pcall(function()
            local fab, c = ctx:get(), child:get()
            if fab and fab:IsValid() and c and c:IsValid() then spawnedBy[pathOf(fab)] = pathOf(c) end
        end)
    end)
    hooked = ok
    if not M.armLogged or ok then
        M.armLogged = true
        log("bygge: krok på AttachSpawnedActor %s", ok and "ok" or tostring(err))
    end
end

local function sendBuilt(f, a, id)
    local cls = pathOf(a:GetClass())
    local v, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    if f.item then M.learn(f.item, cls) end
    props.markOwn(id)
    net.send("built", f.key, cls, string.format("%.1f", v.X), string.format("%.1f", v.Y), string.format("%.1f", v.Z),
        string.format("%.2f", RotP(r) or 0), string.format("%.2f", r.Yaw or 0), string.format("%.2f", r.Roll or 0),
        props.wire(id), f.item or "", mountOf(a))
    log("bygge: min blueprint %s byggd till %s (id %s)", f.key, cls, id)
end

-- A portable module (petrol generator, 2026-11-20) is not attached to
-- anything, so AttachSpawnedActor never runs for it. Then the module is a new
-- actor with a module component where the blueprint stood, one that was not
-- there when the blueprint was placed; never a character.
local MODULE_COMPONENT = "/Script/Voyage.VoyageModuleComponent"
local function guessModule(f)
    local modCls = StaticFindObject(MODULE_COMPONENT)
    local best, bestD
    for p, a in pairs(actorsNear(f.loc)) do
        if not f.near[p] and not notModule(pathOf(a:GetClass())) then
            local c = a:GetComponentByClass(modCls)
            if c and c:IsValid() then
                local d = dist(a:K2_GetActorLocation(), f.loc)
                if not bestD or d < bestD then best, bestD = a, d end
            end
        end
    end
    return best
end

local function vanished(path, f)
    if not spawnedBy[path] and not f.guessed then
        local okG, g = pcall(guessModule, f)
        if okG and g then
            f.guessed = true
            spawnedBy[path] = pathOf(g)
            log("bygge: ingen krokträff för %s, ny modul där den stod: %s", f.key, pathOf(g))
        end
    end
    local spawned = spawnedBy[path]
    if spawned then
        local a = StaticFindObject(spawned)
        if a and a:IsValid() then
            local id = idOf(a)
            if id then
                spawnedBy[path] = nil
                return sendBuilt(f, a, id)
            end
            waitingId[path] = waitingId[path] or { f = f, since = now() }
            return
        end
        spawnedBy[path] = nil
    end
    -- No module from the hook: the blueprint was removed. Guessing "a new
    -- actor with a save id where it stood" took the player standing there,
    -- and the other game summoned a second player character (2026-11-15).
    net.send("bpgone", f.key)
    log("bygge: min blueprint %s borttagen", f.key)
end

-- A blueprint without a save id yet is described again only after a while.
local DESCRIBE_AGAIN = 5
local describeTried = {}   -- path -> time

local function poll()
    local seen = {}
    for _, fab in ipairs(listOf(FAB)) do
        local path = pathOf(fab)
        seen[path] = true
        if not fabs[path] and now() - (describeTried[path] or -100) >= DESCRIBE_AGAIN then
            describeTried[path] = now()
            local ok, f = pcall(describe, fab)
            if not ok and not M.reported then
                M.reported = true
                log("bygge-fel (beskriv %s): %s", path, tostring(f))
            end
            if ok and f.key ~= "" then
                fabs[path] = f
                if not M.firstDone then
                    -- Blueprints that came with the save exist in both games.
                    f.fromSave = true
                elseif not f.item then
                    log("bygge: ny blueprint %s utan föremål", path)
                else
                    local rawId = idOf(fab)
                    if rawId then props.markOwn(rawId) f.key = props.wire(rawId) end
                    net.send("bp", f.key, f.item, string.format("%.1f", f.loc.X), string.format("%.1f", f.loc.Y),
                        string.format("%.1f", f.loc.Z), string.format("%.2f", f.rot.Yaw), table.unpack(f.mount))
                    log("bygge: ny blueprint %s (%s, id %s)", path, f.item, f.key)
                end
            end
        end
    end
    M.firstDone = true
    for path, w in pairs(waitingId) do
        local a = spawnedBy[path] and StaticFindObject(spawnedBy[path])
        local id = a and a:IsValid() and idOf(a)
        if id then
            waitingId[path], spawnedBy[path] = nil, nil
            local ok, err = pcall(sendBuilt, w.f, a, id)
            if not ok then log("bygge-fel: %s", tostring(err)) end
        elseif not (a and a:IsValid()) or now() - w.since > WAIT_ID_SECONDS then
            waitingId[path], spawnedBy[path] = nil, nil
            log("bygge: modulen från %s fick inget spar-id, gissar", w.f.key)
            local ok, err = pcall(vanished, path, w.f)
            if not ok then log("bygge-fel: %s", tostring(err)) end
        end
    end
    for path in pairs(describeTried) do
        if not seen[path] then describeTried[path] = nil end
    end
    for path, f in pairs(fabs) do
        if not seen[path] then
            fabs[path] = nil
            local ok, err = pcall(vanished, path, f)
            if not ok then log("bygge-fel: %s", tostring(err)) end
        end
    end
end

-- Item -> module class pairs learnt from finished builds are kept in a file,
-- so a blueprint of a module built once before shows a ghost from then on.
local CLASS_FILE = "ue4ss/Mods/CoopSync/byggklasser.txt"

-- What a blueprint can never turn into; such a pair is ignored wherever it
-- comes from (old byggklasser.txt lines, the other game's message).
function notModule(classPath)
    return classPath:find("Character", 1, true) or classPath:find("Spawner", 1, true) or classPath:find("/AI/", 1, true)
end
M.notModule = notModule

function M.learn(itemPath, classPath)
    if notModule(classPath) then return end
    if classOf[itemPath] == classPath then return end
    classOf[itemPath] = classPath
    local f = io.open(CLASS_FILE, "a")
    if f then f:write(itemPath, "|", classPath, "\n") f:close() end
end

function M.init(netModule, logFn, nowFn, propsModule, consoleFn, localPCFn)
    net, log, now, props, console, localPC = netModule, logFn, nowFn, propsModule, consoleFn, localPCFn
    local f = io.open(CLASS_FILE, "r")
    if f then
        for line in f:lines() do
            local item, cls = line:match("^([^|]+)|(.+)$")
            if item and not notModule(cls) then classOf[item] = cls end
        end
        f:close()
    end
end

-- Runs in the world once it has settled.
-- Materials ------------------------------------------------------------------
-- The game builds a blueprint by itself once the placer's inventory holds what
-- it needs. What the placer lacks is asked of the other player, who gives it if
-- they stand near the blueprint (their ghost of it): parts first, raw materials
-- in a later round if they have none of the parts. The given items go into the
-- placer's inventory, where the game picks them up.
local NEED_SECONDS = 2
local GIVE_RANGE = 1500     -- cm from the blueprint
local PLAYER_INVENTORY = 1  -- EVoyageInventoryType::PlayerInventory
local quietUntil = {}       -- key -> time; a give is on its way, do not ask again yet
local lastNeed = 0
-- When both players had a blueprint needing the same parts, each gave its
-- parts to the other's and asked them back, every few seconds, for ever
-- (2026-11-15). The host gives nothing while it is asking for its own; the
-- guest still gives, so the host's blueprint is finished first.
local lastAsk = -100
local ASKING_SECONDS = NEED_SECONDS * 3

-- A requirement map as a list of { item, count } (UE4SS hands it over as a
-- Lua table of wrapped keys and values).
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

local function encodeItems(list)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = pathOf(e.item) .. "=" .. e.n end
    return table.concat(parts, ";")
end

local function decodeItems(s)
    local list = {}
    for path, n in (s or ""):gmatch("([^=;]+)=(%d+)") do list[#list + 1] = { path = path, n = tonumber(n) } end
    return list
end

local function missingFor(fab)
    local r = {}
    fab.VoyageFabricator:CalculateFabricationRequirements(fab.FabricationItemOrPattern, r, 1)
    local res = r.Result or r
    -- LocalItems lagged behind what had just been given, so the same items
    -- were asked for again and again; the player's own count is used too.
    local have = {}
    for _, e in ipairs(entries(res.LocalItems)) do have[pathOf(e.item)] = e.n end
    local inv = M.playerInventory()
    local function haveOf(item)
        local own = 0
        if inv then pcall(function() own = inv:GetNumItems(item) end) end
        return math.max(have[pathOf(item)] or 0, own)
    end
    local function short(m)
        local out = {}
        for _, e in ipairs(entries(m)) do
            local lack = e.n - haveOf(e.item)
            if lack > 0 then out[#out + 1] = { item = e.item, n = lack } end
        end
        return out
    end
    return short(res.ItemsRequired), short(res.MaterialsRequired)
end

local function askForMaterials()
    if now() - lastNeed < NEED_SECONDS then return end
    lastNeed = now()
    for path, f in pairs(fabs) do
        -- A blueprint from the save is in both games: only the host asks, or
        -- each would ask the other for the same materials.
        if (quietUntil[f.key] or 0) <= now() and not f.copy and (props.isHost or not f.fromSave) then
            local fab = StaticFindObject(path)
            -- The other player gives only from within GIVE_RANGE, and the
            -- requirement query has an out parameter that UE4SS never frees
            -- (see boat.moveActor): asked only while they are that close.
            local okN, near = pcall(function()
                local p = M.peerLocation and M.peerLocation()
                return p and dist(p, fab:K2_GetActorLocation()) <= GIVE_RANGE
            end)
            if fab and fab:IsValid() and okN and near then
                local ok, parts, raw = pcall(missingFor, fab)
                if ok and (#parts > 0 or #raw > 0) then
                    lastAsk = now()
                    net.send("needmat", f.key, encodeItems(parts), encodeItems(raw))
                elseif not ok and not M.needReported then
                    M.needReported = true
                    log("bygge-fel (behov): %s", tostring(parts))
                end
            end
        end
    end
end

function M.playerInventory()
    local okP, inv = pcall(function() return localPC():GetInventoryComponent(PLAYER_INVENTORY) end)
    if okP and inv and inv:IsValid() then return inv end
end
local playerInventory = M.playerInventory

local function giveMaterials(key, partsText, rawText)
    if (quietUntil[key] or 0) > now() then return end
    local function skip(why)
        M.skipLogged = M.skipLogged or {}
        if M.skipLogged[key] ~= why then
            M.skipLogged[key] = why
            log("bygge: ger inget till %s: %s", key, why)
        end
    end
    -- The peer's blueprint is shown here as a ghost, or, when it came with the
    -- save, this game has the blueprint itself.
    local ghost = ghosts[key] and StaticFindObject(ghosts[key])
    if not (ghost and ghost:IsValid()) then
        ghost = nil
        for path, f in pairs(fabs or {}) do
            if f.key == key and (f.fromSave or f.copy) then ghost = StaticFindObject(path) end
        end
    end
    if not (ghost and ghost:IsValid()) then return skip("inget spöke eller egen kopia här") end
    if props.isHost and now() - lastAsk < ASKING_SECONDS then return skip("saknar själv material till en egen ritning") end
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return skip("ingen spelare") end
    local d = dist(pawn:K2_GetActorLocation(), ghost:K2_GetActorLocation())
    if d > GIVE_RANGE then return skip(string.format("för långt bort (%.0f cm)", d)) end
    local inv = playerInventory()
    if not inv then return skip("hittar inte inventariet") end
    local function take(list)
        local given = {}
        for _, e in ipairs(list) do
            local item = StaticFindObject(e.path)
            local has = item and item:IsValid() and inv:GetNumItems(item) or 0
            local n = math.min(has, e.n)
            if n > 0 then
                local ok, removed = pcall(function() return inv:RemoveItem(item, n, -1, true) end)
                if ok and removed and removed > 0 then given[#given + 1] = { item = item, n = removed } end
            end
        end
        return given
    end
    local given = take(decodeItems(partsText))
    if #given == 0 then given = take(decodeItems(rawText)) end
    if #given == 0 then return skip("har inget av det som behövs") end
    quietUntil[key] = now() + 4
    net.send("givemat", key, encodeItems(given))
    log("bygge: gav %s till den andras blueprint %s", encodeItems(given), key)
end

local function receiveMaterials(key, text)
    local inv = playerInventory()
    if not inv then log("bygge: hittar inte mitt inventarie för givet material") return end
    quietUntil[key] = now() + 4
    for _, e in ipairs(decodeItems(text)) do
        local item = StaticFindObject(e.path)
        if item and item:IsValid() then
            local ok, err = pcall(function() inv:AddItems({ [item] = e.n }, true, true, 0) end)
            if not ok then log("bygge: kunde inte ta emot %s: %s", e.path, tostring(err)) end
        end
    end
    log("bygge: fick %s till blueprint %s", text, key)
end

function M.tick()
    local okL, errL = pcall(sendLooks)
    if not okL and not M.lookReported then M.lookReported = true log("bygge-fel (färg): %s", tostring(errL)) end
    if now() - lastPoll < POLL_SECONDS then return end
    lastPoll = now()
    fabs = fabs or {}
    poll()
    askForMaterials()
end

function M.reset()
    fabs, ghosts, M.firstDone = nil, {}, false
    sentLook = {}
    spawnedBy, waitingId = {}, {}
end

local function num(s) return tonumber(s) or 0 end

function M.handle(msg)
    local kind = msg[1]
    if kind == "bp" then
        local ok, err = pcall(showGhost, msg[3], msg[4], { X = num(msg[5]), Y = num(msg[6]), Z = num(msg[7]) },
            Rot(0, num(msg[8]), 0), msg)
        if not ok then log("bygge-fel (spöke): %s", tostring(err)) end
        return true
    elseif kind == "bplook" then
        local ok, err = pcall(applyLook, msg[3], num(msg[4]), num(msg[5]), num(msg[6]), num(msg[7]))
        if not ok then log("bygge-fel (färg): %s", tostring(err)) end
        return true
    elseif kind == "bpgone" then
        local ok, err = pcall(removeRemote, msg[3], "borttagen hos den andra")
        if not ok then log("bygge-fel: %s", tostring(err)) end
        return true
    elseif kind == "needmat" then
        local ok, err = pcall(giveMaterials, msg[3], msg[4], msg[5])
        if not ok then log("bygge-fel (ge): %s", tostring(err)) end
        return true
    elseif kind == "givemat" then
        local ok, err = pcall(receiveMaterials, msg[3], msg[4])
        if not ok then log("bygge-fel (ta emot): %s", tostring(err)) end
        return true
    elseif kind == "built" then
        local ok, err = pcall(buildRemote, msg[3], msg[4], { X = num(msg[5]), Y = num(msg[6]), Z = num(msg[7]) },
            Rot(num(msg[8]), num(msg[9]), num(msg[10])), msg[11], msg[12], msg)
        if not ok then log("bygge-fel (modul): %s", tostring(err)) end
        return true
    end
    return false
end

return M
