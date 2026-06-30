--[[
@module  hello_luatos
@summary Hello World 基础示例 / Hello World basic demo
@version 1.0
@date    2026.06.30
@usage
本 demo 演示 LuatOS 的基础运行环境。
每隔 1 秒钟通过日志输出一次 "Hello, LuatOS!"。
]]

-- 启动一个异步任务，每秒打印一条日志
sys.taskInit(function()
    while true do
        log.info("hello", "Hello, LuatOS!")
        sys.wait(1000)
    end
end)
