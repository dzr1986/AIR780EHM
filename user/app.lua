-- ================================================================
-- Filename : app.lua
-- Module   : 编排中心：依赖注入、事件订阅、低功耗进/出、USB 边沿、PIR→MQTT 桥、t31x 烧录模式
-- Arch     : doc/modules/APP_EVENT_BUS.md
-- ================================================================

require "sys"
require "sysplus"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local t31xPolicy = require "t31x_policy"
local lpWake = require "lp_wakeup"
local hostEvt = require "host_event"
local t31xNotify = require "t31x_notify"
local deviceId = require "device_id"
local uart_bridge = require "uart_bridge"
local pirCtrl = require "pir_ctrl"
local batteryGuard = require "battery_guard"
local host_uart = require "host_uart"
local ipcSupv = require "ipc_supv"
local t31x_ctrl = require "t31x_ctrl"
local net_tcp = require "net_tcp"
local batAdc = loader.opt("battery", "vbat")
local usbCharge = loader.opt("charge", "usb_charge")
local fota = loader.opt("fota", "fota_svc")
local usbRndis = loader.opt("rndis", "usb_rndis")
local sound_prompt = loader.opt("sound_prompt", "sound_prompt")
local time_sync = loader.opt("time_sync", "time_sync")
local watchdogMod = loader.opt("watchdog", "watchdog")
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local logFuncs = utils.mkLogFns("app_main")
local appInfo = logFuncs.info
local appWarn = logFuncs.warn
local appError = logFuncs.error
local stopWatchdogBeforePowerOff
local E = APP_EVENTS
local started = false
local gpioModule = nil
local netModule = nil
local t31xModule = nil
local state = {
    mqtt_started = false,
    last_wake_event = nil,
    heartbeat_count = 0,
    t31x_burn_active = false,
    heartbeat_paused = false,
    usb_insert_tick = 0,
    pir_watch_sleep_timer = nil,
}

local TIMEOUT = {
    rebootDelay = 500,
    t31xSleepWait = 35000,
    usbExitRestWait = 5000,
    burnPrepWait = 300,
    bootUsbNotifyDefault = 1500,
    pirWatchSleep = 5000,
    pirStopFbDefault = 15000,
    delayedStat = 2000,
    heartbeatMin = 1000,
}

----------------------------------------------------------------
-- 烧录态 / USB 探测
----------------------------------------------------------------
local function setBurnMode(active)
    state.t31x_burn_active = active == true
    t31xPolicy.setBurnActive(active == true)
end

local function isUsbInserted(opts)
    opts = opts or {}
    if opts.bootGpio and not loader.enabled("charge") then
        return gpio and gpio.VBUS and gpio.get(gpio.VBUS) == 1
    end
    return rntmPwr.isUsbInserted()
end

local nowMs = utils.nowMs

local function cancelPwrKeyLongPress()
    if gpioModule then
        gpioModule.cancelLongPress("pwr")
    end
end

local function isLowPowerEnabled()
    return loader.enabled("low_power")
end

local function reqT31xWake(reason, sid, evt, opts)
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    state.last_wake_event = evt
    return t31xPolicy.reqT31xWake(reason, sid, evt, opts)
end

local function onMqttOffline()
    if loader.enabled("t31x_policy") and not t31xPolicy.shdWakeOffline() then
        return
    end
    reqT31xWake("mqtt_offline", 2, 0)
end

----------------------------------------------------------------
-- 低功耗
----------------------------------------------------------------

local function enterLowPower(reason)
    reason = reason or "unknown"
    local userCut = (reason == "mqtt_2002" or reason == "at")
    if userCut then
        rntmPwr.setWorkMode("pir_watch")
    end
    local modeChanged = rntmPwr.setLowPowerMode(true)
    if not userCut and not modeChanged then
        return
    end
    appInfo("enter_low_power", reason)
    rntmPwr.setLastRestReason(reason)
    -- 低功耗已进入的扩展点（当前无订阅者，保留供调试/后续模块挂钩）
    sys.publish(E.POWER_ENTERED_REST)
    local function cutT31x()
        if not t31xModule then
            return
        end
        -- 用户 2002/AT 必须断 T31：全天写盘不得否决。4G 保持 MQTT。
        t31xModule.enterSleep({
            mdmHbrn = lpWake.getModemHibernate() == true,
            skipPendingWorkCheck = userCut,
            reason = reason,
        })
        t31xModule.waitSleepIdle(TIMEOUT.t31xSleepWait)
        if state.mqtt_started and netModule then
            netModule.pubStatus()
        end
    end
    sys.taskInit(cutT31x)
    if modeChanged and state.mqtt_started and netModule then
        netModule.pubRest({ reason = reason, source = "enter" })
    end
    lpWake.onEnterRest()
