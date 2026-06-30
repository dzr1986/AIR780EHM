--[[
@module  main
@summary GPIO 数字输出控制 LED 闪烁示例 / GPIO LED blink demo
@version 1.0
@date    2026.06.30
@usage
本 demo 演示 LuatOS GPIO 功能：控制一个 LED 每隔 500ms 翻转一次电平（闪烁）。
接线说明：
  - 将 LED 正极（经 330 Ω 限流电阻）接到模组 GPIO4（或根据实际硬件修改 LED_PIN）
  - LED 负极接 GND
]]

PROJECT = "AIR780EHM_gpio"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

-- 根据实际硬件修改引脚编号
local LED_PIN = gpio.setup(4, 0, gpio.PULLUP)  -- GPIO4，初始低电平，上拉

sys.taskInit(function()
    log.info("gpio", "LED blink demo started")
    local level = 0
    while true do
        level = 1 - level          -- 翻转电平
        gpio.set(4, level)
        log.info("gpio", "LED level =", level)
        sys.wait(500)              -- 等待 500ms
    end
end)

sys.run()
