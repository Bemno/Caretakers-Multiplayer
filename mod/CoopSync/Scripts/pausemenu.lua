-- The in-game (Esc) menu in multiplayer. The game's Save opens its slot list,
-- which writes singleplayer slots, and Load from file loads a singleplayer
-- world; both are hidden. The host gets "Save <world>", which saves straight
-- into the multiplayer world. The guest saves nothing: the host's world is
-- the one that counts.
local M = {}
local T = require("text")
local bugreport = require("bugreport")

local BTN_CLASS = "/Game/UI/Focusable/BP_FocusableButton.BP_FocusableButton_C"
local BOX_CLASS = "/Game/UI/Focusable/BP_FocusableTextBox.BP_FocusableTextBox_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local RF_CLASS_DEFAULT = 0x10
local VISIBLE, COLLAPSED = 0, 1

local log, localPC, lobby
local doneFor            -- address of the menu we changed
local ours = {}          -- address -> action
local hoverWas, pending
local savedAt = 0
-- Load world… opens a page in the same panel listing the multiplayer worlds
-- (user 2026-11-21); picking one loads it and the guest follows.
local page = "main"
local made = {}          -- address -> true for every button the mod put in the panel
local hidden = {}        -- address -> visibility of a game button hidden on the list page
local listSig
local boxAddr, focusBox     -- the report text box, while the report page is open
local SLOTS = 10

-- The menu sits inside the game's overlay widget, so it is never "in the
-- viewport" itself; an open menu is the one that has a parent.
local function isOpen(m)
    if not (m:IsValid() and m:IsVisible()) then return false end
    if m:IsInViewport() then return true end
    local p = m:GetParent()
    return p ~= nil and p:IsValid()
end

-- Searching every object for the menu each tick cost 0.3-0.6 ms (2026-11-21).
-- The widget stays when closed, so once found its path is checked instead,
-- and a new search is made at most every MENU_SEARCH_GAP seconds.
local menuPath, lastMenuSearch = nil, -100
local MENU_SEARCH_GAP = 0.5

local function findMenu()
    if menuPath then
        local m = StaticFindObject(menuPath)
        if m and m:IsValid() then
            local okO, open = pcall(isOpen, m)
            if okO and open then return m end
        else
            menuPath = nil
        end
    end
    if os.clock() - lastMenuSearch < MENU_SEARCH_GAP then return nil end
    lastMenuSearch = os.clock()
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
        local okV, v = pcall(isOpen, m)
        if okV and v then
            menuPath = m:GetFullName():match("%S+%s+(%S+)")
            return m
        end
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

local function labelOf(action)
    if action == "save" then return saveLabel() end
    if action == "load" then return T("load_list") end
    if action == "back" then return T("back") end
    if action == "report" then return T("report_bug") end
    if action == "send" then return bugreport.status() ~= "" and bugreport.status() or T("send") end
    local empty = tonumber(action:match("^e:(%d+)$"))
    if empty then return T("slot", empty, T("empty")) end
    local name = action:match("^w:(.*)$") or action
    local n = tonumber(name:match("^[Ss]lot(%d+)$"))
    if not n then return name end
    for _, w in ipairs(lobby.worlds) do
        if w.name == name and w.time then return T("slot", n, os.date("%Y-%m-%d %H:%M", w.time)) end
    end
    return "Slot " .. n
end

-- Buttons the mod made earlier are taken out first, so a menu the game opens
-- again never gets them twice.
local function removeMade(panel)
    for _, w in ipairs(children(panel)) do
        if made[w:GetAddress()] then panel:RemoveChild(w) end
    end
    made, ours, boxAddr, focusBox = {}, {}, nil, false
end

local function restoreHidden(panel)
    for _, w in ipairs(children(panel)) do
        local v = hidden[w:GetAddress()]
        if v ~= nil then pcall(function() w:SetVisibility(v) end) end
    end
    hidden = {}
end

local function addButton(menu, panel, action, slot)
    local btn = StaticFindObject(WBL):Create(menu, StaticFindObject(BTN_CLASS), localPC())
    if not (btn and btn:IsValid()) then return end
    require("menu").copyLook(menu.SaveBtn, btn)
    applySlot(panel:AddChild(btn), slot)
    btn:SetText(FText(labelOf(action)), 0)
    btn:SetVisibility(VISIBLE)
    made[btn:GetAddress()] = true
    ours[btn:GetAddress()] = action
end

