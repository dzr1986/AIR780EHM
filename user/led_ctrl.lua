--- LED 控制模块
-- @module led_ctrl
-- 本板默认 single_blue：仅 GPIO21 BAT_STAT_LED（开机/电量/MQTT 联网）
-- 见 doc/LED_INDICATORS.md
require "sys"
require "config"
local led = require "led"
local gpio_util = require "gpio_util"
local _M = { _VERSION = "1.1.0" }
module(..., package.seeall)
_G[_M] = _M

local LOG_TAG = "led_ctrl"

local LED_CONFIG = {
    mode = "single_blue",
    redPin = nil,
    bluePin = 21,
    startupSequence = nil,
    battery = {
        high_threshold = 70,
        medium_threshold = 20,
        high_hold = 10000,
        medium_light = 1000,
        medium_dark = 1000,
        medium_count = 5,
        medium_gap = 1000,
        low_light = 250,
        low_dark = 250,
        low_count = 20,
        low_gap = 1000,
        unknown_hold = 3000,
        fallback_hold = 1000,
    },
    startup = {
        enabled = true,
        blinks = 2,
        light_ms = 400,
        dark_ms = 400,
    },
    low_percent = 20,
    low_blink_ms = 400,
    offline_blink_ms = 1000,
    ok_hold_ms = 5000,
    check_network = true,
    suppress_low_when_charging = true,
}

local ledPins = { red = nil, blue = nil }
local ledEntries = { red = nil, blue = nil }
local started = false
local lastPattern = ""

local function ledCfg()
    return _G.LED_CFG or {}
end

local function isRedEnabled()
    local gout = _G.GPIO_OUT or {}
    local e = gout.led_red
    if e and e.enabled == false then
        return false
    end
    if ledCfg().red_enabled == false then
        return false
    end
    return LED_CONFIG.mode == "dual" and LED_CONFIG.redPin ~= nil
end

local function isSingleBlueMode()
    if LED_CONFIG.mode == "single_blue" then
        return true
    end
    if LED_CONFIG.mode == "dual" then
        return false
    end
    return not isRedEnabled()
end

local function applyConfigs()
    local fromBat = (_G.BATTERY_CFG or {}).led
    if type(fromBat) == "table" then
        for k, v in pairs(fromBat) do
            LED_CONFIG.battery[k] = v
        end
    end
    local fromLed = ledCfg()
    if type(fromLed) == "table" then
        if fromLed.mode then LED_CONFIG.mode = fromLed.mode end
        if type(fromLed.startup) == "table" then
            for k, v in pairs(fromLed.startup) do
                LED_CONFIG.startup[k] = v
            end
        end
        for _, k in ipairs({
            "low_percent", "low_blink_ms", "low_blinks_per_round",
            "offline_blink_ms", "ok_hold_ms", "check_network", "unknown_hold_ms",
            "suppress_low_when_charging",
        }) do
            if fromLed[k] ~= nil then
                LED_CONFIG[k] = fromLed[k]
            end
        end
        if type(fromLed.network) == "table" and fromLed.network.enabled == false then
            LED_CONFIG.check_network = false
        end
    end
end

applyConfigs()

local function makeLedWriter(entry, rawHdl)
    if not rawHdl then
        return nil
    end
    if not entry then
        return function(logical)
            rawHdl(logical == 1 and 1 or 0)
        end
    end
    local offLv = entry.init_level
    local onLv = entry.on_level
    if offLv == nil then offLv = 0 end
    if onLv == nil then onLv = 1 end
    return function(logical)
        rawHdl((logical == 1 or logical == true) and onLv or offLv)
    end
end

local function ledOff()
    led.turnOff(ledPins.red, ledPins.blue)
end

local function ledSet(red, blue)
    led.setPair(ledPins.red, ledPins.blue, red, blue)
end

local function readChargeFlags()
    local rt = _G.APP_RUNTIME or {}
    local usb = false
    local charging = false
    if _G.MODULE_FLAGS.charge ~= false then
        local ok, uc = pcall(require, "usb_charge")
        if ok and type(uc) == "table" then
            if uc.isUsbInserted then
                usb = uc.isUsbInserted() and true or false
            end
            if uc.isCharging then
                charging = uc.isCharging() == 1
            end
        end
    end
    if not usb and rt.power_status == 1 then
        usb = true
    end
    return usb, charging
end

local function runtimeSnapshot()
    local rt = _G.APP_RUNTIME or {}
    local flags = _G.MODULE_FLAGS or {}
    local usb, charging = readChargeFlags()
    return {
        battery_percent = rt.battery_percent,
        online_status = rt.online_status,
        mqtt_enabled = flags.mqtt ~= false,
        usb_inserted = usb,
        charging = charging,
    }
end

local function simpleCycleCfg()
    local batLed = (_G.BATTERY_CFG or {}).led or {}
    return {
        low_percent = LED_CONFIG.low_percent or batLed.medium_threshold or 20,
        low_blink_ms = LED_CONFIG.low_blink_ms,
        low_blinks_per_round = LED_CONFIG.low_blinks_per_round,
        offline_blink_ms = LED_CONFIG.offline_blink_ms,
        ok_hold_ms = LED_CONFIG.ok_hold_ms,
        check_network = LED_CONFIG.check_network,
        unknown_hold_ms = LED_CONFIG.unknown_hold_ms,
        suppress_low_when_charging = LED_CONFIG.suppress_low_when_charging,
    }
