-- ================================================================
-- Filename : led_ctrl.lua
-- Module   : LED 指示：蓝/红 LED 模式（开机序列、低电、离线），读充电态
-- Arch     : doc/modules/PERIPHERAL_LED_FLOW.md
-- ================================================================

require "sys"
require "config"

local loader = require "module_loader"
local rntmPwr = require "runtime_power"
local gpio_util = require "gpio_util"
local cfgm = require "config_manager"
local _M = { _VERSION = "1.2.0" }
module(..., package.seeall)

local LED_CONFIG = {
    bluePin = 21,
    startup = { enabled = true, blinks = 2, light_ms = 400, dark_ms = 400 },
    low_percent = 20,
    low_blink_ms = 400,
    offline_blink_ms = 1000,
    ok_hold_ms = 5000,
    check_network = true,
    suppress_low_when_charging = true,
}

local bluePin, redPinRaw
local started = false
local running = false
local lastPattern = ""
local evtRefs = {}

local REFRESH_EVENT_KEYS = {
    "MQTT_CONNECTED", "MQTT_OFFLINE", "BATTERY_UPDATE",
    "GPIO_USB_DET_CHANGED", "GPIO_CHG_STATE_CHANGED",
}

local function applyCfg()
    local fromLed = cfgm.get("LED_CFG")
    if type(fromLed.startup) == "table" then
        cfgm.merge(LED_CONFIG.startup, fromLed.startup)
    end
    cfgm.merge(LED_CONFIG, fromLed, {
        "low_percent", "low_blink_ms", "low_blinks_per_round",
        "offline_blink_ms", "ok_hold_ms", "check_network", "unknown_hold_ms",
        "suppress_low_when_charging",
    })
    if type(fromLed.network) == "table" and fromLed.network.enabled == false then
        LED_CONFIG.check_network = false
    end
    local batLed = cfgm.get("BATTERY_CFG").led
    if batLed and batLed.medium_threshold and not LED_CONFIG.low_percent then
        LED_CONFIG.low_percent = batLed.medium_threshold
    end
end

applyCfg()

local function setBlue(on)
    if bluePin then bluePin(on == 1 and 1 or 0) end
end

local function blinkBlue(light, dark)
    setBlue(1)
    sys.wait(light or 0)
    setBlue(0)
    sys.wait(dark or 0)
end

local function runtimeSnapshot()
    return {
        battery_percent = rntmPwr.getBatteryPercent(),
        online_status = rntmPwr.isOnline() and 1 or 0,
        mqtt_enabled = loader.enabled("mqtt"),
        usb_inserted = rntmPwr.isUsbInserted(),
        charging = rntmPwr.isCharging(),
    }
end

local function chargingActive(st, cfg)
    return cfg.suppress_low_when_charging ~= false
        and st.usb_inserted
        and (st.charging == 1 or st.charging == true)
end

local function runOneCycle(st, cfg)
    local pct = tonumber(st.battery_percent)
    local online = st.online_status == 1
    local mqttOn = st.mqtt_enabled ~= false
    local chrgActv = chargingActive(st, cfg)
    setBlue(0)
    if pct ~= nil and pct <= (tonumber(cfg.low_percent) or 20) and not chrgActv then
        local n = tonumber(cfg.low_blinks_per_round) or 6
        local ms = tonumber(cfg.low_blink_ms) or 400
        for _ = 1, n do blinkBlue(ms, ms) end
        return "low"
    end
    if cfg.check_network ~= false and mqttOn and not online then
        local ms = tonumber(cfg.offline_blink_ms) or 1000
        blinkBlue(ms, ms)
        return chrgActv and "charging_offline" or "offline"
    end
    if pct == nil and not chrgActv then
        sys.wait(tonumber(cfg.unknown_hold_ms) or 3000)
        return "unknown"
    end
    setBlue(1)
    sys.wait(tonumber(cfg.ok_hold_ms) or 5000)
    return chrgActv and "charging_ok" or "ok"
end

local function ledTask()
    sys.taskInit(function()
        local s = LED_CONFIG.startup or {}
        if s.enabled ~= false and bluePin then
            setBlue(0)
            local n = tonumber(s.blinks) or 2
            for _ = 1, n do blinkBlue(s.light_ms or 400, s.dark_ms or 400) end
        end
        while running do
            lastPattern = runOneCycle(runtimeSnapshot(), LED_CONFIG)
        end
    end)
end

local function setupBlue(gout, pinNum)
    local entry = gout.bat_stat_led
    local raw
    if entry and entry.pin ~= nil and entry.pin == pinNum then
        raw = gpio_util.setupOutput(entry)
        local onLvl = entry.on_level ~= nil and entry.on_level or 0
        local offLvl = entry.init_level ~= nil and entry.init_level or 1
        bluePin = function(logical)
            raw((logical == 1 or logical == true) and onLvl or offLvl)
        end
        return
    end
    raw = gpio.setup(pinNum, 1)
    bluePin = function(logical) raw(logical == 1 and 0 or 1) end
end

local function startEvtRefresh()
    local E = _G.APP_EVENTS
    if not E then return end
    local function bump(_) lastPattern = "" end
    for i = 1, #REFRESH_EVENT_KEYS do
        local key = REFRESH_EVENT_KEYS[i]
        local name = E[key] or (key == "BATTERY_UPDATE" and "BATTERY_UPDATE" or nil)
        if name then
            evtRefs[#evtRefs + 1] = { name, bump }
            sys.subscribe(name, bump)
        end
    end
end

local function stopEvtRefresh()
    for i = 1, #evtRefs do
        sys.unsubscribe(evtRefs[i][1], evtRefs[i][2])
    end
    evtRefs = {}
end

function _M.start(cfg)
    if started then return true end
    if cfg then for k, v in pairs(cfg) do LED_CONFIG[k] = v end end
    applyCfg()
    local gout = cfgm.get("GPIO_OUT")
    local pinNum = LED_CONFIG.bluePin or 21
    setupBlue(gout, pinNum)
    local re = gout.led_red
    if re and re.enabled ~= false and re.pin ~= nil then
        redPinRaw = gpio_util.setupOutput(re)
    end
    if not bluePin then return false end
    setBlue(0)
    stopEvtRefresh()
    startEvtRefresh()
    running = true
    ledTask()
    started = true
    return true
end

function _M.stop()
    if not started then return true end
    started = false
    running = false
    stopEvtRefresh()
    setBlue(0)
    return true
end

function _M.setLed(_red, blue)
    setBlue(blue)
end

function _M.turnOff()
    setBlue(0)
end

function _M.blinkRed()
    if not redPinRaw then return end
    for _ = 1, 3 do
        redPinRaw(1)
        sys.wait(500)
        redPinRaw(0)
        sys.wait(500)
    end
end

function _M.blinkBlue()
    if not bluePin then return end
    for _ = 1, 3 do blinkBlue(500, 500) end
end

function _M.getState()
    return { started = started, mode = "1bl", last_pattern = lastPattern }
end

function _M.getConfig()
    return LED_CONFIG
end

return _M
