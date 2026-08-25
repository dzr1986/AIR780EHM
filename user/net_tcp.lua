-- ================================================================
-- Filename : net_tcp.lua
-- Module   : TCP 唤醒桩：LOW_POWER_WAKEUP_CFG.mode=tcp 时占位，默认 MQTT 模式不加载
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local idle = {
    sid = nil,
    connected = false,
    running = false,
    logged_in = false,
    configured = false,
}
function getState()
    return idle
end

function applyChannel(_ch)
    return false, "tcp_disabled"
end

function closeChannel(_sid)
    return true
end

function appCfgFields()
    return ",tcp_on=0"
end
return _M
