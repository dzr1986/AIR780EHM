require "sys"
require "sysplus"
require "config"
local function optMod(flag, name, loader)
	local flags = _G.MODULE_FLAGS
	if flags and flags[flag] == false then
		return nil
	end
	local ok, m
	if loader then
		ok, m = pcall(loader)
	else
		ok, m = pcall(require, name)
	end
	if not ok or type(m) ~= "table" then
		return nil
	end
	return m
end
local uart_bridge = require "uart_bridge"
local pir_ctrl = require "pir_ctrl"
local battery_guard = require "battery_guard"
local host_uart = require "host_uart"
local ipc_supervision = require "ipc_supervision"
local batAdc = optMod("battery", "vbat", function()
	return require "vbat"
end)
local usbCharge = optMod("charge", "usb_charge")
local mobile_info = optMod("mobile_info", "mobile_info")
local fota = optMod("fota", "fota_svc", function()
	return require "fota_svc"
end)
local usbRndis = optMod("rndis", "usb_rndis")
local sound_prompt = optMod("sound_prompt", "sound_prompt")
local time_sync = optMod("time_sync", "time_sync")
local watchdogMod = optMod("watchdog", "watchdog")
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local L = "app_main"
local function appInfo(...)
	if log and log.info then
		log.info(L, ...)
	end
end
local function appWarn(...)
	if log and log.warn then
		log.warn(L, ...)
	elseif log and log.info then
		log.info(L, ...)
	end
end
local function appError(...)
	if log and log.error then
		log.error(L, ...)
	end
end
local stopWatchdogBeforePowerOff
local E = APP_EVENTS
local started = false
local gpioModule = nil
local netModule = nil
local t3xModule = nil
local state = {
	flag_usb = true,
	mqtt_started = false,
	last_input = nil,
	last_uart_rx = nil,
	last_wake_event = nil,
	last_usb_state = nil,
	heartbeat_count = 0,
	t3x_burn_active = false,
	heartbeat_paused = false,
	usb_insert_tick = 0,
}
local function usbPwrkeyGraceMs()
	return tonumber((_G.HOST_USB_CFG or {}).pwrkey_grace_ms) or 5000
end
local modCache = {}
local function lazyMod(name)
	local mod = modCache[name]
	if mod == nil then
		local ok, loaded = pcall(require, name)
		mod = ok and type(loaded) == "table" and loaded or false
		modCache[name] = mod
	end
	return mod ~= false and mod or nil
end
local function usbPolicyMod()
	return lazyMod("usb_policy")
end
local function t3xPolicyMod()
	return lazyMod("t3x_policy")
end
local function lowPowerWakeupMod()
	return lazyMod("low_power_wakeup")
end
local function deviceIdMod()
	return lazyMod("device_id")
end
local function nowMs()
	if mcu and mcu.ticks then
		return mcu.ticks()
	end
	return os.time() * 1000
end
local function cancelPwrKeyLongPress()
	if gpioModule and gpioModule.cancelLongPress then
		gpioModule.cancelLongPress("pwr")
	end
end
local function setLowPowerMode(enabled)
	local v = enabled and 1 or 0
	local rt = _G.APP_RUNTIME
	if rt.low_power_mode == v then
		return false
	end
	rt.low_power_mode = v
	return true
end
local function isLowPowerFeatureEnabled()
	local fc = _G.FEATURE_CFG
	if fc and fc.low_power == false then
		return false
	end
	local lp = _G.LOW_POWER_CFG
	if lp and lp.enabled == false then
		return false
	end
	if _G.MODULE_FLAGS and _G.MODULE_FLAGS.low_power == false then
		return false
	end
	return true
end
local function requestT3xWake(reason, sid, evt, opts)
	sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
	evt = evt or 0
	state.last_wake_event = evt
	local policy = t3xPolicyMod()
	if type(policy) == "table" and policy.requestT3xWake
		and (_G.MODULE_FLAGS.t3x_policy ~= false) then
		return policy.requestT3xWake(reason, sid, evt, opts)
	end
	if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
		if _G.MODULE_FLAGS.time_sync ~= false and type(time_sync) == "table"
			and time_sync.pushBeforeNotifyAsync then
			time_sync.pushBeforeNotifyAsync(sid, evt)
		else
			host_uart.notify_host(sid, evt)
		end
	elseif t3xModule and t3xModule.pulseWakeup then
		t3xModule.pulseWakeup()
	end
	return true
