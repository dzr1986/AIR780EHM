--- GPIO 输入工具（lib 层公共）
-- @module gpioUtil
-- @release 2026.5.18

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function triggerMode(mode)
    return ({ rising = 0, falling = 1, both = 2 })[mode] or 0
end

function pull(pullName)
    return ({ pullup = 1, pulldown = 2 })[pullName] or 1
end

--- 配置 GPIO 中断输入
-- @param pin number
-- @param callback function(level)
-- @param opts { triggerMode, pull, debounce }
function setupInput(pin, callback, opts)
    if not pin or not callback then
        return false
    end
    opts = opts or {}
    gpio.setup(
        pin,
        callback,
        pull(opts.pull or "pullup"),
        triggerMode(opts.triggerMode or "rising")
    )
    local debounce = opts.debounce
    if debounce and debounce > 0 then
        gpio.debounce(pin, debounce)
    end
    return true
end

return _M
