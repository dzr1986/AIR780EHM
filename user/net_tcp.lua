-- ================================================================
-- Filename : net_tcp.lua
-- Module   : TCP 唤醒桩【实验性/未启用】：仅当 LOW_POWER_WAKEUP_CFG.mode=="tcp" 时才有实际行为；
--            默认 MQTT 模式下 getState 返回 idle 空实现，所有业务调用安全无操作。当前代码路径
--            （main 锚点 + lp_wakeup）仍会加载它，但无可观测副作用，可保留亦可删除。
-- Arch     : 见 doc/overview/LUA_MODULES.md
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
