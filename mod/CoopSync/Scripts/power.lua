-- Power: generic switches (levers that turn rooms and machines on and off) and
-- cable connections. Switches are synced as on/off state with TurnON/TurnOFF.
-- Cables are experimental: the sender watches every cable's connection state,
-- the receiver tries to reproduce it with TryEstablishConnection.
local M = {}

local SWITCH_FN = "/Game/Blueprints/Modules/Utility/Switches/BP_Module_Generic_Switch.BP_Module_Generic_Switch_C:StateUpdated"
local PERSIST_CLASS = "/Script/Voyage.VoyagePersistentActorComponent"
local SOCKET_CLASS = "/Script/Voyage.ModuleSocketComponent"

local net, log, localPC, now, props, console
local isHost = false
local puppetOf
local switchHooked = false
local quietSwitch = {}      -- key -> until time: changes there are the peer's echo

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

-- Static level actors have the same path in both games; runtime actors (built
-- modules, dropped items) only share the save id.
local function keyOf(actor)
    -- Placed in the level: the same name in both games, while the save id can
    -- be shared (three quay solar panels had one id, 2026-11-16).
    local path = pathOf(actor)
    if path and path:find("_UAID_", 1, true) then return "p" .. path end
    local pc = actor:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    if pc and pc:IsValid() then
        local id = pc.PersistentUniqueId
        if id and id ~= 0 then return "i" .. props.wire(tostring(id)) end
    end
    return "p" .. pathOf(actor)
end

-- Player bodies have the same save id in both games, so a cable end in a body
-- is sent by who it is: "@jag" is the sender's own body, "@du" the socket on
-- the sender's puppet (peerpower.lua), i.e. the receiver's body. The receiver
-- swaps the two (swapBodies), and here they resolve to the local actors.
local BODY_SOCKET = "ElectricSocket"
local PUPPET_SOCKET = "VoyageModuleSocketView"
local puppetSocketPath = function() return nil end

local function resolve(key)
    if key == "@jag" then
        local pawn = localPC().Pawn
        return (pawn and pawn:IsValid()) and pawn or nil
    elseif key == "@du" then
        local path = puppetSocketPath()
        local a = path and StaticFindObject(path)
        return (a and a:IsValid()) and a or nil
    end
    local kind, rest = key:sub(1, 1), key:sub(2)
    if kind == "p" then
        local a = StaticFindObject(rest)
        if a and a:IsValid() then return a end
        return nil
    end
    local pc = props.findById(rest)
    local owner = pc and pc:GetOwner()
    if owner and owner:IsValid() then return owner end
end

-- Switches ----------------------------------------------------------------

local switchQueue = {}

