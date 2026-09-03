# Cat.1 user/lib 模块框架（module_loader / config_manager）

> 本文描述 2026-08 框架整合后的模块加载、配置访问、生命周期与事件约定。  
> 相关文档：[CALL_GRAPH.md](CALL_GRAPH.md)（启动顺序）、[LUA_MODULES.md](LUA_MODULES.md)（模块职责）、[CAT1_USER_LIB_SLIM.md](../power/CAT1_USER_LIB_SLIM.md)（瘦身速查）。

---

## 1. 背景与目标

整合前存在多套并行实现：

| 问题 | 整合前 | 整合后 |
|------|--------|--------|
| 条件加载 | `app.lua` 私有 `optMod()`（16 行） | `module_loader.opt(flag, name)` |
| 懒加载 | `utils.lazyRequire()` 私有缓存 + 全项目 60+ 处裸 `pcall(require)` | `module_loader.load(name)` 单一缓存 |
| 配置合并 | 各模块手写 `cfg()` + for 循环 merge（如 `led_ctrl.lua`） | `config_manager.merge/get/num/bool` |
| 日志 | `utils.mkLogFns(tag)` 与死变量 `LOG_TAG` 并存 | 统一 `mkLogFns`；删除 8 处死 `LOG_TAG` |
| 事件 topic | `"BATTERY_UPDATE"` 等散落硬编码 | 收编进 `APP_EVENTS` |

**体积约束**：脚本区约 512KB（见 [CAT1_SLIMMING_FLOW.md](../power/CAT1_SLIMMING_FLOW.md)）。两个框架文件合计约 130 行源码，同时删除了等量重复代码，净体积基本持平。

---

## 2. lib/module_loader.lua — 模块加载框架

单一 require 缓存 + `MODULE_FLAGS` 检查 + 生命周期登记。

### 2.1 API

| 函数 | 说明 |
|------|------|
| `load(name)` | 安全 require（`pcall` + 缓存）。失败或返回非 table 时得 `nil`，**负结果也缓存**，不重复尝试 |
| `enabled(flag)` | 读 `_G.MODULE_FLAGS[flag]`；`false` 为关，`nil`/其余为开 |
| `opt(flag, name)` | `enabled(flag)` 为假返回 `nil`，否则 `load(name or flag)`（等价原 `optMod`） |
| `start(mod, fn, opts)` | 安全调用生命周期方法（默认 `"start"`）；`mod` 可为模块表或模块名。成功 start 的模块登记，供 `stopAll()` 逆序停止 |
| `stopAll()` | **逆序**停止已登记模块（模块有 `stop()` 才调用），随后清空登记表；可安全重复调用 |

> **登记机制**：`start()` 仅在成功（pcall 通过且返回非 `false`）时把模块加入 `started` 登记表。`stopAll()` 从表尾向前调用每个模块的 `stop()`（无 `stop()` 则跳过），最后清空登记表。若某模块的 `stop()` 抛错会被 `pcall` 吞掉，不影响其余模块。**注意**：仅经 `loader.start()` 启动的模块才会被登记并逆序停止。

### 2.2 用法

```lua
local loader = require "module_loader"

-- 按 MODULE_FLAGS 条件加载（关闭时得 nil）
local fota = loader.opt("fota", "fota_svc")

-- 懒加载（不存在/失败时得 nil，且不再重试）
local policy = loader.load("t31x_policy")

-- 安全启动可选服务
loader.start(batAdc, "start")
loader.start(time_sync, "startSntp")
```

### 2.3 接入点

| 文件 | 改动 |
|------|------|
| [user/app.lua](../../user/app.lua) | 删除 `optMod()`；8 个可选模块改 `loader.opt`；`lazyMod`/`startOptionalService` 委托 loader |
| [user/main.lua](../../user/main.lua) | `cellular_bootstrap`、`usb_rndis` 改 `loader.load` |
| [lib/utils.lua](../../lib/utils.lua) | `lazyRequire` 委托 `loader.load`（消除双缓存），旧调用方无需改动 |

**打包注意**：Luatools 只打包从 main.lua 静态 `require` 可达的文件；仅经 `loader.load/opt` 动态加载的模块会被漏掉。main.lua 中的 `__LUATOOLS_SCAN_ANCHOR__` 死代码块列出全部动态模块作为扫描锚点（运行时永不执行）。**新增动态加载模块时必须同步加入该锚点块**。

---

## 3. lib/config_manager.lua — 配置访问框架

替代各模块散落的 `cfg()` + 手工默认值合并。

### 3.1 API

