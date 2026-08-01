local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function isLowPowerMode()
	local rt = _G.APP_RUNTIME
	return rt and tonumber(rt.low_power_mode) == 1
end

function isBatteryDynamicRest()
	local rt = _G.APP_RUNTIME
	if rt and tonumber(rt.battery_dynamic_rest) == 1 then
		return true
	end
	local bg = loader.load("battery_guard")
	if bg and bg.isBatteryDynamicRest then
		return bg.isBatteryDynamicRest() == true
	end
	return false
end

function isUsbInserted()
	local uc = loader.load("usb_charge")
	if uc and type(uc.isUsbInserted) == "function" then
		local ok2, v = pcall(uc.isUsbInserted)
		if ok2 then
			return v == true
		end
	end
	local rt = _G.APP_RUNTIME or {}
	return tonumber(rt.power_status) == 1
end

return _M
