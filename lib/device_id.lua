-- ================================================================
-- Filename : device_id.lua
-- Module   : 设备标识：IMEI 获取 + 显示用 deviceNo 生成
-- Arch     : doc/modules/LIB_RUNTIME_UTILS.md
-- ================================================================

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local cachedImei

local function validImei(id)
    return id and id ~= "" and id ~= "unknown"
end

function setImei(id)
    cachedImei = id
end

function getImei()
    if validImei(cachedImei) then
        return tostring(cachedImei)
    end
    local id = mobile and mobile.imei and mobile.imei()
    -- mobile 无卡时可能回 "unknown"，与 cachedImei 同一过滤口径，
    -- 避免字面 "unknown" 绕过 getDeviceId() 的 "unknown_device" 兜底
    return validImei(id) and tostring(id) or nil
end

function getDeviceId()
    return getImei() or "unknown_device"
end

function getDisplayId()
    return getImei() or "unknown"
end

return _M
