--- PIR 人体红外硬件驱动（lib 层，仅 GPIO + 冷却）
-- 触发后发布 APP_EVENTS.PIR_HW_TRIGGERED，业务见 user/pirCtrl.lua
-- @module pir
-- @release 2026.5.18

require "sys"
local gpioUtil = require "gpioUtil"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local CONFIG = {
    pin = 30,
    triggerMode = "rising",
    debounce = 100,
    cooldown = 10000,
}

local state = {
    last_trigger_time = 0,
    cooldown_active = false,
}

local function onInterrupt(level)
    if level ~= 1 then return end
    local now = os.time() * 1000
    if state.cooldown_active and (now - state.last_trigger_time < CONFIG.cooldown) then
        return
    end

    state.last_trigger_time = now
    state.cooldown_active = true

    local E = _G.APP_EVENTS or {}
    if E.PIR_HW_TRIGGERED then
        sys.publish(E.PIR_HW_TRIGGERED)
    end

    sys.timerStart(function()
        state.cooldown_active = false
    end, CONFIG.cooldown)
end

function start(cfg)
    if cfg then
        for k, v in pairs(cfg) do
            CONFIG[k] = v
        end
    end
    if CONFIG.pin then
        gpioUtil.setupInput(CONFIG.pin, onInterrupt, {
            triggerMode = CONFIG.triggerMode,
            pull = "pulldown",
            debounce = CONFIG.debounce,
        })
    end
    return true
end

function getState()
    return {
        pin = CONFIG.pin,
        cooldown = CONFIG.cooldown,
        cooldown_active = state.cooldown_active,
        last_trigger_time = state.last_trigger_time,
    }
end

return _M
