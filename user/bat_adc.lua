--- 电池采样业务：ADC 读电压 + 电量换算 + 周期上报事件
-- 业务层（user/）；依赖 lib/adc_lib、lib/bat_core（require，勿 require "adc"/"battery"）
-- @module bat_adc
-- @release 2026.5.20

require "sys"
require "config"

local adcLib = require "adc_lib"
local batCore = require "bat_core"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "bat_adc"
local taskStarted = false
local voltageMv, percent, consumptionRate = 0, 0, 0

local function getCfg()
    return _G.BATTERY_CFG or {}
end

local function sampleIntervalMs()
    local root = getCfg()
    return root.sample_interval_ms or (10 * 1000)
end

local function batteryTask()
    local channel = adcLib.getChannel()
    if not adcLib.open(channel) then
        log.warn(LOG_TAG, "ADC 不可用，跳过 BAT_ADC")
        return
    end

    log.info(LOG_TAG, "任务已启动", "channel", channel, "scale", adcLib.getMvScale())

    while true do
        local pinMv = adcLib.readPinMillivolts(channel)
        if pinMv then
            voltageMv = adcLib.pinToCellMillivolts(pinMv)
            percent = batCore.percentFromMillivolts(voltageMv)
            consumptionRate = batCore.updateConsumptionRate(percent)
            batCore.exportGlobals(percent, voltageMv, consumptionRate)
            sys.publish("BATTERY_UPDATE", percent, voltageMv, consumptionRate)
            log.info(LOG_TAG, "pin", pinMv, "mV cell", voltageMv, "mV", percent, "%")
        end
        sys.wait(sampleIntervalMs())
    end
end

function start()
    if taskStarted then
        return false
    end
    if type(adcLib) ~= "table" or type(batCore) ~= "table" then
        log.error(LOG_TAG, "adc_lib/bat_core 无效",
            "adc_lib=", type(adcLib), "bat_core=", type(batCore),
            "（若为 boolean 多为与内置库重名，请用 adc_lib.lua）")
        return false
    end
    taskStarted = true
    sys.taskInit(batteryTask)
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

function getState()
    return {
        started = taskStarted,
        config = getCfg(),
        adc = adcLib.getState(),
        cell = batCore.getConfig(),
        sample_ms = sampleIntervalMs(),
        voltage = voltageMv,
        percent = percent,
        consumptionRate = consumptionRate,
    }
end

return _M
