-- Boats: one game is the authority for each boat and sends its state 20 times a
-- second. The driver is the authority; with nobody driving it is the host. The
-- other game keeps its own physics running and only steers the velocity toward
-- the received state, so the boat moves smoothly between updates and anyone
-- standing on it is carried along. Pitch, roll and height stay with the local
-- buoyancy. Large errors are teleported.
local M = {}
local UEHelpers = require("UEHelpers")

local BOAT_CLASS = "/Script/Voyage.VoyageBoatPawn"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local POS_GAIN, YAW_GAIN = 2.0, 2.0
local SNAP_DIST, SNAP_YAW = 800, 45

local net, log, localPC, now, isHost
local boats, lastScan = {}, -100      -- key -> actor
local remote = {}                     -- key -> received state
local rest = {}     -- key -> average height and tilt while not held (mooring hold)
local hold = {}     -- key -> held z/pitch/roll, and x/y/yaw once settled
-- Whoever drove a boat last keeps sending its state after leaving the helm,
-- since only that game has the throttle set; the other takes over by driving.
local peerAuthority = {}              -- key -> true while the peer drives or drove last
local described = {}
local lastPawnClass

local function boatClass()
    local c = StaticFindObject(BOAT_CLASS)
    if c and c:IsValid() then return c end
end

local function keyOf(actor)
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then
        local id = pc.PersistentUniqueId
        if id and id ~= 0 then return "id" .. tostring(id) end
    end
    return "p" .. (actor:GetFullName():match("%S+%s+(%S+)") or "?")
end

-- The root is a plain scene component; the hull that floats is one of the
-- primitive components simulating physics.
local bodies, bodySearch = {}, {}
local function body(actor)
    local key = actor:GetAddress()
    local b = bodies[key]
    if b and b:IsValid() then
        local ok, sim = pcall(function() return b:IsSimulatingPhysics(FName("None")) end)
        if ok and sim then return b end
    end
    bodies[key] = nil
    if bodySearch[key] and now() - bodySearch[key] < 2 then return nil end
    bodySearch[key] = now()
    local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    for _, e in ipairs(comps or {}) do
        -- UE4SS 4 hands the array's elements wrapped; unwrapped, the hull was
        -- never found and its physics never turned off (2026-11-18).
        local c = e.get and e:get() or e
        local ok, sim = pcall(function() return c:IsSimulatingPhysics(FName("None")) end)
        if ok and sim then
            bodies[key] = c
            log("båt %s: kropp %s simulerar fysik", actor:GetFName():ToString(), c:GetFName():ToString())
            return c
        end
    end
end
M.body = body

