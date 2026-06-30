--[[
@module  hello_luatos
@summary Hello World 基础示例模块 / Hello World basic demo module
@version 1.0
@date    2026.06.30
@usage
每隔 1 秒钟通过日志输出一次 "Hello, LuatOS!"。
]]

sys.taskInit(function()
    while true do
        log.info("hello", "Hello, LuatOS!")
        sys.wait(1000)
    end
end)
