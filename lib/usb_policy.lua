--- USB 插入判定与 rest 门禁单点（读 HOST_USB_CFG）
-- @module usb_policy

require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function usb_cfg()
    return _G.HOST_USB_CFG or {}
end

--- 物理 USB 插入：优先 usb_charge GPIO，回退 APP_RUNTIME.power_status
function isUsbInserted()
    local ok, mod = pcall(require, "usb_charge")
    if ok and type(mod) == "table" and type(mod.isUsbInserted) == "function" then
        local ok2, v = pcall(mod.isUsbInserted)
        if ok2 then
            return v == true
        end
    end
    local rt = _G.APP_RUNTIME or {}
    return tonumber(rt.power_status) == 1
end

function blocksHostIdle()
    if usb_cfg().block_host_idle_when_usb == false then
        return false
    end
    return isUsbInserted()
end

function blocks4gRest()
    if usb_cfg().block_4g_rest_when_usb == false then
        return false
    end
    return isUsbInserted()
end

function mayEnterRest()
    return not blocks4gRest()
end

return _M
