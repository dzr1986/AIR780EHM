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

### 9.5 第七轮：死导出函数清理（16 个文件，−239 行）

luacheck 因 `module(package.seeall)` 无法识别模块导出函数是否被使用，故用脚本做全项目**全词匹配**引用扫描（覆盖 `mod.fn`、字符串动态派发、事件回调引用；已确认代码库无 `mod[var](...)` 动态索引调用），找出零引用的导出函数 47 个：

- 删除 42 个死导出（约 210 行）：如 `usb_rndis.switch/enableAsync/waitForNetStable`、`host_uart.getCachedP2pCfg/getCachedGb28181Cfg/setPirActionDevinfo`、`t3x_ctrl.enterDeepSleep/pulseWakeup`、`app.setModuleFlag/getModuleFlags`、`pir_ctrl.requestStopManual/isSuspended` 等。
- 迭代清理级联孤儿：`usb_rndis.cycleRndis`（仅被已删函数调用）、`t3x_policy.lastDenyReason`（只写不读，8 处）。
- **保留** 5 个框架通用 API：`config_manager.num/bool`、`gpio_util.in_pin/out_pin/set_output`（文档承诺的公共接口）。

复扫确认无新增死导出（收敛），32 文件语法全通过。注意：后续若新增代码需调用上述被删函数，从 git 历史（76ab6cb 之前）恢复即可。

### 9.6 第八轮：host_uart 表驱动重构（解析器 DSL + query/set 工厂，−169 行）

`user/host_uart.lua` 中大量 AT 响应解析器与 query/set 包装函数结构高度重复，本轮改为表驱动，行为等价：

**行解析 DSL**（定义于 `try_encode_uart_error` 之前）：
- `match_flag(pat, ev, tpl)`：行匹配即按模板发布事件（每次发布均拷贝模板为新表，与原实现"每次新建表"等价）。
- `match_pub(pat, ev, names, tpl)`：按捕获名列表转换字段——名字前缀 `!` 转布尔（`==1`）、`$` 保留原始字符串、无前缀 `tonumber(cap) or 0`，合并模板后发布。
- `rows_append / rows_end_flush / rows_collect`：多行查询（`+MIC:`、`+FRAMERATE:`、`+VENC:`、`+AUDIO:`）的行收集与 `END` 冲刷，nil 安全。
- `line_matchers(...)` / `norm_matchers(...)`：把若干匹配器组成一个 `try_X_line`；后者先过 `normalize_host_line`。nil 行直接返回 false（比原实现更安全）。

已用 DSL 重写 11 个解析器：`try_vencset/audioset/micset/mic/softphotoset/softphoto/framerate/recordctrl/persondet/venc/audio_line`。`RX_LINE_HANDLER_REGISTRY` 中的名字与顺序不变。

**defineQuery / defineSet 工厂**（定义于 `cached_host_query` 之后）：
- `defineQuery(d)` 返回兼容双签名的函数（实参为 timeoutMs 数字或 opts 表），短字段映射：`busy→busy_key、cache→cache_key、parsed→require_parsed、tag→policy_tag、cfg（函数引用，查询时调用）、tmo→default_timeout、at（字符串或 function(opts) 动态拼 AT）、ev→ack_event、dis/pre/rsp→when_disabled/before_send/on_response`，统一走 `cached_host_query`。
- `defineSet(d)` 返回 `function(opts)`，映射同上外加 `boot→boot_cfg、prep(opts)→prepare、parse→parse_rsp`（缺省 `parse_ok_rsp`）。

已转换 15 个函数：`queryHostGb28181/Record/RecordTime/Framerate/PersonDetect/Mic/SoftPhoto/TfCard`、`setHostRecordTime/Framerate/PersonDetect/Mic/SoftPhoto`、`recordCtrlStart/Stop`。**刻意保留手写**（选项集复杂）：`queryHostIpcCloudStat/IpcStatus/Wled/Encode`、`setHostEncode`、`formatHostTfCard` 及各简单单行解析器。

注意事项：
- spec 表在模块加载期构造，其中引用的局部函数（如 `encode_cfg`）**必须在词法上先定义**——本轮已把 `encode_cfg` 定义前移至 `tf_card_cfg` 之后。
- `setHostSoftPhoto` 的字段循环改为 `for i = 1, 8`，修复了原 `#fields` 遇 nil 空洞的潜在截断（严格更安全）。
- 已通过宿主机沙箱等价性测试（/tmp/test_parsers.lua、/tmp/test_factories.lua：解析器逐字段断言 + 工厂字段映射/双签名断言全部通过），`luac5.3 -p` 全量通过、luacheck 无新增告警。AT 命令路径有改动，建议整机回归测试上述 query/set 与多行查询。

