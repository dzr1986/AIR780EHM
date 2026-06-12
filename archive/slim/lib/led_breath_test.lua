--- BAT_STAT_LED 上电调试（完整版；lib/led.lua 为桩）
-- 用法：led.BAT_STAT_LED_BREATH_TEST=true 且将本文件逻辑拷回 lib/led.lua
-- @module led_breath_test

require "sys"
require "config"

local gpio_util = require "gpio_util"

local BREATH_INTERVAL_MS = 1000

return function()
    local gout = _G.GPIO_OUT or {}
    local blue = gout.bat_stat_led
    local red = gout.led_red
    if not blue or not blue.pin then
        log.warn("led", "bat_stat_led missing")
        return false
    end

    gpio_util.setup_output(blue)
    log.info("led", "bat_stat test", blue.pin)

    local lit = false
    sys.timerLoopStart(function()
        lit = not lit
        gpio_util.set_output(blue, lit)
    end, BREATH_INTERVAL_MS)

    if red and red.pin and red.enabled ~= false then
        gpio_util.setup_output(red)
        local redLit = false
        sys.timerLoopStart(function()
            redLit = not redLit
            gpio_util.set_output(red, redLit)
        end, BREATH_INTERVAL_MS)
    end
    return true
end
