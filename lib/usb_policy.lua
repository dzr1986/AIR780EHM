require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local function usb_cfg()
	return _G.HOST_USB_CFG or {}
end
function isUsbInserted()
	local ok, mod = pcall(require, "usb_charge")
	if ok and type(mod) == "table" and type(mod.isUsbInserted) == "function" then
		local ok2, v = pcall(mod.isUsbInserted)
		if ok2 then
			return v == true
		end
	end
	local rt = _G.APP_RUNTIME or {}
	return tonumber(rt.power_status) == 1
end
local function usbGatedPolicy(cfgKey)
	if usb_cfg()[cfgKey] == false then
		return false
	end
	return isUsbInserted()
end
function blocksHostIdle()
	return usbGatedPolicy("block_host_idle_when_usb")
end
function blocks4gRest()
	return usbGatedPolicy("block_4g_rest_when_usb")
end
function mayEnterRest()
	return not blocks4gRest()
end
return _M
