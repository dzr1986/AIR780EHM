-- Luatools 合并必需（与 testmy 一致）
PROJECT = "pwrkey_rndis_boot"
VERSION = "1.0.0"

_G.sys = require("sys")

local cfg = require "config"
local rndis = require "rndis"
local net = require "net"
local pwrkey_boot = require "pwrkey_boot"

log.info("main", PROJECT, VERSION, "core", rtos.version())

-- Air780E 关闭开机键默认防抖（testmy/main.lua）
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- ① RNDIS：与 testmy main.lua rndis_open 相同，尽早启动
sys.taskInit(rndis.open)

-- ② 红灯默认关闭（testmy init_gpio20）
sys.taskInit(function()
    if cfg.led_red_io then
        gpio.setup(cfg.led_red_io, 0)
        gpio.set(cfg.led_red_io, 0)
        log.info("main", "GPIO%d 红灯关闭", cfg.led_red_io)
    end
end)

-- ③ 4G 拨号等 IP_READY（testmy 由 single_mqtt 完成，RNDIS 依赖此连接）
net.start()

-- ④ pwrkey / boot / T31（testmy 由 gpio_irq_test 完成）
sys.taskInit(function()
    pwrkey_boot.init_gpio()
    pwrkey_boot.power_on_t31()
    log.info("main", "按键就绪: pwrkey 长按 %dms 关机", cfg.pwrkey_long_ms)
end)

sys.run()
