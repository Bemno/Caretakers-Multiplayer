-- The in-game (Esc) menu in multiplayer. The game's Save opens its slot list,
-- which writes singleplayer slots, and Load from file loads a singleplayer
-- world; both are hidden. The host gets "Save <world>", which saves straight
-- into the multiplayer world. The guest saves nothing: the host's world is
-- the one that counts.
local M = {}
local T = require("text")

local BTN_CLASS = "/Game/UI/Focusable/BP_FocusableButton.BP_FocusableButton_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local RF_CLASS_DEFAULT = 0x10
local VISIBLE, COLLAPSED = 0, 1

local log, localPC, lobby
local doneFor            -- address of the menu we changed
local ours = {}          -- address -> action
local hoverWas, pending
local savedAt = 0

local function findMenu()
    -- The menu sits inside the game's overlay widget, so it is never "in the
    -- viewport" itself; an open menu is the one that has a parent.
    local ok, found = pcall(FindObjects, 0, "BP_VoyageInGameMenu_C", "", 0, RF_CLASS_DEFAULT, true)
    if ok and found and #found > 0 and not M.reported then
        M.reported = true
        for _, m in ipairs(found) do
            pcall(function()
                local p = m:GetParent()
                log("pausmeny hittad: %s synlig %s i vy %s förälder %s", m:GetFullName(), tostring(m:IsVisible()),
                    tostring(m:IsInViewport()), (p and p:IsValid()) and p:GetFullName() or "-")
            end)
        end
    end
    for _, m in ipairs((ok and found) or {}) do
        local okV, v = pcall(function()
            if not (m:IsValid() and m:IsVisible()) then return false end
            if m:IsInViewport() then return true end
            local p = m:GetParent()
            return p ~= nil and p:IsValid()
        end)
        if okV and v then return m end
    end
end

