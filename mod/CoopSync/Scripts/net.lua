-- Line-based link to coopnet.py through two append-only files.
-- out.log: written here, read by coopnet. in.log: written by coopnet, read here.
local M = {}

local OUT, IN
local inOffset = 0
local seq = 0
-- Both files stay open: opening a file that another process is writing cost
-- about 10 ms a time on Windows (each tick, and each message sent).
local outFile, inFile

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size
end

-- Skip whatever is already in in.log so a hot reload does not replay old messages.
function M.init(role)
    local dir = "ue4ss/Mods/CoopSync/io/" .. role .. "/"
    OUT, IN = dir .. "out.log", dir .. "in.log"
    inOffset = fileSize(IN)
end

-- While the test bench replays a recording here (uppspela.lua), nothing that
-- changes the world reaches the other game: replayed recycler output was
-- sent on as drops and threw the host's boat about (2026-11-15).
local QUIET_ALLOWED = { pos = true, ping = true, pong = true, hello = true, welcome = true }
M.quietUntil = 0

function M.send(kind, ...)
    if os.clock() < M.quietUntil and not QUIET_ALLOWED[kind] then return true end
    seq = seq + 1
    local parts = { kind, tostring(seq) }
    for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
    if not outFile then outFile = io.open(OUT, "ab") end
    if not outFile then return false end
    local ok = pcall(function()
        outFile:write(table.concat(parts, "|"), "\n")
        outFile:flush()
    end)
    if not ok then pcall(function() outFile:close() end) outFile = nil return false end
    return true
end

-- Returns a list of messages, each a table {kind, seq, field1, ...}.
function M.receive()
    if not inFile then inFile = io.open(IN, "rb") end
    local f = inFile
    if not f then return {} end
    local okS, size = pcall(f.seek, f, "end")
    if not okS or not size then pcall(f.close, f) inFile = nil return {} end
    if size < inOffset then inOffset = 0 end
    if size == inOffset then return {} end
    f:seek("set", inOffset)
    local data = f:read(size - inOffset)
    if not data then return {} end
    local lastNewline = data:match(".*()\n")
    if not lastNewline then return {} end
    inOffset = inOffset + lastNewline
    local msgs = {}
    for line in data:sub(1, lastNewline):gmatch("([^\n]*)\n") do
        local fields = {}
        for part in (line .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = part end
        if #fields >= 2 then msgs[#msgs + 1] = fields end
    end
    return msgs
end

return M
