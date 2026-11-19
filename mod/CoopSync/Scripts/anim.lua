-- The other player's locomotion on the puppet. The puppet cannot run the
-- player's anim blueprint (ABP_Manny_New froze without a pawn owner,
-- 2026-11-18), so the sender reads that blueprint's variables off its own
-- character and the puppet plays the same blend spaces and sequences the
-- blueprint uses, with the same inputs (speed in the character's frame / 2).
local M = {}
local net, log

local DIR = "/Game/Characters/Mannequins/Animations/"
local ASSETS = {
    move = DIR .. "BS_Movement.BS_Movement",
    crouch = DIR .. "BS_Crouch.BS_Crouch",
    swim = DIR .. "BS_Swimming.BS_Swimming",
    dive = DIR .. "BS_Diving_Slow.BS_Diving_Slow",
    diveFast = DIR .. "BS_Diving.BS_Diving",
    sprint = "/Game/Animations/UTA/AnimSeq_Traversal_Movement_Sprint.AnimSeq_Traversal_Movement_Sprint",
    fall = DIR .. "Manny/MM_Fall_Loop.MM_Fall_Loop",
    ladderUp = "/Game/Animations/UTA/AnimSeq_Traversal_Ladder_Climb_Up_Loop.AnimSeq_Traversal_Ladder_Climb_Up_Loop",
    ladderDown = "/Game/Animations/UTA/AnimSeq_Traversal_Ladder_Slide_Down_Loop.AnimSeq_Traversal_Ladder_Slide_Down_Loop",
    aim = "/Game/Animations/Rifle/AS_Rifle_Aim.AS_Rifle_Aim",
    craft = "/Game/Animations/Crafting/AnimationSequence_Survival_Build_Crafting_GenericMovements_Loop.AnimationSequence_Survival_Build_Crafting_GenericMovements_Loop",
}
-- The blueprint lays the crafting arms over the body by CraftWeight; one
-- sequence at a time can only show them standing still.
local CRAFT_WEIGHT, CRAFT_STILL = 0.3, 30
local BLEND = { move = true, crouch = true, swim = true, dive = true, diveFast = true }
local LADDER_RATE_REF = 100

function M.init(netModule, logFn)
    net, log = netModule, logFn
end

-- Sending: at most 10 times a second, and only when something changed
-- (or once a second, so a lost message does not leave the puppet wrong).
local SEND_EVERY, KEEPALIVE, SPEED_STEP = 0.1, 1.0, 5
local lastSent, lastSentAt = nil, 0

local function flagsOf(ai)
    local f = ""
    if ai.Sprinting then f = f .. "S" end
    if ai.IsCrouching then f = f .. "C" end
    if ai.IsFalling then f = f .. "F" end
    if ai.IsSwimming then f = f .. "W" end
    if ai.IsDiving then f = f .. "D" end
    if ai.IsClimbingLadder then f = f .. "L" end
    if not ai.IsAlive then f = f .. "X" end
    if (ai.CraftWeight or 0) > CRAFT_WEIGHT then f = f .. "B" end
    -- A weapon in the hand (gear.lua sees it at the hand bone).
    local okG, gear = pcall(require, "gear")
    if okG and gear.weaponInHand then f = f .. "G" end
    return f == "" and "-" or f
end

-- Actions (crowbar and fist swings, scanner, mantling) are montages on the
-- player's anim instance. Sent once per start; a swing repeated before the
-- last one ended shows as the position jumping back.
local lastMontage, lastMontagePos = nil, 0

local function sendMontage(ai)
    local m = ai:GetCurrentActiveMontage()
    if not (m and m:IsValid()) then
        lastMontage = nil
        return
    end
    local name = m:GetFullName():match("%S+%s+(%S+)")
    local pos = ai:Montage_GetPosition(m)
    if name ~= lastMontage or pos < lastMontagePos - 0.05 then
        net.send("amon", name)
    end
    lastMontage, lastMontagePos = name, pos
end

function M.send(pawn, now)
    local okM, ai0 = pcall(function() return pawn.Mesh:GetAnimInstance() end)
    if okM and ai0 and ai0:IsValid() then
        local ok, err = pcall(sendMontage, ai0)
        if not ok then log("montage-sändfel: %s", tostring(err)) end
    end
    if now - lastSentAt < SEND_EVERY then return end
    local ai = pawn.Mesh:GetAnimInstance()
    if not (ai and ai:IsValid()) then return end
    local s = {
        fwd = ai.GroundSpeedForward or 0, right = ai.GroundSpeedRight or 0, up = ai.GroundSpeedUp or 0,
        flags = flagsOf(ai), ladder = ai.ClimbLadderSpeed or 0,
    }
    local p = lastSent
    local changed = not p or p.flags ~= s.flags or math.abs(p.fwd - s.fwd) > SPEED_STEP
        or math.abs(p.right - s.right) > SPEED_STEP or math.abs(p.up - s.up) > SPEED_STEP
        or math.abs(p.ladder - s.ladder) > SPEED_STEP
    if not changed and now - lastSentAt < KEEPALIVE then return end
    lastSent, lastSentAt = s, now
    net.send("anim", string.format("%.0f", s.fwd), string.format("%.0f", s.right), string.format("%.0f", s.up), s.flags,
        string.format("%.0f", s.ladder))
end

-- Receiving and playing.
local want         -- latest received state
local playing      -- asset key playing on the puppet
local blend = { x = 0, y = 0 }
local cache = {}
local lastLog = 0

local function asset(key)
    local a = cache[key]
    if a and a:IsValid() then return a end
    local path = ASSETS[key]
    a = StaticFindObject(path)
    if not (a and a:IsValid()) then
        local ok, loaded = pcall(LoadAsset, path)
        a = ok and loaded or nil
    end
    if a and a:IsValid() then cache[key] = a return a end
end

local action        -- montage path waiting to be played on the puppet
local actionPlaying -- montage playing, until the puppet stops

function M.handle(msg)
    if msg[1] == "amon" then
        if msg[3] and msg[3]:find("^/Game/") then action = msg[3] end
        return true
    end
    if msg[1] ~= "anim" then return false end
    want = {
        fwd = tonumber(msg[3]) or 0, right = tonumber(msg[4]) or 0, up = tonumber(msg[5]) or 0,
        flags = msg[6] or "-", ladder = tonumber(msg[7]) or 0,
    }
    return true
end

local function has(flag) return want.flags:find(flag, 1, true) ~= nil end

-- Which asset, and the blend position or play rate for it.
local function choose()
    if has("L") then
        local down = want.ladder < 0
        return down and "ladderDown" or "ladderUp", nil, math.min(1.5, math.abs(want.ladder) / LADDER_RATE_REF)
    end
    if has("D") then return has("S") and "diveFast" or "dive", { x = want.right, y = want.up } end
    if has("W") then return "swim", { x = 0, y = math.sqrt(want.fwd ^ 2 + want.right ^ 2) } end
    if has("F") then return "fall" end
    if has("B") and math.abs(want.fwd) < CRAFT_STILL and math.abs(want.right) < CRAFT_STILL then return "craft" end
    -- The blueprint lays weapon arms over the legs; one sequence at a time
    -- shows the aim standing still. Moving, the legs matter more: the weapon
    -- run sequence moved only the upper body (2026-11-18).
    if has("G") and math.abs(want.fwd) < CRAFT_STILL and math.abs(want.right) < CRAFT_STILL then return "aim" end
    if has("C") then return "crouch", { x = want.right, y = want.fwd } end
    if has("S") and want.fwd > 50 then return "sprint" end
    return "move", { x = want.right, y = want.fwd }
end

-- Called every frame with the puppet's mesh. Returns false before the first
-- state has arrived (an older mod on the other side), so the caller keeps its
-- speed-based animation.
local function montage(path)
    local a = cache[path]
    if a and a:IsValid() then return a end
    a = StaticFindObject(path)
    if not (a and a:IsValid()) then
        local ok, loaded = pcall(LoadAsset, path)
        a = ok and loaded or nil
    end
    if a and a:IsValid() then cache[path] = a return a end
end

-- The puppet plays a montage whole body, once, then goes back to locomotion.
local function applyAction(skc)
    if action then
        local m = montage(action)
        if m then
            skc:PlayAnimation(m, false)
            pcall(function() skc:SetPlayRate(1) end)
            actionPlaying, playing = action, nil
            log("docka: %s", action:match("([^/.]+)$"))
        end
        action = nil
        return actionPlaying ~= nil
    end
    if not actionPlaying then return false end
    local ok, still = pcall(function() return skc:IsPlaying() end)
    if ok and still then return true end
    actionPlaying = nil
    return false
end

function M.apply(skc)
    if applyAction(skc) then return true end
    if not want then return false end
    local key, pos, rate = choose()
    if key ~= playing then
        local a = asset(key)
        if not a then return false end
        skc:PlayAnimation(a, true)
        playing = key
        if os.time() - lastLog >= 2 then
            lastLog = os.time()
            log("docka: %s (%s, fram %.0f höger %.0f)", key, want.flags, want.fwd, want.right)
        end
    end
    if pos and BLEND[key] then
        blend.x = blend.x + (pos.x - blend.x) * 0.25
        blend.y = blend.y + (pos.y - blend.y) * 0.25
        local ai = skc:GetAnimInstance()
        if ai and ai:IsValid() then ai:SetBlendSpacePosition({ X = blend.x, Y = blend.y, Z = 0 }) end
    end
    pcall(function() skc:SetPlayRate(rate or 1) end)
    return true
end

function M.reset()
    playing, actionPlaying, action = nil, nil, nil
end

return M