-- Our buttons take the place of Save: the buttons from Save down are taken
-- out and put back after them (UMG has no insert).
local function change(menu)
    local save = menu.SaveBtn
    local panel = save:GetParent()
    removeMade(panel)
    restoreHidden(panel)
    page = "main"
    save:SetVisibility(COLLAPSED)
    pcall(function() menu.LoadFromFileBtn:SetVisibility(COLLAPSED) end)
    local actions = lobby.role() == "host" and { "save", "load", "report" } or { "report" }
    local tail, moving = {}, false
    for _, w in ipairs(children(panel)) do
        if w:GetAddress() == save:GetAddress() then moving = true end
        if moving then tail[#tail + 1] = { w = w, slot = slotOf(w) } end
    end
    for _, t in ipairs(tail) do panel:RemoveChild(t.w) end
    for _, action in ipairs(actions) do addButton(menu, panel, action, slotOf(menu.ContinueBtn)) end
    for _, t in ipairs(tail) do applySlot(panel:AddChild(t.w), t.slot) end
end

-- The ten multiplayer slots as on the Host page (user 2026-11-21): a slot's
-- world is loaded, an empty slot makes a new world there (user 2026-11-23).
-- Other named worlds are not listed.
local function worldList()
    local byNo = {}
    for _, w in ipairs(lobby.worlds) do
        local n = tonumber(w.name:match("^[Ss]lot(%d+)$"))
        if n and n >= 1 and n <= SLOTS then byNo[n] = w.name end
    end
    local out = {}
    for n = 1, SLOTS do out[#out + 1] = byNo[n] and ("w:" .. byNo[n]) or ("e:" .. n) end
    return out
end

local function hideAll(panel)
    for _, w in ipairs(children(panel)) do
        local a = w:GetAddress()
        if hidden[a] == nil then hidden[a] = w:GetVisibility() end
        w:SetVisibility(COLLAPSED)
    end
end

local function showList(menu)
    local panel = menu.SaveBtn:GetParent()
    local slot = slotOf(menu.ContinueBtn)
    removeMade(panel)
    hideAll(panel)
    local entries = worldList()
    for _, action in ipairs(entries) do addButton(menu, panel, action, slot) end
    addButton(menu, panel, "back", slot)
    listSig = table.concat(entries, "|")
    page = "list"
end

-- A text box and Send: the report covers this session from both games.
local function showReport(menu)
    local panel = menu.SaveBtn:GetParent()
    local slot = slotOf(menu.ContinueBtn)
    removeMade(panel)
    hideAll(panel)
    local box = StaticFindObject(WBL):Create(menu, StaticFindObject(BOX_CLASS), localPC())
    if box and box:IsValid() then
        pcall(function() box.MaxTextLength = 200 end)
        applySlot(panel:AddChild(box), slot)
        pcall(function() box:SetHintText(FText(T("report_hint"))) end)
        box:SetVisibility(VISIBLE)
        made[box:GetAddress()] = true
        boxAddr, focusBox = box:GetAddress(), true
    end
    for _, action in ipairs({ "send", "back" }) do addButton(menu, panel, action, slot) end
    page = "report"
end

local function reportBox(menu)
    for _, w in ipairs(children(menu.SaveBtn:GetParent())) do
        if w:GetAddress() == boxAddr then return w end
    end
end

local function typedReport(menu)
    local w = reportBox(menu)
    local ok, text = pcall(function() return w.EditableTextBox:GetText():ToString() end)
    return ok and text or ""
end

local function pollHover(menu)
    local hovered
    for _, w in ipairs(children(menu.SaveBtn:GetParent())) do
        local a = w:GetAddress()
        if ours[a] then
            if w:IsHovered() then hovered = a end
            pcall(function() w:SetText(FText(labelOf(ours[a])), 0) end)
        end
    end
    hoverWas = hovered
end

function M.mouse(msg)
    if msg[3] == "1" and doneFor then
        log("pausmeny: klick, över %s", hoverWas and tostring(ours[hoverWas]) or "-")
    end
    if msg[3] == "1" and hoverWas and ours[hoverWas] then pending = ours[hoverWas] end
end

-- Keys typed into the report box must not also work as the mod's key binds.
function M.typing() return boxAddr ~= nil end

function M.init(logFn, localPCFn, lobbyModule)
    log, localPC, lobby = logFn, localPCFn, lobbyModule
end

-- The guest saves its local copy every few minutes only to keep the game's
-- autosave off the singleplayer slots; the game's save notices are hidden there.
local SAVE_NOTICES = { "BP_SaveGameIndicator_C", "BP_AutoSaveGameIndicator_C", "BP_CloudSaveGameNotificationWidget_C" }
local lastNoticeCheck = 0
local function hideSaveNotices()
    if lobby.role() ~= "guest" then return end
    -- Closely right after the mod's own save, otherwise now and then: three
    -- searches of every object four times a second cost 0.3 ms a tick.
    local gap = os.time() - lobby.lastSaveAt() < 20 and 0.25 or 2
    if os.clock() - lastNoticeCheck < gap then return end
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
    if not menu then doneFor, ours, hoverWas, pending, boxAddr, focusBox = nil, {}, nil, nil, nil, false return end
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
    local act = pending
    pending = nil
    if act == "save" then
        if lobby.saveNow() then savedAt = os.time() end
    elseif act == "load" then
        lobby.refresh()
        local ok, err = pcall(showList, menu)
        if not ok then log("pausmeny-lista-fel: %s", tostring(err)) end
    elseif act == "back" then
        local ok, err = pcall(change, menu)
        if not ok then log("pausmeny-fel: %s", tostring(err)) end
    elseif act == "report" then
        bugreport.reset()
        local ok, err = pcall(showReport, menu)
        if not ok then log("pausmeny-rapport-fel: %s", tostring(err)) end
    elseif act == "send" and bugreport.canSend() then
        bugreport.send("now", typedReport(menu))
    elseif act and act:sub(1, 2) == "e:" then
        lobby.newWorldFromGame("Slot" .. act:sub(3))
    elseif act and act:sub(1, 2) == "w:" then
        log("pausmeny: laddar %s", act:sub(3))
        lobby.loadWorld(act:sub(3))
    end
    -- The world list comes from coopnet a moment after it is asked for.
    if page == "list" and table.concat(worldList(), "|") ~= listSig then
        local ok, err = pcall(showList, menu)
        if not ok then log("pausmeny-lista-fel: %s", tostring(err)) end
    end
    if focusBox then
        local w = reportBox(menu)
        if w and pcall(function() w.EditableTextBox:SetKeyboardFocus() end) then focusBox = false end
    end
    pollHover(menu)
end

return M
