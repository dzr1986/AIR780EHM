--- t3x启动/烧录按键模块
-- 管理BOOT烧录键和t3x启动完成检测
require "sys"
local gpioUtil = require "gpioUtil"
local _M = { _VERSION = "1.0.0" }
module(..., package.seeall)
_G[_M] = _M

--[[
BOOTKEY: BOOT烧录键配置
  pin             - GPIO引脚号
  triggerMode     - 触发模式: rising/falling/both
  debounce        - 消抖时间(ms)
  longPressTimeout - 长按超时(ms)
  onShortPress    - 短按回调
  onLongPress     - 长按回调(进入烧录模式)
]]
local BOOTKEY = {
    pin = 28,
    triggerMode = "both",
    debounce = 100,
    longPressTimeout = 2000,
    onShortPress = nil,
    onLongPress = nil,
}

--[[
t3xSTART: t3x启动完成检测配置
  pin         - GPIO引脚号
  triggerMode - 触发模式: rising(高电平表示启动完成)
  debounce    - 消抖时间(ms)
  onStarted   - 启动完成回调
]]
local t3xSTART = {
    pin = 29,
    triggerMode = "rising",
    debounce = 100,
    onStarted = nil,
}

local started = false
local bootState = { timer = nil, long_fired = false }

local function publishKeyEvent(eventKey)
    local E = _G.APP_EVENTS
    if E and E[eventKey] then
        sys.publish(E[eventKey])
    end
end

-- BOOT键中断处理
local function onBootkey(level)
    if level == 0 then
        if bootState.timer then
            sys.timerStop(bootState.timer)
        end
        bootState.long_fired = false
        bootState.timer = sys.timerStart(function()
            bootState.timer = nil
            bootState.long_fired = true
            publishKeyEvent("GPIO_BOOTKEY_LONG")
            if BOOTKEY.onLongPress then
                BOOTKEY.onLongPress()
            end
        end, BOOTKEY.longPressTimeout)
    else
        if bootState.timer then
            sys.timerStop(bootState.timer)
            bootState.timer = nil
        end
        if not bootState.long_fired then
            publishKeyEvent("GPIO_BOOTKEY_SHORT")
            if BOOTKEY.onShortPress then
                BOOTKEY.onShortPress()
            end
        end
        bootState.long_fired = false
    end
end

-- t3x启动完成中断处理
local function ont3xStart(level)
    if level == 1 then
        publishKeyEvent("GPIO_t3x_STARTED")
        if t3xSTART.onStarted then
            t3xSTART.onStarted()
        end
    end
end

--- 启动模块
-- @param cfg 配置 { bootkey={}, t3xStartup={} }
function _M.start(cfg)
    if started then return false end
    if cfg then
        if cfg.bootkey then
            for k, v in pairs(cfg.bootkey) do BOOTKEY[k] = v end
        end
        if cfg.t3xStartup then
            for k, v in pairs(cfg.t3xStartup) do t3xSTART[k] = v end
        end
    end
    if BOOTKEY.pin then
        gpioUtil.setupInput(BOOTKEY.pin, onBootkey, {
            triggerMode = BOOTKEY.triggerMode,
            pull = "pullup",
            debounce = BOOTKEY.debounce,
        })
    end
    if t3xSTART.pin then
        gpioUtil.setupInput(t3xSTART.pin, ont3xStart, {
            triggerMode = t3xSTART.triggerMode,
            pull = "pulldown",
            debounce = t3xSTART.debounce,
        })
    end
    started = true
    return true
end

--- 获取状态
function _M.getState()
    return { started = started }
end

--- 获取配置
function _M.getConfig()
    return { bootkey = BOOTKEY, t3xStartup = t3xSTART }
end

return _M
