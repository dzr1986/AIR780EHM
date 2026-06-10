--- 应用核心编排模块（方案1）
-- 串口：仅通过 lib/uart_bridge；见 config.UART_CFG / APP_STACK.uart
-- @module app
-- @release 2026.5.18

require "sys"
require "sysplus"
require "config"

--- MODULE_FLAGS 为 false 时不 require，减 Lua 堆与启动解析（见 doc/CAT1_USER_LIB_SLIM.md）
local function optMod(flag, name)
    local flags = _G.MODULE_FLAGS
    if flags and flags[flag] == false then
        return nil
    end
    local ok, m = pcall(require, name)
    if not ok or type(m) ~= "table" then
        log.warn("app", "require fail", name, ok and "nil module" or tostring(m))
        return nil
    end
    return m
end

local uart_bridge = require "uart_bridge"
local pir_ctrl = require "pir_ctrl"
local battery_guard = require "battery_guard"
local led = require "led"
local host_uart = require "host_uart"
local batAdc = optMod("battery", "vbat")
local usbCharge = optMod("charge", "usb_charge")
local mobile_info = optMod("mobile_info", "mobile_info")
local fota = optMod("fota", "fota")
local usbRndis = optMod("rndis", "usb_rndis")
local sntp_sync = optMod("sntp", "sntp_sync")
local sound_prompt = optMod("sound_prompt", "sound_prompt")
local time_sync = optMod("time_sync", "time_sync")
-- watchdog 在 lib/ 中由工具链自动加载，勿 require（与核心 wdt 库区分）

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local keyModule = require "key"

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

local function nowMs()
    if mcu and mcu.ticks then
        return mcu.ticks()
    end
    return os.time() * 1000
end

local function cancelPwrKeyLongPress()
    if type(keyModule) == "table" and keyModule.cancelLongPress then
        keyModule.cancelLongPress("pwr")
    end
end

-- ============================================================
-- 低功耗状态
-- ============================================================

local function setLowPowerMode(enabled)
    local v = enabled and 1 or 0
    local rt = _G.APP_RUNTIME
    if rt.low_power_mode == v then
        return false
    end
    rt.low_power_mode = v
    return true
end

--- 低功耗产品能力总开关（FEATURE_CFG.low_power / LOW_POWER_CFG / MODULE_FLAGS.low_power）
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
    log.info("app", "t3x wake req", reason, wakeValue)

    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.requestT3xWake
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
    log.info("app", "mqtt offline")
    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.shouldWakeOnMqttOffline
        and (_G.MODULE_FLAGS.t3x_policy ~= false) then
        if not policy.shouldWakeOnMqttOffline() then
            log.info("app", "mqtt off, skip wake", policy.getDenyReason and policy.getDenyReason() or "")
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
        local okLp, lpw = pcall(require, "low_power_wakeup")
        if okLp and lpw and lpw.getModemHibernate then
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
    pcall(function()
        local lpw = require "low_power_wakeup"
        if lpw.onEnterRest then
            lpw.onEnterRest()
        end
    end)
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
        log.info("app", "lp off, ignore enter", reason)
        return
    end
    local okUp, up = pcall(require, "usb_policy")
    if okUp and type(up) == "table" and up.blocks4gRest and up.blocks4gRest() then
        log.info("app", "usb, ignore rest", reason)
        return
    end
    if type(sound_prompt) == "table" and sound_prompt.shouldPlay
        and sound_prompt.shouldPlay("shutdown_low_power") then
        sys.taskInit(function()
            if sound_prompt.playBlocking then
                sound_prompt.playBlocking("shutdown", "shutdown_low_power")
            end
            log.info("app", "enter lp", reason)
            doEnterLowPowerBody(reason)
        end)
        return
    end
    log.info("app", "enter lp", reason)
    doEnterLowPowerBody(reason)
end