| 函数 | 说明 |
|------|------|
| `get(name)` | 取全局配置表（如 `"LED_CFG"`）；不存在返回 `{}`。**不缓存**，支持运行时覆盖 |
| `num(t, key, default)` | 数值配置；`t` 可为表或全局配置名（如 `"LED_CFG"`）；缺失/非数值用 default |
| `bool(t, key, default)` | 布尔配置；`t` 可为表或全局配置名；`nil` 用默认值；`false/0/"0"` 为 false |
| `event(name, fallback)` | 取 `_G.APP_EVENTS[name]`；不存在返回 fallback（lib 层读事件名用，免反向 require user/utils） |
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
  ├─ app.start(peripheral, net_mqtt, t31x_ctrl)
  │    ├─ setupEventHandlers()   订阅 APP_EVENTS
  │    ├─ battery_guard.start / setupWatchdog / setupUartBridge
  │    ├─ t31x_ctrl.start / sound_prompt.start / time_sync.start
  │    ├─ setupGpio / startBackgroundServices（vbat/usb_charge/sntp）
  │    └─ bootMqtt / setupFota / startHeartbeat
  └─ sys.run()
```

模块约定：

- **必须**：`start(opts)` — 幂等（重复调用返回 false 或忽略）；opts 为单个 table。
- **可选**：`stop()` — 持有定时器/连接/订阅/后台任务的模块应实现；`loader.stopAll()` 会逆序调用已登记模块。
- **可选**：`getState()` — 返回快照 table，供 AT/MQTT 查询。

**已实现 `stop()` 的模块**：`net_mqtt`、`host_uart`、`uart_bridge`、`watchdog`、`usb_rndis`、`vbat`、`time_sync`、`led_ctrl`、`battery_guard`、`peripheral`、`pir_ctrl`、`fota_svc`。

---

## 5. 日志约定

统一使用 `utils.mkLogFns(tag)`：

```lua
local logFuncs = utils.mkLogFns("my_mod")
local info, warn, err = logFuncs.info, logFuncs.warn, logFuncs.error
```

- 已采用：app、battery_guard、net_mqtt、pir_ctrl、t31x_ctrl、time_sync。
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
| [lib/module_loader.lua](../../lib/module_loader.lua) | 新增 | 模块加载框架（~65 行） |
| [lib/config_manager.lua](../../lib/config_manager.lua) | 新增 | 配置访问框架（~65 行） |
| [user/app.lua](../../user/app.lua) | 改造 | 删 `optMod`；`loader.opt/load/start` 接管；`E.BATTERY_UPDATE` |
| [user/main.lua](../../user/main.lua) | 改造 | cellular/rndis 加载走 loader |
| [lib/utils.lua](../../lib/utils.lua) | 改造 | `lazyRequire` 委托 loader（API 不变） |
| [lib/led_ctrl.lua](../../lib/led_ctrl.lua) | 改造 | `applyConfigs` 用 `cfgman.merge`；`E.BATTERY_UPDATE` |
| [user/config.lua](../../user/config.lua) | 改造 | `APP_EVENTS.BATTERY_UPDATE` 收编 |
| [user/net_mqtt.lua](../../user/net_mqtt.lua) / [user/vbat.lua](../../user/vbat.lua) | 改造 | BATTERY_UPDATE 改用 `APP_EVENTS` |
| peripheral / sound_prompt / vbat / 5 个 lib 模块 | 清理 | 删死 `LOG_TAG` |

验证：全部改动文件过 `luac5.3 -p` 语法检查；`module_loader`/`config_manager` 通过单元测试（load 缓存/负缓存、opt 开关、start/stopAll 逆序、num/bool/merge/白名单）。

---

## 8. 功能逻辑梳理（2026-08 第二轮）

### 8.1 已实施的等价优化（user/app.lua）

| 项 | 问题 | 处理 |
|----|------|------|
| USB 状态单一数据源 | `state.flag_usb`/`state.last_usb_state` 与 `_G.APP_RUNTIME.power_status` 三处维护同一状态，前两者只写不读 | 删除两个冗余字段；`getState().flag_usb` 改由 `power_status` 推导 |
| 死状态字段 | `state.last_input` 从未写入；`state.last_uart_rx` 只写不读（还常驻引用最近一帧 UART 数据，浪费 RAM） | 删除 |
| PMD 消息双发事件 | `handlePmdMessage` 先写 `power_status` + 发 `GPIO_VBUS_CHANGED`，再调 `applyUsbPower` 又做一遍（同一次插拔广播两次） | 插拔态（state 0/1）只走 `applyUsbPower` 单入口；其余状态仅同步充电位 |
| `isUsbInserted` 回退链 | `usbCharge` 分支出现两次（boot 与非 boot 各一），且 runtime_power 层内部同样先查 usb_charge，链路绕圈 | 收敛为：boot+无charge→GPIO VBUS；usbCharge → runtime_power（兜底）→ `power_status` |
| T31x 唤醒链重复门禁 | `MODULE_FLAGS.t31x_policy` 在 app `requestT31xWake`/`onMqttOffline` 与 `t31x_policy.policyDisabled()` 共 3 处判断 | app 侧删除重复判断；flag 关闭时 `policyDisabled()` 使 `mayPowerT31x` 放行、仍走 `t31x_notify.wakeHost`，行为等价 |
| setupUartBridge 空分支 | `local uc = _G.UART_CFG if ... then else end` 空 if/else（日志剥离残留） | 删除 |

### 8.2 核实后不成立 / 暂不处理的项

| 项 | 结论 |
|----|------|
| battery_guard `onUsbInserted` 双调用 `onExitLowPower` | **不成立**：`exitedRest` 已守卫单次调用，`wasPir` 走 `resumePir()` 不触发 hook |
| 录像停止双路径竞态（`scheduleStopMqttFallback`） | **无实际竞态**：`markStopMqttPublished` 在 `pubPirStop` 内同步置位（协程无抢占），fallback 侧 `canPublishStopMqtt` 双重防护有效 |
| PIR 事件 `PIR_WAKE_T31X` 与 `GPIO_PIR_TRIGGERED` 合并 | **暂不做**：两者语义不同（唤醒 vs MQTT 上报）、发布时机与条件不同（retrigger 只发 GPIO 事件），合并属行为变更 |
| net_mqtt `publishPir*` 构包去重 | **暂不做**：协议热路径字符串改写回归风险大于收益（~40 行） |
| `enterRestIfNeededAfterUsbRemove` 两分支行为不对等 | **保留**：battery_guard 启用时按电量策略评估、禁用时无条件进 rest 是设计意图（见 [WORK_MODE_BATTERY_20PCT.md](../_audit/WORK_MODE_BATTERY_20PCT.md)） |

### 8.3 后续渐进迁移建议

1. **裸 `pcall(require)` 收敛**：~~全项目仍有约 60 处~~（第三、四轮已全部收敛，全项目 0 残留，见 §9）。
2. **配置 merge 收敛**：`watchdog.mergeConfig`、`pir_ctrl` 等模块的手工 merge 可逐步换 `cfgman.merge`。
3. **stop() 补齐**：~~`vbat`、`time_sync`、`led_ctrl` 等持有定时器的模块补 `stop()`~~（第 ? 轮已补 vbat/time_sync/led_ctrl/battery_guard/peripheral/pir_ctrl/fota_svc，`loader.stopAll()` 已可用于整体停机）。
4. **幽灵模块**：~~`MODULE_FLAGS.mobile_info`~~（第四轮已删除 flag 及 app.lua/cellular_bootstrap 引用）。

## 9. 第三轮优化（lazy-require 迁移与响应串收敛）

### 9.1 pcall(require) → loader.load 迁移（47 处）

| 文件 | 迁移点数 | 说明 |
| --- | --- | --- |
| user/host_uart.lua | 33 | 全部惰性加载点统一走 loader（含 usbChargeCache 等缓存守卫简化） |
| user/net_mqtt.lua | 7 | getDeviceId/getCellular/snapSim/usbBlocks4gRest 等 |
| user/time_sync.lua | 3 | getUart/t31xOn/pushBeforeNotify |
| lib/t31x_notify.lua | 4 | notifyViaTimeSync/notifyViaHostUart/fallbackGpioWake/ensurePowered |
| 第四轮：app/battery_guard/sound_prompt/t31x_ctrl/ipc_supervision/led_ctrl/main + lib host_event/usb_charge/low_power_wakeup/usb_rndis/runtime_power | 16 | 至此全项目 pcall(require) 0 残留；另删除 mobile_info 幽灵 flag 与引用 |

等价性要点：`loader.load` 内部即 pcall + 单一缓存 + `type=="table"` 校验，故原 `ok and type(mod)=="table" and mod or false` 一律简化为 `mod or false`；失败路径（模块缺失）行为不变（负缓存返回 nil）。

### 9.2 host_uart 响应串收敛

- 13 处硬编码 `CRLF.."+TAG:OK/ERROR"..CRLF` 改为 `rsp_line(tag, ok)`；`USBRESET:OK`（带 ok_tail）改为 `rsp_body("USBRESET","OK")`。
- 删除 `RSP_SETCFG_OK/ERR` 顶部常量，SETCFG 6 处使用点统一 `rsp_line("SETCFG", ...)`。
- 第五轮：新增 `rsp_only(tag, body)`（无 ok_tail 裸响应）；31 处 `string.format(CRLF.."+TAG:..."..CRLF,...)..ok_tail()` 与常量响应机械替换为 `rsp_fmt/rsp_only/rsp_body`；`rsp_body/rsp_line` 内部复用 `rsp_only`。net_mqtt：pubVersion/pubPirStop 复用 `msgIdPart`，删除 2003 空分支与冗余 opts 赋值。
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

1. **未使用的局部函数/变量**：`fota_svc.defaultFirmwareName/defaultDeviceQuery/lastRequestTime`、`net_mqtt.getSubTopic`、`t31x_ctrl.gpioLv`、`ipc_supervision` 的 `L` 常量、`sound_prompt.t31xModule`（写入后从未读取）、`time_sync` 的 `host_uart` 声明等。
2. **空 if/else 分支**（多为日志剥离残留）：net_mqtt 7 处、host_uart 3 处、app 3 处、peripheral 1 处；有副作用的条件调用（如 `startMqtt()`、`recordCtrlStop`、`ensurePins()`）均保留调用只删弃值捕获。
3. **弃值的多返回捕获**：`local ok, err = pcall(...)` 等收敛为 `pcall(...)` 或 `local ok = ...`；`usb_rndis` 删除纯 getter `readCellularIp()` 的无效调用。

核实后保留：`libfota2.lua`（上游库，保持与官方一致）；`app.lua` 的 `modemHibernate` 仅去掉冗余初始化（if/else 全路径赋值）。清理后 luacheck 目标告警清零，32 个文件 `luac5.3 -p` 全通过。

### 9.5 第七轮：死导出函数清理（16 个文件，−239 行）

luacheck 因 `module(package.seeall)` 无法识别模块导出函数是否被使用，故用脚本做全项目**全词匹配**引用扫描（覆盖 `mod.fn`、字符串动态派发、事件回调引用；已确认代码库无 `mod[var](..)` 动态索引调用），找出零引用的导出函数 47 个：

- 删除 42 个死导出（约 210 行）：如 `usb_rndis.switch/enableAsync/waitForNetStable`、`host_uart.getCachedP2pCfg/getCachedGb28181Cfg/setPirActionDevinfo`、`t31x_ctrl.enterDeepSleep/pulseWakeup`、`app.setModuleFlag/getModuleFlags`、`pir_ctrl.requestStopManual/isSuspended` 等。
- 迭代清理级联孤儿：`usb_rndis.cycleRndis`（仅被已删函数调用）、`t31x_policy.lastDenyReason`（只写不读，8 处）。
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
- `defineQuery(d)` 返回兼容双签名的函数（实参为 timeoutMs 数字或 opts 表），短字段映射：`busy→busyKey、cache→cacheKey、parsed→requireParsed、tag→policyTag、cfg（函数引用，查询时调用）、tmo→defaultTimeout、at（字符串或 function(opts) 动态拼 AT）、ev→ackEvent、dis/pre/rsp→whenDisabled/beforeSend/onResponse`，统一走 `cachedHostQry`。
- `defineSet(d)` 返回 `function(opts)`，映射同上外加 `boot→boot_cfg、prep(opts)→prepare、parse→parse_rsp`（缺省 `parse_ok_rsp`）。

已转换 15 个函数：`queryHostGb28181/Record/RecordTime/Framerate/PersonDetect/Mic/SoftPhoto/TfCard`、`setHostRecordTime/Framerate/PersonDetect/Mic/SoftPhoto`、`recordCtrlStart/Stop`。**刻意保留手写**（选项集复杂）：`qryIpcCloudStat/IpcStatus/Wled/Encode`、`setHostEncode`、`formatHostTfCard` 及各简单单行解析器。

注意事项：
- spec 表在模块加载期构造，其中引用的局部函数（如 `encode_cfg`）**必须在词法上先定义**——本轮已把 `encode_cfg` 定义前移至 `tf_card_cfg` 之后。
- `setHostSoftPhoto` 的字段循环改为 `for i = 1, 8`，修复了原 `#fields` 遇 nil 空洞的潜在截断（严格更安全）。
- 已通过宿主机沙箱等价性测试（/tmp/test_parsers.lua、/tmp/test_factories.lua：解析器逐字段断言 + 工厂字段映射/双签名断言全部通过），`luac5.3 -p` 全量通过、luacheck 无新增告警。AT 命令路径有改动，建议整机回归测试上述 query/set 与多行查询。

