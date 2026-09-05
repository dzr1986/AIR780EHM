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

-- RNDIS USB 网卡：进入 IDLE 并打开 USB 电源（原 usb_rndis.pmUsbApply）
function requestIdle()
    if pm and pm.request and pm.IDLE then
        pm.request(pm.IDLE)
    end
end

function setUsbPower(on)
    if not pm or not pm.power or not pm.USB then
        return false
    end
    return pcall(pm.power, pm.USB, on == true)
end

function prepareUsbRndis()
    requestIdle()
    setUsbPower(true)
end

-- 软重枚举：USB 断电 pauseMs 再上电 + prepareUsbRndis（须在协程内调用）
function cycleUsbPower(pauseMs)
    if not pm or not pm.power or not pm.USB then
        return false
    end
    local ms = tonumber(pauseMs) or 500
    if ms < 100 then
        ms = 100
    end
    pcall(pm.power, pm.USB, false)
    sys.wait(ms)
    pcall(pm.power, pm.USB, true)
    prepareUsbRndis()
    return true
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
