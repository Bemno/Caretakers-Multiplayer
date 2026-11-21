-- Door sync: both players may open and close doors. Local changes to a
-- BP_DoorBase_C are sent as door state and position; received ones are replayed
-- through the same functions. Doors are matched by object path, which is the
-- same in both games because both load the same save.
local M = {}

local DOOR = "/Game/Blueprints/Modules/Utility/Door/BP_DoorBase.BP_DoorBase_C"

local net, log
local applying = false
local pendingPos = {}
local lastSentPos = {}
local missing = {}

local function pathOf(door)
    return door:GetFullName():match("%S+%s+(%S+)")
end

local function findDoor(path)
    local door = StaticFindObject(path)
    if door and door:IsValid() then return door end
    if not missing[path] then
        missing[path] = true
        log("dörr saknas här: %s", path)
    end
    return nil
end

local hooked, lastTry = false, 0

function M.init(netModule, logFn)
    net, log = netModule, logFn
end

-- The door blueprint is only loaded with the world, so hooking is retried.
local function ensureHooks()
    if hooked or os.time() - lastTry < 5 then return end
    lastTry = os.time()
    local cls = StaticFindObject(DOOR)
    if not (cls and cls:IsValid()) then return end
    hooked = true
    local okState = pcall(RegisterHook, DOOR .. ":SetDoorState", function(self, newState)
        if applying then return end
        local door = self:get()
        net.send("doorstate", pathOf(door), newState:get())
    end)
    local okPos = pcall(RegisterHook, DOOR .. ":SetDoorPosition", function(self, position, forced)
        if applying then return end
        pendingPos[pathOf(self:get())] = position:get()
    end)
    log("dörrsynk: hookar state=%s pos=%s", tostring(okState), tostring(okPos))
end

-- Positions change every frame while a door is dragged; send at most once per
-- tick and only when it actually moved.
function M.flush()
    ensureHooks()
    for path, pos in pairs(pendingPos) do
        local last = lastSentPos[path]
        if not last or math.abs(last - pos) > 0.002 then
            net.send("doorpos", path, string.format("%.4f", pos))
            lastSentPos[path] = pos
        end
    end
    pendingPos = {}
end

function M.handle(msg)
    local kind = msg[1]
    if kind ~= "doorstate" and kind ~= "doorpos" then return false end
    local door = findDoor(msg[3])
    if not door then return true end
    applying = true
    local ok, err = pcall(function()
        if kind == "doorstate" then
            door:SetDoorState(tonumber(msg[4]))
        else
            door:SetDoorPosition(tonumber(msg[4]), true)
        end
    end)
    applying = false
    if not ok then log("dörrfel %s: %s", kind, tostring(err)) end
    return true
end

-- A new world in the same game run; the hooks stay registered.
function M.reset()
    applying, pendingPos, lastSentPos, missing = false, {}, {}, {}
end

return M