end

local function notifyUsbIdle(inserted)
    host_uart.pushUsbIdle(inserted == true or inserted == 1)
end

-- 低功耗进/出：setLowPowerMode → t31x_ctrl.enterSleep → MQTT 1002
local function onEnterLowPower(reason)
    reason = reason or "unknown"
    if not isLowPowerEnabled() then
        return
    end
    -- 平台 2002 / AT 明确要进 PIR 值守：不断因 USB 拒绝（USB 仍拦 2004 关机）。
    if reason ~= "mqtt_2002" and reason ~= "at"
        and usbCharge and usbCharge.blocks4gRest() then
        return
    end
    if sound_prompt and sound_prompt.shouldPlay("shutdown_low_power") then
        sys.taskInit(function()
            sound_prompt.playBlocking("off", "shutdown_low_power")
            enterLowPower(reason)
        end)
        return
    end
    enterLowPower(reason)
end

local function onExitLowPower(reason)
    reason = reason or "unknown"
    rntmPwr.setWorkMode("person_detect")
    -- 即使已是非 rest，2002exit 也必须给 T31 正常上电（清 BOOT/OTA，防误进烧录）
    local changed = rntmPwr.setLowPowerMode(false)
    appInfo("exit_low_power", reason, changed and "mode_changed" or "already_awake")
    rntmPwr.setLastRestReason(nil)
    if changed then
        if state.mqtt_started and netModule then
            if reason == "usb_insert" then
                sys.taskInit(function()
                    sys.wait(TIMEOUT.usbExitRestWait)
                    if usbRndis and usbRndis.isRefreshing() then
                        return
                    end
                    local st = netModule.getState()
                    if st and st.connected then
                        netModule.pubRest({ lowPowerMode = "exit", reason = reason })
                    end
                end)
            else
                netModule.pubRest({ lowPowerMode = "exit", reason = reason })
            end
        end
        -- 低功耗已退出的扩展点（当前无订阅者，与 POWER_ENTERED_REST 对称）
        sys.publish(E.POWER_EXITED_REST)
        lpWake.onExitRest()
        if sound_prompt then
            sound_prompt.onWakeFromLowPower()
        end
    end
    sys.taskInit(function()
        local t31x = t31xModule or t31x_ctrl
        if not t31x then
            reqT31xWake("exit_low_power", nil, nil, { forceWake = true })
            return
        end
        local st = t31x.getState()
        if state.t31x_burn_active or (st and st.in_boot_mode) then
            appWarn("exit_low_power_clear_burn")
            t31x.extBootMode()
            setBurnMode(false)
            state.heartbeat_paused = false
            pirCtrl.resume()
        end
        t31x.ensNormalPwrOn("exit_low_power:" .. tostring(reason))
        t31x.pulseMcuInt()
    end)
end

local function onReboot()
    appWarn("device_reboot_request")
    stopWatchdogBeforePowerOff()
    sys.timerStart(function()
        if pm and pm.reboot then pm.reboot() end
    end, TIMEOUT.rebootDelay)
end

local function onPowerOff(reason)
    appWarn("device_poweroff_request", tostring(reason or "unknown"))
    local function shutdownNow()
        if reason == "battery" and batteryGuard.isUsbInserted() then
            return
        end
        stopWatchdogBeforePowerOff()
        pm.shutdown()
    end

    local function runShutdown()
        if sound_prompt then
            sound_prompt.playShutdownThen(reason or "user", shutdownNow)
            return
        end
        shutdownNow()
    end
    if state.mqtt_started and netModule then
        netModule.notifyPowerOff(reason, runShutdown)
        return
    end
    runShutdown()
end

