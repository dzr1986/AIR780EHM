-- ================================================================
-- Filename : t31x_ctrl.lua
-- Module   : 协处理器电源控制：GPIO22 上断电、GPIO29 唤醒脉冲、BOOT/OTA 引脚、优雅 IPC 关机
-- Arch     : doc/modules/t31x_POWER_WAKEUP.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local svc = require "svc"
local gpio_util = require "gpio_util"
local powerHal = require "power_hal"
local loader = require "module_loader"
local cfgm = require "config_manager"
local t31xPolicy = require "t31x_policy"
local hostEvt = require "host_event"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("t31x_ctrl")
local t31xInfo = logFuncs.info
local t31xWarn = logFuncs.warn
local t31xError = logFuncs.error

local started = false
local isPoweredOn = false
local currentPowerLevel = nil
local isInBootMode = false
local currentBootLevel = nil
local currentOtaLevel = nil
local t31xPowerPin = nil
local t31xMcuIntPin = nil
local t31xBootPin = nil
local t31xOtaPin = nil
local lastAction = nil
local BOOT_DELAY_MS = 500
local sleepInProgress = false

local state = {
    power_state = "off",
    last_wake_reason = nil,
    rest_enter_time = nil,
}

local function gpioEntries()
    local g = cfgm.get("GPIO_OUT")
    return g.t31x_pwr_wake, g.t31x_mcu_int, g.t31x_boot, g.t31x_ota
end

local function levelOf(entry, key, default)
    if entry and entry[key] ~= nil then return entry[key] end
    return default
end

local function setOutIfNeed(entry, pinRef)
    if entry and entry.pin ~= nil and not pinRef then
        return gpio_util.setupOutput(entry)
    end
    return pinRef
end

local function ensPins()
    local entry_pwr, entry_int, entry_boot, entry_ota = gpioEntries()
    t31xPowerPin = setOutIfNeed(entry_pwr, t31xPowerPin)
    t31xMcuIntPin = setOutIfNeed(entry_int, t31xMcuIntPin)
    t31xBootPin = setOutIfNeed(entry_boot, t31xBootPin)
    t31xOtaPin = setOutIfNeed(entry_ota, t31xOtaPin)
    return entry_pwr, entry_int, entry_boot, entry_ota
end

local function driveBootOta(bootLvl, otaLvl)
    if t31xBootPin then
        t31xBootPin(bootLvl)
        currentBootLevel = bootLvl
    end
    if t31xOtaPin then
        t31xOtaPin(otaLvl)
        currentOtaLevel = otaLvl
    end
end

local function ensRunPins()
    local _, _, entry_boot, entry_ota = ensPins()
    driveBootOta(levelOf(entry_boot, "init_level", 0), levelOf(entry_ota, "init_level", 0))
    isInBootMode = false
end

local function applyPwrLvl(on)
    local entry_pwr = ensPins()
    if not t31xPowerPin then
        t31xError("power_pin_missing")
        return false
    end
    local level = on and levelOf(entry_pwr, "on_level", 1) or levelOf(entry_pwr, "init_level", 0)
    if on and isPoweredOn and currentPowerLevel == level then return true end
    t31xPowerPin(level)
    currentPowerLevel = level
    isPoweredOn = on
    t31xInfo("power", on and "on" or "off", level)
    state.power_state = on and "on" or "off"
    lastAction = on and "powerOn" or "powerOff"
    if on then
        local bg = loader.load("battery_guard")
        if bg then bg.markT31xWoken() end
    end
    return true
end

function start()
    if started then return true end
    started = true
    ensRunPins()
    t31xInfo("start")
    t31xPolicy.bootPowerOn(_M)
    return true
end

function waitSleepIdle(timeoutMs)
    if not sleepInProgress then return true end
    if not utils.inSysTask() then return false end
    timeoutMs = tonumber(timeoutMs) or 20000
    local elapsed = 0
    local step = 50
    while sleepInProgress and elapsed < timeoutMs do
        sys.wait(step)
        elapsed = elapsed + step
    end
    return not sleepInProgress
end

