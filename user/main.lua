-- 780EHM_PJ 入口
-- 启动链: main → app.start(peripheral, net, t3x_ctrl) → sys.run()
PROJECT = PROJECT or "TUYA_CAT1"
VERSION = VERSION or "v1_20260529"
BUILD_TAG = "v1_20260529"

local moduleName = ...
local isEntry = moduleName == nil

require "sys"
require "sysplus"
require "config"
require "app_config"
require "key_config"

local app = require "app"
local peripheral = require "peripheral"
local net = require "net_mqtt"
local t3x_ctrl = require "t3x_ctrl"

if not isEntry then
    return app
end

log.info("main", "版本", VERSION, BUILD_TAG, "core", rtos.version())

if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    -- 开启 PWRKEY 防抖：关机后需长按 K1 约 2s 才能再开机（见 doc/KEY_GPIO.md）
    pm.power(pm.PWK_MODE, true)
end

-- ① RNDIS：与 pwrkey_rndis_boot/main.lua 相同 sys.taskInit(rndis.open)
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.rndis then
    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if okMod and type(usb_rndis) == "table" and usb_rndis.open then
        sys.taskInit(usb_rndis.open)
        log.info("main", "RNDIS taskInit(open)")
    else
        log.warn("main", "usb_rndis 不可用，跳过 RNDIS")
    end
end

-- ③ 4G 拨号等 IP_READY（与 pwrkey_rndis_boot net.start 一致，RNDIS 共享此连接）
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.mqtt and net.bootstrapNetwork then
    net.bootstrapNetwork()
end

app.start(peripheral, net, t3x_ctrl)

sys.run()