### 9.7 第九轮：modCall 动态模块守卫收敛（host_uart，−50 行）

`user/host_uart.lua` 中 `local m = loader.load("x"); if m and m.fn then m.fn(...) end` 样板出现 30+ 次，新增局部助手统一：

```lua
local function modCall(name, fn, ...)  -- 模块或函数缺失时返回 nil
```

收敛 17 处调用点（fire-and-forget 通知、单/多返回值读取、`== false` 显式布尔门、`getState()` 快照读取等）。转换前均逐点核对语义等价：
- `not modCall(...)` 仅用于"缺失视为否"语义等价的场合（如 `isRecording`）；显式拒绝门（`mayPowerT31x`、`shouldHostSleep`）已核实返回严格布尔后改用 `== false` 比较——函数缺失（nil ≠ false）时保持原"放行"行为。
- `syncStopFromT31x` 在 `reconcileHostRecordSession` 中可能返回 nil 覆盖默认值 `"auto","high"`，该处保留原守卫写法不转换（首次转换曾引入 pir_ctrl 未定义引用，经 luacheck W113 差分对比发现并修复）。
- net_mqtt 等其他文件的守卫多带默认值回退，收益低于引入助手成本，不转换。

验证：luacheck 告警差分与重构前完全一致，test/ 等价性测试通过，`luac5.3 -p` 通过。