local function setupUart()
    if _G.APP_STACK and _G.APP_STACK.uart ~= "uart_bridge" then
        return false
    end
    local ok = uart_bridge.start({
        onRaw = function(data)
            if loader.enabled("t31x_app") then
                host_uart.onRxRaw(data)
            end
        end,
    })
    if ok then
        if loader.enabled("t31x_app") then
            host_uart.start({
                t31x = t31xModule,
                onEnterLowPower = function() onEnterLowPower("at") end,
                onExitLowPower = function() onExitLowPower("at") end,
                onReboot = onReboot,
                onPowerOff = function()
                    onPowerOff("user")
                end,
                onMqttCfg = function(cfg)
                    if not netModule then
                        return
                    end
                    if netModule.sameMqttCfg(cfg) then
                        return
                    end
                    if not netModule.setMqttCfg(cfg) then
                        return
                    end
                    if state.mqtt_started then
                        netModule.restart()
                    else
                        startMqtt()
                    end
                end,
                onServCreate = function(ch)
                    lpWake.applyTcpChannel(ch)
                end,
                onServClose = function(sid)
                    lpWake.closeTcpChannel(sid)
                end,
            })
        end
    end
    return ok
end

local function onUsbRemovedEnterRest(source)
    if not isLowPowerEnabled() then
        return
    end
    if usbRndis and usbRndis.isEnabled() then
        return
    end
    if loader.enabled("battery_guard") then
        batteryGuard.onUsbRemove()
    elseif not rntmPwr.isLowPowerMode() then
        onEnterLowPower("usb_remove")
    end
end

local function onUsbInsertedExitRest(source)
    if loader.enabled("battery_guard") then
        batteryGuard.onUsbIns({ source = source })
    else
        onExitLowPower("usb_insert")
    end
end

local function applyUsbPower(inserted, source)
    local v = rntmPwr.setPowerStatus(inserted)
    appInfo("usb_state", v, tostring(source or ""))
    sys.publish(E.GPIO_VBUS_CHANGED, v)
    if v == 0 then
        notifyUsbIdle(false)
        onUsbRemovedEnterRest(source)
    else
        state.usb_insert_tick = nowMs()
        cancelPwrKeyLongPress()
        onUsbInsertedExitRest(source)
        notifyUsbIdle(true)
    end
end

local function onPmdMsg(msg)
    if not msg or loader.enabled("charge") then
        return
    end
    if msg.state == 0 or msg.state == 1 then
        applyUsbPower(msg.state == 1, "PMD")
    else
        -- 非插拔态仅同步充电位，避免与 applyUsbPower 重复广播
        local v = rntmPwr.setPowerStatus(msg.charger)
        sys.publish(E.GPIO_VBUS_CHANGED, v)
    end
end

local function setupPmd()
    -- pmd 仅部分内核带；MSG_PMD 存在但 pmd 库缺失时不能裸调 pmd.init
    if rtos and rtos.MSG_PMD and pmd then
        rtos.on(rtos.MSG_PMD, onPmdMsg)
        pmd.init({})
    end
end

local function setupWdt()
    if not loader.enabled("watchdog") then
        return
    end
    if watchdogMod then
        watchdogMod.start(_G.WDT_CFG)
    end
end
stopWatchdogBeforePowerOff = function()
    if watchdogMod then
        watchdogMod.stop()
    end
end

function startMqtt()
    if state.t31x_burn_active then
        appWarn("mqtt_start_skip_burn_mode")
        return false
    end
    if not loader.enabled("mqtt") then
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
    if not loader.enabled("mqtt") or not netModule then
        return
    end
    sys.taskInit(function()
        -- RNDIS open 会 flymode；须等 stable 后再起 MQTT，避免与 IP_LOSE 竞态
        if usbRndis and not usbRndis.isBootStable() then
            usbRndis.waitForNetStable(300000)
        end
        if not utils.localIp() then
            sys.waitUntil("net_ready", 300000)
        end
        deviceId.setImei(deviceId.getDisplayId())
        startMqtt()
    end)
end

local function setupFota()
    if not loader.enabled("fota") or not fota then
        return
    end
    fota.start({
        pubStatus = function(stage, retCode, message, extra)
            if netModule then
                netModule.pubOtaStatus(stage, retCode, message, extra)
            end
        end,
    })
end

local function setupRndis()
    if usbRndis and not usbRndis.isStarted() then
        usbRndis.start()
    end
end

