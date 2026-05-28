--- 通用 GPIO 按键：电源键 / BOOT 长短按 + 协处理器就绪信号
-- 配置真源：user/key_config.lua → KEY_CONFIG（引脚来自 GPIO_IN）
-- @module key
-- @release 2026.5.19

require "sys"
require "config"
local gpio_util = require "gpio_util"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "key"
local started = false
local bootCfg, pwrCfg, readyCfg
local pressStates = {
    boot = { timer = nil, long_fired = false },
    pwr = { timer = nil, long_fired = false },
}

local function shallowMerge(base, over)
    local out = {}
    if base then
        for k, v in pairs(base) do
            out[k] = v
        end
    end
    if over then
        for k, v in pairs(over) do
            out[k] = v
        end
    end
    return out
end

local function loadSection(name, overrides)
    local base = (_G.KEY_CONFIG and _G.KEY_CONFIG[name]) or {}
    return shallowMerge(base, overrides)
end

local function publishAppEvent(eventKey)
    if not eventKey then
        return
    end
    local E = _G.APP_EVENTS
    if E and E[eventKey] then
        sys.publish(E[eventKey])
    end
end

--- 长短按 GPIO 键（按下为低、释放为高的上拉输入）
local function setupLongPressKey(cfg, state, logName)
    if not cfg or not cfg.pin then
        return
    end

    local pressLevel = cfg.pressLevel
    if pressLevel == nil then
        pressLevel = 0
    end

    if cfg.requireReleaseFirst and gpio and gpio.get then
        if gpio.get(cfg.pin) == pressLevel then
            state.await_release = true
            log.info(LOG_TAG, logName or "key", cfg.pin, "已按下，等待释放后再识别")
        end
    end

    local function onInterrupt(level)
        if state.await_release then
            if level ~= pressLevel then
                state.await_release = false
            end
            return
        end
        if level == pressLevel then
            if state.timer then
                sys.timerStop(state.timer)
            end
            state.long_fired = false
            local timeout = cfg.longPressMs or cfg.longPressTimeout or 2000
            state.timer = sys.timerStart(function()
                state.timer = nil
                state.long_fired = true
                local ev = cfg.events and cfg.events.long
                publishAppEvent(ev)
                if cfg.onLongPress then
                    cfg.onLongPress()
                end
            end, timeout)
        else
            if state.timer then
                sys.timerStop(state.timer)
                state.timer = nil
            end
            if not state.long_fired then
                local ev = cfg.events and cfg.events.short
                publishAppEvent(ev)
                if cfg.onShortPress then
                    cfg.onShortPress()
                end
            end
            state.long_fired = false
        end
    end

    gpio_util.setup_input(cfg.pin, onInterrupt, {
        trigger_mode = cfg.triggerMode or "both",
        pull = cfg.pull or "pullup",
        debounce_ms = cfg.debounce or 100,
    })
    log.info(LOG_TAG, logName or "key", cfg.pin)
end

local function setupReadySignal(cfg)
    if not cfg or not cfg.pin then
        return
    end

    local active = cfg.activeLevel
    if active == nil then
        active = 1
    end

    local function onReadyInterrupt(level)
        if level == active then
            publishAppEvent(cfg.event)
            if cfg.onReady then
                cfg.onReady()
            end
        end
    end

    gpio_util.setup_input(cfg.pin, onReadyInterrupt, {
        trigger_mode = cfg.triggerMode or "rising",
        pull = cfg.pull or "pulldown",
        debounce_ms = cfg.debounce or 100,
    })
    log.info(LOG_TAG, "ready", cfg.pin, "event", cfg.event)
end

--- 启动按键模块
-- @param cfg table 可选覆盖：{ pwrkey, bootkey, ready }
function cancelLongPress(name)
    local state = pressStates[name]
    if not state then
        return false
    end
    if state.timer then
        sys.timerStop(state.timer)
        state.timer = nil
    end
    state.long_fired = false
    return true
end

function start(cfg)
    if started then
        return false
    end
    cfg = cfg or {}
    pwrCfg = loadSection("pwrkey", cfg.pwrkey)
    bootCfg = loadSection("bootkey", cfg.bootkey)
    readyCfg = loadSection("ready", cfg.ready)

    setupLongPressKey(pwrCfg, pressStates.pwr, "pwrkey")
    setupLongPressKey(bootCfg, pressStates.boot, "bootkey")
    setupReadySignal(readyCfg)

    started = true
    log.info(LOG_TAG, "已启动")
    return true
end

function getState()
    return {
        started = started,
        pwrkey = pwrCfg and pwrCfg.pin,
        bootkey = bootCfg and bootCfg.pin,
        ready = readyCfg and readyCfg.pin,
    }
end

function getConfig()
    return {
        pwrkey = pwrCfg,
        bootkey = bootCfg,
        ready = readyCfg,
    }
end

return _M
