-- ================================================================
-- Filename : t3x_notify.lua
-- Module   : T3x 通知辅助：AT 指令封装、URC 解析、IPC 事件上报桥
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

require "sys"
local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local modCache = {}
local function getMod(name)
    local g = _G[name]
    if g then
        return g
    end
    local m = modCache[name]
    if m == nil then
        m = loader.load(name) or false
        modCache[name] = m
    end
    return m ~= false and m or nil
end

local function ntfyViaTime(sid, evt)
    local time_sync = loader.load("time_sync")
    if not time_sync or not time_sync.pushBeforeNotifyAsync then
        return false
    end
    if not loader.enabled("time_sync") then
        return false
    end
    time_sync.pushBeforeNotifyAsync(sid, evt)
    return true
end

local function ntfyViaHost(sid, evt)
    local hu = getMod("host_uart")
    if hu and hu.notify_host then
        return hu.notify_host(sid, evt) ~= false
    end
    return false
end

local function fllbGpio(onDone)
    local t3x = getMod("t3x_ctrl")
    if not t3x or not t3x.wake then
        return false
    end
    sys.taskInit(function()
        t3x.wake()
        if onDone then
            onDone()
        end
    end)
    return true
end

function wakeHost(sid, evt, opts)
    opts = type(opts) == "table" and opts or {}
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    local onDone = opts.on_done
    -- 保留真值判断：t3x_wakeup 需显式为真，与 enabled() 的 nil 视为开启语义不同
    if not (_G.MODULE_FLAGS and _G.MODULE_FLAGS.t3x_wakeup
        and (_G.MODULE_FLAGS.t3x_app ~= false)) then
        return fllbGpio(onDone)
    end
    if ntfyViaTime(sid, evt) then
        if onDone then
            onDone()
        end
        return true
    end
    if ntfyViaHost(sid, evt) then
        if onDone then
            onDone()
        end
        return true
    end
    return fllbGpio(onDone)
end

function ensPowOn(tag, opts)
    local t3x = getMod("t3x_ctrl")
    if t3x and t3x.ensPowOn then
        return t3x.ensPowOn(tag, opts)
    end
    return false
end

return _M
