--[[
@module  rndis
@summary 与 testmy/user/main.lua 中 rndis_open() 完全一致
]]

local M = {}

function M.open()
    mobile.flymode(0, true)
    sys.wait(1000)
    mobile.config(mobile.CONF_USB_ETHERNET, 3)
    mobile.flymode(0, false)
    pm.request(pm.IDLE)
    pm.power(pm.USB, true)
    log.info("rndis", "RNDIS 已开启，PC 连接 USB 网卡 DHCP 即可")
end

return M
