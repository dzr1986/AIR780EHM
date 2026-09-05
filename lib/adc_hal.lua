-- ================================================================
-- Filename : adc_hal.lua
-- Module   : L0 HAL — ADC 原语封装（open/close/read/setRange；全仓库唯一允许直调 adc.* 的 lib 模块之一）
-- Arch     : AGENTS.md §6；vbat 采样经此模块，user 禁止直调 adc.*
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local readMvFn -- "read" | "get" | nil，首次成功后缓存，避免每采样双 pcall

function available()
    local ad = adc
    return ad ~= nil and (ad.open ~= nil or ad.read ~= nil or ad.get ~= nil)
end

function configure(opts)
    opts = opts or {}
    local ad = adc
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
    local ad = adc
    if not ad or not ad.open then
        return false, "adc_unavailable"
    end
    return pcall(ad.open, channel)
end

function close(channel)
    local ad = adc
    if not ad or not ad.close then
        return true
    end
    pcall(ad.close, channel)
    return true
end

function readMv(channel)
    local ad = adc
    if not ad then
        return nil
    end
    local function tryRead(fnName)
        local fn = ad[fnName]
        if not fn then
            return nil
        end
        local ok, mv = pcall(fn, channel)
        if ok and mv ~= nil and mv >= 0 then
            readMvFn = fnName
            return mv
        end
        return nil
    end
    if readMvFn then
        local mv = tryRead(readMvFn)
        if mv ~= nil then
            return mv
        end
        readMvFn = nil
    end
    return tryRead("read") or tryRead("get")
end

return _M
