-- ================================================================
-- Filename : usb_charge.lua
-- Module   : USB 充电检测：GPIO27/CHG_STATE 中断，发布 GPIO_USB_DET_CHANGED
-- Arch     : doc/modules/USB_CHARGE_POLICY.md
-- ================================================================

require "sys"
require "config"
local gpio_util = require "gpio_util"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local updateCharging
local started = false
local usbDetReady = false
local lastUsb = nil
local lastCharging = nil
local cancelPressHook
local cachedGpioIn = nil
local readChargingPin

local function gpioIn()
    return cachedGpioIn or cfgm.get("GPIO_IN")
end

local function activeLevel(entry, default)
    if entry and entry.active_level ~= nil then
        return entry.active_level
    end
    return default
end

local function pinActive(entry, activeDefault)
    local pin = entry and entry.pin
    if pin == nil then
        return false
    end
    return gpio_util.getLevel(pin) == activeLevel(entry, activeDefault)
end

local function ensUsbDetPin()
    local entry = gpioIn().usb_det
    local pin = entry and entry.pin
    if pin ~= nil and gpio and gpio.setup then
        gpio_util.setupInput(pin, function() end, {
            pull = entry.pull,
            trigger_mode = entry.trigger_mode or "both",
            debounce_ms = entry.debounce_ms,
        })
        usbDetReady = true
        return true
    end
    return false
end

function isUsbInserted()
    return (usbDetReady or ensUsbDetPin()) and pinActive(gpioIn().usb_det, 0)
end

readChargingPin = function()
    return pinActive(gpioIn().chg_state, 1)
end

function snapshot()
    local usb = isUsbInserted()
    return {
        usb_inserted = usb,
        charging = (usb and readChargingPin()) and 1 or 0,
    }
end

local function effectiveCharging()
    return isUsbInserted() and readChargingPin()
end

local function pubUsbChange(inserted, fromIrq)
    if lastUsb == inserted then return end
    lastUsb = inserted
    if inserted and fromIrq and cancelPressHook then cancelPressHook() end
    sys.publish(APP_EVENTS.GPIO_USB_DET_CHANGED, inserted and 1 or 0)
    updateCharging(effectiveCharging())
end

updateCharging = function(charging)
    if lastCharging == charging then return end
    lastCharging = charging
    sys.publish(APP_EVENTS.GPIO_CHG_STATE_CHANGED, charging and 1 or 0)
end

local function onUsbIrq(_level)
    pubUsbChange(isUsbInserted(), true)
end

local function onChgIrq(_level)
    updateCharging(effectiveCharging())
end

function start()
    if started then return true end
    cachedGpioIn = cfgm.get("GPIO_IN")
    local gin = gpioIn()
    if (usbDetReady or ensUsbDetPin())
        and gpio_util.setupInputEntry(gin.usb_det, onUsbIrq)
        and gpio_util.setupInputEntry(gin.chg_state, onChgIrq) then
        started = true
        lastUsb = isUsbInserted()
        lastCharging = effectiveCharging()
        return true
    end
    return false
end

function onUsbInsert(cb)
    cancelPressHook = (type(cb) == "function") and cb or nil
end

function isCharging()
    return snapshot().charging == 1
end

local function usbPolicyActive(cfgKey)
    return cfgm.get("HOST_USB_CFG")[cfgKey] ~= false and isUsbInserted()
end

function blocksHostIdle()
    return usbPolicyActive("block_host_idle_when_usb")
end

function blocks4gRest()
    return usbPolicyActive("block_4g_rest_when_usb")
end

function getState()
    return {
        started = started,
        mode = "irq",
        usb_inserted = isUsbInserted(),
        charging = isCharging(),
    }
end

return _M
