-- ================================================================
-- Filename : app.lua
-- Module   : 编排中心：依赖注入、事件订阅、低功耗进/出、USB 边沿、PIR→MQTT 桥、T3x 烧录模式
-- Arch     : doc/modules/APP_EVENT_BUS.md
-- ================================================================

require "sys"
require "sysplus"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local uart_bridge = require "uart_bridge"
local pir_ctrl = require "pir_ctrl"
local bttrGrd = require "battery_guard"
local host_uart = require "host_uart"
local ipcSprv = require "ipc_supervision"
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
local logFuncs = utils.crtLogFns("app_main")
local appInfo = logFuncs.info
local appWarn = logFuncs.warn
local appError = logFuncs.error
local stopWatchdogBeforePowerOff
local E = APP_EVENTS
local rt = _G.APP_RUNTIME or {}
local started = false
local gpioModule = nil
local netModule = nil
local t3xModule = nil
local state = {
    mqtt_started = false,
    last_wake_event = nil,
    heartbeat_count = 0,
    t3x_burn_active = false,
    heartbeat_paused = false,
    usb_insert_tick = 0,
    pir_watch_sleep_timer = nil,
}
local function lazyMod(name)
    return loader.load(name)
end

local function t3xPolicyMod()
    return lazyMod("t3x_policy")
end

local function lowPwrWake()
    return lazyMod("low_power_wakeup")
end

local function rtPwrMod()
    return lazyMod("runtime_power")
end

local function isUsbInsr(opts)
    opts = opts or {}
    if opts.boot_gpio and not loader.enabled("charge") then
        return (gpio and gpio.VBUS and gpio.get(gpio.VBUS) == 1) or false
    end
    if type(usbCharge) == "table" and usbCharge.isUsbInserted then
        return usbCharge.isUsbInserted() == true
    end
    -- charge 模块关闭时经 runtime_power 兜底（内部直查 usb_charge/全局状态）
    local rp = rtPwrMod()
    if rp and rp.isUsbInserted then
        return rp.isUsbInserted()
    end
    return (_G.APP_RUNTIME and _G.APP_RUNTIME.power_status or 0) == 1
end

local nowMs = utils.nowMs

local function cnclPwrKey()
    if gpioModule and gpioModule.cancelLongPress then
        gpioModule.cancelLongPress("pwr")
    end
end

local function setLowPwr(enabled)
    local v = enabled and 1 or 0
    local rt = _G.APP_RUNTIME
    if rt.low_power_mode == v then
        return false
    end
    rt.low_power_mode = v
    return true
end

local function isLowPwrOn()
    local fc = _G.FEATURE_CFG
    if fc and fc.low_power == false then
        return false
    end
    local lp = _G.LOW_POWER_CFG
    if lp and lp.enabled == false then
        return false
    end
    if not loader.enabled("low_power") then
        return false
    end
    return true
end

local function reqT3xWake(reason, sid, evt, opts)
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    state.last_wake_event = evt
    -- flag/enabled 门禁统一在 t3x_policy.policyDisabled 内判定（关闭时放行）
    local policy = t3xPolicyMod()
    if type(policy) == "table" and policy.reqT3xWake then
        return policy.reqT3xWake(reason, sid, evt, opts)
    end
    local tn = lazyMod("t3x_notify")
    if tn and tn.wakeHost then
        return tn.wakeHost(sid, evt)
    end
    return false
end

local function onMqttOffl()
    -- policy flag 关闭时跳过门禁直接唤醒（reqT3xWake 内 policyDisabled 放行）
    if loader.enabled("t3x_policy") then
        local policy = t3xPolicyMod()
        if type(policy) == "table" and policy.shdWakeOffline
            and not policy.shdWakeOffline() then
            return
        end
    end
    reqT3xWake("mqtt_offline", 2, 0)
end