-- A teleport keeps a simulating hull's speed; whatever moves the boat by hand
-- stills the hull too (no effect on the barge, whose hull does not simulate).
local ZERO = { X = 0, Y = 0, Z = 0 }
-- For a boat whose hull simulates physics (the barge does not: its movement
-- component moves it): the mod places it every frame, so its own physics is
-- off while it follows or lies moored, and back on, still, when this game
-- moves it.
local hulls = {}          -- key -> path of the hull whose physics the mod turned off
-- The anchors are bodies of their own on a cable from the boat's anchor
-- modules. While the boat follows (hull placed by the mod, physics off) they
-- were left behind and fell 280 m under the boat; whoever took over got a
-- hull tied to them and the boat lurched (2026-11-18). The follower holds each
-- anchor, physics off, under its spool (a pendulum's middle, measured with
-- the anchors up), dropped or not, and lets go when this game moves the boat.
local ANCHOR_IN_ROOT = { Translation = { X = 58, Y = 188, Z = -62 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
    Scale3D = { X = 1, Y = 1, Z = 1 } }
local anchorParts = {}      -- key -> { { anchor = path, root = path } }

local function findAnchors(key, actor)
    local list, seen = {}, {}
    local hull = actor.RootComponent
    for i = 0, hull:GetNumChildrenComponents() - 1 do
        pcall(function()
            local o = hull:GetChildComponent(i):GetOwner()
            if not (o and o:IsValid()) or seen[o:GetAddress()] or not o:GetFName():ToString():find("Anchor_C", 1, true) then return end
            seen[o:GetAddress()] = true
            local part = {}
            for _, e in ipairs(o:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent")) or {}) do
                local okG, c = pcall(function() return e:get() end)
                if not okG then c = e end
                local n = c:GetFName():ToString()
                if n == "Anchor" then part.anchor = c:GetFullName():match("%S+%s+(%S+)")
                elseif n == "Root" then part.root = c:GetFullName():match("%S+%s+(%S+)")
                elseif c:GetClass():GetFName():ToString() == "VoyageCableComponent" then part.cable = c:GetFullName():match("%S+%s+(%S+)") end
            end
            if part.anchor and part.root then list[#list + 1] = part end
        end)
    end
    anchorParts[key] = list
    log("båt %s: %d ankare", key, #list)
    return list
end

local function holdAnchors(key, actor)
    local list = anchorParts[key] or findAnchors(key, actor)
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    for _, part in ipairs(list) do
        local a, r = StaticFindObject(part.anchor), StaticFindObject(part.root)
        if a and a:IsValid() and r and r:IsValid() then
            if not part.held then
                pcall(function() a:SetSimulatePhysics(false) end)
                part.held = true
            end
            a:K2_SetWorldTransform(kml:ComposeTransforms(ANCHOR_IN_ROOT, r:K2_GetComponentToWorld()), false, {}, true)
            -- The cable's particles live in the world and trailed metres
            -- astern of the placed boat; reset, they run straight to the anchor.
            local cable = part.cable and StaticFindObject(part.cable)
            if cable and cable:IsValid() then pcall(function() cable:Reset() end) end
        else
            anchorParts[key] = nil
        end
    end
end

local function releaseAnchors(key)
    for _, part in ipairs(anchorParts[key] or {}) do
        local a = part.held and StaticFindObject(part.anchor)
        if a and a:IsValid() then
            pcall(function()
                a:SetSimulatePhysics(true)
                a:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
                a:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
            end)
        end
        part.held = nil
    end
end

local function setHullPhysics(key, actor, on)
    if on then
        releaseAnchors(key)
        local path = hulls[key]
        if not path then return end
        hulls[key] = nil
        local b = StaticFindObject(path)
        if b and b:IsValid() then
            pcall(function()
                b:SetSimulatePhysics(true)
                b:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
                b:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
            end)
            log("båt %s: skrovets fysik på", key)
        end
        return
    end
    if hulls[key] then return end
    local b = body(actor)
    if not b then return end
    local ok = pcall(function() b:SetSimulatePhysics(false) end)
    if ok then
        hulls[key] = b:GetFullName():match("%S+%s+(%S+)")
        log("båt %s: skrovets fysik av", key)
    end
end
M.setHullPhysics = setHullPhysics

local function stillBody(actor, spinOnly)
    local b = body(actor)
    if not b then return end
    pcall(function()
        if not spinOnly then b:SetPhysicsLinearVelocity(ZERO, false, FName("None")) end
        b:SetPhysicsAngularVelocityInDegrees(ZERO, false, FName("None"))
    end)
end

local function describe(key, actor)
    if described[key] then return end
    described[key] = true
    local okA, anch = pcall(function() return actor.AnchorsDropped end)
    log("båt %s: %s, ankare %s", key, actor:GetFullName(), okA and tostring(anch) or "?")
    local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    -- Unwrapped, asking every component for its mass and parent crashed UE4SS
    -- in both games (2026-11-18): only the names of the simulating ones.
    local sims = {}
    for _, e in ipairs(comps or {}) do
        local c = e.get and e:get() or e
        local okS, sim = pcall(function() return c:IsSimulatingPhysics(FName("None")) end)
        if okS and sim then sims[#sims + 1] = c:GetFName():ToString() end
    end
    log("  simulerar fysik: %s", #sims > 0 and table.concat(sims, ", ") or "-")
    log("  %d primitiva komponenter, kropp: %s", #(comps or {}), (body(actor) and body(actor):GetFName():ToString()) or "ingen")
end

local function scan()
    if now() - lastScan < 5 then return end
    lastScan = now()
    local ok, found = pcall(FindObjects, 0, "VoyageBoatPawn", "", 0, 0x10, false)
    local fresh = {}
    for _, a in ipairs((ok and found) or {}) do
        local okK, key = pcall(function() if a:IsValid() then return keyOf(a) end end)
        if okK and key then
            fresh[key] = a
            pcall(describe, key, a)
        end
    end
    boats = fresh
end

local function drivenKey()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return nil end
    local cls = pawn:GetClass():GetFName():ToString()
    if cls ~= lastPawnClass then
        lastPawnClass = cls
        log("egen pawn: %s", cls)
    end
    local bc = boatClass()
    if bc and pawn:IsA(bc) then return keyOf(pawn), pawn end
end

local function wrap(a)
    return (a + 180) % 360 - 180
end

local function f1(v) return string.format("%.1f", v or 0) end

-- The barge is moved kinematically by the game's boat movement, so it has no
-- physics velocity; it is measured from the movement between sends.
local lastSent = {}
local JOLT_SPEED = 60
local function measure(key, l, r)
    local t = now()
    local p = lastSent[key]
    local v = { X = 0, Y = 0, Z = 0, W = 0 }
    if p and t - p.t > 0.01 and t - p.t < 0.5 then
        local dt = t - p.t
        local k = 0.5
        v.X = p.v.X * (1 - k) + (l.X - p.l.X) / dt * k
        v.Y = p.v.Y * (1 - k) + (l.Y - p.l.Y) / dt * k
        v.Z = p.v.Z * (1 - k) + (l.Z - p.l.Z) / dt * k
        v.W = p.v.W * (1 - k) + wrap(r.Yaw - p.yaw) / dt * k
    end
    lastSent[key] = { t = t, l = { X = l.X, Y = l.Y, Z = l.Z }, yaw = r.Yaw, v = v }
    return v, { Z = v.W }
end

local function control(actor, fn)
    local ok, v = pcall(function() return actor[fn](actor) end)
    return (ok and type(v) == "number") and v or 0
end

local function sendState(key, actor, driving)
    local root = body(actor) or actor.RootComponent
    local l = root:K2_GetComponentLocation()
    local r = root:K2_GetComponentRotation()
    -- A held boat sends its held pose: read here, between the game's own move
    -- and the hold, it carried the waves (and the grinder's knocks) to the
    -- other game, whose boat shook while this one lay still (2026-11-18).
    local h = hold[key]
    if h then
        l = { X = h.x or l.X, Y = h.y or l.Y, Z = h.z }
        r = { Pitch = h.pitch, Yaw = h.yaw or r.Yaw, Roll = h.roll }
    end
    -- The driven boat once jumped 90° to the left (2026-11-16); a big step in
    -- heading between two sends is logged with its time.
    local prev = lastSent[key]
    if driving and prev and math.abs(wrap(r.Yaw - prev.yaw)) > 15 and now() - prev.t < 0.5 then
        log("båt %s: kursen hoppade %.1f° på %.0f ms (%.1f -> %.1f), gas %.3f roder %.3f", key, wrap(r.Yaw - prev.yaw),
            (now() - prev.t) * 1000, prev.yaw, r.Yaw, control(actor, "GetThrottleActual"), control(actor, "GetSteeringActual"))
    end
    local v, w = measure(key, l, r)
    -- tested 2026-11-17: with both players aboard the moored boat it jolts now
    -- and then (the quay jumps for the host). A sudden change of the hull's
    -- speed is logged with its time, to set against the other log lines.
    if prev and prev.v and now() - prev.t < 0.5 then
        local dx, dy, dz = v.X - prev.v.X, v.Y - prev.v.Y, v.Z - prev.v.Z
        local dv = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dv > JOLT_SPEED then
            log("båt %s: ryck %.0f cm/s (%.0f %.0f %.0f) på %.0f ms, lutning %.1f/%.1f, gas %.2f", key, dv, dx, dy, dz,
                (now() - prev.t) * 1000, r.Pitch or 0, r.Roll or 0, control(actor, "GetThrottleActual"))
        end
    end
    local okA, anch = pcall(function() return actor.AnchorsDropped end)
    net.send("boat", key, f1(l.X), f1(l.Y), f1(l.Z), string.format("%.2f", r.Pitch or 0), string.format("%.2f", r.Yaw or 0),
        string.format("%.2f", r.Roll or 0), f1(v.X), f1(v.Y), f1(v.Z), f1(w.Z), (okA and anch) and 1 or 0, driving and 1 or 0,
        string.format("%.3f", now()), string.format("%.3f", control(actor, "GetThrottleActual")),
        string.format("%.3f", control(actor, "GetSteeringActual")))
end

local lastFollowLog = 0

-- The follower plays the sender's motion back a little late, between two
-- known states stamped with the sender's clock, so arrival jitter never shows.
local RENDER_DELAY = 0.12
local clockOffset = {}     -- key -> local time minus sender time (smallest seen)

-- A game that hitches loses time on its clock, so the real offset grows and
-- the smallest one seen goes stale: playback ran up to 5 s ahead of every
-- received state and the boat froze and jumped (2026-11-15). The offset eases
-- up to the smallest delay among the buffered states instead.
local OFFSET_SLACK, OFFSET_RELAX = 0.02, 0.2
function M.relaxOffset(offset, buf, dt)
    local m
    for _, e in ipairs(buf) do if e.off and (not m or e.off < m) then m = e.off end end
    if m and m > offset + OFFSET_SLACK then return offset + math.min(m - offset - OFFSET_SLACK, OFFSET_RELAX * dt) end
    return offset
end

local function lerp(a, b, t) return a + (b - a) * t end
local function lerpAngle(a, b, t) return a + wrap(b - a) * t end

-- Course and position follow a straight line fitted to the last half second of
-- states, so the speed is even from frame to frame; uneven spacing of the
-- sender's states showed as jerks on everything aboard. Height and tilt,
-- which follow the waves, are interpolated.
local FIT_WINDOW = 0.6
local function fitLine(buf, renderT)
    local pts = {}
    for i = #buf, 1, -1 do
        if buf[i].st < renderT - FIT_WINDOW then break end
        pts[#pts + 1] = buf[i]
    end
    if #pts < 3 then return nil end
    local base = pts[#pts]
    local n, st, stt = #pts, 0, 0
    local sx, sy, syaw, stx, sty, styaw = 0, 0, 0, 0, 0, 0
    for _, p in ipairs(pts) do
        local t = p.st - base.st
        local yaw = base.yaw + wrap(p.yaw - base.yaw)
        st, stt = st + t, stt + t * t
        sx, sy, syaw = sx + p.x, sy + p.y, syaw + yaw
        stx, sty, styaw = stx + t * p.x, sty + t * p.y, styaw + t * yaw
    end
    local den = n * stt - st * st
    if math.abs(den) < 1e-9 then return nil end
    local function at(s1, s2)
        local slope = (n * s2 - st * s1) / den
        local icpt = (s1 - slope * st) / n
        return icpt + slope * (renderT - base.st)
    end
    return at(sx, stx), at(sy, sty), at(syaw, styaw)
end

local function sample(key, buf)
    local renderT = now() - clockOffset[key] - RENDER_DELAY
    local r = M.rawSample(key, buf, renderT)
    -- A copy: the raw sample may be an entry of the buffer itself.
    local p = { x = r.x, y = r.y, z = r.z, pitch = r.pitch, yaw = r.yaw, roll = r.roll }
    local okF, x, y, yaw = pcall(fitLine, buf, renderT)
    if okF and x then p.x, p.y, p.yaw = x, y, yaw end
    return p
end

function M.rawSample(key, buf, renderT)
    local n = #buf
    for i = n - 1, 1, -1 do
        local a, b = buf[i], buf[i + 1]
        if a.st <= renderT and renderT <= b.st then
            local t = (renderT - a.st) / math.max(b.st - a.st, 0.001)
            return { x = lerp(a.x, b.x, t), y = lerp(a.y, b.y, t), z = lerp(a.z, b.z, t),
                pitch = lerpAngle(a.pitch, b.pitch, t), yaw = lerpAngle(a.yaw, b.yaw, t), roll = lerpAngle(a.roll, b.roll, t) }
        end
    end
    local last = buf[n]
    if n >= 2 and renderT > last.st then
        -- Late packets: carry on along the last motion for a moment.
        local prev = buf[n - 1]
        local t = 1 + math.min(renderT - last.st, 0.3) / math.max(last.st - prev.st, 0.001)
        return { x = lerp(prev.x, last.x, t), y = lerp(prev.y, last.y, t), z = lerp(prev.z, last.z, t),
            pitch = last.pitch, yaw = lerpAngle(prev.yaw, last.yaw, t), roll = last.roll }
    end
    return last
end

-- The game's own boat movement would push the follower's boat every frame
-- against the mod; it is off while the peer controls the boat.
local movementOff = {}
-- The follower's boat keeps its own tick (ladders and other systems aboard
-- need it; with it off, nobody but the controller could climb). Instead the
-- boat ticks before the world time actor, whose tick moves it to the received
-- state, so the mod's placement is what each frame ends with.
local orderedBoats = {}
local function setOwnMovement(key, actor, on)
    if orderedBoats[key] then return end
    local ok, found = pcall(FindObjects, 0, "BP_PersistentWorldTime_C", "", 0, 0x10, false)
    local first = ok and found and found[1]
    if not (first and first:IsValid()) then return end
    orderedBoats[key] = true
    local okP, errP = pcall(function() first:AddTickPrerequisiteActor(actor) end)
    pcall(function() actor:SetActorTickEnabled(true) end)
    log("båt %s: tickar före världstiden (%s)", key, okP and "ok" or tostring(errP))
end

-- The throttle and rudder live in the boat pawn as the driver's accumulated
-- input, with no setter. Taking the helm, the mod holds the boat's own input
-- actions (through Enhanced Input injection) until this game's throttle and
-- rudder have reached the previous driver's.
local CATCHUP_SECONDS, CATCHUP_TOLERANCE = 6, 0.03
local catchup = {}          -- key -> { throttle, steer, untilT, path }

local function inputSubsystem()
    local ok, found = pcall(FindObjects, 0, "EnhancedInputLocalPlayerSubsystem", "", 0, 0x10, false)
    for _, sub in ipairs((ok and found) or {}) do
        if sub:IsValid() then return sub end
    end
end

local function press(sub, action)
    if action and action:IsValid() then
        sub:InjectInputVectorForAction(action, { X = 1, Y = 0, Z = 0 }, {}, {})
    end
end

local function runCatchup()
    for key, c in pairs(catchup) do
        local a = StaticFindObject(c.path)
        local pawn = localPC().Pawn
        local driving = a and a:IsValid() and pawn and pawn:IsValid() and pawn:GetAddress() == a:GetAddress()
        local thr, st = driving and control(a, "GetThrottleActual"), driving and control(a, "GetSteeringActual")
        local thrDone = driving and math.abs(thr - c.throttle) <= CATCHUP_TOLERANCE
        local stDone = driving and math.abs(st - c.steer) <= CATCHUP_TOLERANCE
        if not driving or (thrDone and stDone) or now() > c.untilT then
            log("båt %s: tar över klart (%s): gas %s mål %.3f, roder %s mål %.3f", key,
                not driving and "slutade köra" or (thrDone and stDone) and "nått" or "tiden slut",
                thr and string.format("%.3f", thr) or "-", c.throttle, st and string.format("%.3f", st) or "-", c.steer)
            catchup[key] = nil
        else
            local sub = inputSubsystem()
            if not sub then log("båt: hittar ingen Enhanced Input-subsystem") catchup[key] = nil return end
            if not thrDone then press(sub, thr < c.throttle and a.ThrottleForwardAction or a.ThrottleBackwardAction) end
            if not stDone then press(sub, st < c.steer and a.SteeringRightAction or a.SteeringLeftAction) end
        end
    end
end

-- Diagnosis: how far the boat has moved by itself since the mod last placed
-- it (its own tick runs in between), and how evenly the placed states move.
local drift = { at = 0, n = 0, sum = 0, max = 0, zMax = 0, yawMax = 0, setSum = 0, setMax = 0 }
local lastSet = {}
local function measureDrift(key, root, p)
    local l = root:K2_GetComponentLocation()
    local r = root:K2_GetComponentRotation()
    local t = now()
    local q = lastSet[key]
    if q and t - q.t < 0.2 then
        local d = math.sqrt((l.X - q.x) ^ 2 + (l.Y - q.y) ^ 2)
        drift.n = drift.n + 1
        drift.sum = drift.sum + d
        if d > drift.max then drift.max = d end
        local dz = math.abs(l.Z - q.z)
        if dz > drift.zMax then drift.zMax = dz end
        local dy = math.abs(wrap(r.Yaw - q.yaw))
        if dy > drift.yawMax then drift.yawMax = dy end
        local v = math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) / math.max(t - q.t, 0.001)
        drift.setSum = drift.setSum + v
        if v > drift.setMax then drift.setMax = v end
    end
    lastSet[key] = { t = t, x = p.x, y = p.y, z = p.z, yaw = p.yaw }
    if t - drift.at >= 5 then
        if drift.n > 0 then
            log("båt drift: %d bildrutor, egen förflyttning snitt %.2f max %.2f cm, höjd max %.2f cm, kurs max %.3f grader; lagd fart snitt %.0f max %.0f cm/s",
                drift.n, drift.sum / drift.n, drift.max, drift.zMax, drift.yawMax, drift.setSum / drift.n, drift.setMax)
        end
        drift = { at = t, n = 0, sum = 0, max = 0, zMax = 0, yawMax = 0, setSum = 0, setMax = 0 }
    end
end

M.teleport = true

-- Moves an actor without a SweepHitResult out parameter: UE4SS 3.0.1 keeps a
-- registry reference to the hit result table of every such call (about 1-5 KB
-- each, never freed); called every frame, the host's Lua memory grew by
-- 2.7 MB/s. K2_TeleportTo has no out parameter and placed boat, puppet and
-- shark exactly (2026-11-15); if it ever refuses, the old call is used.
local moveStats = { at = 0, n = 0, refused = 0, off = 0 }
-- K2_TeleportTo has no out parameter (UE4SS 3.0.1 leaked one per call) but
-- tests for a free spot: 3.75 ms per move of the loaded barge against 0.5 ms
-- for K2_SetActorLocationAndRotation, which no longer leaks in 4.x (bench
-- 2026-11-17). The guest moved the barge every frame and lost frames.
local noLeak = (function()
    local ok, major = pcall(function() return UE4SS.GetVersion() end)
    return ok and type(major) == "number" and major >= 4
end)()

function M.moveActor(a, loc, rot)
    if noLeak then
        a:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
        moveStats.n = moveStats.n + 1
        return
    end
    local ok, done = pcall(function() return a:K2_TeleportTo(loc, rot) end)
    local s = moveStats
    s.n = s.n + 1
    if not (ok and done) then
        s.refused = s.refused + 1
        if not s.who then pcall(function() s.who = a:GetClass():GetFName():ToString() end) end
        a:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    elseif M.measure then
        local l = a:K2_GetActorLocation()
        local d = math.sqrt((l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2)
        if d > s.off then s.off = d end
    end
    if now() - s.at >= 10 then
        if s.refused > 0 or s.off > 1 then
            log("flytt: %d, vägrade %d (t.ex. %s), största avvikelse %.1f cm", s.n, s.refused, tostring(s.who), s.off)
        end
        moveStats = { at = now(), n = 0, refused = 0, off = 0 }
    end
end

-- Per-frame measurements for the log (drift, smoothness); each costs game
-- calls every frame, so they are off unless a test turns them on.
M.measure = false
-- Moving the barge with everything on it is the mod's dearest call per frame
-- (about 1 ms), so an unchanged pose is skipped. The limits must stay tiny:
-- with 1 cm / 0.1 degree a bobbing boat moved in visible steps and the guest,
-- standing on it, saw the whole world jump (2026-11-15).
local SKIP_MOVE, SKIP_ANGLE = 0.02, 0.002
local lastPlaced = {}
local placedCount = { placed = 0, skipped = 0 }

local function samePose(q, p)
    return q and math.abs(q.x - p.x) < SKIP_MOVE and math.abs(q.y - p.y) < SKIP_MOVE and math.abs(q.z - p.z) < SKIP_MOVE
        and math.abs(wrap(q.yaw - p.yaw)) < SKIP_ANGLE and math.abs(wrap(q.pitch - p.pitch)) < SKIP_ANGLE
        and math.abs(wrap(q.roll - p.roll)) < SKIP_ANGLE
end

local function follow(key, actor, s)
    local buf = s.buf
    if not buf or #buf == 0 or not clockOffset[key] then return end
    setOwnMovement(key, actor, false)
    setHullPhysics(key, actor, false)
    local t = now()
    clockOffset[key] = M.relaxOffset(clockOffset[key], buf, t - (s.relaxedAt or t))
    s.relaxedAt = t
    local p = sample(key, buf)
    local renderT = now() - clockOffset[key] - RENDER_DELAY
    local q0 = placedCount.prevRaw
    if q0 then
        if renderT == q0.rt then
            placedCount.sameT = (placedCount.sameT or 0) + 1
        elseif p.z == q0.z then
            placedCount.flat = (placedCount.flat or 0) + 1
            if renderT > buf[#buf].st then placedCount.late = (placedCount.late or 0) + 1 end
        end
    end
    placedCount.prevRaw = { rt = renderT, z = p.z }
    placedCount.ahead = math.max(placedCount.ahead or -1e9, renderT - buf[#buf].st)
    -- An unchanged pose is only skipped while the boat is still where it was
    -- put: a moored, held boat sends the same pose for minutes, and the
    -- follower's own boat drifted off meanwhile (2026-11-18).
    local q = lastPlaced[key]
    if q then
        local root = body(actor) or actor.RootComponent
        local cl, cr = root:K2_GetComponentLocation(), root:K2_GetComponentRotation()
        if math.abs(cl.X - q.x) > 1 or math.abs(cl.Y - q.y) > 1 or math.abs(cl.Z - q.z) > 1
            or math.abs(wrap((cr.Pitch or 0) - q.pitch)) > 0.1 or math.abs(wrap((cr.Roll or 0) - q.roll)) > 0.1
            or math.abs(wrap((cr.Yaw or 0) - q.yaw)) > 0.1 then
            lastPlaced[key] = nil
        end
    end
    if not samePose(lastPlaced[key], p) then
        local hull = body(actor)
        if M.measure then pcall(measureDrift, key, hull or actor.RootComponent, p) end
        local loc, rot = { X = p.x, Y = p.y, Z = p.z }, { Pitch = p.pitch, Yaw = p.yaw, Roll = p.roll }
        if hull then
            hull:K2_SetWorldLocationAndRotation(loc, rot, false, {}, M.teleport)
            -- The follower's hull has no motion of its own: something pulling
            -- it here (a data cable plugged in, 2026-11-18) built up speed
            -- under the teleports, the boat shook and could fly off once
            -- this game took over.
            stillBody(actor)
        else
            M.moveActor(actor, loc, rot)
        end
        local okA, errA = pcall(holdAnchors, key, actor)
        if not okA and not s.anchorErr then s.anchorErr = true log("båt %s: ankarhållning: %s", key, tostring(errA)) end
        lastPlaced[key] = p
        placedCount.placed = placedCount.placed + 1
        local q = placedCount.prev
        if q then
            local m = placedCount
            m.dPos = math.max(m.dPos or 0, math.abs(q.x - p.x), math.abs(q.y - p.y), math.abs(q.z - p.z))
            m.dAng = math.max(m.dAng or 0, math.abs(wrap(q.yaw - p.yaw)), math.abs(wrap(q.pitch - p.pitch)), math.abs(wrap(q.roll - p.roll)))
        end
        placedCount.prev = p
    else
        placedCount.skipped = placedCount.skipped + 1
    end
    if os.time() - lastFollowLog >= 10 then
        lastFollowLog = os.time()
        log("båt %s: följer, %d lägen, klockskillnad %.3f, deras gas %s roder %s, placerad %d hoppad %d, största steg %.2f cm %.3f grader", key, #buf, clockOffset[key],
            tostring(s.throttle), tostring(s.steer), placedCount.placed, placedCount.skipped, placedCount.dPos or 0, placedCount.dAng or 0)
        log("båt %s: samma tid %d, samma höjd %d (varav efter sista läget %d), längst före sista läget %.3f s", key,
            placedCount.sameT or 0, placedCount.flat or 0, placedCount.late or 0, placedCount.ahead or 0)
        placedCount = { placed = 0, skipped = 0, prevRaw = placedCount.prevRaw }
    end
    if s.anchors ~= s.anchorsSeen or now() - (s.anchorsAt or 0) > 0.5 then
        s.anchorsSeen, s.anchorsAt = s.anchors, now()
        local okA, anch = pcall(function() return actor.AnchorsDropped end)
        if okA and anch ~= s.anchors then
            if s.anchorsLogged ~= s.anchors then log("båt %s: ankare %s", key, s.anchors and "ner" or "upp") end
            s.anchorsLogged = s.anchors
            if s.anchors then actor:DropAnchors() else actor:LiftAnchors() end
        end
    end
end

-- Moored, the boat lies still (user 2026-11-18: in singleplayer it hardly
-- moves at the quay; in co-op it rode the waves). The game that moves the boat
-- holds it every frame while a mooring line is plugged at both ends (power.lua
-- sets M.moored): height and tilt from the calm average before mooring, so the
-- lines can still pull it in, and the whole pose once it has stopped moving.
-- The other game follows the held boat as usual.
M.moored = false
local SETTLE_SPEED, SETTLE_SECONDS, REST_TAU = 5, 4, 3
-- power.lua: the mooring lines plugged at both ends (sockets and length).
M.mooringLines = ""

local function updateHold(key, actor, driving)
    local root = actor.RootComponent
    local l = root:K2_GetComponentLocation()
    if driving or not M.moored then
        if hold[key] then
            hold[key] = nil
            setHullPhysics(key, actor, true)
            stillBody(actor)
            log("båt %s: förtöjning släppt, vågorna tar båten igen", key)
        end
        local r = root:K2_GetComponentRotation()
        local pitch, roll = r.Pitch or 0, r.Roll or 0
        local s = rest[key]
        if not s then
            rest[key] = { z = l.Z, pitch = pitch, roll = roll, t = now() }
            return
        end
        local k = math.min(1, (now() - s.t) / REST_TAU)
        s.t = now()
        s.z = s.z + (l.Z - s.z) * k
        s.pitch = s.pitch + wrap(pitch - s.pitch) * k
        s.roll = s.roll + wrap(roll - s.roll) * k
        return
    end
    local h = hold[key]
    if not h then
        local s = rest[key]
        local r = root:K2_GetComponentRotation()
        -- Held upright: the average tilt taken while the boat bobbed (during
        -- loading) left it standing askew (2026-11-18).
        h = { z = s and s.z or l.Z, pitch = 0, roll = 0, stillSince = now(), lines = M.mooringLines }
        hold[key] = h
        setOwnMovement(key, actor, true)
        log("båt %s: förtöjd, höjd %.0f och lutning %.1f/%.1f hålls (nu %.0f, %.1f/%.1f)", key, h.z, h.pitch, h.roll,
            l.Z, r.Pitch or 0, r.Roll or 0)
    end
    -- A line moved to another point along the quay (or reeled in) pulls the
    -- boat there, as in singleplayer: the boat is let go sideways until it
    -- has lain still again (user 2026-11-18).
    if h.lines ~= M.mooringLines then
        h.lines = M.mooringLines
        if h.x then
            h.x, h.y, h.yaw, h.lx = nil, nil, nil, nil
            h.stillSince = now()
            setHullPhysics(key, actor, true)
            log("båt %s: förtöjningslinorna ändrades, linorna får dra båten", key)
        end
    end
    if h.x then return end
    if h.lx then
        local dt = now() - h.lt
        if dt > 0 and math.sqrt((l.X - h.lx) ^ 2 + (l.Y - h.ly) ^ 2) / dt > SETTLE_SPEED then h.stillSince = now() end
    end
    h.lx, h.ly, h.lt = l.X, l.Y, now()
    if now() - h.stillSince >= SETTLE_SECONDS then
        h.x, h.y, h.yaw = l.X, l.Y, root:K2_GetComponentRotation().Yaw
        setHullPhysics(key, actor, false)
        log("båt %s: ligger still vid kajen, hela läget hålls", key)
    end
end

local function holdAll()
    for key, h in pairs(hold) do
        local actor = boats[key]
        if actor and actor:IsValid() and not M.peerControls(key) then
            local loc, rot
            if h.x then
                loc, rot = { X = h.x, Y = h.y, Z = h.z }, { Pitch = h.pitch, Yaw = h.yaw, Roll = h.roll }
            else
                local root = actor.RootComponent
                local l, r = root:K2_GetComponentLocation(), root:K2_GetComponentRotation()
                loc, rot = { X = l.X, Y = l.Y, Z = h.z }, { Pitch = h.pitch, Yaw = r.Yaw, Roll = h.roll }
            end
            M.moveActor(actor, loc, rot)
            stillBody(actor)
        else
            hold[key] = nil
        end
    end
end

-- A boat that starts moving itself after being placed by the mod (taken over
-- from the other game, or let go by the mooring hold) rolled to 60 degrees
-- within 3 s and sank (guest 2026-11-18 09:14, likely the capsizing at the
-- quay 2026-11-17 too). The game moving the boat never lets it lean further
-- than this; in singleplayer it hardly leans at all.
-- At full throttle the bow rides at 10-11 degrees, and a 10 degree limit held
-- it down every frame: the boat shook and climbed into the air (2026-11-18).
local MAX_TILT = 25
local tiltLog = { at = 0, n = 0, worst = 0 }

local function limitTilt()
    for key, actor in pairs(boats) do
        if not hold[key] and key:sub(1, 2) == "id" and actor:IsValid() and not M.peerControls(key) then
            local root = actor.RootComponent
            local r = root:K2_GetComponentRotation()
            local pitch, roll = r.Pitch or 0, r.Roll or 0
            if math.abs(pitch) > MAX_TILT or math.abs(roll) > MAX_TILT then
                setOwnMovement(key, actor, true)
                local worst = math.max(math.abs(pitch), math.abs(roll))
                tiltLog.n = tiltLog.n + 1
                if worst > tiltLog.worst then tiltLog.worst = worst end
                pitch = math.max(-MAX_TILT, math.min(MAX_TILT, pitch))
                roll = math.max(-MAX_TILT, math.min(MAX_TILT, roll))
                M.moveActor(actor, root:K2_GetComponentLocation(), { Pitch = pitch, Yaw = r.Yaw or 0, Roll = roll })
                stillBody(actor, true)
            end
        end
    end
    if tiltLog.n > 0 and now() - tiltLog.at >= 5 then
        log("båt: lutningsgränsen tog %d bildrutor, värst %.1f°", tiltLog.n, tiltLog.worst)
        tiltLog = { at = now(), n = 0, worst = 0 }
    end
end

-- The boat the local player drives, from the tick: looking it up every frame
-- cost several game calls.
local tickMyKey

function M.reset()
    lastPlaced, tickMyKey = {}, nil
    movementOff, clockOffset, catchup, orderedBoats, hold, rest, hulls = {}, {}, {}, {}, {}, {}, {}
    boats, lastScan, remote, peerAuthority, described, lastPawnClass, bodies, bodySearch, lastSent = {}, -100, {}, {}, {}, nil, {}, {}, {}
end


-- Following runs about 60 times a second, extrapolating between the 20 Hz
-- updates, so a kinematic boat glides instead of jumping.
local function followAll()
    for key, s in pairs(remote) do
        local actor = boats[key]
        if key ~= tickMyKey and M.peerControls(key) and now() - s.t <= 1.0 and actor and actor:IsValid() then
            do
                local ok, err = pcall(follow, key, actor, s)
                if not ok then log("båt-följ-fel: %s", tostring(err)) remote[key] = nil end
            end
        end
    end
end

-- Following runs once per rendered frame, from the world time actor's tick,
-- and the local player's pawn, its movement and the controller are made to
-- tick after that actor: moved later in the frame, the boat was a frame ahead
-- of the camera and everything on it seemed to lag. A timer loop does not keep
-- step with the frames; it stays as a fallback until the hook has fired.
local FRAME_HOOK = "/Game/Blueprints/BP_PersistentWorldTime.BP_PersistentWorldTime_C:ReceiveTick"
local orderedPawn

local function orderTicks()
    local pc = localPC()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return end
    if orderedPawn == pawn:GetAddress() then return end
    local ok, found = pcall(FindObjects, 0, "BP_PersistentWorldTime_C", "", 0, 0x10, false)
    local first = ok and found and found[1]
    if not (first and first:IsValid()) then return end
    orderedPawn = pawn:GetAddress()
    local done = {}
    for name, fn in pairs({
        pawn = function() pawn:AddTickPrerequisiteActor(first) end,
        movement = function() pawn.CharacterMovement:AddTickPrerequisiteActor(first) end,
        controller = function() pc:AddTickPrerequisiteActor(first) end,
        camera = function() pc.PlayerCameraManager:AddTickPrerequisiteActor(first) end,
    }) do
        local okF = pcall(fn)
        done[#done + 1] = name .. (okF and " ok" or " -")
    end
    log("båt: tickordning för %s: %s", pawn:GetClass():GetFName():ToString(), table.concat(done, ", "))
end
local lastFrame, frameHookAt = -1, -100
-- Smoothness check: how evenly the saved boat moves from frame to frame
-- (speed per frame compared with the average), logged every 5 s.
local smooth = { n = 0, sum = 0, dev = 0, maxDev = 0, at = 0 }
local lastPos, lastPosT
local function measureFrame(t)
    for key, b in pairs(boats) do
        if key:sub(1, 2) == "id" and b:IsValid() then
            local l = b:K2_GetActorLocation()
            if lastPos and lastPosT and t > lastPosT then
                local v = math.sqrt((l.X - lastPos.X) ^ 2 + (l.Y - lastPos.Y) ^ 2) / (t - lastPosT)
                smooth.n = smooth.n + 1
                smooth.sum = smooth.sum + v
                local avg = smooth.sum / smooth.n
                local d = math.abs(v - avg)
                smooth.dev = smooth.dev + d
                if d > smooth.maxDev then smooth.maxDev = d end
            end
            lastPos, lastPosT = { X = l.X, Y = l.Y }, t
            break
        end
    end
    if t - smooth.at >= 5 then
        if smooth.n > 0 and smooth.sum / smooth.n > 50 then
            log("båt jämnhet: %d bildrutor/5 s, fart %.0f cm/s, avvikelse snitt %.0f max %.0f cm/s (%s)",
                smooth.n, smooth.sum / smooth.n, smooth.dev / smooth.n, smooth.maxDev, frameHookAt > 0 and "krok" or "loop")
        end
        smooth = { n = 0, sum = 0, dev = 0, maxDev = 0, at = t }
    end
end

-- Diagnosis of the lag on the follower: frame times, the mod's own time per
-- frame, and how much the local player moves relative to the boat.
local partCost = {}
local diag = { at = 0, frames = 0, maxDt = 0, slow = 0, luaMax = 0, luaSum = 0, relMax = 0, base = "-" }
local lastRel
local function diagnose(t, dt, luaMs)
    diag.frames = diag.frames + 1
    if dt > diag.maxDt then diag.maxDt = dt end
    if dt > 0.025 then diag.slow = diag.slow + 1 end
    diag.luaSum = diag.luaSum + luaMs
    if luaMs > diag.luaMax then diag.luaMax = luaMs end
    if M.measure then pcall(function()
        local pawn = localPC().Pawn
        for key, b in pairs(boats) do
            if key:sub(1, 2) == "id" and b:IsValid() then
                local rel = UEHelpers.GetKismetMathLibrary():InverseTransformLocation(b:GetTransform(), pawn:K2_GetActorLocation())
                if lastRel then
                    local d = math.sqrt((rel.X - lastRel.X) ^ 2 + (rel.Y - lastRel.Y) ^ 2 + (rel.Z - lastRel.Z) ^ 2)
                    if d > diag.relMax and d < 500 then diag.relMax = d end
                end
                lastRel = { X = rel.X, Y = rel.Y, Z = rel.Z }
                break
            end
        end
        local mb = pawn.BasedMovement.MovementBase
        diag.base = (mb and mb:IsValid()) and (mb:GetOwner():GetClass():GetFName():ToString() .. "/" .. mb:GetFName():ToString()) or "ingen"
    end) end
    if t - diag.at >= 5 then
        if diag.frames > 0 then
            log("diagnos: %d bildrutor, längsta %.0f ms, %d över 25 ms, mod %.2f ms snitt %.2f max per bildruta, gubbe mot båt max %.1f cm/bildruta, bas %s, %s",
                diag.frames, diag.maxDt * 1000, diag.slow, diag.luaSum / diag.frames, diag.luaMax, diag.relMax, diag.base,
                next(remote) and "följer" or "styr")
            -- ms per frame: 0 diagnose, 1 smoothness measure, 2 boat follow, 3.. callbacks in order added
            local p = {}
            for i = 0, #partCost do p[#p + 1] = string.format("%d:%.2f", i, (partCost[i] or 0) * 1000 / diag.frames) end
            log("bildrutedelar ms: %s", table.concat(p, " "))
        end
        partCost = {}
        diag = { at = t, frames = 0, maxDt = 0, slow = 0, luaMax = 0, luaSum = 0, relMax = 0, base = diag.base }
    end
end

-- Other modules that move things every frame (npc.lua).
local frameCallbacks = {}
function M.addFrame(fn) frameCallbacks[#frameCallbacks + 1] = fn end

local function onFrame(fromHook)
    if fromHook then frameHookAt = now() elseif now() - frameHookAt < 0.5 then return end
    local t = now()
    if t == lastFrame then return end
    local dt = t - lastFrame
    lastFrame = t
    local c0 = os.clock()
    if M.measure then pcall(measureFrame, t) end
    local c1 = os.clock()
    if next(catchup) then
        local okC, errC = pcall(runCatchup)
        if not okC then log("båt-inställningsfel: %s", tostring(errC)) catchup = {} end
    end
    local ok, err = pcall(followAll)
    if next(hold) then
        local okH, errH = pcall(holdAll)
        if not okH then log("båt-förtöjningsfel: %s", tostring(errH)) hold = {} end
    end
    local okT, errT = pcall(limitTilt)
    if not okT then log("båt-lutningsfel: %s", tostring(errT)) end
    local parts = partCost
    parts[1] = (parts[1] or 0) + (c1 - c0)
    parts[2] = (parts[2] or 0) + (os.clock() - c1)
    for i, fn in ipairs(frameCallbacks) do
        local cf = os.clock()
        local okF, errF = pcall(fn)
        parts[i + 2] = (parts[i + 2] or 0) + (os.clock() - cf)
        if not okF then log("bildrute-fel: %s", tostring(errF)) end
    end
    if not ok then log("båt-loop-fel: %s", tostring(err)) end
    local cd = os.clock()
    if dt < 1 then diagnose(t, dt, (cd - c0) * 1000) end
    parts[0] = (parts[0] or 0) + (os.clock() - cd)
end

local looping = false
local function startLoop()
    if looping then return end
    looping = true
    LoopInGameThreadWithDelay(16, function() onFrame(false) end)
end

local hooked = false
function M.arm()
    if hooked then return end
    hooked = true
    local ok, err = pcall(RegisterHook, FRAME_HOOK, function() onFrame(true) end)
    log("båt: bildrutekrok %s", ok and "ok" or tostring(err))
end

-- Throttle and wheel are lever actors (BP_Module_NonPhysicalSwitch_Base_C) in
-- child actor components of BP_Throttle / BP_Steering. Whoever controls the
-- boat sends their values; the follower sets them, so the levers move along
-- and are already right when the follower takes the helm.
local CONTROL_CLASSES = { "BP_Throttle_C", "BP_Steering_C" }
local lastControls, lastControlSend = {}, 0

local leverLogged = false
local function controlLevers()
    local list, seen = {}, {}
    local ok, found = pcall(FindObjects, 0, "VoyageModuleGenericSwitchActor", "", 0, 0x10, false)
    for _, sw in ipairs((ok and found) or {}) do
        pcall(function()
            if not sw:IsValid() then return end
            local parent = sw:GetParentActor()
            if not (parent and parent:IsValid()) then return end
            local pcls = parent:GetClass():GetFName():ToString()
            if pcls:find("Throttle") or pcls:find("Steering") then seen[#seen + 1] = pcls end
            for _, cls in ipairs(CONTROL_CLASSES) do
                if pcls == cls then list[#list + 1] = { key = keyOf(parent), lever = sw } end
            end
        end)
    end
    if not leverLogged then
        leverLogged = true
        log("båt: %d spakar totalt (%s), %d gas/ratt", #((ok and found) or {}), table.concat(seen, ", "), #list)
    end
    return list
end

local function sendControls()
    if now() - lastControlSend < 0.2 then return end
    lastControlSend = now()
    for _, c in ipairs(controlLevers()) do
        local v = c.lever.Value
        if lastControls[c.key] == nil or math.abs(lastControls[c.key] - v) > 0.001 or now() % 2 < 0.2 then
            lastControls[c.key] = v
            net.send("bctl", c.key, string.format("%.4f", v))
        end
    end
end

local wantControls = {}
local function applyControls()
    if not next(wantControls) then return end
    for _, c in ipairs(controlLevers()) do
        local want = wantControls[c.key]
        if want and math.abs(c.lever.Value - want) > 0.001 then
            local ok, err = pcall(function() c.lever:SetValue(want, false) end)
            if not ok then log("båt: spak %s: %s", c.key, tostring(err)) end
        end
    end
    wantControls = {}
end

function M.init(netModule, logFn, localPCFn, nowFn, host)
    net, log, localPC, now, isHost = netModule, logFn, localPCFn, nowFn, host
    startLoop()
end

-- Before anyone has driven, the host's boat is the one that counts.
function M.peerControls(key)
    local p = peerAuthority[key]
    if p == nil then return not isHost end
    return p
end

-- Only saved boats with a root: the level also holds an empty placeholder
-- barge, and attaching the puppet to it crashed the game.
local function usable(key, b)
    if key:sub(1, 2) ~= "id" or not b:IsValid() then return false end
    local ok, root = pcall(function() return b.RootComponent end)
    return ok and root and root:IsValid()
end

function M.list()
    local out = {}
    for key, b in pairs(boats) do
        if usable(key, b) then out[key] = b end
    end
    return out
end

function M.isBoat(actor)
    local bc = boatClass()
    return bc ~= nil and actor ~= nil and actor:IsValid() and actor:IsA(bc)
end
M.keyOf = keyOf
function M.find(key)
    local b = boats[key]
    if b and usable(key, b) then return b end
end

function M.tick()
    scan()
    pcall(orderTicks)
    local anyPeer = false
    -- Only saved boats count; the level also holds an empty placeholder barge.
    for key in pairs(boats) do if key:sub(1, 2) == "id" and M.peerControls(key) then anyPeer = true end end
    if anyPeer then pcall(applyControls) else pcall(sendControls) end
    local myKey, myBoat = drivenKey()
    tickMyKey = myKey
    if myKey and not boats[myKey] then boats[myKey] = myBoat end
    for key, actor in pairs(boats) do
        if actor:IsValid() then
            if key == myKey then
                if peerAuthority[key] ~= false then
                    setHullPhysics(key, actor, true)
                    stillBody(actor)
                    log("båt %s: jag kör, jag styr (gas %.3f roder %.3f)", key,
                        control(actor, "GetThrottleActual"), control(actor, "GetSteeringActual"))
                    local r = remote[key]
                    if peerAuthority[key] == true and r and r.throttle then
                        catchup[key] = { throttle = r.throttle, steer = r.steer or 0, untilT = now() + CATCHUP_SECONDS,
                            path = actor:GetFullName():match("%S+%s+(%S+)") }
                        log("båt %s: ställer in den förra förarens gas %.3f roder %.3f", key, r.throttle, r.steer or 0)
                    end
                    -- Looked up again by path: a UObject kept to a later tick has crashed UE4SS.
                    local path = actor:GetFullName():match("%S+%s+(%S+)")
                    ExecuteInGameThreadWithDelay(1500, function()
                        pcall(function()
                            local a = StaticFindObject(path)
                            if a and a:IsValid() then
                                log("båt %s: 1,5 s efter övertagandet gas %.3f roder %.3f", key,
                                    control(a, "GetThrottleActual"), control(a, "GetSteeringActual"))
                            end
                        end)
                    end)
                end
                setOwnMovement(key, actor, true)
                peerAuthority[key] = false
                if usable(key, actor) then pcall(updateHold, key, actor, true) end
                sendState(key, actor, true)
            elseif not M.peerControls(key) then
                if not (hold[key] and hold[key].x) then setHullPhysics(key, actor, true) end
                if usable(key, actor) then
                    local okH, errH = pcall(updateHold, key, actor, false)
                    if not okH then log("båt-förtöjningsfel: %s", tostring(errH)) end
                end
                sendState(key, actor, false)
            elseif remote[key] and now() - remote[key].t > 1.0 then
                log("båt %s: inga uppdateringar, släpper", key)
                remote[key] = nil
            end
        end
    end
end

-- Taking the boat without driving it (power.lua, on handling a mooring line):
-- this game's boat moves itself and the other follows. Not while the other
-- player is driving, and not with throttle left in this game's boat (the
-- throttle stays from when this game last drove, and the boat would sail off).
local CLAIM_THROTTLE = 0.05
function M.claim(why)
    for key, actor in pairs(boats) do
        if key:sub(1, 2) == "id" and actor:IsValid() and M.peerControls(key) then
            local r = remote[key]
            if r and r.driving and now() - r.t < 1.0 then
                log("båt %s: %s, den andra kör, tar inte över", key, why)
            elseif math.abs(control(actor, "GetThrottleActual")) > CLAIM_THROTTLE then
                log("båt %s: %s, gas %.3f kvar här, tar inte över", key, why, control(actor, "GetThrottleActual"))
            else
                peerAuthority[key] = false
                setHullPhysics(key, actor, true)
                stillBody(actor)
                net.send("bclaim", key)
                sendState(key, actor, false)
                log("båt %s: %s, jag styr nu", key, why)
            end
        end
    end
end

function M.handle(msg)
    if msg[1] == "bctl" then
        wantControls[msg[3]] = tonumber(msg[4])
        return true
    end
    if msg[1] == "bclaim" then
        if peerAuthority[msg[3]] ~= true then
            peerAuthority[msg[3]] = true
            log("båt %s: den andra tog över (förtöjning), den andra styr", msg[3])
        end
        return true
    end
    if msg[1] ~= "boat" then return false end
    local seq, key = tonumber(msg[2]), msg[3]
    local prev = remote[key]
    if prev and seq and seq <= prev.seq and seq > prev.seq - 50 then return true end
    local n = {}
    for i = 4, 13 do n[i] = tonumber(msg[i]) end
    if not (n[4] and n[5] and n[6] and n[8]) then return true end
    if msg[15] == "1" and peerAuthority[key] ~= true then
        peerAuthority[key] = true
        log("båt %s: den andra kör, den andra styr", key)
    end
    if not boats[key] and not prev then log("båt %s från den andra, finns inte här än", key) end
    local st = tonumber(msg[16]) or now()
    local off = now() - st
    -- The smallest delay seen is the clock difference; both games run on the
    -- same kind of clock, so it does not drift.
    if not clockOffset[key] or off < clockOffset[key] then clockOffset[key] = off end
    local buf = (prev and prev.buf) or {}
    if #buf > 0 and st < buf[#buf].st - 5 then buf = {} end   -- sender restarted
    buf[#buf + 1] = { st = st, off = off, x = n[4], y = n[5], z = n[6], pitch = n[7] or 0, yaw = n[8], roll = n[9] or 0 }
    while #buf > 30 do table.remove(buf, 1) end
    remote[key] = {
        seq = seq or 0, t = now(), buf = buf, throttle = tonumber(msg[17]), steer = tonumber(msg[18]),
        anchors = msg[14] == "1", driving = msg[15] == "1",
        -- Kept across messages: reset with each one, the follower lifted the
        -- anchors 20 times a second (2026-11-18).
        anchorsSeen = prev and prev.anchorsSeen, anchorsAt = prev and prev.anchorsAt, anchorsLogged = prev and prev.anchorsLogged,
    }
    return true
end

return M
