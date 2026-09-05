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
local pirAppBridge = require "pir_app_bridge"
local batteryGuard = require "battery_guard"
local host_uart = require "host_uart"
local ipcSupv = require "ipc_supv"
local t31x_ctrl = require "t31x_ctrl"
local t31xBurnCtrl = require "t31x_burn_ctrl"
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
    heartbeat_paused = false,
}

local TIMEOUT = {
    rebootDelay = 500,
    t31xSleepWait = 35000,
    usbExitRestWait = 5000,
    delayedStat = 2000,
    heartbeatMin = 1000,
}

----------------------------------------------------------------
-- 低功耗 / USB（USB 边沿策略见 battery_guard.applyUsbPower）
----------------------------------------------------------------

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

-- PSM 副作用表（P6a/E 条）：状态裁决与写入在 runtime_power PSM；requestRest 放行后回调这里，app 只做副作用
local function onRestEntered(reason, modeChanged, userCut)
    appInfo("enter_low_power", reason)
    local function cutT31x()
        if not t31xModule then
            return
        end
        -- 用户 2002/AT 必须断 T31：全天写盘不得否决。4G 保持 MQTT。
        t31xModule.enterSleep({
            modemHibernate = lpWake.getModemHibernate() == true,
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

local function enterLowPower(reason)
    rntmPwr.requestRest(reason or "unknown")
end

-- 低功耗进/出：runtime_power.requestRest/requestNormal（PSM 唯一写点）→ t31x_ctrl.enterSleep → MQTT 1002
local function onEnterLowPower(reason)
    reason = reason or "unknown"
    -- 门禁在 PSM（低功耗开关 / USB 只拦策略触发 / 烧录态）；先预判再播音，避免响了却没进
    local can, why = rntmPwr.canRest(reason)
    if not can then
        appInfo("enter_low_power_skip", reason, tostring(why))
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

-- PSM 副作用表（E 条）：由 runtime_power.requestNormal 每次回调；changed=false 时仍需给 T31 正常上电（清 BOOT/OTA，防误进烧录）
local function onRestExited(reason, changed)
    appInfo("exit_low_power", reason, changed and "mode_changed" or "already_awake")
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
        if t31xBurnCtrl.isActive() or (st and st.in_boot_mode) then
            appWarn("exit_low_power_clear_burn")
            t31x.extBootMode()
            t31xBurnCtrl.setActive(false)
            pirCtrl.resume()
        end
        t31x.ensNormalPwrOn("exit_low_power:" .. tostring(reason))
        t31x.pulseMcuInt()
    end)
end

local function onExitLowPower(reason)
    rntmPwr.requestNormal(reason or "unknown")
end

local function onReboot()
    appWarn("device_reboot_request")
    stopWatchdogBeforePowerOff()
    rntmPwr.requestDeviceReboot(TIMEOUT.rebootDelay)
end

local function onPowerOff(reason)
    appWarn("device_poweroff_request", tostring(reason or "unknown"))
    local function shutdownNow()
        if reason == "battery" and batteryGuard.isUsbInserted() then
            return
        end
        stopWatchdogBeforePowerOff()
        rntmPwr.requestDeviceShutdown()
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

-- AT 协议层业务 provider（host_uart.start{ biz }；键名即 bizCall("<键>") 的唯一真源，_ref_name_check 规则 F 校验）。
-- 模块被裁剪/未加载时该键为 nil，bizCall 返回 nil，与旧 modCall 语义一致。
local function bizProvider(mod, fn)
    if mod and type(mod[fn]) == "function" then
        return function(...) return mod[fn](...) end
    end
    return nil
end

local function buildBizProviders()
    local function viaNet(fn)
        return function(...)
            if netModule and netModule[fn] then return netModule[fn](...) end
        end
    end
    return {
        -- battery_guard
        shouldHostSleep = bizProvider(batteryGuard, "shouldHostSleep"),
        canHostSleep = bizProvider(batteryGuard, "canHostSleep"),
        markT31xWoken = bizProvider(batteryGuard, "markT31xWoken"),
        -- t31x_policy
        mayPowerT31x = bizProvider(t31xPolicy, "mayPowerT31x"),
        -- lp_wakeup
        lpAppCfgFields = bizProvider(lpWake, "appCfgFields"),
        allowTcpChannel = bizProvider(lpWake, "allowTcpChannel"),
        closeTcpChannel = bizProvider(lpWake, "closeTcpChannel"),
        -- host_event
        hostEvtEnabled = bizProvider(hostEvt, "isEnabled"),
        hostEvtSummarize = bizProvider(hostEvt, "summarize"),
        -- pir_ctrl
        pirIsRecording = bizProvider(pirCtrl, "isRecording"),
        pirSyncStopT31x = bizProvider(pirCtrl, "syncStopT31x"),
        pirApplyEffMedia = bizProvider(pirCtrl, "applyEffMedia"),
        pirStatSnapshot = bizProvider(pirCtrl, "getStatSnapshot"),
        pirClearMarkers = bizProvider(pirCtrl, "clearConsumableMarkers"),
        pirResetCounters = bizProvider(pirCtrl, "resetCounters"),
        -- time_sync / sound_prompt（可选模块）
        onTimesetAck = bizProvider(time_sync, "onTimesetAck"),
        onSoundAck = bizProvider(sound_prompt, "onSoundAck"),
        -- net_mqtt（注入对象，start 时才有）
        pubUploadDone = viaNet("pubUploadDone"),
        pubUploadNeed = viaNet("pubUploadNeed"),
        setStatInterval = viaNet("setStatInterval"),
        pubRaw = viaNet("pubRaw"),
        pubDeviceIdRef = viaNet("pubDeviceIdRef"),
    }
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
                biz = buildBizProviders(),
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

local function setupPmd()
    -- pmd 仅部分内核带；MSG_PMD 存在但 pmd 库缺失时不能裸调 pmd.init
    rntmPwr.initPmd(batteryGuard.onPmdMessage)
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
    if t31xBurnCtrl.isActive() then
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
            usbRndis.waitForNetStable(tonumber(cfgm.get("MQTT_CFG").boot_net_wait_ms) or 300000)
        end
        if not utils.localIp() then
            sys.waitUntil("net_ready", tonumber(cfgm.get("MQTT_CFG").boot_net_wait_ms) or 300000)
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
-- 事件 handler（PIR 桥见 pir_app_bridge）
----------------------------------------------------------------

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

local function mqttCall(name)
    return function(...)
        if netModule then
            netModule[name](...)
        end
    end
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
    if batteryGuard.shouldBlockPwrKeyLong() then
        return
    end
    onPowerOff("user")
end

local function onBootKeyLong()
    if t31xBurnCtrl.shouldBlockBootKeyLong() then
        appInfo("bootkey_long_ignored", "t31x_poweron_grace")
        return
    end
    sys.taskInit(t31xBurnCtrl.tryEnter)
end

local function onCoprocReady()
    t31xBurnCtrl.onCoprocReady()
end

local function onUsbDet(inserted)
    batteryGuard.onGpioUsbDetChanged(inserted)
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
    batteryGuard.onHostFirstAtSyncUsb()
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
    { E.PIR_WAKE_T31X, pirAppBridge.onPirMediaAction },
    { E.PIR_MEDIA_EFFECTIVE, pirAppBridge.onPirMedia },
    { E.PIR_REQUEST_T31X_STOP, pirAppBridge.onPirReqStop },
    { E.PIR_STOP_RECORDING, pirAppBridge.onPirStop },
    { E.T31X_SNAPSHOT_DONE, mqttCall("pubSnapDone") },
    { E.T31X_RECORD_ACTIVE, mqttCall("pubRecActive") },
    { E.T31X_PERSON_CNT, pirAppBridge.onPersonCnt },
    { E.T31X_RECORD_STOP, pirAppBridge.onT31xRecStop },
    { E.T31X_IPC_ALERT, ipcSupv.pubAlert },
    { E.PIR_TIMER_EXPIRED, pirAppBridge.onPirTimer },
    { E.GPIO_PIR_TRIGGERED, pirAppBridge.onGpioPir },
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
            usbCharge.onUsbInsert(batteryGuard.cancelPwrKeyLongPress)
        end
    end
    if loader.enabled("sntp") then
        loader.start(time_sync, "startSntp")
    end
end

local function startHeartbeat()
    local intervalMs = tonumber(cfgm.get("APP_META").heartbeat_log_interval_ms) or 60000
    if intervalMs < TIMEOUT.heartbeatMin then
        intervalMs = TIMEOUT.heartbeatMin
    end
    sys.timerLoopStart(function()
        if state.heartbeat_paused or t31xBurnCtrl.isActive() then
            return
        end
        state.heartbeat_count = state.heartbeat_count + 1
        local usbInserted = batteryGuard.probeUsbInserted() and 1 or 0
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
    t31xBurnCtrl.bind({
        getT31x = function() return t31xModule end,
        getNet = function() return netModule end,
        getGpio = function() return gpioModule end,
        getBatAdc = function() return batAdc end,
        getUsbRndis = function() return usbRndis end,
        isMqttStarted = function() return state.mqtt_started end,
        setMqttStarted = function(v) state.mqtt_started = v == true end,
        setHeartbeatPaused = function(v) state.heartbeat_paused = v == true end,
    })
    pirAppBridge.bind({
        getNet = function() return netModule end,
        getT31x = function() return t31xModule end,
        wakeT31x = wakeT31xFor,
    })
    batteryGuard.start({
        onEnterLowPower = onEnterLowPower,
        onExitLowPower = onExitLowPower,
        onPowerOff = function()
            onPowerOff("battery")
        end,
        wakeT31x = function()
            reqT31xWake("battery_usb", nil, nil, { forceWake = true })
        end,
        isBurnActive = t31xBurnCtrl.isActive,
        getGpio = function() return gpioModule end,
        getUsbRndis = function() return usbRndis end,
        isLowPowerEnabled = isLowPowerEnabled,
    })
    deviceId.setImei(deviceId.getDisplayId())
    hostEvt.bindMqttPending(function()
        return netModule and netModule.hasHostQueue() == true
    end)
    lpWake.bindNetTcp(net_tcp)
    -- PSM 门禁注入（P6a）：低功耗总开关 + USB 只拦策略触发（2002/AT 用户要求不拦）；烧录态不在此拦（与 155 前行为一致）
    rntmPwr.bindPowerGates({
        enabled = isLowPowerEnabled,
        usbBlocks = function()
            return usbCharge ~= nil and usbCharge.blocks4gRest() == true
        end,
    })
    -- PSM 副作用表（E 条）：进/出 rest 的 T31 断电/上电、MQTT 1002、lp_wakeup、提示音全部挂在 PSM 内触发
    rntmPwr.bindPowerHooks({
        onEnterRest = onRestEntered,
        onExitRest = onRestExited,
    })
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
    if loader.enabled("watchdog") then setupWdt() end
    if loader.enabled("uart_bridge") then setupUart() end
    batteryGuard.initBootPower()
    batteryGuard.schedBootUsbNotify()
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
        flag_usb = batteryGuard.probeUsbInserted(),
        mqtt_started = state.mqtt_started,
        low_power_mode = rntmPwr.isLowPowerMode() and 1 or 0,
        last_wake_event = state.last_wake_event,
        heartbeat_count = state.heartbeat_count,
    }
end
return _M