local function onExitLowPower(reason)
    reason = reason or "unknown"
    if not setLowPowerMode(false) then return end
    _G.APP_RUNTIME.last_rest_reason = nil
    log.info("app", "exit lp", reason)
    sys.publish(E.POWER_EXITED_REST)
    requestT3xWake("exit_low_power", nil, nil, { force_wake = true })
    pcall(function()
        local lpw = require "low_power_wakeup"
        if lpw.onExitRest then
            lpw.onExitRest()
        end
    end)
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
    log.info("app", "reboot")
    sys.timerStart(function()
    if pm and pm.reboot then pm.reboot() end
    end, 500)
end

local function onPowerOff(reason)
    local function shutdownNow()
        log.info("app", "shutdown", reason or "")
        pm.shutdown()
    end
    if _G.MODULE_FLAGS.sound_prompt ~= false and type(sound_prompt) == "table"
        and sound_prompt.playShutdownThen then
        sound_prompt.playShutdownThen(reason or "user", shutdownNow)
        return
    end
    shutdownNow()
end

-- ============================================================
-- UART（唯一入口：uart_bridge）
-- ============================================================

local function setupUartBridge()
    if _G.APP_STACK and _G.APP_STACK.uart ~= "uart_bridge" then
        log.warn("app", "bad uart stack", _G.APP_STACK.uart)
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
            log.info("app", "uart on", uc.id, uc.baud)
        else
            log.info("app", "uart on")
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
                        log.warn("app", "net not ready, skip mqttcfg")
                        return
                    end
                    if netModule.isSameMqttConfig and netModule.isSameMqttConfig(cfg) then
                        log.info("app", "mqttcfg unchanged, skip restart")
                        return
                    end
                    if not netModule.setMqttConfig(cfg) then
                        log.warn("app", "mqttcfg bad")
                        return
                    end
                    log.info("app", "t3x mqtt cfg", cfg.host, cfg.port)
                    if state.mqtt_started and netModule.restart then
                        netModule.restart()
                    elseif startMqtt() then
                        log.info("app", "mqtt t3x cfg")
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
                    log.info("app", "uart line", line)
                end,
            })
        end
    end
    return ok
end

--- 获取串口桥接模块（其他业务应经此收发，勿直接 uart.*）
function getUartBridge()
    return _G.uart_bridge or uart_bridge
end

-- ============================================================
-- PMD / USB
-- ============================================================

--- GPIO27 拔出后的 rest 策略（须在 applyUsbInsertState 已写入 power_status 之后调用）
-- ① battery_guard.onUsbRemoved：按电量重算（≤10% → reason=battery）
-- ② 若仍未 rest：产品规则拔座进 rest（reason=usb_remove）
-- RNDIS 调试时不进 rest。见 doc/LOW_BATTERY_AND_LOW_POWER.md §2
local function enterRestIfNeededAfterUsbRemove(source)
    if not isLowPowerFeatureEnabled() then
            log.info("app", "lp off, skip usb rest", source or "")
        return
    end
    local rndisOn = _G.MODULE_FLAGS.rndis
        and type(usbRndis) == "table"
        and usbRndis.isEnabled
        and usbRndis.isEnabled()
    if rndisOn then
            log.info("app", "rndis, skip gpio rest", source or "")
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

--- GPIO27 插入：恢复电量保护忽略、必要时退出 rest（见 battery_guard.onUsbInserted）
local function exitRestIfNeededAfterUsbInsert()
    if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
        battery_guard.onUsbInserted()
    else
        onExitLowPower("usb_insert")
    end
end

--- USB 座状态写入口（GPIO27 / 旧 PMD）；拔插策略见上两函数
local function applyUsbInsertState(inserted, source)
    local v = inserted and 1 or 0
    state.last_usb_state = v
    _G.APP_RUNTIME.power_status = v
    sys.publish(E.GPIO_VBUS_CHANGED, v)

    if v == 0 then
        state.flag_usb = false
        log.info("app", "usb remove", source or "")
        notifyT3xUsbHostIdlePolicy(false)
        enterRestIfNeededAfterUsbRemove(source)
    else
        state.flag_usb = true
        state.usb_insert_tick = nowMs()
        cancelPwrKeyLongPress()
        log.info("app", "usb insert", source or "")
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
        log.info("app", "pmd inited")
    end
