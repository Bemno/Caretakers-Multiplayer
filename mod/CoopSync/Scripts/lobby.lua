-- Multiplayer sessions: which world the host plays, handing it to the guest,
-- and keeping singleplayer saves untouched. Worlds are in SaveGames\Coop only
-- during a session; coopnet lists, imports, moves and transfers the files and
-- guards the singleplayer saves (see coopnet/saves.py).
local M = {}
local T = require("text")

M.VERSION = "0.4"
local SAVE_EVERY = 240          -- the game autosaves after 5 min without a save
local HELLO_EVERY = 3
local MAP = "VoyageWorld2"
local CLIENT = "_klient"

local net, log, levelName, setRole
local UEHelpers = require("UEHelpers")

local role, world
local inWorldSince, lastSave = nil, 0
local guestWaiting, sendState = false, nil   -- host: nil | "saving" | "sending"
local saveRequestedAt = 0
local joining, lastHello, joinPeer = false, 0, nil
local hostWorld              -- the host's world name, sent before the world file
local pendingLoad                -- slot name to load once on the title screen

-- What the menu shows.
M.worlds, M.spSlots, M.friends = {}, {}, {}
-- Set by friends.lua: a host we joined, and Steam's "Join game"; by main.lua:
-- the multiplayer session ended (back on the title screen).
M.onJoinedHost, M.onJoinRequest, M.onLeave = nil, nil, nil
-- The player's own name (menu, hello/welcome, LAN) and the other player's.
M.playerName, M.peerName = "", nil
-- "online" (Steam) or "lan" while hosting.
M.hostMode = nil
-- LAN servers heard recently: addr -> { addr, world, name, version, t }.
M.lanServers = {}
local LAN_SECONDS = 6
local LEAVE_SECONDS = 5
local wasInMp, onTitleSince = false, nil
-- Our name goes to the other player during a session (pname), again when it
-- changes and now and then, so it arrives whatever the timing of hello.
local sentName, lastNameSent = nil, 0
local namePath
-- io\main normally; -coopIo=<name> gives a copy its own (two copies on one PC).
local ioDir = [[ue4ss\Mods\CoopSync\io\main\]]
M.status, M.me, M.code, M.modWarning = "", nil, nil, nil

-- One-off messages ("Deleted x", "Invite copied") fade after a few seconds;
-- progress messages stay until something replaces them.
local STATUS_SECONDS = 6
local STICKY = { joining = true, waiting = true, receiving = true, loading = true, loading_host = true, creating = true }
local statusAt, statusSticky = 0, false

local function status(key, ...)
    M.status = T(key, ...)
    statusAt, statusSticky = os.time(), STICKY[key] or false
end

function M.statusText()
    if M.status == "" then return "" end
    if statusSticky or os.time() - statusAt < STATUS_SECONDS then return M.status end
    return ""
end
M.progress = nil
M.guestSaves = true

local function coopDir()
    return (os.getenv("LOCALAPPDATA") or "") .. "\\Voyage\\Saved\\SaveGames\\Coop\\"
end

local function subsystem()
    for _, s in ipairs(FindAllOf("VoyageGameStateSubsystem") or {}) do
        if s:IsValid() then return s end
    end
end

