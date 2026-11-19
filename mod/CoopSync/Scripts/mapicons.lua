-- Radar map markers (VoyageMapIconSubsystem.Icons: IconId + 2D location).
-- Each side reads its own list every second; markers that came or went are
-- sent (icon|+ or icon|-) and the other adds or removes the same marker.
local M = {}

local POLL_EVERY = 1

local net, log, now
local subPath
local known, lastPoll = nil, -100

local function subsystem()
    local s = subPath and StaticFindObject(subPath)
    if s and s:IsValid() then return s end
    local found = FindFirstOf("VoyageMapIconSubsystem")
    if found and found:IsValid() then
        subPath = found:GetFullName():match("%S+%s+(%S+)")
        return found
    end
end

local function keyOf(id, x, y) return string.format("%s@%.0f,%.0f", id, x, y) end

local function read(s)
    local list = {}
    s.Icons:ForEach(function(i, e)
        local v = e:get()
        local id, l = v.IconId:ToString(), v.Location
        list[#list + 1] = { index = i - 1, id = id, x = l.X, y = l.Y, key = keyOf(id, l.X, l.Y) }
    end)
    return list
end

local function poll()
    local s = subsystem()
    if not s then return end
    local list = read(s)
    local set = {}
    for _, ic in ipairs(list) do set[ic.key] = ic end
    if known then
        for k, ic in pairs(set) do
            if not known[k] then net.send("icon", "+", ic.id, string.format("%.1f", ic.x), string.format("%.1f", ic.y)) end
        end
        for k, ic in pairs(known) do
            if not set[k] then net.send("icon", "-", ic.id, string.format("%.1f", ic.x), string.format("%.1f", ic.y)) end
        end
    end
    known = set
end

local function applyIcon(op, id, x, y)
    local s = subsystem()
    if not s then return end
    local key = keyOf(id, x, y)
    local list = read(s)
    if op == "+" then
        for _, ic in ipairs(list) do if ic.key == key then return end end
        s:AddIcon(FName(id), { X = x, Y = y })
        log("karta: markering %s från den andra", key)
    else
        for _, ic in ipairs(list) do
            if ic.key == key then
                s:RemoveIcon(ic.index)
                log("karta: tog bort markering %s som den andra", key)
                break
            end
        end
    end
    known = known or {}
    if op == "+" then known[key] = { id = id, x = x, y = y, key = key } else known[key] = nil end
end

function M.init(netModule, logFn, nowFn)
    net, log, now = netModule, logFn, nowFn
end

function M.reset() known, subPath, lastPoll = nil, nil, -100 end

function M.tick()
    if now() - lastPoll < POLL_EVERY then return end
    lastPoll = now()
    poll()
end

function M.handle(msg)
    if msg[1] ~= "icon" then return false end
    local x, y = tonumber(msg[5]), tonumber(msg[6])
    if msg[4] and x and y then
        local ok, err = pcall(applyIcon, msg[3], msg[4], x, y)
        if not ok then log("karta-fel: %s", tostring(err)) end
    end
    return true
end

return M