end

--- Air780EHM 模组侧 WDT（非 t3x）
local function setupWatchdog()
    if not _G.MODULE_FLAGS.watchdog then
        return
    end
    local wdtMod = _G.watchdog
    if wdtMod and wdtMod.start and wdtMod.start(_G.WDT_CFG) then
        log.info("app", "wdt on")
    end
end

-- ============================================================
-- 设备 IMEI 日志
-- ============================================================

local function getImei()
    local ok, did = pcall(require, "device_id")
    if ok and type(did) == "table" and did.getDisplayId then
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
    log.info("app", "+++++ imei=" .. imei .. " ++++++")
end

-- ============================================================
-- MQTT
-- ============================================================

function startMqtt()
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        log.warn("app", "burn: skip mqtt")
        return false
    end
    if state.mqtt_started then
        return false
    end
    if not _G.MODULE_FLAGS.mqtt then
        return false
    end
    if not netModule or not (_G.APP_STACK and _G.APP_STACK.mqtt == "net_mqtt") then
        log.warn("app", "no mqtt cfg")
        return false
    end
    state.mqtt_started = true
    netModule.start()
    log.info("app", "mqtt task on")
    return true
end

--- 上电后等待蜂窝网就绪再启 MQTT（常电联网，不依赖 USB 拔出）
local function bootMqtt()
    if not _G.MODULE_FLAGS.mqtt then
        log.warn("app", "mqtt flag off")
        return
    end
    if not netModule then
        log.error("app", "no net mod")
        return
    end
    -- 蜂窝入网由 main.lua bootstrapNetwork() 尽早启动（同 pwrkey_rndis_boot）
    sys.taskInit(function()
        log.info("app", "wait net_ready")
        local ready, deviceId = sys.waitUntil("net_ready", 300000)
        if ready then
            log.info("app", "net_ready OK", deviceId or "")
        else
            log.warn("app", "net_ready timeout, try mqtt")
        end
        logImeiBanner()
        if startMqtt() then
            log.info("app", "mqtt always-on start")
        elseif state.mqtt_started then
            log.info("app", "mqtt already started")
        else
            log.warn("app", "startMqtt fail")
        end
    end)
end

--- FOTA：订阅 MQTT 2004 触发的 OTA，经 net 上报 1004
local function setupFota()
    if not _G.MODULE_FLAGS.fota then
        return
    end
    local fotaMod = fota or _G.fota
    if not fotaMod or not fotaMod.start then
        log.warn("app", "fota unavailable")
        return
    end
    fotaMod.start({
        publishStatus = function(stage, retCode, message, extra)
            if netModule and netModule.publishOtaStatus then
                netModule.publishOtaStatus(stage, retCode, message, extra)
            end
            end,
        })
    log.info("app", "fota 2004 hooked")
end

local function setupRndis()
    if not _G.MODULE_FLAGS.rndis then
        return
    end
    if type(usbRndis) ~= "table" or not usbRndis.isStarted then
        log.warn("app", "usb_rndis invalid")
        return
    end
    -- main.lua 已 taskInit(open)；未启动时补一次
    if usbRndis.isStarted and not usbRndis.isStarted() and usbRndis.start then
        usbRndis.start()
    end
    sys.taskInit(function()
        sys.wait(3000)
        if type(usbRndis.getStatus) == "function" then
            local st = usbRndis.getStatus()
            log.info("app", "rndis state",
                "enabled", st.enabled and 1 or 0,
                "mode", st.usb_ethernet_mode or "--",
                "ip", st.ip or "--",
                "cell_ip", st.cell_ip or "--")
        end
    end)
end

-- ============================================================
-- 事件订阅
-- ============================================================

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

local function logT3xBurnCheck(name, passed, detail)
    log.info("app", "burn chk", name, passed and "ok" or "fail", detail or "")
end