### 9.8 第十轮：旧名调用修复 + 死代码清理 + helper 收敛（user/ + lib/，−232 行）

基线 b9907b8（第九轮 122 条函数名缩写后）。行数 15098 → 14866（目标 −350~450 未达：提取类改动本身有定义成本，utils.lua +58 行；剩余空间均经核实不宜动，见"不处理"清单）。

**2A 旧名 modCall 修复（行为变化，需真机回归）**：`user/host_uart.lua` 中 7 处调用仍指向缩写前的旧名，模块加载后永远命中"函数缺失"静默分支，本轮改名修复：
- `appendGetCfgFields`→`appCfgFields`（low_power_wakeup）：恢复 AT+GETCFG 应答中的 `wakeup_mode`/`tcp_on` 字段（文档承诺）
- `buildStatBodyy`→`buildStatBody`（pir_ctrl）、`syncStopFromT31x`→`syncStopT31x`（pir_ctrl）、`applyEffectiveMediaAction`→`applyEffMedia`（pir_ctrl）
- `shouldHostSleep`→`shouldHostSleep`（battery_guard，2 处）、`canHostSleep`→`canHostSleep`（battery_guard）

**2B 死代码清理**：`okLp` 未定义全局的死 elseif 分支；net_mqtt `NC` 常量 + `no_conn` 实参传递链；`opts.warn`、`state.last_event`/`last_publish_topic`、`publish()` 死导出；t31x_ctrl `logGpio` 空函数及 3 处调用；battery_guard `handleRestZoneHybrid`/`handlePirZoneHybrid` 零调用函数；led_ctrl `_G[_M] = _M` 死行；fota_svc `selfUrl` 死兜底折叠；runtime_power `WORK_*` 全局零引用改 local。

