-- The guest's own inventory. The guest loads the host's save, which carries the
-- host's inventory; that is replaced by the guest's own, kept in a file per
-- host and world on the guest's computer (empty the first time). The vault is
-- left alone: it follows the shared skills.
local M = {}

local INV_CLASS = "/Script/Voyage.VoyageBaseInventoryComponent"
local VAULT = 2             -- EVoyageInventoryType::PlayerVault
local SAVE_SECONDS = 20

local log, localPC, lobby, ioName, props
local restored = false
local keysLogged = false
local lastSave = 0

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function filePath()
    local key = lobby.guestKey()
    return key and ("ue4ss/Mods/CoopSync/io/" .. ioName .. "/inv_" .. key .. ".txt")
end

-- The host's own player, kept by the mod: after a death the game saves the
-- world without the player (inventories, vault, battery, health all reset).
local function hostFilePath()
    local world = lobby.world()
    return world and ("ue4ss/Mods/CoopSync/io/" .. ioName .. "/spelare_" .. world .. ".txt")
end

local includeVault = false
local HOST_RESTORE_DELAY = 20
local hostSeen, hostBroken

local function inventories()
    local list, seen = {}, {}
    for _, owner in ipairs({ localPC().Pawn, localPC() }) do
        local ok, comps = pcall(function() return owner:K2_GetComponentsByClass(StaticFindObject(INV_CLASS)) end)
        for _, c in ipairs((ok and comps) or {}) do
            local okG, obj = pcall(function() return c:get() end)
            local inv = (okG and obj) or c
            local okT, t = pcall(function() return inv.Type end)
            local addr = inv:GetAddress()
            if not seen[addr] and (includeVault or not (okT and t == VAULT)) then
                seen[addr] = true
                list[#list + 1] = inv
            end
        end
    end
    return list
end

-- One line per occupied slot: inventory|slot|item path|count|flags|version|bytes
local function snapshot()
    local lines, unreadable = {}, 0
    for _, inv in ipairs(inventories()) do
        local name = inv:GetFName():ToString()
        local byName = {}
        local okA, all = pcall(function() return inv:GetAllItems() end)
        -- Returned as a plain Lua table of item objects.
        for _, e in ipairs((okA and type(all) == "table" and all) or {}) do
            local okG, it = pcall(function() return e:get() end)
            it = (okG and it) or e
            if it:IsValid() then byName[it:GetFName():ToString()] = pathOf(it) end
        end
        -- Some inventories report a huge slot count; the guest hung looping it.
        for i = 0, math.min(inv:GetLastOccupiedSlot(), 2000) do
            if inv:IsSlotOccupied(i) then
                local o = {}
                if inv:GetSlot(i, o) then
                    local s = o.OutItemData or (o.AssetName and o)
                    if not s then
                        if not keysLogged then
                            keysLogged = true
                            local keys = {}
                            for k, v in pairs(o) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
                            log("inventarie: GetSlot gav %s", table.concat(keys, ", "))
                        end
                    end
                    local path = s and byName[s.AssetName:ToString()]
                    if not s then
                        unreadable = unreadable + 1
                    elseif path then
                        local bytes = {}
                        local raw = s.Data.ItemData
                        if type(raw) == "table" then
                            -- UE4SS 4 gives RemoteUnrealParams; tostring wrote their addresses.
                            for _, v in ipairs(raw) do bytes[#bytes + 1] = tostring(type(v) == "number" and v or v:get()) end
                        else
                            pcall(function() raw:ForEach(function(_, v) bytes[#bytes + 1] = tostring(v:get()) end) end)
                        end
                        lines[#lines + 1] = table.concat({ name, i, path, s.Data.ItemCount, s.Data.Flags, s.Data.Version,
                            table.concat(bytes, ",") }, "|")
                    else
                        unreadable = unreadable + 1
                        log("inventarie: hittar inte föremålet %s i %s", s.AssetName:ToString(), name)
                    end
                end
            end
        end
    end
    return lines, unreadable
end

local SURV = "/Script/Voyage.VoyageSurvivalComponent"
local HEALTH, ELECTRICITY = 8, 0

local function survival(p) return p:GetComponentByClass(StaticFindObject(SURV)) end

-- GetSlot (and GetAttributeValue) have out parameters, which UE4SS 3.0.1
-- never frees (see boat.moveActor): an inventory whose item counts, last slot
-- and battery have not changed is read in full again only every FULL_EVERY.
local FULL_EVERY = 900
local lastPrint, lastFull = nil, -1e9

local function fingerprint()
    local parts = {}
    for _, inv in ipairs(inventories()) do
        parts[#parts + 1] = string.format("%s:%d:%d", inv:GetFName():ToString(), inv:GetTotalNumItems(), inv:GetLastOccupiedSlot())
    end
    pcall(function()
        parts[#parts + 1] = string.format("%.0f", localPC().Pawn.PlayerModuleComponent:GetResourceAmount(ELECTRICITY) / 25)
    end)
    return table.concat(parts, "|")
end

local function save(path, extra)
    if not path then return end
    local okF, fp = pcall(fingerprint)
    if okF and fp == lastPrint and os.time() - lastFull < FULL_EVERY then return end
    local lines, unreadable = snapshot()
    -- A partial file would lose the rest of the guest's things next time.
    if unreadable > 0 then return end
    lastPrint, lastFull = okF and fp or nil, os.time()
    if type(extra) == "function" then extra = extra() end
    if extra then table.insert(lines, 1, extra) end
    local f = io.open(path, "w")
    if not f then return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

local function bodyLine(p)
    local h = {}
    survival(p):GetAttributeValue(HEALTH, h)
    return string.format("#kropp|%.3f|%.3f", p.PlayerModuleComponent:GetResourceAmount(ELECTRICITY), h.OutValue or 0)
end

local function setBody(p, battery, health)
    local pm = p.PlayerModuleComponent
    local cur = pm:GetResourceAmount(ELECTRICITY)
    if battery > cur then
        if pm:AddResource(ELECTRICITY, battery - cur) <= 0 then pm:ForceAddResource(ELECTRICITY, battery - cur) end
    elseif battery < cur then
        pm:RemoveResource(ELECTRICITY, cur - battery, 0)
    end
    if health > 0 then survival(p):SetAttributeValue(HEALTH, health, true) end
end

local function itemCount()
    local n = 0
    for _, inv in ipairs(inventories()) do
        local ok, all = pcall(function() return inv:GetAllItems() end)
        n = n + #((ok and type(all) == "table" and all) or {})
    end
    return n
end

local function loadItem(path)
    local item = StaticFindObject(path)
    if not (item and item:IsValid()) then
        pcall(LoadAsset, path:match("^(.-)%.") or path)
        item = StaticFindObject(path)
    end
    return item and item:IsValid() and item or nil
end

local pendingWorn  -- worn items laid down at restore, waiting for their state

local function restore(path, clear)
    local byName = {}
    for _, inv in ipairs(inventories()) do byName[inv:GetFName():ToString()] = inv end
    if clear then
        -- Emptying destroys the equipped items' actors, which share save ids
        -- with the host's (same save): their removal must not reach the host.
        props.muteGone(5)
        for name, inv in pairs(byName) do
            local ok, err = pcall(function() inv:ClearItems(true) end)
            if not ok then log("inventarie: tömma %s: %s", name, tostring(err)) end
        end
    end
    local f = path and io.open(path, "r")
    if not f then
        log("inventarie: inget sparat för %s, börjar tomt", tostring(path))
        return
    end
    local n, failed = 0, 0
    -- Adding to the equipment spawns the item's actor from inside the mod's
    -- call, which crashed UE4SS (headlight), also in the backpack where the
    -- game puts it on at once, and in a free vault slot next to another
    -- headlight. Worn things are dropped in front of the player instead, to be
    -- picked up and put on by hand.
    local lines, worn = {}, {}
    for line in f:lines() do
        -- The weapon holster too: the guest died putting its pistol back (2026-11-15).
        if line:match("^EquipmentComponent|") or line:match("^WeaponHolsterComponent|") then worn[#worn + 1] = line else lines[#lines + 1] = line end
    end
    local wornItems = {}
    for _, line in ipairs(worn) do
        local itemPath, count, flags, bytes = line:match("^[^|]*|%d+|([^|]*)|(%d+)|(%d+)|%-?%d+|(.*)$")
        local item = itemPath and loadItem(itemPath)
        local list = {}
        if bytes and not bytes:find("Remote", 1, true) then
            for b in bytes:gmatch("%d+") do list[#list + 1] = tonumber(b) end
        end
        if item then wornItems[#wornItems + 1] = { item = item, count = tonumber(count), path = itemPath, flags = tonumber(flags), bytes = list } end
    end
    for _, line in ipairs(lines) do
        local name, slot, itemPath, count, flags, version, bytes = line:match("^([^|]*)|([%dledig]+)|([^|]*)|(%d+)|(%d+)|(%-?%d+)|(.*)$")
        local inv = name and byName[name]
        if inv and slot == "ledig" then slot = tostring(inv:GetNextEmptySlot()) end
        local item = itemPath and loadItem(itemPath)
        local battery, health = line:match("^#kropp|([%d%.]+)|([%d%.]+)$")
        if battery then
            local ok, err = pcall(setBody, localPC().Pawn, tonumber(battery), tonumber(health))
            log("spelare: batteri %s, liv %s: %s", battery, health, ok and "ok" or tostring(err))
        elseif inv and item then
            local data = { ItemCount = tonumber(count), Flags = tonumber(flags), Version = tonumber(version) }
            local list = {}
            -- Old files hold addresses ("RemoteUnrealParam: 0000...") instead of bytes.
            if not bytes:find("Remote", 1, true) then
                for b in bytes:gmatch("%d+") do list[#list + 1] = tonumber(b) end
            end
            log("inventarie: lägger %s i %s plats %s", itemPath:match("[^%.]+$") or itemPath, name, slot)
            -- A byte list in the struct crashed the game (UE4SS 4, drops.lua): the
            -- item goes in without its state, which is then written into the slot.
            local okA, added = pcall(function() return inv:AddToSlot(item, tonumber(slot), data, true) end)
            if okA and added and added > 0 and #list > 0 then
                local okS, errS = pcall(function()
                    inv.Items:ForEach(function(k, v)
                        if k:get() ~= tonumber(slot) then return end
                        local arr = v:get().Data.ItemData
                        for i, b in ipairs(list) do arr[i] = b end
                    end)
                end)
                log("inventarie: tillstånd för %s (%d byte): %s", itemPath:match("[^%.]+$") or itemPath, #list, okS and "ok" or tostring(errS))
            end
            if okA and added and added > 0 then n = n + 1 else failed = failed + 1 log("inventarie: kunde inte lägga %s i %s: %s", itemPath, name, tostring(added)) end
        elseif line ~= "" then
            failed = failed + 1
            log("inventarie: hoppar över %s", line:sub(1, 120))
        end
    end
    f:close()
    if #wornItems > 0 then
        -- Our own things laid down here are not drops for the other game.
        props.dropQuietUntil = os.time() + 5
        local okD, errD = pcall(function()
            local pawn = localPC().Pawn
            local l, fw = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            local items = {}
            for _, w in ipairs(wornItems) do items[w.item] = (items[w.item] or 0) + w.count end
            local transform = {
                Translation = { X = l.X + fw.X * 120, Y = l.Y + fw.Y * 120, Z = l.Z + 40 },
                Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 },
            }
            StaticFindObject("/Script/Voyage.Default__VoyageInventoryUtils"):SpawnActorsForItems(
                pawn:GetWorld(), transform, items, { bSimulatePhysics = true, bAwake = true }, 0)
            -- Spawned without their own state, weapons were sometimes recycled into
            -- materials when picked up (todo 21/11); the state is written into each
            -- one's slot once they exist (wornTick).
            local withState = {}
            for _, w in ipairs(wornItems) do if #w.bytes > 0 then withState[#withState + 1] = w end end
            if #withState > 0 then pendingWorn = { at = os.clock() + 1, loc = transform.Translation, items = withState, tries = 0 } end
        end)
        for _, w in ipairs(wornItems) do log("inventarie: buren %s läggs på marken: %s", w.path:match("[^%.]+$") or w.path, okD and "ok" or tostring(errD)) end
    end
    log("inventarie: återställt %d platser (%d misslyckades) från %s", n, failed, path)
end

local INV_COMP = "/Script/Voyage.VoyageBaseInventoryComponent"
local function wornTick()
    if not pendingWorn or os.clock() < pendingWorn.at then return end
    local pw = pendingWorn
    pw.tries, pw.at = pw.tries + 1, os.clock() + 1
    local cls = StaticFindObject(INV_COMP)
    for _, a in ipairs(FindObjects(0, "BP_DynamicMeshActor_C", "", 0, 0x30, false) or {}) do
        pcall(function()
            if not a:IsValid() then return end
            local l = a:K2_GetActorLocation()
            if (l.X - pw.loc.X) ^ 2 + (l.Y - pw.loc.Y) ^ 2 + (l.Z - pw.loc.Z) ^ 2 > 600 ^ 2 then return end
            local inv = a:GetComponentByClass(cls)
            if not (inv and inv:IsValid()) then return end
            for i, w in ipairs(pw.items) do
                if inv:GetNumItems(w.item) > 0 then
                    local done = false
                    inv.Items:ForEach(function(_, v)
                        if done then return end
                        local data = v:get().Data
                        local arr = data.ItemData
                        if arr:GetArrayNum() > 0 then return end
                        for j, b in ipairs(w.bytes) do arr[j] = b end
                        if w.flags then data.Flags = w.flags end
                        done = true
                    end)
                    if done then
                        log("inventarie: tillstånd för buren %s (%d byte) på marken", w.path:match("[^%.]+$") or w.path, #w.bytes)
                        table.remove(pw.items, i)
                        return
                    end
                end
            end
        end)
    end
    if #pw.items == 0 or pw.tries >= 5 then
        for _, w in ipairs(pw.items) do log("inventarie: hittade inte buren %s på marken", w.path) end
        pendingWorn = nil
    end
end

function M.init(logFn, localPCFn, lobbyModule, io, propsModule)
    log, localPC, lobby, ioName, props = logFn, localPCFn, lobbyModule, io, propsModule
end

local function hasLines(path)
    local f = path and io.open(path, "r")
    if not f then return false end
    local any = false
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then any = true break end
    end
    f:close()
    return any
end

-- The host: a world loaded with an empty player while the mod's copy has
-- things is one saved after a death; the copy is put back.
local function hostTick(now, p)
    local path = hostFilePath()
    if not path then return end
    includeVault = true
    if not restored then
        -- Adding items spawns the equipped ones; at the moment the mod
        -- registers its hooks after the load that crashed UE4SS.
        hostSeen = hostSeen or now
        if now - hostSeen < HOST_RESTORE_DELAY then return end
        restored = true
        lastSave = now
        local n = itemCount()
        if n == 0 and hasLines(path) then
            log("spelare: världen laddades utan spelare, lägger tillbaka från %s", path)
            local src = io.open(path, "r")
            local bak = src and io.open(path .. ".bak", "w")
            if bak then bak:write(src:read("*a")) bak:close() end
            if src then src:close() end
            local ok, err = pcall(restore, path, false)
            if not ok then
                hostBroken = true
                log("spelare-fel vid återställning, sparar inte över filen: %s", tostring(err))
            end
        else
            log("spelare: %d föremål i världen, ingen återställning", n)
        end
        return
    end
    if hostBroken or now - lastSave < SAVE_SECONDS then return end
    lastSave = now
    local okD, dead = pcall(function() return survival(p):IsDead() end)
    if not okD or dead then return end
    local ok, err = pcall(save, path, function() return bodyLine(p) end)
    if not ok then log("spelare-fel vid sparning: %s", tostring(err)) end
end

-- Called on the mod tick once the world has settled (main.lua waits 30 s).
function M.tick(now)
    local okW, errW = pcall(wornTick)
    if not okW then pendingWorn = nil log("inventarie: tillstånd på marken: %s", tostring(errW)) end
    local p = localPC().Pawn
    if not (p and p:IsValid()) then return end
    if lobby.role() == "host" then return hostTick(now, p) end
    if lobby.role() ~= "guest" or not lobby.guestKey() then return end
    includeVault = false
    if not restored then
        restored = true
        local ok, err = pcall(restore, filePath(), true)
        if not ok then log("inventarie-fel vid återställning: %s", tostring(err)) end
        lastSave = now
        return
    end
    if now - lastSave >= SAVE_SECONDS then
        lastSave = now
        local ok, err = pcall(save, filePath())
        if not ok then log("inventarie-fel vid sparning: %s", tostring(err)) end
    end
end

-- A new world load starts over.
function M.reset() restored, hostSeen, pendingWorn = false, nil, nil end

return M
