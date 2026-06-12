require "sys"
require "sysplus"
require "config"
local L = "app"
local function flagOn(flag)
    local flags = _G.MODULE_FLAGS
    return not (flags and flags[flag] == false)
end
local function optMod(flag, name)
    if not flagOn(flag) then
        return nil
    end
    local ok, m = pcall(require, name)
    if not ok or type(m) ~= "table" then
        log.warn(L, "rqF", name, ok and "nil" or tostring(m))
        return nil
    end
    return m
end
local uart_bridge = require "uart_bridge"
local pir_ctrl = require "pir_ctrl"
local battery_guard = require "battery_guard"
local host_uart = require "host_uart"
local batAdc = flagOn("battery") and require "vbat" or nil
local usbCharge = optMod("charge", "usb_charge")
local mobile_info = optMod("mobile_info", "mobile_info")
local fota = flagOn("fota") and require "fota_svc" or nil
local usbRndis = optMod("rndis", "usb_rndis")
local sound_prompt = flagOn("sound_prompt") and require "sound_prompt" or nil
local time_sync = flagOn("time_sync") and require "time_sync" or nil
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local E = APP_EVENTS
local started = false
local wakeValue = ""
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
local USB_PWRKEY_GRACE_MS = 5000
local modCache = {}
local function lazyMod(name)
    local cached = modCache[name]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
        modCache[name] = mod
        return mod
    end
    modCache[name] = false
    return nil
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
    wakeValue = string.format("%d,%d", sid, evt)
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
            log.info(L, "msk", policy.getDenyReason and policy.getDenyReason() or "")
            return
        end
    end
    requestT3xWake("mqtt_offline", 2, 0)
end
local function doEnterLowPowerBody(reason)
    reason = reason or "unknown"
    if not setLowPowerMode(true) then return end
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
local function usbInsertedFromCharge()
    if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
        return usbCharge.isUsbInserted()
    end
    return nil
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
    _G.APP_RUNTIME.last_rest_reason = nil
    if state.mqtt_started and netModule and netModule.publishRest then
        netModule.publishRest({ lowPowerMode = "exit", reason = reason })
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
    if _G.MODULE_FLAGS.time_sync ~= false and type(time_sync) == "table"
        and time_sync.onT3xWake then
        time_sync.onT3xWake()
    end
end
local function onReboot()
    sys.timerStart(function()
    if pm and pm.reboot then pm.reboot() end
    end, 500)
end
local function onPowerOff(reason)
    local function shutdownNow()
        pm.shutdown()
    end
    if _G.MODULE_FLAGS.sound_prompt ~= false and type(sound_prompt) == "table"
        and sound_prompt.playShutdownThen then
        sound_prompt.playShutdownThen(reason or "user", shutdownNow)
        return
    end
    shutdownNow()
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
        if _G.APP_RUNTIME.low_power_mode == 0 then
            onEnterLowPower("usb_remove")
        end
    elseif _G.APP_RUNTIME.low_power_mode == 0 then
        onEnterLowPower("usb_remove")
    end
end
local function exitRestIfNeededAfterUsbInsert()
    if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
        battery_guard.onUsbInserted()
    else
        onExitLowPower("usb_insert")
    end
end
local function applyUsbInsertState(inserted, source)
    local v = inserted and 1 or 0
    state.last_usb_state = v
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
        exitRestIfNeededAfterUsbInsert()
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
    local wdtMod = _G.watchdog
    if wdtMod and wdtMod.start then
        wdtMod.start(_G.WDT_CFG)
    end
end
local function getImei()
    local did = deviceIdMod()
    if type(did) == "table" and did.getDisplayId then
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
local function logImeiBanner()
    local imei = getImei()
    _G.device_imei = imei
end
function startMqtt()
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        return false
    end
    if state.mqtt_started then
        return false
    end
    if not _G.MODULE_FLAGS.mqtt then
        return false
    end
    if not netModule or not (_G.APP_STACK and _G.APP_STACK.mqtt == "net_mqtt") then
        return false
    end
    state.mqtt_started = true
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
        logImeiBanner()
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
    sys.taskInit(function()
        sys.wait(3000)
        if type(usbRndis.getStatus) == "function" then
            local st = usbRndis.getStatus()
            log.info(L, "rnd",
                "enabled", st.enabled and 1 or 0,
                "mode", st.usb_ethernet_mode or "--",
                "ip", st.ip or "--",
                "cell_ip", st.cell_ip or "--")
        end
    end)
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
local function burnDebugEnabled()
    return (_G.T3X_BURN_CFG or {}).debug_checks == true
