-- Weather and time of day follow the host. Storms and other dynamic weather are
-- volumes (WeatherVolumeActor) that BP_DynamicWeatherSpawner places at random
-- around the player, so each game would roll its own. The guest's spawners are
-- stopped (MaxActive 0); the host sends its dynamic volumes and the guest
-- mirrors them: volumes from the shared save have the same save id in both
-- games, later ones are summoned. Exactness is not the goal, matching storms is.
local M = {}

local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local SEND_SECONDS = 2
local MOVE_TOLERANCE = 1000       -- cm
local CURVE_TOLERANCE = 10        -- s
local TIME_TOLERANCE = 60

local net, log, localPC, now, props, console, isHost
local lastSend, lastProbe, lastMirror = 0, -100, -100
local hostVolumes, hostListAt = {}, nil   -- key -> state, time of last list
local mirrors = {}                        -- host key -> local actor path
local pendingSummon                       -- { key, class, before, t }
local stoppedSpawners = {}

local function pathOf(obj) return obj:GetFullName():match("%S+%s+(%S+)") end
local function f1(v) return string.format("%.1f", type(v) == "number" and v or 0) end

local function saveId(actor)
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then
        local id = pc.PersistentUniqueId
        if id and id ~= 0 then return tostring(id) end
    end
end

