-- Paint on the boats. A boat's paint is an inventory (VoyagePaintInventoryComponent)
-- with one slot per part (deck, tower, hull, flag) holding a paint item; putting
-- an item in a slot with AddToSlot repaints the part at once (tested
-- 2026-11-18). Each game polls its boats and sends a changed set of slots; the
-- other puts the same items in the same slots. On first sight the host sends
-- its paint, so the guest's boat starts out like the host's.
local M = {}
local net, log, now, isHost

local CLS = "/Script/Voyage.VoyagePaintInventoryComponent"
local POLL_SECONDS = 1
local lastPoll = -100
local seen = {}          -- boat key -> slot state last seen or applied
local waiting = {}       -- boat key -> state received before the boat was here

local function pathOf(o) return o:GetFullName():match("%S+%s+(%S+)") end

local function invOf(actor)
    local inv = actor:GetComponentByClass(StaticFindObject(CLS))
    if inv and inv:IsValid() then return inv end
end

local function slots(inv)
    local out = {}
    for _, i in ipairs(inv:GetAllPaintSlotIndices() or {}) do
        out[#out + 1] = type(i) == "number" and i or i:get()
    end
    table.sort(out)
    return out
end

local function stateOf(inv)
    local parts = {}
    for _, i in ipairs(slots(inv)) do
        local it = inv:GetPaintInSlot(i)
        parts[#parts + 1] = i .. "=" .. ((it and it:IsValid()) and pathOf(it) or "-")
    end
    return table.concat(parts, ";")
end

local function loadItem(path)
    local it = StaticFindObject(path)
    if it and it:IsValid() then return it end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and loaded and loaded:IsValid() then return loaded end
end

local function apply(key, inv, st)
    for slot, path in st:gmatch("(%d+)=([^;]+)") do
        local i = tonumber(slot)
        local cur = inv:GetPaintInSlot(i)
        local curPath = (cur and cur:IsValid()) and pathOf(cur) or "-"
        if curPath ~= path then
            if inv:IsSlotOccupied(i) then inv:RemoveSlot(i, 1, true) end
            local added = 0
            if path ~= "-" then
                local item = loadItem(path)
                if item then added = inv:AddToSlot(item, i, { ItemCount = 1 }, true) end
            end
            log("färg %s: plats %d %s -> %s%s", key, i, curPath:match("[^.]+$"), path:match("[^.]+$"),
                (path ~= "-" and added < 1) and " (gick inte)" or "")
        end
    end
    seen[key] = stateOf(inv)
end

function M.init(netModule, logFn, nowFn, hostFn)
    net, log, now, isHost = netModule, logFn, nowFn, hostFn
end

function M.tick()
    if now() - lastPoll < POLL_SECONDS then return end
    lastPoll = now()
    local boat = require("boat")
    for key, b in pairs(boat.list()) do
        if key:sub(1, 2) == "id" and b:IsValid() then
            local inv = invOf(b)
            if inv then
                if waiting[key] then
                    apply(key, inv, waiting[key])
                    waiting[key] = nil
                end
                local st = stateOf(inv)
                if seen[key] == nil then
                    seen[key] = st
                    if isHost() then net.send("paint", key, st) end
                elseif st ~= seen[key] then
                    seen[key] = st
                    net.send("paint", key, st)
                    log("färg %s: ändrad här, skickad (%s)", key, (st:gsub("/Game/Data/Assets/Items/Paints/", "")))
                end
            end
        end
    end
end

function M.handle(msg)
    if msg[1] == "ready" then
        if isHost() then M.resend() end
        return false
    end
    if msg[1] ~= "paint" then return false end
    local key, st = msg[3], msg[4] or ""
    local b = require("boat").find(key)
    local inv = b and invOf(b)
    if inv then apply(key, inv, st) else waiting[key] = st end
    return true
end

-- A guest that (re)joins gets the host's paint again.
function M.resend()
    for key in pairs(seen) do seen[key] = nil end
end

function M.reset()
    seen, waiting, lastPoll = {}, {}, -100
end

return M