local function doEntrLow(reason)
    reason = reason or "unknown"
    local userCut = (reason == "mqtt_2002" or reason == "at")
    if userCut then
        local rp = rtPwrMod()
        if rp and rp.setWorkMode then
            rp.setWorkMode("pir_watch")
        end
    end
    local modeChanged = setLowPwr(true)
    if not userCut and not modeChanged then
        return
    end
    appInfo("enter_low_power", reason)
    _G.APP_RUNTIME.last_rest_reason = reason
    sys.publish(E.POWER_ENTERED_REST)
    local function cutT3x()
        if not (t3xModule and t3xModule.enterSleep) then
            return
        end
        local mdmHbrn
        local lpw = lowPwrWake()
        if lpw and lpw.getModemHibernate then
            mdmHbrn = lpw.getModemHibernate() == true
        else
            local lp = _G.LOW_POWER_CFG or {}
            mdmHbrn = lp.modem_hibernate == true
        end
        -- 用户 2002/AT 必须断 T31：全天写盘不得否决。4G 保持 MQTT。
        t3xModule.enterSleep({
            mdmHbrn = mdmHbrn,
            skip_pending_work_check = userCut,
            reason = reason,
        })
        if t3xModule.waitSleepIdle then
            t3xModule.waitSleepIdle(35000)
        end
        if state.mqtt_started and netModule and netModule.publishStatus then
            netModule.publishStatus()
        end
    end
    sys.taskInit(cutT3x)
    if modeChanged and state.mqtt_started and netModule and netModule.publishRest then
        netModule.publishRest({ reason = reason, source = "enter" })
    end
    local lpw = lowPwrWake()
    if lpw and lpw.onEnterRest then
        lpw.onEnterRest()
    end
end

local function notifT3xIdle(inserted)
    if not host_uart or not host_uart.pushUsbIdleSt then
        return
    end
    host_uart.pushUsbIdleSt(inserted == true or inserted == 1)
end

-- ===== 低功耗进/出：setLowPowerMode → t3x_ctrl.enterSleep → MQTT 1002 ===== )
local function onEntLowPwr(reason)
    reason = reason or "unknown"
    if not isLowPwrOn() then
        return
    end
    -- 平台 2002 / AT 明确要进 PIR 值守：不断因 USB 拒绝（USB 仍拦 2004 关机）。
    if reason ~= "mqtt_2002" and reason ~= "at" then
        if type(usbCharge) == "table" and usbCharge.blocks4gRest and usbCharge.blocks4gRest() then
            return
        end
    end
    if type(sound_prompt) == "table" and sound_prompt.shouldPlay
        and sound_prompt.shouldPlay("shutdown_low_power") then
        sys.taskInit(function()
            if sound_prompt.playBlocking then
                sound_prompt.playBlocking("off", "shutdown_low_power")
            end
            doEntrLow(reason)
        end)
        return
    end
    doEntrLow(reason)
end

local function onExtLowPwr(reason)
    reason = reason or "unknown"
    local rp = rtPwrMod()
    if rp and rp.setWorkMode then
        rp.setWorkMode("person_detect")
    end
    -- 即使已是非 rest，2002exit 也必须给 T31 正常上电（清 BOOT/OTA，防误进烧录）
    local changed = setLowPwr(false)
    appInfo("exit_low_power", reason, changed and "mode_changed" or "already_awake")
    _G.APP_RUNTIME.last_rest_reason = nil
    if changed then
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
                    end
                end)
            else
                netModule.publishRest({ lowPowerMode = "exit", reason = reason })
            end
        end
        sys.publish(E.POWER_EXITED_REST)
        local lpw = lowPwrWake()
        if lpw and lpw.onExitRest then
            lpw.onExitRest()
        end
        if loader.enabled("sound_prompt") and type(sound_prompt) == "table"
            and sound_prompt.onWakeFromLowPower then
            sound_prompt.onWakeFromLowPower()
        end
    end
    sys.taskInit(function()
        local t3x = t3xModule
        if type(t3x) ~= "table" then
            t3x = lazyMod("t3x_ctrl")
        end
        -- 若卡在烧录态：退脚位并恢复业务标志
        local st = t3x and t3x.getState and t3x.getState() or nil
        if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active
            or (st and st.in_boot_mode) then
            appWarn("exit_low_power_clear_burn")
            if t3x and t3x.extBootMode then
                pcall(t3x.extBootMode)
            end
            _G.T3X_BURN_MODE_ACTIVE = false
            state.t3x_burn_active = false
            state.heartbeat_paused = false
            if pir_ctrl and pir_ctrl.resume then
                pcall(pir_ctrl.resume)
            end
        end
        if t3x and t3x.ensureNormalPowerOn then
            t3x.ensureNormalPowerOn("exit_low_power:" .. tostring(reason))
            if t3x.pulseMcuInt then
                t3x.pulseMcuInt()
            end
        else
            reqT3xWake("exit_low_power", nil, nil, { force_wake = true })
        end
    end)
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
            local bg = loader.load("battery_guard")
            if bg and bg.isUsbInserted and bg.isUsbInserted() then
                return
            end
        end
        stopWatchdogBeforePowerOff()
        pm.shutdown()
    end

    local function prcdShtd()
        if loader.enabled("sound_prompt") and type(sound_prompt) == "table"
            and sound_prompt.playShutdownThen then
            sound_prompt.playShutdownThen(reason or "user", shutdownNow)
            return
        end
        shutdownNow()
    end
    if state.mqtt_started and netModule and netModule.notifyPowerOff then
        netModule.notifyPowerOff(reason, prcdShtd)
        return
    end
    prcdShtd()
