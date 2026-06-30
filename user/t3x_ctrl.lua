-- T3x 协处理器电源控制：GPIO22 上断电、GPIO29 唤醒、优雅 IPC 关机
-- 休眠互斥：enterSleep 期间 sleep_in_progress；唤醒前 waitSleepIdle
-- 文档：doc/LUA_MODULES.md §3.7
require "sys"
require "config"
local gpio_util = require "gpio_util"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local L = "t3x_ctrl"

-- ---------------------------------------------------------------------------
-- GPIO 与电源状态
-- ---------------------------------------------------------------------------

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
local sleep_in_progress = false

local modCache = {}
local function loadMod(name)
    local mod = modCache[name]
    if mod ~= nil then
        return mod or nil
    end
    local ok, loaded = pcall(require, name)
    modCache[name] = ok and loaded or false
    return ok and loaded or nil
end

local function t3xPolicyMod()
    return loadMod("t3x_policy")
end

local function hostUartMod()
    return loadMod("host_uart")
end

local function hostEventMod()
    return loadMod("host_event")
end

local function getEntries()
    local gout = _G.GPIO_OUT or {}
    return gout.t3x_pwr_wake, gout.t3x_mcu_int, gout.t3x_boot, gout.t3x_ota
end

local function gpioLv(pin, lv)
    if pin == nil then
        return "?"
    end
    return tostring(pin) .. "=" .. tostring(lv or "?")
end

local function logGpio(action, entry_pwr, entry_boot, entry_ota, pwrLv, bootLv, otaLv)
    log.info(L, action,
        "pwr", gpioLv(entry_pwr and entry_pwr.pin, pwrLv),
        "boot", gpioLv(entry_boot and entry_boot.pin, bootLv),
        "ota", gpioLv(entry_ota and entry_ota.pin, otaLv))
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

local function setupOutputIfNeeded(entry, pinRef)
    if entry and entry.pin and not pinRef then
        return gpio_util.setup_output(entry)
    end
    return pinRef
end

local function ensurePins()
    refreshLevels()
    local entry_pwr, entry_int, entry_boot, entry_ota = getEntries()
    t3xPowerPin = setupOutputIfNeeded(entry_pwr, t3xPowerPin)
    t3xMcuIntPin = setupOutputIfNeeded(entry_int, t3xMcuIntPin)
    t3xBootModePin = setupOutputIfNeeded(entry_boot, t3xBootModePin)
    t3xOtaPin = setupOutputIfNeeded(entry_ota, t3xOtaPin)
    return entry_pwr, entry_int, entry_boot, entry_ota
end

local function applyPowerLevel(on)
    ensurePins()
    if not t3xPowerPin then
        return false
    end
    local level = on and powerOnLevel or powerOffLevel
    if on and isPoweredOn and currentPowerLevel == level then
        return true
    end
    t3xPowerPin(level)
    currentPowerLevel = level
    isPoweredOn = on
    state.power_state = on and "on" or "off"
    lastAction = on and "powerOn" or "powerOff"
    if on then
        local okBg, bg = pcall(require, "battery_guard")
        if okBg and type(bg) == "table" and bg.markT3xWoken then
            bg.markT3xWoken()
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 启动与基础电源控制
-- ---------------------------------------------------------------------------

function start()
    ensurePins()
    local policy = t3xPolicyMod()
    if type(policy) == "table" and policy.bootPowerOn then
        policy.bootPowerOn(_M)
    else
        powerOn()
    end
    return true
end

function isSleepInProgress()
    return sleep_in_progress == true
end

function waitSleepIdle(timeoutMs)
    if not sleep_in_progress then
        return true
    end
    if not coroutine.running() then
        return false
    end
    timeoutMs = tonumber(timeoutMs) or 20000
    local elapsed = 0
    local step = 50
    while sleep_in_progress and elapsed < timeoutMs do
        sys.wait(step)
        elapsed = elapsed + step
    end
    return not sleep_in_progress
