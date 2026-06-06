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

function runSteps(redPin, bluePin, steps, rounds)
    state.call_count = state.call_count + 1
    state.last_action = "runSteps"
    state.last_count = rounds
    if type(steps) ~= "table" or #steps == 0 then
        state.last_ok = false
        return false
    end

    local totalRounds = tonumber(rounds) or 1
    if totalRounds < 1 then
        state.last_ok = false
        return false
    end

    traceLed("runSteps:begin", totalRounds, #steps)
    for _ = 1, totalRounds do
        for _, step in ipairs(steps) do
            setPair(redPin, bluePin, step.red, step.blue)
            sys.wait(step.duration or 0)
        end
    end
    state.last_ok = true
    traceLed("runSteps:end")
    return true
end

function runStartupSequence(redPin, bluePin, startupConfig)
    state.call_count = state.call_count + 1
    state.last_action = "runStartupSequence"

    local startup = type(startupConfig) == "table" and startupConfig or {}
    if startup.enabled ~= true or tonumber(startup.rounds) == nil or tonumber(startup.rounds) < 1 then
        turnOff(redPin, bluePin)
        state.last_ok = false
        return false
    end

    if not redPin and not bluePin then
        state.last_ok = false
        return false
    end

    runSteps(redPin, bluePin, startup.steps, startup.rounds)
    turnOff(redPin, bluePin)
    if (startup.idle_after or 0) > 0 then
        sys.wait(startup.idle_after)
    end
    state.last_ok = true
    return true
end

function runSinglePattern(redPin, bluePin, activePin, patternConfig)
    state.call_count = state.call_count + 1
    state.last_action = "runSinglePattern"

    local pattern = type(patternConfig) == "table" and patternConfig or {}
    if not activePin then
        state.last_ok = false
        return false
    end

    turnOff(redPin, bluePin)
    state.last_ok = blinkPwm(activePin, pattern.light, pattern.dark)
    return state.last_ok
end

function runBatteryPattern(redPin, bluePin, batteryPercent, batteryConfig)
    state.call_count = state.call_count + 1
    state.last_action = "runBatteryPattern"

    local battery = type(batteryConfig) == "table" and batteryConfig or {}
    if batteryPercent == nil then
        turnOff(redPin, bluePin)
        sys.wait(battery.unknown_hold or 0)
        state.last_ok = true
        return "unknown"
    end

    if batteryPercent > (battery.high_threshold or 0) then
        setPair(redPin, bluePin, 0, 1)
        sys.wait(battery.high_hold or 0)
        state.last_ok = true
        return "high"
    end

    turnOff(redPin, bluePin)
    if batteryPercent > (battery.medium_threshold or 0) then
        if bluePin then
            state.last_ok = levelLed(bluePin, battery.medium_light, battery.medium_dark, battery.medium_count, battery.medium_gap)
        else
            sys.wait(battery.fallback_hold or 0)
            state.last_ok = false
        end
        return "medium"
    end

    if redPin then
        state.last_ok = levelLed(redPin, battery.low_light, battery.low_dark, battery.low_count, battery.low_gap)
    else
        sys.wait(battery.fallback_hold or 0)
        state.last_ok = false
    end
    return "low"
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

--- 等级指示灯
-- @function ledPin 由 pins.setup 返回的 LED 控制函数
-- @number bl 每次亮灯时间，单位 ms
-- @number bd 每次灭灯时间，单位 ms
-- @number cnt 重复次数
-- @number gap 一轮结束后的间隔时间，单位 ms
-- @return boolean 参数有效时返回 true
-- @usage led.levelLed(ledPin, 200, 200, 4, 1000)
-- @usage 调用函数需要使用任务支持
function levelLed(ledPin, bl, bd, cnt, gap)
    state.call_count = state.call_count + 1
    state.last_action = "levelLed"
    state.last_light = bl
    state.last_dark = bd
    state.last_count = cnt
    state.last_gap = gap
    if not (ledPin and bl and bd and cnt) then
        state.last_ok = false
        return false
    end

    traceLed("levelLed:begin", bl, bd, cnt, gap or 0)
    for _ = 1, cnt do
        blinkPwm(ledPin, bl, bd)
    end
    sys.wait(gap or 0)
    state.last_ok = true
    traceLed("levelLed:end")
    return true
end

--- 呼吸灯
-- @function ledPin 由 pins.setup 返回的 LED 控制函数
-- @return boolean 参数有效时返回 true
-- @usage led.breateLed(ledPin)
-- @usage 调用函数需要使用任务支持
function breateLed(ledPin)
    state.call_count = state.call_count + 1
    state.last_action = "breateLed"
    if not ledPin then
        state.last_ok = false
        return false
    end

    local bLighting, bDarking, ledPwm = false, true, 18
    if bLighting then
        for i = 1, ledPwm - 1 do
            ledPin(0)
            sys.wait(i)
            ledPin(1)
            sys.wait(ledPwm - i)
        end
        bLighting = false
        bDarking = true
        ledPin(0)
        sys.wait(700)
    end
    if bDarking then
        for i = 1, ledPwm - 1 do
            ledPin(0)
            sys.wait(ledPwm - i)
            ledPin(1)
            sys.wait(i)
        end
        bLighting = true
        bDarking = false
        ledPin(1)
        sys.wait(700)
    end
    state.last_ok = true
    return true
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