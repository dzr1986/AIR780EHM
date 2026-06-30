require "sys"
-- TCP 唤醒桩（LOW_POWER_WAKEUP_CFG.mode=tcp 时由 low_power_wakeup 懒加载）；专题 doc/modules/LOW_POWER_WAKEUP.md
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
function appendGetCfgFields()
    return ",tcp_on=0"
end
return _M
