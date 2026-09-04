-- ================================================================
-- Filename : vbat.lua
-- Module   : 电池 ADC 采样：定时采样 + trim/EMA 滤波 + 百分比/mV/耗电率输出
-- Arch     : doc/modules/VBAT_FILTER.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local BUILD_TAG = "v4-filter"
local taskStarted = false
local running = false
local voltageMv, percent, consumptionRate = 0, 0, 0
local lastPercent, lastReadTime
local filteredMv, stablePercent

local function batteryCfg()
    return cfgm.get("BATTERY_CFG")
end

local function adcCfg()
    return batteryCfg().adc or {}
end

local function cellCfg()
    return batteryCfg().cell or {}
end

local function filterCfg()
    return batteryCfg().filter or {}
end

local function sampleIvMs()
    return batteryCfg().sample_interval_ms or (10 * 1000)
end

local function mvScale()
    local adc = adcCfg()
    local s = tonumber(adc.mv_scale)
    local scale
    if s and s > 1 then
        scale = s
    else
        local div = adc.divider
        local r = type(div) == "table" and tonumber(div.r_kohm)
        local rx = type(div) == "table" and tonumber(div.rx_kohm)
        scale = (r and rx and rx > 0) and ((r + rx) / rx) or (1510 / 510)
    end
    local cal = tonumber(adc.mv_calibration)
    if cal and cal > 0 then
        scale = scale * cal
    end
    return scale
end

local function percentFrom(cellMv)
    local vmax = tonumber(cellCfg().v_max_mv) or 4200
    local vmin = tonumber(cellCfg().v_min_mv) or 3000
    if cellMv >= vmax then return 100 end
    if cellMv <= vmin then return 1 end
    local p = (cellMv - vmin) / ((vmax - vmin) / 100)
    return math.floor(p < 1 and 1 or p)
end

local function trimMean(samples)
    local n = #samples
    if n == 0 then return nil end
    table.sort(samples)
    local drop = tonumber(filterCfg().trim_drop) or 2
    local from, to = 1, n
    if n > drop * 2 + 1 then
        from, to = drop + 1, n - drop
    end
    local sum = 0
    for i = from, to do
        sum = sum + samples[i]
    end
    return math.floor(sum / (to - from + 1) + 0.5)
end

local function clampStep(cur, target, maxStep)
    local diff = target - cur
    if maxStep <= 0 or math.abs(diff) <= maxStep then
        return target
    end
    return cur + (diff > 0 and maxStep or -maxStep)
end

local function smoothCell(rawCellMv)
    local fc = filterCfg()
    local alpha = tonumber(fc.ema_alpha)
    if not alpha or alpha <= 0 or alpha > 1 then
        alpha = 0.35
    end
    if filteredMv == nil then
        filteredMv = rawCellMv
        return filteredMv
    end
    filteredMv = clampStep(
        filteredMv,
        math.floor(rawCellMv * alpha + filteredMv * (1 - alpha) + 0.5),
        tonumber(fc.mv_max_step) or 35)
    return filteredMv
end

local function smoothPct(cellMv, rawPct)
    local fc = filterCfg()
    local vmax = tonumber(cellCfg().v_max_mv) or 4200
    local hystHigh = tonumber(fc.percent_hyst_high_mv) or (vmax - 80)
    local pct = rawPct

    if stablePercent == nil then
        stablePercent = pct
        return pct
    end

    if stablePercent >= 100 then
        pct = cellMv < hystHigh and percentFrom(cellMv) or 100
    elseif rawPct >= 100 and cellMv >= vmax then
        pct = 100
    end

    pct = math.floor(clampStep(stablePercent, pct, tonumber(fc.percent_max_step) or 2))
    if pct < 1 then
        pct = 1
    elseif pct > 100 then
        pct = 100
    end
    stablePercent = pct
    return pct
end

local function updateConsume(currentPercent)
    local now = os.time()
    local hours = lastReadTime and (now - lastReadTime) / 3600
    local diff = lastPercent and (lastPercent - currentPercent)
    local rate = (hours and hours > 0 and diff and diff > 0)
        and (math.floor((diff / hours) * 10 + 0.5) / 10) or 0
    lastPercent = currentPercent
    lastReadTime = now
    return rate
end

local function applyAdc(ad)
    if not ad or not ad.setRange then return end
    local range = adcCfg().range
    if range == nil then range = ad.ADC_RANGE_MIN end
    if range ~= nil then ad.setRange(range) end
end

local function readPinRaw(ad, channel)
    if ad.read then
        local _, mv = ad.read(channel)
        if mv ~= nil and mv >= 0 then return mv end
    end
    if ad.get then
        local mv = ad.get(channel)
        if mv ~= nil and mv >= 0 then return mv end
    end
end

-- 平台 ADC 调用一律 pcall：单次读失败只丢本样本，不能让 batteryTask 协程整体退出；告警只报一次防刷屏
local adcReadErrLogged = false
local function readPin(ad, channel)
    local ok, mv = pcall(readPinRaw, ad, channel)
    if ok then return mv end
    if not adcReadErrLogged then
        adcReadErrLogged = true
        if log and log.warn then log.warn("vbat", "adc_read_err", tostring(mv)) end
    end
    return nil
end

local function readPinMv(ad, channel)
    local fc = filterCfg()
    local count = tonumber(fc.sample_count) or 11
    local spacing = tonumber(fc.sample_spacing_ms) or 20
    local samples = {}
    for i = 1, count do
        local mv = readPin(ad, channel)
        if mv ~= nil then samples[#samples + 1] = mv end
        if i < count and spacing > 0 then sys.wait(spacing) end
    end
    return trimMean(samples)
end

local function batteryTask()
    local channel = adcCfg().channel or 1
    local scale = mvScale()
    -- adc 库本身可能缺失：索引放进闭包内，让 pcall 真正兜住
    pcall(applyAdc, adc)
    local okOpen, errOpen = pcall(function() adc.open(channel) end)
    if not okOpen and log and log.warn then
        log.warn("vbat", "adc_open_err", tostring(channel), tostring(errOpen))
    end
    while running do
        local pinMv = readPinMv(adc, channel)
        if pinMv then
            local cellMv = smoothCell(math.floor(pinMv * scale + 0.5))
            local vmax = tonumber(cellCfg().v_max_mv) or 4200
            if cellMv > vmax then cellMv = vmax end
            local pct = smoothPct(cellMv, percentFrom(cellMv))
            voltageMv, percent = cellMv, pct
            consumptionRate = updateConsume(percent)
            rntmPwr.setBattery(percent, voltageMv, consumptionRate)
            sys.publish(APP_EVENTS.BATTERY_UPDATE, percent, voltageMv, consumptionRate)
        end
        sys.wait(sampleIvMs())
    end
    pcall(function() if adc and adc.close then adc.close(channel) end end)
end

function start()
    if taskStarted then return true end
    taskStarted = true
    running = true
    adcReadErrLogged = false -- 每次启动允许再告警一次（间歇性 ADC 错误不刷屏）
    sys.taskInit(batteryTask)
    return true
end

function stop()
    if not taskStarted then return true end
    taskStarted = false
    running = false
    return true
end

function getPercent()
    return percent
end

function getState()
    return {
        started = taskStarted,
        build = BUILD_TAG,
        voltage = voltageMv,
        percent = percent,
        consumptionRate = consumptionRate,
        filtered_mv = filteredMv,
        stable_percent = stablePercent,
    }
end

return _M