local function getBurnBatteryPercent()
    local pct = rntmPwr.getBatteryPercent()
    if pct and pct >= 0 then
        return pct
    end
    if batAdc then
        pct = tonumber(batAdc.getPercent())
        if pct and pct > 0 then
            return pct
        end
    end
    return nil
end

local function checkBurnAttempt(attemptIndex, attemptTotal)
    local cfg = _G.t31x_BURN_CFG or {}
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBurnBatteryPercent()
    if cfg.require_battery_valid ~= false then
        if not pct then
            failReason = "battery_invalid"
        elseif pct < minPct then
            failReason = "batL"
        end
    end
    if not t31xModule then
        failReason = failReason or "noT3"
    else
        local st = t31xModule.getState() or {}
        if st.in_boot_mode and not allowRepeat then
            failReason = failReason or "boot"
        end
    end
    if failReason then
        return false, failReason
    end
    return true, pct
end

local function checkBurnAllowed()
    local cfg = _G.t31x_BURN_CFG or {}
    local retryCount = math.max(0, tonumber(cfg.burn_check_retry_count) or 2)
    local maxAttempts = 1 + retryCount
    local retryMs = tonumber(cfg.burn_check_retry_interval_ms) or 800
    local lastFailRsn = nil
    local lastPassPct
    for attempt = 1, maxAttempts do
        local ok, detail = checkBurnAttempt(attempt, maxAttempts)
        if ok then
            lastPassPct = detail
            return true, lastPassPct
        end
        lastFailRsn = detail
        if attempt < maxAttempts then
            sys.wait(retryMs)
        end
    end
    return false, lastFailRsn
end

local function shutdownForBurn(cfg)
    cfg = cfg or _G.t31x_BURN_CFG or {}
    appWarn("t31x_burn_prepare")
    setBurnMode(true)
    state.heartbeat_paused = true
    if cfg.suspend_pir ~= false then
        pirCtrl.suspend()
    end
    if cfg.stop_mqtt ~= false and state.mqtt_started and netModule then
        netModule.stop()
        state.mqtt_started = false
        appInfo("t31x_burn_mqtt_stopped")
    end
    if cfg.stop_uart ~= false then
        uart_bridge.stop()
    end
    if cfg.stop_rndis ~= false and usbRndis then
        local rndisOk, rndisErr = usbRndis.disable()
        if rndisOk then
            appInfo("t31x_burn_rndis_disabled")
        else
            appWarn("t31x_burn_rndis_disable_fail", tostring(rndisErr or ""))
        end
    end
    if cfg.turn_off_led ~= false and gpioModule then
        gpioModule.turnOffLed()
    end
    sys.wait(TIMEOUT.burnPrepWait)
    return true
end

local function tryEnterBurnMode()
    local cfg = _G.t31x_BURN_CFG or {}
    local ok, detail = checkBurnAllowed()
    if not ok then
        appWarn("t31x_burn_denied", tostring(detail or "unknown"))
        if gpioModule then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    shutdownForBurn(cfg)
    if not t31xModule then
        appError("t31x_burn_no_t31x_module")
        return false
    end
    if not t31xModule.entBootMode() then
        appError("t31x_burn_enter_bootmode_fail")
        return false
    end
    appWarn("t31x_burn_entered")
    return true
end

local function wakeT31xFor(tag, sid, evt)
    if loader.enabled("battery_guard") then
        batteryGuard.notifyHostIdle()
    end
    if loader.enabled("t31x_wakeup") and loader.enabled("t31x_app") then
        local wakeSid = sid or cfgm.get("HOST_WAKE_CFG").default_sid or 1
        local opts = nil
        if cfgm.get("PIR_CFG").high_priority ~= false then
            opts = { forceWake = true }
        end
        reqT31xWake(tag, wakeSid, evt or 0, opts)
    end
end

local function subscribeAll(handlers)
    for _, item in ipairs(handlers) do
        sys.subscribe(item[1], item[2])
    end
end

----------------------------------------------------------------
-- PIR → MQTT / t31x 桥
----------------------------------------------------------------

local function pubPirEvent(overrides)
    if netModule then
        netModule.pubPirEvent(overrides)
    end
end

local function maybePubWakeup(uploadMode)
    if (uploadMode == "auto" or uploadMode == nil) and not rntmPwr.isLowPowerMode()
        and netModule then
        netModule.pubWakeup()
    end
