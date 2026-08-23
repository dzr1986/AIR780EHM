-- ================================================================
-- Filename : t3x_policy.lua
-- Module   : T3x 唤醒门禁：USB 优先、rest 白名单、低电阻断，统一 mayPowerT3x/reqT3xWake
-- Arch     : doc/modules/T3X_POLICY_GATE.md
-- ================================================================

require "sys"
require "config"
local loader = require "module_loader"
local rntmPwr = require "runtime_power"
local t3x_notify = require "t3x_notify"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local lastMqtt = 0
local function cfg()
    return _G.T3X_POLICY_CFG or {}
end

local function guardCfg()
    local root = _G.BATTERY_CFG or {}
    return root.guard or {}
end

function isUsbInserted()
    return rntmPwr.isUsbInserted()
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

function getBatteryMv()
    local rt = _G.APP_RUNTIME
    if rt then
        return tonumber(rt.battery_mv)
    end
    return nil
end

function isLowPowerMode()
    return rntmPwr.isLowPowerMode()
end

local function isBatDynRest()
    return rntmPwr.isBatDynRest()
end

function isBurnActive()
    return _G.T3X_BURN_MODE_ACTIVE == true
end

local function isWledWake(reason)
    return tostring(reason or "") == "wled"
end

local function isPirWake(reason)
    reason = tostring(reason or "")
    if reason == "notify_host" or reason == "pir_media" or reason == "exit_low_power" then
        return true
    end
    return reason:sub(1, 9) == "pir_stop"
end

local function allwWakeIn(reason)
    if cfg().allow_wled_wake_in_rest ~= false and isWledWake(reason) then
        return true
    end
    if not isPirWake(reason) then
        return false
    end
    if cfg().allow_pir_wake_in_rest ~= false then
        return true
    end
    if cfg().allow_pir_wake_in_battery_rest ~= false and isBatDynRest() then
        return true
    end
    return false
end

local function plcyDsbl()
    if cfg().enabled == false then
        return true
    end
    return not loader.enabled("t3x_policy")
end

local function psssUsbGate(reason)
    if not isUsbInserted() then
        return false
    end
    if reason == "mqtt_offline" and cfg().allow_mqtt_offline_wake_when_usb ~= true then
        return false
    end
    return true
end

local function psssLowPwr(reason, opts)
    if cfg().block_wake_in_low_power == false or not isLowPowerMode() then
        return true
    end
    if allwWakeIn(reason) then
        return true
    end
    return false
end

local function psssBttr()
    local mv = getBatteryMv()
    local blockMv = tonumber(cfg().block_wake_below_mv) or tonumber(guardCfg().shutdown_mv)
    if blockMv and mv and mv <= blockMv then
        return false
    end
    local pct = getBatteryPercent()
    local blockPct = tonumber(cfg().block_wake_below_percent) or tonumber(guardCfg().pir_suspend_percent) or 15
    if pct ~= nil and pct <= blockPct then
        return false
    end
    return true
end

function mayPowerT3x(reason, opts)
    opts = type(opts) == "table" and opts or {}
    if plcyDsbl() or isBurnActive() or psssUsbGate(reason) or opts.force_wake then
        return true
    end
    if not psssLowPwr(reason, opts) then
        return false
    end
    return psssBttr()
end

function shdWakeOffline()
    if cfg().block_mqtt_offline_wake == false then
        return mayPowerT3x("mqtt_offline")
    end
    if isLowPowerMode() then
        return false
    end
    local cd = tonumber(cfg().mqtt_offline_wake_cooldown_sec)
    if cd and cd > 0 and lastMqtt > 0
        and os.time() - lastMqtt < cd then
        return false
    end
    if cfg().block_mqtt_offline_wake_when_usb ~= false and isUsbInserted() then
        return false
    end
    return mayPowerT3x("mqtt_offline")
end

local function rcrdMqtt(reason)
    if reason == "mqtt_offline" then
        lastMqtt = os.time()
    end
end

function reqT3xWake(reason, sid, evt, opts)
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    opts = type(opts) == "table" and opts or {}
    if not mayPowerT3x(reason, opts) then
        return false
    end
    return t3x_notify.wakeHost(sid, evt, {
        on_done = function()
            rcrdMqtt(reason)
        end,
    })
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
