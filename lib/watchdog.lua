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
-- 模块内置兜底默认（仅 WDT_CFG 缺失时生效）；net.lua WDT_CFG 为产品权威默认，两处改动须同步
local DEF_TIMEOUT_MS = 9000
local DEF_FEED_IV_MS = 3000
local runtime = {
    enabled = true,
    timeout_ms = DEF_TIMEOUT_MS,
    feed_interval_ms = DEF_FEED_IV_MS,
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
    local timeout = tonumber(runtime.timeout_ms) or DEF_TIMEOUT_MS
    local interval = clampFeedIv(timeout, tonumber(runtime.feed_interval_ms) or DEF_FEED_IV_MS)
    wdt.init(timeout)
    feedOnce()
    feedTimerId = sys.timerLoopStart(feedOnce, interval)
    started = true
    return true
end

-- start/feed/stop/getState/getConfig = 看门狗 API 族（LIB_RUNTIME_UTILS.md §2.1 登记，
-- P3-4 复核=有意保留）：start/stop 由 app.setupWatchdog 消费；feed/getConfig 零外部直连
-- 但属族内标准接口（feed=手动喂一次、getConfig=调试快照），勿按死代码摘除。
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