end
local function onMqttOffline()
	local policy = t3xPolicyMod()
	if type(policy) == "table" and policy.shouldWakeOnMqttOffline
		and (_G.MODULE_FLAGS.t3x_policy ~= false) then
		if not policy.shouldWakeOnMqttOffline() then
			local why = policy.getDenyReason and policy.getDenyReason() or ""
			return
		end
		if policy.requestT3xWake then
			policy.requestT3xWake("mqtt_offline", 2, 0)
			return
		end
	end
	requestT3xWake("mqtt_offline", 2, 0)
end
local function doEnterLowPowerBody(reason)
	reason = reason or "unknown"
	if not setLowPowerMode(true) then return end
	appInfo("enter_low_power", reason)
	_G.APP_RUNTIME.last_rest_reason = reason
	sys.publish(E.POWER_ENTERED_REST)
	if t3xModule and t3xModule.enterSleep then
		local modemHibernate = false
		local lpw = lowPowerWakeupMod()
		if lpw and lpw.getModemHibernate then
			modemHibernate = lpw.getModemHibernate() == true
		else
			local lp = _G.LOW_POWER_CFG or {}
			modemHibernate = lp.modem_hibernate == true
		end
		t3xModule.enterSleep({ modemHibernate = modemHibernate })
	end
	if state.mqtt_started and netModule and netModule.publishRest then
		netModule.publishRest({ reason = reason, source = "enter" })
	end
	local lpw = lowPowerWakeupMod()
	if lpw and lpw.onEnterRest then
		lpw.onEnterRest()
	end
end
local function notifyT3xUsbHostIdlePolicy(inserted)
	if not host_uart or not host_uart.push_usb_host_idle_state then
		return
	end
	host_uart.push_usb_host_idle_state(inserted == true or inserted == 1)
end
local function onEnterLowPower(reason)
	reason = reason or "unknown"
	if not isLowPowerFeatureEnabled() then
		return
	end
	local up = usbPolicyMod()
	if up and up.blocks4gRest and up.blocks4gRest() then
		return
	end
	if type(sound_prompt) == "table" and sound_prompt.shouldPlay
		and sound_prompt.shouldPlay("shutdown_low_power") then
		sys.taskInit(function()
			if sound_prompt.playBlocking then
				sound_prompt.playBlocking("off", "shutdown_low_power")
			end
			doEnterLowPowerBody(reason)
		end)
		return
	end
	doEnterLowPowerBody(reason)
end
local function onExitLowPower(reason)
	reason = reason or "unknown"
	if not setLowPowerMode(false) then return end
	appInfo("exit_low_power", reason)
	_G.APP_RUNTIME.last_rest_reason = nil
	if state.mqtt_started and netModule and netModule.publishRest then
		if reason == "usb_insert" then
			sys.taskInit(function()
				sys.wait(5000)
				if usbRndis and usbRndis.isRefreshing and usbRndis.isRefreshing() then
					return
				end
				local st = netModule.getState and netModule.getState() or nil
				if st and st.connected then
					netModule.publishRest({ lowPowerMode = "exit", reason = reason })
				else
				end
			end)
		else
			netModule.publishRest({ lowPowerMode = "exit", reason = reason })
		end
	end
	sys.publish(E.POWER_EXITED_REST)
	requestT3xWake("exit_low_power", nil, nil, { force_wake = true })
	local lpw = lowPowerWakeupMod()
	if lpw and lpw.onExitRest then
		lpw.onExitRest()
	end
	if _G.MODULE_FLAGS.sound_prompt ~= false and type(sound_prompt) == "table"
		and sound_prompt.onWakeFromLowPower then
		sound_prompt.onWakeFromLowPower()
	end
end
local function onReboot()
	appWarn("device_reboot_request")
	stopWatchdogBeforePowerOff()
	sys.timerStart(function()
	if pm and pm.reboot then pm.reboot() end
	end, 500)