end

local function stpUartBrdg()
    if _G.APP_STACK and _G.APP_STACK.uart ~= "uart_bridge" then
        return false
    end
    local ok = uart_bridge.start({
        onRaw = function(data)
            if loader.enabled("t3x_app") then
                host_uart.on_rx_raw(data)
            end
        end,
    })
    if ok then
        _G.uart_bridge = uart_bridge
        if loader.enabled("t3x_app") then
            host_uart.start({
                t3x = t3xModule,
                on_enter_low_power = function() onEntLowPwr("at") end,
                on_exit_low_power = function() onExtLowPwr("at") end,
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
                    else
                        startMqtt()
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
            })
        end
    end
    return ok
end

local function entRestIf(source)
    if not isLowPwrOn() then
        return
    end
    local rndisOn = loader.enabled("rndis")
        and type(usbRndis) == "table"
        and usbRndis.isEnabled
        and usbRndis.isEnabled()
    if rndisOn then
        return
    end
    if loader.enabled("battery_guard") and type(bttrGrd) == "table" then
        bttrGrd.onUsbRm()
    elseif _G.APP_RUNTIME.low_power_mode == 0 then
        onEntLowPwr("usb_remove")
    end
end

local function extRestIf(source)
    if loader.enabled("battery_guard") and type(bttrGrd) == "table" then
        bttrGrd.onUsbIns({ source = source })
    else
        onExtLowPwr("usb_insert")
    end
end

local function aplUsbInsSt(inserted, source)
    local v = inserted and 1 or 0
    appInfo("usb_state", v, tostring(source or ""))
    _G.APP_RUNTIME.power_status = v
    sys.publish(E.GPIO_VBUS_CHANGED, v)
    if v == 0 then
        notifT3xIdle(false)
        entRestIf(source)
    else
        state.usb_insert_tick = nowMs()
        cnclPwrKey()
        extRestIf(source)
        notifT3xIdle(true)
    end
end

local function hndlPmdMssg(msg)
    if not msg or loader.enabled("charge") then
        return
    end
    if msg.state == 0 or msg.state == 1 then
        aplUsbInsSt(msg.state == 1, "PMD")
    else
        -- 非插拔态仅同步充电位，避免与 aplUsbInsSt 重复广播
        _G.APP_RUNTIME.power_status = msg.charger and 1 or 0
        sys.publish(E.GPIO_VBUS_CHANGED, _G.APP_RUNTIME.power_status)
    end
end

local function setupPmd()
    if rtos and rtos.MSG_PMD then
        rtos.on(rtos.MSG_PMD, hndlPmdMssg)
        pmd.init({})
    end
end

local function stpWtch()
    if not loader.enabled("watchdog") then
        return
    end
    local wdtMod = watchdogMod or lazyMod("watchdog")
    if wdtMod and wdtMod.start then
        wdtMod.start(_G.WDT_CFG)
    end
end
stopWatchdogBeforePowerOff = function()
    if not loader.enabled("watchdog") then
        return
    end
    local wdtMod = watchdogMod or lazyMod("watchdog")
    if wdtMod and wdtMod.stop then
        wdtMod.stop()
    end
