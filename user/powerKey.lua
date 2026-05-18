--- 电源键模块
-- 管理PWRKEY电源键，支持短按和长按检测
require "sys"
local gpioUtil = require "gpioUtil"
local _M = { _VERSION = "1.0.0" }
module(..., package.seeall)
_G[_M] = _M

--[[
CONFIG: 电源键配置
  pin             - GPIO引脚号
  triggerMode     - 触发模式: rising/falling/both
  debounce        - 消抖时间(ms)
  longPressTimeout - 长按超时(ms)
  onShortPress    - 短按回调函数
  onLongPress     - 长按回调函数
]]
local CONFIG = {
    pin = 35,
    triggerMode = "both",
    debounce = 50,
    longPressTimeout = 3000,
    onShortPress = nil,
    onLongPress = nil,
}

local started = false
local keyState = { timer = nil, long_fired = false }

local function publishKeyEvent(eventKey)
    local E = _G.APP_EVENTS
    if E and E[eventKey] then
        sys.publish(E[eventKey])
    end
end

-- 按键中断处理
-- level=0 按下, level=1 释放
local function onInterrupt(level)
    if level == 0 then
        -- 按下:启动长按计时
        if keyState.timer then
            sys.timerStop(keyState.timer)
        end
        keyState.long_fired = false
        keyState.timer = sys.timerStart(function()
            keyState.timer = nil
            keyState.long_fired = true
            publishKeyEvent("GPIO_PWRKEY_LONG")
            if CONFIG.onLongPress then
                CONFIG.onLongPress()
            end
        end, CONFIG.longPressTimeout)
    else
        -- 释放:检查是否为短按
        if keyState.timer then
            sys.timerStop(keyState.timer)
            keyState.timer = nil
        end
        if not keyState.long_fired then
            publishKeyEvent("GPIO_PWRKEY_SHORT")
            if CONFIG.onShortPress then
                CONFIG.onShortPress()
            end
        end
        keyState.long_fired = false
    end
end

--- 启动电源键模块
-- @param cfg 自定义配置
function _M.start(cfg)
    if started then return false end
    if cfg then
        for k, v in pairs(cfg) do
            CONFIG[k] = v
        end
    end
    if CONFIG.pin then
        gpioUtil.setupInput(CONFIG.pin, onInterrupt, {
            triggerMode = CONFIG.triggerMode,
            pull = "pullup",
            debounce = CONFIG.debounce,
        })
    end
    started = true
    return true
end

--- 获取模块状态
function _M.getState()
    return { started = started }
end

--- 获取配置
function _M.getConfig()
    return CONFIG
end

return _M
