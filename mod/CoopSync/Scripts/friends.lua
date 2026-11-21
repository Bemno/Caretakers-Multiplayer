-- Friend list: Steam ids (udp:<port> on the test bench) with a state of their
-- own. Two players see each other's status only when both have approved:
-- adding someone sends a request, the other approves it in the menu.
-- Status comes from asking the friend's coopnet directly (channel 1), so it
-- works when the friend shows as offline or invisible in Steam.
-- File: io\<name>\vanner.txt, one line per friend: id|name|state, state one
-- of ok, vantar (request sent), nekad, inkommen (request received),
-- borttagen (the friend removed us).
local M = {}
local T = require("text")

local ASK_EVERY = 5         -- status rounds while the friend list is open
local ONLINE_SECONDS = 12   -- a friend who answered this recently is online
local RESEND_EVERY = 30     -- requests and our own state go out again
local RANK = { host = 1, full = 2, guest = 3, menu = 4 }

local net, log, lobby, path
M.entries = {}              -- id -> entry
M.message = nil             -- last error for the menu (bad id)
local active = false
local lastAsk, lastResend = -100, -100
local sentState

local function save()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    for id, e in pairs(M.entries) do
        f:write(id, "|", (e.name or ""):gsub("[|\r\n]", "/"), "|", e.state, "\n")
    end
    f:close()
    os.remove(path)
    os.rename(tmp, path)
end

