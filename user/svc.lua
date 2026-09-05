-- ================================================================
-- Filename : svc.lua
-- Module   : 业务服务定位器：跨域懒加载桥（host_uart / uart_bridge / t31x_ctrl）
-- Arch     : 见 doc/overview/CODE_LAYERING_ARCHITECTURE.md · doc/modules/LIB_RUNTIME_UTILS.md §svc
-- Note     : 原 lib/utils.hostUart / uartBridge / t31xOn（refactor_plan P1b 迁出）。
--            这三座桥让 lib 反向懒加载 user 业务，违反 lib↛user（_layer_check R1）；
--            迁到 user/ 后 lib 回归业务无感。实现逐字等价，均经 module_loader 缓存。
--            本模块只准 require module_loader，不得 require 任何业务模块（避免重入软环变硬环）。
-- ================================================================

local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function hostUart()
    return loader.load("host_uart")
end

function uartBridge()
    return loader.load("uart_bridge")
end

-- 确保 T31x 上电：tag 为策略标签，extra 优先于 defaultExtra
function t31xOn(tag, extra, defaultExtra)
    local t31x = loader.load("t31x_ctrl")
    if not t31x then return false end
    return t31x.ensPowOn(tag, extra or defaultExtra)
end

return _M
