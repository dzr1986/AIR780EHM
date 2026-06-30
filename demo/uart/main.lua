--[[
@module  main
@summary UART 串口收发示例 / UART communication demo
@version 1.0
@date    2026.06.30
@usage
本 demo 演示 LuatOS UART 功能：
  - 打开 UART1，波特率 115200
  - 每隔 2 秒发送一条测试消息
  - 收到数据后通过日志打印
接线说明：
  - 将 PC USB 转 TTL 模块的 TX 接模组 RX1，RX 接模组 TX1
]]

PROJECT = "AIR780EHM_uart"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

local UART_ID   = 1          -- 使用 UART1
local BAUD_RATE = 115200

-- 初始化 UART
uart.setup(UART_ID, BAUD_RATE, 8, 1, uart.NONE)

-- 注册接收回调
uart.on(UART_ID, "receive", function(id, len)
    local data = uart.read(id, len)
    log.info("uart", "received", #data, "bytes:", data)
end)

-- 定时发送任务
sys.taskInit(function()
    log.info("uart", "UART demo started, baud =", BAUD_RATE)
    local count = 0
    while true do
        count = count + 1
        local msg = string.format("AIR780EHM UART test #%d\r\n", count)
        uart.write(UART_ID, msg)
        log.info("uart", "sent:", msg)
        sys.wait(2000)
    end
end)

sys.run()
