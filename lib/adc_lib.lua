--- BAT_ADC 硬件采样（封装 LuatOS 原生 adc API）
-- 文件名 adc_lib.lua，user/bat_adc 中 require "adc_lib"（勿 require "adc"）
-- 参数：config.lua → BATTERY_CFG.adc
-- @module adc_lib
-- @release 2026.5.20

require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function hwadc()
    return adc
end

local LOG_TAG = "adc_lib"
local openedChannel = nil

local function getAdcCfg()
    local root = _G.BATTERY_CFG or {}
    return root.adc or {}
end

function getConfig()
    return getAdcCfg()
end

function getChannel()
    local c = getAdcCfg().channel
    if c == nil then
        c = 1
    end
    return c
end

local function scaleFromDivider(div)
    if type(div) ~= "table" then
        return nil
    end
    local r = tonumber(div.r_kohm) or tonumber(div.r_upper_kohm)
    local rx = tonumber(div.rx_kohm) or tonumber(div.r_lower_kohm)
    if r and rx and rx > 0 then
        return (r + rx) / rx
    end
    return nil
end

--- 分压还原系数：(R+Rx)/Rx；优先 mv_scale，其次 divider，最后本板默认 1000K/510K
function getMvScale()
    local cfg = getAdcCfg()
    local s = tonumber(cfg.mv_scale)
    if s and s > 1 then
        return s
    end
    s = scaleFromDivider(cfg.divider)
    if s and s > 1 then
        return s
    end
    -- 本板 BAT_ADC 默认分压 1000K + 510K
    return 1510 / 510
end

function applyRange()
    local ad = hwadc()
    if not ad or not ad.setRange then
        return false
    end
    local range = getAdcCfg().range
    if range == nil and ad.ADC_RANGE_MIN then
        range = ad.ADC_RANGE_MIN
    end
    if range == nil and ad.ADC_RANGE_MAX then
        range = ad.ADC_RANGE_MAX
    end
    if range ~= nil then
        ad.setRange(range)
        log.info(LOG_TAG, "setRange", range)
        return true
    end
    return false
end

function open(channel)
    channel = channel or getChannel()
    local ad = hwadc()
    if channel == nil or channel == 255 or not ad or not ad.open then
        return false
    end
    applyRange()
    ad.open(channel)
    openedChannel = channel
    log.info(LOG_TAG, "open", channel)
    return true
end

function close()
    local ad = hwadc()
    if openedChannel and ad and ad.close then
        ad.close(openedChannel)
        log.info(LOG_TAG, "close", openedChannel)
    end
    openedChannel = nil
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

--- @return number|nil 引脚电压 mV（连续 3 次取平均，抑制抖动）
function readPinMillivolts(channel)
    channel = channel or openedChannel or getChannel()
    local ad = hwadc()
    if not channel or not ad then
        return nil
    end
    local sum, n = 0, 0
    for _ = 1, 3 do
        local mv = readPinOnce(ad, channel)
        if mv ~= nil then
            sum = sum + mv
            n = n + 1
        end
    end
    if n == 0 then
        log.warn(LOG_TAG, "read fail ch", channel)
        return nil
    end
    return math.floor(sum / n + 0.5)
end

--- 引脚 mV → 电芯 mV（× mv_scale）
function pinToCellMillivolts(pinMv, scale)
    scale = scale or getMvScale()
    return math.floor(pinMv * scale + 0.5)
end

function getState()
    return {
        channel = openedChannel or getChannel(),
        mv_scale = getMvScale(),
        config = getAdcCfg(),
    }
end

_G.adcLib = _M
log.info(LOG_TAG, "loaded -> _G.adcLib")
return _M
