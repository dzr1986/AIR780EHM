# 780EHM_PJ 逻辑架构优化计划

> **状态**：阶段 0–3 已落地（2026-08-29）；阶段 4 表外置**本轮冻结**；阶段 5A USB 查询单点已落地（2026-08-30，见 [USER_LIB_OPTIMIZATION_PLAN_20260830.md](USER_LIB_OPTIMIZATION_PLAN_20260830.md)）
> **审计日期**：2026-08-29（user/ 19 文件 + lib/ 17 文件全量）
> **对齐分支**：`cursor/user-lib-optimize-8f6a`
> **关联文档**：[LUA_MODULES.md](LUA_MODULES.md)（模块分析）· [CODE_ANALYSIS.md](CODE_ANALYSIS.md)（架构与风险）· [CAT1_LOGIC_SLIM.md](CAT1_LOGIC_SLIM.md)（逻辑精简历史，阶段 0–4 已落地）· [CAT1_MODULE_FRAMEWORK.md](CAT1_MODULE_FRAMEWORK.md)（模块框架）

---

## 1. 文档目的

本计划回答三个问题：

1. **现状是什么**——一套可复核的逻辑架构基线（分层、模块职责、事件机制、配置体系）；
2. **哪里有问题**——2026-08-29 审计发现的全局状态散落、依赖方向倒置、死代码、文档漂移；
3. **怎么改**——分阶段、可验收、低风险的优化路线图。

它与既有文档的关系：**不重复** LUA_MODULES.md / CALL_GRAPH.md 的静态分析，**只聚焦**"架构整理"这条优化路线的目标与执行步骤。CAT1_LOGIC_SLIM.md 记录的是已完成的 Flash/逻辑精简（阶段 0–4 全部落地）；本文档是下一轮"逻辑架构整理"的规划。

---

## 2. 现状架构基线（as-is）

### 2.1 分层模型

```
main.lua（入口）
  └─ app.lua（编排中心：启动链 / 事件集中订阅 / 烧录模式 / 低功耗进出）
       ├─ user/ 业务层：net_mqtt、host_uart、t3x_ctrl、pir_ctrl、battery_guard、
       │            peripheral、led_ctrl、vbat、fota_svc、ipc_supervision、
       │            time_sync、sound_prompt、net_tcp（stub）、utils（工具）
       └─ lib/ 公共层：uart_bridge、module_loader、sys、config_manager、gpio_util、
                  usb_charge、usb_rndis、usb_vuart、cellular_bootstrap、low_power_wakeup、
                  t3x_policy、t3x_notify、host_event、runtime_power、watchdog、device_id、libfota2
```

设计约定（与代码一致）：

| 约定 | 现状 |
|------|------|
| 单 MQTT 入口 | `net_mqtt`，下行 `DOWNLINK_HANDLERS` 表驱动（2001–2031） |
| 单串口入口 | `lib/uart_bridge`（唯一 `uart.setup`），host_uart 在其上做 AT 业务 |
| 配置真源 | `user/config.lua` 单文件（`FEATURE_CFG` → `*_CFG` → `MODULE_FLAGS` → `APP_EVENTS` → `KEY_CONFIG`） |
| 事件驱动 | `APP_EVENTS` 38 个事件常量，`app.lua` 集中订阅（subscribeAll） |
| 模块加载 | `lib/module_loader`（load / enabled / opt），`MODULE_FLAGS` 裁剪，大量懒加载 |
| 平台约束 | 脚本区 **512KB** 上限（量产压缩包约 342KB）；LuatOS 单文件 **200 个顶层 local 上限** |

### 2.2 模块职责速览

