require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local logFuncs = utils.createLogFunctions("battery_guard")
local bgInfo = logFuncs.info
local bgWarn = logFuncs.warn
local pir_ctrl
local hooks = {}
local TIER_NORMAL = "normal"
local TIER_SHUTDOWN = "shutdown"
local guard = {
	pir_suspended = false,
	rest_by_battery = false,
	shutdown_timer = nil,
	last_percent = nil,
	last_mv = nil,
	shutdown_mv_streak = 0,
	rest_enter_ts = 0,
	rest_exit_ts = 0,
	enter_confirm_streak = 0,
	exit_confirm_streak = 0,
	host_idle_wake_ts = 0,
}
local function cfg()
	if type(_G.BATTERY_GUARD_CFG) == "table" then
		return _G.BATTERY_GUARD_CFG
	end
	local root = _G.BATTERY_CFG or {}
	return type(root.guard) == "table" and root.guard or {}
end
local function pctThreshold(key)
	return tonumber(cfg()[key])
end
local function intCfg(key, default)
	local v = tonumber(cfg()[key])
	if v == nil then
		return default
	end
	return v
end
local function getStrategy()
	return _G.LOW_POWER_ENTER_STRATEGY or "battery"
end
local function isHybridStrategy()
	return getStrategy() == "hybrid"
end
local function enabled()
	local fc = _G.FEATURE_CFG
	if fc and fc.low_power == false then
		return false
	end
	if cfg().enabled == false then
		return false
	end
	local flags = _G.MODULE_FLAGS
	if flags and flags.battery_guard == false then
		return false
	end
	return true
end
function isUsbInserted()
	if cfg().ignore_when_usb_inserted == false then
		return false
	end
	local rt = _G.APP_RUNTIME
	if rt and tonumber(rt.power_status) == 1 then
		return true
	end
	if type(hooks.is_usb_inserted) == "function" then
		return hooks.is_usb_inserted() and true or false
	end
	return false
end
local function shutdownMv()
	return tonumber(cfg().shutdown_mv)
end
local function shutdownRecoverMv()
	local recover = tonumber(cfg().shutdown_recover_mv)
	local cut = shutdownMv()
	if recover then
		return recover
	end
	if cut then
		return cut + 100
	end
	return nil
end
local function isShutdownByVoltage(mv)
	local cut = shutdownMv()
	mv = tonumber(mv)
	if cut == nil or mv == nil then
		return nil
	end
	return mv <= cut
end
function getBatteryTier(pct, mv)
	mv = tonumber(mv) or tonumber(guard.last_mv)
	local byMv = isShutdownByVoltage(mv)
	if byMv == true then
		return TIER_SHUTDOWN
	end
	pct = tonumber(pct)
	if pct == nil then
		return nil
	end
	local shutdownPct = pctThreshold("shutdown_percent")
	if shutdownPct ~= nil and byMv ~= true and pct <= shutdownPct then
		return TIER_SHUTDOWN
	end
	return TIER_NORMAL
end
local function syncBatteryTier(pct)
	local tier = getBatteryTier(pct, guard.last_mv)
	if _G.APP_RUNTIME and tier then
		_G.APP_RUNTIME.battery_tier = tier
	end
	return tier
end
local function loadPirCtrl()
	if pir_ctrl then
		return pir_ctrl
	end
	pir_ctrl = loader.load("pir_ctrl")
	return pir_ctrl
end
local function resetConfirmStreaks()
	guard.enter_confirm_streak = 0
	guard.exit_confirm_streak = 0
end
local function cancelShutdownTimer()
	if guard.shutdown_timer and sys.timerStop then
		sys.timerStop(guard.shutdown_timer)
	end
	guard.shutdown_timer = nil
end
local function isBlocked()
	if hooks.is_burn_active and hooks.is_burn_active() then
		return true, "t3x_burn"
	end
	if _G.T3X_BURN_MODE_ACTIVE then
		return true, "t3x_burn"
	end
	return false
end
local function suspendPir()
	if guard.pir_suspended then
		return
	end
	local pc = loadPirCtrl()
	if pc and pc.suspend then
		pc.suspend()
		guard.pir_suspended = true
	end
