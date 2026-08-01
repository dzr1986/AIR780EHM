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
	local ok, bg = pcall(require, "battery_guard")
	if ok and type(bg) == "table" and bg.isBatteryDynamicRest then
		return bg.isBatteryDynamicRest() == true
	end
	return false
end

function isUsbInserted()
	local ok, uc = pcall(require, "usb_charge")
	if ok and type(uc) == "table" and type(uc.isUsbInserted) == "function" then
		local ok2, v = pcall(uc.isUsbInserted)
		if ok2 then
			return v == true
		end
	end
	local rt = _G.APP_RUNTIME or {}
	return tonumber(rt.power_status) == 1
end

return _M