end
local function checkT3xBurnPreconditionsOnce(attemptIndex, attemptTotal)
    local cfg = _G.T3X_BURN_CFG or {}
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBatteryPercentForBurn()
    if cfg.require_battery_valid ~= false then
        if not pct then
            failReason = "bat?"
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
    _G.T3X_BURN_MODE_ACTIVE = true
    state.t3x_burn_active = true
    state.heartbeat_paused = true
    if cfg.suspend_pir ~= false and pir_ctrl.suspend then
        pir_ctrl.suspend()
    end
    if cfg.stop_mqtt ~= false and state.mqtt_started and netModule and netModule.stop then
        netModule.stop()
        state.mqtt_started = false
    end
    if cfg.stop_uart ~= false then
        local ub = _G.uart_bridge or uart_bridge
        if ub and ub.stop then
            ub.stop()
        end
    end
    if cfg.stop_rndis ~= false and _G.MODULE_FLAGS.rndis then
        if type(usbRndis) == "table" and usbRndis.disable then
            usbRndis.disable()
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
        if gpioModule and gpioModule.runLedPattern then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    shutdownServicesForT3xBurn(cfg)
    if not t3xModule or not t3xModule.enterBootMode then
        return false
    end
    if not t3xModule.enterBootMode() then
        return false
    end
    return true
end
local function wakeT3xForPir(tag, sid, evt)
    if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
        local wakeSid = sid or ((_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1)
        requestT3xWake(tag, wakeSid, evt or 0)
    end
end
local function onPirMediaAction(action, uploadMode, quality)
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        return
    end
    local inRest = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.low_power_mode) == 1
    if (uploadMode == "auto" or uploadMode == nil) and not inRest
        and netModule and netModule.publishWakeup then
        netModule.publishWakeup()
    elseif inRest and (uploadMode == "auto" or uploadMode == nil) then
    end
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
local function subscribeAll(handlers)
    for _, item in ipairs(handlers) do
        local ev, cb = item[1], item[2]
        if ev and type(cb) == "function" then
            sys.subscribe(ev, cb)
        else
            log.warn(L, "skip_sub", tostring(ev), type(cb))
        end
    end
end
local function subscribePirMqttBridge()
    local function pirPub(overrides)
        if netModule and netModule.publishPirEvent then
            netModule.publishPirEvent(overrides)
        elseif netModule and netModule.publishPirDetect then
            netModule.publishPirDetect(overrides)
        end
    end
    local handlers = {
        { E.PIR_WAKE_T3X, function(action, uploadMode, quality)
            onPirMediaAction(action, uploadMode, quality)
        end },
        { E.PIR_MEDIA_EFFECTIVE, function(action)
            pirPub({ pirStatus = "media_sync", action = action })
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
            pirPub({ pirStatus = "person_update", personCount = tonumber(count) or 0 })
        end },
        { E.T3X_RECORD_STOP, function(reason, uploadMode, quality)
            if netModule and netModule.publishT3xRecordStop then
                netModule.publishT3xRecordStop(reason, uploadMode, quality)
            end
        end },
        { E.PIR_TIMER_EXPIRED, function()
            local stopTimer = (_G.APP_PIR_CONFIG and _G.APP_PIR_CONFIG.STOP_REASON
                and _G.APP_PIR_CONFIG.STOP_REASON.TIMER) or "timer"
            pir_ctrl.publishStopRecording(stopTimer)
        end },
        { E.GPIO_PIR_TRIGGERED, function(pirStatus, action, uploadMode, quality)
            pirPub({
                pirStatus = pirStatus or "detected",
                action = action,
                uploadMode = uploadMode,
                quality = quality,
            })
        end },
    }
    subscribeAll(handlers)