local function children(panel)
    local out = {}
    local ok, arr = pcall(function() return panel:GetAllChildren() end)
    for _, c in ipairs((ok and arr) or {}) do
        local okW, w = pcall(function() return c:get() end)
        w = okW and w or c
        if w and w:IsValid() then out[#out + 1] = w end
    end
    return out
end

local function slotOf(w)
    local s = w.Slot
    return { Padding = s.Padding, H = s.HorizontalAlignment, V = s.VerticalAlignment, Size = s.Size }
end

local function applySlot(slot, src)
    if not (slot and slot:IsValid() and src) then return end
    pcall(function() slot:SetPadding(src.Padding) end)
    pcall(function() slot:SetHorizontalAlignment(src.H) end)
    pcall(function() slot:SetVerticalAlignment(src.V) end)
    pcall(function() slot:SetSize(src.Size) end)
end

local function saveLabel()
    if os.time() - savedAt < 3 then return T("saved", lobby.world()) end
    return T("save_world", lobby.world())
end

-- Our button takes the place of Save: the buttons from Save down are taken
-- out and put back after it (UMG has no insert).
local function change(menu)
    local save = menu.SaveBtn
    local panel = save:GetParent()
    save:SetVisibility(COLLAPSED)
    pcall(function() menu.LoadFromFileBtn:SetVisibility(COLLAPSED) end)
    ours = {}
    if lobby.role() ~= "host" then return end
    local tail, moving = {}, false
    for _, w in ipairs(children(panel)) do
        if w:GetAddress() == save:GetAddress() then moving = true end
        if moving then tail[#tail + 1] = { w = w, slot = slotOf(w) } end
    end
    for _, t in ipairs(tail) do panel:RemoveChild(t.w) end
    local btn = StaticFindObject(WBL):Create(menu, StaticFindObject(BTN_CLASS), localPC())
    if btn and btn:IsValid() then
        require("menu").copyLook(save, btn)
        applySlot(panel:AddChild(btn), slotOf(menu.ContinueBtn))
        btn:SetText(FText(saveLabel()), 0)
        btn:SetVisibility(VISIBLE)
        ours[btn:GetAddress()] = "save"
    end
    for _, t in ipairs(tail) do applySlot(panel:AddChild(t.w), t.slot) end
end

local function pollHover(menu)
    local hovered
    for _, w in ipairs(children(menu.SaveBtn:GetParent())) do
        local a = w:GetAddress()
        if ours[a] then
            if w:IsHovered() then hovered = a end
            pcall(function() w:SetText(FText(saveLabel()), 0) end)
        end
    end
    hoverWas = hovered
end

function M.mouse(msg)
    if msg[3] == "1" and hoverWas and ours[hoverWas] then pending = ours[hoverWas] end
end

function M.init(logFn, localPCFn, lobbyModule)
    log, localPC, lobby = logFn, localPCFn, lobbyModule
end

-- The guest saves its local copy every few minutes only to keep the game's
-- autosave off the singleplayer slots; the game's save notices are hidden there.
local SAVE_NOTICES = { "BP_SaveGameIndicator_C", "BP_AutoSaveGameIndicator_C", "BP_CloudSaveGameNotificationWidget_C" }
local lastNoticeCheck = 0
local function hideSaveNotices()
    if lobby.role() ~= "guest" or os.clock() - lastNoticeCheck < 0.25 then return end
    lastNoticeCheck = os.clock()
    for _, cls in ipairs(SAVE_NOTICES) do
        local ok, found = pcall(FindObjects, 0, cls, "", 0, RF_CLASS_DEFAULT, true)
        for _, w in ipairs((ok and found) or {}) do
            pcall(function()
                if w:IsValid() and w:GetVisibility() ~= COLLAPSED then w:SetVisibility(COLLAPSED) end
            end)
        end
    end
end

-- The save terminal on the boat's wall shows the game's slot list, which saves
-- to and loads from the singleplayer slots (user 2026-11-19). In multiplayer every
-- open slot list has its slots hidden and says where the world is saved instead.
local lastSlotCheck = 0
local blockedLists = {}
local function blockSlotLists()
    if os.clock() - lastSlotCheck < 0.5 then return end
    lastSlotCheck = os.clock()
    local ok, found = pcall(FindObjects, 0, "VoyageSaveGameSlotsWidget", "", 0, RF_CLASS_DEFAULT, false)
    for _, w in ipairs((ok and found) or {}) do
        pcall(function()
            if not (w:IsValid() and w:IsVisible()) then return end
            w:SetAllSlotVisibility(COLLAPSED)
            w:SetAllSlotsState(false)
            pcall(function() w.EmptyTB:SetText(FText(T(lobby.role() == "host" and "slots_host" or "slots_guest"))) end)
            pcall(function() w.EmptyOverlay:SetVisibility(VISIBLE) end)
            local a = w:GetAddress()
            if not blockedLists[a] then
                blockedLists[a] = true
                log("spellistan med sparplatser dold i multiplayer: %s", w:GetFName():ToString())
            end
        end)
    end
end

-- Runs in the world while a multiplayer role is set.
function M.tick()
    pcall(hideSaveNotices)
    pcall(blockSlotLists)
    local menu = findMenu()
    if not menu then doneFor, ours, hoverWas, pending = nil, {}, nil, nil return end
    local a = menu:GetAddress()
    if doneFor ~= a then
        doneFor = a
        local ok, err = pcall(change, menu)
        if not ok then log("pausmeny-fel: %s", tostring(err)) end
        log("pausmeny: Save/Load dolda (%s)", tostring(lobby.role()))
    end
    -- The game may show its buttons again when the menu reopens.
    pcall(function()
        if menu.SaveBtn:GetVisibility() ~= COLLAPSED then menu.SaveBtn:SetVisibility(COLLAPSED) end
        if menu.LoadFromFileBtn:GetVisibility() ~= COLLAPSED then menu.LoadFromFileBtn:SetVisibility(COLLAPSED) end
    end)
    if pending == "save" then
        pending = nil
        if lobby.saveNow() then savedAt = os.time() end
    end
    pollHover(menu)
end

return M
