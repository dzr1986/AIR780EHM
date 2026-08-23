-- ================================================================
-- Filename : usb_charge.lua
-- Module   : USB 充电检测：GPIO27/CHG_STATE 中断，发布 GPIO_USB_DET_CHANGED
-- Arch     : doc/modules/USB_CHARGE_POLICY.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local gpio_util = require "gpio_util"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local updateChg
local started = false
local usb_det_ready = false
local last_usb = nil
local last_chg = nil
local CHARGE_CONFIG = {
    usb_det_pin = nil,
    chg_state_pin = nil,
    usb_inserted_level = 0,
    chg_active_level = 1,
    debounce_ms = 50,
}
local function loadConfigFromGlobals()
    local gin = _G.GPIO_IN
    local usb = gin and gin.usb_det
    local chg = gin and gin.chg_state
    CHARGE_CONFIG.usb_det_pin = usb and usb.pin
    CHARGE_CONFIG.chg_state_pin = chg and chg.pin
    if usb and usb.active_level ~= nil then
        CHARGE_CONFIG.usb_inserted_level = usb.active_level
    end
    if chg and chg.active_level ~= nil then
        CHARGE_CONFIG.chg_active_level = chg.active_level
    end
    if usb and usb.debounce_ms then
        CHARGE_CONFIG.debounce_ms = usb.debounce_ms
    end
end
loadConfigFromGlobals()
local function cfg()
    return CHARGE_CONFIG
end

local function usbPin()
    return cfg().usb_det_pin
end

local function chgPin()
    return cfg().chg_state_pin
end

local function ensureUsbDetPin()
    if usb_det_ready then
        return true
    end
    local entry = (_G.GPIO_IN or {}).usb_det
    local pin = entry and entry.pin or usbPin()
    if not pin or not gpio or not gpio.setup then
        return false
    end
    gpio_util.setup_input(pin, function() end, {
        pull = entry and entry.pull,
        trigger_mode = entry and entry.trigger_mode or "both",
        debounce_ms = entry and entry.debounce_ms,
    })
    usb_det_ready = true
    return true
end

local function readUsbInse()
    if not ensureUsbDetPin() then
        return false
    end
    local pin = usbPin()
    if not pin or not gpio or not gpio.get then
        return false
    end
    return gpio.get(pin) == cfg().usb_inserted_level
end

local function readCharging()
    local pin = chgPin()
    if not pin or not gpio or not gpio.get then
        return false
    end
    return gpio.get(pin) == cfg().chg_active_level
end

local function effChar()
    return readUsbInse() and readCharging()
end

local function publishUsbChange(inserted)
    local ev = utils.appEvent("GPIO_USB_DET_CHANGED", "APP_GPIO_USB_DET_CHANGED")
    sys.publish(ev, inserted and 1 or 0)
end

local function publishChgChange(charging)
    local ev = utils.appEvent("GPIO_CHG_STATE_CHANGED", "APP_GPIO_CHG_STATE_CHANGED")
    sys.publish(ev, charging and 1 or 0)
end

local function updateUsb(inserted, fromIrq)
    if last_usb == inserted then
        return
    end
    last_usb = inserted
    if inserted and fromIrq then
        local peri = loader.load("peripheral")
        if peri and peri.cancelLongPress then
            peri.cancelLongPress("pwr")
        end
    end
    publishUsbChange(inserted)
    updateChg(effChar(), fromIrq)
end
updateChg = function(charging, fromIrq)
    if last_chg == charging then
        return
    end
    last_chg = charging
    publishChgChange(charging)
end

local function onUsbIrq(_level)
    updateUsb(readUsbInse(), true)
end

local function onChgIrq(_level)
    updateChg(effChar(), true)
end

local function setupPinIrq(entry, callback)
    return gpio_util.setup_input_entry(entry, callback)
end

function start()
    if started then
        return false
    end
    local c = cfg()
    if not c.usb_det_pin or not c.chg_state_pin then
        return false
    end
    if not gpio or not gpio.setup then
        return false
    end
    local gin = _G.GPIO_IN or {}
    ensureUsbDetPin()
    if not setupPinIrq(gin.usb_det, onUsbIrq) or not setupPinIrq(gin.chg_state, onChgIrq) then
        return false
    end
    started = true
    last_usb = readUsbInse()
    last_chg = effChar()
    return true
end

function isUsbInserted()
    return readUsbInse()
end

function isCharging()
    if not readUsbInse() then
        return 0
    end
    return effChar() and 1 or 0
end

local function usb_cfg()
    return _G.HOST_USB_CFG or {}
end

local function usbGatedPolicy(cfgKey)
    if usb_cfg()[cfgKey] == false then
        return false
    end
    return isUsbInserted()
end

function blocksHostIdle()
    return usbGatedPolicy("block_host_idle_when_usb")
end

function blocks4gRest()
    return usbGatedPolicy("block_4g_rest_when_usb")
end

function getState()
    return {
        started = started,
        mode = "irq",
        config = cfg(),
        usb_inserted = readUsbInse(),
        charging = isCharging(),
    }
end
return _M
