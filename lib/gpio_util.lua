-- ================================================================
-- Filename : gpio_util.lua
-- Module   : GPIO 配置工具：GPIO_IN/OUT 表转 gpio.setup，含 pull/边沿/防抖/输出初始化
-- Arch     : doc/modules/LIB_UART_GPIO.md
-- ================================================================

require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local TRIGGER = { rising = 0, falling = 1, both = 2 }
local PULL = { pullup = 1, pulldown = 2 }

function triggerMode(mode)
    return TRIGGER[mode] or 0
end

function pull(pull_name)
    return PULL[pull_name] or 1
end

-- opts 同时接受 camelCase（triggerMode/debounce）与 GPIO_IN 表原生 snake_case
-- （trigger_mode/debounce_ms）。9bcfc78 曾只留 camelCase，而 pir_ctrl/peripheral/usb_charge
-- 仍传 snake_case → 按键 both 边沿与全部防抖静默失效（长按事件永不触发）。此处为唯一归一点。
function setupInput(pin, callback, opts)
    if pin == nil or not callback then return false end
    opts = opts or {}
    gpio.setup(
        pin,
        callback,
        pull(opts.pull or opts.pull_mode or "pullup"),
        triggerMode(opts.triggerMode or opts.trigger_mode or "rising")
    )
    local debounce = opts.debounce
    if debounce == nil then debounce = opts.debounce_ms end
    if debounce and debounce > 0 then
        gpio.debounce(pin, debounce)
    end
    return true
end

function setupInputEntry(entry, callback, overrides)
    if not entry or entry.pin == nil then return false end
    local opts = {
        pull = entry.pull,
        triggerMode = entry.trigger_mode,
        debounce = entry.debounce_ms or entry.debounce,
    }
    if overrides then
        for k, v in pairs(overrides) do opts[k] = v end
    end
    return setupInput(entry.pin, callback, opts)
end

function setupOutput(entry)
    if not entry or entry.pin == nil then return end
    local lvl = entry.init_level ~= nil and entry.init_level or 0
    return gpio.setup(entry.pin, lvl)
end

return _M