function ensNormalPwrOn(tag)
    local function doIt()
        waitSleepIdle(20000)
        local _, _, entry_boot, entry_ota = gpioEntries()
        local wasBurn = isInBootMode
            or currentBootLevel == levelOf(entry_boot, "on_level", 1)
            or currentOtaLevel == levelOf(entry_ota, "on_level", 1)
        ensRunPins()
        if wasBurn and isPoweredOn then
            t31xWarn("normal_power_cycle_clear_burn", tostring(tag or ""))
            applyPwrLvl(false)
            sys.wait(BOOT_DELAY_MS)
            ensRunPins()
        end
        local ok = applyPwrLvl(true)
        lastAction = "ensNormalPwrOn"
        t31xInfo("ensure_normal_power_on", tostring(tag or ""), wasBurn and "cycled" or "ok")
        return ok
    end
    if not utils.inSysTask() then
        sys.taskInit(doIt)
        return true
    end
    return doIt()
end

function powerOn()
    return ensNormalPwrOn("powerOn")
end

function powerOff()
    return applyPwrLvl(false)
end

function pulseMcuInt()
    local _, entry_int = ensPins()
    if not t31xMcuIntPin then
        t31xError("mcu_int_pin_missing")
        return false
    end
    local cfg = cfgm.get("HOST_WAKE_CFG")
    local idle = cfg.idle_level
    local active = cfg.pulse_level
    if idle == nil then idle = levelOf(entry_int, "init_level", 1) end
    if active == nil then active = levelOf(entry_int, "on_level", 0) end
    t31xMcuIntPin(active)
    sys.timerStart(function()
        t31xMcuIntPin(idle)
        lastAction = "pulseMcuInt"
    end, tonumber(cfg.pulse_ms) or 120)
    return true
end

function entBootMode()
    local _, _, entry_boot, entry_ota = ensPins()
    if not t31xPowerPin or not t31xBootPin or not t31xOtaPin then
        t31xError("enter_bootmode_pin_missing")
        return false
    end
    t31xWarn("enter_bootmode")
    applyPwrLvl(false)
    local bootOn = levelOf(entry_boot, "on_level", 1)
    local otaOn = levelOf(entry_ota, "on_level", 1)
    sys.timerStart(function()
        driveBootOta(bootOn, otaOn)
        isInBootMode = true
        applyPwrLvl(true)
    end, BOOT_DELAY_MS)
    lastAction = "enterBootMode"
    return true
end

function pulseUsbDebugEn(opts)
    opts = utils.optTable(opts)
    local _, _, _, entry_ota = ensPins()
    if not t31xOtaPin or not entry_ota or entry_ota.pin == nil then
        return false, 0
    end
    local highMs = tonumber(opts.highMs)
        or tonumber(cfgm.get("HOST_USB_CFG").usb_debug_en_pulse_ms)
        or 300
    if highMs < 0 then highMs = 0 end
    local otaOn = levelOf(entry_ota, "on_level", 1)
    local otaOff = levelOf(entry_ota, "init_level", 0)
    t31xOtaPin(otaOn)
    currentOtaLevel = otaOn
    local function finishPulse()
        t31xOtaPin(otaOff)
        currentOtaLevel = otaOff
        lastAction = "pulseUsbDebugEn"
    end
    if highMs == 0 then
        finishPulse()
        return true, 0
    end
    sys.timerStart(finishPulse, highMs)
    return true, highMs
end

function extBootMode()
    local _, _, entry_boot, entry_ota = ensPins()
    if not t31xBootPin or not t31xOtaPin then
        t31xError("exit_bootmode_pin_missing")
        return false
    end
    driveBootOta(1 - levelOf(entry_boot, "on_level", 1), 1 - levelOf(entry_ota, "on_level", 1))
    isInBootMode = false
    lastAction = "exitBootMode"
    t31xInfo("exit_bootmode")
    return true
end

-- 策略触发的休眠（USB 拔出 / 电量 / pir_watch_idle）在两种情况下延后：T31x 有待办事件，或
-- 串口处于破坏性会话（TF 格式化 / 断电中 / USB 恢复）——此时切电等于写盘中拔卡。
-- 用户显式 2002/AT（skipPendingWorkCheck）不在此拦，由 hostIpcPowerOff 有界等待会话结束再优雅断电。
local function blockSleep(opts)
    if opts.skipPendingWorkCheck == true then return false end
    local hif = svc.hostUart()
    if not hif then return false end
    local session = hif.getUartSession and hif.getUartSession()
    if session then
        t31xWarn("sleep_blocked_uart_session", tostring(session))
        return true
    end
    return hostEvt.shouldBlockT31xSleep(hif.bldHostEvtBody()) == true
end