end

local PATTERN_LABEL = {
    ok = "正常-常亮",
    offline = "未联网-慢闪",
    low = "低电-快闪",
    unknown = "电量未知",
    charging_ok = "充电中-常亮",
    charging_offline = "充电中-慢闪(联网)",
}

local function ledStatusSingleBlueTask()
    sys.taskInit(function()
        if LED_CONFIG.startup and LED_CONFIG.startup.enabled ~= false then
            led.runBlueStartup(ledPins.blue, LED_CONFIG.startup)
        end
        while true do
            local pattern = led.runSimpleBlueCycle(ledPins.blue, runtimeSnapshot(), simpleCycleCfg())
            if pattern ~= lastPattern then
                lastPattern = pattern
                local usb, chg = readChargeFlags()
                log.info(LOG_TAG, "蓝灯", PATTERN_LABEL[pattern] or pattern,
                    "bat=" .. tostring((_G.APP_RUNTIME or {}).battery_percent),
                    "online=" .. tostring((_G.APP_RUNTIME or {}).online_status),
                    "usb=" .. tostring(usb), "chg=" .. tostring(chg))
            end
        end
    end)
end

local function ledStatusDualTask()
    sys.taskInit(function()
        if LED_CONFIG.startupSequence then
            led.runStartupSequence(ledPins.red, ledPins.blue, LED_CONFIG.startupSequence)
        end
        while true do
            local batteryPercent = tonumber((_G.APP_RUNTIME or {}).battery_percent) or -1
            if LED_CONFIG.battery then
                led.runBatteryPattern(ledPins.red, ledPins.blue, batteryPercent, LED_CONFIG.battery)
            else
                ledOff()
                sys.wait(3000)
            end
        end
    end)
end

local function setupEventRefresh()
    local E = _G.APP_EVENTS
    if not E then
        return
    end
    local function bump(_)
        lastPattern = ""
    end
    sys.subscribe(E.MQTT_CONNECTED, bump)
    sys.subscribe(E.MQTT_OFFLINE, bump)
    sys.subscribe("BATTERY_UPDATE", bump)
    if E.GPIO_USB_DET_CHANGED then
        sys.subscribe(E.GPIO_USB_DET_CHANGED, bump)
    end
    if E.GPIO_CHG_STATE_CHANGED then
        sys.subscribe(E.GPIO_CHG_STATE_CHANGED, bump)
    end
end

function _M.start(cfg)
    if started then return false end
    if cfg then
        for k, v in pairs(cfg) do LED_CONFIG[k] = v end
    end
    applyConfigs()

    local gout = _G.GPIO_OUT or {}
    if isRedEnabled() and LED_CONFIG.redPin then
        local e = gout.led_red
        local raw
        if e and e.pin == LED_CONFIG.redPin then
            ledEntries.red = e
            raw = gpio_util.setup_output(e)
        else
            raw = gpio.setup(LED_CONFIG.redPin, 0)
        end
        ledPins.red = makeLedWriter(ledEntries.red, raw)
    end

    local bluePinNum = LED_CONFIG.bluePin or 21
    local e = gout.bat_stat_led
    local raw
    if e and e.pin == bluePinNum then
        ledEntries.blue = e
        raw = gpio_util.setup_output(e)
    else
        raw = gpio.setup(bluePinNum, 1)
    end
    ledPins.blue = makeLedWriter(ledEntries.blue or { init_level = 1, on_level = 0 }, raw)

    if not ledPins.blue then
        log.warn(LOG_TAG, "BAT_STAT_LED 未初始化")
        return false
    end

    ledOff()
    setupEventRefresh()

    if isSingleBlueMode() then
        log.info(LOG_TAG, "single_blue GPIO21 常亮/慢闪/快闪")
        ledStatusSingleBlueTask()
    else
        log.info(LOG_TAG, "dual GPIO20+21")
        LED_CONFIG.startupSequence = LED_CONFIG.startupSequence or {
            enabled = true,
            rounds = 1,
            steps = {
                { red = 1, blue = 1, duration = 200 },
                { red = 1, blue = 0, duration = 200 },
                { red = 0, blue = 1, duration = 200 },
            },
            idle_after = 0,
        }
        ledStatusDualTask()
    end

    started = true
    return true
end

function _M.setLed(red, blue)
    if isSingleBlueMode() then
        if ledPins.blue then
            ledPins.blue(blue == 1 and 1 or 0)
        end
        return
    end
    ledSet(red, blue)
end

function _M.turnOff()
    ledOff()
end

function _M.blinkRed()
    if not ledPins.red then
        return
    end
    for i = 1, 3 do
        ledPins.red(1)
        sys.wait(500)
        ledPins.red(0)
        sys.wait(500)
    end
end

function _M.blinkBlue()
    if not ledPins.blue then
        return
    end
    for i = 1, 3 do
        ledPins.blue(1)
        sys.wait(500)
        ledPins.blue(0)
        sys.wait(500)
    end
end

function _M.getState()
    return {
        started = started,
        mode = isSingleBlueMode() and "single_blue" or "dual",
        last_pattern = lastPattern,
    }
end

function _M.getConfig()
    return LED_CONFIG
end

return _M