end
local function resumePir()
	if not guard.pir_suspended then
		return
	end
	local pc = loadPirCtrl()
	if pc and pc.resume then
		pc.resume()
	end
	guard.pir_suspended = false
end
local function dynamicDetectEnabled()
	return cfg().battery_rest_dynamic_detect ~= false
end
local function enterBatteryRest()
	if guard.rest_by_battery then
		return
	end
	bgWarn("enter_battery_rest", tostring(guard.last_percent or "nil"))
	guard.rest_by_battery = true
	guard.rest_enter_ts = os.time()
	resetConfirmStreaks()
	if _G.APP_RUNTIME then
		_G.APP_RUNTIME.battery_dynamic_rest = dynamicDetectEnabled() and 1 or 0
	end
	if type(hooks.on_enter_low_power) == "function" then
		hooks.on_enter_low_power("battery")
	end
end
local function exitBatteryRest()
	if not guard.rest_by_battery then
		return
	end
	bgInfo("exit_battery_rest", tostring(guard.last_percent or "nil"))
	guard.rest_by_battery = false
	guard.rest_exit_ts = os.time()
	guard.rest_enter_ts = 0
	resetConfirmStreaks()
	if _G.APP_RUNTIME then
		_G.APP_RUNTIME.battery_dynamic_rest = 0
	end
	if type(hooks.on_exit_low_power) == "function" then
		hooks.on_exit_low_power("battery_recover")
	end
end
function isBatteryDynamicRest()
	if not dynamicDetectEnabled() then
		return false
	end
	return guard.rest_by_battery == true
end
function shouldAllowHostIdleSleep()
	local rp = loader.load("runtime_power")
	if rp and rp.isPirWatch then
		return rp.isPirWatch() == true
	end
	return false
end
function canAcceptHostIdleSleep()
	if not shouldAllowHostIdleSleep() then
		return false
	end
	local minAwake = intCfg("host_idle_min_awake_sec", 30)
	if minAwake <= 0 or guard.host_idle_wake_ts <= 0 then
		return true
	end
	return (os.time() - guard.host_idle_wake_ts) >= minAwake
end
function noteT3xAwakeForHostIdle()
	guard.host_idle_wake_ts = os.time()
end
function markT3xWoken()
	noteT3xAwakeForHostIdle()
end
local function loadPctThresholds()
	return {
		shutdown = pctThreshold("shutdown_percent"),
		rest = pctThreshold("t3x_rest_percent"),
		recover = pctThreshold("recover_rest_percent"),
		host_idle = pctThreshold("host_idle_below_percent"),
		pir_suspend = pctThreshold("pir_suspend_percent"),
		pir_resume = pctThreshold("pir_resume_percent"),
	}
end
local function thresholdsReadyBattery(t)
	return t.shutdown ~= nil
end
local function thresholdsReadyHybrid(t)
	return t.shutdown and t.rest and t.recover and t.pir_suspend and t.pir_resume
end
local function canEnterRestNow()
	local minOn = intCfg("min_always_on_duration_sec", 0)
	if minOn > 0 and guard.rest_exit_ts > 0 then
		if os.time() - guard.rest_exit_ts < minOn then
			return false
		end
	end
	return true
end
local function canExitRestNow()
	local minRest = intCfg("min_rest_duration_sec", 0)
	if minRest > 0 and guard.rest_enter_ts > 0 then
		if os.time() - guard.rest_enter_ts < minRest then
			return false
		end
	end
	return true
end
local function tryEnterBatteryRest(pct, restPct)
	local need = math.max(1, intCfg("enter_rest_confirm_count", 1))
	if pct <= restPct then
		guard.enter_confirm_streak = guard.enter_confirm_streak + 1
	else
		guard.enter_confirm_streak = 0
		return
	end
	if guard.enter_confirm_streak < need then
		return
	end
	if not canEnterRestNow() then
		guard.enter_confirm_streak = 0
		return
	end
	if not dynamicDetectEnabled() then
		suspendPir()
	end
	enterBatteryRest()