local function readModList()
    local f = io.open("ue4ss/Mods/mods.txt", "r")
    if not f then return "" end
    local mods = {}
    for line in f:lines() do
        local name, on = line:match("^%s*([^;:%s][^:]-)%s*:%s*(%d)")
        if name then mods[#mods + 1] = name .. ":" .. on end
    end
    f:close()
    table.sort(mods)
    return table.concat(mods, ",")
end

local function compareMods(theirs, theirVersion)
    local mine, other = {}, {}
    for e in readModList():gmatch("[^,]+") do mine[e] = true end
    for e in (theirs or ""):gmatch("[^,]+") do other[e] = true end
    local diff = {}
    for e in pairs(mine) do if not other[e] then diff[#diff + 1] = T("only_here", e) end end
    for e in pairs(other) do if not mine[e] then diff[#diff + 1] = T("only_there", e) end end
    if theirVersion ~= M.VERSION then diff[#diff + 1] = T("version", M.VERSION, tostring(theirVersion)) end
    table.sort(diff)
    M.modWarning = #diff > 0 and table.concat(diff, "; ") or nil
    if M.modWarning then log("moddar skiljer sig: %s", M.modWarning) end
end

local function loadSlot(slot)
    local save = UEHelpers.GetGameplayStatics():LoadGameFromSlot(slot, 0)
    if not (save and save:IsValid()) then
        log("LoadGameFromSlot(%s): finns inte", slot)
        status("not_found", slot)
        return false
    end
    local ok = UEHelpers.GetGameInstance():TravelToWorldWithSaveGame(MAP, save, slot, { InternalId = 0 })
    log("laddar %s: %s", slot, tostring(ok))
    return ok
end

-- coopnet moves the worlds into SaveGames\Coop when the guard goes on (they live
-- outside SaveGames between sessions, out of singleplayer's reach); a world is
-- loaded once that is done, or after GUARD_WAIT if coopnet does not answer.
local GUARD_WAIT = 10
local guardReady, guardAskedAt = false, nil
local function askGuard()
    guardReady, guardAskedAt = false, os.time()
    net.send("save", "guard", "on")
end

local function becomeRole(r, w)
    role, world = r, w
    setRole(r)
    askGuard()
end

function M.init(netModule, logFn, levelNameFn, setRoleFn, ioName)
    net, log, levelName, setRole = netModule, logFn, levelNameFn, setRoleFn
    namePath = "ue4ss/Mods/CoopSync/io/" .. ioName .. "/spelarnamn.txt"
    ioDir = [[ue4ss\Mods\CoopSync\io\]] .. ioName .. [[\]]
    local f = io.open(namePath, "r")
    if f then
        M.playerName = (f:read("*l") or ""):gsub("[|\r\n]", "")
        f:close()
    end
end

function M.setPlayerName(name)
    name = (name or ""):gsub("[|\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false end
    M.playerName = name
    local f = io.open(namePath, "w")
    if f then f:write(name) f:close() end
    return true
end

-- Joining a LAN host by address (another network over Tailscale carries no
-- broadcast, so the host is never found by itself). The last address is kept.
M.lastIp = ""
local LAN_PORT = 47020
local function ipPath() return ioDir .. "senaste_ip.txt" end
function M.loadLastIp()
    local f = io.open(ipPath(), "r")
    if f then M.lastIp = (f:read("*l") or ""):gsub("%s", "") f:close() end
    return M.lastIp
end
function M.joinIp(text)
    local addr = (text or ""):gsub("%s", "")
    if not (addr:match("^[%w%.%-]+$") or addr:match("^[%w%.%-]+:%d+$")) then
        status("bad_ip")
        return false
    end
    M.lastIp = addr
    local f = io.open(ipPath(), "w")
    if f then f:write(addr) f:close() end
    if not addr:find(":", 1, true) then addr = addr .. ":" .. LAN_PORT end
    M.join("lan:" .. addr)
    return levelName() ~= MAP
end

function M.lanList()
    local out = {}
    for _, s in pairs(M.lanServers) do
        if os.time() - s.t <= LAN_SECONDS then out[#out + 1] = s end
    end
    table.sort(out, function(a, b) return a.world < b.world end)
    return out
end

function M.deleteWorld(name) net.send("save", "delete", name) end

function M.role() return role end
function M.world() return world end
-- The guest keeps its own inventory per host and world.
function M.guestKey()
    if role ~= "guest" or not hostWorld then return nil end
    return ((joinPeer or "okand"):gsub("[^%w_-]", "_")) .. "_" .. hostWorld:gsub("[^%w_-]", "_")
end

local COOPNET = [[ue4ss\Mods\CoopSync\coopnet\coopnet.exe]]
local STEAM_DLL = [[..\..\..\Engine\Binaries\ThirdParty\Steamworks\Steamv164\Win64\steam_api64.dll]]

local function coopnetAlive()
    local f = io.open(ioDir .. "coopnet.alive", "r")
    if not f then return false end
    local t = tonumber(f:read("*l") or "")
    f:close()
    return t ~= nil and os.time() - t < 10
end

-- A normal start (no test bench) runs coopnet.exe next to the mod; it quits
-- by itself when the game closes.
function M.startCoopnet()
    if coopnetAlive() then log("coopnet körs redan") return end
    local f = io.open(COOPNET, "rb")
    if not f then log("coopnet.exe saknas") status("no_coopnet") return end
    f:close()
    local cmd = string.format('start "" /B "%s" --watchgame --dir "%s" --dll "%s"', COOPNET, ioDir:sub(1, -2), STEAM_DLL)
    local ok, err = pcall(os.execute, cmd)
    log("startar coopnet: %s", ok and "ok" or tostring(err))
end

-- Command line (test bench): -coopRole=host -coopSlot=<slot> loads directly,
-- -coopJoin=<steamid|udp> joins as soon as the title screen is up.
-- -coopHost=<world> (Spelstartare's split screen) hosts that multiplayer world
-- as soon as the title screen is up, without clicking through the menu.
function M.fromCommandLine(cmdRole, cmdSlot, cmdJoin, cmdHost)
    if cmdHost then
        becomeRole("host", cmdHost)
        M.hostMode = "online"
        status("loading", cmdHost)
        pendingLoad = "Coop/" .. cmdHost
    elseif cmdJoin then
        M.join(cmdJoin)
    elseif cmdRole == "host" and cmdSlot then
        becomeRole("host", cmdSlot:match("^Coop/(.+)$") or cmdSlot)
        pendingLoad = cmdSlot
    elseif cmdRole then
        role = cmdRole
        setRole(cmdRole)
        pendingLoad = cmdSlot
    end
end

function M.refresh()
    M.worlds, M.spSlots = {}, {}
    net.send("save", "list")
    net.send("save", "splist")
end

local function startHosting(name, mode)
    M.hostMode = mode or "online"
    if M.hostMode == "lan" then net.send("steam", "lanhost", name, M.playerName, M.VERSION) end
end

function M.host(name, mode)
    becomeRole("host", name)
    startHosting(name, mode)
    status("loading", name)
    pendingLoad = "Coop/" .. name
end

-- A world name becomes a file name in SaveGames\Coop and travels in the
-- "|"-separated lines to coopnet, so those characters are refused.
local function cleanName(name)
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == CLIENT or name:find('[\\/:*?"<>|]') or name:sub(1, 1) == "." then
        status("bad_name")
        return nil
    end
    return name
end

-- From coopnet's list: between sessions the files are outside SaveGames.
local function worldExists(name)
    for _, w in ipairs(M.worlds) do
        if w.name:lower() == name:lower() then return true end
    end
    return false
end

function M.renameWorld(old, new)
    new = cleanName(new)
    if not new then return false end
    if new == old then return true end
    if worldExists(new) then status("name_taken", new) return false end
    net.send("save", "rename", old, new)
    return true
end

-- Returns false (and says why) when the name cannot be used.
function M.newWorld(name, mode)
    name = cleanName(name)
    if not name then return false end
    if worldExists(name) then status("name_taken", name) return false end
    becomeRole("host", name)
    startHosting(name, mode)
    status("creating", name)
    -- An empty save game starts the game from the beginning. Passing a Lua
    -- table as FGameProgress to TravelToWorldWithGameProgess crashes the game.
    local slot = "Coop/" .. name
    local ok, res = pcall(function()
        local save = UEHelpers.GetGameplayStatics():CreateSaveGameObject(StaticFindObject("/Script/Voyage.VoyageSaveGame"))
        save:SetToDefaults()
        save:SetSlotName(slot)
        return UEHelpers.GetGameInstance():TravelToWorldWithSaveGame(MAP, save, slot, { InternalId = 0 })
    end)
    log("ny värld %s: %s", name, tostring(res))
    -- The first periodic save writes Coop/<name>.sav.
    lastSave = -SAVE_EVERY
    return true
end

-- Saves the multiplayer world now (the host's Save in the Esc menu).
function M.saveNow()
    if role ~= "host" or not world then return false end
    local sub = subsystem()
    if not sub then return false end
    lastSave = os.time()
    local ok, res = pcall(function() return sub:RequestSaveGame("Coop/" .. world) end)
    log("sparar Coop/%s (meny): %s", world, ok and tostring(res) or tostring(res))
    return ok and res
end

function M.import(index)
    status("importing", index)
    net.send("save", "import", index)
end

function M.copyInvite() net.send("steam", "clip") end
function M.pasteInvite() net.send("steam", "readclip") end
function M.listFriends() M.friends = {} net.send("steam", "friends") end
function M.invite(id) net.send("steam", "invite", id) status("invite_sent") end

-- The guest waits for a host that went away: once back on the title screen
-- (leave), the same join again; it repeats its hello until the host answers.
local rejoinPeer
function M.rejoinFromTitle()
    rejoinPeer = joinPeer
end

function M.join(peer)
    -- Joining from inside a running world loaded the host's world on top of
    -- it, and the guest crashed on objects of the old world (2026-11-17): a
    -- join (Steam's "Join game" too) only starts from the title screen.
    if levelName() == MAP then
        log("anslutning till %s nekad: inne i en värld", tostring(peer))
        status("join_in_world")
        return
    end
    -- On the test bench a friend's id is udp:<port>; the link is fixed there.
    if tostring(peer):match("^udp") then peer = "udp" end
    role, world = "guest", CLIENT
    setRole("guest")
    joining, lastHello, joinPeer = true, 0, peer
    status("joining")
end

local function hostSend()
    local path = coopDir() .. world .. ".sav"
    net.send("worldname", world)
    net.send("sendfile", path, CLIENT .. ".sav")
    sendState = "sending"
    log("skickar världen %s till gästen", path)
end

-- Back on the title screen after a multiplayer world: the session is over.
-- The guard puts singleplayer files back one last time and stops, so
-- singleplayer can be played and saved in the same run.
local function leave()
    log("multiplayer slut: vakten av, roll %s nollställd", tostring(role))
    if role == "host" then net.send("hostbye") end
    net.send("save", "guard", "off")
    net.send("steam", "leave")
    role, world, hostWorld, joinPeer, M.peerName, M.hostMode = nil, nil, nil, nil, nil, nil
    guestWaiting, sendState, wasInMp, onTitleSince, sentName = false, nil, false, nil, nil
    if M.onLeave then M.onLeave() end
    if rejoinPeer then
        local p = rejoinPeer
        rejoinPeer = nil
        log("ansluter igen till %s", tostring(p))
        M.join(p)
    end
end

function M.tick()
    local level = levelName()
    if role and M.playerName ~= "" and (M.playerName ~= sentName or os.time() - lastNameSent >= 30) then
        sentName, lastNameSent = M.playerName, os.time()
        net.send("pname", M.playerName)
    end
    if role and level == MAP then wasInMp = true end
    if wasInMp and level == "Empty" and not pendingLoad and not joining and not sendState then
        onTitleSince = onTitleSince or os.time()
        if os.time() - onTitleSince >= LEAVE_SECONDS then leave() end
    else
        onTitleSince = nil
    end
    local guardWait = pendingLoad and pendingLoad ~= "Coop/" .. CLIENT and not guardReady
        and guardAskedAt and os.time() - guardAskedAt < GUARD_WAIT
    if pendingLoad and level == "Empty" and not guardWait then
        if not guardReady and pendingLoad ~= "Coop/" .. CLIENT then log("vakten svarade inte, laddar ändå") end
        local slot = pendingLoad
        pendingLoad = nil
        loadSlot(slot)
    end
    if level == MAP then
        inWorldSince = inWorldSince or os.time()
    else
        inWorldSince = nil
    end

    if joining and os.time() - lastHello >= HELLO_EVERY then
        lastHello = os.time()
        -- Repeated with every hello: coopnet may have started after the first one.
        if joinPeer ~= "udp" then net.send("steam", "join", joinPeer) end
        net.send("hello", M.VERSION, readModList(), M.playerName)
    end

    if not (role and inWorldSince and os.time() - inWorldSince > 10) then return end
    local sub = subsystem()
    if not sub then return end
    local slot = "Coop/" .. world

    if role == "host" and guestWaiting and not sendState then
        guestWaiting = false
        sendState, saveRequestedAt = "saving", os.time()
        lastSave = os.time()
        log("sparar inför överföring: %s", tostring(sub:RequestSaveGame(slot)))
    elseif sendState == "saving" and os.time() - saveRequestedAt >= 1 and not sub:HasPendingSaveGame() then
        hostSend()
    end

    -- Saving while a large world is still streaming in crashed the game.
    -- The guest's copy is never used (each join brings the host's world), but saving it
    -- holds the game's autosave off the singleplayer slots: without it the guest's game
    -- autosaved into them 5 min after loading (bench 2026-11-19, the guard put them back).
    if role == "guest" and not M.guestSaves then return end
    if os.time() - lastSave >= SAVE_EVERY and os.time() - inWorldSince > 60 then
        lastSave = os.time()
        local ok, res = pcall(function() return sub:RequestSaveGame(slot) end)
        log("sparar %s: %s", slot, ok and tostring(res) or tostring(res))
    end
end

function M.handle(msg)
    local kind = msg[1]
    if kind == "hello" then
        if role == "host" then
            compareMods(msg[4], msg[3])
            M.peerName = msg[5] ~= "" and msg[5] or nil
            net.send("welcome", M.VERSION, readModList(), M.playerName)
            if not sendState then guestWaiting = true end
        end
        return true
    elseif kind == "welcome" then
        if joining then
            joining = false
            M.peerName = msg[5] ~= "" and msg[5] or nil
            if joinPeer:match("^%d+$") and M.onJoinedHost then M.onJoinedHost(joinPeer) end
            compareMods(msg[4], msg[3])
            status("waiting")
        end
        return true
    elseif kind == "pname" then
        M.peerName = msg[3] ~= "" and msg[3] or M.peerName
        return true
    elseif kind == "worldname" then
        hostWorld = msg[3]
        return true
    elseif kind == "fileprogress" then
        M.progress = math.floor(100 * tonumber(msg[3]) / tonumber(msg[4]))
        status("receiving", M.progress)
        return true
    elseif kind == "savefile" then
        log("världen mottagen: %s", msg[3])
        M.progress = nil
        if role == "guest" then
            askGuard()
            status("loading_host")
            pendingLoad = "Coop/" .. CLIENT
            if levelName() ~= "Empty" then
                -- Already in a world: loading straight away travels from there.
                pendingLoad = nil
                loadSlot("Coop/" .. CLIENT)
            end
        end
        return true
    elseif kind == "filesent" then
        log("världen skickad: %s", msg[3])
        sendState = nil
        return true
    elseif kind == "fileerror" then
        log("filfel: %s", msg[3])
        sendState = nil
        return true
    elseif kind == "save" then
        local what = msg[3]
        if what == "world" then M.worlds[#M.worlds + 1] = { name = msg[4], time = tonumber(msg[5]) }
        elseif what == "sp" then M.spSlots[#M.spSlots + 1] = { index = tonumber(msg[4]), time = tonumber(msg[5]) }
        elseif what == "imported" then
            status("imported", msg[4])
            M.refresh()
        elseif what == "renamed" then
            status("renamed", msg[5])
            M.refresh()
        elseif what == "deleted" then
            status("deleted", msg[4])
            M.refresh()
        elseif what == "error" then status("error", tostring(msg[4])) log("spar-fel: %s", tostring(msg[4]))
        elseif what == "guarded" then log("vakten återställde %s singleplayer-filer", tostring(msg[4]))
        elseif what == "guard" then
            guardReady = msg[4] == "on"
            log("vakten %s, världarna %s", msg[4], guardReady and "inne i SaveGames" or "flyttade ut")
        end
        return true
    elseif kind == "steam" then
        local what = msg[3]
        if what == "me" then M.me, M.code = msg[4], msg[5]
        elseif what == "friend" then M.friends[#M.friends + 1] = { id = msg[4], name = msg[5] }
        elseif what == "clipped" then status("copied", tostring(msg[4]))
        elseif what == "clipcode" then M.join(msg[4])
        elseif what == "clipbad" then status("no_invite")
        elseif what == "lanserver" then
            M.lanServers[msg[4]] = { addr = msg[4], world = msg[5] or "", name = msg[6] or "", version = msg[7] or "", t = os.time() }
        elseif what == "joinrequest" then
            log("Steam: gå med i %s", tostring(msg[4]))
            if M.onJoinRequest then M.onJoinRequest(msg[4]) end
        elseif what == "peer" then log("ansluten till %s", tostring(msg[4]))
        elseif what == "joinfail" then
            log("anslutning: hittar inte %s", tostring(msg[4]))
            joining = false
            leave()
            status("ip_unknown", tostring(msg[4]))
        elseif what == "error" then status("no_steam", tostring(msg[4])) log("steam-fel: %s", tostring(msg[4]))
        end
        return true
    end
    return false
end

return M