end

local function getImei()
    local did = lazyMod("device_id")
    if did and did.getDisplayId then
        return did.getDisplayId()
    end
    if did and did.getImei then
        return did.getImei() or "unknown"
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
    if not loader.enabled("mqtt") then
        return
    end
    if not netModule then
        return
    end
    sys.taskInit(function()
        -- RNDIS open 会 flymode；须等 stable 后再起 MQTT，避免与 IP_LOSE 竞态
        if loader.enabled("rndis") and type(usbRndis) == "table" then
            if usbRndis.waitForNetStable then
                usbRndis.waitForNetStable(300000)
            elseif usbRndis.isBootStable then
                local n = 0
                while not usbRndis.isBootStable() and n < 600 do
                    sys.wait(500)
                    n = n + 1
                end
            end
        end
        -- net_ready 可能已在 RNDIS 等待 IP 期间发布过，不能只 waitUntil
        local ip = socket and socket.localIP and socket.localIP() or nil
        if not (ip and ip ~= "" and ip ~= "0.0.0.0") then
            sys.waitUntil("net_ready", 300000)
        end
        _G.device_imei = getImei()
        startMqtt()
    end)
end

local function setupFota()
    if not loader.enabled("fota") then
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
    if not loader.enabled("rndis") then
        return
    end
    if type(usbRndis) ~= "table" or not usbRndis.isStarted then
        return
    end
    if usbRndis.isStarted and not usbRndis.isStarted() and usbRndis.start then
        usbRndis.start()
    end
end

local function getBttrPrcn()
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

local function chck3XBurn1(attemptIndex, attemptTotal)
    local cfg = _G.T3X_BURN_CFG or {}
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBttrPrcn()
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

local function chck3XBurn()
    local cfg = _G.T3X_BURN_CFG or {}
    local retryCount = math.max(0, tonumber(cfg.burn_check_retry_count) or 2)
    local maxAttempts = 1 + retryCount
    local retryMs = tonumber(cfg.burn_check_retry_interval_ms) or 800
    local lastFailRsn = nil
    local lastPassPct
    for attempt = 1, maxAttempts do
        local ok, detail = chck3XBurn1(attempt, maxAttempts)
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

local function shtdSrvcFor(cfg)
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
    if cfg.stop_rndis ~= false and loader.enabled("rndis") then
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

local function tryEntr3X()
    local cfg = _G.T3X_BURN_CFG or {}
    local ok, detail = chck3XBurn()
    if not ok then
        appWarn("t3x_burn_denied", tostring(detail or "unknown"))
        if gpioModule and gpioModule.runLedPattern then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    shtdSrvcFor(cfg)
    if not t3xModule or not t3xModule.entBootMode then
        appError("t3x_burn_no_t3x_module")
        return false
    end
    if not t3xModule.entBootMode() then
        appError("t3x_burn_enter_bootmode_fail")
        return false
    end
    appWarn("t3x_burn_entered")
    return true
end

local function wake3XFor(tag, sid, evt)
    if loader.enabled("battery_guard") and type(bttrGrd) == "table"
        and bttrGrd.noteHostIdle then
        bttrGrd.noteHostIdle()
    end
    if loader.enabled("t3x_wakeup") and loader.enabled("t3x_app") then
        local wakeSid = sid or ((_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1)
        local opts = nil
        if (_G.PIR_CFG or {}).high_priority ~= false then
            opts = { force_wake = true }
        end
        reqT3xWake(tag, wakeSid, evt or 0, opts)
    end
end

local function subscribeAll(handlers)
    for _, item in ipairs(handlers) do
        sys.subscribe(item[1], item[2])
    end
end

local function pblsPirTo(overrides)
    if netModule and netModule.publishPirEvent then
        netModule.publishPirEvent(overrides)
    elseif netModule and netModule.pubPirDetect then
        netModule.pubPirDetect(overrides)
    end
end

local function mybPblsWkp(uploadMode)
    local inRest = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.low_power_mode) == 1
    if (uploadMode == "auto" or uploadMode == nil) and not inRest
        and netModule and netModule.publishWakeup then
        netModule.publishWakeup()
    end
