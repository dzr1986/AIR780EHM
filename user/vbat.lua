--- 电池采样 v2：分压点 ADC → 电芯 mV → 百分比（新模块名，绕过 flash 内旧 bat_adc.lua）
-- 分压 R=1000K + Rx=510K，见 config.lua BATTERY_CFG.adc
-- @module vbat
-- @release 2026.5.26

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "vbat"
local BUILD_TAG = "v2-divider"

local taskStarted = false
local voltageMv, percent, consumptionRate = 0, 0, 0
local lastPercent, lastReadTime

local function getCfg()
    return _G.BATTERY_CFG or {}
end

local function getAdcCfg()
    return getCfg().adc or {}
end

local function getCellCfg()
    return getCfg().cell or {}
end

local function sampleIntervalMs()
    return getCfg().sample_interval_ms or (10 * 1000)
end

local function resolveMvScale()
    local adcCfg = getAdcCfg()
    local s = tonumber(adcCfg.mv_scale)
    if s and s > 1 then
        return s
    end
    local div = adcCfg.divider
    if type(div) == "table" then
        local r = tonumber(div.r_kohm)
        local rx = tonumber(div.rx_kohm)
        if r and rx and rx > 0 then
            return (r + rx) / rx
        end
    end
    return 1510 / 510
end

local function pinToCellMv(pinMv, scale)
    return math.floor(pinMv * scale + 0.5)
end

local function percentFromCellMv(cellMv)
    local vmax = tonumber(getCellCfg().v_max_mv) or 4200
    local vmin = tonumber(getCellCfg().v_min_mv) or 3000
    if cellMv >= vmax then
        return 100
    end
    if cellMv <= vmin then
        return 1
    end
    local step = (vmax - vmin) / 100
    local p = (cellMv - vmin) / step
    if p < 1 then
        p = 1
    end
    return math.floor(p)
end

local function updateConsumptionRate(currentPercent)
    local rate = 0
    local now = os.time()
    if lastPercent and lastReadTime then
        local hours = (now - lastReadTime) / 3600
        local diff = lastPercent - currentPercent
        if hours > 0 and diff > 0 then
            rate = math.floor((diff / hours) * 10 + 0.5) / 10
        end
    end
    lastPercent = currentPercent
    lastReadTime = now
    return rate
end

local function exportGlobals(pct, cellMv, rate)
    local rt = _G.APP_RUNTIME
    if not rt then
        return
    end
    rt.battery_percent = pct
    rt.battery_mv = cellMv
    rt.battery_consumption_rate = tostring(rate or 0)
end

local function getChannel()
    local c = getAdcCfg().channel
    if c == nil then
        c = 1
    end
    return c
end

local function applyAdcRange(ad)
    if not ad or not ad.setRange then
        return
    end
    local range = getAdcCfg().range
    if range == nil and ad.ADC_RANGE_MIN then
        range = ad.ADC_RANGE_MIN
    end
    if range ~= nil then
        ad.setRange(range)
    end
end

local function readPinOnce(ad, channel)
    if ad.read then
        local _, mv = ad.read(channel)
        if mv ~= nil and mv >= 0 then
            return mv
        end
    end
    if ad.get then
        local mv = ad.get(channel)
        if mv ~= nil and mv >= 0 then
            return mv
        end
    end
    return nil
end

local function readPinMillivolts(ad, channel)
    local sum, n = 0, 0
    for _ = 1, 3 do
        local mv = readPinOnce(ad, channel)
        if mv ~= nil then
            sum = sum + mv
            n = n + 1
        end
    end
    if n == 0 then
        return nil
    end
    return math.floor(sum / n + 0.5)
end

local function batteryTask()
    if not adc or not adc.open then
        log.warn(LOG_TAG, "ADC 不可用")
        return
    end

    local channel = getChannel()
    applyAdcRange(adc)
    adc.open(channel)

    local scale = resolveMvScale()
    log.info(LOG_TAG, BUILD_TAG, "start ch", channel, "scale", string.format("%.4f", scale))

    while true do
        local pinMv = readPinMillivolts(adc, channel)
        if pinMv then
            voltageMv = pinToCellMv(pinMv, scale)
            percent = percentFromCellMv(voltageMv)
            consumptionRate = updateConsumptionRate(percent)
            exportGlobals(percent, voltageMv, consumptionRate)
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
        build = BUILD_TAG,
        config = getCfg(),
        sample_ms = sampleIntervalMs(),
        mv_scale = resolveMvScale(),
        voltage = voltageMv,
        percent = percent,
        consumptionRate = consumptionRate,
    }
end

log.info(LOG_TAG, "loaded", BUILD_TAG)
return _M
