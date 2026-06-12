--- 电池电量保护（仅在外壳 USB 未插入时生效）
-- ≤15% suspend PIR（T3x 可能仍上电）；≤10% 回调 on_enter_low_power → app 进 rest（1002/断 T3x）
-- ≤5% 延时关机；USB 插入（GPIO27）时忽略电量并恢复 T3x/PIR
-- @module battery_guard
-- @release v1_20260528

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "batG"
local pir_ctrl

local hooks = {}
local guard = {
    pir_suspended = false,
    rest_by_battery = false,
    shutdown_timer = nil,
    last_percent = nil,
}

local function cfg()
    if type(_G.BATTERY_GUARD_CFG) == "table" then
        return _G.BATTERY_GUARD_CFG
    end
    local root = _G.BATTERY_CFG or {}
    return type(root.guard) == "table" and root.guard or {}
end

local function pctThreshold(key)
    local v = tonumber(cfg()[key])
    if v == nil then
        log.warn(LOG_TAG, "guard cfg missing", key)
    end
    return v
end

local function enabled()
    local fc = _G.FEATURE_CFG
    if fc and fc.low_power == false then
        return false
    end
    local c = cfg()
    if c.enabled == false then
        return false
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.battery_guard == false then
        return false
    end
    return true
end

--- 外壳 USB 座是否插入（GPIO27 / APP_RUNTIME.power_status）
function isUsbInserted()
    local c = cfg()
    if c.ignore_when_usb_inserted == false then
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
    pir_ctrl = pir_ctrl or (function()
        local ok, m = pcall(require, "pir_ctrl")
        if ok then return m end
    end)()
    if pir_ctrl and pir_ctrl.suspend then
        pir_ctrl.suspend()
        guard.pir_suspended = true
        log.info(LOG_TAG, "pir-")
    end
end

local function resumePir()
    if not guard.pir_suspended then
        return
    end
    pir_ctrl = pir_ctrl or (function()
        local ok, m = pcall(require, "pir_ctrl")
        if ok then return m end
    end)()
    if pir_ctrl and pir_ctrl.resume then
        pir_ctrl.resume()
        log.info(LOG_TAG, "pir+")
    end
    guard.pir_suspended = false
end

local function enterBatteryRest(pct)
    if guard.rest_by_battery then
        return
    end
    guard.rest_by_battery = true
    log.warn(LOG_TAG, "电量", pct, "≤rest")
    if type(hooks.on_enter_low_power) == "function" then
        hooks.on_enter_low_power("battery")
    end
end

local function exitBatteryRest(pct)
    if not guard.rest_by_battery then
        return
    end
    guard.rest_by_battery = false
    log.info(LOG_TAG, "电量", pct, ">rest")
    if type(hooks.on_exit_low_power) == "function" then
        hooks.on_exit_low_power("battery_recover")
    end
end

local function scheduleShutdown(pct)
    if guard.shutdown_timer then
        return
    end
    local delay = tonumber(cfg().shutdown_delay_ms) or 3000
    log.error(LOG_TAG, "电量", pct, "≤off", delay / 1000, "s off")
    guard.shutdown_timer = sys.timerStart(function()
        guard.shutdown_timer = nil
        if isUsbInserted() then
            log.info(LOG_TAG, "usbXoff")
            return
        end
        if type(hooks.on_power_off) == "function" then
            hooks.on_power_off()
        elseif pm and pm.shutdown then
            pm.shutdown()
        end
    end, delay)
end

--- 根据电量与 USB 状态执行分级保护
function evaluate(pct, mv)
    if not enabled() then
        return
    end
    local blocked, reason = isBlocked()
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
        enterBatteryRest(pct)
        scheduleShutdown(pct)
        return
    end

    cancelShutdownTimer()

    if pct <= restPct then
        suspendPir()
        enterBatteryRest(pct)
    elseif pct > recoverPct then
        exitBatteryRest(pct)
    end

    if pct <= pirSuspendPct then
        suspendPir()
    elseif pct > pirResumePct then
        resumePir()
    end
end

--- USB 插入：忽略电量策略，保持 T3x 运行
function onUsbInserted()
    cancelShutdownTimer()
    local wasRest = guard.rest_by_battery
    local wasPir = guard.pir_suspended
    guard.rest_by_battery = false
    guard.pir_suspended = false
    if wasPir then
        resumePir()
    end
    log.info(LOG_TAG, "usb+")
    local exitedRest = false
    if wasRest or (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) then
        if type(hooks.on_exit_low_power) == "function" then
            hooks.on_exit_low_power("usb_insert")
            exitedRest = true
        end
    end
    -- 已走 on_exit_low_power → requestT3xWake，勿再 wake_t3x 重复脉冲
    if not exitedRest and type(hooks.wake_t3x) == "function" then
        hooks.wake_t3x()
    end
end

--- USB 拔出：按当前电量重新评估
function onUsbRemoved()
    log.info(LOG_TAG, "usb-")
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
    local c = cfg()
    log.info(LOG_TAG, "on",
        "rest<=" .. tostring(c.t3x_rest_percent) .. "%",
        "off<=" .. tostring(c.shutdown_percent) .. "%",
        "pir<=" .. tostring(c.pir_suspend_percent) .. "%",
        "usb_ignore=" .. tostring(c.ignore_when_usb_inserted ~= false))
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
        shutdown_pending = guard.shutdown_timer ~= nil,
        last_percent = guard.last_percent,
    }
end

return _M
