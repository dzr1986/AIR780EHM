--- 设备 IMEI 单点解析（MQTT topic / AT+IMEI / 日志横幅）
-- @module device_id

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

--- @return string|nil
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

--- MQTT topic / 上行 JSON 用
function getDeviceId()
    return getImei() or "unknown_device"
end

--- 日志横幅等
function getDisplayId()
    return getImei() or "unknown"
end

return _M