| 层 | 模块 | 职责（一句话） |
|----|------|----------------|
| user | `app.lua` | 编排中心：启动 18 步、subscribeAll、烧录模式、低功耗进出、MOTOR 桥接 |
| user | `net_mqtt.lua`（2803 行） | 云端 MQTT：1001–1031 上行 / 2001–2031 下行表驱动分发、待 T3x 下行队列 |
| user | `host_uart.lua`（3673 行） | T3x AT 协议：44 条 AT_CMD_TABLE、24 个行处理器、事务互斥、唤醒通知 |
| user | `t3x_ctrl.lua` | 协处理器电源：enterSleep 优雅关机、boot 模式、经 t3x_policy 门禁上电 |
| user | `pir_ctrl.lua` | PIR 侦测与会话：录像/冷却/云端启停/PIRSTAT、配置持久化 |
| user | `battery_guard.lua` | 电量三档策略：3400mV 连续确认关机、PIR 挂起、battery rest、hooks 注入 |
| user | `peripheral.lua` / `led_ctrl.lua` | 按键长短按 / 单蓝灯模式 |
| user | `vbat.lua` | 电池 ADC：trim/EMA 滤波、发 BATTERY_UPDATE |
| user | `fota_svc.lua` / `ipc_supervision.lua` | MQTT 2004 OTA / IPC 告警对账（1004/1011） |
| user | `time_sync.lua` / `sound_prompt.lua` | 唤醒前对时 / 提示音 |
| user | `utils.lua` | 工具：nowMs/escJson/appEvent/waitT3xCmdAck/lazyRequire |
| user | `net_tcp.lua`（33 行） | TCP 唤醒桩（默认 `mode="mqtt"` 不加载） |
| lib | `uart_bridge.lua` / `sys.lua` | 底层串口（on_raw/on_line 拆包） / LuatOS 事件调度核心 |
| lib | `module_loader.lua` / `config_manager.lua` | 懒加载门面 / 配置合并 |
| lib | `usb_charge.lua` / `usb_rndis.lua` / `usb_vuart.lua` | USB 充电检测 / RNDIS 网卡 / USB 虚拟串口 |
| lib | `cellular_bootstrap.lua` | 蜂窝拨号引导：SIM/APN 探测、运营商映射 |
| lib | `low_power_wakeup.lua` / `t3x_policy.lua` / `t3x_notify.lua` | 唤醒通道 mqtt/tcp / T3x 上电门禁 / 唤醒三级链 |
| lib | `host_event.lua` / `runtime_power.lua` | HOSTEVT 汇总（TYPE_BIT 位图）/ 工作模式查询 |
| lib | `device_id.lua` / `watchdog.lua` / `gpio_util.lua` / `libfota2.lua` | IMEI 单点 / WDT / GPIO 工具 / FOTA 引擎（供应商） |

### 2.3 关键机制

- **事件总线**：`config.lua` 中 `APP_EVENTS` 38 个常量；app.lua `subscribeAll` 集中订阅；模块内另有"点对点 ACK 事件"（host_uart `SYS_EVT` 约 28 个、`TIME_SYNC_ACK`、`SOUND_PROMPT_ACK`）+ `utils.waitT3xCmdAck` 等待原语。
- **内部通道**：字符串事件 `"mqtt_pub"(topic, payload, qos)`（net_mqtt 对外发布口）、`"net_ready"`、系统事件（`IP_READY`/`SIM_IND`/`SNTP_SYNC_SUCCESS` 等）。
- **依赖注入**：`app.start(peripheral, net, t3x_ctrl)` 构造注入；`battery_guard.start({onEnterLowPower, ...})` hooks；`ipc_supervision.bind(...)`。
- **协议分发**：net_mqtt `DOWNLINK_HANDLERS` 表驱动；host_uart `AT_CMD_TABLE` + `RX_LINE_HANDLER_REGISTRY`（24 个行处理器）。
- **运行期共享状态**：`APP_RUNTIME`（online_status / power_status / low_power_mode / work_mode / battery_* / consumption_rate 等），多模块读写。

---

## 3. 问题诊断（2026-08-29 审计）

### 3.1 全局状态散落（P0）——跨模块 `_G.` 裸写

