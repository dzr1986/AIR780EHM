require "sys"
require "sysplus"
require "config"
local gpio_util = require "gpio_util"
local led_ctrl = require "led_ctrl"
local pir_ctrl = require "pir_ctrl"
local _M = {}
module(..., package.seeall)
local LOG_TAG = "peripheral"
local keyStarted = false
local bootCfg, pwrCfg, readyCfg
local pressStates = {
	boot = { timer = nil, long_fired = false },
	pwr = { timer = nil, long_fired = false },
}
local function shallowMerge(base, over)
	local out = {}
	if base then for k, v in pairs(base) do out[k] = v end end
	if over then for k, v in pairs(over) do out[k] = v end end
	return out
end
local function loadKeySection(name, overrides)
	return shallowMerge((_G.KEY_CONFIG and _G.KEY_CONFIG[name]) or {}, overrides)
end
local function publishAppEvent(eventKey)
	local E = _G.APP_EVENTS
	if E and E[eventKey] then sys.publish(E[eventKey]) end
end
local function setupLongPressKey(cfg, state)
	if not cfg or not cfg.pin then return end
	local pressLevel = cfg.pressLevel
	if pressLevel == nil then pressLevel = 0 end
	if cfg.requireReleaseFirst and gpio and gpio.get and gpio.get(cfg.pin) == pressLevel then
		state.await_release = true
	end
	gpio_util.setup_input(cfg.pin, function(level)
		if state.await_release then
			if level ~= pressLevel then state.await_release = false end
			return
		end
		if level == pressLevel then
			if state.timer then sys.timerStop(state.timer) end
			state.long_fired = false
			state.timer = sys.timerStart(function()
				state.timer = nil
				state.long_fired = true
				publishAppEvent(cfg.events and cfg.events.long)
				if cfg.onLongPress then cfg.onLongPress() end
			end, cfg.longPressMs or cfg.longPressTimeout or 2000)
		else
			if state.timer then sys.timerStop(state.timer); state.timer = nil end
			if not state.long_fired then
				publishAppEvent(cfg.events and cfg.events.short)
				if cfg.onShortPress then cfg.onShortPress() end
			end
			state.long_fired = false
		end
	end, {
		trigger_mode = cfg.triggerMode or "both",
		pull = cfg.pull or "pullup",
		debounce_ms = cfg.debounce or 100,
	})
end
local function setupReadySignal(cfg)
	if not cfg or not cfg.pin then return end
	local active = cfg.activeLevel
	if active == nil then active = 1 end
	gpio_util.setup_input(cfg.pin, function(level)
		if level == active then
			publishAppEvent(cfg.event)
			if cfg.onReady then cfg.onReady() end
		end
	end, {
		trigger_mode = cfg.triggerMode or "rising",
		pull = cfg.pull or "pulldown",
		debounce_ms = cfg.debounce or 100,
	})
end
local function normalizeConfig(cfg)
	cfg = cfg or {}
	local led = cfg.led or {}
	local keyCfg = cfg.key or {}
	if cfg.ledBluePin then led.bluePin = cfg.ledBluePin end
	if cfg.pwrkeyPin or cfg.onPwrkeyShort or cfg.onPwrkeyLong then
		keyCfg.pwrkey = keyCfg.pwrkey or {}
		if cfg.pwrkeyPin then keyCfg.pwrkey.pin = cfg.pwrkeyPin end
		if cfg.onPwrkeyShort then keyCfg.pwrkey.onShortPress = cfg.onPwrkeyShort end
		if cfg.onPwrkeyLong then keyCfg.pwrkey.onLongPress = cfg.onPwrkeyLong end
	end
	if cfg.bootkeyPin or cfg.onBootkeyShort or cfg.onBootkeyLong then
		keyCfg.bootkey = keyCfg.bootkey or {}
		if cfg.bootkeyPin then keyCfg.bootkey.pin = cfg.bootkeyPin end
		if cfg.onBootkeyShort then keyCfg.bootkey.onShortPress = cfg.onBootkeyShort end
		if cfg.onBootkeyLong then keyCfg.bootkey.onLongPress = cfg.onBootkeyLong end
	end
	if cfg.readyPin or cfg.onReady then
		keyCfg.ready = keyCfg.ready or {}
		if cfg.readyPin then keyCfg.ready.pin = cfg.readyPin end
		if cfg.onReady then keyCfg.ready.onReady = cfg.onReady end
	end
	return { led = led, key = keyCfg }
end
function _M.cancelLongPress(name)
	local state = pressStates[name]
	if not state then return false end
	if state.timer then sys.timerStop(state.timer); state.timer = nil end
	state.long_fired = false
	return true
end
function _M.start(cfg)
	local sub = normalizeConfig(cfg)
	led_ctrl.start(sub.led)
	if not keyStarted then
		cfg = sub.key or {}
		pwrCfg = loadKeySection("pwrkey", cfg.pwrkey)
		bootCfg = loadKeySection("bootkey", cfg.bootkey)
		readyCfg = loadKeySection("ready", cfg.ready)
		setupLongPressKey(pwrCfg, pressStates.pwr)
		setupLongPressKey(bootCfg, pressStates.boot)
		setupReadySignal(readyCfg)
		keyStarted = true
	end
	pir_ctrl.startHw()
	return true
end
function _M.getState()
	return {
		led = led_ctrl.getState(),
		key = { started = keyStarted, pwrkey = pwrCfg and pwrCfg.pin, bootkey = bootCfg and bootCfg.pin },
		pir = pir_ctrl.getState(),
	}
end
function _M.getConfig()
	return { led = led_ctrl.getConfig(), pir = pir_ctrl.getMediaConfig() }
end
function _M.setLed(red, blue)
	led_ctrl.setLed(red, blue)
end
function _M.turnOffLed()
	led_ctrl.turnOff()
end
function _M.runLedPattern(pattern)
	if pattern == "blink_red" and led_ctrl.blinkRed then
		sys.taskInit(led_ctrl.blinkRed)
	elseif pattern == "blink_blue" and led_ctrl.blinkBlue then
		sys.taskInit(led_ctrl.blinkBlue)
	else
	end
end
return _M
