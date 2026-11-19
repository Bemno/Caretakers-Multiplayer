-- Multiplayer entry in the game's main menu. The menu's own buttons live in
-- BP_VoyageMainMenu_C.ButtonRoot; this adds a "Multiplayer" button there, and
-- while a multiplayer page is open it hides the game's buttons and fills the
-- panel with its own (same button class, so it looks like the game's menu).
-- No widget references are kept between ticks: buttons are recognised by
-- address and the menu is looked up again each time.
local M = {}
local T = require("text")
local net = require("net")
local UEHelpers = require("UEHelpers")

local BTN_CLASS = "/Game/UI/Focusable/BP_FocusableButton.BP_FocusableButton_C"
local BOX_CLASS = "/Game/UI/Focusable/BP_FocusableTextBox.BP_FocusableTextBox_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local RF_CLASS_DEFAULT = 0x10
local VISIBLE, COLLAPSED = 0, 1
local MAX_LIST = 6

local lobby, log, localPC, friends
local page = "main"
local selected           -- world chosen in the archive
local selectedFriend     -- friend id chosen in the friend list
local draft = ""         -- text in the name box; kept when the page is redrawn
local boxAddr            -- the name box, when the page has one
local focusBox = false
local ours = {}          -- address -> action (false for the status line)
local origVis = {}       -- address of a game button -> its visibility
local renderedFor, renderedSig = nil, nil
local clicked = {}
local hooked = false
local mouseWas = false
local hoverWas = nil
local pressedWas = {}    -- address -> SubBtn was pressed last tick
local lastClickAt = {}   -- address -> os.clock() of its last click, so two click paths don't fire twice

local function addClick(a, how)
    local t = os.clock()
    if lastClickAt[a] and t - lastClickAt[a] < 0.6 then log("menyklick via %s (redan taget)", how) return end
    lastClickAt[a] = t
    clicked[#clicked + 1] = a
    log("menyklick via %s", how)
end
local lastCheck = 0

local function children(panel)
    local out = {}
    local ok, arr = pcall(function() return panel:GetAllChildren() end)
    if not ok or not arr then return out end
    for _, c in ipairs(arr) do
        local okW, w = pcall(function() return c:get() end)
        w = okW and w or c
        if w and w:IsValid() then out[#out + 1] = w end
    end
    return out
end

-- The game's own buttons (Continue, New Game...) share one panel; ButtonRoot
-- is the row of social links at the bottom.
local function buttonPanel(menu)
    local ok, p = pcall(function() return menu.NewBtn:GetParent() end)
    if ok and p and p:IsValid() then return p end
    return menu.ButtonRoot
end

local function findMenu()
    local ok, found = pcall(FindObjects, 0, "BP_VoyageMainMenu_C", "", 0, RF_CLASS_DEFAULT, true)
    for _, m in ipairs((ok and found) or {}) do
        local okV, inView = pcall(function() return m:IsValid() and m:IsInViewport() end)
        if okV and inView then return m end
    end
end

local function stamp(t)
    return t and os.date("%Y-%m-%d %H:%M", t) or ""
end

local function go(p) return function() page = p friends.message = nil end end

local function friendText(e)
    local s = friends.statusOf(e)
    local t
    if s == "host" or s == "full" then t = T("st_" .. s, e.name, e.world or "")
    elseif s == "waiting" or s == "declined" or s == "removed" or s == "offline" or s == "guest" or s == "menu" or s == "lan" then
        t = T("st_" .. s, e.name)
    else t = e.name end
    if friends.online(e) and e.version and e.version ~= "" and e.version ~= lobby.VERSION then
        t = t .. "  " .. T("other_version", e.version)
    end
    return t
end

local function boxWidget(menu)
    if not boxAddr then return nil end
    for _, w in ipairs(children(buttonPanel(menu))) do
        if w:GetAddress() == boxAddr then return w end
    end
end

local function readBox(menu)
    local w = boxWidget(menu)
    if not w then return draft end
    local ok, t = pcall(function() return w.EditableTextBox:GetText():ToString() end)
    if ok and t then draft = t end
    return draft
end

local currentMenu
local function typedName() return readBox(currentMenu) end

local copiedUntil = 0    -- the Copy invite button says "Copied" until then

local function copyInvite()
    return function()
        lobby.copyInvite()
        copiedUntil = os.time() + 4
    end
end

local function inviteLabel()
    return os.time() < copiedUntil and T("copied_clip") or T("copy_invite")
end

-- coopnet found a newer release on GitHub (update|0|available|x.y.z). The
-- download is verified there; quitting lets coopnet run the installer, which
-- starts the game again through Steam.
local upd = { version = nil, pct = nil, ready = false, failed = false }

local function updateEntry(add)
    if not upd.version then return end
    if upd.ready then
        add(T("update_restart", upd.version), function()
            log("uppdatering: avslutar för installation av %s", upd.version)
            UEHelpers.GetKismetSystemLibrary():QuitGame(localPC(), localPC(), 0, false)
        end)
    elseif upd.pct then
        add(T("update_downloading", upd.pct), false)
    else
        add(T(upd.failed and "update_failed" or "update_to", upd.version), function()
            upd.pct, upd.failed = 0, false
            net.send("update", "get")
        end)
    end
end

local function entries()
    local e = {}
    local function add(text, fn) e[#e + 1] = { text = text, fn = fn } end
    local function box(hint, max) e[#e + 1] = { box = true, text = "[box]", hint = hint, max = max } end
    if page == "main" then
        add(T("multiplayer"), function() page = "mp" lobby.refresh() end)
        updateEntry(add)
        return e
    end
    -- Servers to join come first on the multiplayer page, with a gap below
    -- them (tested 2026-11-17); a status line follows.
    if page == "mp" then
        local joins = 0
        for _, f in ipairs(friends.list()) do
            if f.state == "ok" and friends.online(f) and f.mode == "host" then
                local id = f.id
                add(T("join_server", f.world or "", f.name), function() lobby.join(id) end)
                joins = joins + 1
            end
        end
        for _, l in ipairs(lobby.lanList()) do
            local addr = l.addr
            add(T("join_lan", l.world, l.name), function() lobby.join("lan:" .. addr) end)
            joins = joins + 1
        end
        if joins > 0 then add("", false) end
    end
    local status = lobby.statusText()
    if friends.message then status = friends.message end
    if status ~= "" or lobby.modWarning then
        add((lobby.modWarning and T("mods_differ", lobby.modWarning) or status), false)
    end
    if page == "mp" then
        add(T("player_name", lobby.playerName ~= "" and lobby.playerName or "?"), function()
            draft = lobby.playerName page = "playername"
        end)
        add(T("host"), function() page = "host" lobby.refresh() end)
        add(T("join_ip"), function() draft = lobby.loadLastIp() page = "joinip" end)
        local reqs = #friends.requests()
        add(reqs > 0 and T("friends_req", reqs) or T("friends"), function() draft = "" page = "friendlist" end)
        add(T("back"), go("main"))
    elseif page == "playername" then
        box("player_hint", 30)
        add(T("save_name"), function() if lobby.setPlayerName(typedName()) then page = "mp" end end)
        add(T("cancel"), go("mp"))
    elseif page == "host" then
        add(T("load_world"), go("archive"))
        add(T("new_world"), function() draft = os.date("%Y-%m-%d_%H%M") page = "newname" end)
        add(inviteLabel(), copyInvite())
        add(T("back"), go("mp"))
    elseif page == "friendlist" then
        for _, r in ipairs(friends.requests()) do
            local id = r.id
            add(T("approve", r.name), function() friends.approve(id) end)
            add(T("decline", r.name), function() friends.decline(id) end)
        end
        local list = friends.list()
        if #list == 0 then add(T("no_friends_yet"), false) end
        for i, f in ipairs(list) do
            if i > MAX_LIST * 2 then break end
            local id = f.id
            add(friendText(f), function() selectedFriend = id page = "friend" end)
        end
        add(T("add_friend"), function() draft = "" page = "addfriend" end)
        add(inviteLabel(), copyInvite())
        add(T("back"), go("mp"))
    elseif page == "addfriend" then
        box("id_hint", 80)
        add(T("add"), function() friends.add(typedName()) draft = "" page = "friendlist" end)
        add(T("back"), go("friendlist"))
    elseif page == "friend" then
        -- A friend hosting can be joined or removed; otherwise the click asks
        -- whether to remove.
        local f = selectedFriend and friends.entries[selectedFriend]
        if not f then page = "friendlist" return entries() end
        local id = f.id
        if f.state == "ok" and friends.online(f) and f.mode == "host" then
            add(T("join_server", f.world or "", f.name), function() lobby.join(id) end)
            add(T("remove_friend", f.name), go("confirmfriend"))
            add(T("back"), go("friendlist"))
        else
            add(T("remove_question", f.name), false)
            add(T("confirm_remove", f.name), function() friends.remove(id) selectedFriend = nil page = "friendlist" end)
            add(T("cancel"), go("friendlist"))
        end
    elseif page == "confirmfriend" then
        local f = selectedFriend and friends.entries[selectedFriend]
        if not f then page = "friendlist" return entries() end
        local id = f.id
        add(T("confirm_remove", f.name), function() friends.remove(id) selectedFriend = nil page = "friendlist" end)
        add(T("cancel"), go("friend"))
    elseif page == "joinip" then
        box("ip_hint", 60)
        add(T("connect"), function() if lobby.joinIp(typedName()) then page = "mp" end end)
        add(T("cancel"), go("mp"))
    elseif page == "newname" then
        box()
        add(T("host_online"), function() if lobby.newWorld(typedName(), "online") then page = "host" end end)
        add(T("host_lan"), function() if lobby.newWorld(typedName(), "lan") then page = "host" end end)
        add(T("back"), go("host"))
    elseif page == "rename" then
        box()
        local old = selected
        add(T("save_name"), function()
            if lobby.renameWorld(old, typedName()) then page = "archive" end
        end)
        add(T("cancel"), go("world"))
    elseif page == "archive" then
        if #lobby.worlds == 0 then add(T("no_worlds"), false) end
        for i, w in ipairs(lobby.worlds) do
            if i > MAX_LIST * 2 then break end
            add(w.name .. "  (" .. stamp(w.time) .. ")", function() selected = w.name page = "world" end)
        end
        add(T("import"), go("import"))
        add(T("back"), go("host"))
    elseif page == "world" then
        local name = selected
        add(T("play_online", name), function() lobby.host(name, "online") end)
        add(T("play_lan", name), function() lobby.host(name, "lan") end)
        add(T("rename"), function() draft = name page = "rename" end)
        add(T("delete", name), go("confirm"))
        add(T("back"), go("archive"))
    elseif page == "confirm" then
        local name = selected
        add(T("confirm_delete", name), function() lobby.deleteWorld(name) page = "archive" end)
        add(T("cancel"), go("world"))
    elseif page == "import" then
        for _, s in ipairs(lobby.spSlots) do
            add(T("slot", s.index, stamp(s.time)), function() lobby.import(s.index) page = "archive" end)
        end
        add(T("back"), go("archive"))
    end
    return e
end

local function signature(list)
    local t = { page }
    for _, x in ipairs(list) do t[#t + 1] = x.text end
    return table.concat(t, "\n")
end

-- Created buttons start with class defaults; the menu's buttons were set up in
-- the designer. The widget applies these settings when its Slate widget is
-- built (PreConstruct), so they are copied before the button is added.
local LOOK = {
    "bShowBackground", "bOverrideAlignment", "MainTextHorizontalAlingment", "MainTextVerticalAlingment",
    "RootPanelHorizontalAlingment", "RootPanelVerticalAlingment",
    "bOverrideHeaderSizeRule", "bOverrideHeaderSizeRuleFill", "bOverrideHeaderSize", "HeaderSizeBoxMinWidth",
    "HeaderSizeBoxHorizontalAlingment", "bOverrideValueSizeRule", "bOverrideValueSizeRuleFill",
    "bOverrideValueSize", "ValueSizeBoxMinWidth", "ValueSizeBoxHorizontalAlingment",
    "bOverrideRootSize", "WidthOverride", "HeightOverride", "MinDesiredWidth", "MinDesiredHeight",
    "MaxDesiredWidth", "MaxDesiredHeight", "MinAspectRatio", "MaxAspectRatio",
    "bOverrideMainFont", "MainFontOverrideSize", "bOverrideMainFontPadding", "MainFontOverridePadding",
    "bOverrideMainFontTransformPolicy", "MainFontTextTransformPolicy",
    "bCanFocus", "bCanHover", "bFocusOnHover", "bCanSelect", "bFocusOnSelect", "bFocusOnActivation",
    "FocusableSoundData", "ActivateAnimData", "FocusAnimData", "HoverAnimData", "SelectAnimData",
    "LeftMouseActivation", "PrimaryActionActivation",
}

local function copyLook(from, to)
    for _, k in ipairs(LOOK) do
        local ok, err = pcall(function() to[k] = from[k] end)
        if not ok then log("meny: kan inte kopiera %s: %s", k, tostring(err)) end
    end
end

M.copyLook = function(from, to) copyLook(from, to) end

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

-- UMG has no insert, so the game's buttons from Options down are taken out
-- and put back after ours, which puts ours just above Options.
local function render(menu, list)
    local root = buttonPanel(menu)
    for _, w in ipairs(children(root)) do
        local a = w:GetAddress()
        if ours[a] ~= nil then
            w:RemoveFromParent()
        else
            if origVis[a] == nil then origVis[a] = w:GetVisibility() end
            w:SetVisibility(page == "main" and origVis[a] or COLLAPSED)
        end
    end
    ours = {}
    local tail = {}
    local okO, options = pcall(function() return menu.OptionsBtn end)
    local optAddr = okO and options and options:IsValid() and options:GetAddress()
    local moving = false
    for _, w in ipairs(children(root)) do
        if w:GetAddress() == optAddr then moving = true end
        if moving then tail[#tail + 1] = { w = w, slot = slotOf(w) } end
    end
    for _, t in ipairs(tail) do root:RemoveChild(t.w) end
    local look = slotOf(menu.NewBtn)
    local cls = StaticFindObject(BTN_CLASS)
    local wbl = StaticFindObject(WBL)
    boxAddr = nil
    for _, x in ipairs(list) do
        if x.box then
            local b = wbl:Create(menu, StaticFindObject(BOX_CLASS), localPC())
            if b and b:IsValid() then
                local max, hint = x.max or 40, x.hint or "name_hint"
                pcall(function() b.MaxTextLength = max end)
                applySlot(root:AddChild(b), look)
                pcall(function() b:SetHintText(FText(T(hint))) end)
                pcall(function() b:SetEditTextNoDelegate(FText(draft)) end)
                b:SetVisibility(VISIBLE)
                boxAddr, focusBox = b:GetAddress(), true
                -- Ours, so the next render removes it like the buttons.
                ours[boxAddr] = false
            end
            goto continue
        end
        local btn = wbl:Create(menu, cls, localPC())
        if btn and btn:IsValid() then
            copyLook(menu.NewBtn, btn)
            applySlot(root:AddChild(btn), look)
            btn:SetText(FText(x.text), 0)
            btn:SetVisibility(VISIBLE)
            ours[btn:GetAddress()] = x.fn or false
        end
        ::continue::
    end
    for _, t in ipairs(tail) do applySlot(root:AddChild(t.w), t.slot) end
end

local function onActivated(widget)
    local ok, a = pcall(function()
        local w = widget:get()
        return w and w:IsValid() and w:GetAddress()
    end)
    if ok and a and ours[a] ~= nil then addClick(a, "händelse") end
end

local function hook()
    if hooked then return end
    hooked = true
    local okL, l = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):GetCurrentLanguage():ToString()
    end)
    log("spelets språk: %s", okL and l or ("okänt: " .. tostring(l)))
    local paths = {
        "/Script/Voyage.VoyageBaseMenuUserWidget:OnMenuButtonActivation",
        "/Script/Voyage.VoyageFocusableButtonWidget:Click",
        -- Bound to the inner button's OnClicked: fires on the click event itself. Under ProtoInput (split
        -- screen) press and release can land in the same frame, so polling the button state misses them.
        "/Script/Voyage.VoyageFocusableButtonWidget:SubBtnClicked",
    }
    for _, path in ipairs(paths) do
        local ok, err = pcall(RegisterHook, path,
            function(ctx, widget) if widget then pcall(onActivated, widget) else pcall(onActivated, ctx) end end,
            function(ctx, widget) if widget then pcall(onActivated, widget) else pcall(onActivated, ctx) end end)
        log("menyhook %s: %s", path, ok and "ok" or tostring(err))
    end
end

-- Fallback when the game never reports a click on an added button: a left
-- mouse press while one of ours is hovered.
local function pollMouse(menu)
    local pc = localPC()
    local okD, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) end)
    down = okD and down
    local hovered
    for _, w in ipairs(children(buttonPanel(menu))) do
        local a = w:GetAddress()
        if ours[a] ~= nil and w:IsHovered() then hovered = a end
        -- The button's own pressed state is read inside the game, so it also works when the mouse
        -- reaches the game through ProtoInput (split screen), where coopnet sees no Windows click.
        if ours[a] then
            local okP, pressed = pcall(function() return w.SubBtn:IsPressed() end)
            pressed = okP and pressed or false
            if pressed and not pressedWas[a] then addClick(a, "knapp") end
            pressedWas[a] = pressed
        end
    end
    if hovered ~= hoverWas then
        log("meny: hover %s, mus %s", tostring(hovered), tostring(down))
        hoverWas = hovered
    end
    if down ~= mouseWas then log("meny: musknapp %s", tostring(down)) end
    if down and not mouseWas then
        for _, w in ipairs(children(buttonPanel(menu))) do
            local a = w:GetAddress()
            if ours[a] and w:IsHovered() then addClick(a, "mus") end
        end
    end
    mouseWas = down
end

-- coopnet reports the left mouse button straight from Windows.
function M.handle(msg)
    if msg[1] == "update" then
        local what = msg[3]
        log("uppdatering: %s %s", tostring(what), tostring(msg[4]))
        if what == "available" then upd.version = msg[4]
        elseif what == "progress" then upd.pct = tonumber(msg[4]) or upd.pct
        elseif what == "ready" then upd.ready, upd.pct = true, nil
        elseif what == "error" and upd.version then upd.failed, upd.pct = true, nil
        end
        return true
    end
    if msg[1] ~= "mouse" then return false end
    if hoverWas then log("meny: mus %s, hover %s", tostring(msg[3]), tostring(hoverWas)) end
    if msg[3] == "1" and hoverWas and ours[hoverWas] then addClick(hoverWas, "coopnet") end
    return true
end

function M.init(lobbyModule, logFn, localPCFn, friendsModule)
    lobby, log, localPC, friends = lobbyModule, logFn, localPCFn, friendsModule
end

-- Runs on the title screen only.
function M.tick()
    local menu = findMenu()
    friends.setActive(menu ~= nil and (page == "mp" or page == "friendlist" or page == "friend"))
    if not menu then renderedFor = nil return end
    hook()
    currentMenu = menu
    local q = clicked
    clicked = {}
    local seen = {}
    for _, a in ipairs(q) do
        if not seen[a] and ours[a] then
            seen[a] = true
            local ok, err = pcall(ours[a])
            if not ok then log("menyfel: %s", tostring(err)) end
        end
    end
    pollMouse(menu)
    if os.clock() - lastCheck < 0.25 and #q == 0 then return end
    lastCheck = os.clock()
    local list = entries()
    local sig = signature(list)
    local addr = menu:GetAddress()
    if focusBox then
        -- Typing goes to the box only once it has keyboard focus.
        local w = boxWidget(menu)
        if w and pcall(function() w.EditableTextBox:SetKeyboardFocus() end) then focusBox = false end
    end
    if addr ~= renderedFor or sig ~= renderedSig then
        readBox(menu)
        local ok, err = pcall(render, menu, list)
        if not ok then log("meny-ritfel: %s", tostring(err)) end
        renderedFor, renderedSig = addr, sig
    end
end

return M