end
local function onPowerOff(reason)
	appWarn("device_poweroff_request", tostring(reason or "unknown"))
	local function shutdownNow()
		if reason == "battery" then
			local okBg, bg = pcall(require, "battery_guard")
			if okBg and type(bg) == "table" and bg.isUsbInserted and bg.isUsbInserted() then
				return
			end
		end
		stopWatchdogBeforePowerOff()
		pm.shutdown()
	end
	local function proceedShutdown()
		if _G.MODULE_FLAGS.sound_prompt ~= false and type(sound_prompt) == "table"
			and sound_prompt.playShutdownThen then
			sound_prompt.playShutdownThen(reason or "user", shutdownNow)
			return
		end
		shutdownNow()
	end
	if state.mqtt_started and netModule and netModule.notifyPowerOff then
		netModule.notifyPowerOff(reason, proceedShutdown)
		return
	end
	proceedShutdown()
end
local function setupUartBridge()
	if _G.APP_STACK and _G.APP_STACK.uart ~= "uart_bridge" then
		return false
	end
	local ok = uart_bridge.start({
		onRaw = function(data)
			state.last_uart_rx = data
			if _G.MODULE_FLAGS.t3x_app ~= false then
				host_uart.on_rx_raw(data)
			end
		end,
	})
	if ok then
		_G.uart_bridge = uart_bridge
		local uc = _G.UART_CFG
		if type(uc) == "table" then
		else
		end
		if _G.MODULE_FLAGS.t3x_app ~= false then
			host_uart.start({
				t3x = t3xModule,
				on_enter_low_power = function() onEnterLowPower("at") end,
				on_exit_low_power = function() onExitLowPower("at") end,
				on_reboot = onReboot,
				on_power_off = function()
					onPowerOff("user")
				end,
				on_mqtt_cfg = function(cfg)
					if not netModule or not netModule.setMqttConfig then
						return
					end
					if netModule.isSameMqttConfig and netModule.isSameMqttConfig(cfg) then
						return
					end
					if not netModule.setMqttConfig(cfg) then
						return
					end
					if state.mqtt_started and netModule.restart then
						netModule.restart()
					elseif startMqtt() then
					end
				end,
				on_servcreate = function(ch)
					local lpw = require "low_power_wakeup"
					lpw.applyTcpChannel(ch)
				end,
				on_servclose = function(sid)
					local lpw = require "low_power_wakeup"
					lpw.closeTcpChannel(sid)
				end,
				on_plain_line = function(line)
				end,
			})
		end
	end
	return ok
end
function getUartBridge()
	return _G.uart_bridge or uart_bridge
end
local function enterRestIfNeededAfterUsbRemove(source)
	if not isLowPowerFeatureEnabled() then
		return
	end
	local rndisOn = _G.MODULE_FLAGS.rndis
		and type(usbRndis) == "table"
		and usbRndis.isEnabled
		and usbRndis.isEnabled()
	if rndisOn then
		return
	end
	if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
		battery_guard.onUsbRemoved()
	elseif _G.APP_RUNTIME.low_power_mode == 0 then
		onEnterLowPower("usb_remove")
	end
end
local function exitRestIfNeededAfterUsbInsert(source)
	if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
		battery_guard.onUsbInserted({ source = source })
	else
		onExitLowPower("usb_insert")
	end
end
local function applyUsbInsertState(inserted, source)
	local v = inserted and 1 or 0
	state.last_usb_state = v
	appInfo("usb_state", v, tostring(source or ""))
	_G.APP_RUNTIME.power_status = v
	sys.publish(E.GPIO_VBUS_CHANGED, v)
	if v == 0 then
		state.flag_usb = false
		notifyT3xUsbHostIdlePolicy(false)
		enterRestIfNeededAfterUsbRemove(source)
	else
		state.flag_usb = true
		state.usb_insert_tick = nowMs()
		cancelPwrKeyLongPress()
		exitRestIfNeededAfterUsbInsert(source)
		notifyT3xUsbHostIdlePolicy(true)
	end
end
local function handlePmdMessage(msg)
	if not msg or _G.MODULE_FLAGS.charge then
		return
	end
	state.last_usb_state = msg.state
	_G.APP_RUNTIME.power_status = msg.charger and 1 or 0
	sys.publish(E.GPIO_VBUS_CHANGED, _G.APP_RUNTIME.power_status)
	if msg.state == 0 then
		applyUsbInsertState(false, "PMD")
	elseif msg.state == 1 then
		applyUsbInsertState(true, "PMD")
	end
