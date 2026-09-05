-- ================================================================
-- Filename : battery_guard.lua
-- Module   : 电量分档策略：USB 优先 / 三档电量 / PIR 挂起 / 4G rest / 关机定时器 / HOSTIDLE 门禁
-- Arch     : doc/modules/BATTERY_GUARD_TIERS.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local t31xPolicy = require "t31x_policy"
local pir_ctrl = require "pir_ctrl"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("battery_guard")
local bgInfo = logFuncs.info
local bgWarn = logFuncs.warn

local TIER_NORMAL = "normal"
local TIER_SHUTDOWN = "shutdown"

local hooks = {}
local started = false
local guard = {
    pir_suspended = false,
    rest_by_battery = false,
    shutdown_timer = nil,
    last_percent = nil,
    last_mv = nil,
    shutdown_mv_streak = 0,
    rest_enter_ts = 0,
    rest_exit_ts = 0,
    enter_confirm_streak = 0,
    exit_confirm_streak = 0,
    host_idle_wake_ts = 0,
}

local function guardCfg()
    return cfgm.get("BATTERY_GUARD_CFG")
end

local function pctThresh(key)
    return tonumber(guardCfg()[key])
end

local function intCfg(key, default)
    local v = tonumber(guardCfg()[key])
    return v ~= nil and v or default
end

local function strategy()
    return _G.LOW_POWER_ENTER_STRATEGY or "battery"
end

local function enabled()
    local fc = _G.FEATURE_CFG
    return not (fc and fc.low_power == false)
        and guardCfg().enabled ~= false
        and loader.enabled("battery_guard")
end

function isUsbInserted()
    if guardCfg().ignore_when_usb_inserted == false then
        return false
    end
    return rntmPwr.getPowerStatus() == 1
        or (type(hooks.isUsbInserted) == "function" and hooks.isUsbInserted())
end

local function shutdownMv()
    return tonumber(guardCfg().shutdown_mv)
end

local function shutdownRecMv()
    local recover = tonumber(guardCfg().shutdown_recover_mv)
    local cut = shutdownMv()
    if recover then return recover end
    if cut then return cut + 100 end
    return nil
end

local function isMvShutdown(mv)
    local cut = shutdownMv()
    mv = tonumber(mv)
    if cut == nil or mv == nil then return nil end
    return mv <= cut
end

function getBatteryTier(pct, mv)
    mv = tonumber(mv) or tonumber(guard.last_mv)
    if isMvShutdown(mv) == true then
        return TIER_SHUTDOWN
    end
    pct = tonumber(pct)
    if pct == nil then return nil end
    local shutdownPct = pctThresh("shutdown_percent")
    if shutdownPct ~= nil and pct <= shutdownPct then
        return TIER_SHUTDOWN
    end
    return TIER_NORMAL
end

local function syncTier(pct)
    local tier = getBatteryTier(pct, guard.last_mv)
    rntmPwr.setBatteryTier(tier)
    return tier
end

local function resetConfirm()
    guard.enter_confirm_streak = 0
    guard.exit_confirm_streak = 0
end

local function cancelShutdownTimer()
    if guard.shutdown_timer then sys.timerStop(guard.shutdown_timer) end
    guard.shutdown_timer = nil
end

local function isBlocked()
    if hooks.isBurnActive and hooks.isBurnActive() then
        return true, "t31x_burn"
    end
    if t31xPolicy.isBurnActive() then
        return true, "t31x_burn"
    end
    return false
end

local function suspendPir()
    pir_ctrl.suspend()
    guard.pir_suspended = true
end

local function resumePir()
    pir_ctrl.resume()
    guard.pir_suspended = false
end

local function dynDetectOn()
    return guardCfg().battery_rest_dynamic_detect ~= false
end

local function enterBatRest()
    bgWarn("enter_battery_rest", tostring(guard.last_percent or "nil"))
    guard.rest_by_battery = true
    guard.rest_enter_ts = os.time()
    resetConfirm()
    rntmPwr.setBatDynRest(dynDetectOn())
    if type(hooks.onEnterLowPower) == "function" then
        hooks.onEnterLowPower("battery")
    end
