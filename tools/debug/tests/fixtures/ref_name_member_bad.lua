-- 护栏单测样本：host_uart 成员不存在 + modCall 实参超形参（P9 规则 D/E）
local hostUart = require "host_uart"
local function zz(hif) return hif.noSuchFnZZ() end
local function zz2() return modCall("t31x_policy", "isBurnActive", 1, 2, 3) end
