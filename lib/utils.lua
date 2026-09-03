-- ================================================================
-- Filename : utils.lua
-- Module   : 通用工具函数：JSON 辅助、表操作、类型检查、字符串转义等基础 helper
-- Arch     : 见 doc/overview/LUA_MODULES.md
-- ================================================================

local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

MIN_VALID_UNIX = 1704067200

function nowMs()
    if mcu and mcu.ticks then return mcu.ticks() end
    return os.time() * 1000
end

function formatTime(ts)
    return os.date("%Y-%m-%d %H:%M:%S", tonumber(ts) or os.time())
end

function parseUnixTs(v)
    if v == nil or v == "" then
        return nil
    end
    if type(v) == "number" then
        local n = math.floor(v)
        return n > 1000000000 and n or nil
    end
    local s = tostring(v)
    local n = tonumber(s)
    if n and n > 1000000000 then
        return math.floor(n)
    end
    local y, m, d, H, M, S = s:match("^(%d+)%-(%d+)%-(%d+)[ T](%d+):(%d+):(%d+)$")
    if not y then
        y, m, d, H, M = s:match("^(%d+)%-(%d+)%-(%d+)[ T](%d+):(%d+)$")
        S = 0
    end
    if not y then
        return nil
    end
    return os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(H) or 0, min = tonumber(M) or 0, sec = tonumber(S) or 0,
    })
end

function jsonSafe(value)
    if not json or not json.encode then return nil end
    local ok, encoded = pcall(json.encode, value)
    return ok and encoded or nil
end

function escKv(v)
    return (tostring(v or ""):gsub(",", "_"):gsub("=", "_"))
end

function escJson(s)
    return (tostring(s or ""):gsub('[\\"]', { ['\\'] = '\\\\', ['"'] = '\\"' }))
end

function optTable(x)
    return type(x) == "table" and x or {}
end

function encodeHex(data)
    if not data or #data == 0 then
        return ""
    end
    if data.toHex then
        return data:toHex()
    end
    if string.toHex then
        return string.toHex(data)
    end
    local out = {}
    for i = 1, #data do
        out[i] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(out)
end

function decodeHex(hex)
    hex = hex and hex:gsub("[%s]", "") or ""
    if hex == "" or (#hex % 2) ~= 0 then
        return nil
    end
    if string.fromHex then
        return string.fromHex(hex)
    end
    local parts = {}
    for i = 1, #hex, 2 do
        local n = tonumber(hex:sub(i, i + 1), 16)
        if n == nil then
            return nil
        end
        parts[#parts + 1] = string.char(n)
    end
    return table.concat(parts)
end

function t31xOn(tag, extra, defaultExtra)
    local t31x = loader.load("t31x_ctrl")
    if not t31x then return false end
    return t31x.ensPowOn(tag, extra or defaultExtra)
end

function waitT31xAck(eventName, timeoutMs, ackOk)
    local deadline = nowMs() + timeoutMs
    while true do
        local remain = timeoutMs
        if mcu and mcu.ticks then
            remain = deadline - mcu.ticks()
            if remain <= 0 then return false end
        end
        local got, ackName = sys.waitUntil(eventName, remain)
        if got and (not ackOk or ackOk(ackName)) then return true end
        if not mcu or not mcu.ticks then return false end
    end
end

function parseBool(v)
    if v == true or v == 1 then return true end
    if type(v) == "string" then
        local s = string.lower(v)
        return s == "1" or s == "true" or s == "yes" or s == "on"
    end
    return false
end

function inSysTask()
    if coroutine.isyieldable then
        return coroutine.isyieldable() == true
    end
    local co, isMain = coroutine.running()
    return co ~= nil and isMain ~= true
end

function parseBoolDef(v, default)
    if v == nil then return default end
    if v == false or v == 0 or v == "0" then return false end
    return true
end

function to01(v)
    return (tonumber(v) == 1) and 1 or 0
end

function mkLogFns(tag)
    local funcs = {}
    funcs.info = function(...)
        if log and log.info then log.info(tag, ...) end
    end
    funcs.warn = function(...)
        if log and log.warn then
            log.warn(tag, ...)
        elseif log and log.info then
            log.info(tag, ...)
        end
    end
    funcs.error = function(...)
        if log and log.error then log.error(tag, ...) end
    end
    return funcs
end

function localIp(adp)
    if not socket or not socket.localIP then return nil end
    if adp ~= nil then
        local ok, ip = pcall(socket.localIP, adp)
        if ok and ip and ip ~= "" and ip ~= "0.0.0.0" then return ip end
    end
    local ok, ip = pcall(socket.localIP)
    if ok and ip and ip ~= "" and ip ~= "0.0.0.0" then return ip end
end

function waitLocalIp(timeoutMs)
    local ip = localIp()
    if not ip then
        sys.waitUntil("IP_READY", tonumber(timeoutMs) or 120000)
        ip = localIp()
    end
    return ip
end

function hostUart()
    return loader.load("host_uart")
end

function uartBridge()
    return loader.load("uart_bridge")
end

return _M