end

local function exitBatRest()
    bgInfo("exit_battery_rest", tostring(guard.last_percent or "nil"))
    guard.rest_by_battery = false
    guard.rest_exit_ts = os.time()
    guard.rest_enter_ts = 0
    resetConfirm()
    rntmPwr.setBatDynRest(false)
    if type(hooks.onExitLowPower) == "function" then
        hooks.onExitLowPower("battery_recover")
    end
end

function isBatDynRest()
    return dynDetectOn() and guard.rest_by_battery
end

function shouldHostSleep()
    return rntmPwr.isPirWatch()
end

function canHostSleep()
    if not shouldHostSleep() then return false end
    local minAwake = intCfg("host_idle_min_awake_sec", 30)
    if minAwake <= 0 or guard.host_idle_wake_ts <= 0 then return true end
    return (os.time() - guard.host_idle_wake_ts) >= minAwake
end

function notifyHostIdle()
    guard.host_idle_wake_ts = os.time()
end

function markT31xWoken()
    notifyHostIdle()
end

local function loadPctThresh()
    return {
        shutdown = pctThresh("shutdown_percent"),
        rest = pctThresh("t31x_rest_percent"),
        recover = pctThresh("recover_rest_percent"),
        host_idle = pctThresh("host_idle_below_percent"),
        pir_suspend = pctThresh("pir_suspend_percent"),
        pir_resume = pctThresh("pir_resume_percent"),
    }
end

local function schedShutdown()
    local delay = tonumber(guardCfg().shutdown_delay_ms) or 3000
    bgWarn("schedule_shutdown", delay, tostring(guard.last_percent or "nil"), tostring(guard.last_mv or "nil"))
    guard.shutdown_timer = sys.timerStart(function()
        guard.shutdown_timer = nil
        if isUsbInserted() then
            bgInfo("shutdown_canceled_usb")
            return
        end
        bgWarn("shutdown_execute")
        if type(hooks.onPowerOff) == "function" then
            hooks.onPowerOff()
        elseif pm and pm.shutdown then
            pm.shutdown()
        end
    end, delay)
end

local function resetMvStreak()
    guard.shutdown_mv_streak = 0
end

local function confirmMvShutdown(mv)
    local byMv = isMvShutdown(mv)
    if byMv == nil then return nil end
    if byMv then
        guard.shutdown_mv_streak = guard.shutdown_mv_streak + 1
    else
        resetMvStreak()
        return false
    end
    local need = math.max(1, intCfg("shutdown_mv_confirm_count", 2))
    return guard.shutdown_mv_streak >= need
end

local function shouldShutdown(pct, mv, shutdownPct)
    local confirmed = confirmMvShutdown(mv)
    if confirmed == true then return true end
    if confirmed == false then return false end
    return pct ~= nil and shutdownPct ~= nil and pct <= shutdownPct
end

local function shouldRecover(pct, mv, shutdownPct)
    local recover = shutdownRecMv()
    mv = tonumber(mv)
    if recover and mv then return mv > recover end
    return pct ~= nil and shutdownPct ~= nil and pct > shutdownPct
end

local function onShutdown(pct, shutdownPct, mv)
    if not shouldShutdown(pct, mv, shutdownPct) then return false end
    if not guard.pir_suspended then suspendPir() end
    if not guard.rest_by_battery then enterBatRest() end
    if not guard.shutdown_timer then schedShutdown() end
    return true
end

local function evalTiers(pct, thresholds, mv)
    syncTier(pct)
    if onShutdown(pct, thresholds.shutdown, mv) then return end
    if guard.shutdown_timer and not shouldRecover(pct, mv, thresholds.shutdown) then
        return
    end
    cancelShutdownTimer()
    if guard.pir_suspended then resumePir() end
    if guard.rest_by_battery then exitBatRest() end
