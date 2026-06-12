require "sys"
require "config"
local gpio_util = require "gpio_util"
local LOG_TAG = "t3x"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local isPoweredOn = false
local currentPowerLevel = nil
local isInBootMode = false
local currentBootLevel = nil
local currentOtaLevel = nil
local t3xPowerPin = nil
local t3xMcuIntPin = nil
local t3xBootModePin = nil
local t3xOtaPin = nil
local lastAction = nil
local pulseLowMs = 120
local bootDelay = 500
local powerOnLevel = 1
local powerOffLevel = 0
local bootModeLevel = 1
local otaModeLevel = 1
local state = {
    power_state = "off",
    last_wake_reason = nil,
    rest_enter_time = nil,
}
local function getEntries()
    local gout = _G.GPIO_OUT or {}
    return gout.t3x_pwr_wake, gout.t3x_mcu_int, gout.t3x_boot, gout.t3x_ota
end
local function gpioTag(pin, level)
    if pin == nil then
        return "gpio(?)=?"
    end
    return string.format("gpio(%d)=%d", pin, level or 0)
end
local function logGpioSet(action, entry_pwr, entry_boot, entry_ota, pwrLv, bootLv, otaLv)
    log.info(LOG_TAG, action,
        gpioTag(entry_pwr and entry_pwr.pin, pwrLv),
        gpioTag(entry_boot and entry_boot.pin, bootLv),
        gpioTag(entry_ota and entry_ota.pin, otaLv))
end
local function getWakePulseMs()
    local cfg = _G.HOST_WAKE_CFG or {}
    return tonumber(cfg.pulse_ms) or pulseLowMs
end
local function getMcuIntLevels(entry_int)
    local cfg = _G.HOST_WAKE_CFG or {}
    local idle = cfg.idle_level
    if idle == nil then
        idle = entry_int and entry_int.init_level or 1
    end
    local active = cfg.pulse_level
    if active == nil then
        active = entry_int and entry_int.on_level or 0
    end
    return idle, active
end
local function refreshLevels()
    local entry_pwr, _, entry_boot, entry_ota = getEntries()
    powerOnLevel = entry_pwr and entry_pwr.on_level or 1
    powerOffLevel = entry_pwr and entry_pwr.init_level or 0
    bootModeLevel = entry_boot and entry_boot.on_level or 1
    otaModeLevel = entry_ota and entry_ota.on_level or 1
end
local function ensurePins()
    refreshLevels()
    local entry_pwr, entry_int, entry_boot, entry_ota = getEntries()
    if not entry_pwr or not entry_pwr.pin then
    elseif not t3xPowerPin then
        t3xPowerPin = gpio_util.setup_output(entry_pwr)
    end
    if not entry_int or not entry_int.pin then
    elseif not t3xMcuIntPin then
        t3xMcuIntPin = gpio_util.setup_output(entry_int)
    end
    if not entry_boot or not entry_boot.pin then
    elseif not t3xBootModePin then
        t3xBootModePin = gpio_util.setup_output(entry_boot)
    end
    if not entry_ota or not entry_ota.pin then
    elseif not t3xOtaPin then
        t3xOtaPin = gpio_util.setup_output(entry_ota)
    end
    return entry_pwr, entry_int, entry_boot, entry_ota
end
function start()
    ensurePins()
    local ok, policy = pcall(require, "t3x_policy")
    if ok and type(policy) == "table" and policy.bootPowerOn then
        policy.bootPowerOn(_M)
    else
        powerOn()
    end
    return true
end
function powerOn()
    local entry_pwr, _, entry_boot, entry_ota = ensurePins()
    if not t3xPowerPin then
        return false
    end
    if isPoweredOn and currentPowerLevel == powerOnLevel then
        return true
    end
    t3xPowerPin(powerOnLevel)
    currentPowerLevel = powerOnLevel
    isPoweredOn = true
    state.power_state = "on"
    lastAction = "powerOn"
    logGpioSet("pwr+", entry_pwr, entry_boot, entry_ota,
        powerOnLevel, currentBootLevel, currentOtaLevel)
    return true
end
function pulseMcuInt()
    local _, entry_int = getEntries()
    ensurePins()
    if not t3xMcuIntPin then
        return false
    end
    local idle, active = getMcuIntLevels(entry_int)
    local ms = getWakePulseMs()
    t3xMcuIntPin(active)
    sys.timerStart(function()
        t3xMcuIntPin(idle)
        lastAction = "pulseMcuInt"
        log.info(LOG_TAG, "wake", "pin", entry_int.pin, "ms", ms,
            "idle", idle, "active", active)
    end, ms)
    return true
