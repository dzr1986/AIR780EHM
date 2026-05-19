--- 电池电量换算（百分比、耗电率、全局导出）
-- user/bat_adc 中 require "bat_core"（勿 require "battery"）
-- 参数：config.lua → BATTERY_CFG.cell
-- @module bat_core
-- @release 2026.5.20

require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "bat_core"
local lastPercent, lastReadTime

local function getCellCfg()
    local root = _G.BATTERY_CFG or {}
    return root.cell or {}
end

function getConfig()
    return getCellCfg()
end

function vbatMax()
    return getCellCfg().v_max_mv or 4300
end

function vbatMin()
    return getCellCfg().v_min_mv or 3300
end

--- 电芯电压 mV → 1~100%
function percentFromMillivolts(voltageMv)
    local vmax = vbatMax()
    local vmin = vbatMin()
    if voltageMv >= vmax then
        return 100
    end
    if voltageMv <= vmin then
        return 1
    end
    local step = (vmax - vmin) / 100
    local p = (voltageMv - vmin) / step
    if p < 1 then
        p = 1
    end
    return math.floor(p)
end

function updateConsumptionRate(currentPercent)
    local rate = 0
    local now = os.time()
    if lastPercent and lastReadTime then
        local timeDiffHours = (now - lastReadTime) / 3600
        local batteryDiff = lastPercent - currentPercent
        if timeDiffHours > 0 and batteryDiff > 0 then
            rate = math.floor((batteryDiff / timeDiffHours) * 10 + 0.5) / 10
        end
    end
    lastPercent = currentPercent
    lastReadTime = now
    return rate
end

function exportGlobals(percent, voltageMv, consumptionRate)
    local rt = _G.APP_RUNTIME
    if not rt then
        return
    end
    rt.battery_percent = percent
    rt.battery_mv = voltageMv
    rt.battery_consumption_rate = tostring(consumptionRate or 0)
end

function resetRateTracking()
    lastPercent = nil
    lastReadTime = nil
end

return _M