--- 单次条件判断（由 checkT3xBurnPreconditions 轮询调用）
local function checkT3xBurnPreconditionsOnce(attemptIndex, attemptTotal)
    local cfg = _G.T3X_BURN_CFG or {}
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBatteryPercentForBurn()

    log.info("app", "burn checks", attemptIndex or 1, attemptTotal or 1)
    log.info("app", "burn cfg", "min", minPct, "req_valid", cfg.require_battery_valid ~= false, "allow_repeat", allowRepeat)

    logT3xBurnCheck("runtime.APP_RUNTIME.battery_percent",
        pct ~= nil,
        string.format("raw=%s mv=%s",
            tostring(_G.APP_RUNTIME and _G.APP_RUNTIME.battery_percent),
            tostring(_G.APP_RUNTIME and _G.APP_RUNTIME.battery_mv)))

    if cfg.require_battery_valid ~= false then
        if not pct then
            logT3xBurnCheck("bat", false, string.format("need>=%d wait adc", minPct))
            failReason = failReason or "bat unknown"
        elseif pct < minPct then
            logT3xBurnCheck("bat", false, string.format("%d<%d", pct, minPct))
            failReason = failReason or string.format("bat %d < %d", pct, minPct)
        else
            logT3xBurnCheck("bat", true, string.format("%d>=%d", pct, minPct))
        end
    else
        logT3xBurnCheck("bat", true, "req_valid=off")
    end

    if pir_ctrl.isRecording and pir_ctrl.isRecording() then
        logT3xBurnCheck("pir_rec", true, "will suspend")
    else
        logT3xBurnCheck("pir_rec", true, "idle")
    end

    logT3xBurnCheck("mqtt", true,
        state.mqtt_started and "on" or "off")

    logT3xBurnCheck("burn_flag",
        not (_G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active),
        string.format("BURN=%s active=%s",
            tostring(_G.T3X_BURN_MODE_ACTIVE), tostring(state.t3x_burn_active)))

    if not t3xModule or not t3xModule.getState then
        logT3xBurnCheck("t3x", false, "no module")
        failReason = failReason or "no t3x_ctrl"
    else
        local st = t3xModule.getState() or {}
        log.info("app", "burn t3xst", tostring(st.in_boot_mode), tostring(st.powered_on), tostring(st.power_state))
        if st.pins then
            log.info("app", "burn pins", tostring(st.pins.pwr), tostring(st.pins.boot), tostring(st.pins.ota))
        end
        if st.in_boot_mode then
            if allowRepeat then
                logT3xBurnCheck("bootmode", true, "repeat allowed")
            else
                logT3xBurnCheck("bootmode", false, "already in boot")
                failReason = failReason or "in boot"
            end
        else
            logT3xBurnCheck("bootmode", true, "not in boot")
        end
    end

    if failReason then
        log.warn("app", "burn fail", attemptIndex or 1, failReason)
        return false, failReason
    end
    log.info("app", "burn pass", attemptIndex or 1, "bat", pct)
    return true, pct
end

--- 不满足时重试若干次后综合结果（默认再判断 2 次，共最多 3 次）
local function checkT3xBurnPreconditions()
    local cfg = _G.T3X_BURN_CFG or {}
    local retryCount = tonumber(cfg.burn_check_retry_count) or 2
    if retryCount < 0 then
        retryCount = 0
    end
    local maxAttempts = 1 + retryCount
    local retryMs = tonumber(cfg.burn_check_retry_interval_ms) or 800
    local passCount = 0
    local failCount = 0
    local lastFailReason = nil
    local lastPassPct = nil
    local executed = 0
    local finalOk = false

    log.info("app", "burn poll", maxAttempts, retryMs, retryCount)

    for attempt = 1, maxAttempts do
        executed = attempt
        local ok, detail = checkT3xBurnPreconditionsOnce(attempt, maxAttempts)
        if ok then
            passCount = passCount + 1
            lastPassPct = detail
            finalOk = true
            log.info("app", "burn stats", executed, passCount, failCount)
            break
        end
        failCount = failCount + 1
        lastFailReason = detail
        log.warn("app", "burn stats", executed, passCount, failCount, detail or "")
        if attempt < maxAttempts then
            log.info("app", "burn retry", retryMs, attempt + 1, maxAttempts)
            sys.wait(retryMs)
        end
    end

    log.info("app", "burn sum", maxAttempts, executed, passCount, failCount, finalOk and 1 or 0)
    if finalOk then
        log.info("app", "burn allow", lastPassPct)
        return true, lastPassPct
    end
    log.warn("app", "burn deny", lastFailReason or "?")
    return false, lastFailReason
