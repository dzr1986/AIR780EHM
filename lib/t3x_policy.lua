-- ================================================================
-- Filename : t3x_policy.lua
-- Module   : T3x 唤醒门禁：USB 优先、rest 白名单、低电阻断，统一 mayPowerT3x/reqT3xWake
-- Arch     : doc/modules/T3X_POLICY_GATE.md
-- ================================================================

require "sys"
require "config"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local t3x_notify = require "t3x_notify"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local lastMqttWakeAt = 0
local burnActive = false

local function policyCfg()
    return cfgm.get("T3X_POLICY_CFG")
end

local function guardCfg()
    return cfgm.get("BATTERY_CFG").guard or {}
end

function setBurnActive(active)
    burnActive = active == true
end

function isBurnActive()
    return burnActive
end

local function isPirWake(reason)
    reason = tostring(reason or "")
    return reason == "ntfHost" or reason == "pir_media"
        or reason == "exit_low_power" or reason:sub(1, 9) == "pir_stop"
end

local function allowWakeRest(reason)
    if policyCfg().allow_wled_wake_in_rest ~= false and tostring(reason or "") == "wled" then
        return true
    end
    return isPirWake(reason) and (
        policyCfg().allow_pir_wake_in_rest ~= false
        or (policyCfg().allow_pir_wake_in_battery_rest ~= false and rntmPwr.isBatDynRest())
    )
end

local function policyOff()
    return policyCfg().enabled == false or not loader.enabled("t3x_policy")
end

local function passUsbGate(reason)
    return rntmPwr.isUsbInserted()
        and (reason ~= "mqtt_offline" or policyCfg().allow_mqtt_offline_wake_when_usb == true)
end

local function passLpGate(reason)
    return policyCfg().block_wake_in_low_power == false
        or not rntmPwr.isLowPowerMode()
        or allowWakeRest(reason)
end

local function passBatGate()
    local mv = rntmPwr.getBatteryMv()
    local blockMv = tonumber(policyCfg().block_wake_below_mv) or tonumber(guardCfg().shutdown_mv)
    if blockMv and mv and mv <= blockMv then
        return false
    end
    local pct = rntmPwr.getBatteryPercent()
    local blockPct = tonumber(policyCfg().block_wake_below_percent)
        or tonumber(guardCfg().pir_suspend_percent) or 15
    return pct == nil or pct > blockPct
end

function mayPowerT3x(reason, opts)
    opts = type(opts) == "table" and opts or {}
    if policyOff() or isBurnActive() or passUsbGate(reason) or opts.forceWake then
        return true
    end
    return passLpGate(reason) and passBatGate()
end

function shdWakeOffline()
    local cfg = policyCfg()
    if cfg.block_mqtt_offline_wake ~= false then
        if rntmPwr.isLowPowerMode() then return false end
        local cd = tonumber(cfg.mqtt_offline_wake_cooldown_sec)
        if cd and cd > 0 and lastMqttWakeAt > 0
            and os.time() - lastMqttWakeAt < cd then
            return false
        end
        if cfg.block_mqtt_offline_wake_when_usb ~= false and rntmPwr.isUsbInserted() then
            return false
        end
    end
    return mayPowerT3x("mqtt_offline")
end

local function recMqttWake(reason)
    if reason == "mqtt_offline" then
        lastMqttWakeAt = os.time()
    end
end

function reqT3xWake(reason, sid, evt, opts)
    sid = sid or cfgm.get("HOST_WAKE_CFG").default_sid or 1
    evt = evt or 0
    opts = type(opts) == "table" and opts or {}
    return mayPowerT3x(reason, opts) and t3x_notify.wakeHost(sid, evt, {
        onDone = function()
            recMqttWake(reason)
        end,
    })
end

function bootPowerOn(t3xModule)
    return mayPowerT3x("boot") and t3xModule ~= nil and t3xModule.powerOn()
end

return _M
