-- The guest notices when the host is gone (quit, lost its network): nothing
-- from it for LOST_SECONDS, or a "hostbye" when it leaves on purpose. The
-- game's own yes/no dialog then asks: wait for the host or quit. Waiting goes
-- to the title screen and joins again from there until the host answers:
-- loading the host's world again inside the old one crashed the guest
-- (stale objects of the old world in the boat sync, 2026-11-17).
local M = {}
local T = require("text")

local LOST_SECONDS = 10
local CONFIRM_HOOK = "/Script/Voyage.VoyageBaseDialogWidget:ConfirmDialog"
local TWO_BUTTONS = "/Game/Data/UI/Dialogs/DA_Dialog_Delete_SaveGameSlot.DA_Dialog_Delete_SaveGameSlot"
-- Yes = wait, No = quit; Cancel (Esc) waits too, so a stray Esc never quits.
local YES, NO = 1, 2

local log, localPC, lobby
local lastHeard = os.time()
local shownPath                -- the dialog while it is up
local answer                   -- set by the hook, acted on in tick
local waiting = false          -- the guest chose to wait
local hooked = false

function M.init(logFn, localPCFn, lobbyModule)
    log, localPC, lobby = logFn, localPCFn, lobbyModule
end

-- Every message from the other game counts as a sign of life.
function M.heard()
    lastHeard = os.time()
end

-- The host left on purpose.
function M.hostBye()
    lastHeard = 0
end

function M.reset()
    lastHeard, answer, waiting = os.time(), nil, false
    shownPath = nil
end

local function dialog()
    local d = shownPath and StaticFindObject(shownPath)
    if d and d:IsValid() then return d end
end

local function hook()
    if hooked then return end
    hooked = true
    local ok, err = pcall(RegisterHook, CONFIRM_HOOK, function(ctx, result)
        pcall(function()
            local d = ctx:get()
            if not (shownPath and d:GetFullName():find(shownPath, 1, true)) then return end
            answer = result:get().Type
        end)
    end)
    log("värden borta: dialogkrok %s", ok and "ok" or tostring(err))
end

local function show()
    hook()
    local pc = localPC()
    local gi = require("UEHelpers").GetGameInstance()
    -- ShowDialogK2 gives a single button; the game's yes/no dialog (delete a
    -- save slot) is borrowed and its texts replaced.
    local data = StaticFindObject(TWO_BUTTONS)
    if not (data and data:IsValid()) then data = LoadAsset(TWO_BUTTONS) end
    local d = gi:ShowCommonDialog(pc, data)
    if not (d and d:IsValid()) then log("värden borta: ingen dialog") return end
    pcall(function() d.TitleTB:SetText(FText(T("host_lost_title"))) end)
    local body = FText(T("host_lost_body", lobby.peerName or "?"))
    pcall(function() d.BodyTB:SetText(body) end)
    pcall(function() d.BodyRTB:SetText(body) end)
    pcall(function() d:SetDialogButtonText(FText(T("host_lost_wait")), YES) end)
    pcall(function() d:SetDialogButtonText(FText(T("host_lost_quit")), NO) end)
    shownPath = d:GetFullName():match("%S+%s+(%S+)")
    log("värden borta: dialog visas (%s)", tostring(shownPath))
end

local function close()
    local d = dialog()
    if d then pcall(function() d:RemoveFromParent() end) end
    shownPath = nil
end

-- settled: the guest's world has been running long enough for the sync.
function M.tick(settled)
    if lobby.role() ~= "guest" or not settled then return end
    local silent = os.time() - lastHeard >= LOST_SECONDS
    if answer then
        local a = answer
        answer, shownPath = nil, nil
        if a == NO then
            log("värden borta: gästen avslutar")
            pcall(function() require("UEHelpers").GetGameInstance():GotoInitialState() end)
            return
        end
        log("värden borta: gästen väntar, till titelskärmen och ansluter därifrån")
        lobby.rejoinFromTitle()
        pcall(function() require("UEHelpers").GetGameInstance():GotoInitialState() end)
        return
    end
    if not silent then
        if shownPath or waiting then
            log("värden är tillbaka")
            close()
            waiting = false
        end
        return
    end
    if not shownPath and not waiting then
        local ok, err = pcall(show)
        if not ok then log("värden borta: dialogfel %s", tostring(err)) end
    end
end

return M
