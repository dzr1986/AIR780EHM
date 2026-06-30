require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local pir_ctrl
local hooks = {}
local guard = {
    pir_suspended = false,
    rest_by_battery = false,
    shutdown_timer = nil,
    last_percent = nil,
    rest_enter_ts = 0,
    rest_exit_ts = 0,
    enter_confirm_streak = 0,
    exit_confirm_streak = 0,
}
local function cfg()
    if type(_G.BATTERY_GUARD_CFG) == "table" then
        return _G.BATTERY_GUARD_CFG
    end
    local root = _G.BATTERY_CFG or {}
    return type(root.guard) == "table" and root.guard or {}
end
local function pctThreshold(key)
    return tonumber(cfg()[key])
end
local function intCfg(key, default)
    local v = tonumber(cfg()[key])
    if v == nil then
        return default
    end
    return v
end
local function enabled()
    local fc = _G.FEATURE_CFG
    if fc and fc.low_power == false then
        return false
    end
    if cfg().enabled == false then
        return false
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.battery_guard == false then
        return false
    end
    return true
end
function isUsbInserted()
    if cfg().ignore_when_usb_inserted == false then
        return false
    end
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.power_status) == 1 then
        return true
    end
    if type(hooks.is_usb_inserted) == "function" then
        return hooks.is_usb_inserted() and true or false
    end
    return false
end
local function loadPirCtrl()
    if pir_ctrl then
        return pir_ctrl
    end
    local ok, m = pcall(require, "pir_ctrl")
    if ok then
        pir_ctrl = m
    end
    return pir_ctrl
end
local function cancelShutdownTimer()
    if guard.shutdown_timer and sys.timerStop then
        sys.timerStop(guard.shutdown_timer)
    end
    guard.shutdown_timer = nil
end
local function isBlocked()
    if hooks.is_burn_active and hooks.is_burn_active() then
        return true, "t3x_burn"
    end
    if _G.T3X_BURN_MODE_ACTIVE then
        return true, "t3x_burn"
    end
    return false
end
local function suspendPir()
    if guard.pir_suspended then
        return
    end
    local pc = loadPirCtrl()
    if pc and pc.suspend then
        pc.suspend()
        guard.pir_suspended = true
    end
end
local function resumePir()
    if not guard.pir_suspended then
        return
    end
    local pc = loadPirCtrl()
    if pc and pc.resume then
        pc.resume()
    end
    guard.pir_suspended = false
end
local function dynamicDetectEnabled()
    return cfg().battery_rest_dynamic_detect ~= false
end
local function enterBatteryRest()
    if guard.rest_by_battery then
        return
    end
    guard.rest_by_battery = true
    guard.rest_enter_ts = os.time()
    guard.enter_confirm_streak = 0
    guard.exit_confirm_streak = 0
    if _G.APP_RUNTIME then
        _G.APP_RUNTIME.battery_dynamic_rest = dynamicDetectEnabled() and 1 or 0
    end
    if type(hooks.on_enter_low_power) == "function" then
        hooks.on_enter_low_power("battery")
    end
end
local function exitBatteryRest()
    if not guard.rest_by_battery then
        return
    end
    guard.rest_by_battery = false
    guard.rest_exit_ts = os.time()
    guard.rest_enter_ts = 0
    guard.enter_confirm_streak = 0
    guard.exit_confirm_streak = 0
    if _G.APP_RUNTIME then
        _G.APP_RUNTIME.battery_dynamic_rest = 0
    end
    if type(hooks.on_exit_low_power) == "function" then
        hooks.on_exit_low_power("battery_recover")
    end
end
function isBatteryDynamicRest()
    if not dynamicDetectEnabled() then
        return false
    end
    return guard.rest_by_battery == true
end
function shouldAllowPirInRest()
    return isBatteryDynamicRest()
end
--- 一直录像常电：电量 >t3x_rest_percent 且非 rest 时拒绝 HOSTIDLE 休眠
function shouldAllowHostIdleSleep()
    if cfg().block_host_idle_above_recover == false then
        return true
    end
    if guard.rest_by_battery then
        return true
    end
    local pct = guard.last_percent
    if pct == nil and _G.APP_RUNTIME then
        pct = tonumber(_G.APP_RUNTIME.battery_percent)
    end
    local alwaysOnPct = pctThreshold("t3x_rest_percent")
    if pct ~= nil and alwaysOnPct ~= nil and pct > alwaysOnPct then
        return false
    end
    return true
end
local function canEnterRestNow()
    local minOn = intCfg("min_always_on_duration_sec", 0)
    if minOn > 0 and guard.rest_exit_ts > 0 then
        if os.time() - guard.rest_exit_ts < minOn then
            return false
        end
    end
    return true
end
local function canExitRestNow()
    local minRest = intCfg("min_rest_duration_sec", 0)
    if minRest > 0 and guard.rest_enter_ts > 0 then
        if os.time() - guard.rest_enter_ts < minRest then
            return false
        end
    end
    return true
end
local function tryEnterBatteryRest(pct, restPct)
    local need = intCfg("enter_rest_confirm_count", 1)
    if need < 1 then
        need = 1
    end
    if pct <= restPct then
        guard.enter_confirm_streak = guard.enter_confirm_streak + 1
    else
        guard.enter_confirm_streak = 0
        return
    end
    if guard.enter_confirm_streak < need then
        return
    end
    if not canEnterRestNow() then
        guard.enter_confirm_streak = 0
        return
    end
    if not dynamicDetectEnabled() then
        suspendPir()
    end
    enterBatteryRest()
