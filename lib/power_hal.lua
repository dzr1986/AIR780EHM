-- ================================================================
-- Filename : power_hal.lua
-- Module   : L0 HAL — pm/pmd 电源原语封装（全仓库唯一允许直接调 pm.*/pmd.* 的 lib 模块之一）
-- Arch     : AGENTS.md §6 收敛目标；业务层/user 禁止直调 pm/pmd
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function shutdown()
    if pm and pm.shutdown then
        pm.shutdown()
    end
end

function reboot(delayMs)
    delayMs = tonumber(delayMs) or 0
    sys.timerStart(function()
        if pm and pm.reboot then
            pm.reboot()
        end
    end, delayMs)
end

function hibernate()
    if pm and pm.hibernate then
        pm.hibernate()
    end
end

-- EC618 唤醒键模式（main 冷启动唯一入口）
function initPwkMode()
    if rtos and rtos.bsp() == "EC618" and pm and pm.PWK_MODE and pm.power then
        pm.power(pm.PWK_MODE, true)
    end
end

-- pmd 充电/插拔消息：onMsg 由 L3 app 注入；库缺失时 no-op
function initPmd(onMsg)
    if not (rtos and rtos.MSG_PMD and pmd and pmd.init) then
        return false
    end
    if type(onMsg) == "function" then
        rtos.on(rtos.MSG_PMD, onMsg)
    end
    pmd.init({})
    return true
end

return _M