-- The hook only queues the path; all work happens on the mod tick. A UObject
-- kept from a hook until a later tick crashed UE4SS when Lua collected it.
local function onSwitch(ctx)
    switchQueue[#switchQueue + 1] = pathOf(ctx:get())
end

local function processSwitch(path)
    local sw = StaticFindObject(path)
    if not (sw and sw:IsValid()) then return end
    -- The boat's throttle and wheel are levers too; boat.lua syncs their value.
    -- Known by name (…BP_Throttle_C_0BP_Module_Generic_Switch_CSwitch): after
    -- the boat's main switch was flipped under UE4SS 4 the guest crashed inside
    -- UE4SS, and GetParentActor was the call to avoid (2026-11-15).
    local name = sw:GetFName():ToString()
    if name:find("BP_Throttle_C", 1, true) or name:find("BP_Steering_C", 1, true) then return end
    local on = sw:IsOn()
    local key = keyOf(sw)
    -- IsOn lags the lever, so a quick on-off from the peer looked like local
    -- changes and the two games bounced the switch between them.
    if (quietSwitch[key] or 0) > now() then return end
    net.send("switch", key, on and 1 or 0)
    log("brytare %s -> %s", key, on and "på" or "av")
end

local function tryHookSwitch()
    if switchHooked then return end
    local fn = StaticFindObject(SWITCH_FN)
    if not (fn and fn:IsValid()) then return end
    -- Post hooks never fire for blueprint functions in UE4SS 3.0.1; the state
    -- is read on the next tick instead, after the switch has changed.
    local ok, err = pcall(RegisterHook, SWITCH_FN, function(ctx)
        pcall(onSwitch, ctx)
    end)
    switchHooked = true
    log("brytarsynk: %s", ok and "ok" or tostring(err))
    if not isHost then net.send("ready") end
end

local function handleSwitch(msg)
    local key, on = msg[3], msg[4] == "1"
    local sw = resolve(key)
    if not sw then log("brytare %s finns inte här", key) return end
    if sw:IsOn() == on then return end
    quietSwitch[key] = now() + 1.5
    -- TurnON/TurnOFF alone left the lever unchanged; ToggleSwitch is what the
    -- player's interaction calls.
    local ok, err = pcall(function() sw:ToggleSwitch() end)
    if not ok then
        log("brytare %s: ToggleSwitch %s, provar TurnON/OFF", key, tostring(err))
        if on then sw:TurnON() else sw:TurnOFF() end
    end
    log("brytare %s satt %s (direkt %s)", key, on and "på" or "av", tostring(sw:IsOn()))
    local path = pathOf(sw)
    ExecuteInGameThreadWithDelay(3000, function()
        local s = StaticFindObject(path)
        if s and s:IsValid() then log("brytare %s efter 1,5 s: %s", key, tostring(s:IsOn())) end
    end)
end

-- Cables ------------------------------------------------------------------
-- A placed cable is a runtime actor that exists only in the game where it was
-- placed. Every second all cables are looked up afresh (holding UObject
-- references across ticks crashed UE4SS once the game freed them) and each
-- new cable or change in what its plugs are connected to is sent as
-- cable|key|class|socketA|socketB. The other game summons a cable of that
-- class if it has none with that key, maps the ids (props.alias), moves the
-- end spheres to the sockets and calls TryEstablishConnection.

local CABLE_POLL_SECONDS = 1
local copies = {}           -- local save ids of cables summoned as copies
local lastPoll = 0
local cableStates               -- key -> state, nil until the first scan
local applyingCable = {}        -- key -> until time (echo guard)
local pendingCables = {}        -- summoned for the peer, waiting to be found

local function socketKey(cable, connector)
    local ok, sock = pcall(function() return cable:GetSocket(connector) end)
    if not ok or not (sock and sock:IsValid()) then return "-" end
    local owner = sock:GetOwner()
    if not (owner and owner:IsValid()) then return "-" end
    local name = sock:GetFName():ToString()
    local pawn = localPC().Pawn
    if name == BODY_SOCKET and pawn and pawn:IsValid() and owner:GetAddress() == pawn:GetAddress() then return "@jag#" .. BODY_SOCKET end
    local pp = puppetSocketPath()
    if pp and pathOf(owner) == pp then return "@du#" .. PUPPET_SOCKET end
    return keyOf(owner) .. "#" .. name
end

-- With one end loose, GetSocket reports the plugged end's socket for both
-- connectors; the end closer to that socket is the plugged one.
local function plugsOf(cable)
    local a, b = socketKey(cable, cable.ConnectorMeshA), socketKey(cable, cable.ConnectorMeshB)
    if a ~= "-" and a == b then
        local sock = cable:GetSocket(cable.ConnectorMeshA)
        local s = sock:K2_GetComponentLocation()
        local function d(c)
            local l = c:K2_GetComponentLocation()
            return (l.X - s.X) ^ 2 + (l.Y - s.Y) ^ 2 + (l.Z - s.Z) ^ 2
        end
        if d(cable.SphereA) <= d(cable.SphereB) then b = "-" else a = "-" end
    end
    return a, b
end

local function stateOf(cable)
    local a, b = plugsOf(cable)
    return string.format("%s|%s|%s", tostring(cable:IsConnected()), a, b)
end

local function allCables()
    local ok, found = pcall(FindObjects, 0, "ModulesConnectCable", "", 0, 0, false)
    local list = {}
    for _, c in ipairs((ok and found) or {}) do
        local okV, valid = pcall(function() return c:IsValid() and not c:GetFullName():find("Default__", 1, true) end)
        if okV and valid then list[#list + 1] = c end
    end
    return list
end

local function className(obj) return obj:GetClass():GetFName():ToString() end

-- A summoned cable has the class defaults for its length; the length of the
-- original comes from the cable item and is sent along, otherwise the copy is
-- too short and snaps (and the game destroys it) when an end is pulled.
local function lengthOf(c)
    return string.format("%.1f", c.MaxLength or 0), string.format("%.1f", c.Cable.CableLength or 0)
end

-- A loose end is only in the player's hand when it is close to them; a cable
-- pulled out by the boat sailing off lies where it fell.
local HELD_RADIUS = 400

local function looseEnd(c, a, b)
    if (a == "-") == (b == "-") then return "0", "", "", "" end
    local sphere = a == "-" and c.SphereA or c.SphereB
    local l = sphere:K2_GetComponentLocation()
    local held = "0"
    pcall(function()
        local p = localPC().Pawn:K2_GetActorLocation()
        if (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < HELD_RADIUS ^ 2 then held = "1" end
    end)
    return held, string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z)
end

-- A weapon is an actor only in its owner's game; at the other the end went to
-- the body socket too and the cable looped into it twice (electric pistol,
-- 2026-11-18). It is sent as a loose end in the hand, which the other game
-- keeps at the puppet's hand.
local function weaponSocket(sk) return sk ~= "-" and sk:find("DA_Weapon_", 1, true) ~= nil end

local function sendCable(key, c, a, b)
    if weaponSocket(a) then a = "-" end
    if weaponSocket(b) then b = "-" end
    local maxLen, len = lengthOf(c)
    local okL, held, x, y, z = pcall(looseEnd, c, a, b)
    if not okL then held, x, y, z = "1", "", "", "" end
    local okC, consumed = pcall(function() return c.ItemsConsumed end)
    net.send("cable", key, pathOf(c:GetClass()), a, b, maxLen, len, held, x, y, z, okC and tostring(consumed) or "")
end

-- A copy of a mooring line in the game that only follows the boat pulled
-- that game's boat, and the mod put the boat back every frame: the boat
-- bounced at the quay for whoever had not moored (14-28 cm per frame,
-- 2026-11-16). There the copy hangs slack; in the game that moves the boat it
-- has the owner's length.
local MOORING_SLACK = 100
local mooringCopies = {}    -- cable path -> the owner's length
local mooringPlugged = {}   -- cable path -> true once seen in at both ends here
-- When the mod removes a mooring line, the boat brings back its own built-in
-- line at once, already plugged into the quay. Taken for the player's doing
-- it was sent, the other game's copy clashed with its own returned line, was
-- removed, and the lines went round in a loop (2026-11-18). A line appearing
-- where the mod just emptied a socket is the game's own and is never sent.
local emptiedAt = {}        -- socket key -> time the mod emptied it
local RETURN_SECONDS = 5
local returned = {}         -- cable key -> time until its changes are not sent
local function noteEmptied(a, b)
    if a and a ~= "-" then emptiedAt[a] = now() end
    if b and b ~= "-" then emptiedAt[b] = now() end
end

local function weMoveBoat()
    local ok, res = pcall(function()
        local boat = require("boat")
        for key in pairs(boat.list()) do return not boat.peerControls(key) end
        return isHost
    end)
    if ok then return res end
    return isHost
end

local function mooringLength(c, len)
    if weMoveBoat() then c.Cable.CableLength = len return end
    local a, b = c.SphereA:K2_GetComponentLocation(), c.SphereB:K2_GetComponentLocation()
    local span = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
    c.Cable.CableLength = math.max(len, span + MOORING_SLACK)
end

local SEGMENT_CM = 12
local function setLength(c, maxLen, len)
    local ok, err = pcall(function()
        c.bCanSnapFromStretching = false
        if maxLen and maxLen > 0 then c.MaxLength = maxLen c.MaxLengthBase = maxLen end
        if not (len and len > 0) then return end
        if c.bMooringCable then
            mooringCopies[c:GetFullName():match("%S+%s+(%S+)")] = len
            mooringLength(c, len)
        else
            -- The game saves the segments, not CableLength: copies given only
            -- the length came back 96 cm long after loading (2026-11-17).
            -- One segment is 12 cm; a negative count removes.
            local steps = math.floor((len - (c.Cable.CableLength or 0)) / SEGMENT_CM + 0.5)
            if steps ~= 0 then c:AddSegments(0, steps) end
        end
    end)
    if not ok then log("kabellängd: %s", tostring(err)) end
end

local lastMooringCheck = 0
local function keepMooringCopies()
    if now() - lastMooringCheck < 0.5 then return end
    lastMooringCheck = now()
    for path, len in pairs(mooringCopies) do
        local c = StaticFindObject(path)
        local okP, a, b = false, nil, nil
        if c and c:IsValid() then okP, a, b = pcall(plugsOf, c) end
        -- Our copy of their mooring line, unplugged here: it stood stiff at
        -- full length (2026-11-18). It is removed; the removal reaches the
        -- owner, who removes the line too, and both boats get their own
        -- built-in line back.
        if okP and a ~= "-" and b ~= "-" then mooringPlugged[path] = true end
        if okP and (a == "-" or b == "-") and mooringPlugged[path] then
            mooringCopies[path], mooringPlugged[path] = nil, nil
            noteEmptied(a, b)
            c:K2_DestroyActor()
            log("förtöjning %s: urkopplad här, kopian borttagen", path:match("[^.]+$"))
        elseif c and c:IsValid() then
            pcall(mooringLength, c, len)
        else
            mooringCopies[path] = nil
        end
    end
end

-- A mooring line pulls the boat only in the game that moves it; in the other
-- the line reels in without the boat coming, and its length yanked the boat
-- (2026-11-16). Whoever handles a mooring line therefore takes the boat over,
-- unless the other player is driving it.
local function claimBoatForMooring(c, key)
    local ok, moor = pcall(function() return c.bMooringCable end)
    if not (ok and moor) then return end
    local okB, err = pcall(function() require("boat").claim("förtöjning " .. key) end)
    if not okB then log("kabel %s: båten kunde inte tas över: %s", key, tostring(err)) end
end

-- Cables also appear when a part of the world streams in (the boat is its own
-- level instance and loads after the first scan). Such a cable is not one a
-- player just laid out: it is taken as it is, and given a few seconds to plug
-- into its sockets before changes count. Only a cable that appears close to
-- the local player once the world has settled is sent as new.
local SETTLE_SECONDS, NEW_CABLE_RADIUS, LOAD_GRACE = 5, 1500, 60
local baselineAt, settling = nil, {}

local function nearPlayer(c)
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return false end
    local p, l = pawn:K2_GetActorLocation(), c:K2_GetActorLocation()
    return (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < NEW_CABLE_RADIUS ^ 2
end

-- A cable end plugged in by the local player is within reach of them. Loaded
-- cables also plug themselves in when a module streams in (the guest's two
-- cables, 15.6 m, went into a guest-only module and stood up through the
-- host's deck, 2026-11-16); those are not sent.
local PLUG_REACH = 600

local function endNearPlayer(c)
    local pawn = localPC().Pawn
    if not (pawn and pawn:IsValid()) then return false end
    local p = pawn:K2_GetActorLocation()
    for _, sphere in ipairs({ c.SphereA, c.SphereB }) do
        local l = sphere:K2_GetComponentLocation()
        if (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < PLUG_REACH ^ 2 then return true end
    end
    return false
end

local function plugCount(st)
    local a, b = st:match("^(.-)|(.-)|")
    if not a then return 0 end
    return (a ~= "-" and 1 or 0) + (b ~= "-" and 1 or 0)
end

local function pollCables()
    if now() - lastPoll < CABLE_POLL_SECONDS or #pendingCables > 0 then return end
    lastPoll = now()
    local first = cableStates == nil
    if first then baselineAt = now() end
    local states = {}
    local moored = false
    local moorLines, moorPaths = {}, {}
    for _, c in ipairs(allCables()) do
        local okK, key = pcall(keyOf, c)
        local okA, a, b = pcall(plugsOf, c)
        if okA and a ~= "-" and b ~= "-" then
            local okM, isMoor = pcall(function() return c.bMooringCable end)
            if okM and isMoor then
                moored = true
                local okL, len = pcall(function() return c.Cable.CableLength end)
                moorLines[#moorLines + 1] = a .. "|" .. b .. "|" .. (okL and math.floor((len or 0) / 50) or 0)
                moorPaths[#moorPaths + 1] = c:GetFullName():match("%S+%s+(%S+)")
            end
        end
        -- Cables without a save id are the game's temporary previews while a
        -- cable is being placed.
        if okK and okA and key:sub(1, 1) == "i" then
            -- The length (in 50 cm steps) is part of the state so that a copy
            -- shortens while the owner reels the cable in.
            local okL, len = pcall(function() return c.Cable.CableLength end)
            local st = a .. "|" .. b .. "|" .. (okL and math.floor((len or 0) / 50) or 0)
            states[key] = st
            local prev = not first and cableStates[key]
            if not first and not prev and ((emptiedAt[a] and now() - emptiedAt[a] < RETURN_SECONDS)
                or (emptiedAt[b] and now() - emptiedAt[b] < RETURN_SECONDS)) then
                returned[key] = now() + RETURN_SECONDS
                log("kabel %s: båtens egen lina tillbaka i tömt uttag, skickas inte", key)
            end
            if returned[key] then
                if returned[key] > now() then prev = st else returned[key] = nil prev = prev or st end
            end
            if not first and not prev then
                local okN, near = pcall(nearPlayer, c)
                -- A cable in our own body was just plugged in by us: the
                -- host's charging cable laid in the first minute was taken
                -- for a loaded one and never reached the guest (2026-11-15).
                local okB, body = pcall(function() return keyOf(localPC().Pawn) .. "#" end)
                local inBody = okB and (a:sub(1, #body) == body or b:sub(1, #body) == body)
                -- Plugged at both ends near us at first sight: laid by us
                -- between two polls (the second mooring line, 2026-11-16).
                -- A saved one has the same id in the other game, which then
                -- only finds it there.
                local okE, nearEnd = pcall(endNearPlayer, c)
                local laidByUs = plugCount(st) == 2 and okE and nearEnd
                if not inBody and not laidByUs and (now() - baselineAt < LOAD_GRACE or not (okN and near)) then
                    settling[key] = { untilT = now() + SETTLE_SECONDS, from = st }
                    log("kabel %s: inladdad (%s), skickas inte", key, st)
                end
            end
            -- The boat's mooring sockets bring back a built-in line when they
            -- are emptied; it looks loaded, and the player plugging it into
            -- the quay within the settling seconds was swallowed: the other
            -- game never saw the line (2026-11-16). A plug-in within reach of
            -- the own player ends the settling.
            local s = settling[key]
            if s and s.untilT > now() then
                local okE, near = pcall(endNearPlayer, c)
                if plugCount(st) > plugCount(s.from) and okE and near then
                    settling[key] = nil
                    prev = s.from
                    log("kabel %s: inladdad men inkopplad av mig (%s -> %s)", key, s.from, st)
                else
                    prev = st
                end
            elseif s then
                settling[key] = nil
            end
            local plugsChanged = not prev or prev:match("^(.*)|[^|]*$") ~= a .. "|" .. b
            local pc = c:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
            local isCopy = pc and pc:IsValid() and copies[tostring(pc.PersistentUniqueId)]
            -- Copies only report plug changes; their length follows the owner's.
            if not first and prev and plugsChanged and not isCopy and plugCount(st) > plugCount(prev)
                and (applyingCable[key] or 0) <= now() then
                local okE, near = pcall(endNearPlayer, c)
                if okE and not near then
                    log("kabel %s: kopplades in långt från spelaren (%s -> %s), skickas inte", key, prev, st)
                    prev = st
                    plugsChanged = false
                end
            end
            if not first and prev ~= st and (applyingCable[key] or 0) <= now() and (plugsChanged or not isCopy) then
                if plugsChanged then
                    log("kabel %s (%s): %s -> %s", key, className(c), tostring(prev), st)
                    if not isCopy then claimBoatForMooring(c, key) end
                end
                sendCable(key, c, a, b)
            end
        end
    end
    if first then
        local n = 0
        for _ in pairs(states) do n = n + 1 end
        log("kablar: %d", n)
    end
    cableStates = states
    table.sort(moorLines)
    pcall(function()
        local boat = require("boat")
        boat.moored = moored
        boat.mooringLines = table.concat(moorLines, ";")
        boat.mooringCables = moorPaths
    end)
end

local function findSocket(sockKey)
    if sockKey == "-" then return nil end
    local ownerKey, name = sockKey:match("^(.*)#([^#]+)$")
    local owner = ownerKey and resolve(ownerKey)
    if not owner then return nil end
    local comps = owner:K2_GetComponentsByClass(StaticFindObject(SOCKET_CLASS))
    for _, elem in ipairs(comps) do
        local okG, obj = pcall(function() return elem:get() end)
        if not okG or obj == nil then obj = elem end
        local ok, n = pcall(function() return obj:GetFName():ToString() end)
        if ok and n == name then return obj end
    end
end

-- A summoned cable has no CableItem, and TryEstablishConnection then drops
-- every socket it finds (disassembly 2026-11-16); it is the main reason only
-- 8 of 35 copies plugged in. Taken from a cable of the same class in the world.
local cableItems = {}       -- class name -> item path
local CABLE_ITEM_FALLBACK = {
    BP_ModuleCable_Electric_C = "/Game/Data/Assets/Cable/DA_Cable_Electricity.DA_Cable_Electricity",
}
local function giveCableItem(cable)
    local cur = cable.CableItem
    if cur and cur:IsValid() then return end
    local cls = cable:GetClass()
    local name = cls:GetFName():ToString()
    local path = cableItems[name]
    if not path then
        for _, c in ipairs(FindObjects(0, name, "", 0, 0, false) or {}) do
            local ok, p = pcall(function()
                local item = c.CableItem
                return item and item:IsValid() and item:GetFullName():match("%S+%s+(%S+)")
            end)
            if ok and p then path = p break end
        end
        path = path or CABLE_ITEM_FALLBACK[name]
        cableItems[name] = path
        log("kabel: CableItem för %s = %s", name, tostring(path))
    end
    local item = path and StaticFindObject(path)
    if item and item:IsValid() then cable.CableItem = item end
end

local spawnCopy
local props_goneHook
local follow = {}           -- key -> { path, side }: copy ends held by the other player

local givenAway = {}        -- key -> until time; late messages about it are ignored

local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"

-- Stored electricity: each game ran its own power, and the guest's boat
-- battery stood empty while the host's had 272 (2026-11-15), so nothing on the
-- guest's boat had power. The host sends the charge of the modules near either
-- player and the guest's modules are topped up or drained to it.
local MODULE_CLASS = "/Script/Voyage.VoyageModuleComponent"
local CHARGE_SECONDS, CHARGE_RADIUS, CHARGE_BATCH = 2, 6000, 25
local lastCharge, chargeSent = -100, {}

local function sendCharges()
    if now() - lastCharge < CHARGE_SECONDS then return end
    lastCharge = now()
    local centres = {}
    local pawn = localPC().Pawn
    if pawn and pawn:IsValid() then centres[#centres + 1] = pawn:K2_GetActorLocation() end
    local puppet = puppetOf()
    if puppet and puppet:IsValid() then centres[#centres + 1] = puppet:K2_GetActorLocation() end
    if #centres == 0 then return end
    local character = StaticFindObject("/Script/Engine.Character")
    local ok, found = pcall(FindObjects, 0, "VoyageModuleComponent", "", 0, 0, false)
    local batch = {}
    local function flush()
        if #batch > 0 then net.send("charge", table.concat(batch, ";")) batch = {} end
    end
    for _, m in ipairs((ok and found) or {}) do
        pcall(function()
            -- Distance first: the name check on every module of the world
            -- made this a 30 ms stall every 2 s (2026-11-17).
            if not m:IsValid() then return end
            local a = m:GetOwner()
            if not (a and a:IsValid()) then return end
            local l = a:K2_GetActorLocation()
            local near = false
            for _, c in ipairs(centres) do
                if (c.X - l.X) ^ 2 + (c.Y - l.Y) ^ 2 + (c.Z - l.Z) ^ 2 < CHARGE_RADIUS ^ 2 then near = true break end
            end
            if not near or a:IsA(character) or m:GetFullName():find("Default__", 1, true) then return end
            local amount = m:GetTotalResourcesAmountForType(0)
            local key = keyOf(a)
            if amount <= 0 and not (chargeSent[key] and chargeSent[key] > 0) then return end
            chargeSent[key] = amount
            batch[#batch + 1] = key .. "=" .. string.format("%.1f", amount)
            if #batch >= CHARGE_BATCH then flush() end
        end)
    end
    flush()
end

local function receiveCharges(msg)
    local cls = StaticFindObject(MODULE_CLASS)
    for key, v in (msg[3] or ""):gmatch("([^;=]+)=([%d%.%-]+)") do
        pcall(function()
            local a = resolve(key)
            local m = a and a:GetComponentByClass(cls)
            if not (m and m:IsValid()) then return end
            local want = tonumber(v)
            local d = want - m:GetTotalResourcesAmountForType(0)
            if math.abs(d) < math.max(1, want * 0.02) then return end
            if d > 0 then m:ForceAddResource(0, d) else m:RemoveResource(0, -d, 2) end
        end)
    end
end

local function inventories()
    local list, seen = {}, {}
    for _, owner in ipairs({ localPC().Pawn, localPC() }) do
        local ok, comps = pcall(function() return owner:K2_GetComponentsByClass(StaticFindObject(INV_CLASS)) end)
        for _, c in ipairs((ok and comps) or {}) do
            local okG, obj = pcall(function() return c:get() end)
            local inv = (okG and obj) or c
            local addr = inv:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                list[#list + 1] = inv
            end
        end
    end
    return list
end

local function counts(item)
    local t = {}
    for _, inv in ipairs(inventories()) do
        local ok, k = pcall(function() return inv:GetNumItems(item) end)
        t[inv:GetAddress()] = { inv = inv, n = (ok and k) or 0 }
    end
    return t
end

local function describe(t)
    local parts = {}
    for _, e in pairs(t) do parts[#parts + 1] = e.inv:GetFName():ToString() .. "=" .. e.n end
    return table.concat(parts, " ")
end

-- Our own cable, removed by the other player through their copy: it is
-- unplugged with our own pawn, which reels it into our inventory with its
-- full length (destroying the actor or StartCableReelIn refunded nothing).
-- The refund is then taken out of the inventory that grew and sent to the
-- player who removed it.
local function giveAway(cable, key)
    givenAway[key] = now() + 5
    local utils = StaticFindObject("/Script/Voyage.Default__VoyageInventoryUtils")
    local okI, item = pcall(function() return utils:FindItemForActor(cable) end)
    local itemPath = okI and item and item:IsValid() and pathOf(item)
    local before = itemPath and counts(item) or {}
    local pawn = localPC().Pawn
    local a, b = plugsOf(cable)
    for _, sk in ipairs({ a, b }) do
        if sk ~= "-" and cable:IsValid() then
            local sock = findSocket(sk)
            local ok, err = pcall(function() sock:ReleaseSocketCable(pawn) end)
            log("kabel %s: borttagen av den andra, släpper %s: %s", key, sk, ok and "ok" or tostring(err))
        end
    end
    -- A mooring line belongs to the boat, not the inventory: unplugged it
    -- stood stiff at full length (2026-11-18). Removed, the boat's socket
    -- brings back its built-in line, folded up, as when the owner removes it.
    local okM, moor = pcall(function() return cable.bMooringCable end)
    if okM and moor then
        noteEmptied(a, b)
        if cable:IsValid() then cable:K2_DestroyActor() end
        log("kabel %s: förtöjningslina borttagen av den andra, båtens egen lina tillbaka", key)
        return
    end
    if cable:IsValid() then
        local ok, res = pcall(function() return cable:StartCableReelIn() end)
        log("kabel %s: kvar efter urkoppling, StartCableReelIn -> %s", key, tostring(res))
    end
    if not itemPath then log("kabel %s: hittar inte kabelns föremål, stannar här", key) return end
    ExecuteInGameThreadWithDelay(3000, function()
        local it = StaticFindObject(itemPath)
        local after = counts(it)
        log("kabel %s: före %s | efter %s", key, describe(before), describe(after))
        local sent = 0
        for addr, e in pairs(after) do
            local grew = e.n - ((before[addr] and before[addr].n) or 0)
            if grew > 0 then
                local ok, removed = pcall(function() return e.inv:RemoveItem(it, grew, -1, true) end)
                log("kabel %s: tar %d från %s -> %s, nu %s", key, grew, e.inv:GetFName():ToString(),
                    ok and tostring(removed) or tostring(removed), tostring(e.inv:GetNumItems(it)))
                if ok and removed and removed > 0 then sent = sent + removed end
            end
        end
        if sent > 0 then net.send("give", itemPath, sent) end
    end)
end

local PLAYER_INVENTORY = 1   -- EVoyageInventoryType::PlayerInventory

local function receiveGive(msg)
    local path, n = msg[3], tonumber(msg[4])
    local item = StaticFindObject(path)
    if not (item and item:IsValid()) or not n or n <= 0 then log("ge: okänt föremål %s", tostring(path)) return end
    local okP, inv = pcall(function() return localPC():GetInventoryComponent(PLAYER_INVENTORY) end)
    if not (okP and inv and inv:IsValid()) then log("ge: hittar inte spelarens inventarie") return end
    local before = inv:GetNumItems(item)
    local ok, err = pcall(function() inv:AddItems({ [item] = n }, true, true, 0) end)
    log("ge: %d st %s till %s: %s (%s -> %s)", n, path, inv:GetFName():ToString(), ok and "ok" or tostring(err),
        tostring(before), tostring(inv:GetNumItems(item)))
end

-- The other player removed their copy of our cable (picked it up, or the
-- game removed it when they unplugged it): the cable goes to them.
props_goneHook = function(owner, id)
    local cableClass = StaticFindObject("/Script/Voyage.ModulesConnectCable")
    if not (cableClass and cableClass:IsValid() and owner:IsA(cableClass)) then return false end
    local pc = owner:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local localId = pc and pc:IsValid() and tostring(pc.PersistentUniqueId)
    if localId and copies[localId] then return false end
    if localId then props.suppressGone(localId) end
    giveAway(owner, "i" .. id)
    return true
end


local goneEarly = {}         -- key -> time a gone message came for a cable we had no copy of
local consumedOf = {}        -- key -> the sender's ItemsConsumed
local looseInfo = {}         -- key -> { held, pos } for the sender's loose end
local retries = {}           -- key -> { n, at, path, args }: copies not yet plugged in as sent
local RETRY_COUNT, RETRY_SECONDS = 3, 1.5

local function applyCable(cable, key, sockA, sockB, class, maxLen, len)
    applyingCable[key] = now() + 3
    local pc = cable:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local localId = pc and pc:IsValid() and pc.PersistentUniqueId
    -- Only copies take the sender's length; an original keeps its own, which
    -- decides how much cable is refunded when it is removed.
    if copies[tostring(localId)] then
        setLength(cable, maxLen, len)
        -- The game saves ItemsConsumed and rebuilds the length from it on
        -- load: copies saved with 0 came back 96 cm long (2026-11-17).
        local consumed = consumedOf[key]
        if consumed then pcall(function() cable.ItemsConsumed = consumed end) end
    end
    local hereA, hereB = plugsOf(cable)
    if hereA == sockA and hereB == sockB then return end
    -- Unplugging through the game (ReleaseSocketCable) reels the cable into
    -- this player's inventory, so it is never used here.
    if (hereA ~= "-" and hereA ~= sockA) or (hereB ~= "-" and hereB ~= sockB) then
        if localId and localId ~= 0 then props.suppressGone(tostring(localId)) end
        if copies[tostring(localId)] then
            -- Our copy of their cable: they unplugged an end and hold it, so
            -- the copy is re-created with only the end that is still in.
            cable:K2_DestroyActor()
            log("kabel %s: urkopplad hos den andra, kopian borttagen", key)
            if sockA ~= "-" or sockB ~= "-" then spawnCopy(key, class or pathOf(cable:GetClass()), sockA, sockB, maxLen, len) end
        else
            -- Our own cable, unplugged by them through their copy (which the
            -- game removes at once).
            giveAway(cable, key)
        end
        return
    end
    -- A copy already plugged in at one end hardly ever took its second end
    -- (logs 2026-11-15/16: 0 of 10), while a fresh copy given both ends at
    -- once did about half the time; so it is made again with both.
    if copies[tostring(localId)] and sockA ~= "-" and sockB ~= "-" and (hereA == "-") ~= (hereB == "-") then
        if localId and localId ~= 0 then props.suppressGone(tostring(localId)) end
        local cls = class or pathOf(cable:GetClass())
        cable:K2_DestroyActor()
        log("kabel %s: andra änden kom, kopian görs om med båda", key)
        spawnCopy(key, cls, sockA, sockB, maxLen, len)
        return
    end
    -- A loose end in the other player's hand is put at their puppet (left near
    -- our own pawn it gets plugged into our character); one lying loose is put
    -- where it lies there.
    local loose = looseInfo[key]
    local held = not loose or loose.held
    local puppet = puppetOf()
    local hand = puppet and puppet:IsValid() and puppet:K2_GetActorLocation()
    if hand then hand.Z = hand.Z + 100 end
    if not held then hand = loose.pos end
    follow[key] = nil
    if held and copies[tostring(localId)] and (sockA == "-") ~= (sockB == "-") then
        follow[key] = { path = pathOf(cable), side = sockA == "-" and "SphereA" or "SphereB" }
    end
    for _, side in ipairs({ { sockA, hereA, cable.SphereA }, { sockB, hereB, cable.SphereB } }) do
        local want, have, sphere = side[1], side[2], side[3]
        if want ~= "-" and have ~= want then
            local sock = findSocket(want)
            if sock then
                sphere:K2_SetWorldLocation(sock:K2_GetComponentLocation(), false, {}, true)
            else
                log("kabel %s: uttag %s saknas här", key, want)
            end
        elseif want == "-" and hand then
            -- Out of reach while plugging in: at the hand it lay within 40 cm
            -- of the puppet's chest socket, the game found that socket for
            -- both ends and plugged in neither (2026-11-16).
            sphere:K2_SetWorldLocation({ X = hand.X, Y = hand.Y, Z = hand.Z + 200 }, false, {}, true)
        end
    end
    pcall(giveCableItem, cable)
    local okT, res = pcall(function() return cable:TryEstablishConnection(40) end)
    if hand then
        for _, side in ipairs({ { sockA, cable.SphereA }, { sockB, cable.SphereB } }) do
            if side[1] == "-" then side[2]:K2_SetWorldLocation(hand, false, {}, true) end
        end
    end
    -- Modules built from the other game's blueprint stand a little off, and
    -- the copy then would not plug in at one end (2026-11-15). Joining the two
    -- sockets directly gives the same power link, with the cable only drawn.
    local linked = ""
    if not (okT and res) and sockA ~= "-" and sockB ~= "-" then
        local sa, sb = findSocket(sockA), findSocket(sockB)
        if sa and sb then
            local okE = pcall(function() sa:EstablishConnection(sb, 1) end)
            linked = okE and string.format(", uttagen ihopkopplade direkt: %s", tostring(sa:IsSocketConnected())) or ", direktkoppling misslyckades"
        end
    end
    log("kabel %s: ska vara %s|%s, TryEstablishConnection %s, nu %s%s", key, sockA, sockB,
        tostring(res), stateOf(cable), linked)
    -- TryEstablishConnection often misses on the first try; a few more tries.
    local nowA, nowB = plugsOf(cable)
    local r = retries[key]
    if nowA == sockA and nowB == sockB then
        retries[key] = nil
    elseif not r or r.n < RETRY_COUNT then
        retries[key] = { n = (r and r.n or 0) + 1, at = now() + RETRY_SECONDS, path = pathOf(cable),
            args = { sockA, sockB, class, maxLen, len } }
    else
        retries[key] = nil
        -- A copy plugged in nowhere hangs loose and is pulled around by the
        -- game: the "ghost cables" on land (2026-11-16). Better none.
        local gone = ""
        -- Also one following the puppet: plugged in nowhere, it only hangs
        -- between the players.
        if copies[tostring(localId)] and nowA == "-" and nowB == "-" then
            follow[key] = nil
            if localId and localId ~= 0 then props.suppressGone(tostring(localId)) end
            pcall(function() cable:K2_DestroyActor() end)
            gone = ", lös kopia borttagen"
        end
        log("kabel %s: kopplas inte in efter %d försök%s", key, RETRY_COUNT + 1, gone)
    end
end

local function runRetries()
    for key, r in pairs(retries) do
        if now() >= r.at then
            local cable = StaticFindObject(r.path)
            if cable and cable:IsValid() then
                r.at = math.huge
                local a = r.args
                pcall(applyCable, cable, key, a[1], a[2], a[3], a[4], a[5])
                if retries[key] == r then retries[key] = nil end
            else
                retries[key] = nil
            end
        end
    end
end

-- A copy that keeps being re-created means the two games disagree about the
-- cable; giving up beats filling the world with cables.
local spawnLog = {}
local SPAWN_LIMIT, SPAWN_WINDOW = 3, 30

local skippedMooring = {}
spawnCopy = function(key, class, sockA, sockB, maxLen, len)
    -- A copy with one end never plugs in, and a mooring line's loose end is
    -- reeled in at the owner anyway: made, removed and made again, it stood
    -- 15 m straight up (2026-11-18). Such a line is not copied until both
    -- ends are in.
    if class and class:find("Mooring", 1, true) and (sockA == "-") ~= (sockB == "-") then
        if not skippedMooring[key] then
            skippedMooring[key] = true
            log("kabel %s: förtöjningslina med en lös ände, ingen kopia", key)
        end
        return
    end
    skippedMooring[key] = nil
    local recent = {}
    for _, t in ipairs(spawnLog[key] or {}) do if now() - t < SPAWN_WINDOW then recent[#recent + 1] = t end end
    if #recent >= SPAWN_LIMIT then
        if #recent == SPAWN_LIMIT then
            log("kabel %s: %d kopior på %d s, väntar med nästa", key, SPAWN_LIMIT, SPAWN_WINDOW)
        end
        spawnLog[key] = recent
        return recent[1] + SPAWN_WINDOW
    end
    recent[#recent + 1] = now()
    spawnLog[key] = recent
    local before = {}
    for _, c in ipairs(allCables()) do before[c:GetAddress()] = true end
    pendingCables[#pendingCables + 1] = { key = key, class = class, sockA = sockA, sockB = sockB, maxLen = maxLen, len = len, before = before, t = now() }
    -- class is the full class path; a cable type nobody has nearby is not
    -- loaded yet, and summon only finds loaded classes.
    local cls = StaticFindObject(class)
    if not (cls and cls:IsValid()) then
        local err
        for _, asset in ipairs({ (class:gsub("_C$", "")), class:match("^(.-)%.") or class }) do
            local ok, e = pcall(LoadAsset, asset)
            err = ok and "ingen klass" or tostring(e)
            cls = StaticFindObject(class)
            if cls and cls:IsValid() then break end
        end
        log("kabel %s: laddar klassen %s: %s", key, class, (cls and cls:IsValid()) and "ok" or tostring(err))
    end
    -- Host: a summoned cable got save id 0 and no RuntimeActorClass, so the
    -- guest's cables were not saved in the host's world. The game's own
    -- runtime spawn gives both (tested 2026-11-15); summon stays as fallback.
    if isHost and cls and cls:IsValid() then
        local okS, made = pcall(function()
            local pawn = localPC().Pawn
            local l = pawn:K2_GetActorLocation()
            return StaticFindObject("/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary"):SpawnRuntimeActorFromClass(pawn:GetWorld(), cls,
                { Translation = { X = l.X, Y = l.Y, Z = l.Z + 100 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } },
                { Value = 0 }, nil, nil)
        end)
        if okS and made and made:IsValid() then
            log("kabel %s: skapar %s som runtime-aktör", key, class)
            return
        end
        log("kabel %s: runtime-skapande misslyckades (%s), summon i stället", key, tostring(made))
    end
    console("summon " .. (class:match("%.([^%.]+)$") or class))
    log("kabel %s: skapar %s", key, class)
end

-- The guest's copies stay out of the save room and the Lazarus modules:
-- powering them there brought up the backup dialog in the guest's game, and
-- the backup belongs to the host's world. A room outlet has no link to its
-- room, so the save room's is the one with a save room light close by.
local SAVE_LIGHT = "LightBP_Scifi_Ceiling_SaveRoom_C"
local SAVE_ROOM_RADIUS = 1500

local function nearestSaveLight(actor)
    local ok, found = pcall(FindObjects, 0, SAVE_LIGHT, "", 0, 0, false)
    local here = actor:K2_GetActorLocation()
    local best
    for _, l in ipairs((ok and found) or {}) do
        pcall(function()
            if not l:IsValid() or l:GetFullName():find("Default__", 1, true) then return end
            local v = l:K2_GetActorLocation()
            local d = math.sqrt((v.X - here.X) ^ 2 + (v.Y - here.Y) ^ 2 + (v.Z - here.Z) ^ 2)
            if not best or d < best then best = d end
        end)
    end
    return best
end

local blockedEnds = {}      -- socket key -> true/false, decided once
local function blockedForGuest(key, sockKey)
    if isHost or sockKey == "-" then return false end
    if blockedEnds[sockKey] == nil then
        local ownerKey = sockKey:match("^(.*)#[^#]+$")
        local owner = ownerKey and resolve(ownerKey)
        if not owner then return false end
        local cls = className(owner)
        local block = cls:find("Lazarus", 1, true) ~= nil
        local dist
        if cls == "BP_Module_RoomOutlet_C" then
            dist = nearestSaveLight(owner)
            block = dist ~= nil and dist < SAVE_ROOM_RADIUS
        end
        blockedEnds[sockKey] = block
        log("kabel %s: ände i %s (%s%s)%s", key, sockKey, cls,
            dist and string.format(", sparrumslampa %.0f cm bort", dist) or "", block and " kopplas inte här" or "")
    end
    return blockedEnds[sockKey]
end

-- The guest's own cable there (loaded with the host's save) is removed only in
-- the guest's game; leaving an end loose would read as the guest unplugging
-- the host's cable.
local function dropForGuest(key)
    local cable = resolve(key)
    if not cable then return end
    local pc = cable:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
    local id = pc and pc:IsValid() and pc.PersistentUniqueId
    if id and id ~= 0 then props.suppressGone(tostring(id)) end
    cable:K2_DestroyActor()
    log("kabel %s: går till sparrummet, borttagen här", key)
end

-- Both games load the same save, so the player character has the same save
-- id in both: a cable the peer plugs into their own body named our body, and
-- charging one player charged the other. That end is in the peer's body, so
-- here it is a loose end at the puppet.
local function swapBodies(sockKey)
    if sockKey == "@jag#" .. BODY_SOCKET then return "@du#" .. PUPPET_SOCKET end
    if sockKey == "@du#" .. PUPPET_SOCKET then return "@jag#" .. BODY_SOCKET end
    return sockKey
end

local function bodyEnd(sockKey)
    sockKey = swapBodies(sockKey)
    if sockKey == "-" or sockKey:sub(1, 1) == "@" then return sockKey end
    local ownerKey = sockKey:match("^(.*)#[^#]+$")
    -- Equipment the other player carries (a charging cable in their pistol:
    -- …BP_FirstPersonCharacter_New_C1-1-DA_Weapon_ElectricPistol) has the
    -- same name as ours here; plugged into ours, the copy stuck (2026-11-15).
    -- That end is in their hand, so it follows the puppet.
    if ownerKey and ownerKey:find("BP_FirstPersonCharacter", 1, true) then return "-" end
    local owner = ownerKey and resolve(ownerKey)
    local pawn = localPC().Pawn
    if owner and pawn and pawn:IsValid() and owner:GetAddress() == pawn:GetAddress() then return "-" end
    return sockKey
end

local deferred = {}          -- key -> cable message held until the world has loaded
-- key -> { msg, at }: the newest message for a cable whose copies hit the
-- limit. Plugged and unplugged four times in 8 s, the guest's last plug never
-- reached the host and the recycler ran only for the guest (2026-11-17).
local limited = {}

local function handleCable(msg)
    local key, class = msg[3], msg[4]
    limited[key] = nil
    local sockA, sockB = bodyEnd(msg[5]), bodyEnd(msg[6])
    local maxLen, len = tonumber(msg[7]), tonumber(msg[8])
    if tonumber(msg[13]) then consumedOf[key] = tonumber(msg[13]) end
    if msg[9] then
        local x, y, z = tonumber(msg[10]), tonumber(msg[11]), tonumber(msg[12])
        looseInfo[key] = { held = msg[9] == "1", pos = x and y and z and { X = x, Y = y, Z = z } or nil }
        if not looseInfo[key].held and not looseInfo[key].pos then looseInfo[key].held = true end
    end
    if (givenAway[key] or 0) > now() then return end
    if blockedForGuest(key, sockA) or blockedForGuest(key, sockB) then dropForGuest(key) return end
    local cable = resolve(key)
    if cable then deferred[key] = nil applyCable(cable, key, sockA, sockB, class, maxLen, len) return end
    if key:sub(1, 1) ~= "i" then log("kabel %s finns inte här", key) return end
    if sockA == "-" and sockB == "-" then return end
    -- Right after loading, the cable may be in a part of the world that has not
    -- streamed in yet; a copy now would sit next to the real one. When every
    -- socket it wants is here and free, it is not waiting to load: a mooring
    -- line laid in the first minute reached the other game only after it
    -- (2026-11-16).
    local ready = true
    for _, sk in ipairs({ sockA, sockB }) do
        if sk ~= "-" then
            local sock = findSocket(sk)
            local okC, used = pcall(function() return sock:IsSocketConnected() end)
            if not sock or not okC or used then ready = false end
        end
    end
    if (not baselineAt or now() - baselineAt < LOAD_GRACE) and not ready then
        if not deferred[key] then log("kabel %s: inte inladdad än, väntar", key) end
        deferred[key] = msg
        return
    end
    -- A copy needs a socket here to hang from; without one it floats loose.
    local anchored = (sockA ~= "-" and findSocket(sockA)) or (sockB ~= "-" and findSocket(sockB))
    if not anchored then
        log("kabel %s: inget av uttagen %s|%s finns här, ingen kopia", key, sockA, sockB)
        return
    end
    log("kabel %s: längd max %s, kabel %s", key, tostring(maxLen), tostring(len))
    local waitUntil = spawnCopy(key, class, sockA, sockB, maxLen, len)
    if waitUntil then limited[key] = { msg = msg, at = waitUntil } end
end

local function adoptPending()
    if #pendingCables == 0 then return end
    local p = pendingCables[1]
    if now() - p.t < 0.5 then return end
    for _, c in ipairs(allCables()) do
        if not p.before[c:GetAddress()] then
            table.remove(pendingCables, 1)
            local pc = c:GetComponentByClass(StaticFindObject(PERSIST_CLASS))
            local id = pc and pc:IsValid() and pc.PersistentUniqueId
            if id and id ~= 0 then
                props.alias(p.key:sub(2), tostring(id), pc)
                copies[tostring(id)] = true
            end
            log("kabel %s: skapad som %s (id %s)", p.key, pathOf(c), tostring(id))
            if goneEarly[p.key] and now() - goneEarly[p.key] < 30 then
                goneEarly[p.key] = nil
                if id and id ~= 0 then props.suppressGone(tostring(id)) end
                pcall(function() c:K2_DestroyActor() end)
                log("kabel %s: redan borta hos den andra, kopian borttagen", p.key)
                return
            end
            if cableStates then cableStates[p.key] = p.sockA .. "|" .. p.sockB end
            log("kabel %s: standardlängd max %s, kabel %s", p.key, lengthOf(c))
            applyCable(c, p.key, p.sockA, p.sockB, p.class, p.maxLen, p.len)
            return
        end
    end
    if now() - p.t > 5 then
        table.remove(pendingCables, 1)
        log("kabel %s: summon gav ingen kabel", p.key)
    end
end

-- The host sends its whole cable and switch state when the guest says it is
-- ready, so whatever was done before the sync was armed is mirrored too.
local snapshotWanted = false

local function sendSnapshot()
    local cablesSent = 0
    for _, c in ipairs(allCables()) do
        local okK, key = pcall(keyOf, c)
        local okA, a, b = pcall(plugsOf, c)
        if okK and okA and key:sub(1, 1) == "i" then
            sendCable(key, c, a, b)
            cablesSent = cablesSent + 1
        end
    end
    local okF, found = pcall(FindObjects, 0, "VoyageModuleGenericSwitchActor", "", 0, 0, false)
    local n = 0
    for _, sw in ipairs((okF and found) or {}) do
        local okS, key, on = pcall(function()
            if not sw:IsValid() or sw:GetFullName():find("Default__", 1, true) then return nil end
            return keyOf(sw), sw:IsOn()
        end)
        if okS and key then
            net.send("switch", key, on and 1 or 0)
            n = n + 1
        end
    end
    log("läge skickat: %d kablar, %d brytare", cablesSent, n)
end

-- Module interface ----------------------------------------------------------

function M.setPuppetSocket(fn) puppetSocketPath = fn end

function M.init(netModule, logFn, localPCFn, nowFn, propsModule, consoleFn, hostRole, puppetFn)
    net, log, localPC, now, props = netModule, logFn, localPCFn, nowFn, propsModule
    puppetOf = puppetFn
    props.goneHook = props_goneHook
    -- The cable went before our copy of it existed (the guest unplugged its
    -- charging cable, the game reeled it in at once): the copy then hung at
    -- the puppet in the host's game (2026-11-16).
    props.missingGoneHook = function(id) goneEarly["i" .. id] = now() end
    isHost = hostRole
    console = consoleFn
end

local worldSince
function M.tick()
    worldSince = worldSince or now()
    if now() - worldSince < 0 then return end
    tryHookSwitch()
    local okR, errR = pcall(runRetries)
    if not okR then log("kabel-omförsök fel: %s", tostring(errR)) end
    if snapshotWanted then
        snapshotWanted = false
        local okSn, errSn = pcall(sendSnapshot)
        if not okSn then log("läges-fel: %s", tostring(errSn)) end
    end
    local q = switchQueue
    switchQueue = {}
    for _, sw in ipairs(q) do
        local okS, errS = pcall(processSwitch, sw)
        if not okS then log("brytar-fel: %s", tostring(errS)) end
    end
    if now() - worldSince < 3 then return end
    local due = {}
    for key, l in pairs(limited) do
        if now() >= l.at then due[#due + 1] = { key = key, msg = l.msg } end
    end
    for _, d in ipairs(due) do
        limited[d.key] = nil
        log("kabel %s: väntan slut, senaste läget används", d.key)
        local okL, errL = pcall(handleCable, d.msg)
        if not okL then log("kabel-fel: %s", tostring(errL)) end
    end
    if baselineAt and now() - baselineAt >= LOAD_GRACE and next(deferred) then
        local held = deferred
        deferred = {}
        for _, msg in pairs(held) do
            local okD, errD = pcall(handleCable, msg)
            if not okD then log("kabel-fel: %s", tostring(errD)) end
        end
    end
    for key, f in pairs(follow) do
        local okF = pcall(function()
            local c = StaticFindObject(f.path)
            local puppet = puppetOf()
            if not (c and c:IsValid()) then follow[key] = nil return end
            if not (puppet and puppet:IsValid()) then return end
            -- The other player's hand on the puppet (their weapon's socket when
            -- they hold one); a point above the puppet sat nowhere near it.
            local okG, gear = pcall(require, "gear")
            local hand = okG and gear.weaponSocketPoint(puppet)
            if not hand then
                hand = puppet:K2_GetActorLocation()
                hand.Z = hand.Z + 100
            end
            c[f.side]:K2_SetWorldLocation(hand, false, {}, true)
        end)
        if not okF then follow[key] = nil end
    end
    local okM, errM = pcall(keepMooringCopies)
    if not okM then log("kabel-fel: %s", tostring(errM)) end
    local okA, errA = pcall(adoptPending)
    if not okA then log("kabel-fel: %s", tostring(errA)) end
    local ok, err = pcall(pollCables)
    if not ok then log("kabel-fel: %s", tostring(err)) end
    if isHost then
        local okC, errC = pcall(sendCharges)
        if not okC then log("el-fel: %s", tostring(errC)) end
    end
end

M.findSocket, M.stateOf, M.keyOf, M.resolve = findSocket, stateOf, keyOf, resolve

function M.handle(msg)
    if msg[1] == "switch" then handleSwitch(msg) return true end
    if msg[1] == "cable" then handleCable(msg) return true end
    if msg[1] == "give" then receiveGive(msg) return true end
    if msg[1] == "charge" then
        if not isHost then receiveCharges(msg) end
        return true
    end
    if msg[1] == "ready" then
        if isHost then snapshotWanted = true log("gästen redo") end
        return true
    end
    return false
end

return M