end
local function setupPmd()
	if rtos and rtos.MSG_PMD then
		rtos.on(rtos.MSG_PMD, handlePmdMessage)
		pmd.init({})
	end
end
local function setupWatchdog()
	if not _G.MODULE_FLAGS.watchdog then
		return
	end
	local wdtMod = watchdogMod or lazyMod("watchdog")
	if wdtMod and wdtMod.start then
		local ok = wdtMod.start(_G.WDT_CFG)
	else
	end
end
stopWatchdogBeforePowerOff = function()
	if not _G.MODULE_FLAGS.watchdog then
		return
	end
	local wdtMod = watchdogMod or lazyMod("watchdog")
	if wdtMod and wdtMod.stop then
		wdtMod.stop()
	end
end
local function getImei()
	local did = deviceIdMod()
	if did and did.getDisplayId then
		return did.getDisplayId()
	end
	if _G.aliyuncs_imei and _G.aliyuncs_imei ~= "" then
		return tostring(_G.aliyuncs_imei)
	end
	if mobile and mobile.imei then
		local id = mobile.imei()
		if id and id ~= "" then
			return tostring(id)
		end
	end
	return "unknown"
end
function startMqtt()
	if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
		appWarn("mqtt_start_skip_burn_mode")
		return false
	end
	if state.mqtt_started then
		appInfo("mqtt_already_started")
		return false
	end
	if not _G.MODULE_FLAGS.mqtt then
		appWarn("mqtt_module_disabled")
		return false
	end
	if not netModule or not (_G.APP_STACK and _G.APP_STACK.mqtt == "net_mqtt") then
		appError("mqtt_module_not_ready")
		return false
	end
	state.mqtt_started = true
	appInfo("mqtt_start")
	netModule.start()
	return true
end
local function bootMqtt()
	if not _G.MODULE_FLAGS.mqtt then
		return
	end
	if not netModule then
		return
	end
	sys.taskInit(function()
		sys.waitUntil("net_ready", 300000)
		_G.device_imei = getImei()
		startMqtt()
	end)
end
local function setupFota()
	if not _G.MODULE_FLAGS.fota then
		return
	end
	local fotaMod = fota or _G.fota_svc
	if not fotaMod or not fotaMod.start then
		return
	end
	fotaMod.start({
		publishStatus = function(stage, retCode, message, extra)
			if netModule and netModule.publishOtaStatus then
				netModule.publishOtaStatus(stage, retCode, message, extra)
			end
		end,
		})
end
local function setupRndis()
	if not _G.MODULE_FLAGS.rndis then
		return
	end
	if type(usbRndis) ~= "table" or not usbRndis.isStarted then
		return
	end
	if usbRndis.isStarted and not usbRndis.isStarted() and usbRndis.start then
		usbRndis.start()
	end
end
local function getBatteryPercentForBurn()
	local pct = tonumber(_G.APP_RUNTIME and _G.APP_RUNTIME.battery_percent)
	if pct and pct >= 0 then
		return pct
	end
	if type(batAdc) == "table" and batAdc.getPercent then
		pct = tonumber(batAdc.getPercent())
		if pct and pct > 0 then
			return pct
		end
	end
	return nil
end
local function checkT3xBurnPreconditionsOnce(attemptIndex, attemptTotal)
	local cfg = _G.T3X_BURN_CFG or {}
	local minPct = tonumber(cfg.min_battery_percent) or 20
	local allowRepeat = cfg.allow_repeat_enter_boot ~= false
	local failReason = nil
	local pct = getBatteryPercentForBurn()
	if cfg.require_battery_valid ~= false then
		if not pct then
			failReason = "battery_invalid"
		elseif pct < minPct then
			failReason = "batL"
		end
	end
	if not t3xModule or not t3xModule.getState then
		failReason = failReason or "noT3"
	else
		local st = t3xModule.getState() or {}
		if st.in_boot_mode and not allowRepeat then
			failReason = failReason or "boot"
		end
	end
	if failReason then
		return false, failReason
	end
	return true, pct
