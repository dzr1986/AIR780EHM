-- @module gpioInput

require "sys"
module(..., package.seeall)

local started = false
local lastPullupLevel = nil
local lastPulldownLevel = nil
local APP_LIB_CONFIG = _G.APP_LIB_CONFIG or {}

local function resolve(value)
    if type(value) == "function" then
        return value()
    end
    return value
end

local config = {
    pullup_pin = function()
        return ((APP_LIB_CONFIG.gpioInput or {}).pullup_pin and resolve((APP_LIB_CONFIG.gpioInput or {}).pullup_pin)) or _G.gpio_input_pullup_io_number or 7
    end,
    pulldown_pin = function()
        return ((APP_LIB_CONFIG.gpioInput or {}).pulldown_pin and resolve((APP_LIB_CONFIG.gpioInput or {}).pulldown_pin)) or _G.netstatus_io_number or 27
    end,
    interval = 1000,
    debounce = 50,
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
            config[key] = value
        end
    end
    return config
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function start(newConfig)
    if started then
        return false
    end

    local runtimeConfig = mergeConfig(newConfig)
    started = true
    sys.taskInit(function()
        local pullupPin = resolve(runtimeConfig.pullup_pin)
        local pulldownPin = resolve(runtimeConfig.pulldown_pin)
        local interval = resolve(runtimeConfig.interval)
        gpio.setup(pullupPin, nil, gpio.PULLUP)
        gpio.debounce(pullupPin, runtimeConfig.debounce)
        gpio.setup(pulldownPin, nil, gpio.PULLDOWN)
        gpio.debounce(pulldownPin, runtimeConfig.debounce)

        while true do
            lastPullupLevel = gpio.get(pullupPin)
            lastPulldownLevel = gpio.get(pulldownPin)
            log.info("GPIO", pullupPin, "电平", lastPullupLevel)
            log.info("GPIO", pulldownPin, "电平", lastPulldownLevel)
            sys.wait(interval)
        end
    end)

    return true
end

function getState()
    return {
        started = started,
        pullup_pin = resolve(config.pullup_pin),
        pulldown_pin = resolve(config.pulldown_pin),
        pullup_level = lastPullupLevel,
        pulldown_level = lastPulldownLevel,
    }
end