end

local function waitBeforeWake()
    waitSleepIdle(20000)
end

function powerOn()
    waitBeforeWake()
    return applyPowerLevel(true)
end

function powerOff()
    return applyPowerLevel(false)
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
    end, ms)
    return true
end

function pulseWakeup()
    return pulseMcuInt()
end

-- ---------------------------------------------------------------------------
-- Boot / OTA 模式
-- ---------------------------------------------------------------------------

function enterBootMode()
    log.info(L, "t3x_boot_mode_enter")
    local entry_pwr, _, entry_boot, entry_ota = ensurePins()
    if not t3xPowerPin or not t3xBootModePin or not t3xOtaPin then
        log.warn(L, "t3x_boot_mode_enter_fail",
            "pwr", gpioLv(entry_pwr and entry_pwr.pin, nil),
            "boot", gpioLv(entry_boot and entry_boot.pin, nil),
            "ota", gpioLv(entry_ota and entry_ota.pin, nil))
        return false
    end
    powerOff()
    logGpio("t3x_power_off", entry_pwr, entry_boot, entry_ota,
        powerOffLevel, currentBootLevel, currentOtaLevel)
    sys.timerStart(function()
        t3xBootModePin(bootModeLevel)
        t3xOtaPin(otaModeLevel)
        currentBootLevel = bootModeLevel
        currentOtaLevel = otaModeLevel
        isInBootMode = true
        logGpio("t3x_boot_ota_levels_set", entry_pwr, entry_boot, entry_ota,
            powerOffLevel, bootModeLevel, otaModeLevel)
    end, bootDelay)
    sys.timerStart(function()
        powerOn()
        logGpio("t3x_power_on", entry_pwr, entry_boot, entry_ota,
            powerOnLevel, bootModeLevel, otaModeLevel)
    end, bootDelay)
    lastAction = "enterBootMode"
    return true
end

function pulseUsbDebugEn(opts)
    opts = type(opts) == "table" and opts or {}
    local entry_pwr, _, entry_boot, entry_ota = getEntries()
    ensurePins()
    if not t3xOtaPin or not entry_ota or not entry_ota.pin then
        return false, 0
    end
    local usbCfg = _G.HOST_USB_CFG or {}
    local high_ms = tonumber(opts.high_ms) or tonumber(usbCfg.usb_debug_en_pulse_ms) or 300
    if high_ms < 0 then
        high_ms = 0
    end
    local otaOff = entry_ota.init_level or 0
    local function finishPulse()
        t3xOtaPin(otaOff)
        currentOtaLevel = otaOff
        lastAction = "pulseUsbDebugEn"
    end
    t3xOtaPin(otaModeLevel)
    currentOtaLevel = otaModeLevel
    if high_ms <= 0 then
        finishPulse()
        return true, 0
    end
    sys.timerStart(finishPulse, high_ms)
    return true, high_ms
end

function exitBootMode()
    log.info(L, "t3x_boot_mode_exit")
    local entry_pwr, _, entry_boot, entry_ota = ensurePins()
    if not t3xBootModePin or not t3xOtaPin then
        log.warn(L, "t3x_boot_mode_exit_fail")
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
    return true
end

-- ---------------------------------------------------------------------------
-- 休眠 / 唤醒
-- ---------------------------------------------------------------------------

local function shouldBlockSleep(opts)
    if opts.skip_pending_work_check == true then
        return false
    end
    local hu = hostUartMod()
    local he = hostEventMod()
    if not hu or not hu.buildHostEvtBody or not he or not he.shouldBlockT3xSleep then
        return false
    end
    return he.shouldBlockT3xSleep(hu.buildHostEvtBody()) == true
end

