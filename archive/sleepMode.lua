--- 模块功能：项目休眠与 t3x 电源控制库
-- @module sleepMode
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

local config = {
    t3x_power_pin = function() return _G.t3xj_init_io_number end,
    lowpower_flag_name = "lowPowerModeStatus",
    gps_power_off = true,
    wait_before_sleep = 500,
    wait_after_gpio = 200,
    -- 应用层通过 configure({cleanup_fn=function()...end}) 注入项目特定的 GPIO 释放操作
    cleanup_fn = nil,
}

local function getPin()
    if type(config.t3x_power_pin) == "function" then
        return config.t3x_power_pin()
    end
    return config.t3x_power_pin
end

local function setLowpowerFlag(value)
    _G[config.lowpower_flag_name] = value
end

--- 配置休眠控制参数
-- @param newConfig table
-- 支持字段：t3x_power_pin、lowpower_flag_name、gps_power_off、wait_before_sleep、wait_after_gpio、cleanup_fn
-- @return table 当前配置
function configure(newConfig)
    if type(newConfig) == "table" then
        for key, value in pairs(newConfig) do
            config[key] = value
        end
    end
    return config
end

--- 获取当前配置
-- @return table 当前配置
function getConfig()
    return config
end

--- 获取最近一次唤醒原因
-- @return number|string 平台返回的唤醒原因
function lastWakeReason()
    return pm.lastReson()
end

--- 进入低功耗休眠
-- @return boolean 始终返回 true
function enterRestDeep()
    log.info("sleepMode.enterRestDeep")
    sys.wait(config.wait_before_sleep)

    if config.gps_power_off and pm and pm.GPS then
        pm.power(pm.GPS, false)
    end

    if type(config.cleanup_fn) == "function" then
        config.cleanup_fn()
    end
    sys.wait(config.wait_after_gpio)

    local pin = getPin()
    if pin then
        gpio.setup(pin, 1)
        gpio.set(pin, 0)
    end

    setLowpowerFlag(1)
    if _G.APP_EVENTS and _G.APP_EVENTS.POWER_ENTERED_REST then
        sys.publish(_G.APP_EVENTS.POWER_ENTERED_REST)
    end
    return true
end

--- 唤醒 t3x
-- @return boolean 始终返回 true
function wakeT3x()
    log.info("sleepMode.wakeT3x")
    local pin = getPin()
    if pin then
        gpio.setup(pin, 1)
        gpio.set(pin, 1)
    end

    setLowpowerFlag(0)
    if _G.APP_EVENTS and _G.APP_EVENTS.POWER_EXITED_REST then
        sys.publish(_G.APP_EVENTS.POWER_EXITED_REST)
    end
    return true
end