end

local function schdDlyd(delayMs)
    delayMs = tonumber(delayMs) or 2000
    sys.timerStart(function()
        if _G.APP_RUNTIME.online_status == 1 and netModule and netModule.publishStatus then
            sys.taskInit(function()
                netModule.publishStatus()
            end)
        end
    end, delayMs)
end

local function onPirMdActn(action, uploadMode, quality)
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        return
    end
    mybPblsWkp(uploadMode)
    wake3XFor("pir_media")
end

local function t3xRecActive()
    if host_uart and host_uart.getT3xRecActive then
        return host_uart.getT3xRecActive() == 1
    end
    return false
end

local function schePirWatc(delayMs)
    local rp = rtPwrMod()
    if not rp or not rp.isPirWatch or not rp.isPirWatch() then
        return
    end
    if state.pir_watch_sleep_timer and sys.timerStop then
        sys.timerStop(state.pir_watch_sleep_timer)
        state.pir_watch_sleep_timer = nil
    end
    state.pir_watch_sleep_timer = sys.timerStart(function()
        state.pir_watch_sleep_timer = nil
        local rp2 = rtPwrMod()
        if not rp2 or not rp2.isPirWatch or not rp2.isPirWatch() then
            return
        end
        if t3xRecActive() then
            return
        end
        if t3xModule and t3xModule.enterSleep then
            appInfo("pir_watch_idle_sleep")
            t3xModule.enterSleep({ skip_pending_work_check = true, reason = "pir_watch_idle" })
        end
    end, tonumber(delayMs) or 5000)
end

local function schdStop(reason, uploadMode, quality)
    local waitMs = tonumber((_G.PIR_RECORD_CFG or {}).stop_mqtt_fallback_ms) or 15000
    sys.taskInit(function()
        sys.wait(waitMs)
        if not pir_ctrl.canStopMqtt or not pir_ctrl.canStopMqtt() then
            return
        end
        local st = pir_ctrl.getState()
        if st.last_stop_reason ~= reason then
            return
        end
        if netModule and netModule.pubPirStop then
            netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
        end
    end)
end

local function onPirStop(reason, uploadMode, quality)
    local preferT3x = (reason == "timer" or reason == "device" or reason == "manual")
        and t3xRecActive()
    if not preferT3x and netModule and netModule.pubPirStop then
        netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
    elseif preferT3x then
        schdStop(reason, uploadMode, quality)
    end
    wake3XFor("pir_stop")
    schePirWatc(5000)
end

local function bldPirMqtt()
    local stopTimer = (_G.APP_PIR_CONFIG and _G.APP_PIR_CONFIG.STOP_REASON
        and _G.APP_PIR_CONFIG.STOP_REASON.TIMER) or "timer"
    return {
        { E.PIR_WAKE_T3X, function(action, uploadMode, quality)
            onPirMdActn(action, uploadMode, quality)
        end },
        { E.PIR_MEDIA_EFFECTIVE, function(action)
            pblsPirTo({ pirStatus = "media_sync", action = action })
        end },
        { E.PIR_REQUEST_T3X_STOP, function(reason)
            wake3XFor("pir_stop_" .. tostring(reason))
        end },
        { E.PIR_STOP_RECORDING, function(reason, uploadMode, quality)
            onPirStop(reason, uploadMode, quality)
        end },
        { E.T3X_SNAPSHOT_DONE, function(path)
            if netModule and netModule.pubSnapDone then
                netModule.pubSnapDone(path)
            end
        end },
        { E.T3X_RECORD_ACTIVE, function()
            if netModule and netModule.pubRecActive then
                netModule.pubRecActive()
            end
        end },
        { E.T3X_PERSON_CNT, function(_)
            -- 有人才走 AT+PERSONCNT；IVS 抖动由 T31 30s 限流。
            -- 人数不上 MQTT 1010，避免后台刷屏。抽片在 T31 本地完成。
        end },
        { E.T3X_RECORD_STOP, function(reason, uploadMode, quality)
            if netModule and netModule.pubT3xStop then
                netModule.pubT3xStop(reason, uploadMode, quality)
            end
            schePirWatc(3000)
        end },
        { E.T3X_IPC_ALERT, function(alertCode, alertDetail)
            ipcSprv.onAlert(alertCode, alertDetail)
        end },
        { E.PIR_TIMER_EXPIRED, function()
            pir_ctrl.pubStopRec(stopTimer)
        end },
        { E.GPIO_PIR_TRIGGERED, function(pirStatus, action, uploadMode, quality)
            pblsPirTo({
                pirStatus = pirStatus or "detected",
                action = action,
                uploadMode = uploadMode,
                quality = quality,
            })
        end },
    }
