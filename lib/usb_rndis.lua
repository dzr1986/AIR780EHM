--- USB RNDIS 网卡（PC 经 USB 共享模组数据通道）
-- 勿命名为 rndis.lua：与 LuatOS 内置 rndis 库重名，require 会得到 boolean
-- 合宙 Air780：mobile.config(CONF_USB_ETHERNET, 3)
-- @module usb_rndis
-- @release 2026.5.19

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "usb_rndis"
local started = false

local function openTask()
    if not mobile or not mobile.flymode or not mobile.config then
        log.warn(LOG_TAG, "mobile 库不可用，跳过 RNDIS")
        return
    end
    if mobile.CONF_USB_ETHERNET == nil then
        log.warn(LOG_TAG, "固件无 CONF_USB_ETHERNET，跳过 RNDIS")
        return
    end

    log.info(LOG_TAG, "开启 USB RNDIS...")
    mobile.flymode(0, true)
    sys.wait(1000)
    mobile.config(mobile.CONF_USB_ETHERNET, 3)
    mobile.flymode(0, false)

    if pm then
        if pm.request then
            pm.request(pm.IDLE)
        end
        if pm.power and pm.USB then
            pm.power(pm.USB, true)
        end
    end

    log.info(LOG_TAG, "RNDIS 已配置（USB 以太网模式）")
end

--- 异步启动 RNDIS（重复调用无效）
function start()
    if started then
        return false
    end
    started = true
    sys.taskInit(openTask)
    return true
end

function isStarted()
    return started
end