end

function evaluate(pct, mv)
    if not enabled() or isBlocked() then return end
    pct = tonumber(pct)
    mv = tonumber(mv)
    if pct == nil and mv == nil and guardCfg().require_valid_sample ~= false then
        return
    end
    guard.last_percent = pct
    if mv ~= nil then guard.last_mv = mv end
    if isUsbInserted() then
        resetMvStreak()
        cancelShutdownTimer()
        if guard.rest_by_battery or guard.pir_suspended then
            onUsbIns()
        end
        return
    end
    if pct == nil and mv == nil then return end
    local thresholds = loadPctThresh()
    if strategy() == "hybrid" then
        local t = thresholds
        if not (t.shutdown and t.rest and t.recover and t.pir_suspend and t.pir_resume) then
            return
        end
    elseif thresholds.shutdown == nil then
        return
    end
    evalTiers(pct, thresholds, mv or guard.last_mv)
end

function onUsbIns(opts)
    opts = utils.optTable(opts)
    local source = opts.source
    bgInfo("usb_inserted", tostring(source or ""))
    cancelShutdownTimer()
    resetMvStreak()
    local wasRest = guard.rest_by_battery
    local wasPir = guard.pir_suspended
    guard.rest_by_battery = false
    guard.pir_suspended = false
    guard.rest_enter_ts = 0
    guard.rest_exit_ts = 0
    guard.host_idle_wake_ts = 0
    resetConfirm()
    rntmPwr.setBatDynRest(false)
    rntmPwr.setBatteryTier(TIER_NORMAL)
    if wasPir then resumePir() end
    local exitedRest = false
    if wasRest or rntmPwr.isLowPowerMode() then
        if type(hooks.onExitLowPower) == "function" then
            hooks.onExitLowPower("usb_insert")
            exitedRest = true
        end
    end
    if not exitedRest and source ~= "boot" and type(hooks.wakeT31x) == "function" then
        hooks.wakeT31x()
    end
end

function onUsbRemove()
    bgInfo("usb_removed")
    local pct = guard.last_percent
    if pct == nil then pct = rntmPwr.getBatteryPercent() end
    evaluate(pct, guard.last_mv)
end

function onBatUpd(pct, mv)
    local prev = guard.last_percent
    local prevMv = guard.last_mv
    evaluate(pct, mv)
    if (tonumber(pct) and prev ~= tonumber(pct)) or (tonumber(mv) and prevMv ~= tonumber(mv)) then
        bgInfo("battery_update", tonumber(pct), tonumber(mv), tostring(getBatteryTier(pct, mv) or "nil"))
    end
end

function start(opts)
    if started then return true end
    started = true
    hooks = utils.optTable(opts)
    bgInfo("start", tostring(strategy()))
    local pct = rntmPwr.getBatteryPercent()
    local mv = rntmPwr.getBatteryMv()
    if pct or mv then
        sys.taskInit(function()
            sys.wait(500)
            evaluate(pct, mv)
        end)
    end
    return true
end

function stop()
    if not started then return true end
    started = false
    cancelShutdownTimer()
    hooks = {}
    return true
end

function getState()
    return {
        strategy = strategy(),
        battery_tier = getBatteryTier(guard.last_percent),
        usb_inserted = isUsbInserted(),
        pir_suspended = guard.pir_suspended,
        rest_by_battery = guard.rest_by_battery,
        battery_dynamic_rest = isBatDynRest(),
        shutdown_pending = guard.shutdown_timer ~= nil,
        last_percent = guard.last_percent,
        last_mv = guard.last_mv,
        shutdown_mv_streak = guard.shutdown_mv_streak,
        host_idle_wake_ts = guard.host_idle_wake_ts,
        rest_enter_ts = guard.rest_enter_ts,
        rest_exit_ts = guard.rest_exit_ts,
        enter_confirm_streak = guard.enter_confirm_streak,
        exit_confirm_streak = guard.exit_confirm_streak,
    }
end

return _M
