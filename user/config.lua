-- ================================================================
-- Filename : config.lua
-- Module   : 硬件与策略总配置编排（配置片段见 config/ 子目录）
-- Arch     : 见 doc/LUA_MODULES.md
-- Note     : 本文件仅按依赖顺序 require 各片段；所有配置以 _G.X_CFG 暴露，
--            由 config_manager 统一读取。新增配置请归入对应 config/<group>.lua。
--            加载顺序必须保持：features 最先（定义 FEATURE_CFG），其余按依赖排列。
-- ================================================================

module(..., package.seeall)
_G[_modname or (...)] = _M

-- 必需顺序：features 提供 FEATURE_CFG，其后片段均依赖之。
-- 注意：Luatools 不递归扫本文件 require，片段须在 main.lua __LUATOOLS_SCAN_ANCHOR__ 挂名，否则会 module not found。
require "features"      -- 功能开关宏 / RNDIS / 低功耗 / USB / APP 元信息 / 运行态种子
require "cellular"      -- 蜂窝 APN / 搜网复位
require "t31x_burn"      -- t31x 烧录门禁
require "gpio_cfg"      -- GPIO 输入/输出 / KEY_CONFIG（含 GPIO_IN，须先于 led_pir；勿用 gpio，与核心库冲突）
require "led_pir"       -- LED / WLED / PIR 冷却与硬件 / 持久化路径（依赖 gpio_cfg）
require "battery"       -- 电量保护 / t31x 唤醒门禁 / 低功耗进入策略（依赖 features）
require "host"          -- 主机 T31x 侧服务（依赖 features）
require "net"           -- UART / 看门狗 / MQTT / FOTA / resFotaUrl
require "flags"         -- MODULE_FLAGS 服务裁剪（依赖 features）
require "events"        -- APP_EVENTS 事件名常量

return _M
