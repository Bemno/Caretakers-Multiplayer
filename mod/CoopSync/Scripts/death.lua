-- Death in multiplayer: nothing is reloaded. The death screen's own buttons
-- (continue from last save, load game) are swapped for "respawn on the boat"
-- and "respawn at your friend", and the dead character is brought back.
--
-- Dying turns the character into a ragdoll: the mesh simulates physics and the
-- capsule gets NoCollision with every channel ignored. Restoring only the
-- profile name leaves the channels ignored and the character falls through
-- floors, so the capsule's per-channel responses are captured while alive.
-- SurvivalComponent:Reset() destroys the pawn and crashes the game; the
-- attributes are set one by one instead.
local M = {}
local T = require("text")

local SURV = "/Script/Voyage.VoyageSurvivalComponent"
local BTN_CLASS = "/Game/UI/Focusable/BP_FocusableButton.BP_FocusableButton_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local VISIBLE, COLLAPSED = 0, 1
local A = { Oxygen = 4, Radiation = 5, Fever = 6, Hypothermia = 7, Health = 8, Stamina = 9, Nutrition = 2, Hydration = 3 }
local ELECTRICITY = 0
local RESPAWN_SHARE = 0.10

local log, localPC, puppetFn
local alive              -- captured body state of the living pawn
local aliveFor           -- address of the pawn it belongs to
local startPos           -- where the player stood when the world loaded
local dead = false
local buttons = {}       -- address -> action
local hoverWas
local pending
local hudAddr            -- the death screen we changed
local builtWithFriend

local function pawn()
    local p = localPC().Pawn
    if p and p:IsValid() then return p end
end

local function survival(p)
    local s = p:GetComponentByClass(StaticFindObject(SURV))
    if s and s:IsValid() then return s end
end

local function vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end

local function capture(p)
    local cap, mesh = p.CapsuleComponent, p.Mesh
    local s = {
        capEnabled = cap:GetCollisionEnabled(),
        capProfile = cap:GetCollisionProfileName():ToString(),
        capResp = {},
        meshProfile = mesh:GetCollisionProfileName():ToString(),
        meshLoc = vec(mesh.RelativeLocation),
    }
    local r = mesh.RelativeRotation
    s.meshRot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
    for ch = 0, 31 do s.capResp[ch] = cap:GetCollisionResponseToChannel(ch) end
    pcall(function()
        local cyl = p.CollisionCylinderPhysical
        local c = { enabled = cyl:GetCollisionEnabled(), profile = cyl:GetCollisionProfileName():ToString(), resp = {} }
        for ch = 0, 31 do c.resp[ch] = cyl:GetCollisionResponseToChannel(ch) end
        s.cyl = c
    end)
    pcall(function() s.postEnabled = p.PlayerPostProcess.bEnabled end)
    return s
end

local function boat()
    local ok, locs = pcall(FindObjects, 0, "VoyageLocatorComponent", "", 0, 0x10, false)
    for _, l in ipairs((ok and locs) or {}) do
        local okO, o = pcall(function()
            if l.properties.Name:ToString() ~= "Mainboat" then return nil end
            local o = l:GetOwner()
            if not (o and o:IsValid()) then return nil end
            -- The level also holds an empty placeholder barge at the world
            -- origin; reviving "on the boat" put the guest there (2026-11-15).
            local v = o:K2_GetActorLocation()
            if math.abs(v.X) < 100 and math.abs(v.Y) < 100 then return nil end
            return o
        end)
        if okO and o then return o end
    end
end

local function friend()
    local d = puppetFn()
    if d and d:IsValid() then return d end
end

local function step(label, fn)
    local ok, err = pcall(fn)
    if not ok then log("död: %s misslyckades: %s", label, tostring(err)) end
end

local function setAttr(s, t, fn)
    local o = {}
    if not (s:HasAttribute(t) and s:GetAttributeMaxValue(t, o)) then return end
    local mx = o.OutValue
    local mn = (function() local m = {} s:GetAttributeMinValue(t, m) return m.OutValue end)()
    local cur = (function() local c = {} s:GetAttributeValue(t, c) return c.OutValue end)()
    local v = fn(cur, mn, mx)
    if v then s:SetAttributeValue(t, v, true) end
end

