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
function appendGetCfgFields()
	return ",tcp_on=0"
end
return _M
