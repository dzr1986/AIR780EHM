--- MQTT 模式占位（满足 LuatTools 工程清单；完整 TCP 见 archive/slim/user/net_tcp_full.lua）
-- @module net_tcp
require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function tcpOn()
    local ok, lpw = pcall(require, "low_power_wakeup")
    return ok and lpw and lpw.allowTcpChannel and lpw.allowTcpChannel()
end

function getState()
    return { sid = nil, connected = false, running = false, logged_in = false }
end

function applyChannel(_ch)
    if not tcpOn() then
        return false, "mqtt_mode"
    end
    log.error("net_tcp", "stub: set LOW_POWER_WAKEUP_MODE=tcp and restore archive/slim/user/net_tcp_full.lua")
    return false, "stub"
end

function closeChannel(_sid)
    return true
end

function appendGetCfgFields()
    return ""
end

return _M
