-- 护栏单测样本：5 类应被 _gpio_opts_check 抓到的写法（复制进临时仓库 user/ 后运行）
local g = require "gpio_util"
local setupIn = gpio_util.setupInput
gpio_util.setupInput(1, function() end, { bogus_key = 1, debounce_ms = 5 })              -- 单行字面表错键
g.setupInput(2, function(l) local t = { x = 1 } end, { trigger_mode = "both" })         -- 模块别名 + 回调内嵌套表（合法，不应误报）
setupIn(3, cb, { typo = 2 })                                                             -- 函数别名错键
local o = { debounce = 1 }
gpio_util.setupInput(4, cb, o)                                                           -- 变量传 opts → 未覆盖
gpio_util.setupInputEntry(entry, cb, { bad_override = 1 })                              -- overrides 错键