end
local function checkT3xBurnPreconditions()
	local cfg = _G.T3X_BURN_CFG or {}
	local retryCount = math.max(0, tonumber(cfg.burn_check_retry_count) or 2)
	local maxAttempts = 1 + retryCount
	local retryMs = tonumber(cfg.burn_check_retry_interval_ms) or 800
	local lastFailReason = nil
	local lastPassPct = nil
	for attempt = 1, maxAttempts do
		local ok, detail = checkT3xBurnPreconditionsOnce(attempt, maxAttempts)
		if ok then
			lastPassPct = detail
			return true, lastPassPct
		end
		lastFailReason = detail
		if attempt < maxAttempts then
			sys.wait(retryMs)
		end
	end
	return false, lastFailReason
end
local function shutdownServicesForT3xBurn(cfg)
	cfg = cfg or _G.T3X_BURN_CFG or {}
	appWarn("t3x_burn_prepare")
	_G.T3X_BURN_MODE_ACTIVE = true
	state.t3x_burn_active = true
	state.heartbeat_paused = true
	if cfg.suspend_pir ~= false and pir_ctrl.suspend then
		pir_ctrl.suspend()
	end
	if cfg.stop_mqtt ~= false and state.mqtt_started and netModule and netModule.stop then
		netModule.stop()
		state.mqtt_started = false
		appInfo("t3x_burn_mqtt_stopped")
	end
	if cfg.stop_uart ~= false then
		local ub = _G.uart_bridge or uart_bridge
		if ub and ub.stop then
			ub.stop()
		end
	end
	if cfg.stop_rndis ~= false and _G.MODULE_FLAGS.rndis then
		if type(usbRndis) == "table" and usbRndis.disable then
			local rndisOk, rndisErr = usbRndis.disable()
			if rndisOk then
				appInfo("t3x_burn_rndis_disabled")
			else
				appWarn("t3x_burn_rndis_disable_fail", tostring(rndisErr or ""))
			end
		end
	end
	if cfg.turn_off_led ~= false and gpioModule and gpioModule.turnOffLed then
		gpioModule.turnOffLed()
	end
	sys.wait(300)
	return true
end
local function tryEnterT3xBurnMode()
	local cfg = _G.T3X_BURN_CFG or {}
	local ok, detail = checkT3xBurnPreconditions()
	if not ok then
		appWarn("t3x_burn_denied", tostring(detail or "unknown"))
		if gpioModule and gpioModule.runLedPattern then
			gpioModule.runLedPattern("blink_red")
		end
		return false
	end
	shutdownServicesForT3xBurn(cfg)
	if not t3xModule or not t3xModule.enterBootMode then
		appError("t3x_burn_no_t3x_module")
		return false
	end
	if not t3xModule.enterBootMode() then
		appError("t3x_burn_enter_bootmode_fail")
		return false
	end
	appWarn("t3x_burn_entered")
	return true
end
local function wakeT3xForPir(tag, sid, evt)
	if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table"
		and battery_guard.noteT3xAwakeForHostIdle then
		battery_guard.noteT3xAwakeForHostIdle()
	end
	if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
		local wakeSid = sid or ((_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1)
		local opts = nil
		if (_G.PIR_CFG or {}).high_priority ~= false then
			opts = { force_wake = true }
		end
		requestT3xWake(tag, wakeSid, evt or 0, opts)
	end
end
local function subscribeAll(handlers)
	for _, item in ipairs(handlers) do
		sys.subscribe(item[1], item[2])
	end
end
local function publishPirToMqtt(overrides)
	if netModule and netModule.publishPirEvent then
		netModule.publishPirEvent(overrides)
	elseif netModule and netModule.publishPirDetect then
		netModule.publishPirDetect(overrides)
	end
end
local function maybePublishWakeupForPir(uploadMode)
	local inRest = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.low_power_mode) == 1
	if (uploadMode == "auto" or uploadMode == nil) and not inRest
		and netModule and netModule.publishWakeup then
		netModule.publishWakeup()
	end
end
local function scheduleDelayedStatusPublish(delayMs)
	delayMs = tonumber(delayMs) or 2000
	sys.timerStart(function()
		if _G.APP_RUNTIME.online_status == 1 and netModule and netModule.publishStatus then
			sys.taskInit(function()
				netModule.publishStatus()
			end)
		end
	end, delayMs)
