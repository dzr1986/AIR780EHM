# AGENTS.md — 架构决策与 Agent 工作指南

> 本文件供 **Cursor Agent / Cloud Agent / 子代理** 在改 `user/`、`lib/`、`tools/debug/` 前快速对齐架构口径。  
> **规则真源**（机器强制）：`.cursor/rules/*.mdc` + `python3 tools/debug/run_all_checks.py`（14 项）。  
> **决策流水**（按日）：`doc/overview/USER_LIB_OPTIMIZATION_NEXT.md` §8。  
> **体检与优先级**：`docs/architecture_audit.md`、`docs/refactor_plan.md`。  
> **逐层重构**：`docs/layer_refactor_plan.md`（L0 完成 → L1 进行中）。

---

## 1. 项目上下文

| 项 | 值 |
|---|---|
| 硬件 | Air780EHM Cat.1 + T31x 协处理器（UART AT） |
| 运行时 | LuatOS **Lua 5.3** |
| 真源目录 | 仓库根 `user/`、`lib/`、`main.lua`（**不要**改 `LuaTools/userprojs/AIR780EHM/` 旧副本） |
| 当前版本 | `user/main.lua` `VERSION`（2026-09-05：**001.000.161**） |
| 模块风格 | `module(..., package.seeall)` — **禁止**改成 `local M = {}` |
| 文件名 | Luatools 限制 **≤ 24 字节**（`hif_*` / `mqtt_*` 家族名已是最优，勿重命名） |

---

## 2. 四层架构（决策 ADR-001）

**决策**：采用 HAL 驱动 → 平台抽象 → 业务逻辑 → 应用 四层；**只允许上层调用下层**；层间只经**导出接口**（Lua 里 = 模块导出 + `ctx` bind 头），禁止反向依赖与跨层直接读内部 `state`。

| 层 | 落点 | 职责 |
|---|---|---|
| **L0 HAL 驱动** | LuatOS 内核库 + `lib/power_hal`、`lib/adc_hal`、`lib/uart_bridge`、`lib/gpio_util`、`lib/led_ctrl`、`lib/usb_*`、`lib/watchdog`、`lib/cell_boot` | **全仓库唯一**允许 `pm.*/pmd.*/adc.*`/`uart.setup`/`gpio.setup` 等；`user/` 零直调（`_hal_layer_check` #14） |
| **L1 平台抽象** | `lib/utils`、`runtime_power`、`config_manager`、`module_loader`、`device_id`；config 域（`user/config.lua` + 10 片段）；vendor：`sys.lua`、`libfota2.lua` | 与业务无关的平台能力；`APP_RUNTIME` **只**经 `runtime_power` 读写 |
| **L2 业务逻辑** | `user/` 除 app/config 外全部（含基础设施 `svc`、`t31x_ctrl`、`host_uart`+`hif_*`、`net_mqtt`+`mqtt_*`、`pir_ctrl` …） | 协议、状态机、策略 |
| **L3 应用** | `main.lua`、`user/app.lua` | 装配、事件桥接、**provider 注入**；不放业务算法 |

**机器护栏**：`tools/debug/_layer_check.py` R1–R5（基线 **0 条**，只许收缩）。  
**详细规则**：`.cursor/rules/arch-layering.mdc`。

### L2 内部子层（决策 ADR-002）

| 子层 | 模块 | 规则 |
|---|---|---|
| AT 协议族 | `host_uart` + 18× `hif_*` | **不得** `modCall`/`require` 业务模块；需要业务数据/动作 → `app.buildBizProviders` + `ctx.bizCall(key, …)` |
| MQTT 族 | `net_mqtt` + `mqtt_*` | 子模块只经 `bind(ctx)`，禁止 `require "net_mqtt"` |
| 基础设施 | `t31x_ctrl`、`runtime_power`、`device_id`、`svc` | AT 层与其他 L2 可调；不算「业务层」 |

