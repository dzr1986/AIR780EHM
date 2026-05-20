-- 780EHM_PJ 入口
-- 启动链: main → app.start(peripheral, net, t3x) → sys.run()
PROJECT = PROJECT or "TUYA_CAT1"
VERSION = VERSION or "1.0.0"

local moduleName = ...
local isEntry = moduleName == nil

require "sys"
require "sysplus"
require "config"
require "app_config"
require "key_config"

local app = require "app"
local peripheral = require "peripheral"
local net = require "net"
local t3x = require "t3x"

if not isEntry then
    return app
end

log.info("main", "版本", VERSION, "core", rtos.version())

if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

app.start(peripheral, net, t3x)

sys.run()
