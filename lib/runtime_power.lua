-- ================================================================
-- Filename : runtime_power.lua
-- Module   : 运行时功耗管理：pm 接口封装、休眠/唤醒调度辅助
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local WORK_PERSON_DETECT = "person_detect"
local WORK_PIR_WATCH = "pir_watch"

function getWorkMode()
    local rt = _G.APP_RUNTIME
    local m = rt and rt.work_mode
    if m == WORK_PIR_WATCH then
        return WORK_PIR_WATCH
    end
    return WORK_PERSON_DETECT
end

function setWorkMode(mode)
    local rt = _G.APP_RUNTIME
    if type(rt) ~= "table" then
        return getWorkMode()
    end
    if mode == WORK_PIR_WATCH then
        rt.work_mode = WORK_PIR_WATCH
    else
        rt.work_mode = WORK_PERSON_DETECT
    end
    return rt.work_mode
end

function isPirWatch()
    return getWorkMode() == WORK_PIR_WATCH
end

function isLowPowerMode()
    local rt = _G.APP_RUNTIME
    return rt and tonumber(rt.low_power_mode) == 1
end

function isBatDynRest()
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.battery_dynamic_rest) == 1 then
        return true
    end
    local bg = loader.load("battery_guard")
    if bg and bg.isBatDynRest then
        return bg.isBatDynRest() == true
    end
    return false
end

function isUsbInserted()
    local uc = loader.load("usb_charge")
    if uc and type(uc.isUsbInserted) == "function" then
        local ok2, v = pcall(uc.isUsbInserted)
        if ok2 then
            return v == true
        end
    end
    local rt = _G.APP_RUNTIME or {}
    return tonumber(rt.power_status) == 1
end

return _M