**2C 重复 helper 提取到 utils.lua**（`nowMs`/`escKv`/`optTable`/`appEvent`/`t31xOn`/`waitT31xCmdAck`）：收敛 app/host_uart/pir_ctrl/net_mqtt/t31x_ctrl/battery_guard/fota_svc 的重复实现；time_sync/sound_prompt 的 T31x 上电等待 + ACK 等待循环跨文件去重（保留"无 `mcu.ticks` 只等一拍"语义）；`hostFirsAtEvt` 等 12 处 `_G.APP_EVENTS` fallback 统一走 `appEvent`。约 80 处 `type(x)=="table" and x or {}` 机械替换为 `optTable`。utils 保持零依赖（仅 require module_loader，sys 经全局运行时解析，避免循环 require）。

**2D 样板收敛**：`_G.MODULE_FLAGS` 直查 → `loader.enabled()`（config.lua 显式定义全部键，转换安全；t31x_notify:61-62 真值语义不同，保留并注释）；battery_guard 两个逐字相同的 evaluate 函数合并；host_uart 新增 `t31xSectOff()`/`rspLineOk(tag)`/`writeT31xNotif` 本地助手；t31x_notify 三份 getGlobalOrLoad 拷贝 → `getMod()` 带负缓存；ipc_supervision 模块折叠为 `loader.load()`；usb_charge `ensureUsbDetPin` → `gpio_util.setupInput`（显式传 trigger_mode 保持原默认）；usb_rndis 补 `cfg()` 助手；uart_bridge 三个早退合并 + 布尔样板一行化；t31x_policy `reqT31xWake` 删预置默认（5 个调用点均已传非 nil reason）、`shdWakeOffline` 冷却期条件压缩；net_mqtt `identityEnabled`/`tfCardEnabled` 改 `~= false`、`midField` 复用 `msgIdPart`；cellular_bootstrap `applyApnForSim` 三分支 → 两分支（真值表已验证等价）；libfota2 云平台错误码 if/elseif 链 → `FOTA_ERR_INFO` 表驱动（文案逐字保留，1111111111111 动态参数分支保留）；usb_vuart 两处 REBOOT 命令清单提取共用（AT+RESET 仅保留带换行路径的现状差异）。