local function sendApproved()
    local ids = {}
    for id, e in pairs(M.entries) do if e.state == "ok" then ids[#ids + 1] = id end end
    net.send("steam", "approved", table.concat(ids, ","))
end

local function changed()
    save()
    sendApproved()
end

local function nextName()
    local n = 1
    for _ in pairs(M.entries) do n = n + 1 end
    return T("friend_n", n)
end

local function q(id, ...) net.send("steam", "qsend", id, ...) end

local function request(id) q(id, "req", lobby.playerName) end

local function newEntry(id, name, state)
    local given = name and name ~= ""
    -- auto: the name is ours ("Friend 3") until Steam tells the real one.
    local e = { id = id, name = given and name or nextName(), state = state, auto = not given }
    M.entries[id] = e
    if not given and not id:match("^udp:") then net.send("steam", "name", id) end
    return e
end

function M.addId(id, name)
    if not id or id == "" or id == lobby.me then M.message = T("bad_id") return false end
    M.message = nil
    local e = M.entries[id]
    if not e then
        newEntry(id, name, "vantar")
        request(id)
    elseif e.state == "inkommen" then
        e.state = "ok"
        q(id, "ok")
    elseif e.state == "nekad" or e.state == "borttagen" then
        e.state = "vantar"
        request(id)
    end
    changed()
    return true
end

-- Typed text (id, invite code, profile address) goes to coopnet to be read.
function M.add(text)
    text = (text or ""):gsub("[|\r\n]", "")
    net.send("steam", "resolve", text)
end

function M.approve(id)
    local e = M.entries[id]
    if not e then return end
    e.state = "ok"
    q(id, "ok")
    changed()
end

function M.decline(id)
    q(id, "no")
    M.entries[id] = nil
    changed()
end

function M.remove(id)
    local e = M.entries[id]
    if e and (e.state == "ok" or e.state == "vantar") then q(id, "bye") end
    M.entries[id] = nil
    changed()
end

function M.rename(id, name)
    local e = M.entries[id]
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not e or name == "" then return false end
    e.name, e.auto = name, false
    save()
    return true
end

function M.online(e)
    return e.seen ~= nil and os.time() - e.seen < ONLINE_SECONDS
end

-- What the list shows for a friend: hosting, in the menu, waiting...
function M.statusOf(e)
    if e.state == "vantar" then return "waiting" end
    if e.state == "nekad" then return "declined" end
    if e.state == "borttagen" then return "removed" end
    if not M.online(e) then return "offline" end
    return e.mode or "menu"
end

-- Approved and pending friends, hosting first; requests are separate.
function M.list()
    local out = {}
    for _, e in pairs(M.entries) do
        if e.state ~= "inkommen" then out[#out + 1] = e end
    end
    local function rank(e)
        local s = M.statusOf(e)
        return RANK[s] or (s == "offline" and 5 or 6)
    end
    table.sort(out, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

function M.requests()
    local out = {}
    for _, e in pairs(M.entries) do if e.state == "inkommen" then out[#out + 1] = e end end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function M.setActive(on)
    if on and not active then lastAsk = -100 end
    active = on
end

local function myState()
    local role, world = lobby.role(), lobby.world()
    if role == "host" and world then return lobby.hostMode == "lan" and "lan" or "host", world end
    if role == "guest" then return "guest", "" end
    return "menu", ""
end

local function ask()
    local ids = {}
    for id, e in pairs(M.entries) do if e.state == "ok" then ids[#ids + 1] = id end end
    if #ids > 0 then net.send("steam", "ask", table.concat(ids, ",")) end
end

function M.tick()
    local now = os.time()
    local mode, world = myState()
    local st = mode .. "|" .. world
    -- coopnet may start after the mod, so the state goes out again now and then.
    if st ~= sentState or now - lastResend >= RESEND_EVERY then
        sentState = st
        net.send("steam", "state", mode, world, lobby.VERSION)
        net.send("steam", "presence", mode, world)
    end
    if now - lastResend >= RESEND_EVERY then
        lastResend = now
        sendApproved()
        -- coopnet may have said who we are before the mod listened.
        if not lobby.me then net.send("steam", "whoami") end
        if lobby.me and lobby.playerName == "" then
            -- No Steam name on the bench: the player is named after the port.
            if lobby.me:match("^udp:") then lobby.setPlayerName(T("player_n", lobby.me:sub(5)))
            else net.send("steam", "name", lobby.me) end
        end
        for id, e in pairs(M.entries) do if e.state == "vantar" then request(id) end end
    end
    if active and now - lastAsk >= ASK_EVERY then
        lastAsk = now
        ask()
    end
end

function M.handle(msg)
    if msg[1] ~= "steam" then return false end
    local what, id = msg[3], msg[4]
    if what == "me" then
        -- coopnet has (re)started and emptied out.log: what was sent before it
        -- came up is lost, so the list and our state go out again now.
        sentState, lastResend = nil, -100
        for fid, e in pairs(M.entries) do
            if e.auto and not fid:match("^udp:") then net.send("steam", "name", fid) end
        end
        return false
    elseif what == "friendstate" then
        local e = M.entries[id]
        if e then e.mode, e.world, e.version, e.seen = msg[5], msg[6], msg[7], os.time() end
    elseif what == "request" then
        local e = M.entries[id]
        if e and (e.state == "ok" or e.state == "vantar") then
            e.state = "ok"
            q(id, "ok")
        elseif e then
            e.state = "inkommen"
        else
            newEntry(id, msg[5], "inkommen")
        end
        log("vänförfrågan från %s", id)
        changed()
    elseif what == "accepted" then
        -- Only an answer to our own request counts; an "ok" nobody asked for
        -- must not make a stranger approved.
        local e = M.entries[id]
        if e and e.state == "vantar" then
            e.state = "ok"
            changed()
        elseif not e then
            q(id, "bye")
        end
    elseif what == "declined" then
        local e = M.entries[id]
        if e and e.state == "vantar" then e.state = "nekad" changed() end
    elseif what == "removed" then
        local e = M.entries[id]
        if e and e.state == "inkommen" then
            M.entries[id] = nil
            changed()
        elseif e then
            e.state, e.seen = "borttagen", nil
            changed()
        end
    elseif what == "resolved" then
        if id == "" then M.message = T("bad_id") return true end
        M.addId(id)
    elseif what == "name" then
        local name = msg[5] or ""
        if id == lobby.me then
            if lobby.playerName == "" and name ~= "" then lobby.setPlayerName(name) end
        else
            local e = M.entries[id]
            if e and name ~= "" and e.auto then e.name, e.auto = name, false save() end
        end
    elseif what == "clippedid" then
        M.message = T("copied_id")
    else
        return false
    end
    return true
end

-- Hosts joined before the list existed (recent.txt) become friend requests once.
local function migrateRecent(dir)
    local old = dir .. "recent.txt"
    local f = io.open(old, "r")
    if not f then return end
    for line in f:lines() do
        local id, name = line:match("^(%d+)|(.*)$")
        if id and not M.entries[id] then newEntry(id, name, "vantar") end
    end
    f:close()
    os.remove(old .. ".old")
    os.rename(old, old .. ".old")
    save()
end

function M.init(netModule, logFn, lobbyModule, ioName)
    net, log, lobby = netModule, logFn, lobbyModule
    local dir = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/"
    path = dir .. "vanner.txt"
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local id, name, state = line:match("^([^|]+)|([^|]*)|(%a+)$")
            if id then M.entries[id] = { id = id, name = name, state = state } end
        end
        f:close()
    end
    migrateRecent(dir)
    -- A host we joined becomes a friend (a request when not one already).
    lobby.onJoinedHost = function(host) if not M.entries[host] then M.addId(host) end end
    lobby.onJoinRequest = function(host) lobby.join(host) end
end

return M