end
function pulseWakeup()
    return pulseMcuInt()
end
function powerOff()
    local entry_pwr, _, entry_boot, entry_ota = ensurePins()
    if not t3xPowerPin then
        return false
    end
    t3xPowerPin(powerOffLevel)
    currentPowerLevel = powerOffLevel
    isPoweredOn = false
    state.power_state = "off"
    lastAction = "powerOff"
    logGpioSet("pwr-", entry_pwr, entry_boot, entry_ota,
        powerOffLevel, currentBootLevel, currentOtaLevel)
    return true
end
function enterBootMode()
    local entry_pwr, _, entry_boot, entry_ota = ensurePins()
    if not t3xPowerPin or not t3xBootModePin or not t3xOtaPin then
        log.warn(LOG_TAG, "bootFail",
            gpioTag(entry_pwr and entry_pwr.pin, nil),
            gpioTag(entry_boot and entry_boot.pin, nil),
            gpioTag(entry_ota and entry_ota.pin, nil))
        return false
    end
    powerOff()
    sys.timerStart(function()
        t3xBootModePin(bootModeLevel)
        t3xOtaPin(otaModeLevel)
        currentBootLevel = bootModeLevel
        currentOtaLevel = otaModeLevel
        isInBootMode = true
        logGpioSet("bootIO", entry_pwr, entry_boot, entry_ota,
            powerOffLevel, bootModeLevel, otaModeLevel)
    end, bootDelay)
    sys.timerStart(function()
        powerOn()
    end, bootDelay)
    lastAction = "enterBootMode"
    return true
end
function pulseUsbDebugEn(opts)
    opts = type(opts) == "table" and opts or {}
    local entry_pwr, _, entry_boot, entry_ota = getEntries()
    ensurePins()
    if not t3xOtaPin or not entry_ota or not entry_ota.pin then
        return false
    end
    local usbCfg = _G.HOST_USB_CFG or {}
    local high_ms = tonumber(opts.high_ms) or tonumber(usbCfg.usb_debug_en_pulse_ms) or 300
    if high_ms < 0 then
        high_ms = 0
    end
    local otaOff = entry_ota.init_level or 0
    t3xOtaPin(otaModeLevel)
    currentOtaLevel = otaModeLevel
    if high_ms > 0 then
        sys.wait(high_ms)
    end
    t3xOtaPin(otaOff)
    currentOtaLevel = otaOff
    lastAction = "pulseUsbDebugEn"
    log.info(LOG_TAG, "usbRst", "pin", entry_ota.pin,
        "high_ms", high_ms, "off", otaOff)
    logGpioSet("USB_DEBUG_EN", entry_pwr, entry_boot, entry_ota,
        currentPowerLevel, currentBootLevel, otaOff)
    return true
end
function exitBootMode()
    local entry_pwr, _, entry_boot, entry_ota = getEntries()
    ensurePins()
    if not t3xBootModePin or not t3xOtaPin then
        return false
    end
    local bootOff = 1 - bootModeLevel
    local otaOff = 1 - otaModeLevel
    t3xBootModePin(bootOff)
    t3xOtaPin(otaOff)
    currentBootLevel = bootOff
    currentOtaLevel = otaOff
    isInBootMode = false
    lastAction = "exitBootMode"
    logGpioSet("bootX", entry_pwr, entry_boot, entry_ota,
        currentPowerLevel, bootOff, otaOff)
    return true
end
function enterSleep(opts)
    if state.power_state == "sleeping" then
        return
    end
    opts = type(opts) == "table" and opts or {}
    if opts.skip_pending_work_check ~= true then
        local okHu, hu = pcall(require, "host_uart")
        local okHe, he = pcall(require, "host_event")
        if okHu and hu and hu.buildHostEvtBody and okHe and he and he.shouldBlockT3xSleep then
            local body = hu.buildHostEvtBody()
            if he.shouldBlockT3xSleep(body) then
                return false
            end
        end
    end
    state.power_state = "sleeping"
    state.rest_enter_time = os.time()
    if opts.modemHibernate == true then
        pm.hibernate()
        return
    end
    if isPoweredOn then
        local ipcCfg = _G.HOST_IPC_CFG or {}
        if ipcCfg.graceful_poweroff ~= false then
            local playSound = opts.ipc_poweroff_sound
            if playSound == nil then
                playSound = ipcCfg.poweroff_play_sound
            end
            gracefulPowerOff({
                play_sound = playSound,
                poweroff_timeout_ms = opts.ipc_poweroff_timeout_ms,
                status_timeout_ms = opts.ipc_status_timeout_ms,
            })
        else
            powerOff()
        end
    end