**provider 唯一真源**：`user/app.lua` → `buildBizProviders()`（**22 键**，2026-09-05）。  
**护栏**：`_ref_name_check` 规则 F — `bizCall("x")` 的 x 必须在 provider 表内。

---

## 3. 已冻结的架构决策（勿推翻）

| ID | 决策 | 理由 |
|---|---|---|
| **F-01** | **不合并、不再拆 `app.lua`** | 约定冻结；PSM/provider 注入完成后 app 自然瘦身 |
| **F-02** | **不重命名 `hif_*` / `mqtt_*` 家族** | 24 字节限制下已最优，改名只增 diff |
| **F-03** | **不改 `module(..., package.seeall)` 风格** | LuatOS 生态与 `.cursor/rules/lua-luatos.mdc` |
| **F-04** | **不动 vendor：`lib/sys.lua`、`lib/libfota2.lua`** | 合宙原厂；Luatools 只扫 `lib/`；R5 sha256 锁（`_vendor_lock.json`） |
| **F-05** | **config 域片段禁止 `require utils/module_loader`** | require 环会栈溢出（R2） |
| **F-06** | **`host_uart` / `net_mqtt` 主文件不再拆** | 锁/分发/ctx 与 `mqttTask` 必须在主文件；新 handler 进子模块 |

---

## 4. 核心架构模式（已落地）

### 4.1 串口并发三层（P3，VERSION 156+）

| 层 | 机制 | 语义 |
|---|---|---|
| 事务锁 | `uartAcquire` / `uartRelease` | 同一时刻只有一个 AT 请求在飞 |
| 破坏性会话 | `state.uart_session`（`tfformat` / `poweroff` / `usb_recovery`） | T31x 处于不可打扰状态；非持有协程 `hostQuery` 走缓存、`hostSet` 回 busy |
| per-query 重入 | `hostQuery` 内部 | 与会话正交 |

**仲裁（#2，VERSION 161）**：`t31x_ctrl.blockSleep` 看 `getUartSession()`；`hostIpcPowerOff` 有界等待他会话。  
**文档**：`doc/modules/HOST_UART_AT_DISPATCH.md` §9–§11。

### 4.2 状态单写点

| 状态 | 唯一写入入口 | 护栏 |
|---|---|---|
| 低功耗 rest 位 | `runtime_power.requestRest` / `requestNormal` | `SINGLE_WRITERS` |
| PSM 副作用 | `runtime_power.bindPowerHooks{ onEnterRest, onExitRest }`（E 条） | app 只回调，不自己判态再副作用 |
| 录像态 `recordingt31x` | `hif_ipc.setRecActive` | `SINGLE_WRITERS` |
| `host_uart.state` 四语义键 | `setHostIpcStatus` / `setHostAtReady` / `setHostTfCard` / `setHostCloudStat`（C 条） | `SINGLE_WRITERS` +4 |
| 云状态 ts | `commitIpcStat`；局部补丁传 `keepTs=true`（#3） | 防 1003 跳查 |

### 4.3 AT 层 ↔ 业务层解耦（A 条）

- **之前**：25 处 `modCall("pir_ctrl"|"net_mqtt"|…)` → 运行期软环 22 模块，静态图看不见。
- **现在**：`host_uart.start{ biz = buildBizProviders() }` → `ctx.bizCall`；R4 基线 15→**0**。
- **语义差异**：被 `MODULE_FLAGS` 裁剪的模块，旧 `modCall` 会 `loader.load` 强行加载；新 `bizCall` 返回 nil（更符合裁剪意图）。

### 4.4 常量单源

| 范围 | 真源 | 示例 |
|---|---|---|
| 同族 | 主文件 `TMO_SHARED` → `ctx.TMO_SHARED` | `acquireCapMs`、`cloudStatQueryMs` |
| 跨族 | config 片段 `user/host.lua` → `_G.HOST_PROTO_TMO`（F 条） | `ipcstat_query_ms=2500`、`record_stop_ms=22000` |
| 配置 | `_G.*_CFG` + `cfgm.get("KEY")` | `_config_key_check.py` + `CONFIG.md` 索引 |

