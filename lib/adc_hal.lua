-- ================================================================
-- Filename : adc_hal.lua
-- Module   : L0 HAL — ADC 原语封装（open/close/read/setRange；全仓库唯一允许直调 adc.* 的 lib 模块之一）
-- Arch     : AGENTS.md §6；vbat 采样经此模块，user 禁止直调 adc.*
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function adcLib()
    return adc
end

function available()
    local ad = adcLib()
    return ad ~= nil and (ad.open ~= nil or ad.read ~= nil or ad.get ~= nil)
end

function configure(opts)
    opts = opts or {}
    local ad = adcLib()
    if not ad or not ad.setRange then
        return false
    end
    local range = opts.range
    if range == nil and ad.ADC_RANGE_MIN ~= nil then
        range = ad.ADC_RANGE_MIN
    end
    if range ~= nil then
        ad.setRange(range)
    end
    return true
end

function open(channel)
    local ad = adcLib()
    if not ad or not ad.open then
        return false, "adc_unavailable"
    end
    return pcall(ad.open, channel)
end

function close(channel)
    local ad = adcLib()
    if not ad or not ad.close then
        return true
    end
    pcall(ad.close, channel)
    return true
end

function readMv(channel)
    local ad = adcLib()
    if not ad then
        return nil
    end
    if ad.read then
        local ok, mv = pcall(ad.read, channel)
        if ok and mv ~= nil and mv >= 0 then
            return mv
        end
    end
    if ad.get then
        local ok, mv = pcall(ad.get, channel)
        if ok and mv ~= nil and mv >= 0 then
            return mv
        end
    end
    return nil
end

return _M