end
local function setupEventHandlers()
    pir_ctrl.start()
    subscribeAll({
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
            if state.usb_insert_tick > 0 then
                local elapsed = nowMs() - state.usb_insert_tick
                if _G.APP_RUNTIME.power_status == 1 and elapsed < USB_PWRKEY_GRACE_MS then
                    return
                end
            end
            onPowerOff("user")
        end },
        { E.GPIO_BOOTKEY_LONG, function()
            sys.taskInit(tryEnterT3xBurnMode)
        end },
        { E.GPIO_COPROC_READY, function()
            if t3xModule then t3xModule.exitBootMode() end
            if pir_ctrl.resume and state.t3x_burn_active then
                pir_ctrl.resume()
                _G.T3X_BURN_MODE_ACTIVE = false
                state.t3x_burn_active = false
                state.heartbeat_paused = false
            end
        end },
        { E.GPIO_USB_DET_CHANGED, function(inserted)
            applyUsbInsertState(inserted == 1, "GPIO27")
            if inserted == 1 and _G.MODULE_FLAGS.rndis and not state.t3x_burn_active
                and type(usbRndis) == "table" and usbRndis.enableAsync then
                usbRndis.enableAsync()
            end
            if inserted == 1 and state.mqtt_started and netModule and netModule.publishStatus then
                sys.timerStart(function()
                    if _G.APP_RUNTIME.online_status == 1 then
                        netModule.publishStatus()
                    end
                end, 2000)
            end
        end },
        { E.GPIO_CHG_STATE_CHANGED, function(charging)
            if state.mqtt_started and netModule and netModule.publishStatus and _G.APP_RUNTIME.online_status == 1 then
                netModule.publishStatus()
            end
        end },
        { "BATTERY_UPDATE", function(pct, mv)
            if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
                battery_guard.onBatteryUpdate(pct, mv)
            end
        end },
        { E.MQTT_OFFLINE, onMqttOffline },
    })
    subscribePirMqttBridge()
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
local function startBackgroundServices()
    if _G.MODULE_FLAGS.battery then
        if type(batAdc) == "table" and batAdc.start then
            batAdc.start()
        end
    end
    if _G.MODULE_FLAGS.charge then
        if type(usbCharge) == "table" and usbCharge.start then
            usbCharge.start()
        end
    end
    if _G.MODULE_FLAGS.sntp then
        if type(time_sync) == "table" and time_sync.startSntp then
            time_sync.startSntp()
        end
    end
    if _G.MODULE_FLAGS.mobile_info then
        if type(mobile_info) == "table" and mobile_info.start then
            mobile_info.start()
        end
    end
end
local function initPowerStatus()
    local inserted = usbInsertedFromCharge()
    if inserted == nil then
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
        local inserted = usbInsertedFromCharge()
        inserted = inserted == nil and ((_G.APP_RUNTIME and _G.APP_RUNTIME.power_status or 0) == 1)
            or inserted == true
        notifyT3xUsbHostIdlePolicy(inserted)
    end, delayMs)
end
local function startHeartbeat()
    sys.timerLoopStart(function()
        if state.heartbeat_paused or _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
            return
        end
        state.heartbeat_count = state.heartbeat_count + 1
        local mqttHint = "mqtt-off"
        if state.mqtt_started then
            if _G.APP_RUNTIME.online_status == 1 then
                mqttHint = "mqtt-ok"
            else
                local ip = (socket and socket.localIP and socket.localIP()) or "noip"
                local csq = (mobile and mobile.csq and mobile.csq()) or "?"
                mqttHint = string.format("mqtt-up ip=%s csq=%s", ip, csq)
            end
        end
        local batPct = _G.APP_RUNTIME.battery_percent
        local batMv = _G.APP_RUNTIME.battery_mv
        if (batPct == nil or batPct == "--") and type(batAdc) == "table" and batAdc.getPercent then
            local p, mv = batAdc.getPercent(), batAdc.getVoltage and batAdc.getVoltage()
            if p and p > 0 then batPct = p end
            if (batMv == nil or batMv == "--") and mv and mv > 0 then batMv = mv end
        end
        local batPctNum = tonumber(batPct)
        local batMvNum = tonumber(batMv)
        local batHint
        if batPct ~= nil and batPct ~= "--" and batPctNum ~= nil then
            batHint = string.format("%d%%", batPctNum)
            if batMv ~= nil and batMv ~= "--" and batMvNum ~= nil and batMvNum > 0 then
                batHint = batHint .. string.format(" %dmV", batMvNum)
            end
        elseif batMv ~= nil and batMv ~= "--" and batMvNum ~= nil and batMvNum > 0 then
            batHint = string.format("%dmV", batMvNum)
        else
            batHint = "--"
        end
        log.info(L, string.format("a%d u%d lp%d b%s m%s",
            state.heartbeat_count, _G.APP_RUNTIME.power_status or 0, _G.APP_RUNTIME.low_power_mode or 0, batHint, mqttHint))
    end, 10000)
end
function start(gpio, net, t3x_ctrl)
    if started then
        return false
    end
    gpioModule, netModule, t3xModule = gpio, net, t3x_ctrl
    log.info(L, "stk", json.encode(_G.APP_STACK or {}))
    logImeiBanner()
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
                local inserted = usbInsertedFromCharge()
                if inserted ~= nil then
                    return inserted
                end
                return (_G.APP_RUNTIME and _G.APP_RUNTIME.power_status or 0) == 1
            end,
            is_burn_active = function()
                return state.t3x_burn_active or _G.T3X_BURN_MODE_ACTIVE
            end,
        })
    end
    if _G.MODULE_FLAGS.watchdog then setupWatchdog() end
    if _G.MODULE_FLAGS.uart_bridge then setupUartBridge() end
    do
        local evt = E.HOST_UART_FIRST_AT or "host_uart_first_at"
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