local function revive(p)
    local s = survival(p)
    if s then
        step("bIsDead", function() s.bIsDead = false end)
        step("värden", function()
            local full = function(_, _, mx) return mx end
            local none = function(_, mn) return mn end
            setAttr(s, A.Health, function(_, mn, mx) return mn + (mx - mn) * RESPAWN_SHARE end)
            setAttr(s, A.Oxygen, full)
            setAttr(s, A.Stamina, full)
            setAttr(s, A.Radiation, none)
            setAttr(s, A.Fever, none)
            setAttr(s, A.Hypothermia, none)
            local atLeast = function(cur, mn, mx) local f = mn + (mx - mn) * 0.25 if cur < f then return f end end
            setAttr(s, A.Nutrition, atLeast)
            setAttr(s, A.Hydration, atLeast)
        end)
    end
    step("batteri", function()
        local pm = p.PlayerModuleComponent
        local want = pm:GetMaxResourceAmount(ELECTRICITY) * RESPAWN_SHARE
        local cur = pm:GetResourceAmount(ELECTRICITY)
        if cur < want and pm:AddResource(ELECTRICITY, want - cur) <= 0 then
            pm:ForceAddResource(ELECTRICITY, want - cur)
        end
        log("död: batteri %.0f -> %.0f, modulläge %s", cur, pm:GetResourceAmount(ELECTRICITY), tostring(pm.ModuleState))
    end)
    -- Death adds warnings (red pulsing screen edge) that the revive leaves;
    -- the game adds them again if they still apply.
    step("varningar", function()
        for w = 1, 5 do
            if p:HasCharacterWarning(w) then p:RemoveCharacterWarning(w) end
        end
    end)
    -- The game's own undo: death runs SetRagdoll(true), which also changes the
    -- second collision cylinder ladders use, and plays the Audio_Death_Filter
    -- timeline, a low-pass that leaves footsteps, monsters and tools silent.
    step("ragdoll", function() p:SetRagdoll(false) end)
    step("vid liv", function() p:OnAliveChangedDelegate_Event(p, true) end)
    step("ljudfilter", function()
        p.Audio_Death_Filter:Stop()
        p.Audio_Death_Filter:SetPlaybackPosition(0, true, true)
        p.Audio_DeathFilter_Type:SetFilterCutoffFrequency(20000)
    end)
    local b = alive
    if not b then log("död: inget sparat kroppsläge") return end
    local cap, mesh = p.CapsuleComponent, p.Mesh
    step("fysik", function() mesh:SetSimulatePhysics(false) end)
    step("fäst", function() mesh:K2_AttachToComponent(p.MeshSmoother, FName("None"), 0, 0, 0, true) end)
    step("meshplats", function() mesh:K2_SetRelativeLocationAndRotation(b.meshLoc, b.meshRot, false, {}, false) end)
    step("meshprofil", function() mesh:SetCollisionProfileName(FName(b.meshProfile), true) end)
    step("kapselprofil", function() cap:SetCollisionProfileName(FName(b.capProfile), true) end)
    step("kapsel", function() cap:SetCollisionEnabled(b.capEnabled) end)
    step("kapselsvar", function() for ch = 0, 31 do cap:SetCollisionResponseToChannel(ch, b.capResp[ch]) end end)
    -- Ladders use the second cylinder; after a death it stayed as the ragdoll
    -- left it and ladders no longer worked.
    if b.cyl then
        local cyl = p.CollisionCylinderPhysical
        step("cylinderprofil", function() cyl:SetCollisionProfileName(FName(b.cyl.profile), true) end)
        step("cylinder", function() cyl:SetCollisionEnabled(b.cyl.enabled) end)
        step("cylindersvar", function() for ch = 0, 31 do cyl:SetCollisionResponseToChannel(ch, b.cyl.resp[ch]) end end)
    end
    -- Death turns on the damage glitch post process (the red around the
    -- screen); a living player has it off.
    if b.postEnabled ~= nil then step("efterbehandling", function() p.PlayerPostProcess.bEnabled = b.postEnabled end) end
    -- Death turns off the character's own tick, where ladder climbing runs.
    step("tick", function() p:SetActorTickEnabled(true) end)
    step("rörelse", function() p.CharacterMovement:Activate(false) p.CharacterMovement:SetMovementMode(1, 0) end)
    local pc = localPC()
    step("kamera", function()
        local r = pc:GetControlRotation()
        pc:SetControlRotation({ Pitch = 0, Yaw = r.Yaw, Roll = 0 })
    end)
    step("mus", function() pc.bShowMouseCursor = false end)
    step("styrning", function() StaticFindObject(WBL):SetInputMode_GameOnly(pc, false) end)
end

