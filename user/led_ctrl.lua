--- LED 控制模块
-- @module led_ctrl
-- 管理红蓝LED指示灯，支持启动序列和电量指示
require "sys"
require "config"
local led = require "led"
local gpio_util = require "gpio_util"
local _M = { _VERSION = "1.0.0" }
module(..., package.seeall)
_G[_M] = _M

--[[
LED_CONFIG: LED配置表
  redPin        - 红色LED引脚号
  bluePin       - 蓝色LED引脚号
  startupSequence - 开机启动序列配置
  battery       - 电量指示配置
]]
local LED_CONFIG = {
    redPin = 20,
    bluePin = 21,
    startupSequence = {
        enabled = true,
        rounds = 1,
        steps = {
            { red = 1, blue = 1, duration = 200 },
            { red = 1, blue = 0, duration = 200 },
            { red = 0, blue = 1, duration = 200 },
        },
        idle_after = 0,
    },
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
}

local function applyBatteryLedCfg()
    local from = (_G.BATTERY_CFG or {}).led
    if type(from) ~= "table" then
        return
    end
    for k, v in pairs(from) do
        LED_CONFIG.battery[k] = v
    end
end

applyBatteryLedCfg()

local ledPins = { red = nil, blue = nil }
local ledEntries = { red = nil, blue = nil }
local started = false

--- 逻辑 1=亮 / 0=灭 → 按 GPIO_OUT 的 on_level、init_level 写脚
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

-- 设置LED状态
-- @param red 红灯状态(0/1)
-- @param blue 蓝灯状态(0/1)
local function ledSet(red, blue)
    led.setPair(ledPins.red, ledPins.blue, red, blue)
end

-- LED状态任务: 循环执行启动序列和电量指示
local function ledStatusTask()
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

--- 启动LED模块
-- @param cfg 自定义配置(可选)
-- @return true=成功, false=已启动
function _M.start(cfg)
    if started then return false end
    if cfg then
        for k, v in pairs(cfg) do LED_CONFIG[k] = v end
    end
    local gout = _G.GPIO_OUT or {}
    if LED_CONFIG.redPin then
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
    if LED_CONFIG.bluePin then
        local e = gout.bat_stat_led
        local raw
        if e and e.pin == LED_CONFIG.bluePin then
            ledEntries.blue = e
            raw = gpio_util.setup_output(e)
        else
            raw = gpio.setup(LED_CONFIG.bluePin, 1)
        end
        ledPins.blue = makeLedWriter(ledEntries.blue or { init_level = 1, on_level = 0 }, raw)
    end
    ledOff()
    ledStatusTask()
    started = true
    return true
end

--- 设置LED状态
function _M.setLed(red, blue)
    ledSet(red, blue)
end

--- 关闭LED
function _M.turnOff()
    ledOff()
end

--- 红灯闪烁3次
function _M.blinkRed()
    if ledPins.red then
        for i = 1, 3 do
            ledPins.red(1)
            sys.wait(500)
            ledPins.red(0)
            sys.wait(500)
        end
    end
end

--- 蓝灯闪烁3次
function _M.blinkBlue()
    if ledPins.blue then
        for i = 1, 3 do
            ledPins.blue(1)
            sys.wait(500)
            ledPins.blue(0)
            sys.wait(500)
        end
    end
end

--- 获取模块状态
function _M.getState()
    return { started = started }
end

--- 获取配置
function _M.getConfig()
    return LED_CONFIG
end

return _M