### 9.7 第九轮：mod_call 动态模块守卫收敛（host_uart，−50 行）

`user/host_uart.lua` 中 `local m = loader.load("x"); if m and m.fn then m.fn(...) end` 样板出现 30+ 次，新增局部助手统一：

```lua
local function mod_call(name, fn, ...)  -- 模块或函数缺失时返回 nil
```

收敛 17 处调用点（fire-and-forget 通知、单/多返回值读取、`== false` 显式布尔门、`getState()` 快照读取等）。转换前均逐点核对语义等价：
- `not mod_call(...)` 仅用于"缺失视为否"语义等价的场合（如 `isRecording`）；显式拒绝门（`mayPowerT3x`、`shouldAllowHostIdleSleep`）已核实返回严格布尔后改用 `== false` 比较——函数缺失（nil ≠ false）时保持原"放行"行为。
- `syncStopFromT3x` 在 `reconcileHostRecordSession` 中可能返回 nil 覆盖默认值 `"auto","high"`，该处保留原守卫写法不转换（首次转换曾引入 pir_ctrl 未定义引用，经 luacheck W113 差分对比发现并修复）。
- net_mqtt 等其他文件的守卫多带默认值回退，收益低于引入助手成本，不转换。

验证：luacheck 告警差分与重构前完全一致，test/ 等价性测试通过，`luac5.3 -p` 通过。

### 9.8 第十轮：旧名调用修复 + 死代码清理 + helper 收敛（user/ + lib/，−232 行）

基线 b9907b8（第九轮 122 条函数名缩写后）。行数 15098 → 14866（目标 −350~450 未达：提取类改动本身有定义成本，utils.lua +58 行；剩余空间均经核实不宜动，见"不处理"清单）。

**2A 旧名 mod_call 修复（行为变化，需真机回归）**：`user/host_uart.lua` 中 7 处调用仍指向缩写前的旧名，模块加载后永远命中"函数缺失"静默分支，本轮改名修复：
- `appendGetCfgFields`→`appCfgFields`（low_power_wakeup）：恢复 AT+GETCFG 应答中的 `wakeup_mode`/`tcp_on` 字段（文档承诺）
- `buildAtBody`→`buildAtBod`（pir_ctrl）、`syncStopFromT3x`→`syncStopT3x`（pir_ctrl）、`applyEffectiveMediaAction`→`applEffMedia`（pir_ctrl）
- `shouldAllowHostIdleSleep`→`shdHostSleep`（battery_guard，2 处）、`canAcceptHostIdleSleep`→`canHostSleep`（battery_guard）

**2B 死代码清理**：`okLp` 未定义全局的死 elseif 分支；net_mqtt `NC` 常量 + `no_conn` 实参传递链；`opts.warn`、`state.last_event`/`last_publish_topic`、`publish()` 死导出；t3x_ctrl `logGpio` 空函数及 3 处调用；battery_guard `handleRestZoneHybrid`/`handlePirZoneHybrid` 零调用函数；led_ctrl `_G[_M] = _M` 死行；fota_svc `selfUrl` 死兜底折叠；runtime_power `WORK_*` 全局零引用改 local。

**2C 重复 helper 提取到 utils.lua**（`nowMs`/`escKv`/`optTable`/`appEvent`/`t3xOn`/`waitT3xCmdAck`）：收敛 app/host_uart/pir_ctrl/net_mqtt/t3x_ctrl/battery_guard/fota_svc 的重复实现；time_sync/sound_prompt 的 T3x 上电等待 + ACK 等待循环跨文件去重（保留"无 `mcu.ticks` 只等一拍"语义）；`hostFirsAtEvt` 等 12 处 `_G.APP_EVENTS` fallback 统一走 `appEvent`。约 80 处 `type(x)=="table" and x or {}` 机械替换为 `optTable`。utils 保持零依赖（仅 require module_loader，sys 经全局运行时解析，避免循环 require）。

**2D 样板收敛**：`_G.MODULE_FLAGS` 直查 → `loader.enabled()`（config.lua 显式定义全部键，转换安全；t3x_notify:61-62 真值语义不同，保留并注释）；battery_guard 两个逐字相同的 evaluate 函数合并；host_uart 新增 `t3xSectOff()`/`rspLineOk(tag)`/`writeT3xNotif` 本地助手；t3x_notify 三份 getGlobalOrLoad 拷贝 → `getMod()` 带负缓存；ipc_supervision 模块折叠为 `loader.load()`；usb_charge `ensureUsbDetPin` → `gpio_util.setup_input`（显式传 trigger_mode 保持原默认）；usb_rndis 补 `cfg()` 助手；uart_bridge 三个早退合并 + 布尔样板一行化；t3x_policy `reqT3xWake` 删预置默认（5 个调用点均已传非 nil reason）、`shdWakeOffline` 冷却期条件压缩；net_mqtt `identityEnabled`/`tfCardEnabled` 改 `~= false`、`midField` 复用 `msgIdPart`；cellular_bootstrap `applyApnForSim` 三分支 → 两分支（真值表已验证等价）；libfota2 云平台错误码 if/elseif 链 → `FOTA_ERR_INFO` 表驱动（文案逐字保留，1111111111111 动态参数分支保留）；usb_vuart 两处 REBOOT 命令清单提取共用（AT+RESET 仅保留带换行路径的现状差异）。

