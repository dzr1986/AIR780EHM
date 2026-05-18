--- Air780EHM 模组侧硬件看门狗（LuatOS wdt，非 t3x 协处理器）
-- 全工程唯一 wdt.init / wdt.feed 入口；由 app 在启动早期调用
-- @module watchdog
-- @release 2026.5.18

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "air780_wdt"

local started = false
local feedTimerId = nil

local config = {
    timeout_ms = 9000,
    feed_interval_ms = 3000,
}

local function isModuleBsp()
    if not rtos or not rtos.bsp then
        return true
    end
    local bsp = rtos.bsp() or ""
  -- Air780EHM / EC718 等模组 BSP
    return bsp:find("780") ~= nil
        or bsp:find("718") ~= nil
        or bsp:find("EC618") ~= nil
end

local function mergeConfig(opts)
    if type(opts) ~= "table" then
        return config
    end
    if opts.timeout_ms then config.timeout_ms = opts.timeout_ms end
    if opts.feed_interval_ms then config.feed_interval_ms = opts.feed_interval_ms end
    if opts.timeout then config.timeout_ms = opts.timeout end
    if opts.feed_interval then config.feed_interval_ms = opts.feed_interval end
    return config
end

local function feedOnce()
    if wdt and wdt.feed then
        wdt.feed()
    end
end

--- 启动 Air780 模组看门狗（重复调用无效）
-- @param opts 覆盖 _G.WDT_CONFIG：timeout_ms, feed_interval_ms
function start(opts)
    if started then
        log.warn(LOG_TAG, "已启动")
        return false
    end
    if not wdt or not wdt.init then
        log.warn(LOG_TAG, "当前固件无 wdt 库")
        return false
    end
    if not isModuleBsp() then
        log.warn(LOG_TAG, "非 Air780 类 BSP，跳过模组 WDT", rtos.bsp and rtos.bsp() or "?")
        return false
    end

    mergeConfig(opts or _G.WDT_CONFIG)

    local timeout = config.timeout_ms
    local interval = config.feed_interval_ms
    if interval >= timeout then
        interval = math.floor(timeout / 3)
        if interval < 500 then interval = 500 end
    end

    wdt.init(timeout)
    feedOnce()
    feedTimerId = sys.timerLoopStart(feedOnce, interval)

    started = true
    log.info(LOG_TAG, "Air780 模组 WDT 已启动",
        "bsp", rtos.bsp and rtos.bsp() or "?",
        "timeout", timeout, "feed", interval)
    return true
end

--- 手动喂狗（长阻塞任务中可偶尔调用）
function feed()
    if started then
        feedOnce()
        return true
    end
    return false
end

function stop()
    if feedTimerId then
        sys.timerStop(feedTimerId)
        feedTimerId = nil
    end
    started = false
    return true
end

function getState()
    return {
        started = started,
        bsp = rtos.bsp and rtos.bsp() or nil,
        timeout_ms = config.timeout_ms,
        feed_interval_ms = config.feed_interval_ms,
    }
end

function getConfig()
    return config
end

return _M
