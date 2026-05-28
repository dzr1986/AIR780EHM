--[[
@module  config
@summary pwrkey + 开机 + RNDIS 配置（与 testmy projectConfig.lua 引脚一致）
]]

local M = {}

M.pwrkey_io = gpio.PWR_KEY
M.pwrkey_long_ms = 3000

M.bootkey_io = 28
M.bootkey_long_ms = 2000

M.t31_power_io = 22
M.t31_boot_io = 26
M.t31_ota_io = 32

M.led_red_io = 20
M.netstatus_io = 27

return M
