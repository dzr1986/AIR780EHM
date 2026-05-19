--- 应用核心编排模块（方案1）
-- 串口：仅通过 uartBridge 统一初始化与收发，见 config.uartid / APP_STACK.uart
-- @module app
-- @release 2026.5.18

require "sys"
require "sysplus"
require "config"
local sntpSync = require "sntpSync"
local uartBridge = require "uartBridge"
local pirCtrl = require "pirCtrl"
local battery = require "battery"
local charge = require "charge"
local mobileInfo = require "mobileInfo"
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
    if _G.lowPowerModeStatus == v then
        return false
    end
    _G.lowPowerModeStatus = v
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
-- UART（唯一入口：uartBridge）
-- ============================================================

local function setupUartBridge()
    if _G.APP_STACK and _G.APP_STACK.uart ~= "uartBridge" then
        log.warn("app", "未支持的 UART 栈:", _G.APP_STACK.uart)
        return false
    end
    local ok = uartBridge.start({
        uartId = _G.uartid or 1,
        baud = _G.uart_baud,
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
        _G.uartBridge = uartBridge
        log.info("app", "串口由 uartBridge 管理", _G.uartid or 1)
    end
    return ok
end

--- 获取串口桥接模块（其他业务应经此收发，勿直接 uart.*）
function getUartBridge()
    return _G.uartBridge or uartBridge
end

-- ============================================================
-- PMD / USB
-- ============================================================

local function handlePmdMessage(msg)
    if not msg then return end
    state.last_usb_state = msg.state
    _G.PowerStatus = msg.charger and 1 or 0
    sys.publish(E.GPIO_VBUS_CHANGED, _G.PowerStatus)

    if msg.state == 0 then
        state.flag_usb = false
        log.info("app", "USB拔出")
        if _G.lowPowerModeStatus == 0 then onEnterLowPower() end
        if not state.mqtt_started then startMqtt() end
    elseif msg.state == 1 then
        state.flag_usb = true
        log.info("app", "USB插入")
        onExitLowPower()
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
    if wdtMod and wdtMod.start and wdtMod.start(_G.WDT_CONFIG) then
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
    pirCtrl.start()
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
            local st = pirCtrl.getState()
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
    sys.subscribe(E.GPIO_t3x_STARTED, function()
        log.info("app", "t3x启动完成")
        if t3xModule then t3xModule.exitBootMode() end
    end)
    sys.subscribe(E.GPIO_VBUS_CHANGED, function(powerStatus)
        log.info("app", "VBUS", powerStatus)
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
    gpioModule.start({
        pirPin = PIR_io_number,
        pwrkeyPin = pwrkey_io_number,
        bootkeyPin = t3x_ota_key_io_number,
        t3xStartupPin = t3x_startup_io_number,
        ledRedPin = led_red_io_number,
        ledBluePin = led_blue_io_number,
    })
end

local function startBackgroundServices()
    if _G.MODULE_FLAGS.battery then battery.start() end
    if _G.MODULE_FLAGS.charge then charge.start() end
    if _G.MODULE_FLAGS.sntp then sntpSync.start() end
    if _G.MODULE_FLAGS.mobile_info then mobileInfo.start() end
end

local function initPowerStatus()
    _G.PowerStatus = (gpio and gpio.VBUS and gpio.get(gpio.VBUS)) or 0
    state.flag_usb = _G.PowerStatus == 1
    sys.publish(E.GPIO_VBUS_CHANGED, _G.PowerStatus)
    log.info("app", "USB", _G.PowerStatus == 1 and "插入" or "未插入")
    if _G.PowerStatus == 0 and not _G.MODULE_FLAGS.pmd_runtime then
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
            if _G.OnlineStatus == 1 then
                mqttHint = "已连接"
            else
                local ip = (socket and socket.localIP and socket.localIP()) or "无IP"
                local csq = (mobile and mobile.csq and mobile.csq()) or "?"
                mqttHint = string.format("已启未连 ip=%s csq=%s", ip, csq)
            end
        end
        log.info("app", string.format("[ALIVE #%d] USB=%d lowPwr=%d mqtt=%s",
            state.heartbeat_count, _G.PowerStatus or 0, _G.lowPowerModeStatus or 0, mqttHint))
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
        lowPowerModeStatus = _G.lowPowerModeStatus,
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