end

local function schedDelayedStat(delayMs)
    delayMs = tonumber(delayMs) or TIMEOUT.delayedStat
    sys.timerStart(function()
        if rntmPwr.isOnline() and netModule then
            sys.taskInit(function()
                netModule.pubStatus()
            end)
        end
    end, delayMs)
end

local function onPirMediaAction(action, uploadMode, quality)
    if state.t31x_burn_active then
        return
    end
    maybePubWakeup(uploadMode)
    wakeT31xFor("pir_media")
end

local function isT31xRecording()
    return host_uart.getT31xRecActive() == 1
end

local function schedPirSleep(delayMs)
    if not rntmPwr.isPirWatch() then
        return
    end
    if state.pir_watch_sleep_timer then sys.timerStop(state.pir_watch_sleep_timer) end
    state.pir_watch_sleep_timer = sys.timerStart(function()
        state.pir_watch_sleep_timer = nil
        if not rntmPwr.isPirWatch() then
            return
        end
        if isT31xRecording() then
            return
        end
        if t31xModule then
            appInfo("pir_watch_idle_sleep")
            t31xModule.enterSleep({ skipPendingWorkCheck = true, reason = "pir_watch_idle" })
        end
    end, tonumber(delayMs) or TIMEOUT.pirWatchSleep)
end

local function schedMqttStopFb(reason, uploadMode, quality)
    local waitMs = tonumber(cfgm.get("PIR_RECORD_CFG").stop_mqtt_fallback_ms) or TIMEOUT.pirStopFbDefault
    sys.taskInit(function()
        sys.wait(waitMs)
        if not pirCtrl.canStopMqtt() then
            return
        end
        local st = pirCtrl.getState()
        if st.last_stop_reason ~= reason then
            return
        end
        if netModule then
            netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
        end
    end)
end

local function onPirStop(reason, uploadMode, quality)
    local preferT31x = (reason == "timer" or reason == "device" or reason == "manual")
        and isT31xRecording()
    if not preferT31x and netModule then
        netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
    elseif preferT31x then
        schedMqttStopFb(reason, uploadMode, quality)
    end
    wakeT31xFor("pir_stop")
    schedPirSleep(TIMEOUT.pirWatchSleep)
end

local PIR_STOP_TIMER = pirCtrl.APP_PIR_CONFIG.STOP_REASON.TIMER

local function mqttCall(name)
    return function(...)
        if netModule then
            netModule[name](...)
        end
    end
end

local function onPirMedia(action)
    pubPirEvent({ pirStatus = "media_sync", action = action })
end

local function onPirReqStop(reason)
    wakeT31xFor("pir_stop_" .. tostring(reason))
end

local function onPersonCnt()
    -- 有人才走 AT+PERSONCNT；IVS 抖动由 T31 30s 限流。
    -- 人数不上 MQTT 1010，避免后台刷屏。抽片在 T31 本地完成。
end

local function onT31xRecStop(reason, uploadMode, quality)
    if netModule then
        netModule.pubT31xStop(reason, uploadMode, quality)
    end
    schedPirSleep(3000)
end

local function onPirTimer()
    pirCtrl.pubStopRec(PIR_STOP_TIMER)
end

local function onGpioPir(pirStatus, action, uploadMode, quality)
    pubPirEvent({
        pirStatus = pirStatus or "detected",
        action = action,
        uploadMode = uploadMode,
        quality = quality,
    })
end

local function onPwrEnterRest()
    if not isLowPowerEnabled() then
        return
    end
    onEnterLowPower("mqtt_2002")
end

local function onPwrExitRest()
    -- 2002exit：无论当前是否已在 rest，都走退出逻辑给 T31 正常上电
    onExitLowPower("mqtt_2002")
end

local function onPwrOffMqtt()
    onPowerOff("mqtt")
end

local function onPwrKeyLong()
    if state.usb_insert_tick > 0 and isUsbInserted() then
        local elapsed = nowMs() - state.usb_insert_tick
        if elapsed < (tonumber(cfgm.get("HOST_USB_CFG").pwrkey_grace_ms) or 5000) then
            return
        end
    end
    onPowerOff("user")
end

local function onBootKeyLong()
    sys.taskInit(tryEnterBurnMode)
end