| 变量 | 位置 | 问题 | 建议 |
|------|------|------|------|
| `_G.APP_PIR_CONFIG` / `_G.normPirMCfg` / `_G.normPirRPol` / `_G.pirMediaConfig` / `_G.pirRecordPolicy` | `pir_ctrl.lua` 30/245/246/292/317/320/326/327/524/536 | **纯内部状态与函数写成全局**，全库除 pir_ctrl 外无任何外部引用 | 改模块级 local + 访问器 |
| `_G.T3X_BURN_MODE_ACTIVE` | app.lua 写（273/618/879）；battery_guard:160 / sound_prompt:29 / t3x_policy:57 读 | 烧录模式标志 3 文件裸读裸写 | 收进 `t3x_ctrl` 模块状态 + `isBurnActive()` 访问器 |
| `_G.uart_bridge` | app.lua:339 写；utils.lua:153 读 | 实例别名走全局 | 改注入/模块持有 |
| `_G.device_imei` | app.lua:519/1004 写；device_id:11 读 | 与 `lib/device_id.lua` 职责重叠 | 缓存收进 device_id + getter |
| `_G.usbRndis = _M` | usb_rndis.lua:425 | 与 `_G[_modname] = _M` 重复注册 | 删除冗余行 |
| `_G.MQTT_CFG = normalized` | net_mqtt.lua:1945 | **运行期归一化覆盖配置真源**，调试时配置与文件不一致 | 改局部副本（模块内 `local mqttCfg = normalized`） |

### 3.2 lib 反向依赖 user（P0/P1）——与文档声称不符

`doc/CODE_ANALYSIS.md` 声称"lib 不反向依赖 user"，实际存在：

| lib 模块 | 反向依赖 |
|----------|----------|
| `gpio_util.lua` / `cellular_bootstrap.lua` / `t3x_policy.lua` / `usb_charge.lua` / `host_event.lua` | `require "config"`（即 user/config.lua） |
| `usb_charge.lua` | 另用 `user/utils` 函数 |
| `host_event.lua` | `loader.load("net_mqtt")` 懒加载 **user 业务模块** |

依赖方向倒置的后果：lib 无法独立复用、模块间职责边界模糊、静态分析工具难以建模。

### 3.3 死代码 / 死读（P1）

| 候选 | 位置 | 判定 |
|------|------|------|
| `net_tcp.lua` 全文件（33 行 stub） | user/net_tcp.lua | 默认 `mode="mqtt"` 不加载；属开关保留桩 → 可归档或加文件头说明 |
| `_G.aliyuncs_imei` 读取分支 | lib/device_id.lua:14-15 | 全库无写入方，**死读**（旧阿里云方案残留）→ 删除 |
| `T3X_PERSON_CNT` 处理器空函数 | app.lua:818-821 | 故意 no-op（人数不上 MQTT 1010），保留订阅防丢事件 → 补注释说明意图 |

### 3.4 大文件热点（P2）

- `host_uart.lua` 3673 行、`net_mqtt.lua` 2803 行，占 user/ 近一半。
- **约束**：LuatOS 单文件 200 个顶层 local 上限。host_uart 顶层 `xxx = function()` 导出**是有意为之**（3407 行注释），不可盲目 local 化。
- 拆分方向见 §5 阶段 4（高成本、可选，先保证数据表驱动化）。

### 3.5 文档漂移（P0，低成本高收益）

| 漂移 | 说明 |
|------|------|
| `app_config.lua` / `key_config.lua` 不存在 | 已并入 `user/config.lua`（665 行），但 CODE_ANALYSIS.md / README.md 仍按三文件描述 |
| `lib/usb_policy.lua` 不存在 | CAT1_LOGIC_SLIM.md §10 记载"已落地"，实际 lib/ 中无此文件（USB/rest 门禁现落在 usb_charge / t3x_policy / runtime_power） |
| 行号过期 | CODE_ANALYSIS.md 引用 `app.start` 1106–1157，实际 app.lua 仅 1063 行 |
| `lib/mobile_info.lua`、`lib/led.lua`、`lib/pir.lua` 等引用 | 均已归档/合并，旧文档仍提及 |