end

local function bldSystEvnt()
    return {
        { E.POWER_ENTER_REST, function()
            if not isLowPwrOn() then
                return
            end
            onEntLowPwr("mqtt_2002")
        end },
        { E.POWER_EXIT_REST, function()
            -- 2002exit：无论当前是否已在 rest，都走退出逻辑给 T31 正常上电
            onExtLowPwr("mqtt_2002")
        end },
        { E.DEVICE_REBOOT_REQUEST, onReboot },
        { E.DEVICE_POWER_OFF_REQUEST, function()
            onPowerOff("mqtt")
        end },
        { E.GPIO_PWRKEY_LONG, function()
            if state.usb_insert_tick > 0 and (_G.APP_RUNTIME.power_status or 0) == 1 then
                local elapsed = nowMs() - state.usb_insert_tick
                if elapsed < (tonumber((_G.HOST_USB_CFG or {}).pwrkey_grace_ms) or 5000) then
                    return
                end
            end
            onPowerOff("user")
        end },
        { E.GPIO_BOOTKEY_LONG, function()
            sys.taskInit(tryEntr3X)
        end },
        { E.GPIO_COPROC_READY, function()
            if t3xModule then
                t3xModule.extBootMode()
            end
            if pir_ctrl.resume and state.t3x_burn_active then
                pir_ctrl.resume()
                _G.T3X_BURN_MODE_ACTIVE = false
                state.t3x_burn_active = false
                state.heartbeat_paused = false
            end
        end },
        { E.GPIO_USB_DET_CHANGED, function(inserted)
            aplUsbInsSt(inserted == 1, "GPIO27")
            if inserted == 1 and state.mqtt_started then
                schdDlyd(2000)
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
        { E.BATTERY_UPDATE, function(pct, mv)
            if loader.enabled("battery_guard") and type(bttrGrd) == "table" then
                bttrGrd.onBatUpd(pct, mv)
            end
        end },
        { E.MQTT_OFFLINE, onMqttOffl },
        { E.HOST_UART_FIRST_AT or "APP_HOST_UART_FIRST_AT", function()
            notifT3xIdle((_G.APP_RUNTIME.power_status or 0) == 1)
        end },
    }
end

local function stpEvntHndl()
    pir_ctrl.start()
    subscribeAll(bldSystEvnt())
    subscribeAll(bldPirMqtt())
end

local function setupGpio()
    if not gpioModule or not loader.enabled("gpio") then return end
    local gin, gout = _G.GPIO_IN, _G.GPIO_OUT
    gpioModule.start({
        pwrkeyPin = gin and gin.pwr_key and gin.pwr_key.pin,
        bootkeyPin = gin and gin.boot_key and gin.boot_key.pin,
        readyPin = gin and gin.coproc_ready and gin.coproc_ready.pin,
        ledRedPin = (gout and gout.led_red and gout.led_red.enabled ~= false) and gout.led_red.pin or nil,
        ledBluePin = gout and gout.bat_stat_led and gout.bat_stat_led.pin,
    })
end

local function strtBckg()
    if loader.enabled("battery") then
        loader.start(batAdc, "start")
    end
    if loader.enabled("charge") then
        loader.start(usbCharge, "start")
    end
    if loader.enabled("sntp") then
        loader.start(time_sync, "startSntp")
    end
end

local function initPwrStts()
    local inserted = isUsbInsr({ boot_gpio = true })
    if not inserted and not isLowPwrOn() then
        _G.APP_RUNTIME.power_status = 0
        sys.publish(E.GPIO_VBUS_CHANGED, 0)
        return
    end
    if not loader.enabled("pmd_runtime") then
        aplUsbInsSt(inserted, "boot")
    else
        _G.APP_RUNTIME.power_status = inserted and 1 or 0
        sys.publish(E.GPIO_VBUS_CHANGED, _G.APP_RUNTIME.power_status)
    end
end

local function schdBootUsb()
    local usbCfg = _G.HOST_USB_CFG or {}
    local notify = usbCfg.notify_t3x_usb_state
    if notify == false then
        return
    end
    local delayMs = tonumber(usbCfg.boot_notify_delay_ms)
        or tonumber((_G.TIME_SYNC_CFG or {}).hostBootWaitMs)
        or 1500
    sys.timerStart(function()
        notifT3xIdle(isUsbInsr())
    end, delayMs)
end

local function strtHrtb()
    local intervalMs = tonumber((_G.APP_META or {}).heartbeat_log_interval_ms) or 60000
    if intervalMs < 1000 then
        intervalMs = 1000
    end
    sys.timerLoopStart(function()
        if state.heartbeat_paused or _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
            return
        end
        state.heartbeat_count = state.heartbeat_count + 1
        local usbInserted = isUsbInsr() and 1 or 0
        local mqttCnnc = tonumber(rt.online_status) == 1 and 1 or 0
        if netModule and type(netModule.getState) == "function" then
            local ok, ns = pcall(netModule.getState)
            if ok and type(ns) == "table" and ns.connected ~= nil then
                mqttCnnc = ns.connected and 1 or 0
            end
        end
        appInfo("heartbeat_status",
            "usb=" .. tostring(usbInserted),
            "power=" .. tostring(rt.power_status or 0),
            "bat_mv=" .. tostring(rt.battery_mv or "--"),
            "bat_pct=" .. tostring(rt.battery_percent or "--"),
            "mqtt=" .. tostring(mqttCnnc),
            "lowpwr=" .. tostring(rt.low_power_mode or 0))
    end, intervalMs)
end

function start(gpio, net, t3x_ctrl)
    if started then
        appInfo("app_already_started")
        return false
    end
    appInfo("app_start")
    gpioModule, netModule, t3xModule = gpio, net, t3x_ctrl
    _G.device_imei = getImei()
    stpEvntHndl()
    if loader.enabled("battery_guard") and type(bttrGrd) == "table" then
        bttrGrd.start({
            on_enter_low_power = onEntLowPwr,
            on_exit_low_power = onExtLowPwr,
            on_power_off = function()
                onPowerOff("battery")
            end,
            wake_t3x = function()
                reqT3xWake("battery_usb", nil, nil, { force_wake = true })
            end,
            isUsbInse = function()
                return isUsbInsr()
            end,
            is_burn_active = function()
                return state.t3x_burn_active or _G.T3X_BURN_MODE_ACTIVE
            end,
        })
    end
    if loader.enabled("watchdog") then stpWtch() end
    if loader.enabled("uart_bridge") then stpUartBrdg() end
    initPwrStts()
    schdBootUsb()
    if t3xModule then t3xModule.start() end
    if loader.enabled("sound_prompt") and type(sound_prompt) == "table" then
        sound_prompt.start({ t3x = t3xModule })
        if loader.enabled("uart_bridge") and sound_prompt.onAppStarted then
            sound_prompt.onAppStarted()
        end
    end
    if loader.enabled("time_sync") and type(time_sync) == "table" then
        time_sync.start({ t3x = t3xModule })
    end
    if loader.enabled("gpio") then setupGpio() end
    if loader.enabled("pmd_runtime") then setupPmd() end
    strtBckg()
    setupRndis()
    if loader.enabled("mqtt") and netModule and netModule.bootstrapNetwork then
        netModule.bootstrapNetwork()
    end
    bootMqtt()
    setupFota()
    strtHrtb()
    started = true
    appInfo("app_started")
    return true
end

function getState()
    return {
        started = started,
        flag_usb = (_G.APP_RUNTIME.power_status or 0) == 1,
        mqtt_started = state.mqtt_started,
        low_power_mode = _G.APP_RUNTIME.low_power_mode,
        last_wake_event = state.last_wake_event,
        heartbeat_count = state.heartbeat_count,
    }
end
return _M
