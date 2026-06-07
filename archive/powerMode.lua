--- [归档] 不参与主路径。低功耗请用 user/app.lua + uartBridge + net/t3x。
--- 模块功能：基于 lowpower demo 抽出的功耗模式切换库（含 UART1 唤醒，与 uartBridge 冲突）
-- @module powerMode
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

local currentModel = hmeta and hmeta.model and hmeta.model() or "UNKNOWN"
local wakeupCallback
local uartReadBuffer = ""
local state = {
    current_mode = "normal",
    last_wakeup_reason = nil,
    last_wakeup_data = nil,
}

local defaultConfig = {
    normal = {},
    lowpower = {},
    psm = {},
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return defaultConfig
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
            defaultConfig[key] = value
        end
    end
    return defaultConfig
end

local function isGnssModel()
    return currentModel == "Air780EGH" or currentModel == "Air780EGG" or currentModel == "Air780EGP"
end

local function wakeTag(id)
    local tags = {
        [gpio.PWR_KEY] = "PWR_KEY",
        [gpio.CHG_DET] = "CHG_DET",
        [gpio.WAKEUP0] = "WAKEUP0",
        [gpio.WAKEUP1] = "WAKEUP1",
        [gpio.WAKEUP2] = "WAKEUP2",
        [gpio.WAKEUP3] = "WAKEUP3",
        [gpio.WAKEUP4] = "WAKEUP4",
        [gpio.WAKEUP5] = "WAKEUP5",
    }
    return tags[id] or tostring(id)
end

local function notifyWakeup(reason, data)
    state.last_wakeup_reason = reason
    state.last_wakeup_data = data
    if wakeupCallback then
        wakeupCallback(reason, data)
    end
end

local function interruptWakeup(level, id)
    log.info("powerMode.interruptWakeup", wakeTag(id), level)
    notifyWakeup("gpio", {level = level, id = id, tag = wakeTag(id)})
end

local function uartConcatTimeout()
    if uartReadBuffer:len() > 0 then
        notifyWakeup("uart_data", uartReadBuffer)
        uartReadBuffer = ""
    end
end

local function uartWakeupRead(_, len)
    if len == -1 then
        pm.power(pm.WORK_MODE, 0)
        uart.write(1, "lowpower wakeup\r\n")
        notifyWakeup("uart_wakeup", true)
    end

    while true do
        local s = uart.read(1, 1024)
        if not s or s:len() == 0 then
            sys.timerStart(uartConcatTimeout, 50)
            break
        end
        uartReadBuffer = uartReadBuffer .. s
    end
end

local function applyInterrupts(interrupts)
    if type(interrupts) ~= "table" then
        return
    end

    for _, item in ipairs(interrupts) do
        if item.debounce then
            gpio.debounce(item.id, item.debounce)
        end
        gpio.setup(item.id, interruptWakeup, item.pull, item.edge)
    end
end

local function applyUartWakeup(config)
    if not config or not config.enable then
        return
    end

    uart.setup(1, config.baudrate or 9600, 8, 1)
    uart.on(1, "receive", uartWakeupRead)
end

local function applyCommon(config)
    local cfg = config or {}

    if cfg.flymode ~= nil and mobile and mobile.flymode then
        mobile.flymode(0, cfg.flymode)
    end

    if cfg.gpio23 ~= nil and isGnssModel() then
        gpio.setup(23, cfg.gpio23 and 1 or 0)
    end

    applyInterrupts(cfg.interrupts)
    applyUartWakeup(cfg.uart1_wakeup)
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return defaultConfig
end

function configureDefaults(config)
    return configure(config)
end

function onWakeup(callback)
    wakeupCallback = callback
end

function model()
    return currentModel
end

function setNormal(config)
    local cfg = config or defaultConfig.normal or {}
    state.current_mode = "normal"
    sys.taskInit(function()
        if cfg.restore_gnss_power ~= false and isGnssModel() then
            gpio.setup(23, 1)
        end
        if cfg.flymode == false and mobile and mobile.flymode then
            mobile.flymode(0, false)
        end
        pm.power(pm.WORK_MODE, 0)
    end)
end

function setLowpower(config)
    local cfg = config or defaultConfig.lowpower or {}
    state.current_mode = "lowpower"
    sys.taskInit(function()
        applyCommon(cfg)
        pm.power(pm.WORK_MODE, 1)
    end)
end

function setPsm(config)
    local cfg = config or defaultConfig.psm or {}
    state.current_mode = "psm"
    sys.taskInit(function()
        applyCommon(cfg)
        if cfg.dtimer_ms then
            pm.dtimerStart(0, cfg.dtimer_ms)
        end
        pm.power(pm.WORK_MODE, 3)
    end)
end

sys.subscribe("DRV_SET_NORMAL", function()
    setNormal(defaultConfig.normal)
end)

sys.subscribe("DRV_SET_LOWPOWER", function()
    setLowpower(defaultConfig.lowpower)
end)

sys.subscribe("DRV_SET_PSM", function()
    setPsm(defaultConfig.psm)
end)

function getState()
    return {
        model = currentModel,
        current_mode = state.current_mode,
        last_wakeup_reason = state.last_wakeup_reason,
        last_wakeup_data = state.last_wakeup_data,
        wakeup_callback_set = wakeupCallback ~= nil,
    }
end
