--- PIR 人体红外（GPIO 中断 + 冷却）
-- 引脚与参数：config.lua → PIR_CFG
-- @module pir
-- @release 2026.5.20

require "sys"
require "config"
local gpio_util = require "gpio_util"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "pir"
local pin
local cfg
local started = false
local cooldownUntil = 0

local function onInterrupt(level)
    if _G.T31_BURN_MODE_ACTIVE then
        return
    end
    log.info(LOG_TAG, "触发0", pin)
    local active = cfg.active_level
    if active == nil then
        active = 1
    end
    if level ~= active then
        return
    end

    local now = os.time() * 1000
    if now < cooldownUntil then
        return
    end

    cooldownUntil = now + (cfg.cooldown_ms or 10000)
    log.info(LOG_TAG, "触发", pin)

    local E = _G.APP_EVENTS
    if E and E.PIR_HW_TRIGGERED then
        sys.publish(E.PIR_HW_TRIGGERED)
    end
end

function start()
    if started then
        return false
    end
    cfg = _G.PIR_CFG
    pin = cfg and cfg.pin
    if not pin or not cfg then
        log.warn(LOG_TAG, "PIR_CFG 无效")
        return false
    end

    gpio_util.setup_input(pin, onInterrupt, {
        trigger_mode = cfg.trigger_mode or "rising",
        pull = cfg.pull or "pulldown",
        debounce_ms = cfg.debounce_ms or 100,
    })
    started = true
    log.info(LOG_TAG, "已启动", pin, "cooldown", cfg.cooldown_ms or 10000)
    return true
end

function getState()
    return { started = started, pin = pin }
end

return _M