local function onCoprocReady()
    if t31xModule then
        t31xModule.extBootMode()
    end
    if state.t31x_burn_active then
        pirCtrl.resume()
        setBurnMode(false)
        state.heartbeat_paused = false
    end
end

local function onUsbDet(inserted)
    applyUsbPower(inserted == 1, "GPIO27")
    if inserted == 1 and state.mqtt_started then
        schedDelayedStat(TIMEOUT.delayedStat)
    end
end

local function onChgState()
    if state.mqtt_started and netModule and rntmPwr.isOnline() then
        sys.taskInit(function()
            netModule.pubStatus()
        end)
    end
end

local function onBatUpd(pct, mv)
    if loader.enabled("battery_guard") then
        batteryGuard.onBatUpd(pct, mv)
    end
end

local function onHostFirstAt()
    notifyUsbIdle(isUsbInserted())
end

----------------------------------------------------------------
-- 事件表 / start
----------------------------------------------------------------

local EVNT_HNDL = {
    { E.POWER_ENTER_REST, onPwrEnterRest },
    { E.POWER_EXIT_REST, onPwrExitRest },
    { E.DEVICE_REBOOT_REQUEST, onReboot },
    { E.DEVICE_POWER_OFF_REQUEST, onPwrOffMqtt },
    { E.GPIO_PWRKEY_LONG, onPwrKeyLong },
    { E.GPIO_BOOTKEY_LONG, onBootKeyLong },
    { E.GPIO_COPROC_READY, onCoprocReady },
    { E.GPIO_USB_DET_CHANGED, onUsbDet },
    { E.GPIO_CHG_STATE_CHANGED, onChgState },
    { E.BATTERY_UPDATE, onBatUpd },
    { E.MQTT_OFFLINE, onMqttOffline },
    { E.HOST_UART_FIRST_AT, onHostFirstAt },
    { E.PIR_WAKE_T31X, onPirMediaAction },
    { E.PIR_MEDIA_EFFECTIVE, onPirMedia },
    { E.PIR_REQUEST_T31X_STOP, onPirReqStop },
    { E.PIR_STOP_RECORDING, onPirStop },
    { E.T31X_SNAPSHOT_DONE, mqttCall("pubSnapDone") },
    { E.T31X_RECORD_ACTIVE, mqttCall("pubRecActive") },
    { E.T31X_PERSON_CNT, onPersonCnt },
    { E.T31X_RECORD_STOP, onT31xRecStop },
    { E.T31X_IPC_ALERT, ipcSupv.pubAlert },
    { E.PIR_TIMER_EXPIRED, onPirTimer },
    { E.GPIO_PIR_TRIGGERED, onGpioPir },
}

local function setupEvents()
    pirCtrl.start()
    subscribeAll(EVNT_HNDL)
end

local function setupGpio()
    if not gpioModule or not loader.enabled("gpio") then return end
    local gin = cfgm.get("GPIO_IN")
    local gout = cfgm.get("GPIO_OUT")
    gpioModule.start({
        pwrkeyPin = gin.pwr_key and gin.pwr_key.pin,
        bootkeyPin = gin.boot_key and gin.boot_key.pin,
        readyPin = gin.coproc_ready and gin.coproc_ready.pin,
        ledRedPin = (gout.led_red and gout.led_red.enabled ~= false and gout.led_red.pin ~= nil)
            and gout.led_red.pin or nil,
        ledBluePin = gout.bat_stat_led and gout.bat_stat_led.pin,
    })
end

local function startBgSvc()
    if loader.enabled("battery") then
        loader.start(batAdc, "start")
    end
    if loader.enabled("charge") then
        loader.start(usbCharge, "start")
        if usbCharge then
            usbCharge.onUsbInsert(cancelPwrKeyLongPress)
        end
    end
    if loader.enabled("sntp") then
        loader.start(time_sync, "startSntp")
    end
end

local function initPower()
    local inserted = isUsbInserted({ bootGpio = true })
    if not inserted and not isLowPowerEnabled() then
        rntmPwr.setPowerStatus(0)
        sys.publish(E.GPIO_VBUS_CHANGED, 0)
        return
    end
    if not loader.enabled("pmd_runtime") then
        applyUsbPower(inserted, "boot")
    else
        local v = rntmPwr.setPowerStatus(inserted)
        sys.publish(E.GPIO_VBUS_CHANGED, v)
    end
