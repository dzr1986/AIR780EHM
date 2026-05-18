--- 模块功能：VBAT 采样与电量估算库
-- @module battery
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
local _modname = ...
local _G_direct = _ENV
_G_direct[_modname] = _G_direct[_modname] or {}
module(_modname, package.seeall)
_G[_modname] = _M

local taskStarted = false
local voltageMv, percent, consumptionRate = 0, 0, 0
local lastPercent, lastReadTime
local config = {
    channel = adc.CH_VBAT,
    interval = function()
        return _G.update_time
    end,
    event_name = "BATTERY_UPDATE",
}

local function resolveInterval()
    if type(config.interval) == "function" then
        return config.interval()
    end
    return config.interval
end

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

local function exportGlobals()
    _G.electricity = percent
    _G.vbat = voltageMv
    _G.battery_consumption_rate = tostring(consumptionRate)
end

local function calcPercent(voltage)
    if voltage >= _G.vbat_max then
        return 100
    end

    if voltage <= _G.vbat_min then
        return 1
    end

    local interval = (_G.vbat_max - _G.vbat_min) / 100
    local battery = (voltage - _G.vbat_min) / interval
    if battery < 1 then
        battery = 1
    end
    return math.floor(battery)
end

local function updateRate(currentPercent)
    local now = os.time()
    if lastPercent and lastReadTime then
        local timeDiffHours = (now - lastReadTime) / 3600
        local batteryDiff = lastPercent - currentPercent
        if timeDiffHours > 0 and batteryDiff > 0 then
            consumptionRate = math.floor((batteryDiff / timeDiffHours) * 10 + 0.5) / 10
        else
            consumptionRate = 0
        end
    end

    lastPercent = currentPercent
    lastReadTime = now
end

--- 配置电池采样参数
-- @param newConfig table 支持 channel、interval、event_name
-- @return table 当前配置
function configure(newConfig)
    return mergeConfig(newConfig)
end

--- 获取当前配置
-- @return table 当前配置
function getConfig()
    return config
end

local function batteryTask(runtimeConfig)
    local channel = runtimeConfig.channel
    if channel == nil or channel == 255 then
        log.warn("battery", "无效 ADC 通道，电池检测已跳过")
        return
    end
    adc.open(channel)

    while true do
        local rawVal, voltVal = adc.get(channel)
        if rawVal then
            voltageMv = voltVal or rawVal
            percent = calcPercent(voltageMv)
            updateRate(percent)
            exportGlobals()
            sys.publish(runtimeConfig.event_name, percent, voltageMv, consumptionRate)
        end
        sys.wait(resolveInterval())
    end
end

function start(newConfig)
    if taskStarted then
        return false
    end

    local runtimeConfig = mergeConfig(newConfig)
    taskStarted = true
    sys.taskInit(batteryTask, runtimeConfig)
    return true
end

function getVoltage()
    return voltageMv
end

function getPercent()
    return percent
end

function getConsumptionRate()
    return consumptionRate
end

--- 获取当前状态
-- @return table 当前运行状态
function getState()
    return {
        started = taskStarted,
        voltage = voltageMv,
        percent = percent,
        consumptionRate = consumptionRate,
        lastReadTime = lastReadTime,
    }
end
if type(_M) == "table" then _G[_modname] = _M end
return _M
