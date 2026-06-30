require "sys"
require "config"
-- GPIO_IN/OUT → gpio.setup 封装；专题 doc/modules/LIB_UART_GPIO.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
function trigger_mode(mode)
    return ({ rising = 0, falling = 1, both = 2 })[mode] or 0
end
function pull(pull_name)
    return ({ pullup = 1, pulldown = 2 })[pull_name] or 1
end
function in_pin(name)
    local e = _G.GPIO_IN and _G.GPIO_IN[name]
    return e and e.pin
end
function out_pin(name)
    local e = _G.GPIO_OUT and _G.GPIO_OUT[name]
    return e and e.pin
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
    local level = entry.init_level
    if level == nil then
        level = 0
    end
    return gpio.setup(entry.pin, level)
end
function set_output(entry, on)
    if not entry or not entry.pin then
        return false
    end
    local level = on and (entry.on_level or 1) or (entry.init_level or 0)
    gpio.set(entry.pin, level)
    return true
end
return _M
