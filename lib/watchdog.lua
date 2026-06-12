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
function start(opts)
    if started then
        return false
    end
    if not wdt or not wdt.init then
        return false
    end
    if not isModuleBsp() then
        log.warn(LOG_TAG, "noBsp", rtos.bsp and rtos.bsp() or "?")
        return false
    end
    mergeConfig(opts or _G.WDT_CFG)
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
    log.info(LOG_TAG, "on",
        "bsp", rtos.bsp and rtos.bsp() or "?",
        "timeout", timeout, "feed", interval)
    return true
end
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