end
local function onPirMediaAction(action, uploadMode, quality)
	if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
		return
	end
	maybePublishWakeupForPir(uploadMode)
	wakeT3xForPir("pir_media")
end
local function t3xRecActive()
	if host_uart and host_uart.getT3xRecActive then
		return host_uart.getT3xRecActive() == 1
	end
	return false
end
local function stopMqttFallbackMs()
	local cfg = _G.PIR_RECORD_CFG or {}
	return tonumber(cfg.stop_mqtt_fallback_ms) or 15000
end
local function scheduleStopMqttFallback(reason, uploadMode, quality)
	local waitMs = stopMqttFallbackMs()
	sys.taskInit(function()
		sys.wait(waitMs)
		if not pir_ctrl.canPublishStopMqtt or not pir_ctrl.canPublishStopMqtt() then
			return
		end
		local st = pir_ctrl.getState()
		if st.last_stop_reason ~= reason then
			return
		end
		if netModule and netModule.publishPirRecordStop then
			netModule.publishPirRecordStop(reason, uploadMode, quality, { source = "4g" })
		end
	end)
end
local function onPirStopRecording(reason, uploadMode, quality)
	local preferT3x = (reason == "timer" or reason == "device" or reason == "manual")
		and t3xRecActive()
	if not preferT3x and netModule and netModule.publishPirRecordStop then
		netModule.publishPirRecordStop(reason, uploadMode, quality, { source = "4g" })
	elseif preferT3x then
		scheduleStopMqttFallback(reason, uploadMode, quality)
	end
	wakeT3xForPir("pir_stop")
end
local function buildPirMqttHandlers()
	local stopTimer = (_G.APP_PIR_CONFIG and _G.APP_PIR_CONFIG.STOP_REASON
		and _G.APP_PIR_CONFIG.STOP_REASON.TIMER) or "timer"
	return {
		{ E.PIR_WAKE_T3X, function(action, uploadMode, quality)
			onPirMediaAction(action, uploadMode, quality)
		end },
		{ E.PIR_MEDIA_EFFECTIVE, function(action)
			publishPirToMqtt({ pirStatus = "media_sync", action = action })
		end },
		{ E.PIR_REQUEST_T3X_STOP, function(reason)
			wakeT3xForPir("pir_stop_" .. tostring(reason))
		end },
		{ E.PIR_STOP_RECORDING, function(reason, uploadMode, quality)
			onPirStopRecording(reason, uploadMode, quality)
		end },
		{ E.T3X_SNAPSHOT_DONE, function(path)
			if netModule and netModule.publishPirSnapshotDone then
				netModule.publishPirSnapshotDone(path)
			end
		end },
		{ E.T3X_RECORD_ACTIVE, function()
			if netModule and netModule.publishPirRecordActive then
				netModule.publishPirRecordActive()
			end
		end },
		{ E.T3X_PERSON_CNT, function(count)
			publishPirToMqtt({ pirStatus = "person_update", personCount = tonumber(count) or 0 })
		end },
		{ E.T3X_RECORD_STOP, function(reason, uploadMode, quality)
			if netModule and netModule.publishT3xRecordStop then
				netModule.publishT3xRecordStop(reason, uploadMode, quality)
			end
		end },
		{ E.T3X_IPC_ALERT, function(alertCode, alertDetail)
			ipc_supervision.onAlert(alertCode, alertDetail)
		end },
		{ E.PIR_TIMER_EXPIRED, function()
			pir_ctrl.publishStopRecording(stopTimer)
		end },
		{ E.GPIO_PIR_TRIGGERED, function(pirStatus, action, uploadMode, quality)
			publishPirToMqtt({
				pirStatus = pirStatus or "detected",
				action = action,
				uploadMode = uploadMode,
				quality = quality,
			})
		end },
	}
