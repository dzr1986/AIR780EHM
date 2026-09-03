-- ================================================================
-- Filename : t31x_notify.lua
-- Module   : T31x 通知辅助：AT 指令封装、URC 解析、IPC 事件上报桥
-- Layer    : L2 协处理器服务（被 t31x_ctrl / t31x_policy 依赖）
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

require "sys"
require "config"
local loader = require "module_loader"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local providers = {}

function registerProviders(p)
    if type(p) ~= "table" then return end
    for k, v in pairs(p) do
        providers[k] = v
    end
end

local function wakeCfg()
    return cfgm.get("HOST_WAKE_CFG")
end

local function ntfViaTimeSync(sid, evt)
    if providers.pushBeforeNotify then
        return providers.pushBeforeNotify(sid, evt) ~= false
    end
    local time_sync = loader.load("time_sync")
    if time_sync and loader.enabled("time_sync") then
        time_sync.pushBeforeNotifyAsync(sid, evt)
        return true
    end
    return false
end

local function ntfViaHostUart(sid, evt)
    if providers.ntfHost then
        return providers.ntfHost(sid, evt) ~= false
    end
    local hif = loader.load("host_uart")
    return hif ~= nil and hif.ntfHost(sid, evt) ~= false
end

local function gpioWakeFb(onDone)
    local wake = providers.wakeHost
    if not wake then
        local t31x = loader.load("t31x_ctrl")
        if not t31x then return false end
        wake = function() t31x.wake() end
    end
    sys.taskInit(function()
        wake()
        if onDone then onDone() end
    end)
    return true
end

function wakeHost(sid, evt, opts)
    opts = type(opts) == "table" and opts or {}
    sid = sid or wakeCfg().default_sid or 1
    evt = evt or 0
    local onDone = opts.onDone
    local flags = cfgm.get("MODULE_FLAGS")
    -- t31x_wakeup 须显式为真；t31x_app 的 nil 视为开
    if flags and flags.t31x_wakeup and flags.t31x_app ~= false then
        if ntfViaTimeSync(sid, evt) or ntfViaHostUart(sid, evt) then
            if onDone then onDone() end
            return true
        end
    end
    return gpioWakeFb(onDone)
end

function ensPowOn(tag, opts)
    if providers.ensPowOn then
        return providers.ensPowOn(tag, opts)
    end
    local t31x = loader.load("t31x_ctrl")
    return t31x ~= nil and t31x.ensPowOn(tag, opts)
end

return _M