### 4.5 业务层不拼 AT 文本（H 条）

- `pir_ctrl.getStatSnapshot()` — 只出数据。
- `hif_cmd_pir.buildPirStatBody(snap)` — 拼 `+PIRSTAT:` 文本（字段顺序与旧版逐字一致）。

### 4.6 lib 工具命名（I 条）

- `lib/utils.lua` 只用**通用名**（如 `waitEventUntil`，禁止 `waitT31xAck`）。
- 跨域桥接 → `user/svc.lua`（utils 禁止依赖 user）。

---

## 5. 暂缓 / 明确不做的决策

| ID | 项 | 结论 | 文档 |
|---|---|---|---|
| **D-01** | P4 ACK 请求关联 `_seq` | **不实施** — 需 T31x 固件配合，风险大于收益 | `docs/refactor_plan.md` P4 |
| **D-02** | P7 ctx 三命名空间拆分 | **不实施** — 改为 bind 时刻可用性 + `bind_header_specs.json` | `docs/refactor_plan.md` P7 |
| **D-03** | P8 上行 JSON 字段表序列化重写 | **不做** — 离线无法逐字节黄金样本；护栏半落地 | `docs/refactor_plan.md` P8 |
| **D-04** | P10 余 5 项对外接口 | **待三方** — 1013 进度字段、need 去重、hostevt_poll、hybrid 配置、内核号 | `docs/refactor_plan.md` P10 |
| **D-05** | 物理 `lib/vendor/` 目录 | **不可** — Luatools 只扫 `lib/`；用 R5 sha256 锁代替 | `doc/overview/LUA_MODULES.md` vendor 段 |

---

## 6. 业务层硬件调用（L0 已收敛，2026-09-05）

**决策 ADR-L0-01**：`user/` **零** HAL 直调；全部经 L0 封装：

| HAL 模块 | API |
|---|---|
| `lib/power_hal.lua` | `shutdown` / `reboot` / `hibernate` / `initPwkMode` / `initPmd` |
| `lib/adc_hal.lua` | `configure` / `open` / `close` / `readMv` |
| `lib/gpio_util.lua` | `getLevel`（+ `setupInput` / `setupOutput`） |

**机器护栏**：`tools/debug/_hal_layer_check.py`（`run_all_checks` #14）— user/ 零容忍；lib/ 仅白名单 12 文件。

**巡检**（应无输出）：`rg -n "\b(uart|gpio|adc|wdt|pm|pmd|i2c|spi|pwm)\.[a-zA-Z_]+\s*\(" user/*.lua`

逐层计划 → [`docs/layer_refactor_plan.md`](docs/layer_refactor_plan.md)（**L0+L1 完成**；L2 下一步：`patchCloud(keepTs)` / 跨族常量 / `vbat→adc_hal` 收口）。

### L1 设备 power 单入口（ADR-L1-01，2026-09-05）

| API | 用途 |
|---|---|
| `requestDeviceShutdown()` | 4G 关机（`pm.shutdown`） |
| `requestDeviceReboot(delayMs)` | 4G 重启 |
| `requestModemHibernate()` | _modem_ hibernate 路径（T31x sleep 时 `opts.modemHibernate`） |
| `initPwkMode()` / `initPmd(onMsg)` | 冷启动 / 充电消息 |

`user/` 禁止 `require "power_hal"`（`_hal_layer_check`）；与 PSM `requestRest/requestNormal` 正交。

---

## 7. 提交门槛（Agent 必做）

```bash
# 1. 语法
for f in user/*.lua lib/*.lua; do luac5.3 -p "$f" || exit 1; done

# 2. 14 项静态护栏（必须 ALL PASS）
python3 tools/debug/run_all_checks.py

# 3. 分层与环
python3 tools/debug/_dep_graph.py --scc    # 硬环必须 0

# 4. 行为改动时
#    - user/main.lua VERSION +1
#    - python3 tools/debug/_doc_version_check.py
#    - 同步 doc/overview/USER_LIB_OPTIMIZATION_NEXT.md §8 一行
```