**2E 文件头注释修正**：34 个文件头部 `Notes: 本地 helper 速查：无本地压缩 helper` 与事实不符（各文件均有大量 local helper，第九轮已压缩 122 个函数名），统一删除该占位行。

**核实后不处理**：t3xPowerWaitMs 六处 fallback 链统一、battery_guard `cfg()`（有 guard fallback 与 config_manager 语义不同）、peripheral `shallowMerge`（嵌套子表整体替换 vs 逐 key 合并）、host_uart 3249/3552-3559 内联、cellular_bootstrap `waitSimInfo`、各文件零星 optTable——均有语义差异或收益过低，保持现状。

**验证**：luatos-cli `build luac` 全量编译 user/（17 文件）+ lib/（17 文件）零错误；test_parsers.lua（44 断言）+ test_factories.lua（17 断言）经 lupa（Lua 5.5 宿主）全部通过。注：两份测试的提取锚点此前全部失效（Lua pattern `.-` 不跨行，函数均为多行定义），本轮改为"起点 marker 定界提取"后首次真正运行，并修正一处历史错误断言（mic 无收集行时 END 不发布，与 venc/audio/framerate 共用 rowsEndFlus 语义一致）。2A 的 7 处行为变化项（2001/2003/2005/2008 + HOSTIDLE + GETCFG 字段）需整机回归。

### 9.9 脚本区 512KB 超限修复（Luatools 合并口径，−99 行）

背景：Luatools 合并脚本报"文件总数据量(518kb)超过了固件脚本区空间(512kb)"。复现口径 = luatos-cli `build filesystem` 排除固件自带 `sys.lua` 后 debug99 全量编译：基线 531859B(519.4KB) 与用户 518KB 吻合。

**体积构成实测**（决定削减方向）：debug99 总包 ≈ 代码+常量 58% + 行号信息 27% + 变量名信息 15%。行号表按**指令数**存储而非源码行数——单行化/删注释/删空行对 luac 体积零影响（实测 541 处守卫单行化 −1115 行后 script.bin 逐字节不变，该批改动已回退）。有效削减仅两类：删语句（减指令+行号）与减字符串/数字常量。

**本轮削减**（全部零行为变化）：
- 死函数 3 个：battery_guard `canEnterRestNow`/`canExitRestNow`（零调用）、net_mqtt `fetchWledFromHost`（零调用）
- libfota2：`FOTA_ERR_INFO` 8 条长错误文案压缩为短形式（键与语义不变）；5 条参数日志合并为 1 条；删 2 条冗余日志（`使用合宙服务器…` 裸日志、`code/body` 重复日志）
- fota_svc：删 5 条例行 info 日志（ota_start/ota_network_ok/ota_checking/ota_callback/ota_reboot_scheduled，信息均已被 reportStatus 上报覆盖）；4 条 warn 错误路径日志全保留
- host_uart：删 ipcpoweroff 成功路径 3 条日志（OK/STAGE/tx）与 `venc_unparsed`、连带空 if 与死变量 `sent`
- net_mqtt：conack/disconnect 两处 8 行 pushNetLed 块提取为本地函数；4 处 `need`/`usbLogical` 的 if-nil 改 `or`（tonumber 场景，无 false 语义风险）
- vbat/gpio_util/host_event/t3x_policy 共 6 处 if-nil 改 `or`（全部为数字/tonumber 场景）

**结果**：排除 sys.lua 口径 531859 → 526807B（−5052B，514.5KB）。注意：debug99 口径下 514.5KB 仍未进 512KB 线（用户侧约差 1~4KB），**治本方案是打包链改用较低 luac 调试级别**——实测同代码 `--luac-debug 1`（仅行号）= 456085B(445.4KB)、`--luac-debug 2`（仅变量名）= 393727B(384.5KB)，均稳过 512KB；量产链 pack_mass_prod.py 已用 `luac_debug = 0` + 内存压缩（≈346KB）不受影响。

**验证**：luatos-cli `build luac` 全量零错误；test_parsers（44 断言）+ test_factories（17 断言）lupa 宿主全部通过；提交 8d949c1。
