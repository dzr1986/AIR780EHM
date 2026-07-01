require "sys"
-- USB RNDIS 桩（量产 RNDIS_ENABLE=0）；完整版见 archive/lib/usb_rndis_full.lua
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local disabled = { status = "disabled", started = false, enabled = false }
function isStarted() return false end
function isEnabled() return false end
function isRefreshing() return false end
function isBootStable() return true end
function waitForNetStable() return true end
function getStatus() return disabled end
function open() return false, "rndis_disabled" end
function enable() return false, "rndis_disabled" end
function disable() return true end
function stop() return true end
function switch() return false, "rndis_disabled" end
function rebind() return false, "rndis_disabled" end
function enableAsync() return false end
function start() return false end
_G.usbRndis = _M
return _M
