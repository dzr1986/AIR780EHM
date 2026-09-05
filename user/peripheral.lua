-- ================================================================
-- Filename : peripheral.lua
-- Module   : 外设聚合：PWR/BOOT 长按、coproc_ready、LED 模式、启动 pir_ctrl 硬件
-- Arch     : doc/modules/PERIPHERAL_LED_FLOW.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local gpio_util = require "gpio_util"
local led_ctrl = require "led_ctrl"
local pir_ctrl = require "pir_ctrl"
local _M = {}
module(..., package.seeall)

local keyStarted = false
local pressStates = {
    boot = { timer = nil, long_fired = false },
    pwr = { timer = nil, long_fired = false },
}

local function pubAppEvent(eventKey)
    local E = _G.APP_EVENTS
    if E and E[eventKey] then sys.publish(E[eventKey]) end
end

local function resetPress(state)
    if state.timer then sys.timerStop(state.timer) end
    state.timer = nil
    state.long_fired = false
    state.await_release = nil
end

local function keySection(name, overrides)
    local out = {}
    local keyCfg = cfgm.get("KEY_CONFIG")
    if type(keyCfg[name]) == "table" then
        cfgm.merge(out, keyCfg[name])
    end
    if type(overrides) == "table" then
        cfgm.merge(out, overrides)
    end
    return out
end

local function setupLong(cfg, state)
    if not cfg or cfg.pin == nil then return end
    local pressLevel = cfg.pressLevel or 0
    if cfg.requireReleaseFirst and gpio_util.getLevel(cfg.pin) == pressLevel then
        state.await_release = true
    end
    gpio_util.setupInput(cfg.pin, function(level)
        if state.await_release then
            if level ~= pressLevel then state.await_release = false end
            return
        end
        if level == pressLevel then
            if state.timer then sys.timerStop(state.timer) end
            state.long_fired = false
            state.timer = sys.timerStart(function()
                state.timer = nil
                state.long_fired = true
                pubAppEvent(cfg.events and cfg.events.long)
                if cfg.onLongPress then cfg.onLongPress() end
            end, cfg.longPressMs or cfg.longPressTimeout or 2000)
            return
        end
        if state.timer then sys.timerStop(state.timer) end
        state.timer = nil
        if not state.long_fired then
            pubAppEvent(cfg.events and cfg.events.short)
            if cfg.onShortPress then cfg.onShortPress() end
        end
        state.long_fired = false
    end, {
        trigger_mode = cfg.triggerMode or "both",
        pull = cfg.pull or "pullup",
        debounce_ms = cfg.debounce or 100,
    })
end

local function setupReady(cfg)
    if not cfg or cfg.pin == nil then return end
    local active = cfg.activeLevel or 1
    gpio_util.setupInput(cfg.pin, function(level)
        if level == active then
            pubAppEvent(cfg.event)
            if cfg.onReady then cfg.onReady() end
        end
    end, {
        trigger_mode = cfg.triggerMode or "rising",
        pull = cfg.pull or "pulldown",
        debounce_ms = cfg.debounce or 100,
    })
end

local function normStartCfg(cfg)
    cfg = cfg or {}
    local led = cfg.led or {}
    local key = cfg.key or {}
    if cfg.ledBluePin ~= nil then led.bluePin = cfg.ledBluePin end
    local function mapKey(slot, pinKey, shortKey, longKey)
        if cfg[pinKey] == nil and not cfg[shortKey] and not cfg[longKey] then return end
        local k = key[slot] or {}
        if cfg[pinKey] ~= nil then k.pin = cfg[pinKey] end
        if cfg[shortKey] then k.onShortPress = cfg[shortKey] end
        if cfg[longKey] then k.onLongPress = cfg[longKey] end
        key[slot] = k
    end
    mapKey("pwrkey", "pwrkeyPin", "onPwrkeyShort", "onPwrkeyLong")
    mapKey("bootkey", "bootkeyPin", "onBootkeyShort", "onBootkeyLong")
    if cfg.readyPin ~= nil or cfg.onReady then
        local r = key.ready or {}
        if cfg.readyPin ~= nil then r.pin = cfg.readyPin end
        if cfg.onReady then r.onReady = cfg.onReady end
        key.ready = r
    end
    return { led = led, key = key }
end

function _M.cancelLongPress(name)
    local state = pressStates[name]
    if not state then return false end
    resetPress(state)
    return true
end

function _M.ignoreUntilRelease(name)
    local state = pressStates[name]
    if not state then return false end
    resetPress(state)
    local section = name == "boot" and "bootkey" or (name == "pwr" and "pwrkey" or name)
    local cfg = keySection(section)
    local pin = cfg and cfg.pin
    local pressLevel = (cfg and cfg.pressLevel) or 0
    if pin ~= nil and gpio_util.getLevel(cfg.pin) == pressLevel then
        state.await_release = true
    end
    return true
end

function _M.start(cfg)
    if keyStarted then return true end
    local sub = normStartCfg(cfg)
    led_ctrl.start(sub.led)
    cfg = sub.key or {}
    setupLong(keySection("pwrkey", cfg.pwrkey), pressStates.pwr)
    setupLong(keySection("bootkey", cfg.bootkey), pressStates.boot)
    setupReady(keySection("ready", cfg.ready))
    keyStarted = true
    pir_ctrl.startHw()
    return true
end

function _M.stop()
    if not keyStarted then return true end
    for _, state in pairs(pressStates) do
        resetPress(state)
    end
    led_ctrl.stop()
    pir_ctrl.stopHw()
    keyStarted = false
    return true
end

function _M.getState()
    return {
        led = led_ctrl.getState(),
        key = { started = keyStarted },
        pir = pir_ctrl.getState(),
    }
end

function _M.getConfig()
    return { led = led_ctrl.getConfig(), pir = pir_ctrl.getMediaConfig() }
end

function _M.setLed(red, blue)
    led_ctrl.setLed(red, blue)
end

function _M.turnOffLed()
    led_ctrl.turnOff()
end

function _M.runLedPattern(pattern)
    local fn = pattern == "blink_red" and led_ctrl.blinkRed
        or pattern == "blink_blue" and led_ctrl.blinkBlue
    if fn then sys.taskInit(fn) end
end

return _M