end

local function shutdownServicesForT3xBurn(cfg)
    cfg = cfg or _G.T3X_BURN_CFG or {}
    _G.T3X_BURN_MODE_ACTIVE = true
    state.t3x_burn_active = true
    state.heartbeat_paused = true

    log.info("app", "stop for burn")

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
            local rndisOk, rndisErr = usbRndis.disable()
            if rndisOk then
                log.info("app", "rndis stopped preburn")
            else
                log.warn("app", "rndis stop fail preburn", rndisErr or "")
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
    log.info("app", "burn mode gpio28")

    local ok, detail = checkT3xBurnPreconditions()
    if not ok then
        log.warn("app", "burn cond fail", detail)
        if gpioModule and gpioModule.runLedPattern then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    log.info("app", "bat ok", detail)

    shutdownServicesForT3xBurn(cfg)

    if not t3xModule or not t3xModule.enterBootMode then
        log.warn("app", "no t3x_ctrl")
        return false
    end
    if not t3xModule.enterBootMode() then
        log.warn("app", "enterBoot fail")
        return false
    end
    log.info("app", "burn seq start, wait coproc ready")
    return true
end

local function onPirMediaAction(action, uploadMode, quality)
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        return
    end
    log.info("app", "pir act", action, uploadMode, quality)
    local inRest = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.low_power_mode) == 1
    if (uploadMode == "auto" or uploadMode == nil) and not inRest
        and netModule and netModule.publishWakeup then
        netModule.publishWakeup()
    elseif inRest and (uploadMode == "auto" or uploadMode == nil) then
        log.info("app", "rest, skip pir 1001")
    end
    local sid = (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    requestT3xWake("pir_media", sid, 0)
end

local function t3xRecActive()
    if host_uart and host_uart.getT3xRecActive then
        return host_uart.getT3xRecActive() == 1
    end
    return false
end

local function onPirStopRecording(reason, uploadMode, quality)
    log.info("app", "pir stop", reason)
    local preferT3x = (reason == "timer" or reason == "cloud" or reason == "manual")
        and t3xRecActive()
    if not preferT3x and netModule and netModule.publishPirRecordStop then
        netModule.publishPirRecordStop(reason, uploadMode, quality, { source = "4g" })
    elseif preferT3x then
        log.info("app", "t3x rec active, 1011 to t3x", reason)
    end
    if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
        local sid = (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
        requestT3xWake("pir_stop", sid, 0)
    end
end

local function setupEventHandlers()
    pir_ctrl.start()
    sys.subscribe(E.POWER_ENTER_REST, function()
        if not isLowPowerFeatureEnabled() then
            return
        end
        local okUp, up = pcall(require, "usb_policy")
        if okUp and type(up) == "table" and up.blocks4gRest and up.blocks4gRest() then
            log.info("app", "usb, ignore 2002 rest")
            return
        end
        onEnterLowPower("mqtt_2002")
    end)
    sys.subscribe(E.POWER_EXIT_REST, function()
        if isLowPowerFeatureEnabled() or (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) then
            onExitLowPower("mqtt_2002")
        end
    end)
    sys.subscribe(E.DEVICE_REBOOT_REQUEST, onReboot)
    sys.subscribe(E.DEVICE_POWER_OFF_REQUEST, function()
        onPowerOff("mqtt")
    end)

    sys.subscribe(E.PIR_WAKE_T3X, function(action, uploadMode, quality)
        onPirMediaAction(action, uploadMode, quality)
    end)
    sys.subscribe(E.PIR_REQUEST_T3X_STOP, function(reason, uploadMode, quality)
        log.info("app", "req t3x stop rec", reason)
        local sid = (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
        requestT3xWake("pir_stop_" .. tostring(reason), sid, 0)
    end)
    sys.subscribe(E.T3X_SNAPSHOT_DONE, function(path)
        log.info("app", "t3x snap done", path)
        if netModule and netModule.publishPirSnapshotDone then
            netModule.publishPirSnapshotDone(path)
        end
    end)
    sys.subscribe(E.PIR_STOP_RECORDING, function(reason, uploadMode, quality)
        onPirStopRecording(reason, uploadMode, quality)
    end)
    sys.subscribe(E.T3X_RECORD_ACTIVE, function()
        if netModule and netModule.publishPirRecordActive then
            netModule.publishPirRecordActive()
        end
    end)
    sys.subscribe(E.T3X_RECORD_STOP, function(reason, uploadMode, quality)
        log.info("app", "t3x rec end", reason)
        if netModule and netModule.publishT3xRecordStop then
            netModule.publishT3xRecordStop(reason, uploadMode, quality)
        end
    end)
    sys.subscribe(E.PIR_TIMER_EXPIRED, function(uploadMode, quality)
        local stopTimer = (_G.APP_PIR_CONFIG and _G.APP_PIR_CONFIG.STOP_REASON
            and _G.APP_PIR_CONFIG.STOP_REASON.TIMER) or "timer"
        pir_ctrl.publishStopRecording(stopTimer)
    end)
    sys.subscribe(E.GPIO_PIR_TRIGGERED, function(pirStatus, action, uploadMode, quality)
        log.info("app", "PIR GPIO", pirStatus, action)
        if netModule and netModule.publishPirDetect then
            local st = pir_ctrl.getState()
            netModule.publishPirDetect({
                status = "1",
                pirStatus = pirStatus or "detected",
                action = action,
                uploadMode = uploadMode,
                quality = quality,
                recording = st.recording and 1 or 0,
            })
        end
    end)

    sys.subscribe(E.GPIO_PWRKEY_SHORT, function()
        log.info("app", "pwr short")
    end)
    sys.subscribe(E.GPIO_PWRKEY_LONG, function()
        log.info("app", "pwr long")
        if state.usb_insert_tick > 0 then
            local elapsed = nowMs() - state.usb_insert_tick
            if _G.APP_RUNTIME.power_status == 1 and elapsed < USB_PWRKEY_GRACE_MS then
                log.warn("app", "usb just inserted, ignore pwr long", elapsed)
                return
            end
        end
        onPowerOff("user")
    end)
    sys.subscribe(E.GPIO_BOOTKEY_SHORT, function()
        log.info("app", "boot short")
    end)
    sys.subscribe(E.GPIO_BOOTKEY_LONG, function()
        log.info("app", "boot long")
        sys.taskInit(tryEnterT3xBurnMode)
    end)
    sys.subscribe(E.GPIO_COPROC_READY, function()
        log.info("app", "coproc ready")
        if t3xModule then t3xModule.exitBootMode() end
        if pir_ctrl.resume and state.t3x_burn_active then
            pir_ctrl.resume()
            _G.T3X_BURN_MODE_ACTIVE = false
            state.t3x_burn_active = false
            state.heartbeat_paused = false
            log.info("app", "burn end, pir resume")
        end
    end)
    sys.subscribe(E.GPIO_VBUS_CHANGED, function(powerStatus)
        log.info("app", "VBUS", powerStatus)
    end)
    sys.subscribe(E.GPIO_USB_DET_CHANGED, function(inserted)
        applyUsbInsertState(inserted == 1, "GPIO27")
        if inserted == 1 and _G.MODULE_FLAGS.rndis and not state.t3x_burn_active
            and type(usbRndis) == "table" and usbRndis.enableAsync then
            log.info("app", "usb, re-en rndis")
            usbRndis.enableAsync()
        end
        if inserted == 1 and state.mqtt_started and netModule and netModule.publishStatus then
            sys.timerStart(function()
                if _G.APP_RUNTIME.online_status == 1 then
                    netModule.publishStatus()
                end
            end, 2000)
        end
    end)
    sys.subscribe(E.GPIO_CHG_STATE_CHANGED, function(charging)
        log.info("app", "chg17", charging == 1 and "chg" or "no")
        if state.mqtt_started and netModule and netModule.publishStatus and _G.APP_RUNTIME.online_status == 1 then
            netModule.publishStatus()
        end
    end)

    sys.subscribe("BATTERY_UPDATE", function(pct, mv)
        log.info("app", "bat", pct, mv)
        if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
            battery_guard.onBatteryUpdate(pct, mv)
        end
    end)
    sys.subscribe(E.MQTT_OFFLINE, onMqttOffline)
    sys.subscribe(E.MQTT_SERVER_DATA, function(_topic, payload)
        log.info("app", "mqtt dl", payload)
    end)
    sys.subscribe(E.MQTT_PUBLISH_WAKEUP, function(topic, payload)
        log.info("app", "mqtt pub wake", topic)
    end)
    sys.subscribe(E.MQTT_PUBLISH_REST, function(topic, payload)
        log.info("app", "mqtt pub rest", topic)
    end)
    sys.subscribe(E.MQTT_OTA_STATUS, function(stage, retCode, message)
        log.info("app", "ota st", stage, retCode, message)
    end)
end

-- ============================================================
-- 外设
-- ============================================================

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
        log.info("app", "bat mod v2")
        if type(batAdc) == "table" and batAdc.start then
            batAdc.start()
        else
            log.error("app", "no bat_adc, skip")
        end
    end
    if _G.MODULE_FLAGS.charge then
        if type(usbCharge) == "table" and usbCharge.start then
            usbCharge.start()
        else
            log.error("app", "no usb_charge, skip")
        end
    end
    if _G.MODULE_FLAGS.sntp then
        if type(sntp_sync) == "table" and sntp_sync.start then
            sntp_sync.start()
        else
            log.warn("app", "no sntp_sync, skip")
        end
    end
    if _G.MODULE_FLAGS.mobile_info then
        if type(mobile_info) == "table" and mobile_info.start then
            mobile_info.start()
        else
            log.warn("app", "no mobile_info, skip")
        end
    end
end

local function initPowerStatus()
    local inserted
    if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
        inserted = usbCharge.isUsbInserted()
        log.info("app", "usb_det27", inserted and 1 or 0)
    else
        inserted = (gpio and gpio.VBUS and gpio.get(gpio.VBUS) == 1) or false
        log.info("app", "vbus", inserted and 1 or 0)
    end
    if not inserted and not isLowPowerFeatureEnabled() then
        _G.APP_RUNTIME.power_status = 0
        state.flag_usb = false
        sys.publish(E.GPIO_VBUS_CHANGED, 0)
        log.info("app", "lp off, no usb keep t3x")
        return
    end
    if not _G.MODULE_FLAGS.pmd_runtime then
        -- 拔插策略、T3x +CAT1:USB 通知、进/出 rest 均走统一入口
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
        -- 延迟补发也优先读真实的 USB_DET 物理插入状态，避免早期读数与实际不一致时误报 USB
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
        log.info("app", string.format("[ALIVE #%d] USB=%d lowPwr=%d bat=%s mqtt=%s",
            state.heartbeat_count, _G.APP_RUNTIME.power_status or 0, _G.APP_RUNTIME.low_power_mode or 0, batHint, mqttHint))
    end, 10000)
end

-- ============================================================
-- 启动入口
-- ============================================================

function start(gpio, net, t3x_ctrl)
    if started then
        log.warn("app", "started")
        return false
    end
    if led.isBatStatBreathTestEnabled() then
        led.startBatStatBreathTest()
        started = true
        log.info("app", "led test, skip boot")
        return true
    end
    gpioModule, netModule, t3xModule = gpio, net, t3x_ctrl

    log.info("app", "app start ====")
    log.info("app", "stack", json.encode(_G.APP_STACK or {}))
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

    log.info("app", "app ready ====")
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