end
local function tryExitBatteryRest(pct, recoverPct)
	local need = math.max(1, intCfg("exit_rest_confirm_count", 1))
	if pct > recoverPct then
		guard.exit_confirm_streak = guard.exit_confirm_streak + 1
	else
		guard.exit_confirm_streak = 0
		return
	end
	if guard.exit_confirm_streak < need then
		return
	end
	if not canExitRestNow() then
		return
	end
	exitBatteryRest()
end
local function tryExitMismatchedRest(pct, recoverPct)
	local rp = loader.load("runtime_power")
	if rp and rp.isPirWatch and rp.isPirWatch() then
		return
	end
	if pct == nil or recoverPct == nil or pct <= recoverPct then
		return
	end
	if guard.rest_by_battery then
		return
	end
	local rt = _G.APP_RUNTIME
	if not rt or tonumber(rt.low_power_mode) ~= 1 then
		return
	end
	if type(hooks.on_exit_low_power) == "function" then
		hooks.on_exit_low_power("battery_recover")
	end
end
local function scheduleShutdown()
	if guard.shutdown_timer then
		return
	end
	local delay = tonumber(cfg().shutdown_delay_ms) or 3000
	bgWarn("schedule_shutdown", delay, tostring(guard.last_percent or "nil"), tostring(guard.last_mv or "nil"))
	guard.shutdown_timer = sys.timerStart(function()
		guard.shutdown_timer = nil
		if isUsbInserted() then
			bgInfo("shutdown_canceled_usb")
			return
		end
		bgWarn("shutdown_execute")
		if type(hooks.on_power_off) == "function" then
			hooks.on_power_off()
		elseif pm and pm.shutdown then
			pm.shutdown()
		end
	end, delay)
end
local function resetShutdownMvStreak()
	guard.shutdown_mv_streak = 0
end
local function confirmShutdownByVoltage(mv)
	local byMv = isShutdownByVoltage(mv)
	if byMv == nil then
		return nil
	end
	if byMv then
		guard.shutdown_mv_streak = (guard.shutdown_mv_streak or 0) + 1
	else
		resetShutdownMvStreak()
		return false
	end
	local need = math.max(1, intCfg("shutdown_mv_confirm_count", 2))
	return guard.shutdown_mv_streak >= need
end
local function shouldEnterShutdown(pct, mv, shutdownPct)
	local confirmed = confirmShutdownByVoltage(mv)
	if confirmed == true then
		return true
	end
	if confirmed == false then
		return false
	end
	return pct ~= nil and shutdownPct ~= nil and pct <= shutdownPct
end
local function shouldLeaveShutdown(pct, mv, shutdownPct)
	local recover = shutdownRecoverMv()
	mv = tonumber(mv)
	if recover and mv then
		return mv > recover
	end
	return pct ~= nil and shutdownPct ~= nil and pct > shutdownPct
end
local function handleShutdownZone(pct, shutdownPct, mv)
	if not shouldEnterShutdown(pct, mv, shutdownPct) then
		return false
	end
	suspendPir()
	enterBatteryRest()
	scheduleShutdown()
	return true
end
local function evaluateBatteryStrategy(pct, t, mv)
	syncBatteryTier(pct)
	if handleShutdownZone(pct, t.shutdown, mv) then
		return
	end
	if guard.shutdown_timer and not shouldLeaveShutdown(pct, mv, t.shutdown) then
		return
	end
	cancelShutdownTimer()
	if guard.pir_suspended then
		resumePir()
	end
	if guard.rest_by_battery then
		exitBatteryRest()
	end
end
local function handleRestZoneHybrid(pct, t)
	if guard.rest_by_battery then
		tryExitBatteryRest(pct, t.recover)
	else
		tryEnterBatteryRest(pct, t.rest)
		tryExitMismatchedRest(pct, t.recover)
	end
end
local function handlePirZoneHybrid(pct, t)
	if pct <= t.pir_suspend then
		suspendPir()
	elseif pct > t.pir_resume then
		resumePir()
	end
end
local function evaluateHybridStrategy(pct, t, mv)
	syncBatteryTier(pct)
	if handleShutdownZone(pct, t.shutdown, mv) then
		return
	end
	if guard.shutdown_timer and not shouldLeaveShutdown(pct, mv, t.shutdown) then
		return
	end
	cancelShutdownTimer()
	if guard.pir_suspended then
		resumePir()
	end
	if guard.rest_by_battery then
		exitBatteryRest()
	end