end

local function schedBootUsb()
    local usbCfg = cfgm.get("HOST_USB_CFG")
    local notify = usbCfg.notify_t31x_usb_state
    if notify == false then
        return
    end
    local delayMs = tonumber(usbCfg.boot_notify_delay_ms)
        or tonumber(cfgm.get("TIME_SYNC_CFG").hostBootWaitMs)
        or TIMEOUT.bootUsbNotifyDefault
    sys.timerStart(function()
        notifyUsbIdle(isUsbInserted())
    end, delayMs)
end

local function startHeartbeat()
    local intervalMs = tonumber(cfgm.get("APP_META").heartbeat_log_interval_ms) or 60000
    if intervalMs < TIMEOUT.heartbeatMin then
        intervalMs = TIMEOUT.heartbeatMin
    end
    sys.timerLoopStart(function()
        if state.heartbeat_paused or state.t31x_burn_active then
            return
        end
        state.heartbeat_count = state.heartbeat_count + 1
        local usbInserted = isUsbInserted() and 1 or 0
        local mqttCnnc = rntmPwr.isOnline() and 1 or 0
        if netModule then
            local ns = netModule.getState()
            if ns and ns.connected ~= nil then
                mqttCnnc = ns.connected and 1 or 0
            end
        end
        appInfo("heartbeat_status",
            "usb=" .. tostring(usbInserted),
            "power=" .. tostring(rntmPwr.getPowerStatus()),
            "bat_mv=" .. tostring(rntmPwr.getBatteryMv() or "--"),
            "bat_pct=" .. tostring(rntmPwr.getBatteryPercent() or "--"),
            "mqtt=" .. tostring(mqttCnnc),
            "lowpwr=" .. tostring(rntmPwr.isLowPowerMode() and 1 or 0))
    end, intervalMs)
end

function start(gpio, net, t31x_ctrl)
    if started then return true end
    appInfo("app_start")
    gpioModule, netModule, t31xModule = gpio, net, t31x_ctrl
    deviceId.setImei(deviceId.getDisplayId())
    hostEvt.bindMqttPending(function()
        return netModule and netModule.hasHostQueue() == true
    end)
    lpWake.bindNetTcp(net_tcp)
    t31xNotify.registerProviders({
        pushBeforeNotify = function(sid, evt)
            if time_sync then
                time_sync.pushBeforeNotifyAsync(sid, evt)
                return true
            end
            return false
        end,
        ntfHost = function(sid, evt)
            return host_uart.ntfHost(sid, evt)
        end,
        wakeHost = function()
            return t31xModule and t31xModule.wake() ~= false
        end,
        ensPowOn = function(tag, opts)
            return t31xModule and t31xModule.ensPowOn(tag, opts)
        end,
    })
    setupEvents()
    if loader.enabled("battery_guard") then
        batteryGuard.start({
            onEnterLowPower = onEnterLowPower,
            onExitLowPower = onExitLowPower,
            onPowerOff = function()
                onPowerOff("battery")
            end,
            wakeT31x = function()
                reqT31xWake("battery_usb", nil, nil, { forceWake = true })
            end,
            isUsbInserted = function()
                return isUsbInserted()
            end,
            isBurnActive = function()
                return state.t31x_burn_active
            end,
        })
    end
    if loader.enabled("watchdog") then setupWdt() end
    if loader.enabled("uart_bridge") then setupUart() end
    initPower()
    schedBootUsb()
    if t31xModule then t31xModule.start() end
    if sound_prompt then
        sound_prompt.start({ t31x = t31xModule })
        if loader.enabled("uart_bridge") then
            sound_prompt.onAppStarted()
        end
    end
    if time_sync then
        time_sync.start({ t31x = t31xModule })
    end
    if loader.enabled("gpio") then setupGpio() end
    if loader.enabled("pmd_runtime") then setupPmd() end
    startBgSvc()
    setupRndis()
    if netModule then
        netModule.bootstrapNet()
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
        flag_usb = isUsbInserted(),
        mqtt_started = state.mqtt_started,
        low_power_mode = rntmPwr.isLowPowerMode() and 1 or 0,
        last_wake_event = state.last_wake_event,
        heartbeat_count = state.heartbeat_count,
    }
end
return _M
