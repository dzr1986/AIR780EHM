-- 文档：doc/modules/T3X_POWER_WAKEUP.md
require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "t3x_policy"
local lastDenyReason = ""
local lastMqttOfflineWakeSec = 0

-- ---------------------------------------------------------------------------
-- 配置与运行时快照
-- ---------------------------------------------------------------------------

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
    return rt and tonumber(rt.power_status) == 1
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

local function isBatteryDynamicRest()
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.battery_dynamic_rest) == 1 then
        return true
    end
    local ok, bg = pcall(require, "battery_guard")
    if ok and type(bg) == "table" and bg.isBatteryDynamicRest then
        return bg.isBatteryDynamicRest() == true
    end
    return false
end

function isBurnActive()
    return _G.T3X_BURN_MODE_ACTIVE == true
end

-- ---------------------------------------------------------------------------
-- 唤醒原因分类
-- ---------------------------------------------------------------------------

local function isWledWakeReason(reason)
    return tostring(reason or "") == "wled"
end

local function isPirWakeReason(reason)
    reason = tostring(reason or "")
    if reason == "notify_host" or reason == "pir_media" or reason == "exit_low_power" then
        return true
    end
    return reason:sub(1, 9) == "pir_stop"
end

local function allowsWakeInRest(reason)
    if cfg().allow_wled_wake_in_rest ~= false and isWledWakeReason(reason) then
        return true
    end
    if not isPirWakeReason(reason) then
        return false
    end
    if cfg().allow_pir_wake_in_rest ~= false then
        return true
    end
    if cfg().allow_pir_wake_in_battery_rest ~= false and isBatteryDynamicRest() then
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- mayPowerT3x：T3x 上电/唤醒门禁
-- ---------------------------------------------------------------------------

local function policyDisabled()
    if cfg().enabled == false then
        return true
    end
    local flags = _G.MODULE_FLAGS
    return flags and flags.t3x_policy == false
end

local function passesUsbGate(reason)
    if not isUsbInserted() then
        return false
    end
    if reason == "mqtt_offline" and cfg().allow_mqtt_offline_wake_when_usb ~= true then
        return false
    end
    return true
end

local function passesLowPowerGate(reason, opts)
    if cfg().block_wake_in_low_power == false or not isLowPowerMode() then
        return true
    end
    if allowsWakeInRest(reason) then
        return true
    end
    lastDenyReason = "low_power_mode=rest"
    return false
end

local function passesBatteryGate()
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

function mayPowerT3x(reason, opts)
    opts = type(opts) == "table" and opts or {}
    lastDenyReason = ""
    if policyDisabled() or isBurnActive() or passesUsbGate(reason) or opts.force_wake then
        return true
    end
    if not passesLowPowerGate(reason, opts) then
        return false
    end
    return passesBatteryGate()
end

-- ---------------------------------------------------------------------------
-- MQTT 离线唤醒
-- ---------------------------------------------------------------------------

function shouldWakeOnMqttOffline()
    lastDenyReason = ""
    if cfg().block_mqtt_offline_wake == false then
        return mayPowerT3x("mqtt_offline")
    end
    if isLowPowerMode() then
        lastDenyReason = "mqtt_offline+rest"
        return false
    end
    local cd = tonumber(cfg().mqtt_offline_wake_cooldown_sec)
    if cd and cd > 0 and lastMqttOfflineWakeSec > 0 then
        local elapsed = os.time() - lastMqttOfflineWakeSec
        if elapsed < cd then
            lastDenyReason = string.format("mqtt_offline_cooldown_%ds", cd - elapsed)
            return false
        end
    end
    if cfg().block_mqtt_offline_wake_when_usb ~= false and isUsbInserted() then
        lastDenyReason = "mqtt_offline+usb"
        return false
    end
    return mayPowerT3x("mqtt_offline")
end

-- ---------------------------------------------------------------------------
-- requestT3xWake：策略通过后分发唤醒
-- ---------------------------------------------------------------------------

local function recordMqttOfflineWake(reason)
    if reason == "mqtt_offline" then
        lastMqttOfflineWakeSec = os.time()
    end
end

local function notifyViaTimeSync(sid, evt)
    local okTs, time_sync = pcall(require, "time_sync")
    if not okTs or not time_sync or not time_sync.pushBeforeNotifyAsync then
        return false
    end
    if _G.MODULE_FLAGS and _G.MODULE_FLAGS.time_sync == false then
        return false
    end
    time_sync.pushBeforeNotifyAsync(sid, evt)
    return true
end

local function notifyViaHostUart(sid, evt)
    local hu = _G.host_uart
    if not hu then
        local ok, mod = pcall(require, "host_uart")
        hu = ok and mod or nil
    end
    if hu and hu.notify_host then
        return hu.notify_host(sid, evt) ~= false
    end
    return false
end

local function fallbackGpioWake(reason)
    local t3x = _G.t3x_ctrl
    if not t3x then
        local ok, mod = pcall(require, "t3x_ctrl")
        t3x = ok and mod or nil
    end
    if not t3x or not t3x.wake then
        return false
    end
    sys.taskInit(function()
        t3x.wake()
        recordMqttOfflineWake(reason)
    end)
    return true
end

function requestT3xWake(reason, sid, evt, opts)
    reason = reason or "wake"
    sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
    evt = evt or 0
    opts = type(opts) == "table" and opts or {}
    if not mayPowerT3x(reason, opts) then
        return false
    end
    if not (_G.MODULE_FLAGS and _G.MODULE_FLAGS.t3x_wakeup
        and (_G.MODULE_FLAGS.t3x_app ~= false)) then
        return fallbackGpioWake(reason)
    end
    if notifyViaTimeSync(sid, evt) then
        recordMqttOfflineWake(reason)
        return true
    end
    if notifyViaHostUart(sid, evt) then
        recordMqttOfflineWake(reason)
        return true
    end
    return fallbackGpioWake(reason)
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
