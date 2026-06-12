--- 专有 TCP 低功耗通道（仅 LOW_POWER_WAKEUP_CFG.mode="tcp" 时使用）
-- 工程默认 mqtt：本文件仅提供空态 API，满足 LuatTools 清单与 rest 清理逻辑
-- 若启用 tcp 唤醒：用 archive/slim/user/net_tcp.lua 覆盖本文件
-- @module net_tcp
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
    log.warn("net_tcp", "tcp off: set mode=tcp and deploy archive/slim/user/net_tcp.lua")
    return false, "tcp_disabled"
end

function closeChannel(_sid)
    return true
end

function appendGetCfgFields()
    return ",tcp_on=0"
end

return _M
