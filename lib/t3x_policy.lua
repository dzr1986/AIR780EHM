require "sys"
require "config"
local runtime_power = require "runtime_power"
local t3x_notify = require "t3x_notify"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local lastMqttOfflineWakeSec = 0
local function cfg()
	return _G.T3X_POLICY_CFG or {}
end
local function guardCfg()
	local root = _G.BATTERY_CFG or {}
	return root.guard or {}
end
function isUsbInserted()
	return runtime_power.isUsbInserted()
end
function getBatteryPercent()
	local rt = _G.APP_RUNTIME
	if rt then
		local p = tonumber(rt.battery_percent)
		if p then
			return p
		end
	end
	return nil
end
function isLowPowerMode()
	return runtime_power.isLowPowerMode()
end
local function isBatteryDynamicRest()
	return runtime_power.isBatteryDynamicRest()
end
function isBurnActive()
	return _G.T3X_BURN_MODE_ACTIVE == true
end
local function isWledWakeReason(reason)
	return tostring(reason or "") == "wled"
end
local function isPirWakeReason(reason)
	reason = tostring(reason or "")
	if reason == "notify_host" or reason == "pir_media" or reason == "exit_low_power" then
		return true
	end
	return reason:sub(1, 9) == "pir_stop"
end
local function allowsWakeInRest(reason)
	if cfg().allow_wled_wake_in_rest ~= false and isWledWakeReason(reason) then
		return true
	end
	if not isPirWakeReason(reason) then
		return false
	end
	if cfg().allow_pir_wake_in_rest ~= false then
		return true
	end
	if cfg().allow_pir_wake_in_battery_rest ~= false and isBatteryDynamicRest() then
		return true
	end
	return false
end
local function policyDisabled()
	if cfg().enabled == false then
		return true
	end
	local flags = _G.MODULE_FLAGS
	return flags and flags.t3x_policy == false
end
local function passesUsbGate(reason)
	if not isUsbInserted() then
		return false
	end
	if reason == "mqtt_offline" and cfg().allow_mqtt_offline_wake_when_usb ~= true then
		return false
	end
	return true
end
local function passesLowPowerGate(reason, opts)
	if cfg().block_wake_in_low_power == false or not isLowPowerMode() then
		return true
	end
	if allowsWakeInRest(reason) then
		return true
	end
	return false
end
local function passesBatteryGate()
	local pct = getBatteryPercent()
	local blockPct = tonumber(cfg().block_wake_below_percent)
	if blockPct == nil then
		blockPct = tonumber(guardCfg().pir_suspend_percent) or 15
	end
	if pct ~= nil and pct <= blockPct then
		return false
	end
	return true
end
function mayPowerT3x(reason, opts)
	opts = type(opts) == "table" and opts or {}
	if policyDisabled() or isBurnActive() or passesUsbGate(reason) or opts.force_wake then
		return true
	end
	if not passesLowPowerGate(reason, opts) then
		return false
	end
	return passesBatteryGate()
end
function shouldWakeOnMqttOffline()
	if cfg().block_mqtt_offline_wake == false then
		return mayPowerT3x("mqtt_offline")
	end
	if isLowPowerMode() then
		return false
	end
	local cd = tonumber(cfg().mqtt_offline_wake_cooldown_sec)
	if cd and cd > 0 and lastMqttOfflineWakeSec > 0 then
		local elapsed = os.time() - lastMqttOfflineWakeSec
		if elapsed < cd then
			return false
		end
	end
	if cfg().block_mqtt_offline_wake_when_usb ~= false and isUsbInserted() then
		return false
	end
	return mayPowerT3x("mqtt_offline")
end
local function recordMqttOfflineWake(reason)
	if reason == "mqtt_offline" then
		lastMqttOfflineWakeSec = os.time()
	end
end
function requestT3xWake(reason, sid, evt, opts)
	reason = reason or "wake"
	sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
	evt = evt or 0
	opts = type(opts) == "table" and opts or {}
	if not mayPowerT3x(reason, opts) then
		return false
	end
	return t3x_notify.wakeHost(sid, evt, {
		on_done = function()
			recordMqttOfflineWake(reason)
		end,
	})
end
function bootPowerOn(t3xModule)
	if not mayPowerT3x("boot") then
		return false
	end
	if t3xModule and t3xModule.powerOn then
		return t3xModule.powerOn()
	end
	return false
end
return _M
