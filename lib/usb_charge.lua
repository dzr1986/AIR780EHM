require "sys"
require "config"
local gpio_util = require "gpio_util"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "usb_charge"
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
    gpio.setup(
        pin,
        function() end,
        gpio_util.pull(entry and entry.pull or "pullup"),
        gpio_util.trigger_mode(entry and entry.trigger_mode or "both")
    )
    local debounce = entry and entry.debounce_ms
    if debounce and debounce > 0 and gpio.debounce then
        gpio.debounce(pin, debounce)
    end
    usb_det_ready = true
    return true
end
local function readUsbInserted()
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
local function publishUsbChange(inserted)
    local ev = (_G.APP_EVENTS and _G.APP_EVENTS.GPIO_USB_DET_CHANGED) or "APP_GPIO_USB_DET_CHANGED"
    sys.publish(ev, inserted and 1 or 0)
end
local function publishChgChange(charging)
    local ev = (_G.APP_EVENTS and _G.APP_EVENTS.GPIO_CHG_STATE_CHANGED) or "APP_GPIO_CHG_STATE_CHANGED"
    sys.publish(ev, charging and 1 or 0)
end
local function updateUsb(inserted, fromIrq)
    if last_usb == inserted then
        return
    end
    last_usb = inserted
    log.info(LOG_TAG, "USB_DET GPIO" .. tostring(usbPin()),
        inserted and "插入" or "拔出", fromIrq and "IRQ" or "init")
    publishUsbChange(inserted)
end
local function updateChg(charging, fromIrq)
    if last_chg == charging then
        return
    end
    last_chg = charging
    log.info(LOG_TAG, "CHG_STATE GPIO" .. tostring(chgPin()),
        charging and "充电中(硬件CHG_RED)" or "充满或未充(硬件CHG_BLUE)", fromIrq and "IRQ" or "init")
    publishChgChange(charging)
end
local function onUsbIrq(_level)
    updateUsb(readUsbInserted(), true)
end
local function onChgIrq(_level)
    updateChg(readCharging(), true)
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
    last_usb = readUsbInserted()
    last_chg = readCharging()
    log.info(LOG_TAG, "已启动(中断)",
        "USB_DET GPIO" .. tostring(c.usb_det_pin), last_usb and "插入" or "拔出",
        "CHG_STATE GPIO" .. tostring(c.chg_state_pin), last_chg and "充电" or "未充")
    return true
end
function getLevel()
    local pin = chgPin()
    if not pin or not gpio or not gpio.get then
        return 0
    end
    return gpio.get(pin)
end
function isUsbInserted()
    return readUsbInserted()
end
function isCharging()
    return readCharging() and 1 or 0
end
function getState()
    return {
        started = started,
        mode = "irq",
        config = cfg(),
        usb_inserted = readUsbInserted(),
        charging = isCharging(),
    }
end
return _M
