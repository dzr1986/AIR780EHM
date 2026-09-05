-- ================================================================
-- Filename : usb_power_policy.lua
-- Module   : USB 边沿策略：power_status、T31x +CAT1:USB、rest 进/出、PWRKEY 宽限
-- Layer    : L2（app 经 bind 注入 gpio/rndis/低功耗 hook；PMD 回退经 onPmdMessage）
-- Arch     : doc/modules/USB_CHARGE_POLICY.md · doc/power/T31X_USB_HOSTIDLE.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local gpio_util = require "gpio_util"
local host_uart = require "host_uart"
local batteryGuard = require "battery_guard"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local E = APP_EVENTS
local logFuncs = utils.mkLogFns("usb_policy")
local polInfo = logFuncs.info

local deps = {}
local state = {
    usb_insert_tick = 0,
}

local TIMEOUT = {
    bootUsbNotifyDefault = 1500,
}

function bind(opts)
    deps = opts or {}
end

local function getUsbRndis()
    return type(deps.getUsbRndis) == "function" and deps.getUsbRndis() or nil
end

local function getGpio()
    return type(deps.getGpio) == "function" and deps.getGpio() or nil
end

local function isLowPowerEnabled()
    return type(deps.isLowPowerEnabled) == "function" and deps.isLowPowerEnabled() == true
end

function isInserted(opts)
    opts = opts or {}
    if opts.bootGpio and not loader.enabled("charge") then
        return gpio and gpio.VBUS and gpio_util.getLevel(gpio.VBUS) == 1
    end
    return rntmPwr.isUsbInserted()
end

local function notifyT31xIdle(inserted)
    host_uart.pushUsbIdle(inserted == true or inserted == 1)
end

local function onRemovedEnterRest(source)
    if not isLowPowerEnabled() then
        return
    end
    local usbRndis = getUsbRndis()
    if usbRndis and usbRndis.isEnabled() then
        return
    end
    if loader.enabled("battery_guard") then
        batteryGuard.onUsbRemove()
    elseif not rntmPwr.isLowPowerMode() then
        if type(deps.onEnterLowPower) == "function" then
            deps.onEnterLowPower("usb_remove")
        end
    end
end

local function onInsertedExitRest(source)
    if loader.enabled("battery_guard") then
        batteryGuard.onUsbIns({ source = source })
    elseif type(deps.onExitLowPower) == "function" then
        deps.onExitLowPower("usb_insert")
    end
end

function cancelPwrKeyLongPress()
    local gpioModule = getGpio()
    if gpioModule then
        gpioModule.cancelLongPress("pwr")
    end
end

function applyPower(inserted, source)
    local v = rntmPwr.setPowerStatus(inserted)
    polInfo("usb_state", v, tostring(source or ""))
    sys.publish(E.GPIO_VBUS_CHANGED, v)
    if v == 0 then
        notifyT31xIdle(false)
        onRemovedEnterRest(source)
    else
        state.usb_insert_tick = utils.nowMs()
        cancelPwrKeyLongPress()
        onInsertedExitRest(source)
        notifyT31xIdle(true)
    end
end

function onPmdMessage(msg)
    if not msg or loader.enabled("charge") then
        return
    end
    if msg.state == 0 or msg.state == 1 then
        applyPower(msg.state == 1, "PMD")
    else
        -- 非插拔态仅同步充电位，避免与 applyPower 重复广播
        local v = rntmPwr.setPowerStatus(msg.charger)
        sys.publish(E.GPIO_VBUS_CHANGED, v)
    end
end

function initBootPower()
    local inserted = isInserted({ bootGpio = true })
    if not inserted and not isLowPowerEnabled() then
        rntmPwr.setPowerStatus(0)
        sys.publish(E.GPIO_VBUS_CHANGED, 0)
        return
    end
    if not loader.enabled("pmd_runtime") then
        applyPower(inserted, "boot")
    else
        local v = rntmPwr.setPowerStatus(inserted)
        sys.publish(E.GPIO_VBUS_CHANGED, v)
    end
end

function schedBootNotify(defaultDelayMs)
    local usbCfg = cfgm.get("HOST_USB_CFG")
    if usbCfg.notify_t31x_usb_state == false then
        return
    end
    local delayMs = tonumber(usbCfg.boot_notify_delay_ms)
        or tonumber(cfgm.get("TIME_SYNC_CFG").hostBootWaitMs)
        or tonumber(defaultDelayMs)
        or TIMEOUT.bootUsbNotifyDefault
    sys.timerStart(function()
        notifyT31xIdle(isInserted())
    end, delayMs)
end

function onGpioDetChanged(inserted)
    applyPower(inserted == 1, "GPIO27")
end

function onHostFirstAt()
    notifyT31xIdle(isInserted())
end

function shouldBlockPwrKeyLong()
    if state.usb_insert_tick <= 0 or not isInserted() then
        return false
    end
    local elapsed = utils.nowMs() - state.usb_insert_tick
    return elapsed < (tonumber(cfgm.get("HOST_USB_CFG").pwrkey_grace_ms) or 5000)
end

return _M
