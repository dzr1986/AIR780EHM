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

**打包注意**：Luatools 只打包从 main.lua 静态 `require` 可达的文件；仅经 `loader.load/opt` 动态加载的模块会被漏掉。main.lua 中的 `__LUATOOLS_SCAN_ANCHOR__` 死代码块列出全部动态模块作为扫描锚点（运行时永不执行）。**新增动态加载模块时必须同步加入该锚点块**。

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

## 8. 功能逻辑梳理（2026-08 第二轮）

### 8.1 已实施的等价优化（user/app.lua）

| 项 | 问题 | 处理 |
|----|------|------|
| USB 状态单一数据源 | `state.flag_usb`/`state.last_usb_state` 与 `_G.APP_RUNTIME.power_status` 三处维护同一状态，前两者只写不读 | 删除两个冗余字段；`getState().flag_usb` 改由 `power_status` 推导 |
| 死状态字段 | `state.last_input` 从未写入；`state.last_uart_rx` 只写不读（还常驻引用最近一帧 UART 数据，浪费 RAM） | 删除 |
| PMD 消息双发事件 | `handlePmdMessage` 先写 `power_status` + 发 `GPIO_VBUS_CHANGED`，再调 `applyUsbInsertState` 又做一遍（同一次插拔广播两次） | 插拔态（state 0/1）只走 `applyUsbInsertState` 单入口；其余状态仅同步充电位 |
| `isUsbInserted` 回退链 | `usbCharge` 分支出现两次（boot 与非 boot 各一），且 runtime_power 层内部同样先查 usb_charge，链路绕圈 | 收敛为：boot+无charge→GPIO VBUS；usbCharge → runtime_power（兜底）→ `power_status` |
| T3x 唤醒链重复门禁 | `MODULE_FLAGS.t3x_policy` 在 app `requestT3xWake`/`onMqttOffline` 与 `t3x_policy.policyDisabled()` 共 3 处判断 | app 侧删除重复判断；flag 关闭时 `policyDisabled()` 使 `mayPowerT3x` 放行、仍走 `t3x_notify.wakeHost`，行为等价 |
| setupUartBridge 空分支 | `local uc = _G.UART_CFG if ... then else end` 空 if/else（日志剥离残留） | 删除 |

### 8.2 核实后不成立 / 暂不处理的项

| 项 | 结论 |
|----|------|
| battery_guard `onUsbInserted` 双调用 `on_exit_low_power` | **不成立**：`exitedRest` 已守卫单次调用，`wasPir` 走 `resumePir()` 不触发 hook |
| 录像停止双路径竞态（`scheduleStopMqttFallback`） | **无实际竞态**：`markStopMqttPublished` 在 `publishPirRecordStop` 内同步置位（协程无抢占），fallback 侧 `canPublishStopMqtt` 双重防护有效 |
| PIR 事件 `PIR_WAKE_T3X` 与 `GPIO_PIR_TRIGGERED` 合并 | **暂不做**：两者语义不同（唤醒 vs MQTT 上报）、发布时机与条件不同（retrigger 只发 GPIO 事件），合并属行为变更 |
| net_mqtt `publishPir*` 构包去重 | **暂不做**：协议热路径字符串改写回归风险大于收益（~40 行） |
| `enterRestIfNeededAfterUsbRemove` 两分支行为不对等 | **保留**：battery_guard 启用时按电量策略评估、禁用时无条件进 rest 是设计意图（见 [WORK_MODE_BATTERY_20PCT.md](WORK_MODE_BATTERY_20PCT.md)） |

### 8.3 后续渐进迁移建议

1. **裸 `pcall(require)` 收敛**：~~全项目仍有约 60 处~~（第三、四轮已全部收敛，全项目 0 残留，见 §9）。
2. **配置 merge 收敛**：`watchdog.mergeConfig`、`pir_ctrl` 等模块的手工 merge 可逐步换 `cfgman.merge`。
3. **stop() 补齐**：`vbat`、`time_sync`、`led_ctrl` 等持有定时器的模块补 `stop()`，使 `loader.stopAll()` 可用于 T3x 烧录模式/关机前的整体停机。
4. **幽灵模块**：~~`MODULE_FLAGS.mobile_info`~~（第四轮已删除 flag 及 app.lua/cellular_bootstrap 引用）。

## 9. 第三轮优化（lazy-require 迁移与响应串收敛）

