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
local pir_runtime = nil
pcall(function() pir_runtime = require "pir_runtime" end)

local function statBump(key)
    if pir_runtime and pir_runtime.bump then
        pir_runtime.bump(key)
    end
end

local function statLast(evt)
    if pir_runtime and pir_runtime.setLast then
        pir_runtime.setLast(evt)
    end
end

local function onInterrupt(level)
    statBump("cnt_hw_irq")
    if _G.T3X_BURN_MODE_ACTIVE then
        statBump("cnt_hw_ignore_burn")
        statLast("ignore_burn")
        return
    end
    log.info(LOG_TAG, "触发0", pin)
    local active = cfg.active_level
    if active == nil then
        active = 1
    end
    if level ~= active then
        statBump("cnt_hw_ignore_level")
        return
    end

    local now = os.time() * 1000
    if now < cooldownUntil then
        statBump("cnt_hw_ignore_cooldown")
        statLast("ignore_cooldown")
        return
    end

    cooldownUntil = now + (cfg.cooldown_ms or 10000)
    statBump("cnt_hw_accept")
    statLast("hw_accept")
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
    local now = os.time() * 1000
    local remain = 0
    if cooldownUntil > now then
        remain = cooldownUntil - now
    end
    return {
        started = started,
        pin = pin,
        cooldown_remaining_ms = remain,
    }
end

return _M
