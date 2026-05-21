--- t3x 协处理器控制模块
-- @module t3x_ctrl
-- @release 2026.5.20
-- @description t3x 电源、BOOT/OTA、休眠（模组 WDT 见 lib/watchdog.lua）
require "sys"
require "config"
local gpio_util = require "gpio_util"

local LOG_TAG = "t3x_ctrl"
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

--- 运行时读 GPIO_OUT（勿在 require 时缓存，避免 config 未就绪）
local function getEntries()
    local gout = _G.GPIO_OUT or {}
    return gout.t3x_pwr_wake, gout.t3x_mcu_int, gout.t3x_boot, gout.t3x_ota
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
    local entry_pwr, entry_boot, entry_ota = getEntries()
    powerOnLevel = entry_pwr and entry_pwr.on_level or 1
    powerOffLevel = entry_pwr and entry_pwr.init_level or 0
    bootModeLevel = entry_boot and entry_boot.on_level or 1
    otaModeLevel = entry_ota and entry_ota.on_level or 1
end

--- 确保 GPIO 句柄已 setup（start / enterBootMode 等可重复调用）
local function ensurePins()
    refreshLevels()
    local entry_pwr, entry_int, entry_boot, entry_ota = getEntries()
    if not entry_pwr or not entry_pwr.pin then
        log.warn(LOG_TAG, "t3x_pwr_wake 未配置")
    elseif not t3xPowerPin then
        t3xPowerPin = gpio_util.setup_output(entry_pwr)
    end
    if not entry_int or not entry_int.pin then
        log.warn(LOG_TAG, "t3x_mcu_int 未配置")
    elseif not t3xMcuIntPin then
        t3xMcuIntPin = gpio_util.setup_output(entry_int)
    end
    if not entry_boot or not entry_boot.pin then
        log.warn(LOG_TAG, "t3x_boot 未配置")
    elseif not t3xBootModePin then
        t3xBootModePin = gpio_util.setup_output(entry_boot)
    end
    if not entry_ota or not entry_ota.pin then
        log.warn(LOG_TAG, "t3x_ota 未配置")
    elseif not t3xOtaPin then
        t3xOtaPin = gpio_util.setup_output(entry_ota)
    end
    return entry_pwr, entry_int, entry_boot, entry_ota
end

function start()
    log.info(LOG_TAG, "========== t3x 控制模块启动 ==========")
    ensurePins()
    powerOn()
    log.info(LOG_TAG, "========== t3x 控制模块启动完成 ==========")
    return true
end

function powerOn()
    local entry_pwr = ensurePins()
    if not t3xPowerPin then
        log.warn(LOG_TAG, "电源脚未初始化", "pin", entry_pwr and entry_pwr.pin)
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
    log.info(LOG_TAG, "t3x 上电", "pin", entry_pwr.pin)
    return true
end

--- GPIO29 → T31 PB27：低电平脉冲（空闲高，勿动 GPIO22 电源）
function pulseMcuInt()
    local _, entry_int = getEntries()
    ensurePins()
    if not t3xMcuIntPin then
        log.warn(LOG_TAG, "MCU_INT 未初始化", "pin", entry_int and entry_int.pin)
        return false
    end
    local idle, active = getMcuIntLevels(entry_int)
    local ms = getWakePulseMs()
    t3xMcuIntPin(active)
    sys.timerStart(function()
        t3xMcuIntPin(idle)
        lastAction = "pulseMcuInt"
        log.info(LOG_TAG, "T31 唤醒脉冲(低)", "pin", entry_int.pin, "ms", ms,
            "idle", idle, "active", active)
    end, ms)
    return true
end

function pulseWakeup()
    return pulseMcuInt()
end

function powerOff()
    ensurePins()
    if not t3xPowerPin then
        log.warn(LOG_TAG, "电源脚未初始化，跳过断电")
        return false
    end
    t3xPowerPin(powerOffLevel)
    currentPowerLevel = powerOffLevel
    isPoweredOn = false
    state.power_state = "off"
    lastAction = "powerOff"
    log.info(LOG_TAG, "t3x 断电")
    return true
end

function enterBootMode()
    log.info(LOG_TAG, "进入 BOOT 模式")
    local entry_pwr, entry_boot, entry_ota = ensurePins()
    if not t3xPowerPin or not t3xBootModePin or not t3xOtaPin then
        log.warn(LOG_TAG, "BOOT 模式失败：GPIO 未就绪",
            "pwr", entry_pwr and entry_pwr.pin,
            "boot", entry_boot and entry_boot.pin,
            "ota", entry_ota and entry_ota.pin)
        return false
    end

    powerOff()

    sys.timerStart(function()
        t3xBootModePin(bootModeLevel)
        t3xOtaPin(otaModeLevel)
        currentBootLevel = bootModeLevel
        currentOtaLevel = otaModeLevel
        isInBootMode = true
        log.info(LOG_TAG, "BOOT/OTA 电平已设置", "boot", entry_boot.pin, "ota", entry_ota.pin)
    end, bootDelay)

    sys.timerStart(function()
        powerOn()
    end, bootDelay)

    lastAction = "enterBootMode"
    return true
end

function exitBootMode()
    ensurePins()
    if not t3xBootModePin or not t3xOtaPin then
        log.warn(LOG_TAG, "退出 BOOT：GPIO 未就绪")
        return false
    end
    log.info(LOG_TAG, "退出 BOOT 模式")

    t3xBootModePin(1 - bootModeLevel)
    t3xOtaPin(1 - otaModeLevel)
    currentBootLevel = 1 - bootModeLevel
    currentOtaLevel = 1 - otaModeLevel
    isInBootMode = false
    lastAction = "exitBootMode"
    return true
end

function enterSleep(opts)
    if state.power_state == "sleeping" then
        log.info(LOG_TAG, "已在休眠状态")
        return
    end

    opts = type(opts) == "table" and opts or {}
    log.info(LOG_TAG, "========== 进入休眠 ==========")
    state.power_state = "sleeping"
    state.rest_enter_time = os.time()

    if opts.modemHibernate == true then
        log.warn(LOG_TAG, "整模组 hibernate（MQTT 将断开）")
        pm.hibernate()
        return
    end

    if isPoweredOn then
        powerOff()
        log.info(LOG_TAG, "业务休眠：t3x 已断电，模组保持联网")
    else
        log.info(LOG_TAG, "业务休眠：t3x 已处于断电")
    end
end

function wake()
    log.info(LOG_TAG, "========== 唤醒设备 ==========")
    state.last_wake_reason = rtos.last_wake_reason and rtos.last_wake_reason() or nil
    if state.last_wake_reason then
        log.info(LOG_TAG, "唤醒原因:", state.last_wake_reason)
    end

    if not isPoweredOn then
        powerOn()
    end
    pulseMcuInt()
end

function enterDeepSleep()
    log.info(LOG_TAG, "========== 进入深度休眠 ==========")
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

return _M