### 3.6 其他观察

- **良态**：全库无 TODO/FIXME/HACK/XXX 残留；无注释掉的旧逻辑块；net_mqtt → host_uart 全部走懒加载模块 API，解耦良好。
- `APP_RUNTIME` 是隐式全局状态表（多写者），重构期需全库搜索，暂无类型约束——短期接受，列入阶段 1 的"状态访问收敛"范围。
- `POWER_ENTERED_REST` 事件无订阅者（历史遗留），可清理或明确为扩展点。

---

## 4. 目标架构（to-be）

```
main.lua
  └─ app.lua（编排中心，保持集中订阅）
       ├─ user/ 业务层（net_mqtt / host_uart / t3x_ctrl / pir_ctrl / battery_guard / ...）
       ├─ lib/  公共层（uart_bridge / module_loader / usb_* / cellular / 电源策略 / ...）
       └─ config 基础层（唯一真源；lib 允许依赖，禁止 lib 依赖 user 业务）
```

收敛原则：

1. **依赖单向**：`main → app → user 业务 → lib 公共 → config`。lib 不得 require user 业务模块；lib 对 `user/config.lua` 的依赖在文档中明确定义为"基础层依赖"（或按 §5 阶段 2 方案下沉）。
2. **状态模块化**：跨模块共享状态一律"模块内 local + 访问器"，消灭 `_G.` 裸写；`APP_RUNTIME` 保留但由模块 API 读写。
3. **配置只读**：config.lua 是唯一真源；任何运行期归一化结果（如 MQTT_CFG）只放局部副本，不回写全局。
4. **表驱动优先**：协议分发保持 DOWNLINK_HANDLERS / AT_CMD_TABLE 风格，新协议只加表项不写新分支。
5. **事件命名收敛**：全局事件走 APP_EVENTS 常量，模块内 ACK 事件在各自模块顶部集中声明。

---

## 5. 分阶段实施计划

> 每阶段独立可合并、可验收；阶段间不互相阻塞。改动遵循"先文档后代码、每阶段烧录回归"。

### 阶段 0：基线文档同步（约 0.5 天，P0）

**目标**：消灭 §3.5 文档漂移，让后续阶段有可信基线。

| 动作 | 文件 |
|------|------|
| 修正配置描述：三文件 → 单文件 `user/config.lua` | README.md、CODE_ANALYSIS.md、doc/README.md |
| 修正 `usb_policy.lua` 条目：标注"已回退/职责并入 usb_charge、t3x_policy、runtime_power" | CAT1_LOGIC_SLIM.md §10 |
| 修正过期行号引用 | CODE_ANALYSIS.md |
| 新增本计划到文档索引 | doc/README.md |

**验收**：grep `app_config.lua` / `key_config.lua` / `usb_policy` 不再有错误指向。

### 阶段 1：全局状态收敛（约 1–2 天，P0）

**目标**：§3.1 全部收敛，跨模块 `_G.` 裸写清零。

