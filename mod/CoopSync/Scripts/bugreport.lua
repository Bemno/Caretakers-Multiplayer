-- Bug reports. coopnet copies, cleans, packs and posts the logs (report.py);
-- this sends the request and keeps the state the menus show. During a session
-- the other game is asked to send its own logs under the same id.
local M = {}
local T = require("text")
local net = require("net")
local lobby = require("lobby")
local hostlost = require("hostlost")
local okRelease, RELEASE = pcall(require, "release")

local log = function() end
local state, detail = "", ""
local sentAt = 0
-- coopnet answers sent or failed; none means coopnet is not running.
local ANSWER_WAIT = 90
local disabled = false
M.pendingCrash = false   -- the last run crashed and its report is not sent
M.pendingLast = false    -- the last run's logs are kept and not sent
M.inWorld = false        -- a world was played this run: "now" holds its logs

function M.init(logFn) log = logFn end

local function clean(s) return ((s or ""):gsub("[|\r\n,]", " ")) end

local function peerConnected()
    return lobby.role() ~= nil and lobby.peerName ~= nil and hostlost.since() < 15
end

local function sendAs(id, which, text)
    if disabled then state = "disabled" return end
    local header = string.format("version=%s role=%s link=%s peer=%s", okRelease and RELEASE or lobby.VERSION,
        lobby.role() or "menu", lobby.hostMode or "-", peerConnected() and "connected" or "not connected")
    net.send("report", "send", id, which, clean(lobby.playerName) .. "," .. clean(lobby.peerName), header, clean(text))
    state, detail, sentAt = "sending", "", os.time()
    log("felrapport %s (%s) begärd", id, which)
end

-- At the title screen the logs of a world played this run are still being
-- written ("now"); "last" is the run before, kept by coopnet when it ended.
function M.which() return M.inWorld and "now" or "last" end

function M.send(which, text)
    local id = os.date("%Y%m%d-%H%M%S") .. string.format("-%04x", math.random(0, 0xffff))
    sendAs(id, which, text)
    if which == "now" and peerConnected() and not disabled then net.send("bugreport", id, clean(text)) end
end

function M.dismiss()
    net.send("report", "dismiss")
    M.pendingCrash, M.pendingLast = false, false
end

-- Where hello, welcome and pname carry the other player's name. coopnet keeps
-- every name of the session to clean a "last" report sent after they left.
local NAME_FIELD = { hello = 5, welcome = 5, pname = 3 }
local namesSent

function M.handle(msg)
    local f = NAME_FIELD[msg[1]]
    if f and (msg[f] or "") ~= "" then
        local names = clean(lobby.playerName) .. "," .. clean(msg[f])
        if names ~= namesSent then
            namesSent = names
            net.send("report", "names", names)
        end
        return false
    end
    if msg[1] == "bugreport" then
        sendAs(msg[3], "peer", "(from the other player) " .. (msg[4] or ""))
        return true
    end
    if msg[1] ~= "report" then return false end
    if msg[2] ~= "0" then return true end
    local what = msg[3]
    if what == "sent" then
        state = "sent"
        M.pendingCrash, M.pendingLast = false, false
    elseif what == "failed" then
        state, detail = "failed", msg[5] or ""
        log("felrapport misslyckades: %s", detail)
    elseif what == "disabled" then
        disabled = true
    elseif what == "pending" then
        M.pendingCrash, M.pendingLast = msg[4] == "1", true
    end
    return true
end

function M.disabled() return disabled end
function M.reset() state, detail = "", "" end
function M.sent() return state == "sent" end
function M.canSend() return state ~= "sent" and state ~= "sending" end

function M.status()
    if disabled then return T("report_disabled") end
    if state == "sending" and os.time() - sentAt > ANSWER_WAIT then state, detail = "failed", "no answer from coopnet" end
    if state == "sending" then return T("report_sending") end
    if state == "sent" then return T("report_sent") end
    if state == "failed" then return T("report_failed", detail) end
    return ""
end

return M
