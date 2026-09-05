-- 项目统一使用 Lua 5.1 兼容的 module(..., package.seeall) 模式（固件提供兼容层），
-- 全局读写类告警（1xx）属于该模式的固有噪音；行宽（631）不作约束。
-- 用法: luacheck user lib
std = "lua53"
ignore = { "11", "12", "13", "14", "631" }
exclude_files = {
    "archive/**",
    "t31x_ipc/**",
    "tools/**",
    "test/**",
}
