--- 模块功能：LED 通用控制库，参考根目录 lib/led.lua 设计
-- @module led
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
local _modname = ...
local _G_direct = _ENV
_G_direct[_modname] = _G_direct[_modname] or {}
module(_modname, package.seeall)
_G[_modname] = _M

local state = {
    call_count = 0,
    last_action = nil,
    last_ok = nil,
    last_light = nil,
    last_dark = nil,
    last_count = nil,
    last_gap = nil,
}

local function traceLed(...)
    if _G.led_trace_enable == true then
        print("LED_LIB", ...)
    end
end

local function setLevel(ledPin, level)
    if not ledPin then
        return false
    end

    ledPin(level == 1 and 1 or 0)
    return true
end

function setPair(redPin, bluePin, redLevel, blueLevel)
    state.call_count = state.call_count + 1
    state.last_action = "setPair"

    local updated = false
    if setLevel(redPin, redLevel or 0) then
        updated = true
    end
    if setLevel(bluePin, blueLevel or 0) then
        updated = true
    end

    state.last_ok = updated
    return updated
end

function turnOff(redPin, bluePin)
    return setPair(redPin, bluePin, 0, 0)
end

-- dual 红蓝灯效见 archive/slim/lib/led_dual.lua（门球 single_blue 不编入 lib/）

local function dualStub(name)
    state.call_count = state.call_count + 1
    state.last_action = name
    state.last_ok = false
end

function runSteps(_redPin, _bluePin, _steps, _rounds)
    dualStub("runSteps")
    return false
end

function runStartupSequence(redPin, bluePin, _startupConfig)
    dualStub("runStartupSequence")
    turnOff(redPin, bluePin)
    return false
end

function runSinglePattern(redPin, bluePin, _activePin, _patternConfig)
    dualStub("runSinglePattern")
    turnOff(redPin, bluePin)
    return false
end

function runBatteryPattern(redPin, bluePin, _batteryPercent, batteryConfig)
    dualStub("runBatteryPattern")
    turnOff(redPin, bluePin)
    local battery = type(batteryConfig) == "table" and batteryConfig or {}
    sys.wait(battery.unknown_hold or 0)
    return "unknown"
end

--- 闪烁指示灯
-- @function ledPin 由 pins.setup 返回的 LED 控制函数
-- @number light 亮灯时间，单位 ms
-- @number dark 灭灯时间，单位 ms
-- @return boolean 参数有效时返回 true
-- @usage led.blinkPwm(ledPin, 500, 500)
-- @usage 调用函数需要使用任务支持
function blinkPwm(ledPin, light, dark)
    state.call_count = state.call_count + 1
    state.last_action = "blinkPwm"
    state.last_light = light
    state.last_dark = dark
    if not ledPin then
        state.last_ok = false
        return false
    end

    traceLed("blinkPwm:begin", light or 0, dark or 0)
    traceLed("blinkPwm:on:before")
    ledPin(1)
    traceLed("blinkPwm:on:after")
    sys.wait(light or 0)
    traceLed("blinkPwm:off:before")
    ledPin(0)
    traceLed("blinkPwm:off:after")
    sys.wait(dark or 0)
    state.last_ok = true
    traceLed("blinkPwm:end")
    return true
end

function levelLed(_ledPin, _bl, _bd, _cnt, _gap)
    dualStub("levelLed")
    return false
end

function breateLed(_ledPin)
    dualStub("breateLed")
    return false
end

function getState()
    return state
end

-- ============================================================
-- 单蓝灯（GPIO21）：开机 / 电量 / MQTT 联网
-- ============================================================

function runBlueStartup(bluePin, startupCfg)
    state.last_action = "runBlueStartup"
    local s = type(startupCfg) == "table" and startupCfg or {}
    if s.enabled == false or not bluePin then
        state.last_ok = false
        return false
    end
    local n = tonumber(s.blinks) or 3
    local light = tonumber(s.light_ms) or 300
    local dark = tonumber(s.dark_ms) or 300
    setLevel(bluePin, 0)
    for _ = 1, n do
        blinkPwm(bluePin, light, dark)
    end
    state.last_ok = true
    return true