**2E 文件头注释修正**：34 个文件头部 `Notes: 本地 helper 速查：无本地压缩 helper` 与事实不符（各文件均有大量 local helper，第九轮已压缩 122 个函数名），统一删除该占位行。

**核实后不处理**：t31xPowerWaitMs 六处 fallback 链统一、battery_guard `cfg()`（有 guard fallback 与 config_manager 语义不同）、peripheral `shallowMerge`（嵌套子表整体替换 vs 逐 key 合并）、host_uart 3249/3552-3559 内联、cellular_bootstrap `waitSimInfo`、各文件零星 optTable——均有语义差异或收益过低，保持现状。

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
- vbat/gpio_util/host_event/t31x_policy 共 6 处 if-nil 改 `or`（全部为数字/tonumber 场景）

**结果**：排除 sys.lua 口径 531859 → 526807B（−5052B，514.5KB）。注意：debug99 口径下 514.5KB 仍未进 512KB 线（用户侧约差 1~4KB），**治本方案是打包链改用较低 luac 调试级别**——实测同代码 `--luac-debug 1`（仅行号）= 456085B(445.4KB)、`--luac-debug 2`（仅变量名）= 393727B(384.5KB)，均稳过 512KB；量产链 pack_mass_prod.py 已用 `luac_debug = 0` + 内存压缩（≈346KB）不受影响。

**验证**：luatos-cli `build luac` 全量零错误；test_parsers（44 断言）+ test_factories（17 断言）lupa 宿主全部通过；提交 8d949c1。

### 9.10 脚本区第二轮压缩：长局部变量名缩短（debug99 口径 −6560B）

背景：9.9 之后用户仍报 513kb 超限。上一轮已挖完函数级存量（死代码/日志/if-nil），本轮主攻 debug99 的**变量名调试表**——实测其占包体约 15%（≈84KB），且按**每次出现**存储（声明处、参数、嵌套闭包 upvalue 名都各存一份），缩名按出现次数线性省钱，删语句同效。

**方法**（`_temp/varname_shorten.py`，零行为变化，纯改名）：
- ≥13 字符的 local 声明名缩写至 ≤11 字符，驼峰风格与既有轮次一致（如 `run_uart_power_cycle_recovery`→`runUartPwr`、`dispatchDl2001`→`hndDwn2001`）；全大写常量、表字段、配置键不碰
- 安全约束：Lua 感知扫描（字符串/注释内不替换）；只替换裸标识符（`.`/`:` 后的字段/方法名不碰，`_M.xxx` 导出字段保持原名）；文件内出现 `{ name = ... }` 构造器键、全局定义（`function name(`/`name = function`）的名字跳过；撞名组保留最短原名、其余加区分后缀；测试文件锚点名（`norm_matchers`/`try_vencset_line` 等行解析器）进黑名单
- 实测 987 处出现被缩短，跨越 22 个文件

**结果**：526807 → 520247B（−6560B，508.1KB）→ 用户 Luatools 口径约 506KB，低于 512KB 线且留 ~5KB 余量。验证：luatos-cli 全量编译零错误；test_parsers/test_factories 全断言通过；git diff 删除行长名逐一回扫代码区确认零残留裸引用（残留项均为表字段/配置键/全大写常量/测试锚点，属预期保留）。

**后续建议**：代码侧余量约 5KB；若后续功能持续增长，治本方案仍是打包链将 `--luac-debug` 从 99 降为 1（仅行号，445.4KB）或 2（仅变量名，384.5KB），可腾出 70~130KB 永久空间。

### 9.11 脚本区第三轮压缩：单调用点函数内联（debug99 口径 −3689B）

