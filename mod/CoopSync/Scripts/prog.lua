-- Shared progression: level/exp, skills and enhancers live in the world save
-- (FGameProgress), so one world carries one progression for both players. While
-- both play, each side polls its own player state and sends a snapshot when it
-- changes; the receiver merges it upwards (progress never goes back).
local M = {}

local LIB = "/Script/Voyage.Default__VoyageGameplayBlueprintFunctionLibrary"
local POLL_SECONDS = 2
local SOURCE_UNKNOWN = 9    -- EVoyageExperienceType::Unknown

local net, log, localPC, now
local lastPoll, lastSent = 0, nil
local peer                  -- last snapshot received
local diagDone = false

local function pathOf(obj)
    return obj:GetFullName():match("%S+%s+(%S+)")
end

local function playerState()
    local pc = localPC()
    local ps = pc and pc.PlayerState
    if ps and ps:IsValid() then return pc, ps end
end

-- Out-parameter arrays came back empty from these calls, so the assets are
-- listed with FindObjects and checked one by one.
local function assets(className)
    local ok, found = pcall(FindObjects, 0, className, "", 0, 0, false)
    local list = {}
    for _, a in ipairs((ok and found) or {}) do
        local okV, valid = pcall(function() return a:IsValid() and not a:GetFullName():find("Default__", 1, true) end)
        if okV and valid then list[#list + 1] = a end
    end
    return list
end

local function skillsOf(ps)
    local list = {}
    for _, s in ipairs(assets("VoyageSkill")) do
        if ps:HasSkill(s) then list[#list + 1] = pathOf(s) end
    end
    table.sort(list)
    return list
end

-- The enhancer map is keyed by primary asset id; its name is the asset's name.
local function enhancersOf(ps)
    local byName = {}
    ps.PlayerGameProgress.Enhancers:ForEach(function(k, v)
        byName[k:get().PrimaryAssetName:ToString()] = v:get().Points
    end)
    local list = {}
    for _, e in ipairs(assets("VoyageEnhancer")) do
        local pts = byName[e:GetFName():ToString()]
        if pts and pts > 0 then list[#list + 1] = pathOf(e) .. "=" .. pts end
    end
    table.sort(list)
    return list
end

local function expOf(ps)
    local d = ps:GetPlayerProgressPersistentData()
    return d.Level, d.exp, d.LevelCapExp
end

-- Experience as one number, so two snapshots can be compared and the gap given.
local function totalExp(level, exp)
    local lib = StaticFindObject(LIB)
    return lib:GetTotalExpRequired(1, level) + exp
end

local function snapshot(ps)
    local level, exp, cap = expOf(ps)
    local okS, skills = pcall(skillsOf, ps)
    local okE, enh = pcall(enhancersOf, ps)
    if not diagDone then
        diagDone = true
        log("progression: nivå %d, exp %d, takexp %d, skills %s av %d, enhancers %s av %d", level, exp, cap,
            okS and #skills or tostring(skills), #assets("VoyageSkill"), okE and #enh or tostring(enh),
            #assets("VoyageEnhancer"))
    end
    return {
        level = level, exp = exp, cap = cap,
        skills = okS and skills or nil, enh = okE and enh or nil,
    }
end

local function encode(s)
    return s.level, s.exp, s.cap, table.concat(s.skills or {}, ","), table.concat(s.enh or {}, ",")
end

local function setOf(str)
    local set = {}
    for item in (str or ""):gmatch("[^,]+") do set[item] = true end
    return set
end

local function applyExp(ps, level, exp, cap)
    local myLevel, myExp, myCap = expOf(ps)
    local gap = totalExp(level, exp) - totalExp(myLevel, myExp)
    if gap > 0 then
        local ok, res = pcall(function() return ps:GainExp({ Source = SOURCE_UNKNOWN, Amount = gap }) end)
        local l2, e2 = expOf(ps)
        log("progression: exp +%d (GainExp %s) -> nivå %d exp %d, ska vara nivå %d exp %d",
            gap, ok and tostring(res) or tostring(res), l2, e2, level, exp)
        -- GainExp may scale the amount; the stored values are set to match.
        if l2 ~= level or e2 ~= exp then
            local okW, errW = pcall(function()
                local pd = ps.PlayerGameProgress.PlayerData
                pd.Level = level
                pd.exp = exp
            end)
            local l3, e3 = expOf(ps)
            log("progression: skrev nivå/exp direkt (%s) -> nivå %d exp %d", okW and "ok" or tostring(errW), l3, e3)
        end
    end
    local _, _, cap2 = expOf(ps)
    if cap > cap2 then
        local ok, err = pcall(function() ps.PlayerGameProgress.PlayerData.LevelCapExp = cap end)
        log("progression: takexp %d -> %d (%s)", cap2, cap, ok and "ok" or tostring(err))
    end
end

local function applySkills(ps, remote)
    local mine = setOf(table.concat(skillsOf(ps), ","))
    for path in pairs(remote) do
        if not mine[path] then
            local skill = StaticFindObject(path)
            if skill and skill:IsValid() then
                local ok, res = pcall(function() return ps:AddSkill(skill, true) end)
                log("progression: skill %s -> %s", path, ok and tostring(res) or tostring(res))
            else
                log("progression: hittar inte skill %s", path)
            end
        end
    end
end

local function applyEnhancers(ps, remote)
    local mine = {}
    for _, e in ipairs(enhancersOf(ps)) do
        local path, pts = e:match("^(.*)=(%d+)$")
        mine[path] = tonumber(pts)
    end
    for item in pairs(remote) do
        local path, pts = item:match("^(.*)=(%d+)$")
        pts = tonumber(pts)
        local have = mine[path] or 0
        if pts and pts > have then
            local enh = StaticFindObject(path)
            if enh and enh:IsValid() then
                local ok, res = pcall(function() return ps:AddEnhancer(enh, pts - have) end)
                local after = 0
                for _, e in ipairs(enhancersOf(ps)) do
                    local p2, n2 = e:match("^(.*)=(%d+)$")
                    if p2 == path then after = tonumber(n2) end
                end
                log("progression: enhancer %s %d -> %d (AddEnhancer +%d %s)", path, have, after, pts - have,
                    ok and tostring(res) or tostring(res))
            else
                log("progression: hittar inte enhancer %s", path)
            end
        end
    end
end

local function apply()
    local _, ps = playerState()
    if not (ps and peer) then return end
    local p = peer
    peer = nil
    local ok, err = pcall(applyExp, ps, p.level, p.exp, p.cap)
    if not ok then log("progression exp-fel: %s", tostring(err)) end
    ok, err = pcall(applySkills, ps, p.skills)
    if not ok then log("progression skill-fel: %s", tostring(err)) end
    ok, err = pcall(applyEnhancers, ps, p.enh)
    if not ok then log("progression enhancer-fel: %s", tostring(err)) end
    -- Whatever changed here is not news for the peer.
    lastSent = table.concat({ encode(snapshot(ps)) }, "|")
end

function M.init(netModule, logFn, localPCFn, nowFn)
    net, log, localPC, now = netModule, logFn, localPCFn, nowFn
end

-- The vault (the build menu) holds what the skills unlocked. A world saved
-- after a death comes back without the player and an empty vault while the
-- skills remain, so nothing could be built (2026-11-15). Once per loaded
-- world: if a held skill's item is missing from the vault, the skills are
-- added again and the game refills the vault as on unlocking.
local PLAYER_VAULT = 2
local vaultCheckedFor
local function checkVault(pc, ps)
    local vault = pc:GetInventoryComponent(PLAYER_VAULT)
    if not (vault and vault:IsValid()) then return end
    local held, missing = {}, nil
    for _, s in ipairs(assets("VoyageSkill")) do
        if ps:HasSkill(s) then
            held[#held + 1] = pathOf(s)
            pcall(function()
                s.Items:ForEach(function(_, e)
                    local it = e:get()
                    if it and it:IsValid() and vault:GetNumItems(it) == 0 then missing = missing or it:GetFName():ToString() end
                end)
            end)
        end
    end
    if not missing then return end
    ps.PlayerGameProgress.Skills:Empty()
    local n = 0
    for _, path in ipairs(held) do
        local s = StaticFindObject(path)
        if s and s:IsValid() and ps:AddSkill(s, false) then n = n + 1 end
    end
    log("progression: valvet saknade %s, %d av %d skills tillagda igen", missing, n, #held)
end

-- Scanning puts the item in the scanner's vault only (2026-11-15). New vault
-- items are sent and added to the other's vault; nothing is ever taken out.
local vaultKnown, vaultPrint = nil, nil

local function vaultItems(vault)
    local set = {}
    for _, e in ipairs(vault:GetAllItems() or {}) do
        local okG, it = pcall(function() return e:get() end)
        it = (okG and it) or e
        if it:IsValid() then set[pathOf(it)] = true end
    end
    return set
end

local function pollVault(pc)
    local vault = pc:GetInventoryComponent(PLAYER_VAULT)
    if not (vault and vault:IsValid()) then return end
    local fp = vault:GetTotalNumItems() .. ":" .. vault:GetNumOccupiedSlots()
    if fp == vaultPrint then return end
    vaultPrint = fp
    local set = vaultItems(vault)
    if vaultKnown then
        local new = {}
        for path in pairs(set) do if not vaultKnown[path] then new[#new + 1] = path end end
        if #new > 0 then
            table.sort(new)
            net.send("vault", table.concat(new, ";"))
            log("progression: nytt i valvet, skickat: %s", table.concat(new, ", "))
        end
    end
    vaultKnown = set
end

local function addToVault(list)
    local pc = localPC()
    local vault = pc and pc:GetInventoryComponent(PLAYER_VAULT)
    if not (vault and vault:IsValid()) then return end
    for path in (list or ""):gmatch("[^;]+") do
        local item = StaticFindObject(path)
        if not (item and item:IsValid()) then
            pcall(LoadAsset, path:match("^(.-)%.") or path)
            item = StaticFindObject(path)
        end
        if item and item:IsValid() and vault:GetNumItems(item) == 0 then
            local added = vault:AddItems({ [item] = 1 }, false, true, 0)
            log("progression: %s in i valvet från den andra: %s", path:match("[^%.]+$") or path, tostring(added))
        end
        if vaultKnown then vaultKnown[path] = true end
    end
end

function M.tick()
    if peer then apply() end
    local pcNow, psNow = playerState()
    if pcNow and pcNow:GetAddress() ~= vaultCheckedFor then
        vaultCheckedFor = pcNow:GetAddress()
        -- A new world: its vault is the starting point, nothing to send.
        vaultKnown, vaultPrint = nil, nil
        local okV, errV = pcall(checkVault, pcNow, psNow)
        if not okV then log("progression valv-fel: %s", tostring(errV)) end
    end
    if now() - lastPoll < POLL_SECONDS then return end
    lastPoll = now()
    local pcV, ps = playerState()
    if not ps then return end
    local okP, errP = pcall(pollVault, pcV)
    if not okP then log("progression valv-fel: %s", tostring(errP)) end
    local snap = snapshot(ps)
    local enc = table.concat({ encode(snap) }, "|")
    if enc ~= lastSent then
        lastSent = enc
        net.send("prog", encode(snap))
    end
end

function M.handle(msg)
    if msg[1] == "vault" then
        local ok, err = pcall(addToVault, msg[3])
        if not ok then log("progression valv-fel: %s", tostring(err)) end
        return true
    end
    if msg[1] ~= "prog" then return false end
    peer = {
        level = tonumber(msg[3]), exp = tonumber(msg[4]), cap = tonumber(msg[5]),
        skills = setOf(msg[6]), enh = setOf(msg[7]),
    }
    if not (peer.level and peer.exp and peer.cap) then peer = nil end
    return true
end

return M
