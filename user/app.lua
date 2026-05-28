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
local batAdc = require "vbat"
local usbCharge = require "usb_charge"
local mobile_info = require "mobile_info"
local fota = require "fota"
local usbRndis = require "usb_rndis"
local battery_guard = require "battery_guard"
local led = require "led"
local host_uart = require "host_uart"
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

local function sendWakePulse(evt, channel)
    local sid = channel or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    wakeValue = string.format("%d,%d", sid, evt)
    state.last_wake_event = evt
    log.info("app", "t3x 唤醒", wakeValue)
    if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
        host_uart.notify_host(sid, evt)
    elseif t3xModule and t3xModule.pulseWakeup then
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
    pcall(function()
        local net_tcp = require "net_tcp"
        if net_tcp.getState and net_tcp.getState().configured then
            net_tcp.closeChannel(net_tcp.getState().sid)
        end
    end)
end

local function onExitLowPower()
    if not setLowPowerMode(false) then return end
    log.info("app", "退出低功耗")
    sys.publish(E.POWER_EXITED_REST)
    if t3xModule then
        sys.taskInit(function() t3xModule.wake() end)
    end
    pcall(function()
        local ch = _G.NET_TCP_CHANNEL
        if ch and _G.MODULE_FLAGS.net_tcp ~= false then
            require("net_tcp").applyChannel(ch)
        end
    end)
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
            log.info("app", "串口驱动已启", uc.id, uc.baud)
        else
            log.info("app", "串口驱动已启")
        end
        if _G.MODULE_FLAGS.t3x_app ~= false then
            host_uart.start({
                t3x = t3xModule,
                on_enter_low_power = onEnterLowPower,
                on_exit_low_power = onExitLowPower,
                on_reboot = onReboot,
                on_power_off = onPowerOff,
                on_mqtt_cfg = function(cfg)
                    if not netModule or not netModule.setMqttConfig then
                        log.warn("app", "net 未就绪，忽略 MQTTCFG")
                        return
                    end
                    if not netModule.setMqttConfig(cfg) then
                        log.warn("app", "MQTTCFG 无效")
                        return
                    end
                    log.info("app", "t3x 覆盖 MQTT", cfg.host, cfg.port)
                    if state.mqtt_started and netModule.restart then
                        netModule.restart()
                    elseif startMqtt() then
                        log.info("app", "MQTT 已按 t3x 配置连接")
                    end
                end,
                on_servcreate = function(ch)
                    local net_tcp = require "net_tcp"
                    net_tcp.applyChannel(ch)
                end,
                on_servclose = function(sid)
                    local net_tcp = require "net_tcp"
                    net_tcp.closeChannel(sid)
                end,
                on_plain_line = function(line)
                    log.info("app", "UART 行", line)
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

local function applyUsbInsertState(inserted, source)
    local v = inserted and 1 or 0
    state.last_usb_state = v
    _G.APP_RUNTIME.power_status = v
    sys.publish(E.GPIO_VBUS_CHANGED, v)

    if v == 0 then
        state.flag_usb = false
        log.info("app", "USB拔出", source or "")
        -- GPIO27=外壳 USB 座；PC 调试线/RNDIS 时可能仍为未插入，勿因此进低功耗
        local rndisOn = _G.MODULE_FLAGS.rndis
            and type(usbRndis) == "table"
            and usbRndis.isEnabled
            and usbRndis.isEnabled()
        if rndisOn then
            log.info("app", "RNDIS 已开，跳过因 GPIO27 未插入而进入低功耗")
        elseif _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
            battery_guard.onUsbRemoved()
            if _G.APP_RUNTIME.low_power_mode == 0 then
                onEnterLowPower()
            end
        elseif _G.APP_RUNTIME.low_power_mode == 0 then
            onEnterLowPower()
        end
    else
        state.flag_usb = true
        state.usb_insert_tick = nowMs()
        cancelPwrKeyLongPress()
        log.info("app", "USB插入", source or "")
        if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
            battery_guard.onUsbInserted()
        else
            onExitLowPower()
        end
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
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        log.warn("app", "t3x 烧录模式，跳过启动 MQTT")
        return false
    end
    if state.mqtt_started then
        return false
    end
    if not _G.MODULE_FLAGS.mqtt then
        return false
    end
    if not netModule or not (_G.APP_STACK and _G.APP_STACK.mqtt == "net_mqtt") then
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
    -- 蜂窝入网由 main.lua bootstrapNetwork() 尽早启动（同 pwrkey_rndis_boot）
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
        elseif state.mqtt_started then
            log.info("app", "MQTT 已由其他路径启动，跳过重复 startMqtt")
        else
            log.warn("app", "startMqtt 失败")
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
    if type(usbRndis) ~= "table" or not usbRndis.isStarted then
        log.warn("app", "usb_rndis 模块无效，跳过 RNDIS")
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
            log.info("app", "RNDIS 状态",
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
    log.info("app", "t3x烧录条件", name, passed and "通过" or "失败", detail or "")
end

--- 单次条件判断（由 checkT3xBurnPreconditions 轮询调用）
local function checkT3xBurnPreconditionsOnce(attemptIndex, attemptTotal)
    local cfg = _G.T3X_BURN_CFG or {}
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBatteryPercentForBurn()

    log.info("app", "---------- t3x 烧录条件检查",
        "第", attemptIndex or 1, "/", attemptTotal or 1, "次", "----------")
    log.info("app", "t3x烧录配置",
        "min_battery", minPct, "%",
        "require_battery_valid", cfg.require_battery_valid ~= false,
        "allow_repeat_enter_boot", allowRepeat)

    logT3xBurnCheck("runtime.APP_RUNTIME.battery_percent",
        pct ~= nil,
        string.format("raw=%s mv=%s",
            tostring(_G.APP_RUNTIME and _G.APP_RUNTIME.battery_percent),
            tostring(_G.APP_RUNTIME and _G.APP_RUNTIME.battery_mv)))

    if cfg.require_battery_valid ~= false then
        if not pct then
            logT3xBurnCheck("电量", false,
                string.format("未知(需≥%d%%)，请等待 bat_adc 采样", minPct))
            failReason = failReason or "电量未知，请等待 bat_adc 采样"
        elseif pct < minPct then
            logT3xBurnCheck("电量", false, string.format("%d%% < 要求 %d%%", pct, minPct))
            failReason = failReason or string.format("电量 %d%% 低于 %d%%", pct, minPct)
        else
            logT3xBurnCheck("电量", true, string.format("%d%% >= %d%%", pct, minPct))
        end
    else
        logT3xBurnCheck("电量", true, "已关闭 require_battery_valid")
    end

    if pir_ctrl.isRecording and pir_ctrl.isRecording() then
        logT3xBurnCheck("PIR录像中", true, "进入后将 suspend 并停录")
    else
        logT3xBurnCheck("PIR录像中", true, "未在录像")
    end

    logT3xBurnCheck("MQTT状态", true,
        state.mqtt_started and "mqtt_started=true(进入后将 stop)" or "mqtt_started=false")

    logT3xBurnCheck("烧录标志",
        not (_G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active),
        string.format("T3X_BURN_MODE_ACTIVE=%s t3x_burn_active=%s",
            tostring(_G.T3X_BURN_MODE_ACTIVE), tostring(state.t3x_burn_active)))

    if not t3xModule or not t3xModule.getState then
        logT3xBurnCheck("t3x_ctrl", false, "模块未注入或无 getState")
        failReason = failReason or "t3x_ctrl 不可用"
    else
        local st = t3xModule.getState() or {}
        log.info("app", "t3x烧录条件 t3x状态",
            "in_boot_mode", tostring(st.in_boot_mode),
            "powered_on", tostring(st.powered_on),
            "power_state", tostring(st.power_state),
            "last_action", tostring(st.last_action))
        if st.pins then
            log.info("app", "t3x烧录条件 t3x引脚",
                "pwr", tostring(st.pins.pwr),
                "boot", tostring(st.pins.boot),
                "ota", tostring(st.pins.ota))
        end
        if st.in_boot_mode then
            if allowRepeat then
                logT3xBurnCheck("未在BOOT模式", true,
                    "in_boot_mode=true 但 allow_repeat_enter_boot，允许再次 enterBootMode")
            else
                logT3xBurnCheck("未在BOOT模式", false,
                    "in_boot_mode=true（需 coproc_ready 退出 BOOT 或开 allow_repeat_enter_boot）")
                failReason = failReason or "已在 BOOT 模式"
            end
        else
            logT3xBurnCheck("未在BOOT模式", true, "in_boot_mode=false")
        end
    end

    if failReason then
        log.warn("app", "本次判断结果: 失败", "第", attemptIndex or 1, "次", failReason)
        return false, failReason
    end
    log.info("app", "本次判断结果: 通过", "第", attemptIndex or 1, "次", "battery", pct, "%")
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

    log.info("app", "========== t3x 烧录条件轮询 ==========",
        "最多", maxAttempts, "次",
        "失败间隔", retryMs, "ms",
        "额外重试", retryCount, "次")

    for attempt = 1, maxAttempts do
        executed = attempt
        local ok, detail = checkT3xBurnPreconditionsOnce(attempt, maxAttempts)
        if ok then
            passCount = passCount + 1
            lastPassPct = detail
            finalOk = true
            log.info("app", "累计统计", "已执行", executed, "次",
                "通过", passCount, "次", "失败", failCount, "次")
            break
        end
        failCount = failCount + 1
        lastFailReason = detail
        log.warn("app", "累计统计", "已执行", executed, "次",
            "通过", passCount, "次", "失败", failCount, "次", "最近失败", detail or "")
        if attempt < maxAttempts then
            log.info("app", "条件未满足，", retryMs, "ms 后进行第", attempt + 1, "/", maxAttempts, "次判断")
            sys.wait(retryMs)
        end
    end

    log.info("app", "========== t3x 烧录条件综合 ==========",
        "配置最多", maxAttempts, "次",
        "实际执行", executed, "次",
        "通过计数", passCount,
        "失败计数", failCount,
        "最终结果", finalOk and "通过" or "拒绝")
    if finalOk then
        log.info("app", "综合结论: 允许进入烧录", "电量", lastPassPct, "%")
        return true, lastPassPct
    end
    log.warn("app", "综合结论: 拒绝进入烧录", "最近原因", lastFailReason or "未知")
    return false, lastFailReason
end

local function shutdownServicesForT3xBurn(cfg)
    cfg = cfg or _G.T3X_BURN_CFG or {}
    _G.T3X_BURN_MODE_ACTIVE = true
    state.t3x_burn_active = true
    state.heartbeat_paused = true

    log.info("app", "关停业务：准备 t3x 烧录")

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
                log.info("app", "烧录前 RNDIS 已停止")
            else
                log.warn("app", "烧录前 RNDIS 停止失败", rndisErr or "")
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
    log.info("app", "========== t3x 烧录模式（GPIO28 长按）==========")

    local ok, detail = checkT3xBurnPreconditions()
    if not ok then
        log.warn("app", "t3x 烧录条件不满足:", detail)
        if gpioModule and gpioModule.runLedPattern then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    log.info("app", "电量 OK", detail, "%")

    shutdownServicesForT3xBurn(cfg)

    if not t3xModule or not t3xModule.enterBootMode then
        log.warn("app", "t3x_ctrl 不可用")
        return false
    end
    if not t3xModule.enterBootMode() then
        log.warn("app", "t3x_ctrl.enterBootMode 失败")
        return false
    end
    log.info("app", "t3x 烧录时序已启动，等待协处理器就绪(GPIO_COPROC_READY 退出 BOOT)")
    return true
end

local function onPirMediaAction(action, uploadMode, quality)
    if _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
        return
    end
    log.info("app", "PIR动作", action, uploadMode, quality)
    if (uploadMode == "auto" or uploadMode == nil) and netModule and netModule.publishWakeup then
        netModule.publishWakeup()
    end
    if _G.MODULE_FLAGS.t3x_app ~= false then
        local sid = (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
        host_uart.notify_host(sid, 0)
    elseif t3xModule then
        sys.taskInit(function() t3xModule.wake() end)
    end
end

local function onPirStopRecording(reason, uploadMode, quality)
    log.info("app", "PIR停录", reason)
    if netModule and netModule.publishPirRecordStop then
        netModule.publishPirRecordStop(reason, uploadMode, quality)
    end
    if _G.MODULE_FLAGS.t3x_wakeup and (_G.MODULE_FLAGS.t3x_app ~= false) then
        local sid = (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
        host_uart.notify_host(sid, 0)
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
        if state.usb_insert_tick > 0 then
            local elapsed = nowMs() - state.usb_insert_tick
            if _G.APP_RUNTIME.power_status == 1 and elapsed < USB_PWRKEY_GRACE_MS then
                log.warn("app", "USB刚插入", elapsed, "ms，忽略误触关机")
                return
            end
        end
        onPowerOff()
    end)
    sys.subscribe(E.GPIO_BOOTKEY_SHORT, function()
        log.info("app", "BOOT键短按")
    end)
    sys.subscribe(E.GPIO_BOOTKEY_LONG, function()
        log.info("app", "BOOT键长按")
        sys.taskInit(tryEnterT3xBurnMode)
    end)
    sys.subscribe(E.GPIO_COPROC_READY, function()
        log.info("app", "协处理器就绪")
        if t3xModule then t3xModule.exitBootMode() end
        if pir_ctrl.resume and state.t3x_burn_active then
            pir_ctrl.resume()
            _G.T3X_BURN_MODE_ACTIVE = false
            state.t3x_burn_active = false
            state.heartbeat_paused = false
            log.info("app", "t3x 烧录流程结束，PIR 已恢复（MQTT/串口需按需重启或复位）")
        end
    end)
    sys.subscribe(E.GPIO_VBUS_CHANGED, function(powerStatus)
        log.info("app", "VBUS", powerStatus)
    end)
    sys.subscribe(E.GPIO_USB_DET_CHANGED, function(inserted)
        applyUsbInsertState(inserted == 1, "GPIO27")
        if inserted == 1 and _G.MODULE_FLAGS.rndis and not state.t3x_burn_active
            and type(usbRndis) == "table" and usbRndis.enableAsync then
            log.info("app", "USB 插入，重新启用 RNDIS（修复 PC 网卡媒体断开）")
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
        log.info("app", "CHG_STATE GPIO17", charging == 1 and "充电中" or "未充电/充满",
            "（充电板：充电=CHG_RED 硬件红灯，充满=CHG_BLUE 硬件蓝灯）")
        if state.mqtt_started and netModule and netModule.publishStatus and _G.APP_RUNTIME.online_status == 1 then
            netModule.publishStatus()
        end
    end)

    sys.subscribe("BATTERY_UPDATE", function(pct, mv)
        log.info("app", "电量", pct, "%", mv, "mV",
            "（模组LED：>70%蓝常亮，20~70%蓝闪，<20%红闪）")
        if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
            battery_guard.onBatteryUpdate(pct, mv)
        end
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
        log.info("app", "电量模块", "vbat", "v2-divider")
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
        if state.heartbeat_paused or _G.T3X_BURN_MODE_ACTIVE or state.t3x_burn_active then
            return
        end
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

function start(gpio, net, t3x_ctrl)
    if started then
        log.warn("app", "已启动")
        return false
    end
    if led.isBatStatBreathTestEnabled() then
        led.startBatStatBreathTest()
        started = true
        log.info("app", "BAT_STAT_LED 测试模式，已跳过业务启动")
        return true
    end
    gpioModule, netModule, t3xModule = gpio, net, t3x_ctrl

    log.info("app", "========== 应用启动 ==========")
    log.info("app", "栈", json.encode(_G.APP_STACK or {}))
    logImeiBanner()

    setupEventHandlers()
    if _G.MODULE_FLAGS.battery_guard ~= false and type(battery_guard) == "table" then
        battery_guard.start({
            on_enter_low_power = onEnterLowPower,
            on_exit_low_power = onExitLowPower,
            on_power_off = onPowerOff,
            wake_t3x = function()
                if t3xModule and t3xModule.wake then
                    sys.taskInit(function() t3xModule.wake() end)
                end
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
