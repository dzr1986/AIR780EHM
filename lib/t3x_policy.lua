require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "t3x_policy"
local lastDenyReason = ""
local function cfg()
    return _G.T3X_POLICY_CFG or {}
end
local function guardCfg()
    local root = _G.BATTERY_CFG or {}
    return root.guard or {}
end
function getDenyReason()
    return lastDenyReason
end
function isUsbInserted()
    local ok, up = pcall(require, "usb_policy")
    if ok and type(up) == "table" and up.isUsbInserted then
        return up.isUsbInserted()
    end
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.power_status) == 1 then
        return true
    end
    return false
end
function getBatteryPercent()
    local rt = _G.APP_RUNTIME
    if rt then
        local p = tonumber(rt.battery_percent)
        if p then
            return p
        end
    end
    return nil
end
function isLowPowerMode()
    local rt = _G.APP_RUNTIME
    return rt and tonumber(rt.low_power_mode) == 1
end
function isBurnActive()
    if _G.T3X_BURN_MODE_ACTIVE then
        return true
    end
    return false
end
function mayPowerT3x(reason, opts)
    opts = type(opts) == "table" and opts or {}
    lastDenyReason = ""
    if cfg().enabled == false then
        return true
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.t3x_policy == false then
        return true
    end
    if isBurnActive() then
        return true
    end
    if isUsbInserted() then
        return true
    end
    if opts.force_wake then
        return true
    end
    if cfg().block_wake_in_low_power ~= false and isLowPowerMode() then
        lastDenyReason = "low_power_mode=rest"
        return false
    end
    local pct = getBatteryPercent()
    local blockPct = tonumber(cfg().block_wake_below_percent)
    if blockPct == nil then
        blockPct = tonumber(guardCfg().pir_suspend_percent) or 15
    end
    if pct ~= nil and pct <= blockPct then
        lastDenyReason = string.format("battery<=%d%%", blockPct)
        return false
    end
    return true
end
function shouldWakeOnMqttOffline()
    if cfg().block_mqtt_offline_wake == false then
        return mayPowerT3x("mqtt_offline")
    end
    if isLowPowerMode() then
        lastDenyReason = "mqtt_offline+rest"
        return false
    end
    return mayPowerT3x("mqtt_offline")
end
function requestT3xWake(reason, sid, evt, opts)
    reason = reason or "wake"
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    opts = type(opts) == "table" and opts or {}
    if not mayPowerT3x(reason, opts) then
        return false
    end
    if _G.MODULE_FLAGS and _G.MODULE_FLAGS.t3x_wakeup
        and (_G.MODULE_FLAGS.t3x_app ~= false) then
        local okTs, time_sync = pcall(require, "time_sync")
        if okTs and time_sync and time_sync.pushBeforeNotifyAsync
            and _G.MODULE_FLAGS.time_sync ~= false then
            time_sync.pushBeforeNotifyAsync(sid, evt)
            return true
        end
        local hu = _G.host_uart
        if not hu then
            local ok, mod = pcall(require, "host_uart")
            if ok then hu = mod end
        end
        if hu and hu.notify_host then
            return hu.notify_host(sid, evt) ~= false
        end
    end
    local t3x = _G.t3x_ctrl
    if not t3x then
        local ok, mod = pcall(require, "t3x_ctrl")
        if ok then t3x = mod end
    end
    if t3x and t3x.wake then
        sys.taskInit(function() t3x.wake() end)
        return true
    end
    return false
end
function bootPowerOn(t3xModule)
    if not mayPowerT3x("boot") then
        return false
    end
    if t3xModule and t3xModule.powerOn then
        return t3xModule.powerOn()
    end
    return false
end
return _M