-- The death screen of this death: the one we already changed, or one whose
-- own buttons are showing (an earlier death's screen may still exist).
local function deathHud()
    local ok, ws = pcall(FindAllOf, "BP_VoyageDeathHud_C")
    for _, w in ipairs((ok and ws) or {}) do
        if w:IsValid() and not w:GetFullName():find("Default__") then
            if hudAddr then
                if w:GetAddress() == hudAddr then return w end
            else
                local okL, v = pcall(function() return w.LoadGame:IsVisible() end)
                if okL and v then return w end
            end
        end
    end
end

local function respawn(where)
    local p = pawn()
    if not p then return end
    local dest
    if where == "boat" then
        local b = boat()
        if b then
            local v = b:K2_GetActorLocation()
            dest = { X = v.X, Y = v.Y, Z = v.Z + 400 }
        else
            dest = startPos
        end
    elseif where == "friend" then
        local d = friend()
        if d then
            local v = d:K2_GetActorLocation()
            dest = { X = v.X + 80, Y = v.Y, Z = v.Z + 120 }
        end
    end
    local hud = deathHud()
    if hud then step("hud", function() hud:RequestOverlayRemoval() end) end
    revive(p)
    if dest then
        step("flytt", function() p:K2_TeleportTo(dest, { Pitch = 0, Yaw = p:K2_GetActorRotation().Yaw, Roll = 0 }) end)
    end
    dead, buttons, hoverWas, hudAddr = false, {}, nil, nil
    log("död: återuppstod (%s) vid %s", where,
        dest and string.format("%.0f %.0f %.0f", dest.X, dest.Y, dest.Z) or "samma plats")
end

local function copyLook(from, to) require("menu").copyLook(from, to) end

local function copySlot(from, slot)
    if not (slot and slot:IsValid()) then return end
    local src = from.Slot
    pcall(function() slot:SetPadding(src.Padding) end)
    pcall(function() slot:SetHorizontalAlignment(src.HorizontalAlignment) end)
    pcall(function() slot:SetVerticalAlignment(src.VerticalAlignment) end)
    pcall(function() slot:SetSize(src.Size) end)
end

local function addButtons(hud)
    local panel = hud.LoadGame:GetParent()
    hud.LoadGame:SetVisibility(COLLAPSED)
    pcall(function() hud.ContinueFromLast:SetVisibility(COLLAPSED) end)
    local cls, wbl, pc = StaticFindObject(BTN_CLASS), StaticFindObject(WBL), localPC()
    local list = { { boat() and T("respawn_boat") or T("respawn_start"), "boat" } }
    builtWithFriend = friend() ~= nil
    if builtWithFriend then list[#list + 1] = { T("respawn_friend"), "friend" } end
    for _, x in ipairs(list) do
        local btn = wbl:Create(hud, cls, pc)
        if btn and btn:IsValid() then
            copyLook(hud.LoadGame, btn)
            copySlot(hud.LoadGame, panel:AddChild(btn))
            btn:SetText(FText(x[1]), 0)
            btn:SetVisibility(VISIBLE)
            buttons[btn:GetAddress()] = x[2]
        end
    end
    hudAddr = hud:GetAddress()
    log("död: dödsskärmens knappar utbytta (%d val)", #list)
end

local function pollHover(hud)
    local hovered
    local okC, arr = pcall(function() return hud.LoadGame:GetParent():GetAllChildren() end)
    for _, c in ipairs((okC and arr) or {}) do
        local okW, w = pcall(function() return c:get() end)
        w = okW and w or c
        if w and w:IsValid() and buttons[w:GetAddress()] and w:IsHovered() then hovered = w:GetAddress() end
    end
    hoverWas = hovered
end

-- coopnet reports the left mouse button straight from Windows; the game
-- swallows clicks on added buttons.
function M.mouse(msg)
    if dead and msg[3] == "1" and hoverWas and buttons[hoverWas] then pending = buttons[hoverWas] end
end

-- Test bench: pick an option as if its button had been clicked.
function M.choose(where) if dead then pending = where end end

function M.init(logFn, localPCFn, puppetFnArg)
    log, localPC, puppetFn = logFn, localPCFn, puppetFnArg
end

function M.reset()
    alive, aliveFor, startPos, dead, buttons, hoverWas, pending, hudAddr = nil, nil, nil, false, {}, nil, nil, nil
end

-- Runs while in the world.
function M.tick()
    local p = pawn()
    if not p then return end
    local s = survival(p)
    if not s then return end
    if not s:IsDead() then
        if dead then dead, buttons, hudAddr = false, {}, nil end
        local a = p:GetAddress()
        if aliveFor ~= a then
            alive, aliveFor = capture(p), a
            startPos = startPos or vec(p:K2_GetActorLocation())
        end
        return
    end
    if not dead then
        dead, buttons, pending, hudAddr = true, {}, nil, nil
        log("död: spelaren dog")
    end
    if pending then
        local where = pending
        pending = nil
        respawn(where)
        return
    end
    local hud = deathHud()
    if not hud then return end
    -- The friend may show up (or leave) while the death screen is open.
    if next(buttons) ~= nil and (friend() ~= nil) ~= builtWithFriend then
        local okC, arr = pcall(function() return hud.LoadGame:GetParent():GetAllChildren() end)
        for _, c in ipairs((okC and arr) or {}) do
            local okW, w = pcall(function() return c:get() end)
            w = okW and w or c
            if w and w:IsValid() and buttons[w:GetAddress()] then w:RemoveFromParent() end
        end
        buttons = {}
    end
    if next(buttons) == nil then addButtons(hud) end
    pollHover(hud)
end

return M