### 9.1 pcall(require) → loader.load 迁移（47 处）

| 文件 | 迁移点数 | 说明 |
| --- | --- | --- |
| user/host_uart.lua | 33 | 全部惰性加载点统一走 loader（含 usbChargeCache 等缓存守卫简化） |
| user/net_mqtt.lua | 7 | getDeviceId/getCellular/collectSimSnapshot/usbBlocks4gRest 等 |
| user/time_sync.lua | 3 | getUart/t3xOn/pushBeforeNotify |
| lib/t3x_notify.lua | 4 | notifyViaTimeSync/notifyViaHostUart/fallbackGpioWake/ensurePowered |
| 第四轮：app/battery_guard/sound_prompt/t3x_ctrl/ipc_supervision/led_ctrl/main + lib host_event/usb_charge/low_power_wakeup/usb_rndis/runtime_power | 16 | 至此全项目 pcall(require) 0 残留；另删除 mobile_info 幽灵 flag 与引用 |

等价性要点：`loader.load` 内部即 pcall + 单一缓存 + `type=="table"` 校验，故原 `ok and type(mod)=="table" and mod or false` 一律简化为 `mod or false`；失败路径（模块缺失）行为不变（负缓存返回 nil）。

### 9.2 host_uart 响应串收敛

- 13 处硬编码 `CRLF.."+TAG:OK/ERROR"..CRLF` 改为 `rsp_line(tag, ok)`；`USBRESET:OK`（带 ok_tail）改为 `rsp_body("USBRESET","OK")`。
- 删除 `RSP_SETCFG_OK/ERR` 顶部常量，SETCFG 6 处使用点统一 `rsp_line("SETCFG", ...)`。
- 第五轮：新增 `rsp_only(tag, body)`（无 ok_tail 裸响应）；31 处 `string.format(CRLF.."+TAG:..."..CRLF,...)..ok_tail()` 与常量响应机械替换为 `rsp_fmt/rsp_only/rsp_body`；`rsp_body/rsp_line` 内部复用 `rsp_only`。net_mqtt：publishVersion/publishPirRecordStop 复用 `msgIdPart`，删除 2003 空分支与冗余 opts 赋值。
- 输出字节完全一致，仅代码收敛。

### 9.3 核实后不处理的项

| 分析建议 | 结论 |
| --- | --- |
| escJson 重复实现（net_mqtt / ipc_supervision） | **已统一**：ipc_supervision 通过 `_deps.esc_json` 注入委托 net_mqtt 实现，本地版本仅为注入前兜底，无需改动 |
| net_mqtt `netReadyPublished/bootstrapStarted` 为死标志 | **不成立**：分别在 bootstrap 流程中写入，用于去重 |
| host_uart `pulseUsbDebugEn` 定时器泄漏 | **不成立**：调用幂等，无泄漏 |
| watchdog `mergeConfig` 换 cfgman.merge | **暂不做**：含字段别名映射（timeout→timeout_ms），cfgman.merge 不支持，改造收益为负 |

### 9.4 第六轮：luacheck 死代码清理（12 个文件，−66/+41 行）

用 `luacheck`（W211/W231/W311/W542）全量扫描后逐项人工核实，清理三类死代码，全部为等价改动：

1. **未使用的局部函数/变量**：`fota_svc.defaultFirmwareName/defaultDeviceQuery/lastRequestTime`、`net_mqtt.getSubTopic`、`t3x_ctrl.gpioLv`、`ipc_supervision` 的 `L` 常量、`sound_prompt.t3xModule`（写入后从未读取）、`time_sync` 的 `host_uart` 声明等。
2. **空 if/else 分支**（多为日志剥离残留）：net_mqtt 7 处、host_uart 3 处、app 3 处、peripheral 1 处；有副作用的条件调用（如 `startMqtt()`、`recordCtrlStop`、`ensurePins()`）均保留调用只删弃值捕获。
3. **弃值的多返回捕获**：`local ok, err = pcall(...)` 等收敛为 `pcall(...)` 或 `local ok = ...`；`usb_rndis` 删除纯 getter `readCellularIp()` 的无效调用。

核实后保留：`libfota2.lua`（上游库，保持与官方一致）；`app.lua` 的 `modemHibernate` 仅去掉冗余初始化（if/else 全路径赋值）。清理后 luacheck 目标告警清零，32 个文件 `luac5.3 -p` 全通过。