| # | 改动 | 文件 |
|---|------|------|
| 1.1 | pir_ctrl 5 个全局（APP_PIR_CONFIG / normPirMCfg / normPirRPol / pirMediaConfig / pirRecordPolicy）→ 模块级 local + `getPirMediaConfig()` / `getRecordPolicy()` 访问器（net_mqtt 2010 已走模块 API，无外部引用，安全） | user/pir_ctrl.lua |
| 1.2 | `T3X_BURN_MODE_ACTIVE` → `t3x_policy.setBurnActive()` 规范状态 + `isBurnActive()` 访问器；app 侧 `setBurnMode()` 统一写入口；battery_guard / sound_prompt / pir_ctrl 改调用访问器 | user/app.lua、user/battery_guard.lua、user/sound_prompt.lua、user/pir_ctrl.lua、lib/t3x_policy.lua |
| 1.3 | `_G.uart_bridge` 实例别名 → 删除（`loader.load("uart_bridge")` 等价）；`_G.host_uart` 死读同步清理 | user/app.lua、user/utils.lua |
| 1.4 | `_G.device_imei` 缓存 → 收进 `lib/device_id.lua`（`setImei()` + 模块内缓存）；app.lua 两处写改调用 `didCacheImei` | user/app.lua、lib/device_id.lua |
| 1.5 | 删除 `_G.usbRndis = _M` 冗余行 | lib/usb_rndis.lua |
| 1.6 | `MQTT_CFG = normalized` → 模块内局部副本 `mqttCfg`（`curMqttCfg()`），不再回写全局 | user/net_mqtt.lua |

**验收**：`grep -rn "_G\.[A-Za-z_]* *=" user/ lib/`（排除 config.lua / main.lua 平台约定项）无运行期状态写入；luacheck 通过；烧录后 MQTT 2001–2013 下行、PIR 2010、烧录模式（GPIO28 长按）回归。

**风险**：低。全部为机械收敛，行为不变；1.2 涉及 3 个读方，改访问器时同步改。

### 阶段 2：依赖方向治理（约 1–2 天，P1）

**目标**：消灭 lib → user 业务依赖；明确 config 基础层约定。

| # | 改动 | 说明 |
|---|------|------|
| 2.1 | `host_event.lua` 去 `loader.load("net_mqtt")`：`bindMqttPending(fn)` 回调注入（app.start 时绑定），lib 不再反向 require user 业务 | ✅ 已落地 |
| 2.2 | `usb_charge.lua` 依赖 `user/utils` 的 `appEvent` → 下沉 `config_manager.event()`，utils.appEvent 委托之（单一实现） | ✅ 已落地 |
| 2.3 | 文档约定：`lib 允许 require "config"`（视为基础层），禁止 require 其它 user 模块；CODE_ANALYSIS.md 同步修正"lib 不反向依赖 user"表述 | ✅ 已落地（CODE_ANALYSIS.md §2.2 同步修正） |

**验收**：`grep -rn 'require ".*"' lib/` 结果中，除 `config` / `sys` / `patch` / `clib` / lib 内部互引外，无 user 模块；luacheck 通过。

**风险**：中（host_event 与 net_mqtt 的时序敏感）。2.1 改动后需重点回归 HOSTEVT 上报 → MQTT 上行的链路。

### 阶段 3：死代码清理（约 0.5 天，P1）

| # | 改动 | 文件 |
|---|------|------|
| 3.1 | 删除 `aliyuncs_imei` 死读分支 | lib/device_id.lua（阶段 1.4 一并完成） |
| 3.2 | `net_tcp.lua` stub 归档到 archive/（保留桩说明）或文件头标注"tcp 模式启用时才加载" | 已有文件头说明，维持现状（静态打包锚点依赖该文件） |
| 3.3 | `T3X_PERSON_CNT` no-op 补注释说明意图 | 已有注释（app.lua:831-834），维持现状 |
| 3.4 | 评估 `POWER_ENTERED_REST` 无订阅者：清理或标注扩展点 | ✅ 已标注扩展点注释（user/app.lua） |

**验收**：功能开关组合（mqtt 模式、tcp 模式、低功耗开/关）下烧录回归通过。

### 阶段 4（可选）：大文件结构优化（约 2–3 天，P2，高风险）

**目标**：缓解 host_uart（3673 行）/ net_mqtt（2803 行）维护压力。**不追求行数目标，追求可读性**。

