-- Guest arrival: the world is visible well before the character has spawned
-- and the sync is running. Until then the guest looks at the boat from a
-- camera above the deck, with movement and look locked and the game's own
-- loading throbber on screen, and is then handed back to the character.
local M = {}

local SCREEN_CLASS = "/Game/UI/BP_LoadingScreen.BP_LoadingScreen_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local KML = "/Script/Engine.Default__KismetMathLibrary"
local COLLAPSED = 1
-- Camera: orbits a point above the boat's middle, steered with the mouse
-- like the boat's outside view; it starts at the bow looking back and down.
local CAM_DIST, AIM_UP = 2400, 150
local START_PITCH, MIN_PITCH, MAX_PITCH = -23, -70, -5

local log, localPC, console
local active, done, aimed = false, false, false
local lastAngleLog = 0
local camYaw, camPitch, lastYaw, lastPitch = 0, 0, 0, 0
local boatPath, lastSearch = nil, -100
local camPath, camPending, camSummonAt, camsBefore = nil, false, -100, nil
local screenPath
local cleanupAt

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end

local function lookup(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function findBoat(now)
    local b = lookup(boatPath)
    if b then return b end
    boatPath = nil
    if now - lastSearch < 1 then return nil end
    lastSearch = now
    local ok, locs = pcall(FindObjects, 0, "VoyageLocatorComponent", "", 0, 0x10, false)
    for _, l in ipairs((ok and locs) or {}) do
        local okO, o = pcall(function()
            if l.properties.Name:ToString() ~= "Mainboat" then return nil end
            local o = l:GetOwner()
            return (o and o:IsValid()) and o or nil
        end)
        if okO and o then boatPath = pathOf(o) return o end
    end
end

local function cameraActors()
    local set = {}
    local ok, found = pcall(FindObjects, 0, "CameraActor", "", 0, 0, true)
    for _, a in ipairs((ok and found) or {}) do
        pcall(function() if a:IsValid() then set[pathOf(a)] = true end end)
    end
    return set
end

-- A summoned CameraActor; the new one is whichever was not there before.
local function camera(now)
    local c = lookup(camPath)
    if c then return c end
    camPath = nil
    if camPending then
        for path in pairs(cameraActors()) do
            if not camsBefore[path] and not path:find("Default__") then
                camPath, camPending = path, false
                c = lookup(path)
                pcall(function() c.CameraComponent.bConstrainAspectRatio = false end)
                log("laddvy: kamera %s", path)
                return c
            end
        end
    end
    if not camPending or now - camSummonAt > 5 then
        camsBefore, camPending, camSummonAt = cameraActors(), true, now
        console("summon CameraActor")
    end
end

local function placeCamera(c, b)
    local o, e = {}, {}
    b:GetActorBounds(true, o, e, false)
    local centre = (o.X and o) or o.Origin
    local pc = localPC()
    local cr = pc.ControlRotation
    local cp = (cr.Pitch or 0) > 180 and cr.Pitch - 360 or (cr.Pitch or 0)
    if not aimed then
        aimed = true
        camYaw, camPitch = b:K2_GetActorRotation().Yaw + 180, START_PITCH
        pc:SetControlRotation({ Pitch = cp, Yaw = camYaw, Roll = 0 })
    else
        -- The control rotation's pitch is held by the game here, so mouse
        -- movement is taken as change from the last tick.
        local dy = (cr.Yaw or camYaw) - lastYaw
        if dy > 180 then dy = dy - 360 elseif dy < -180 then dy = dy + 360 end
        camYaw = camYaw + dy
        camPitch = math.max(MIN_PITCH, math.min(MAX_PITCH, camPitch + (cp - lastPitch)))
    end
    lastYaw, lastPitch = cr.Yaw or camYaw, cp
    local rot = { Pitch = camPitch, Yaw = camYaw, Roll = 0 }
    local pr, yr = math.rad(camPitch), math.rad(camYaw)
    local fw = { X = math.cos(pr) * math.cos(yr), Y = math.cos(pr) * math.sin(yr), Z = math.sin(pr) }
    local aim = { X = centre.X, Y = centre.Y, Z = centre.Z + AIM_UP }
    local loc = { X = aim.X - fw.X * CAM_DIST, Y = aim.Y - fw.Y * CAM_DIST, Z = aim.Z - fw.Z * CAM_DIST }
    -- A rotator built in Lua lost its pitch here; the engine's own look-at
    -- rotator keeps it.
    c:K2_SetActorLocationAndRotation(loc, StaticFindObject(KML):FindLookAtRotation(loc, aim), false, {}, true)
    if os.time() - lastAngleLog >= 3 then
        lastAngleLog = os.time()
        log("laddvy: kontroll %.1f/%.1f -> kamera %.1f/%.1f, z %.0f (mitt %.0f)", cp, cr.Yaw or -999, camPitch, camYaw, loc.Z, centre.Z)
    end
end

local function showScreen()
    if lookup(screenPath) then return end
    local pc = localPC()
    local w = StaticFindObject(WBL):Create(pc, StaticFindObject(SCREEN_CLASS), pc)
    if not (w and w:IsValid()) then return end
    w:AddToViewport(50)
    screenPath = pathOf(w)
    log("laddvy: laddsymbol visas")
end

-- Construct shows the menu background after creation, so it is hidden every
-- tick while the screen is up.
local function styleScreen()
    local w = lookup(screenPath)
    if w then w.BP_VoyageMenuBackground:SetVisibility(COLLAPSED) end
end

local function hold(now)
    local pc = localPC()
    if not (pc and pc:IsValid()) then return end
    if not active then
        active = true
        pc:SetIgnoreMoveInput(true)
        log("laddvy: på")
    end
    local okS, errS = pcall(showScreen)
    if not okS then log("laddvy: laddsymbol: %s", tostring(errS)) end
    pcall(styleScreen)
    local b = findBoat(now)
    if not b then return end
    local c = camera(now)
    if not c then return end
    placeCamera(c, b)
    -- The game sets the view to the character when it spawns, so keep at it.
    local vt = pc:GetViewTarget()
    if not (vt and vt:IsValid() and vt:GetAddress() == c:GetAddress()) then
        pc:SetViewTargetWithBlend(c, 0, 0, 0, false)
    end
end

local function release(now)
    if not active then return end
    active = false
    local pc = localPC()
    if pc and pc:IsValid() then
        pc:ResetIgnoreMoveInput()
        local p = pc.Pawn
        if p and p:IsValid() then pc:SetViewTargetWithBlend(p, 0.8, 0, 0, false) end
    end
    local w = lookup(screenPath)
    if w then pcall(function() w:RemoveFromParent() end) end
    screenPath = nil
    cleanupAt = now + 2
    log("laddvy: av")
end

function M.init(logFn, localPCFn, consoleFn) log, localPC, console = logFn, localPCFn, consoleFn end

-- Called every tick while the guest is in the world; once ready it lets go
-- and stays out until the next world.
function M.tick(now, ready)
    if cleanupAt and now >= cleanupAt then
        cleanupAt = nil
        local c = lookup(camPath)
        if c then pcall(function() c:K2_DestroyActor() end) end
        camPath = nil
    end
    if done then return end
    if ready then release(now) done = true return end
    hold(now)
end

function M.reset()
    local w = lookup(screenPath)
    if w then pcall(function() w:RemoveFromParent() end) end
    active, done, aimed, boatPath, lastSearch = false, false, false, nil, -100
    camPath, camPending, camSummonAt, camsBefore, screenPath, cleanupAt = nil, false, -100, nil, nil, nil
end

return M
