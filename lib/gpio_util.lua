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
function trigger_mode(mode)
    return ({ rising = 0, falling = 1, both = 2 })[mode] or 0
end

function pull(pull_name)
    return ({ pullup = 1, pulldown = 2 })[pull_name] or 1
end

function setup_input(pin, callback, opts)
    if not pin or not callback then
        return false
    end
    opts = opts or {}
    gpio.setup(
        pin,
        callback,
        pull(opts.pull or "pullup"),
        trigger_mode(opts.trigger_mode or opts.triggerMode or "rising")
    )
    local debounce = opts.debounce_ms or opts.debounce
    if debounce and debounce > 0 then
        gpio.debounce(pin, debounce)
    end
    return true
end

function setup_input_entry(entry, callback, overrides)
    if not entry or not entry.pin then
        return false
    end
    local opts = {
        pull = entry.pull,
        trigger_mode = entry.trigger_mode,
        debounce_ms = entry.debounce_ms,
    }
    if overrides then
        for k, v in pairs(overrides) do
            opts[k] = v
        end
    end
    return setup_input(entry.pin, callback, opts)
end

function setup_output(entry)
    if not entry or not entry.pin then
        return nil
    end
    local level = entry.init_level or 0
    return gpio.setup(entry.pin, level)
end

return _M
