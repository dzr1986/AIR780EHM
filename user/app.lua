--- 应用核心编排模块（方案1）
-- 串口：仅通过 lib/uart_bridge；见 config.UART_CFG / APP_STACK.uart
-- @module app
-- @release 2026.5.18

require "sys"
require "sysplus"
require "config"
local sntp_sync = require "sntp_sync"
local uart_bridge = require "uart_bridge"
local pir_ctrl = require "pir_ctrl"
local batAdc = require "bat_adc"
local usbCharge = require "usb_charge"
local mobile_info = require "mobile_info"
local fota = require "fota"
local usbRndis = require "usb_rndis"
-- watchdog 在 lib/ 中由工具链自动加载，勿 require（与核心 wdt 库区分）

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
}

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

local function sendWakePulse(evt, channel)
    wakeValue = string.format("%d,%d", channel or 0, evt)
    state.last_wake_event = evt
    log.info("app", "唤醒脉冲记录", wakeValue)
    if _G.MODULE_FLAGS.t3x_wakeup and t3xModule and t3xModule.pulseWakeup then
        t3xModule.pulseWakeup()
    end
end

local function onMqttOffline()
    log.info("app", "MQTT离线")
    sendWakePulse(2, 0)
end

local function onEnterLowPower()
    if not setLowPowerMode(true) then return end
    log.info("app", "进入低功耗")
    sys.publish(E.POWER_ENTERED_REST)
    if t3xModule and t3xModule.enterSleep then
        t3xModule.enterSleep({ modemHibernate = false })
    end
    if state.mqtt_started and netModule and netModule.publishRest then
        netModule.publishRest()
    end
end

local function onExitLowPower()
    if not setLowPowerMode(false) then return end
    log.info("app", "退出低功耗")
    sys.publish(E.POWER_EXITED_REST)
    if t3xModule then
        sys.taskInit(function() t3xModule.wake() end)
    end
end

local function onReboot()
    log.info("app", "设备重启")
    sys.timerStart(function()
        if pm and pm.reboot then pm.reboot() end
    end, 500)
end

local function onPowerOff()
    log.info("app", "设备关机")
    pm.shutdown()
end

-- ============================================================
-- UART（唯一入口：uart_bridge）
-- ============================================================

local function setupUartBridge()
    if _G.APP_STACK and _G.APP_STACK.uart ~= "uart_bridge" then
        log.warn("app", "未支持的 UART 栈:", _G.APP_STACK.uart)
        return false
    end
    local ok = uart_bridge.start({
        uartId = (_G.UART_CFG and _G.UART_CFG.id) or 1,
        baud = _G.UART_CFG and _G.UART_CFG.baud,
        onEnterLowPower = onEnterLowPower,
        onExitLowPower = onExitLowPower,
        onReboot = onReboot,
        onPowerOff = onPowerOff,
        onRaw = function(data)
            state.last_uart_rx = data
        end,
        onString = function(line)
            log.info("app", "UART STR", line)
        end,
        onHex = function(bin, hex)
            log.info("app", "UART HEX", hex or "")
        end,
    })
    if ok then
        _G.uart_bridge = uart_bridge
        log.info("app", "串口由 uart_bridge 管理", (_G.UART_CFG and _G.UART_CFG.id) or 1)
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

local function applyUsbInsertState(inserted, source)
    local v = inserted and 1 or 0
    state.last_usb_state = v
    _G.APP_RUNTIME.power_status = v
    sys.publish(E.GPIO_VBUS_CHANGED, v)

    if v == 0 then
        state.flag_usb = false
        log.info("app", "USB拔出", source or "")
        if _G.APP_RUNTIME.low_power_mode == 0 then onEnterLowPower() end
        if not state.mqtt_started then startMqtt() end
    else
        state.flag_usb = true
        log.info("app", "USB插入", source or "")
        onExitLowPower()
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
        log.info("app", "PMD已初始化")
    end
end

--- Air780EHM 模组侧 WDT（非 t3x）
local function setupWatchdog()
    if not _G.MODULE_FLAGS.watchdog then
        return
    end
    local wdtMod = _G.watchdog
    if wdtMod and wdtMod.start and wdtMod.start(_G.WDT_CFG) then
        log.info("app", "已启用 Air780 模组看门狗")
    end
end

-- ============================================================
-- 设备 IMEI 日志
-- ============================================================

local function getImei()
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
    if state.mqtt_started then
        return false
    end
    if not _G.MODULE_FLAGS.mqtt then
        return false
    end
    if not netModule or not (_G.APP_STACK and _G.APP_STACK.mqtt == "net") then
        log.warn("app", "MQTT 未配置")
        return false
    end
    state.mqtt_started = true
    netModule.start()
    log.info("app", "MQTT任务已启动")
    return true
end