local function find(className)
    local ok, found = pcall(FindObjects, 0, className, "", 0, 0x10, false)
    local list = {}
    for _, a in ipairs((ok and found) or {}) do
        local okV, valid = pcall(function() return a:IsValid() and not a:GetFullName():find("Default__", 1, true) end)
        if okV and valid then list[#list + 1] = a end
    end
    return list
end

local function volumeOf(v)
    return v:GetComponentByClass(StaticFindObject("/Script/Voyage.VoyageWeatherVolume"))
end

local function asset(path)
    if not path or path == "-" then return nil end
    local a = StaticFindObject(path)
    if not (a and a:IsValid()) then pcall(LoadAsset, path) a = StaticFindObject(path) end
    if a and a:IsValid() then return a end
end

local function dynamicVolumes()
    local list = {}
    for _, v in ipairs(find("WeatherVolumeActor_C")) do
        local ok, dyn = pcall(function() return v.Dynamic end)
        -- A volume whose curve has run out sits at 0 0 without a save id
        -- until the game removes it. Mirrored, the guest made a copy of it and
        -- then removed one every half second (2026-11-17, the guest's screen
        -- jolting in the weather).
        local okE, ended = pcall(function()
            local l = v:K2_GetActorLocation()
            return v.CurrentTime >= v.CurveLengthSeconds or (l.X == 0 and l.Y == 0)
        end)
        if ok and dyn and not (okE and ended) then list[#list + 1] = v end
    end
    return list
end

local function worldTime()
    local t = find("BP_PersistentWorldTime_C")[1]
    return t
end

local function describe(v)
    local l = v:K2_GetActorLocation()
    local parts = { v:GetClass():GetFName():ToString(), saveId(v) or "-",
        string.format("%.0f %.0f", l.X, l.Y) }
    pcall(function()
        parts[#parts + 1] = string.format("kurva %.0f/%.0f x%.2f", v.CurrentTime, v.CurveLengthSeconds, v.CurveMultiplier)
    end)
    pcall(function()
        local vol = v:GetComponentByClass(StaticFindObject("/Script/Voyage.VoyageWeatherVolume"))
        local preset = vol.WeatherPreset
        parts[#parts + 1] = string.format("r %.0f prio %.1f mult %.2f nederbörd %.2f åska %.2f moln %.2f vind %.0f %s",
            vol.Radius, vol.Priority, vol.Multiplier, vol.Climate.Precipitation, vol.Climate.Thunder,
            vol.Climate.CloudCoverage, vol.Wind.SpeedInKm,
            preset and preset:IsValid() and preset:GetFName():ToString() or "-")
    end)
    return table.concat(parts, " | ")
end

local function probe()
    if now() - lastProbe < 30 then return end
    lastProbe = now()
    for _, s in ipairs(find("BP_DynamicWeatherSpawner_C")) do
        pcall(function()
            local l = s:K2_GetActorLocation()
            log("väder: spawner %s max %d aktiva %d radie %.0f/%.0f runt spelaren %s vid %.0f %.0f",
                s:GetFName():ToString(), s.MaxActive, #s.SpawnedWeatherVolumes, s.SpawnRadius, s.ActiveRadius,
                tostring(s.SpawnAroundPlayer), l.X, l.Y)
        end)
    end
    for _, v in ipairs(dynamicVolumes()) do log("väder: volym %s", describe(v)) end
    local t = worldTime()
    if t then pcall(function() log("väder: världstid %.1f offset %.1f", t.WorldTime, t.TimeOffset) end) end
    pcall(function()
        local sub = find("VoyageWeatherSubsystem")[1]
        local c = sub.CurrentClimate
        log("väder: här nu nederbörd %.2f åska %.2f moln %.2f dimma %.2f vind %.0f km/h",
            c.Precipitation, c.Thunder, c.CloudCoverage, c.FogDensity, sub.CurrentWind.SpeedInKm)
    end)
end

-- Host ---------------------------------------------------------------------

local function keyOf(v) return saveId(v) or ("p" .. pathOf(v)) end

local function sendAll()
    if now() - lastSend < SEND_SECONDS then return end
    lastSend = now()
    local keys = {}
    for _, v in ipairs(dynamicVolumes()) do
        local ok, err = pcall(function()
            local key = keyOf(v)
            local l, r = v:K2_GetActorLocation(), v:K2_GetActorRotation()
            local vol = volumeOf(v)
            local preset, curve = vol.WeatherPreset, v.WeatherCurve
            net.send("wvol", key, pathOf(v:GetClass()), f1(l.X), f1(l.Y), f1(l.Z), f1(r.Yaw),
                f1(v.CurrentTime), f1(v.CurveLengthSeconds), string.format("%.3f", v.CurveMultiplier),
                preset and preset:IsValid() and pathOf(preset) or "-", curve and curve:IsValid() and pathOf(curve) or "-",
                f1(vol.Radius), f1(vol.Height), f1(vol.InterpolationRange), string.format("%.3f", tonumber(vol.Priority) or 0), tonumber(vol.WeatherMask) or "",
                string.format("%.3f", tonumber(vol.Multiplier) or 0))
            keys[#keys + 1] = key
        end)
        if not ok then log("väder-sändfel: %s", tostring(err)) end
    end
    net.send("wvols", table.concat(keys, ","))
    local t = worldTime()
    if t then pcall(function() net.send("wtime", f1(t.WorldTime)) end) end
end

-- Guest --------------------------------------------------------------------

local function stopSpawners()
    for _, s in ipairs(find("BP_DynamicWeatherSpawner_C")) do
        local p = pathOf(s)
        local ok, max = pcall(function() return s.MaxActive end)
        if ok and max ~= 0 then
            s.MaxActive = 0
            if not stoppedSpawners[p] then log("väder: stoppar egen spawner %s (max %d)", s:GetFName():ToString(), max) end
            stoppedSpawners[p] = true
        end
    end
end

local function localByKey(key)
    local path = mirrors[key]
    if path then
        local a = StaticFindObject(path)
        if a and a:IsValid() then return a end
        mirrors[key] = nil
    end
    for _, v in ipairs(dynamicVolumes()) do
        if keyOf(v) == key then return v end
    end
end

local function destroy(v, why)
    local id = saveId(v)
    if id then props.suppressGone(id) end
    log("väder: tar bort %s (%s)", describe(v), why)
    v:K2_DestroyActor()
end

local function apply(v, s)
    local l = v:K2_GetActorLocation()
    local d = math.sqrt((l.X - s.x) ^ 2 + (l.Y - s.y) ^ 2)
    if d > MOVE_TOLERANCE then
        v:K2_SetActorLocationAndRotation({ X = s.x, Y = s.y, Z = s.z }, { Pitch = 0, Yaw = s.yaw, Roll = 0 }, false, {}, true)
    end
    if math.abs((v.CurrentTime or 0) - s.time) > CURVE_TOLERANCE then v.CurrentTime = s.time end
    if v.CurveLengthSeconds ~= s.len then v.CurveLengthSeconds = s.len end
    if math.abs((v.CurveMultiplier or 0) - s.mult) > 0.01 then v.CurveMultiplier = s.mult end
    -- The spawner sets these after spawning; a summoned copy has the defaults.
    local vol = volumeOf(v)
    local preset = asset(s.preset)
    if preset and not (vol.WeatherPreset and vol.WeatherPreset:IsValid() and pathOf(vol.WeatherPreset) == s.preset) then
        vol.WeatherPreset = preset
        pcall(function()
            vol.Climate = preset.Climate
            vol.Wind = preset.Wind
            vol.WaveProperties = preset.WaveProperties
        end)
        log("väder: %s får förinställningen %s", s.key, preset:GetFName():ToString())
    end
    local curve = asset(s.curve)
    if curve and not (v.WeatherCurve and v.WeatherCurve:IsValid() and pathOf(v.WeatherCurve) == s.curve) then
        v.WeatherCurve = curve
    end
    if s.radius and math.abs(vol.Radius - s.radius) > 1 then vol.Radius = s.radius end
    if s.height and math.abs(vol.Height - s.height) > 1 then vol.Height = s.height end
    if s.interp and math.abs(vol.InterpolationRange - s.interp) > 1 then vol.InterpolationRange = s.interp end
    if s.prio and math.abs(vol.Priority - s.prio) > 0.001 then vol.Priority = s.prio end
    if s.mask and vol.WeatherMask ~= s.mask then vol.WeatherMask = s.mask end
    -- A summoned copy does not run the curve or move itself; the strength and
    -- position come from the host.
    if s.strength and math.abs(vol.Multiplier - s.strength) > 0.005 then
        vol.Multiplier = s.strength
        vol.Modified = true
    end
end

local function adoptSummon()
    local p = pendingSummon
    if not p or now() - p.t < 0.5 then return end
    for _, v in ipairs(find(p.className)) do
        if not p.before[v:GetAddress()] then
            pendingSummon = nil
            mirrors[p.key] = pathOf(v)
            pcall(function() v.Dynamic = true end)
            log("väder: kopia av %s skapad: %s", p.key, pathOf(v))
            local s = hostVolumes[p.key]
            if s then pcall(apply, v, s) end
            return
        end
    end
    if now() - p.t > 5 then
        log("väder: summon %s gav ingen volym", p.className)
        pendingSummon = nil
    end
end

local function mirror()
    stopSpawners()
    adoptSummon()
    if not hostListAt then return end
    for key, s in pairs(hostVolumes) do
        local v = localByKey(key)
        if v then
            local ok, err = pcall(apply, v, s)
            if not ok then log("väder-fel %s: %s", key, tostring(err)) end
        elseif not pendingSummon then
            local className = s.class:match("%.([^%.]+)$") or s.class
            local before = {}
            for _, a in ipairs(find(className)) do before[a:GetAddress()] = true end
            if not StaticFindObject(s.class) then pcall(LoadAsset, (s.class:gsub("_C$", ""))) end
            pendingSummon = { key = key, className = className, before = before, t = now() }
            console("summon " .. className)
            log("väder: skapar kopia av värdens %s (%s)", key, className)
        end
    end
    local wanted = {}
    for key in pairs(hostVolumes) do
        local v = localByKey(key)
        if v then wanted[v:GetAddress()] = true end
    end
    for _, v in ipairs(dynamicVolumes()) do
        if not wanted[v:GetAddress()] and not (pendingSummon and now() - pendingSummon.t < 1) then
            pcall(destroy, v, "finns inte hos värden")
        end
    end
end

-- --------------------------------------------------------------------------

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, consoleFn, host)
    net, log, localPC, now, props, console, isHost = netModule, logFn, localPCFn, nowFn, propsModule, consoleFn, host
end

function M.reset()
    hostVolumes, hostListAt, mirrors, pendingSummon, stoppedSpawners, lastProbe = {}, nil, {}, nil, {}, -100
end

function M.tick()
    pcall(probe)
    if isHost then sendAll()
    elseif now() - lastMirror >= 1 then
        lastMirror = now()
        mirror()
    end
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "wvol" then
        if isHost then return true end
        hostVolumes[msg[3]] = {
            class = msg[4], x = tonumber(msg[5]), y = tonumber(msg[6]), z = tonumber(msg[7]), yaw = tonumber(msg[8]) or 0,
            time = tonumber(msg[9]) or 0, len = tonumber(msg[10]) or 0, mult = tonumber(msg[11]) or 1,
            preset = msg[12], curve = msg[13], radius = tonumber(msg[14]), height = tonumber(msg[15]),
            interp = tonumber(msg[16]), prio = tonumber(msg[17]), mask = tonumber(msg[18]), strength = tonumber(msg[19]), key = msg[3],
        }
        return true
    elseif kind == "wvols" then
        if isHost then return true end
        local keep = {}
        for key in (msg[3] or ""):gmatch("[^,]+") do keep[key] = true end
        for key in pairs(hostVolumes) do
            if not keep[key] then hostVolumes[key] = nil end
        end
        hostListAt = now()
        return true
    elseif kind == "wtime" then
        if isHost then return true end
        local t, want = worldTime(), tonumber(msg[3])
        if t and want then
            local diff = t.WorldTime - want
            if math.abs(diff) > TIME_TOLERANCE then
                log("väder: världstid %.0f -> %.0f (värdens)", t.WorldTime, want)
                t.WorldTime = want
            end
        end
        return true
    end
    return false
end

return M
