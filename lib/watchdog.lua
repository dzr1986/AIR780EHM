require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "air780_wdt"
local started = false
local feedTimerId = nil
local config = {
    enabled = true,
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
    if opts.enabled ~= nil then config.enabled = opts.enabled ~= false end
    if opts.timeout_ms then config.timeout_ms = opts.timeout_ms end
    if opts.feed_interval_ms then config.feed_interval_ms = opts.feed_interval_ms end
    if opts.timeout then config.timeout_ms = opts.timeout end
    if opts.feed_interval then config.feed_interval_ms = opts.feed_interval end
    return config
end
local function feedOnce()
    if wdt and wdt.feed then
        wdt.feed()
        return true
    end
    return false
end
function start(opts)
    if started then
        return true
    end
    mergeConfig(opts or _G.WDT_CFG)
    if config.enabled == false then
        log.info(LOG_TAG, "disabled")
        return false
    end
    if not wdt or not wdt.init then
        log.warn(LOG_TAG, "no_wdt_api")
        return false
    end
    if not isModuleBsp() then
        log.warn(LOG_TAG, "no_bsp_wdt", rtos.bsp and rtos.bsp() or "?")
        return false
    end
    local timeout = tonumber(config.timeout_ms) or 9000
    local interval = tonumber(config.feed_interval_ms) or 3000
    if interval >= timeout then
        interval = math.floor(timeout / 3)
        if interval < 500 then interval = 500 end
    end
    wdt.init(timeout)
    feedOnce()
    feedTimerId = sys.timerLoopStart(feedOnce, interval)
    started = true
    log.info(LOG_TAG, "module_on",
        "bsp", rtos.bsp and rtos.bsp() or "?",
        "timeout", timeout, "feed", interval)
    return true
end
function feed()
    if started then
        return feedOnce()
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
        enabled = config.enabled ~= false,
        bsp = rtos.bsp and rtos.bsp() or nil,
        timeout_ms = config.timeout_ms,
        feed_interval_ms = config.feed_interval_ms,
        has_wdt_api = wdt and wdt.init ~= nil,
    }
end
function getConfig()
    return config
end
return _M