背景：9.10 之后用户仍要求继续压缩（余量仅 ~5KB）。函数名缩短已挖尽（第二轮 987 处），本轮转向**单调用点小函数内联**——实测每处内联净省 ≈142B（`_temp/inline_exp` 对照实验：同逻辑 a.luac=564B vs 内联后 b.luac=422B）。原理：删除定义端省下函数头尾、行号表（4B/指令）与变量名调试表（按出现次数存储），调用点端只增加正文表达式，且 debug99 下函数体调试信息随定义一并消失。

**筛选**（`_temp/inline_cands.py`）：对候选名单按文件统计裸出现次数，恰好 2 次（= 定义 + 唯一调用点）且跨文件 grep 确认无外部引用的才内联。34 个候选中有 8 个因以下原因跳过：

| 跳过项 | 原因 |
|---|---|
| `notifyHostIdle`（battery_guard）、`lazyRequire`（utils） | 全局导出公共 API，内联即删接口 |
| `stpUartBrdg`（app，30+ 行）、`rdUplnFlds`（net_mqtt，16 行含嵌套函数） | 长函数展开膨胀，且 rdUplnFlds 调用点在表达式参数中间、外层已有同名 `snap` 局部变量（遮蔽风险） |
| `makeRfrs`（net_mqtt） | 闭包工厂，展开破坏构建表可读性，收益/风险比差 |
| `stpEvntRfrs`（led_ctrl） | 函数体含 `if not E then return end`，展开后 return 会作用于外层函数，语义不等价 |

**方法**（26 处，零行为变化）：
- 单表达式体直接替换调用表达式（如 `isVldP2PUid(uid)` → `type(uid) == "string" and #uid == 8 and ...`）
- 多语句体在表达式上下文（if 条件）的调用点改为前置局部变量（如 `isT31XPwrdOn()` 展开为 `local st = modCall("t31x_ctrl", "getState")` + 条件，避免 modCall 求值两次；`shldMap1011(alertCode)` 同理前置 `local e = alertLookup(alertCode)`）
- 参数名替换为调用点实参名（如 isVldGb 的参数 `pwd` → 实参 `password`）
- 字符串/注释内的名字不动

**结果**：520247 → 516558B（−3689B，504.5KB）→ 用户 Luatools 口径约 503KB，比 512KB 线余量 9KB。净 −107 行（10 个文件）。验证：luatos-cli 全量编译零错误；test_parsers/test_factories 全断言通过；残留回扫确认被内联名零残留（命中的均为子串同名函数：isVldGb28181/uartRcvryCfg/t31x_policy.isBurnActive，属预期保留）。提交 905ea56。

### 9.12 脚本区第四轮压缩：重构式内联 + lib 侧单调用点内联（debug99 口径 −1027B）

背景：9.11 之后继续。第三轮暂缓的三个候选本轮处理两个，并扩展到 lib/（inline_scan 本就覆盖 lib，但候选多为公共 API，需逐一甄别）。

**重构式内联**（net_mqtt）：
- `rdUplnFlds`（16 行嵌套函数）：调用点在 `string.format` 参数列表中间且外层已有局部变量 `snap` → 前置 `local rdSnp = cllcRdSnps()` + 嵌套 `local function sv(v)`（改名规避遮蔽），调用点展开为内层 `string.format` 表达式。cllcRdSnps() 求值时机从调用点提前到语句块开头，同函数内无中间写操作，行为等价
- `makeRfrs`（闭包工厂）：唯一调用点 `map[spec.dl] = makeRfrs(spec)` 纯表达式替换，闭包体展开到赋值处（spec 为循环局部变量，upvalue 可见性不变）

**lib 侧内联 8 处**（cellular_bootstrap 2、usb_charge 4、low_power_wakeup 1、t31x_policy 1）：均为 local 函数、单文件单调用点；`pblsUsbChng`/`pblsChgChng` 展开为 `local ev = utils.appEvent(...)` + `sys.publish(ev, ...)` 两行（无外层 `ev` 冲突）；`cfg()`/`usb_cfg()` 等配置读取内联为 `(_G.XXX or {})` 直查

**甄别后跳过**：gpio_util.trigger_mode/pull、module_loader.enabled、usb_charge.isUsbInserted 等全局导出公共 API；`isBatDynRest` 跨 3 文件引用；`stpUartBrdg`（app，40 行，函数体 `return false` 展开后会使外层 appStart 提前返回，语义不等价）；`type(x)=="table" and x or {}` 样板 12 处中 lib 5 处受"lib 不反向依赖 user"约束、config.lua 2 处在 require 链最前端不可新增依赖，剩余收益约 20B/处放弃

