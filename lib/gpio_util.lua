--- GPIO 工具：输入中断、输出上电初始化（读 config.GPIO_IN / GPIO_OUT）
-- @module gpio_util
-- @release 2026.5.21

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

--- 取输入项 pin 号
function in_pin(name)
    local e = _G.GPIO_IN and _G.GPIO_IN[name]
    return e and e.pin
end

--- 取输出项 pin 号
function out_pin(name)
    local e = _G.GPIO_OUT and _G.GPIO_OUT[name]
    return e and e.pin
end

--- 配置 GPIO 中断输入（opts 可覆盖 entry 内字段）
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

--- 按 GPIO_IN 表项注册中断
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

--- 输出脚初始化，返回 gpio.setup 句柄（可 gpio.handle(level)）
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

--- 写到 on_level / 灭到 init_level
function set_output(entry, on)
    if not entry or not entry.pin then
        return false
    end
    local level = on and (entry.on_level or 1) or (entry.init_level or 0)
    gpio.set(entry.pin, level)
    return true
end

return _M