end
local function buildSystemEventHandlers()
	return {
		{ E.POWER_ENTER_REST, function()
			if not isLowPowerFeatureEnabled() then
				return
			end
			local up = usbPolicyMod()
			if up and up.blocks4gRest and up.blocks4gRest() then
				return
			end
			onEnterLowPower("mqtt_2002")
		end },
		{ E.POWER_EXIT_REST, function()
			if isLowPowerFeatureEnabled() or (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) then
				onExitLowPower("mqtt_2002")
			end
		end },
		{ E.DEVICE_REBOOT_REQUEST, onReboot },
		{ E.DEVICE_POWER_OFF_REQUEST, function()
			onPowerOff("mqtt")
		end },
		{ E.GPIO_PWRKEY_LONG, function()
			if state.usb_insert_tick > 0 and (_G.APP_RUNTIME.power_status or 0) == 1 then
				local elapsed = nowMs() - state.usb_insert_tick
				if elapsed < usbPwrkeyGraceMs() then
					return
				end
			end
			onPowerOff("user")
		end },
		{ E.GPIO_BOOTKEY_LONG, function()
			sys.taskInit(tryEnterT3xBurnMode)
		end },
		{ E.GPIO_COPROC_READY, function()
			if t3xModule then
				t3xModule.exitBootMode()
			end
			if pir_ctrl.resume and state.t3x_burn_active then
				pir_ctrl.resume()
				_G.T3X_BURN_MODE_ACTIVE = false
				state.t3x_burn_active = false
				state.heartbeat_paused = false
			end
		end },
		{ E.GPIO_USB_DET_CHANGED, function(inserted)
			applyUsbInsertState(inserted == 1, "GPIO27")
			if inserted == 1 and state.mqtt_started then
				scheduleDelayedStatusPublish(2000)
			end
		end },
		{ E.GPIO_CHG_STATE_CHANGED, function(charging)
			if state.mqtt_started and netModule and netModule.publishStatus
				and _G.APP_RUNTIME.online_status == 1 then
				sys.taskInit(function()
					netModule.publishStatus()
				end)
			end
		end },
		{ "BATTERY_UPDATE", function(pct, mv)
			if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
				battery_guard.onBatteryUpdate(pct, mv)
			end
		end },
		{ E.MQTT_OFFLINE, onMqttOffline },
	}
end
local function setupEventHandlers()
	pir_ctrl.start()
	subscribeAll(buildSystemEventHandlers())
	subscribeAll(buildPirMqttHandlers())
end
local function setupGpio()
	if not gpioModule or not _G.MODULE_FLAGS.gpio then return end
	local gin, gout = _G.GPIO_IN, _G.GPIO_OUT
	gpioModule.start({
		pwrkeyPin = gin and gin.pwr_key and gin.pwr_key.pin,
		bootkeyPin = gin and gin.boot_key and gin.boot_key.pin,
		readyPin = gin and gin.coproc_ready and gin.coproc_ready.pin,
		ledRedPin = (gout and gout.led_red and gout.led_red.enabled ~= false) and gout.led_red.pin or nil,
		ledBluePin = gout and gout.bat_stat_led and gout.bat_stat_led.pin,
	})
end
local function startOptionalService(mod, fn)
	if type(mod) == "table" and mod[fn] then
		mod[fn]()
	end
end
local function startBackgroundServices()
	if _G.MODULE_FLAGS.battery then
		startOptionalService(batAdc, "start")
	end
	if _G.MODULE_FLAGS.charge then
		startOptionalService(usbCharge, "start")
	end
	if _G.MODULE_FLAGS.sntp then
		startOptionalService(time_sync, "startSntp")
	end
	if _G.MODULE_FLAGS.mobile_info then
		startOptionalService(mobile_info, "start")
	end
end
local function initPowerStatus()
	local inserted
	if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
		inserted = usbCharge.isUsbInserted()
	else
		inserted = (gpio and gpio.VBUS and gpio.get(gpio.VBUS) == 1) or false
	end
	if not inserted and not isLowPowerFeatureEnabled() then
		_G.APP_RUNTIME.power_status = 0
		state.flag_usb = false
		sys.publish(E.GPIO_VBUS_CHANGED, 0)
		return
	end
	if not _G.MODULE_FLAGS.pmd_runtime then
		applyUsbInsertState(inserted, "boot")
	else
		_G.APP_RUNTIME.power_status = inserted and 1 or 0
		state.flag_usb = inserted
		sys.publish(E.GPIO_VBUS_CHANGED, _G.APP_RUNTIME.power_status)
	end