end
function evaluate(pct, mv)
	if not enabled() then
		return
	end
	if isBlocked() then
		return
	end
	pct = tonumber(pct)
	mv = tonumber(mv)
	if pct == nil and mv == nil and cfg().require_valid_sample ~= false then
		return
	end
	guard.last_percent = pct
	if mv ~= nil then
		guard.last_mv = mv
	end
	if isUsbInserted() then
		resetShutdownMvStreak()
		cancelShutdownTimer()
		if guard.rest_by_battery or guard.pir_suspended then
			onUsbInserted()
		end
		return
	end
	if pct == nil and mv == nil then
		return
	end
	local t = loadPctThresholds()
	if isHybridStrategy() then
		if not thresholdsReadyHybrid(t) then
			return
		end
		evaluateHybridStrategy(pct, t, mv or guard.last_mv)
	else
		if not thresholdsReadyBattery(t) then
			return
		end
		evaluateBatteryStrategy(pct, t, mv or guard.last_mv)
	end
end
function onUsbInserted(opts)
	opts = type(opts) == "table" and opts or {}
	local source = opts.source
	bgInfo("usb_inserted", tostring(source or ""))
	cancelShutdownTimer()
	resetShutdownMvStreak()
	local wasRest = guard.rest_by_battery
	local wasPir = guard.pir_suspended
	guard.rest_by_battery = false
	guard.pir_suspended = false
	guard.rest_enter_ts = 0
	guard.rest_exit_ts = 0
	guard.host_idle_wake_ts = 0
	resetConfirmStreaks()
	if _G.APP_RUNTIME then
		_G.APP_RUNTIME.battery_dynamic_rest = 0
		_G.APP_RUNTIME.battery_tier = TIER_NORMAL
	end
	if wasPir then
		resumePir()
	end
	local exitedRest = false
	if wasRest or (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) then
		if type(hooks.on_exit_low_power) == "function" then
			hooks.on_exit_low_power("usb_insert")
			exitedRest = true
		end
	end
	if not exitedRest and source ~= "boot" and type(hooks.wake_t3x) == "function" then
		hooks.wake_t3x()
	end
end
function onUsbRemoved()
	bgInfo("usb_removed")
	local pct = guard.last_percent
	if pct == nil and _G.APP_RUNTIME then
		pct = tonumber(_G.APP_RUNTIME.battery_percent)
	end
	evaluate(pct, guard.last_mv)
end
function onBatteryUpdate(pct, mv)
	local prev = guard.last_percent
	local prevMv = guard.last_mv
	evaluate(pct, mv)
	if (tonumber(pct) and prev ~= tonumber(pct)) or (tonumber(mv) and prevMv ~= tonumber(mv)) then
		local tier = getBatteryTier(pct, mv)
		bgInfo("battery_update", tonumber(pct), tonumber(mv), tostring(tier or "nil"))
	end
end
function start(opts)
	hooks = type(opts) == "table" and opts or {}
	bgInfo("start", tostring(getStrategy()))
	local pct = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.battery_percent)
	local mv = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.battery_mv)
	if pct or mv then
		sys.taskInit(function()
			sys.wait(500)
			evaluate(pct, mv)
		end)
	end
	return true
end
function getState()
	return {
		enabled = enabled(),
		strategy = getStrategy(),
		battery_tier = getBatteryTier(guard.last_percent),
		usb_inserted = isUsbInserted(),
		pir_suspended = guard.pir_suspended,
		rest_by_battery = guard.rest_by_battery,
		battery_dynamic_rest = isBatteryDynamicRest(),
		shutdown_pending = guard.shutdown_timer ~= nil,
		last_percent = guard.last_percent,
		last_mv = guard.last_mv,
		shutdown_mv = shutdownMv(),
		shutdown_mv_streak = guard.shutdown_mv_streak,
		host_idle_wake_ts = guard.host_idle_wake_ts,
		rest_enter_ts = guard.rest_enter_ts,
		rest_exit_ts = guard.rest_exit_ts,
		enter_confirm_streak = guard.enter_confirm_streak,
		exit_confirm_streak = guard.exit_confirm_streak,
	}
end
return _M
