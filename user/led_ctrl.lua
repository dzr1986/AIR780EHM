require "sys"
require "config"
local gpio_util = require "gpio_util"
local _M = { _VERSION = "1.2.0" }
module(..., package.seeall)
_G[_M] = _M
local LED_CONFIG = {
	bluePin = 21,
	startup = { enabled = true, blinks = 2, light_ms = 400, dark_ms = 400 },
	low_percent = 20,
	low_blink_ms = 400,
	offline_blink_ms = 1000,
	ok_hold_ms = 5000,
	check_network = true,
	suppress_low_when_charging = true,
}
local bluePin, redPinRaw
local started = false
local lastPattern = ""
local function ledCfg()
	return _G.LED_CFG or {}
end
local function applyConfigs()
	local fromLed = ledCfg()
	if type(fromLed.startup) == "table" then
		for k, v in pairs(fromLed.startup) do LED_CONFIG.startup[k] = v end
	end
	for _, k in ipairs({
		"low_percent", "low_blink_ms", "low_blinks_per_round",
		"offline_blink_ms", "ok_hold_ms", "check_network", "unknown_hold_ms",
		"suppress_low_when_charging",
	}) do
		if fromLed[k] ~= nil then LED_CONFIG[k] = fromLed[k] end
	end
	if type(fromLed.network) == "table" and fromLed.network.enabled == false then
		LED_CONFIG.check_network = false
	end
	local batLed = (_G.BATTERY_CFG or {}).led
	if batLed and batLed.medium_threshold and not LED_CONFIG.low_percent then
		LED_CONFIG.low_percent = batLed.medium_threshold
	end
end
applyConfigs()
local function setBlue(on)
	if bluePin then bluePin(on == 1 and 1 or 0) end
end
local function blinkBlue(light, dark)
	setBlue(1)
	sys.wait(light or 0)
	setBlue(0)
	sys.wait(dark or 0)
end
local function readChargeFlags()
	local rt = _G.APP_RUNTIME or {}
	local usb, charging = false, false
	if _G.MODULE_FLAGS.charge ~= false then
		local ok, uc = pcall(require, "usb_charge")
		if ok and type(uc) == "table" then
			if uc.isUsbInserted then usb = uc.isUsbInserted() and true or false end
			if uc.isCharging then charging = uc.isCharging() == 1 end
		end
	end
	if not usb and rt.power_status == 1 then usb = true end
	return usb, charging
end
local function runtimeSnapshot()
	local rt = _G.APP_RUNTIME or {}
	local usb, charging = readChargeFlags()
	return {
		battery_percent = rt.battery_percent,
		online_status = rt.online_status,
		mqtt_enabled = (_G.MODULE_FLAGS or {}).mqtt ~= false,
		usb_inserted = usb,
		charging = charging,
	}
end
local function cycleCfg()
	return {
		low_percent = LED_CONFIG.low_percent or 20,
		low_blink_ms = LED_CONFIG.low_blink_ms,
		low_blinks_per_round = LED_CONFIG.low_blinks_per_round,
		offline_blink_ms = LED_CONFIG.offline_blink_ms,
		ok_hold_ms = LED_CONFIG.ok_hold_ms,
		check_network = LED_CONFIG.check_network,
		unknown_hold_ms = LED_CONFIG.unknown_hold_ms,
		suppress_low_when_charging = LED_CONFIG.suppress_low_when_charging,
	}
end
local function runOneCycle(st, cfg)
	st = type(st) == "table" and st or {}
	cfg = type(cfg) == "table" and cfg or {}
	local pct = tonumber(st.battery_percent)
	local online = st.online_status == 1
	local mqttOn = st.mqtt_enabled ~= false
	local chargingActive = cfg.suppress_low_when_charging ~= false
		and st.usb_inserted and (st.charging == 1 or st.charging == true)
	setBlue(0)
	if pct ~= nil and pct <= (tonumber(cfg.low_percent) or 20) and not chargingActive then
		local n = tonumber(cfg.low_blinks_per_round) or 6
		local ms = tonumber(cfg.low_blink_ms) or 400
		for _ = 1, n do blinkBlue(ms, ms) end
		return "low"
	end
	if cfg.check_network ~= false and mqttOn and not online then
		local ms = tonumber(cfg.offline_blink_ms) or 1000
		blinkBlue(ms, ms)
		return chargingActive and "charging_offline" or "offline"
	end
	if pct == nil and not chargingActive then
		sys.wait(tonumber(cfg.unknown_hold_ms) or 3000)
		return "unknown"
	end
	setBlue(1)
	sys.wait(tonumber(cfg.ok_hold_ms) or 5000)
	return chargingActive and "charging_ok" or "ok"
end
local function ledTask()
	sys.taskInit(function()
		local s = LED_CONFIG.startup or {}
		if s.enabled ~= false and bluePin then
			setBlue(0)
			local n = tonumber(s.blinks) or 2
			for _ = 1, n do blinkBlue(s.light_ms or 400, s.dark_ms or 400) end
		end
		while true do
			local pattern = runOneCycle(runtimeSnapshot(), cycleCfg())
			if pattern ~= lastPattern then
				lastPattern = pattern
			end
		end
	end)
end
local function setupEventRefresh()
	local E = _G.APP_EVENTS
	if not E then return end
	local function bump(_) lastPattern = "" end
	sys.subscribe(E.MQTT_CONNECTED, bump)
	sys.subscribe(E.MQTT_OFFLINE, bump)
	sys.subscribe("BATTERY_UPDATE", bump)
	if E.GPIO_USB_DET_CHANGED then sys.subscribe(E.GPIO_USB_DET_CHANGED, bump) end
	if E.GPIO_CHG_STATE_CHANGED then sys.subscribe(E.GPIO_CHG_STATE_CHANGED, bump) end
end
function _M.start(cfg)
	if started then return false end
	if cfg then for k, v in pairs(cfg) do LED_CONFIG[k] = v end end
	applyConfigs()
	local gout = _G.GPIO_OUT or {}
	local pinNum = LED_CONFIG.bluePin or 21
	local e = gout.bat_stat_led
	local raw
	if e and e.pin == pinNum then
		raw = gpio_util.setup_output(e)
		bluePin = function(logical)
			raw((logical == 1 or logical == true) and (e.on_level or 0) or (e.init_level or 1))
		end
	else
		raw = gpio.setup(pinNum, 1)
		bluePin = function(logical) raw(logical == 1 and 0 or 1) end
	end
	local re = gout.led_red
	if re and re.enabled ~= false and re.pin then
		redPinRaw = gpio_util.setup_output(re)
	end
	if not bluePin then
		return false
	end
	setBlue(0)
	setupEventRefresh()
	ledTask()
	started = true
	return true
end
function _M.setLed(_red, blue)
	setBlue(blue)
end
function _M.turnOff()
	setBlue(0)
end
function _M.blinkRed()
	if not redPinRaw then return end
	for _ = 1, 3 do
		redPinRaw(1)
		sys.wait(500)
		redPinRaw(0)
		sys.wait(500)
	end
end
function _M.blinkBlue()
	if not bluePin then return end
	for _ = 1, 3 do blinkBlue(500, 500) end
end
function _M.getState()
	return { started = started, mode = "1bl", last_pattern = lastPattern }
end
function _M.getConfig()
	return LED_CONFIG
end
return _M