local function shutdownT31x(opts)
    if not isPoweredOn then return end
    local ipc = cfgm.get("HOST_IPC_CFG")
    if ipc.graceful_poweroff == false then
        powerOff()
        return
    end
    local playSound = opts.ipcPoweroffSound
    if playSound == nil then playSound = ipc.poweroff_play_sound end
    gracePowOff({
        playSound = playSound,
        poweroffTimeoutMs = opts.ipcPoweroffTimeoutMs,
        statusTimeoutMs = opts.ipcStatusTimeoutMs,
    })
end

function enterSleep(opts)
    opts = utils.optTable(opts)
    if state.power_state == "sleeping" and not isPoweredOn then
        t31xInfo("sleep_already")
        return
    end
    if blockSleep(opts) then
        t31xWarn("sleep_blocked_pending_work")
        return false
    end
    t31xInfo("enter_sleep", opts.modemHibernate == true and "hibernate" or "normal")
    state.power_state = "sleeping"
    state.rest_enter_time = os.time()
    if opts.modemHibernate == true then
        powerHal.hibernate()
        return
    end
    sleepInProgress = true
    sys.taskInit(function()
        local ok, err = pcall(shutdownT31x, opts)
        sleepInProgress = false
        if not ok then
            t31xError("enter_sleep_fail", tostring(err or ""))
        end
    end)
end

function wake()
    state.last_wake_reason = rtos.last_wake_reason and rtos.last_wake_reason() or nil
    t31xInfo("wake", tostring(state.last_wake_reason or ""))
    ensNormalPwrOn("wake")
    pulseMcuInt()
end

function getState()
    return {
        powered_on = isPoweredOn,
        power_level = currentPowerLevel,
        in_boot_mode = isInBootMode,
        boot_level = currentBootLevel,
        ota_level = currentOtaLevel,
        power_state = state.power_state,
        slpInPrgr = sleepInProgress,
        last_wake_reason = state.last_wake_reason,
        rest_enter_time = state.rest_enter_time,
        last_action = lastAction,
    }
end

local function resolvePwrWaitMs(opts)
    opts = utils.optTable(opts)
    return tonumber(opts.powerWaitMs) or tonumber(opts.t31xPowerWaitMs)
        or tonumber(cfgm.get("HOST_IPC_CFG").t31x_power_wait_ms)
        or tonumber(cfgm.get("TIME_SYNC_CFG").t31x_power_wait_ms)
        or tonumber(cfgm.get("SOUND_CFG").t31x_power_wait_ms)
        or 800
end

function ensPowOn(tag, opts)
    opts = utils.optTable(opts)
    tag = tag or "t31x_ipc"
    if not t31xPolicy.mayPowerT31x(tag) then
        t31xWarn("ensure_power_denied", tostring(tag))
        return false
    end
    ensNormalPwrOn(tag)
    local waitMs = resolvePwrWaitMs(opts)
    if waitMs > 0 and utils.inSysTask() then sys.wait(waitMs) end
    return true
end

function gracePowOff(opts)
    opts = utils.optTable(opts)
    local hif = svc.hostUart()
    local ipc = cfgm.get("HOST_IPC_CFG")
    local playSound = opts.playSound
    if playSound == nil then playSound = ipc.poweroff_play_sound ~= false end
    if ipc.enabled ~= false and hif then
        t31xInfo("ipc_poweroff_begin")
        local ack = hif.hostIpcPowerOff(playSound, opts.poweroffTimeoutMs)
        t31xInfo("ipc_poweroff_done", ack and "ack" or "timeout")
        local settle = tonumber(opts.settleMs) or tonumber(ipc.poweroff_settle_ms) or 500
        if settle > 0 then sys.wait(settle) end
    end
    powerOff()
    if hif then hif.resetHostLink() end -- 旧名 resetHostLinkState 无定义，真身见 hif_ipc_rec
    return true
end

function pwrOnReady(opts)
    opts = utils.optTable(opts)
    if not utils.inSysTask() then return false end
    local hif = svc.hostUart()
    local ipc = cfgm.get("HOST_IPC_CFG")
    local ipcOn = ipc.enabled ~= false and hif
    if ipcOn and hif.qryHostStat(opts.statusTimeoutMs) == "ready" then
        return true
    end
    if not isPoweredOn then
        powerOn()
        sys.wait(resolvePwrWaitMs(opts))
    end
    if ipcOn then
        return hif.waitHostIpcReady(opts.readyTimeoutMs, opts.pollMs)
    end
    sys.wait(tonumber(ipc.hostBootWaitMs) or 1500)
    return true
end

return _M
