-- Repairs. A module (a broken solar panel on a quay) repaired in one game
-- stayed broken in the other (2026-11-16). Modules near the own player are
-- watched; when one's durability rises the new value is sent (rep) and the
-- other game repairs its module up to it with the game's own Repair.
-- Durability lost over time is left to each game.
local M = {}

local MODULE_CLASS = "/Script/Voyage.VoyageModuleComponent"
local NEAR = 2000           -- cm: repairing is done standing next to a module
local SCAN_EVERY = 5
local POLL_EVERY = 0.5
local RISE = 0.5            -- durability units counted as a repair

local net, log, localPC, now, props, boxes
local near = {}             -- module component path -> last durability seen
local lastScan, lastPoll = -100, -100
local echo = {}             -- module component path -> durability set from the other game

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function scan()
    lastScan = now()
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return end
    local p = pawn:K2_GetActorLocation()
    local found = {}
    local ok, comps = pcall(FindObjects, 0, "VoyageModuleComponent", "", 0, 0x10, false)
    for _, c in ipairs((ok and comps) or {}) do
        pcall(function()
            if not c:IsValid() then return end
            -- Templates first: calls on them have crashed the game.
            local path = pathOf(c)
            if path:find("Default__", 1, true) or path:find("_GEN_VARIABLE", 1, true) then return end
            local owner = c:GetOwner()
            if not (owner and owner:IsValid()) then return end
            local l = owner:K2_GetActorLocation()
            if (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < NEAR * NEAR then
                found[path] = near[path] or c:GetDurability()
            end
        end)
    end
    near = found
end

local function poll()
    lastPoll = now()
    for path, last in pairs(near) do
        local c = StaticFindObject(path)
        if c and c:IsValid() then
            local ok, d = pcall(function() return c:GetDurability() end)
            if ok and d then
                if d > last + RISE and not (echo[path] and math.abs(echo[path] - d) < RISE) then
                    local id = boxes.idOfActor(c:GetOwner())
                    if id then
                        net.send("rep", props.wire(id), string.format("%.2f", d))
                        log("lagning: %s %.1f -> %.1f av %.1f, skickad", c:GetOwner():GetFName():ToString(), last, d,
                            c:GetMaxDurability())
                    end
                end
                near[path] = d
            end
        else
            near[path] = nil
        end
    end
end

local function apply(id, target)
    local pc = props.findById(id)
    local owner = pc and pc:IsValid() and pc:GetOwner()
    if not (owner and owner:IsValid()) then log("lagning: modul %s finns inte här", tostring(id)) return end
    local c = owner:GetComponentByClass(StaticFindObject(MODULE_CLASS))
    if not (c and c:IsValid()) then log("lagning: %s har ingen modulkomponent", tostring(id)) return end
    local before = c:GetDurability()
    if before >= target - 0.1 then return end
    local path = pathOf(c)
    echo[path] = target
    local ok, err = pcall(function() c:Repair(target - before) end)
    local after = c:GetDurability()
    -- Repair may take a share instead of units; then the rest goes in once more.
    if ok and after < target - 0.1 and after > before then
        pcall(function() c:Repair((target - after) * (target - before) / (after - before)) end)
        after = c:GetDurability()
    end
    if near[path] then near[path] = after end
    log("lagning: %s %.1f -> %.1f (mål %.1f, trasig %s): %s", owner:GetFName():ToString(), before, after, target,
        tostring(c:IsBroken()), ok and "ok" or tostring(err))
end

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, boxesModule)
    net, log, localPC, now, props, boxes = netModule, logFn, localPCFn, nowFn, propsModule, boxesModule
end

function M.reset() near, echo, lastScan, lastPoll = {}, {}, -100, -100 end

function M.tick()
    if now() - lastScan >= SCAN_EVERY then scan() end
    if now() - lastPoll >= POLL_EVERY then poll() end
end

function M.handle(msg)
    if msg[1] ~= "rep" then return false end
    apply(msg[3], tonumber(msg[4]) or 0)
    return true
end

return M
