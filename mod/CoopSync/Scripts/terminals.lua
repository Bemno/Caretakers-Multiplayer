-- Terminals: the screen style (StyleIndex, changed with InteractAction) is
-- read every second and sent when it changes; the other sets the same style
-- and runs OnStyleChanged as the game does. Focus and camera stay local.
local M = {}

local CLASS = "^BP_Module_Terminal_C$"
local SCAN_EVERY, POLL_EVERY = 5, 1

local net, log, now, boxes, props
local terms, known = {}, {}       -- { path, id }, id -> style
local lastScan, lastPoll = -100, -100

local function scan()
    terms = {}
    for _, a in ipairs(boxes.modulesNamed(CLASS)) do
        pcall(function()
            local full = a:GetFullName():match("%S+%s+(%S+)")
            local id = boxes.idOfActor(a)
            if id then terms[#terms + 1] = { path = full, id = id } end
        end)
    end
end

function M.init(netModule, logFn, nowFn, boxesModule, propsModule)
    net, log, now, boxes, props = netModule, logFn, nowFn, boxesModule, propsModule
end

function M.reset() terms, known, lastScan, lastPoll = {}, {}, -100, -100 end

function M.tick()
    if now() - lastPoll < POLL_EVERY then return end
    lastPoll = now()
    if now() - lastScan >= SCAN_EVERY then lastScan = now() scan() end
    for _, t in ipairs(terms) do
        local a = StaticFindObject(t.path)
        if a and a:IsValid() then
            local okS, style = pcall(function() return a.StyleIndex end)
            if okS and type(style) == "number" then
                if known[t.id] ~= nil and known[t.id] ~= style then
                    net.send("term", props.wire(t.id), style)
                    log("terminal: %s stil %d", t.id, style)
                end
                known[t.id] = style
            end
        end
    end
end

function M.handle(msg)
    if msg[1] ~= "term" then return false end
    local style = tonumber(msg[4])
    local pc = props.findById(msg[3])
    local a = pc and pc:IsValid() and pc:GetOwner()
    if not (a and a:IsValid() and style) then log("terminal: %s finns inte här", tostring(msg[3])) return true end
    local localId = boxes.idOfActor(a) or msg[3]
    known[localId] = style
    a.StyleIndex = style
    local ok, err = pcall(function() a:OnStyleChanged(style) end)
    log("terminal: %s stil %d från den andra: %s", localId, style, ok and "ok" or tostring(err))
    return true
end

return M