end
local function tryExitBatteryRest(pct, recoverPct)
    local need = intCfg("exit_rest_confirm_count", 1)
    if need < 1 then
        need = 1
    end
    if pct > recoverPct then
        guard.exit_confirm_streak = guard.exit_confirm_streak + 1
    else
        guard.exit_confirm_streak = 0
        return
    end
    if guard.exit_confirm_streak < need then
        return
    end
    if not canExitRestNow() then
        return
    end
    exitBatteryRest()
end
--- 已在 rest 但非电量 rest（如历史 usb_remove 误进）：电量 >recover 时立即退出
local function tryExitMismatchedRest(pct, recoverPct)
    if pct == nil or recoverPct == nil or pct <= recoverPct then
        return
    end
    if guard.rest_by_battery then
        return
    end
    local rt = _G.APP_RUNTIME
    if not rt or tonumber(rt.low_power_mode) ~= 1 then
        return
    end
    if type(hooks.on_exit_low_power) == "function" then
        hooks.on_exit_low_power("battery_recover")
    end
end
local function scheduleShutdown()
    if guard.shutdown_timer then
        return
    end
    local delay = tonumber(cfg().shutdown_delay_ms) or 3000
    guard.shutdown_timer = sys.timerStart(function()
        guard.shutdown_timer = nil
        if isUsbInserted() then
            return
        end
        if type(hooks.on_power_off) == "function" then
            hooks.on_power_off()
        elseif pm and pm.shutdown then
            pm.shutdown()
        end
    end, delay)
end
function evaluate(pct, mv)
    if not enabled() then
        return
    end
    local blocked = isBlocked()
    if blocked then
        return
    end
    pct = tonumber(pct)
    if pct == nil then
        if cfg().require_valid_sample ~= false then
            return
        end
    end
    guard.last_percent = pct
    if isUsbInserted() then
        cancelShutdownTimer()
        if guard.rest_by_battery or guard.pir_suspended then
            onUsbInserted()
        end
        return
    end
    if pct == nil then
        return
    end
    local shutdownPct = pctThreshold("shutdown_percent")
    local restPct = pctThreshold("t3x_rest_percent")
    local recoverPct = pctThreshold("recover_rest_percent")
    local pirSuspendPct = pctThreshold("pir_suspend_percent")
    local pirResumePct = pctThreshold("pir_resume_percent")
    if not shutdownPct or not restPct or not recoverPct or not pirSuspendPct or not pirResumePct then
        return
    end
    if pct <= shutdownPct then
        suspendPir()
        enterBatteryRest()
        scheduleShutdown()
        return
    end
    cancelShutdownTimer()
    if guard.rest_by_battery then
        tryExitBatteryRest(pct, recoverPct)
    else
        tryEnterBatteryRest(pct, restPct)
        tryExitMismatchedRest(pct, recoverPct)
    end
    if pct <= pirSuspendPct then
        suspendPir()
    elseif pct > pirResumePct then
        resumePir()
    end
end
function onUsbInserted()
    cancelShutdownTimer()
    local wasRest = guard.rest_by_battery
    local wasPir = guard.pir_suspended
    guard.rest_by_battery = false
    guard.pir_suspended = false
    guard.rest_enter_ts = 0
    guard.rest_exit_ts = 0
    guard.enter_confirm_streak = 0
    guard.exit_confirm_streak = 0
    if _G.APP_RUNTIME then
        _G.APP_RUNTIME.battery_dynamic_rest = 0
    end
    if wasPir then
        resumePir()
    end
    local exitedRest = false
    if wasRest or (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) then
        if type(hooks.on_exit_low_power) == "function" then
            hooks.on_exit_low_power("usb_insert")
            exitedRest = true
        end
    end
    if not exitedRest and type(hooks.wake_t3x) == "function" then
        hooks.wake_t3x()
    end
end
function onUsbRemoved()
    local pct = guard.last_percent
    if pct == nil and _G.APP_RUNTIME then
        pct = tonumber(_G.APP_RUNTIME.battery_percent)
    end
    evaluate(pct, nil)
end
function onUsbChanged(inserted)
    if inserted then
        onUsbInserted()
    else
        onUsbRemoved()
    end
end
function onBatteryUpdate(pct, mv)
    evaluate(pct, mv)
end
function start(opts)
    hooks = type(opts) == "table" and opts or {}
    local pct = _G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.battery_percent)
    if pct then
        sys.taskInit(function()
            sys.wait(500)
            evaluate(pct, nil)
        end)
    end
    return true
end
function getState()
    return {
        enabled = enabled(),
        usb_inserted = isUsbInserted(),
        pir_suspended = guard.pir_suspended,
        rest_by_battery = guard.rest_by_battery,
        battery_dynamic_rest = isBatteryDynamicRest(),
        shutdown_pending = guard.shutdown_timer ~= nil,
        last_percent = guard.last_percent,
        rest_enter_ts = guard.rest_enter_ts,
        rest_exit_ts = guard.rest_exit_ts,
        enter_confirm_streak = guard.enter_confirm_streak,
        exit_confirm_streak = guard.exit_confirm_streak,
    }
end
return _M