end
local function scheduleBootUsbPolicySync()
	local usbCfg = _G.HOST_USB_CFG or {}
	local notify = usbCfg.notify_t3x_usb_state
	if notify == false then
		return
	end
	local delayMs = tonumber(usbCfg.boot_notify_delay_ms)
		or tonumber((_G.TIME_SYNC_CFG or {}).host_boot_wait_ms)
		or 1500
	sys.timerStart(function()
		local inserted = false
		if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
			inserted = usbCharge.isUsbInserted() == true
		else
			inserted = (_G.APP_RUNTIME and _G.APP_RUNTIME.power_status or 0) == 1
		end
		notifyT3xUsbHostIdlePolicy(inserted)
	end, delayMs)
end
local function startHeartbeat()
	sys.timerLoopStart(function()
		if state.heartbeat_paused or _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
			return
		end
		state.heartbeat_count = state.heartbeat_count + 1
		if (state.heartbeat_count % 1) == 0 then
			local rt = _G.APP_RUNTIME or {}
			local usbInserted = (rt.power_status == 1) and 1 or 0
			if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
				usbInserted = usbCharge.isUsbInserted() and 1 or 0
			end
		end
	end, 10000)
end
function start(gpio, net, t3x_ctrl)
	if started then
		appInfo("app_already_started")
		return false
	end
	appInfo("app_start")
	gpioModule, netModule, t3xModule = gpio, net, t3x_ctrl
	_G.device_imei = getImei()
	setupEventHandlers()
	if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
		battery_guard.start({
			on_enter_low_power = onEnterLowPower,
			on_exit_low_power = onExitLowPower,
			on_power_off = function()
				onPowerOff("battery")
			end,
			wake_t3x = function()
				requestT3xWake("battery_usb", nil, nil, { force_wake = true })
			end,
			is_usb_inserted = function()
				if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
					return usbCharge.isUsbInserted()
				end
				return (_G.APP_RUNTIME and _G.APP_RUNTIME.power_status) == 1
			end,
			is_burn_active = function()
				return state.t3x_burn_active or _G.T3X_BURN_MODE_ACTIVE
			end,
		})
	end
	if _G.MODULE_FLAGS.watchdog then setupWatchdog() end
	if _G.MODULE_FLAGS.uart_bridge then setupUartBridge() end
	do
		local evt = E.HOST_UART_FIRST_AT or "APP_HOST_UART_FIRST_AT"
		sys.subscribe(evt, function()
			notifyT3xUsbHostIdlePolicy((_G.APP_RUNTIME.power_status or 0) == 1)
		end)
	end
	initPowerStatus()
	scheduleBootUsbPolicySync()
	if t3xModule then t3xModule.start() end
	if _G.MODULE_FLAGS.sound_prompt ~= false and type(sound_prompt) == "table" then
		sound_prompt.start({ t3x = t3xModule })
		if _G.MODULE_FLAGS.uart_bridge and sound_prompt.onAppStarted then
			sound_prompt.onAppStarted()
		end
	end
	if _G.MODULE_FLAGS.time_sync ~= false and type(time_sync) == "table" then
		time_sync.start({ t3x = t3xModule })
	end
	if _G.MODULE_FLAGS.gpio then setupGpio() end
	if _G.MODULE_FLAGS.pmd_runtime then setupPmd() end
	startBackgroundServices()
	setupRndis()
	if _G.MODULE_FLAGS.mqtt and netModule and netModule.bootstrapNetwork then
		netModule.bootstrapNetwork()
	end
	bootMqtt()
	setupFota()
	startHeartbeat()
	started = true
	appInfo("app_started")
	return true
end
function getState()
	return {
		started = started,
		flag_usb = state.flag_usb,
		mqtt_started = state.mqtt_started,
		low_power_mode = _G.APP_RUNTIME.low_power_mode,
		last_wake_event = state.last_wake_event,
		heartbeat_count = state.heartbeat_count,
	}
end
function setModuleFlag(name, enabled)
	if _G.MODULE_FLAGS[name] ~= nil then
		_G.MODULE_FLAGS[name] = enabled
		return true
	end
	return false
end
function getModuleFlags()
	local flags = {}
	for k, v in pairs(_G.MODULE_FLAGS) do flags[k] = v end
	return flags
end
return _M
