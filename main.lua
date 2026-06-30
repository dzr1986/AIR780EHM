--[[
@module  main
@summary LuatOS 用户应用脚本入口 / LuatOS user application entry point
@version 1.0
@date    2026.06.30
@usage
AIR780EHM 主入口脚本。
根据需要取消注释对应的 require 行，以加载不同的演示模块。
]]

-- 项目名称和版本号（Luatools 和远程升级功能会使用这两个变量）
-- PROJECT: 项目名，ASCII 字符串
-- VERSION: 版本号，格式 "XXX.YYY.ZZZ"（YYY 固定为 999）
PROJECT = "AIR780EHM"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

-- 加载演示模块（根据需要取消注释）
-- Uncomment the module you want to run:

-- require "hello_luatos"   -- Hello World 示例
-- require "gpio_demo"      -- GPIO 示例
-- require "uart_demo"      -- UART 示例
-- require "http_demo"      -- HTTP 示例
-- require "mqtt_demo"      -- MQTT 示例

-- 默认运行 Hello World
require "hello_luatos"

-- 用户代码结束 -------------------------------------------------
-- 结尾必须调用 sys.run()
sys.run()
-- sys.run() 之后不要添加任何语句，因为它们不会被执行！
