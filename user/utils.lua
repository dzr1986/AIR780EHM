-- ================================================================
-- Filename : utils.lua
-- Module   : 通用工具函数：JSON 辅助、表操作、类型检查、字符串转义等基础 helper
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

local _modname = ...
local loader = require "module_loader"
module(_modname, package.seeall)
_G[_modname] = _M

MIN_VALID_UNIX = 1704067200

-- 毫秒时间戳：mcu.ticks 优先（单调），退化到 os.time()*1000（1s 精度）
function nowMs()
    if mcu and mcu.ticks then
        return mcu.ticks()
    end
    return os.time() * 1000
end

-- AT 帧字段转义：逗号/等号 → 下划线，防止破坏 IPC 结构
function escKv(v)
    return (tostring(v or ""):gsub(",", "_"):gsub("=", "_"))
end

-- JSON 字符串字段转义：反斜杠与双引号
function escJson(s)
    return (tostring(s or ""):gsub('[\\"]', { ['\\'] = '\\\\', ['"'] = '\\"' }))
end

-- 表兜底：非表返回空表
function optTable(x)
    return type(x) == "table" and x or {}
end

-- 事件名兜底：APP_EVENTS 缺失时用内置默认名
function appEvent(name, fallback)
    local evt = _G.APP_EVENTS
    return (evt and evt[name]) or fallback
end

-- T3x 上电门禁：经 t3x_ctrl.ensPowOn，模块缺失时返回 false
local t3xIpc
function t3xOn(tag, extra, defaultExtra)
    if t3xIpc == nil then
        local m = loader.load("t3x_ctrl")
        t3xIpc = m or false
    end
    if not t3xIpc or not t3xIpc.ensPowOn then
        return false
    end
    return t3xIpc.ensPowOn(tag, extra or defaultExtra)
end

-- 等待 T3x 命令 ACK：ackOk 谓词可选（校验事件负载）；
-- 无 mcu.ticks 时只等一拍。sys 延迟取全局：utils 先于 sys 被 require
function waitT3xCmdAck(eventName, timeoutMs, ackOk)
    local deadline = nowMs() + timeoutMs
    while true do
        local remain = timeoutMs
        if mcu and mcu.ticks then
            remain = deadline - mcu.ticks()
            if remain <= 0 then
                return false
            end
        end
        local got, ackName = sys.waitUntil(eventName, remain)
        if got and (not ackOk or ackOk(ackName)) then
            return true
        end
        if not mcu or not mcu.ticks then
            return false
        end
    end
end

function parseBoolLike(v)
    if v == true or v == 1 then
        return true
    end
    if type(v) == "string" then
        local s = string.lower(v)
        return s == "1" or s == "true" or s == "yes" or s == "on"
    end
    return false
end

-- Lua 5.3 主调度里 coroutine.running() 也非 nil，不能用来判断能否 sys.wait。
function inSysTask()
    if coroutine.isyieldable then
        return coroutine.isyieldable() == true
    end
    local co, isMain = coroutine.running()
    if co == nil or isMain == true then
        return false
    end
    return true
end

function parseBoolDefault(v, default)
    if v == nil then
        return default
    end
    if v == false or v == 0 or v == "0" then
        return false
    end
    return true
end

function crtLogFns(tag)
    local funcs = {}
    funcs.info = function(...)
        if log and log.info then
            log.info(tag, ...)
        end
    end
    funcs.warn = function(...)
        if log and log.warn then
            log.warn(tag, ...)
        elseif log and log.info then
            log.info(tag, ...)
        end
    end
    funcs.error = function(...)
        if log and log.error then
            log.error(tag, ...)
        end
    end
    return funcs
end

-- 委托 module_loader，保持全项目单一 require 缓存
function lazyRequire(name)
    return loader.load(name)
end

local hostUartMod
function getHostUart()
    if hostUartMod == nil then
        if _G.host_uart then
            hostUartMod = _G.host_uart
        else
            hostUartMod = lazyRequire("host_uart") or false
        end
    end
    return hostUartMod or nil
end

local uartBrdgMod
function getUartBridge()
    if uartBrdgMod == nil then
        uartBrdgMod = _G.uart_bridge or loader.load("uart_bridge") or false
    end
    return uartBrdgMod or nil
end

return _M