end

--- 单蓝灯一轮（简化：快闪=低电，慢闪=未联网，常亮=正常）
-- st: battery_percent, online_status, mqtt_enabled, usb_inserted, charging
function runSimpleBlueCycle(bluePin, st, cfg)
    state.last_action = "runSimpleBlueCycle"
    if not bluePin then
        state.last_ok = false
        return "none"
    end

    st = type(st) == "table" and st or {}
    cfg = type(cfg) == "table" and cfg or {}

    local pct = tonumber(st.battery_percent)
    local online = st.online_status == 1
    local mqttOn = st.mqtt_enabled ~= false
    local lowPct = tonumber(cfg.low_percent) or 20
    local fastMs = tonumber(cfg.low_blink_ms) or 400
    local slowMs = tonumber(cfg.offline_blink_ms) or 1000
    local okHold = tonumber(cfg.ok_hold_ms) or 5000
    local checkNet = cfg.check_network ~= false

    local chargingActive = cfg.suppress_low_when_charging ~= false
        and st.usb_inserted
        and (st.charging == 1 or st.charging == true)

    setLevel(bluePin, 0)

    -- 1 低电：快闪（充电中且 suppress 开启则跳过）
    if pct ~= nil and pct <= lowPct and not chargingActive then
        local n = tonumber(cfg.low_blinks_per_round) or 6
        for _ = 1, n do
            blinkPwm(bluePin, fastMs, fastMs)
        end
        state.last_ok = true
        return "low"
    end

    -- 2 未联网：慢闪
    if checkNet and mqttOn and not online then
        blinkPwm(bluePin, slowMs, slowMs)
        state.last_ok = true
        return chargingActive and "charging_offline" or "offline"
    end

    -- 3 正常：常亮
    if pct == nil and not chargingActive then
        sys.wait(tonumber(cfg.unknown_hold_ms) or 3000)
        state.last_ok = true
        return "unknown"
    end

    setLevel(bluePin, 1)
    sys.wait(okHold)
    state.last_ok = true
    return chargingActive and "charging_ok" or "ok"
end

--- 兼容旧名
function runUnifiedBlueCycle(bluePin, st, cfg)
    return runSimpleBlueCycle(bluePin, st, cfg)
end

-- ============================================================
-- BAT_STAT_LED 上电调试（GPIO21 低电平点亮，1s 翻转）
-- ============================================================

--- 设为 true 时仅跑蓝灯测试；由 app.start 检测并跳过其余业务
_M.BAT_STAT_LED_BREATH_TEST = false

local BREATH_INTERVAL_MS = 1000
local breathStarted = false

function isBatStatBreathTestEnabled()
    return _M.BAT_STAT_LED_BREATH_TEST == true
end

function startBatStatBreathTest()
    if breathStarted then
        return false
    end
    require "config"
    local gpio_util = require "gpio_util"
    local gout = _G.GPIO_OUT or {}
    local blue = gout.bat_stat_led
    local red = gout.led_red
    if not blue or not blue.pin then
        log.warn("led", "bat_stat_led 未配置")
        return false
    end

    gpio_util.setup_output(blue)
    log.info("led", "bat_stat_led test", "pin", blue.pin,
        "off", blue.init_level, "on", blue.on_level)

    local tick = 0
    local lit = false
    sys.timerLoopStart(function()
        tick = tick + 1
        lit = not lit
        gpio_util.set_output(blue, lit)
        log.info("led", "bat_stat_led", blue.pin, lit and "ON" or "OFF", "tick", tick)
    end, BREATH_INTERVAL_MS)

    if red and red.pin and red.enabled ~= false then
        gpio_util.setup_output(red)
        local redLit = false
        sys.timerLoopStart(function()
            redLit = not redLit
            gpio_util.set_output(red, redLit)
        end, BREATH_INTERVAL_MS)
        log.info("led", "led_red 同步翻转 pin", red.pin)
    end

    breathStarted = true
    return true
end

if type(_M) == "table" then _G[_modname] = _M end
return _M