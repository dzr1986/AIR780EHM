-- ================================================================
-- Filename : watchdog.lua
-- Module   : 硬件看门狗：WDT 初始化与定时喂狗，异常死机自动复位
-- Arch     : doc/modules/LIB_RUNTIME_UTILS.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local started = false
local feedTimerId = nil
local runtime = {
    enabled = true,
    timeout_ms = 9000,
    feed_interval_ms = 3000,
}

local function isModuleBsp()
    if not rtos or not rtos.bsp then return true end
    local bsp = rtos.bsp() or ""
    return bsp:find("780") ~= nil
        or bsp:find("718") ~= nil
        or bsp:find("EC618") ~= nil
end

local function applyCfg(opts)
    local o = type(opts) == "table" and opts or cfgm.get("WDT_CFG")
    if o.enabled ~= nil then runtime.enabled = o.enabled ~= false end
    if o.timeout_ms then runtime.timeout_ms = o.timeout_ms end
    if o.feed_interval_ms then runtime.feed_interval_ms = o.feed_interval_ms end
    if o.timeout then runtime.timeout_ms = o.timeout end
    if o.feed_interval then runtime.feed_interval_ms = o.feed_interval end
end

local function feedOnce()
    if wdt and wdt.feed then
        wdt.feed()
        return true
    end
    return false
end

local function clampFeedIv(timeout, interval)
    if interval >= timeout then
        interval = math.floor(timeout / 3)
        if interval < 500 then interval = 500 end
    end
    return interval
end

function start(opts)
    if started then return true end
    applyCfg(opts)
    if runtime.enabled == false or not wdt or not wdt.init or not isModuleBsp() then
        return false
    end
    local timeout = tonumber(runtime.timeout_ms) or 9000
    local interval = clampFeedIv(timeout, tonumber(runtime.feed_interval_ms) or 3000)
    wdt.init(timeout)
    feedOnce()
    feedTimerId = sys.timerLoopStart(feedOnce, interval)
    started = true
    return true
end

function feed()
    return started and feedOnce() or false
end

function stop()
    if not started then return true end
    if feedTimerId then sys.timerStop(feedTimerId) end
    feedTimerId = nil
    started = false
    return true
end

function getState()
    return {
        started = started,
        bsp = rtos.bsp and rtos.bsp() or nil,
        has_wdt_api = wdt and wdt.init ~= nil,
    }
end

function getConfig()
    return runtime
end

return _M