| 方案 | 说明 | 取舍 |
|------|------|------|
| A. 数据表外置 | `AT_CMD_TABLE` / `DOWNLINK_HANDLERS` 等纯数据表拆到独立 `.lua`（如 `hu_at_tbl.lua`），运行时 require 合并 | 低风险、不触 200 local 上限；推荐先做 |
| B. 处理器子模块 | 按协议族（GB28181 / TF / RECORD / IPC / 编码）拆 handler 文件 | 中高风险：跨文件互斥锁、SYS_EVT 表、seeall 语义需整体搬迁；需保持 200 local 上限约束 |
| C. 维持现状 | 只在表驱动与命名上持续优化 | 零风险 |

**2026-08-30 已做 A**：`hu_at.lua`（AT 表）+ `net_mqtt_host_proto.lua`（2020–2031）。方案 B（按协议族拆 handler / 互斥锁）仍冻结。`APP_RUNTIME` 改为嵌套表，见 [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)。版本 `001.000.071`。

---

## 6. 优先级速查

| 优先级 | 内容 | 预估 | 风险 |
|--------|------|------|------|
| P0 | 阶段 0 文档同步 + 阶段 1 全局收敛 | 1.5–2.5 天 | 低 |
| P1 | 阶段 2 依赖治理 + 阶段 3 死代码清理 | 1.5–2.5 天 | 中 |
| P2 | 阶段 4 数据表外置（可选） | 2–3 天 | 低～中 |

---

## 7. 验收与回归清单（每阶段合并后）

- [ ] **烧录**：`cat1_flash.py flash-script` 通过，压缩 LuaDB < 512KB（量产约 342KB；勿用 Luatools debug99）
- [ ] **静态**：`luacheck user lib` 无新增告警（1xx 全局读写噪音除外）
- [ ] **MQTT**：2001–2007、2010–2021、2020、2013 下行；1001–1011 上行
- [ ] **PIR**：2010 录像/拍照、PIRSTAT / HOSTEVT body、冷却与计数
- [ ] **低功耗**：rest 进/出、USB 插入拦截 rest、`AT+HOSTIDLE`、唤醒通道 mqtt/tcp
- [ ] **T3x 电源**：上电门禁、`IPCPOWEROFF` 优雅断电、USBRESET、烧录模式（GPIO28 长按）
- [ ] **电量**：vbat ADC 上报、3400mV 关机、电量灯效
- [ ] **对账**：`doc/CODE_DOC_AUDIT.md` 的代码↔文档核验流程跑一遍

详细场景见 [CAT1_SLIMMING_FLOW.md §6](CAT1_SLIMMING_FLOW.md)。

---

## 8. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-29 | 初版：基线审计（user/ 19 + lib/ 17 全量）+ 四阶段优化路线（0 文档同步 / 1 全局收敛 / 2 依赖治理 / 3 死代码 / 4 可选拆分） |
| 2026-08-29 | **阶段 0–3 已落地**：文档漂移修正；全局状态收敛（pir_ctrl 5 全局 / 烧录态收进 t3x_policy / 实例别名 / device_imei / usbRndis / MQTT_CFG 局部副本）；依赖治理（host_event 回调注入 / appEvent 下沉 config_manager）；死代码清理。luatos-cli 全量编译通过（36 文件）。阶段 4 未实施（数据表外置需单独评估）。 |
| 2026-08-30 | 阶段 4 冻结；下一刀见 [USER_LIB_OPTIMIZATION_PLAN_20260830.md](USER_LIB_OPTIMIZATION_PLAN_20260830.md)；阶段 5A USB/充电查询收进 `runtime_power`；脚本区口径改为 512KB；版本 `001.000.050`。 |
| 2026-08-30 | 阶段 5B：运行态访问器（电量/在线/rest 读路径）；版本 `001.000.051`。 |
| 2026-08-30 | 阶段 5D：去过度防护（常驻库直接调、可关模块只判 nil）；版本 `001.000.052` → `001.000.055`。5D 可收项已尽，停止。 |
| 2026-08-30 | 阶段 4A + 嵌套 `APP_RUNTIME`：`hu_at` / `net_mqtt_host_proto`；版本 `001.000.071`。 |
