--- LED dual 模式（红+蓝电量灯效）；门球 single_blue 不需编入 lib/
-- 恢复：copy archive\slim\lib\led_dual.lua lib\led_dual.lua，config LED_CFG.mode=dual
-- @module led_dual

require "sys"
local led = require "led"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function traceLed(...)
    if _G.led_trace_enable == true then
        print("LED_DUAL", ...)
    end
end

function levelLed(ledPin, bl, bd, cnt, gap)
    if not (ledPin and bl and bd and cnt) then
        return false
    end
    traceLed("levelLed:begin", bl, bd, cnt, gap or 0)
    for _ = 1, cnt do
        led.blinkPwm(ledPin, bl, bd)
    end
    sys.wait(gap or 0)
    traceLed("levelLed:end")
    return true
end

function runSteps(redPin, bluePin, steps, rounds)
    if type(steps) ~= "table" or #steps == 0 then
        return false
    end
    local totalRounds = tonumber(rounds) or 1
    if totalRounds < 1 then
        return false
    end
    traceLed("runSteps:begin", totalRounds, #steps)
    for _ = 1, totalRounds do
        for _, step in ipairs(steps) do
            led.setPair(redPin, bluePin, step.red, step.blue)
            sys.wait(step.duration or 0)
        end
    end
    traceLed("runSteps:end")
    return true
end

function runStartupSequence(redPin, bluePin, startupConfig)
    local startup = type(startupConfig) == "table" and startupConfig or {}
    if startup.enabled ~= true or tonumber(startup.rounds) == nil or tonumber(startup.rounds) < 1 then
        led.turnOff(redPin, bluePin)
        return false
    end
    if not redPin and not bluePin then
        return false
    end
    runSteps(redPin, bluePin, startup.steps, startup.rounds)
    led.turnOff(redPin, bluePin)
    if (startup.idle_after or 0) > 0 then
        sys.wait(startup.idle_after)
    end
    return true
end

function runSinglePattern(redPin, bluePin, activePin, patternConfig)
    local pattern = type(patternConfig) == "table" and patternConfig or {}
    if not activePin then
        return false
    end
    led.turnOff(redPin, bluePin)
    return led.blinkPwm(activePin, pattern.light, pattern.dark)
end

function runBatteryPattern(redPin, bluePin, batteryPercent, batteryConfig)
    local battery = type(batteryConfig) == "table" and batteryConfig or {}
    if batteryPercent == nil then
        led.turnOff(redPin, bluePin)
        sys.wait(battery.unknown_hold or 0)
        return "unknown"
    end
    if batteryPercent > (battery.high_threshold or 0) then
        led.setPair(redPin, bluePin, 0, 1)
        sys.wait(battery.high_hold or 0)
        return "high"
    end
    led.turnOff(redPin, bluePin)
    if batteryPercent > (battery.medium_threshold or 0) then
        if bluePin then
            levelLed(bluePin, battery.medium_light, battery.medium_dark,
                battery.medium_count, battery.medium_gap)
        else
            sys.wait(battery.fallback_hold or 0)
        end
        return "medium"
    end
    if redPin then
        levelLed(redPin, battery.low_light, battery.low_dark,
            battery.low_count, battery.low_gap)
    else
        sys.wait(battery.fallback_hold or 0)
    end
    return "low"
end

function breateLed(ledPin)
    if not ledPin then
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
    return true
end

return _M
