--- t3x 控制模块（简化版）
-- @module t3x
-- @release 2026.5.18
-- @description t3x 电源、BOOT/OTA、休眠（模组 WDT 见 lib/watchdog.lua）
require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 电源状态
local isPoweredOn = false
local currentPowerLevel = nil

-- BOOT/OTA 模式状态
local isInBootMode = false
local currentBootLevel = nil
local currentOtaLevel = nil

-- 引脚控制句柄
local t3xPowerPin = nil
local t3xBootModePin = nil
local t3xOtaPin = nil

-- 最后操作记录
local lastAction = nil

-- 配置（t3x_init_io_number：电源使能 + 唤醒脉冲，同一硬件信号）
local powerPin = _G.t3x_init_io_number
local pulseLowMs = 120
local bootPin = _G.t3x_boot_io_number
local otaPin = _G.t3x_ota_io_number

-- 电平配置
local powerOnLevel = 1
local powerOffLevel = 0
local bootModeLevel = 1
local otaModeLevel = 1

-- BOOT 模式切换延迟(ms)
local bootDelay = 500

-- 运行时状态
local state = {
    power_state = "off",
    last_wake_reason = nil,
    rest_enter_time = nil,
}

-- ============================================================
-- 启动
-- ============================================================

function start()
    log.info("t3x", "========== t3x 控制模块启动 ==========")

    t3xPowerPin = gpio.setup(powerPin, powerOffLevel)
    t3xBootModePin = gpio.setup(bootPin, 0)
    t3xOtaPin = gpio.setup(otaPin, 0)

    powerOn()

    log.info("t3x", "========== t3x 控制模块启动完成 ==========")
    return true
end

-- ============================================================
-- 电源控制
-- ============================================================

function powerOn()
    if not t3xPowerPin then
        log.warn("t3x", "电源脚未初始化")
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
    log.info("t3x", "t3x 上电", "pin", powerPin)
    return true
end

--- 唤醒脉冲（电源脚拉低再拉高，不重复 gpio.setup）
function pulseWakeup()
    if not t3xPowerPin then
        log.warn("t3x", "电源脚未初始化，跳过脉冲")
        return false
    end
    t3xPowerPin(powerOffLevel)
    sys.timerStart(function()
        t3xPowerPin(powerOnLevel)
        currentPowerLevel = powerOnLevel
        isPoweredOn = true
        state.power_state = "on"
        lastAction = "pulseWakeup"
        log.info("t3x", "唤醒脉冲", "pin", powerPin, "ms", pulseLowMs)
    end, pulseLowMs)
    return true
end

function powerOff()
    t3xPowerPin(powerOffLevel)
    currentPowerLevel = powerOffLevel
    isPoweredOn = false
    state.power_state = "off"
    lastAction = "powerOff"
    log.info("t3x", "t3x 断电")
end

-- ============================================================
-- BOOT/OTA 模式控制
-- ============================================================

function enterBootMode()
    log.info("t3x", "进入 BOOT 模式")
    powerOff()

    sys.timerStart(function()
        t3xBootModePin(bootModeLevel)
        t3xOtaPin(otaModeLevel)
        currentBootLevel = bootModeLevel
        currentOtaLevel = otaModeLevel
        isInBootMode = true
    end, bootDelay)

    sys.timerStart(function()
        powerOn()
    end, bootDelay)

    lastAction = "enterBootMode"
end

function exitBootMode()
    log.info("t3x", "退出 BOOT 模式")

    t3xBootModePin(1 - bootModeLevel)
    t3xOtaPin(1 - otaModeLevel)
    currentBootLevel = 1 - bootModeLevel
    currentOtaLevel = 1 - otaModeLevel
    isInBootMode = false
    lastAction = "exitBootMode"
end

-- ============================================================
-- 休眠管理
-- ============================================================

--- 业务低功耗：默认仅 t3x 断电，模组保持 Cat.1/MQTT 在线
--- @param opts table|nil modemHibernate=true 时整模组 pm.hibernate（会断 MQTT）
function enterSleep(opts)
    if state.power_state == "sleeping" then
        log.info("t3x", "已在休眠状态")
        return
    end

    opts = type(opts) == "table" and opts or {}
    log.info("t3x", "========== 进入休眠 ==========")
    state.power_state = "sleeping"
    state.rest_enter_time = os.time()

    if opts.modemHibernate == true then
        log.warn("t3x", "整模组 hibernate（MQTT 将断开）")
        pm.hibernate()
        return
    end

    if isPoweredOn then
        powerOff()
        log.info("t3x", "业务休眠：t3x 已断电，模组保持联网")
    else
        log.info("t3x", "业务休眠：t3x 已处于断电")
    end
end

function wake()
    log.info("t3x", "========== 唤醒设备 ==========")
    state.last_wake_reason = rtos.last_wake_reason and rtos.last_wake_reason() or nil
    if state.last_wake_reason then
        log.info("t3x", "唤醒原因:", state.last_wake_reason)
    end

    if not isPoweredOn then
        powerOn()
    else
        pulseWakeup()
    end
end

function enterDeepSleep()
    log.info("t3x", "========== 进入深度休眠 ==========")
    state.power_state = "sleeping"

    if _G.uartBridge and _G.uartBridge.stop then
        _G.uartBridge.stop()
    elseif _G.uartid then
        uart.close(_G.uartid)
    end

    pm.deepSleep()
end

-- ============================================================
-- 状态查询
-- ============================================================

function getState()
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
    }
end

return _M