local function shutdownPoweredT3x(opts)
    if not isPoweredOn then
        return
    end
    local ipcCfg = _G.HOST_IPC_CFG or {}
    if ipcCfg.graceful_poweroff == false then
        powerOff()
        return
    end
    local playSound = opts.ipc_poweroff_sound
    if playSound == nil then
        playSound = ipcCfg.poweroff_play_sound
    end
    gracefulPowerOff({
        play_sound = playSound,
        poweroff_timeout_ms = opts.ipc_poweroff_timeout_ms,
        status_timeout_ms = opts.ipc_status_timeout_ms,
    })
end

function enterSleep(opts)
    if state.power_state == "sleeping" then
        return
    end
    opts = type(opts) == "table" and opts or {}
    if shouldBlockSleep(opts) then
        return false
    end
    state.power_state = "sleeping"
    state.rest_enter_time = os.time()
    if opts.modemHibernate == true then
        pm.hibernate()
        return
    end
    sleep_in_progress = true
    local ok, err = pcall(shutdownPoweredT3x, opts)
    sleep_in_progress = false
    if not ok then
        log.warn(L, "enter_sleep_fail", tostring(err))
    end
end

function wake()
    waitBeforeWake()
    state.last_wake_reason = rtos.last_wake_reason and rtos.last_wake_reason() or nil
    if not isPoweredOn then
        applyPowerLevel(true)
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
        sleep_in_progress = sleep_in_progress,
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

-- ---------------------------------------------------------------------------
-- IPC 上电 / 优雅关机 / 就绪等待
-- ---------------------------------------------------------------------------

local function ipcCfg()
    return _G.HOST_IPC_CFG or {}
end

local function ipcEnabled()
    return ipcCfg().enabled ~= false
end

local function ipcHostUart()
    return hostUartMod()
end

local function ipcInTask()
    return coroutine.running() ~= nil
end

local function resolvePowerWaitMs(opts)
    opts = type(opts) == "table" and opts or {}
    local waitMs = tonumber(opts.power_wait_ms) or tonumber(opts.t3x_power_wait_ms)
    if waitMs ~= nil then
        return waitMs
    end
    return tonumber(ipcCfg().t3x_power_wait_ms)
        or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
        or tonumber((_G.SOUND_CFG or {}).t3x_power_wait_ms)
        or 800
end

local function resetHostLink(hu)
    if hu and hu.resetHostLinkState then
        hu.resetHostLinkState()
    end
end

function ensurePowered(tag, opts)
    opts = type(opts) == "table" and opts or {}
    waitBeforeWake()
    local policy = t3xPolicyMod()
    if type(policy) == "table" and policy.mayPowerT3x
        and not policy.mayPowerT3x(tag or "t3x_ipc") then
        return false
    end
    if isPoweredOn then
        return true
    end
    powerOn()
    local waitMs = resolvePowerWaitMs(opts)
    if waitMs > 0 and ipcInTask() then
        sys.wait(waitMs)
    end
    return true
end

function gracefulPowerOff(opts)
    opts = type(opts) == "table" and opts or {}
    local hu = ipcHostUart()
    if not ipcInTask() then
        powerOff()
        resetHostLink(hu)
        return true
    end
    local playSound = opts.play_sound
    if playSound == nil then
        playSound = ipcCfg().poweroff_play_sound ~= false
    end
    if ipcEnabled() and hu and hu.queryHostIpcStatus then
        local st = hu.queryHostIpcStatus(opts.status_timeout_ms)
        if (st == "ready" or st == "shutting_down") and hu.hostIpcPowerOff then
            hu.hostIpcPowerOff(playSound, opts.poweroff_timeout_ms)
        end
    end
    powerOff()
    resetHostLink(hu)
    return true
end

function powerOnWaitReady(opts)
    opts = type(opts) == "table" and opts or {}
    if not ipcInTask() then
        return false
    end
    local hu = ipcHostUart()
    if ipcEnabled() and hu and hu.queryHostIpcStatus then
        if hu.queryHostIpcStatus(opts.status_timeout_ms) == "ready" then
            return true
        end
    end
    if not isPoweredOn then
        powerOn()
        sys.wait(resolvePowerWaitMs(opts))
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
