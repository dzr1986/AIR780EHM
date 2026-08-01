# Cat.1 user/lib 模块框架（module_loader / config_manager）

> 本文描述 2026-08 框架整合后的模块加载、配置访问、生命周期与事件约定。  
> 相关文档：[CALL_GRAPH.md](CALL_GRAPH.md)（启动顺序）、[LUA_MODULES.md](LUA_MODULES.md)（模块职责）、[CAT1_USER_LIB_SLIM.md](CAT1_USER_LIB_SLIM.md)（瘦身速查）。

---

## 1. 背景与目标

整合前存在多套并行实现：

| 问题 | 整合前 | 整合后 |
|------|--------|--------|
| 条件加载 | `app.lua` 私有 `optMod()`（16 行） | `module_loader.opt(flag, name)` |
| 懒加载 | `utils.lazyRequire()` 私有缓存 + 全项目 60+ 处裸 `pcall(require)` | `module_loader.load(name)` 单一缓存 |
| 配置合并 | 各模块手写 `cfg()` + for 循环 merge（如 `led_ctrl.lua`） | `config_manager.merge/get/num/bool` |
| 日志 | `utils.createLogFunctions(tag)` 与死变量 `LOG_TAG` 并存 | 统一 `createLogFunctions`；删除 8 处死 `LOG_TAG` |
| 事件 topic | `"BATTERY_UPDATE"` 等散落硬编码 | 收编进 `APP_EVENTS` |

**体积约束**：脚本区约 512KB（见 [CAT1_SLIMMING_FLOW.md](CAT1_SLIMMING_FLOW.md)）。两个框架文件合计约 130 行源码，同时删除了等量重复代码，净体积基本持平。

---

## 2. lib/module_loader.lua — 模块加载框架

单一 require 缓存 + `MODULE_FLAGS` 检查 + 生命周期登记。

### 2.1 API

| 函数 | 说明 |
|------|------|
| `load(name)` | 安全 require（`pcall` + 缓存）。失败或返回非 table 时得 `nil`，**负结果也缓存**，不重复尝试 |
| `enabled(flag)` | 读 `_G.MODULE_FLAGS[flag]`；`false` 为关，`nil`/其余为开 |
| `opt(flag, name)` | `enabled(flag)` 为假返回 `nil`，否则 `load(name or flag)`（等价原 `optMod`） |
| `start(mod, fn, opts)` | 安全调用生命周期方法（默认 `"start"`）；`mod` 可为模块表或模块名。成功 start 的模块登记 |
| `stopAll()` | **逆序**停止已登记模块（模块有 `stop()` 才调用） |

### 2.2 用法

```lua
local loader = require "module_loader"

-- 按 MODULE_FLAGS 条件加载（关闭时得 nil）
local fota = loader.opt("fota", "fota_svc")

-- 懒加载（不存在/失败时得 nil，且不再重试）
local policy = loader.load("t3x_policy")

-- 安全启动可选服务
loader.start(batAdc, "start")
loader.start(time_sync, "startSntp")
```

### 2.3 接入点

| 文件 | 改动 |
|------|------|
| [user/app.lua](../user/app.lua) | 删除 `optMod()`；8 个可选模块改 `loader.opt`；`lazyMod`/`startOptionalService` 委托 loader |
| [user/main.lua](../user/main.lua) | `cellular_bootstrap`、`usb_rndis` 改 `loader.load` |
| [user/utils.lua](../user/utils.lua) | `lazyRequire` 委托 `loader.load`（消除双缓存），旧调用方无需改动 |

---

## 3. lib/config_manager.lua — 配置访问框架

替代各模块散落的 `cfg()` + 手工默认值合并。

### 3.1 API

| 函数 | 说明 |
|------|------|
| `get(name)` | 取全局配置表（如 `"LED_CFG"`）；不存在返回 `{}`。**不缓存**，支持运行时覆盖 |
| `num(t, key, default)` | 数值配置；`t` 可为表或全局配置名 |
| `bool(t, key, default)` | 布尔配置；`nil` 用默认值；`false/0/"0"` 为 false |
| `merge(defaults, overrides, keys)` | 将 overrides（表或全局配置名）合并进 defaults 并返回。`keys` 白名单限定合并键；无 keys 时全量合并，子表做一层浅合并 |

### 3.2 用法（led_ctrl 实例）

```lua
local cfgman = require "config_manager"

-- 子表全量合并
cfgman.merge(LED_CONFIG.startup, fromLed.startup)

-- 白名单合并（只接受已知键，防配置污染）
cfgman.merge(LED_CONFIG, fromLed, {
    "low_percent", "low_blink_ms", "offline_blink_ms", ...
})
```

---

## 4. 生命周期约定