end
function wake()
    state.last_wake_reason = rtos.last_wake_reason and rtos.last_wake_reason() or nil
    if not isPoweredOn then
        powerOn()
    end
    pulseMcuInt()
end
function enterDeepSleep()
    state.power_state = "sleeping"
    if _G.uart_bridge and _G.uart_bridge.stop then
        _G.uart_bridge.stop()
    elseif _G.UART_CFG and _G.UART_CFG.id then
        uart.close(_G.UART_CFG.id)
    end
    pm.deepSleep()
end
function getState()
    local entry_pwr, entry_int, entry_boot, entry_ota = getEntries()
    return {
        powered_on = isPoweredOn,
        power_level = currentPowerLevel,
        in_boot_mode = isInBootMode,
        boot_level = currentBootLevel,
        ota_level = currentOtaLevel,
        power_state = state.power_state,
        last_wake_reason = state.last_wake_reason,
        rest_enter_time = state.rest_enter_time,
        last_action = lastAction,
        pins = {
            pwr = entry_pwr and entry_pwr.pin,
            mcu_int = entry_int and entry_int.pin,
            boot = entry_boot and entry_boot.pin,
            ota = entry_ota and entry_ota.pin,
        },
    }
end
local function ipcCfg()
    return _G.HOST_IPC_CFG or {}
end
local function ipcEnabled()
    return ipcCfg().enabled ~= false
end
local function ipcHostUart()
    local ok, mod = pcall(require, "host_uart")
    return ok and mod or nil
end
local function ipcInTask()
    return coroutine.running() ~= nil
end
function ensurePowered(tag, opts)
    opts = type(opts) == "table" and opts or {}
    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.mayPowerT3x
        and not policy.mayPowerT3x(tag or "t3x_ipc") then
        return false
    end
    if isPoweredOn then
        return true
    end
    powerOn()
    local waitMs = tonumber(opts.power_wait_ms)
    if waitMs == nil then
        waitMs = tonumber(opts.t3x_power_wait_ms)
            or tonumber(ipcCfg().t3x_power_wait_ms)
            or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
            or tonumber((_G.SOUND_CFG or {}).t3x_power_wait_ms)
            or 800
    end
    if waitMs > 0 and ipcInTask() then
        sys.wait(waitMs)
    end
    return true
end
function gracefulPowerOff(opts)
    opts = type(opts) == "table" and opts or {}
    if not ipcInTask() then
        powerOff()
        local hu = ipcHostUart()
        if hu and hu.resetHostLinkState then
            hu.resetHostLinkState()
        end
        return true
    end
    local hu = ipcHostUart()
    local playSound = opts.play_sound
    if playSound == nil then
        playSound = ipcCfg().poweroff_play_sound ~= false
    end
    if ipcEnabled() and hu then
        local st = hu.queryHostIpcStatus and hu.queryHostIpcStatus(opts.status_timeout_ms)
        if st == "ready" or st == "shutting_down" then
            if hu.hostIpcPowerOff then
                hu.hostIpcPowerOff(playSound, opts.poweroff_timeout_ms)
            end
        elseif st == "idle" then
        end
    end
    powerOff()
    if hu and hu.resetHostLinkState then
        hu.resetHostLinkState()
    end
    return true
end
function powerOnWaitReady(opts)
    opts = type(opts) == "table" and opts or {}
    if not ipcInTask() then
        return false
    end
    local hu = ipcHostUart()
    if ipcEnabled() and hu and hu.queryHostIpcStatus then
        local st = hu.queryHostIpcStatus(opts.status_timeout_ms)
        if st == "ready" then
            return true
        end
    end
    if not isPoweredOn then
        powerOn()
        sys.wait(tonumber(opts.power_wait_ms)
            or tonumber(ipcCfg().t3x_power_wait_ms)
            or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
            or 800)
    end
    if ipcEnabled() and hu and hu.waitHostIpcReady then
        return hu.waitHostIpcReady(opts.ready_timeout_ms, opts.poll_ms)
    end
    sys.wait(tonumber(ipcCfg().host_boot_wait_ms)
        or tonumber((_G.TIME_SYNC_CFG or {}).host_boot_wait_ms)
        or 1500)
    return hu and hu.isHostAtReady and hu.isHostAtReady() or true
end
return _M