**基线文件**（只许收缩，放大须在 AGENTS.md / rules / NEXT §8 登记原因后再 `--save-baseline`）：

| 文件 | 内容 |
|---|---|
| `_layer_baseline.json` | 分层违规边（当前 `[]`） |
| `_vendor_lock.json` | vendor sha256 |
| `_uplink_schema_baseline.json` | 文档有、代码无的上行字段缺口 |
| `_module_tree_baseline.json` | 模块行数 |

**禁止**：用 `git checkout -- <file>` 做负向验证（会把未提交改动一并还原）。

---

## 8. 子代理（`.cursor/agents/`）

| 子代理 | 何时用 |
|---|---|
| **`arch-guard-reviewer`** | 改完 `user/`/`lib/` 后主动评审：分层、护栏、VERSION、文档同步；输出 Critical/Warning/Suggestion |
| **`luatos-guard-author`** | 把新规则写成 `tools/debug/_*.py` 护栏；负向 fixture + `test_guards.py` + 注册 `run_all_checks` |

用法示例：`Use the arch-guard-reviewer subagent to review my changes.`

---

## 9. 如何记录新的架构决策

1. **在本文件**「§4 核心架构模式」或「§5 暂缓」增一行 ADR 表项（含 ID、决策、理由、关联 VERSION）。
2. **在** `doc/overview/USER_LIB_OPTIMIZATION_NEXT.md` **§8** 加一行日期流水（团队 changelog）。
3. **若影响分层/例外/护栏**：同步 `.cursor/rules/arch-layering.mdc` 对应小节。
4. **若需机器拦截**：按 `luatos-guard-author` 流程加护栏；基线收缩用 `--save-baseline`。
5. **若改对外契约**（MQTT/AT/配置键）：升 VERSION + 同步 `MQTT_DOWNLINK.md` / `HOST_UART_AT_DISPATCH.md` / `CONFIG.md`。

---

## 10. 深度文档索引

| 主题 | 路径 |
|---|---|
| 模块框架与依赖 | `doc/overview/CAT1_MODULE_FRAMEWORK.md` |
| 模块清单 | `doc/overview/LUA_MODULES.md` |
| host_uart / AT | `doc/modules/HOST_UART_AT_DISPATCH.md` |
| 低功耗 PSM | `doc/modules/LOW_POWER_WAKEUP.md` |
| PIR / 录像 | `doc/modules/PIR_CTRL_FLOW.md` |
| MQTT 协议 | `doc/mqtt/MQTT_DOWNLINK.md`、`MQTT_PROTOCOL.md` |
| 配置键索引 | `doc/overview/CONFIG.md`（`_config_key_check.py --write-doc` 生成） |
| 重构计划 | `docs/refactor_plan.md` |
| 逐层重构 | `docs/layer_refactor_plan.md`（L0→L3） |
| 架构体检 | `docs/architecture_audit.md`（含附二 A–I 处置表） |
| 工具链 | `doc/manual/MANUAL_V7_TOOLCHAIN.md` |
| Cursor 规则 | `.cursor/rules/arch-layering.mdc`、`air780ehm-source.mdc`、`refactor-hard-constraints.mdc` |

---

## 11. 决策时间线（摘要）

| 日期 | 里程碑 | VERSION |
|---|---|---|
| 2026-09-04 | P0–P2b 护栏 + 超时单源；第二轮体检 R1–R14 | 155 |
| 2026-09-05 | P3 `uart_session`；P6a/b PSM 单写点；P9/P10；A–I 架构条；rules + agents | **161** |
| 待定 | P10 余 5 项三方接口；G 条真机黄金样本采集 | — |

完整逐条记录 → `doc/overview/USER_LIB_OPTIMIZATION_NEXT.md` §8。