```
main.lua（入口守卫 isEntry）
  ├─ require config          → 全局配置就绪（_G.*_CFG / MODULE_FLAGS / APP_EVENTS）
  ├─ loader.load cellular_bootstrap → cellular.start()
  ├─ loader.load usb_rndis   → usb_rndis.open()（rndis 开时）
  ├─ app.start(peripheral, net_mqtt, t3x_ctrl)
  │    ├─ setupEventHandlers()   订阅 APP_EVENTS
  │    ├─ battery_guard.start / setupWatchdog / setupUartBridge
  │    ├─ t3x_ctrl.start / sound_prompt.start / time_sync.start
  │    ├─ setupGpio / startBackgroundServices（vbat/usb_charge/sntp）
  │    └─ bootMqtt / setupFota / startHeartbeat
  └─ sys.run()
```

模块约定：

- **必须**：`start(opts)` — 幂等（重复调用返回 false 或忽略）；opts 为单个 table。
- **可选**：`stop()` — 目前仅 `host_uart`、`net_mqtt`、`uart_bridge`、`watchdog` 提供；新模块若持有定时器/连接**应**实现，`loader.stopAll()` 会逆序调用。
- **可选**：`getState()` — 返回快照 table，供 AT/MQTT 查询。

---

## 5. 日志约定

统一使用 `utils.createLogFunctions(tag)`：

```lua
local logFuncs = utils.createLogFunctions("my_mod")
local info, warn, err = logFuncs.info, logFuncs.warn, logFuncs.error
```

- 已采用：app、battery_guard、net_mqtt、pir_ctrl、t3x_ctrl、time_sync。
- `host_uart` 仍保留 `LOG_TAG` 直调 `log.error`（仅 4 处崩溃日志，剥离脚本会保留 error 级）。
- 本次已删除 **8 处**定义后从未使用的死 `LOG_TAG`（peripheral / sound_prompt / vbat / cellular_bootstrap / host_event / uart_bridge / usb_charge / watchdog）。

---

## 6. 事件约定

- 所有跨模块 topic **必须**定义在 `config.lua` 的 `_G.APP_EVENTS`，使用方 `local E = APP_EVENTS`。
- 本次收编：`BATTERY_UPDATE`（vbat 发布 → app/led_ctrl/net_mqtt 订阅），字符串值保持 `"BATTERY_UPDATE"` 不变，兼容旧固件抓包。
- 例外（不收编）：LuatOS 系统事件（`"IP_READY"`、`"NTP_UPDATE"`）；模块内部自发自收事件（如 time_sync 的 `"SNTP_SYNC_SUCCESS"`）。

---

## 7. 本次整合改动清单

| 文件 | 类型 | 说明 |
|------|------|------|
| [lib/module_loader.lua](../lib/module_loader.lua) | 新增 | 模块加载框架（~65 行） |
| [lib/config_manager.lua](../lib/config_manager.lua) | 新增 | 配置访问框架（~65 行） |
| [user/app.lua](../user/app.lua) | 改造 | 删 `optMod`；`loader.opt/load/start` 接管；`E.BATTERY_UPDATE` |
| [user/main.lua](../user/main.lua) | 改造 | cellular/rndis 加载走 loader |
| [user/utils.lua](../user/utils.lua) | 改造 | `lazyRequire` 委托 loader（API 不变） |
| [user/led_ctrl.lua](../user/led_ctrl.lua) | 改造 | `applyConfigs` 用 `cfgman.merge`；`E.BATTERY_UPDATE` |
| [user/config.lua](../user/config.lua) | 改造 | `APP_EVENTS.BATTERY_UPDATE` 收编 |
| [user/net_mqtt.lua](../user/net_mqtt.lua) / [user/vbat.lua](../user/vbat.lua) | 改造 | BATTERY_UPDATE 改用 `APP_EVENTS` |
| peripheral / sound_prompt / vbat / 5 个 lib 模块 | 清理 | 删死 `LOG_TAG` |

验证：全部改动文件过 `luac5.3 -p` 语法检查；`module_loader`/`config_manager` 通过单元测试（load 缓存/负缓存、opt 开关、start/stopAll 逆序、num/bool/merge/白名单）。

---

## 8. 后续渐进迁移建议

1. **裸 `pcall(require)` 收敛**：全项目仍有约 60 处，改动一处业务文件时顺带换成 `loader.load`（勿一次性全改，避免回归）。
2. **配置 merge 收敛**：`watchdog.mergeConfig`、`pir_ctrl` 等模块的手工 merge 可逐步换 `cfgman.merge`。
3. **stop() 补齐**：`vbat`、`time_sync`、`led_ctrl` 等持有定时器的模块补 `stop()`，使 `loader.stopAll()` 可用于 T3x 烧录模式/关机前的整体停机。
4. **幽灵模块**：`MODULE_FLAGS.mobile_info` 指向的 `lib/mobile_info.lua` 已删除（flag=false + loader 负缓存兜底）；如确认不再恢复，可删除相关 flag 与 `app.lua` 引用。