**结果**：516558 → 515277B（−1027B，503.2KB）→ 用户口径约 501.7KB，余量 ~10KB。净 −38 行（5 个文件）。验证：全量编译零错误；test_parsers/test_factories 全断言通过；残留回扫干净（命中的 cellInfoRfrsh/host_usb_cfg 为子串同名）。提交 db12bf7。

## 10. 架构重构轮（stop() 补齐 + lib→user 反向依赖解耦 + 事件收编）

> 本节记录四项架构性改动：生命周期 `stop()` 补齐、`lib→user` 动态反向依赖解耦、`loader.stopAll()`/`config_manager.num()/bool()` 文档-实现对齐、事件 fallback 收编。

### 10.1 框架 API 文档-实现对齐

此前文档 §2.1 声明 `loader.stopAll()`、§3.1 声明 `config_manager.num()/bool()`，但代码均未实现。本轮补齐：

- `lib/module_loader.lua`：`start()` 成功后登记模块；新增 `stopAll()` 从登记表尾逆序调用各模块 `stop()` 后清空。
- `lib/config_manager.lua`：新增 `num(t, key, default)`、`bool(t, key, default)`（`t` 可为全局配置名或表）。

### 10.2 生命周期 stop() 补齐

按 §8.3-3 补齐持资源模块的 `stop()`（行为等价——均设置为停止标志/清理订阅/定时器）：

| 模块 | stop() 内容 |
|------|------|
| `vbat` | `running` 标志退出采样循环；`adc.close` |
| `time_sync` | `sntpRunning` 退出 sntp 任务；`sys.unsubscribe(SNTP_SYNC_SUCCESS)` |
| `led_ctrl` | `running` 退出 LED 循环；取消 5 个事件订阅；关灯 |
| `battery_guard` | `cnclShutTmr()` 取消关机定时器；清 hook |
| `peripheral` | 取消长按定时器；委托 `led_ctrl.stop()`/`pir_ctrl.stopHw()` |
| `pir_ctrl` | `stop()` 取消 `PIR_HW_TRIGGERED` 订阅 + `clearRecTmr`；新增 `stopHw()` |
| `fota_svc` | `sys.unsubscribe` 两个 OTA topic |

`t31x_ctrl`、`usb_charge`、`cellular_bootstrap` 无持久后台任务/无标准 teardown API，不补 `stop()`（其资源均为一次性短脉冲/GPIO IRQ）。`sound_prompt` 的 `start` 为空实现、任务均一次性，不补。T31x 烧录/关机前整体停机可 `loader.stopAll()`（必须先经 `loader.start()` 启动的模块才会被登记）。

### 10.3 lib→user 反向依赖解耦

消除 4 处 `lib` 动态 `loader.load("user")` 反向业务依赖与 3 个依赖环（环 A/B/C），全部行为等价：

| 位置 | 解耦方式 |
|------|------|
| `runtime_power.isBatDynRest` → `battery_guard`（环 B） | 删除 battery_guard fallback：读 `_G.APP_RUNTIME.battery_dynamic_rest` 全局即可（battery_guard 各处已同步维护该字段，语义等价） |
| `t31x_notify` → `time_sync`/`host_uart`/`t31x_ctrl`（环 C，3 处） | `registerProviders{pushBeforeNotify, ntfHost, wakeHost, ensPowOn}`；user 层 app.lua 启动时注入，未注入时保持原懒加载路径 |
| `usb_charge` → `peripheral.cancelLongPress` | 新增 `onUsbInsert(cb)` 注入钩子；app.lua 注册 |
| `low_power_wakeup` → `net_tcp` | 新增 `bindNetTcp(mod)`；app.lua 注册 |

同时移除 `lib/sys.lua` 中从未使用的 `require "utils"`（死引用，也是环 A 的成环点——`sys`(lib) 一度反向牵 user/utils）。

**剩余说明**：lib 至 user 的 6 处静态 `require "config"` 属"共享配置真源"约定内例外（config 非业务模块），保留。

### 10.4 事件 fallback 收编

`host_uart`/`app`/`net_mqtt` 中 `X or "APP_*"` 硬编码回退统一收编为 `utils.appEvent(name, fallback)`（委托 `config_manager.event`），事件值字符串保持不变，行为等价。

### 10.5 验证

所有改动文件经 `luatos-cli build luac` 全量编译零错误；修改遵循行为等价原则（全局事件字符串、返回值、时序均未变）。建议整机回归：唤醒链路（time_sync/sound_prompt/t31x_notify）、USB 插入长按取消、低电量 rest 动态检测、T31x 烧录模式整体停机。
