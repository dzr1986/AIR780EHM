-- IMEI 解析；专题 doc/modules/LIB_RUNTIME_UTILS.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
function getImei()
    if _G.device_imei and _G.device_imei ~= "" and _G.device_imei ~= "unknown" then
        return tostring(_G.device_imei)
    end
    if _G.aliyuncs_imei and _G.aliyuncs_imei ~= "" then
        return tostring(_G.aliyuncs_imei)
    end
    if mobile and mobile.imei then
        local id = mobile.imei()
        if id and id ~= "" then
            return tostring(id)
        end
    end
    return nil
end
function getDeviceId()
    return getImei() or "unknown_device"
end
function getDisplayId()
    return getImei() or "unknown"
end
return _M