--- 上电后等待蜂窝网就绪再启 MQTT（常电联网，不依赖 USB 拔出）
local function bootMqtt()
    if not _G.MODULE_FLAGS.mqtt then
        log.warn("app", "MODULE_FLAGS.mqtt=false，跳过 MQTT")
        return
    end
    if not netModule then
        log.error("app", "net 模块未注入，无法启动 MQTT")
        return
    end
    -- 尽早拉起蜂窝入网（发布 net_ready），避免只等事件却无人 publish
    if netModule.bootstrapNetwork then
        netModule.bootstrapNetwork()
    end
    sys.taskInit(function()
        log.info("app", "等待 net_ready...")
        local ready, deviceId = sys.waitUntil("net_ready", 300000)
        if ready then
            log.info("app", "net_ready OK", deviceId or "")
        else
            log.warn("app", "net_ready 超时，仍尝试 startMqtt")
        end
        logImeiBanner()
        if startMqtt() then
            log.info("app", "MQTT 已按常电策略启动")
        else
            log.warn("app", "startMqtt 失败", "mqtt_started", state.mqtt_started)
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
        log.warn("app", "FOTA 模块不可用，跳过")
        return
    end
    fotaMod.start({
        publishStatus = function(stage, retCode, message, extra)
            if netModule and netModule.publishOtaStatus then
                netModule.publishOtaStatus(stage, retCode, message, extra)
            end
        end,
    })
    log.info("app", "FOTA 已对接 MQTT 2004")
end

local function setupRndis()
    if not _G.MODULE_FLAGS.rndis then
        return
    end
    if type(usbRndis) ~= "table" or not usbRndis.start then
        log.warn("app", "usb_rndis 模块无效，跳过 RNDIS")
        return
    end
    if usbRndis.start() then
        log.info("app", "RNDIS 任务已启动")
    end
end

-- ============================================================
-- 事件订阅
-- ============================================================

local function onPirMediaAction(action, uploadMode, quality)
    log.info("app", "PIR动作", action, uploadMode, quality)
    if (uploadMode == "auto" or uploadMode == nil) and netModule and netModule.publishWakeup then
        netModule.publishWakeup()
    end
    if t3xModule then
        sys.taskInit(function() t3xModule.wake() end)
    end
end

local function onPirStopRecording(reason, uploadMode, quality)
    log.info("app", "PIR停录", reason)
    if netModule and netModule.publishPirRecordStop then
        netModule.publishPirRecordStop(reason, uploadMode, quality)
    end
    if t3xModule and t3xModule.pulseWakeup then
        t3xModule.pulseWakeup()
    end
end

local function setupEventHandlers()
    pir_ctrl.start()
    sys.subscribe(E.POWER_ENTER_REST, onEnterLowPower)
    sys.subscribe(E.POWER_EXIT_REST, onExitLowPower)
    sys.subscribe(E.DEVICE_REBOOT_REQUEST, onReboot)
    sys.subscribe(E.DEVICE_POWER_OFF_REQUEST, onPowerOff)

    sys.subscribe(E.PIR_TAKE_PHOTO, function(uploadMode, quality)
        onPirMediaAction("photo", uploadMode, quality)
    end)
    sys.subscribe(E.PIR_RECORD_VIDEO, function(uploadMode, quality)
        onPirMediaAction("video", uploadMode, quality)
    end)
    sys.subscribe(E.PIR_STOP_RECORDING, function(reason, uploadMode, quality)
        onPirStopRecording(reason, uploadMode, quality)
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
        log.info("app", "电源键短按")
    end)
    sys.subscribe(E.GPIO_PWRKEY_LONG, function()
        log.info("app", "电源键长按")
        onPowerOff()
    end)
    sys.subscribe(E.GPIO_BOOTKEY_SHORT, function()
        log.info("app", "BOOT键短按")
    end)
    sys.subscribe(E.GPIO_BOOTKEY_LONG, function()
        log.info("app", "BOOT键长按")
        if t3xModule then t3xModule.enterBootMode() end
    end)
    sys.subscribe(E.GPIO_COPROC_READY, function()
        log.info("app", "协处理器就绪")
        if t3xModule then t3xModule.exitBootMode() end
    end)
    sys.subscribe(E.GPIO_VBUS_CHANGED, function(powerStatus)
        log.info("app", "VBUS", powerStatus)
    end)
    sys.subscribe(E.GPIO_USB_DET_CHANGED, function(inserted)
        applyUsbInsertState(inserted == 1, "GPIO27")
        if inserted == 1 and state.mqtt_started and netModule and netModule.publishStatus then
            sys.timerStart(function()
                if _G.APP_RUNTIME.online_status == 1 then
                    netModule.publishStatus()
                end
            end, 2000)
        end
    end)
    sys.subscribe(E.GPIO_CHG_STATE_CHANGED, function(charging)
        log.info("app", "CHG_STATE GPIO17", charging == 1 and "充电中" or "未充电/充满",
            "（充电板：充电=CHG_RED 硬件红灯，充满=CHG_BLUE 硬件蓝灯）")
        if state.mqtt_started and netModule and netModule.publishStatus and _G.APP_RUNTIME.online_status == 1 then
            netModule.publishStatus()
        end
    end)

    sys.subscribe("BATTERY_UPDATE", function(pct, mv)
        log.info("app", "电量", pct, "%", mv, "mV",
            "（模组LED：>70%蓝常亮，20~70%蓝闪，<20%红闪）")
    end)
    sys.subscribe(E.MQTT_OFFLINE, onMqttOffline)
    sys.subscribe(E.MQTT_SERVER_DATA, function(_topic, payload)
        log.info("app", "MQTT下行", payload)
    end)
    sys.subscribe(E.MQTT_PUBLISH_WAKEUP, function(topic, payload)
        log.info("app", "MQTT已发唤醒", topic, payload)
    end)
    sys.subscribe(E.MQTT_PUBLISH_REST, function(topic, payload)
        log.info("app", "MQTT已发休眠", topic, payload)
    end)
    sys.subscribe(E.MQTT_OTA_STATUS, function(stage, retCode, message)
        log.info("app", "OTA状态", stage, retCode, message)
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
        ledRedPin = gout and gout.led_red and gout.led_red.pin,
        ledBluePin = gout and gout.bat_stat_led and gout.bat_stat_led.pin,
    })
