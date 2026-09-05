-- 护栏单测样本：单引号 cfgm.get 视为消费（复制进临时仓库 user/ 后运行）
local cfgm = require "config_manager"
local _zz2 = cfgm.get('ZZ_DEAD_CFG')
