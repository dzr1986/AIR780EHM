-- ================================================================
-- Filename : t31x_burn_ctrl.lua
-- Module   : T31x 烧录模式策略：电量门禁、服务裁剪、enterBootMode 编排
-- Layer    : L2 协处理器服务（app 经 bind 注入 net/gpio/t31x 等运行时依赖）
-- Arch     : doc/hardware/T31X_BURN_MODE.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local rntmPwr = require "runtime_power"
local t31xPolicy = require "t31x_policy"
local pirCtrl = require "pir_ctrl"
local uart_bridge = require "uart_bridge"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("t31x_burn")
local burnInfo = logFuncs.info
local burnWarn = logFuncs.warn
local burnError = logFuncs.error

local deps = {}

local TIMEOUT = {
    burnPrepWait = 300,
}

function bind(opts)
    deps = opts or {}
end

function isActive()
    return t31xPolicy.isBurnActive()
end

function setActive(active)
    t31xPolicy.setBurnActive(active == true)
    if type(deps.setHeartbeatPaused) == "function" then
        deps.setHeartbeatPaused(active == true)
    end
end

local function burnCfg()
    return _G.t31x_BURN_CFG or {}
end

local function getT31x()
    return type(deps.getT31x) == "function" and deps.getT31x() or nil
end

local function getNet()
    return type(deps.getNet) == "function" and deps.getNet() or nil
end

local function getGpio()
    return type(deps.getGpio) == "function" and deps.getGpio() or nil
end

local function getBatAdc()
    return type(deps.getBatAdc) == "function" and deps.getBatAdc() or nil
end

local function getUsbRndis()
    return type(deps.getUsbRndis) == "function" and deps.getUsbRndis() or nil
end

local function isMqttStarted()
    return type(deps.isMqttStarted) == "function" and deps.isMqttStarted() == true
end

local function setMqttStarted(v)
    if type(deps.setMqttStarted) == "function" then
        deps.setMqttStarted(v == true)
    end
end

local function getBurnBatteryPercent()
    local pct = rntmPwr.getBatteryPercent()
    if pct and pct >= 0 then
        return pct
    end
    local batAdc = getBatAdc()
    if batAdc then
        pct = tonumber(batAdc.getPercent())
        if pct and pct > 0 then
            return pct
        end
    end
    return nil
end

local function checkBurnAttempt(attemptIndex, attemptTotal)
    local cfg = burnCfg()
    local minPct = tonumber(cfg.min_battery_percent) or 20
    local allowRepeat = cfg.allow_repeat_enter_boot ~= false
    local failReason = nil
    local pct = getBurnBatteryPercent()
    if cfg.require_battery_valid ~= false then
        if not pct then
            failReason = "battery_invalid"
        elseif pct < minPct then
            failReason = "batL"
        end
    end
    local t31x = getT31x()
    if not t31x then
        failReason = failReason or "noT3"
    else
        local st = t31x.getState() or {}
        if st.in_boot_mode and not allowRepeat then
            failReason = failReason or "boot"
        end
    end
    if failReason then
        return false, failReason
    end
    return true, pct
end

local function checkBurnAllowed()
    local cfg = burnCfg()
    local retryCount = math.max(0, tonumber(cfg.burn_check_retry_count) or 2)
    local maxAttempts = 1 + retryCount
    local retryMs = tonumber(cfg.burn_check_retry_interval_ms) or 800
    local lastFailRsn = nil
    local lastPassPct
    for attempt = 1, maxAttempts do
        local ok, detail = checkBurnAttempt(attempt, maxAttempts)
        if ok then
            lastPassPct = detail
            return true, lastPassPct
        end
        lastFailRsn = detail
        if attempt < maxAttempts then
            sys.wait(retryMs)
        end
    end
    return false, lastFailRsn
end

local function shutdownForBurn(cfg)
    cfg = cfg or burnCfg()
    burnWarn("t31x_burn_prepare")
    setActive(true)
    if cfg.suspend_pir ~= false then
        pirCtrl.suspend()
    end
    local netModule = getNet()
    if cfg.stop_mqtt ~= false and isMqttStarted() and netModule then
        netModule.stop()
        setMqttStarted(false)
        burnInfo("t31x_burn_mqtt_stopped")
    end
    if cfg.stop_uart ~= false then
        uart_bridge.stop()
    end
    local usbRndis = getUsbRndis()
    if cfg.stop_rndis ~= false and usbRndis then
        local rndisOk, rndisErr = usbRndis.disable()
        if rndisOk then
            burnInfo("t31x_burn_rndis_disabled")
        else
            burnWarn("t31x_burn_rndis_disable_fail", tostring(rndisErr or ""))
        end
    end
    local gpioModule = getGpio()
    if cfg.turn_off_led ~= false and gpioModule then
        gpioModule.turnOffLed()
    end
    sys.wait(TIMEOUT.burnPrepWait)
    return true
end

function tryEnter()
    local cfg = burnCfg()
    local ok, detail = checkBurnAllowed()
    if not ok then
        burnWarn("t31x_burn_denied", tostring(detail or "unknown"))
        local gpioModule = getGpio()
        if gpioModule then
            gpioModule.runLedPattern("blink_red")
        end
        return false
    end
    shutdownForBurn(cfg)
    local t31x = getT31x()
    if not t31x then
        burnError("t31x_burn_no_t31x_module")
        return false
    end
    if not t31x.entBootMode() then
        burnError("t31x_burn_enter_bootmode_fail")
        return false
    end
    burnWarn("t31x_burn_entered")
    return true
end

function onCoprocReady()
    local t31x = getT31x()
    if t31x then
        t31x.extBootMode()
    end
    if isActive() then
        pirCtrl.resume()
        setActive(false)
    end
end

return _M