end

local function startBackgroundServices()
    if _G.MODULE_FLAGS.battery then
        if type(batAdc) == "table" and batAdc.start then
            batAdc.start()
        else
            log.error("app", "bat_adc 模块无效，跳过电量采样")
        end
    end
    if _G.MODULE_FLAGS.charge then
        if type(usbCharge) == "table" and usbCharge.start then
            usbCharge.start()
        else
            log.error("app", "usb_charge 模块无效，跳过充电检测")
        end
    end
    if _G.MODULE_FLAGS.sntp then sntp_sync.start() end
    if _G.MODULE_FLAGS.mobile_info then mobile_info.start() end
end

local function initPowerStatus()
    local inserted
    if _G.MODULE_FLAGS.charge and type(usbCharge) == "table" and usbCharge.isUsbInserted then
        inserted = usbCharge.isUsbInserted()
        log.info("app", "USB_DET GPIO27", inserted and "插入" or "未插入")
    else
        inserted = (gpio and gpio.VBUS and gpio.get(gpio.VBUS) == 1) or false
        log.info("app", "USB VBUS", inserted and "插入" or "未插入")
    end
    _G.APP_RUNTIME.power_status = inserted and 1 or 0
    state.flag_usb = inserted
    sys.publish(E.GPIO_VBUS_CHANGED, _G.APP_RUNTIME.power_status)
    if not inserted and not _G.MODULE_FLAGS.pmd_runtime and not _G.MODULE_FLAGS.charge then
        if _G.MODULE_FLAGS.mqtt then
            setLowPowerMode(true)
            if t3xModule and t3xModule.enterSleep then
                t3xModule.enterSleep({ modemHibernate = false })
            end
            log.info("app", "无USB，MQTT常电：仅 t3x 休眠，等待蜂窝/MQTT")
        else
            onEnterLowPower()
        end
    end
end

local function startHeartbeat()
    sys.timerLoopStart(function()
        state.heartbeat_count = state.heartbeat_count + 1
        local mqttHint = "未启"
        if state.mqtt_started then
            if _G.APP_RUNTIME.online_status == 1 then
                mqttHint = "已连接"
            else
                local ip = (socket and socket.localIP and socket.localIP()) or "无IP"
                local csq = (mobile and mobile.csq and mobile.csq()) or "?"
                mqttHint = string.format("已启未连 ip=%s csq=%s", ip, csq)
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

function start(gpio, net, t3x)
    if started then
        log.warn("app", "已启动")
        return false
    end
    gpioModule, netModule, t3xModule = gpio, net, t3x

    log.info("app", "========== 应用启动 ==========")
    log.info("app", "栈", json.encode(_G.APP_STACK or {}))
    logImeiBanner()

    setupEventHandlers()
    if _G.MODULE_FLAGS.watchdog then setupWatchdog() end
    if _G.MODULE_FLAGS.uart_bridge then setupUartBridge() end
    if t3xModule then t3xModule.start() end
    if _G.MODULE_FLAGS.gpio then setupGpio() end
    if _G.MODULE_FLAGS.pmd_runtime then setupPmd() end
    startBackgroundServices()
    initPowerStatus()
    setupRndis()
    if _G.MODULE_FLAGS.mqtt and netModule and netModule.bootstrapNetwork then
        netModule.bootstrapNetwork()
    end
    bootMqtt()
    setupFota()
    startHeartbeat()

    log.info("app", "========== 启动完成 ==========")
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
