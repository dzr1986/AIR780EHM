# user/lib 框架优化计划书（拆分后治理版）

> **日期**：2026-08-31  
> **VERSION 基线**：`001.000.140`（`user/main.lua`）  
> **前置账本**：[USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)（命名/camelCase 与逐刀拆分记录）  
> **硬约束真源**：`.cursor/rules/air780ehm-source.mdc`

---

## 1. 背景与问题

经过多轮拆分，`host_uart` / `net_mqtt` 已从「单文件巨石」变为 **协议族 + 主文件编排** 结构。收益是单文件可读性、顶层 local 压力下降；代价是 **文件数激增、文档滞后、bind 样板重复、跨子模块顺序敏感**。

本计划书回答：**在不再拆 `app`、不把连接任务/锁迁出主文件的前提下，如何治理「文件过多」带来的维护成本**，而不是继续无节制裂变或粗暴合并回主文件。

---

## 2. 现状盘点（2026-08-31 统计）

### 2.1 规模

| 目录 | `.lua` 文件数 | 总行数（约） | 说明 |
|------|---------------|--------------|------|
| `user/` | **50** | **12 273** | 业务 + 协议分发 |
| `lib/` | **17** | **2 586** | 策略/底层/常驻库 |
| **合计** | **67** | **~14 859** | 仅根目录真源 |

### 2.2 两大协议族（占 user 行数 ~55%）

#### host_uart 族（16 文件，~4 900 行）

```
host_uart.lua              657   ← 锁 / SYS_EVT / state / RX 入口 / bind 编排
hif_at.lua            81
hif_rx.lua           649   ← 最大子文件，URC 行分发
hif_cmd.lua          327
  hif_cmd_pir.lua    111
  hif_cmd_t31x.lua    209
  hif_cmd_link.lua   230
  hif_cmd_wled.lua   169
  hif_cmd_usb.lua    269
hif_ipc.lua          348
  hif_ipc_cloud.lua      296
  hif_ipc_recovery.lua   155
  hif_ipc_power.lua      145
  hif_ipc_hostq.lua      275
  hif_ipc_tffmt.lua      109
  hif_ipc_encode.lua     182
```

#### net_mqtt 族（18 文件，~3 400 行）

```
net_mqtt.lua               574   ← mqttTask / pubRaw / notifyPowerOff / 连接状态
net_mqtt_topic.lua          99
net_mqtt_cfg.lua            71
net_mqtt_bootstrap.lua      58
net_mqtt_adapter.lua        55
net_mqtt_snap.lua           83
net_mqtt_dispatch.lua       64
net_mqtt_hooks.lua          45
mqtt_uplink.lua       493  (+1003 interval，原 stat 153 行)
net_mqtt_downlink.lua       222
  net_mqtt_downlink_pir.lua      257
  net_mqtt_downlink_ctrl.lua     183
  net_mqtt_downlink_upload.lua   113
  net_mqtt_downlink_tf.lua       122
  net_mqtt_downlink_identity.lua  (小)
mqtt_uplink.lua         345
  mqtt_uplink_pir.lua        162
  mqtt_uplink_upload.lua     152
net_mqtt_host_proto.lua     432
```

### 2.3 仍偏大但未动刀的 user 模块

| 文件 | 行数 | 策略 |
|------|------|------|
| `app.lua` | 945 | **冻结**（规则禁止再拆/合） |
| `config.lua` | 681 | 配置表聚合，暂不动 |
| `pir_ctrl.lua` | 656 | 业务闭环，非协议分发，低优先级 |
| `battery_guard.lua` | 391 | 可接受 |
| `t31x_ctrl.lua` | 373 | 可接受 |

### 2.4 lib/ 状态

17 文件、最大 `sys.lua`（394 行）、`cellular_bootstrap.lua`（373 行）。**无 urgent 拆分需求**；优化重心在 user 协议族与文档/tooling。

### 2.5 已暴露的结构性风险

| 风险 | 实例 | 教训 |
|------|------|------|
| 生成/手工合并导致 **死代码** | `hif_rx.lua` 注册表嵌在 `tryIpcParam` 之后 | 子模块 `return M` / 注册表必须在函数块外；生成脚本需 `\nend\n` 防护 |
| **模块名 shadowing** | `IP_LOSE` 回调参数 `adapter` 遮蔽 `net_mqtt_adapter` | 回调参数用 `ipAdapter` 等前缀，文档写进约束 |
| **bind 顺序依赖** | ipc：`recovery → hostq → cloud → power` | 主文件 bind 顺序即契约，改顺序必跑回归 |
| **文档与代码脱节** | `LUA_MODULES.md` 仍写「19 user 模块」 | 需模块树索引，而非继续堆「+N 模块」叙述 |

---

## 3. 优化目标（可衡量）

| 维度 | 目标 | 不做 |
|------|------|------|
| **可读性** | 新人 15 分钟内从 `LUA_MODULES.md` 找到任意 handler 所在文件 | 为减文件数合并已拆 cmd/ipc 子模块 |
| **稳定性** | 纯重构不升 VERSION；行为 fix 单独记版本 | 动 `mqttTask` / `host_uart` 锁与 `SYS_EVT` 归属 |
| **Flash** | 拆分 **不** 以减字节为目标（Luat 按模块加载，文件数本身不增 Flash） | 为 Flash 再拆协议体或合并 handler |
| **回归成本** | 每次动协议族：静态脚本 + 约定 smoke 项 | 全量 200x/AT 手工测一遍 |
| **顶层 local** | `host_uart.lua` 顶层 local **≤ 200**（Luat 硬限制） | 往主文件回填已迁出 handler |

---

## 4. 设计原则（拆分后治理）

1. **主文件 = 编排 + 不可迁移内核**  
   - `host_uart.lua`：互斥锁、`SYS_EVT`、`state`、RX 入口、子模块 `bind` 顺序。  
   - `net_mqtt.lua`：`mqttTask`、`pubRaw`、`notifyPowerOff`、连接生命周期。

2. **子模块 = 按边界拆，不按行数机械拆**  
   - 合格边界：协议域（PIR / TF / cloud / encode）、连接外围（topic/cfg/bootstrap）、上下行 cmd 号段。  
   - **停止条件**：单文件 &lt; 500 行且职责单一 → **不再拆**。

3. **禁止合并回主文件**（除非 Luat 加载/Flash 实测证明必须，当前无证据）。

4. **禁止继续拆 `app`**；`APP_RUNTIME` 只经 `lib/runtime_power.lua` 访问。

5. **子模块通信**：经 `ctx` / 共享表 `H` bind 注入；**禁止**子模块 `require "host_uart"` / `require "net_mqtt"`。

6. **命名约束**：与模块表同名的回调参数必须加前缀（如 `ipAdapter`）。

---

## 5. 优化方向与优先级

### P0 — 文档与索引（低成本、立刻做）

**问题**：文件 50+，但 `LUA_MODULES.md` / `doc/modules/README.md` 仍按「19 模块时代」描述，维护者找不到 handler。

**动作**：

| # | 任务 | 产出 |
|---|------|------|
| P0-1 | 重写 `doc/LUA_MODULES.md` §2 为 **模块树**（host_uart / net_mqtt 子树 + 其余 user 一览） | 单页全景 |
| P0-2 | `doc/modules/README.md` 增加 **子模块索引表**（文件名 → 职责 → 专题 doc 链接） | 与 P0-1 互链 |
| P0-3 | `doc/CALL_GRAPH.md` 补充 bind 顺序：`hif_ipc_*`、`net_mqtt_*` 加载链 | 防顺序回归 |
| P0-4 | `HOST_UART_AT_DISPATCH.md` / `NET_MQTT_DOWNLINK_DISPATCH.md` 各加 **文件→注册表** 对照 | 改 handler 前必查 |

**验收**：任意 200x / AT 命令名，在文档中 **≤2 次点击** 定位到 `.lua` 文件。

---

### P1 — 工具与回归口径（防再犯）

| # | 任务 | 说明 |
|---|------|------|
| P1-1 | 保留并 CI 化 `tools/debug/_net_mqtt_regression_check.py` | 已 17/17；可加 `--strict` |
| P1-2 | 新增 `tools/debug/_host_uart_regression_check.py` | 检查：各 `*.bind` 存在、`RX_LINE_HANDLER_REGISTRY` 在模块顶层、`return M` 可达 |
| P1-3 | 生成脚本 `_gen_host_uart_*` 统一后处理：强制 trailing `end` + 注册表不在函数内 | 避免 rx 类 bug |
| P1-4 | 可选：`tools/debug/_module_tree.py` 输出 user 行数树（本计划 §2 自动化） | 发布前 diff |

**验收**：改 host_uart/net_mqtt 任意子文件后，两条静态脚本均通过。

---

### P2 — 代码结构微调（可选、单点动刀）

**原则**：仅当单文件 **&gt; 500 行** 且边界清晰；**一次只动一刀**。

| 候选 | 行数 | 建议 | 风险 |
|------|------|------|------|
| `hif_rx.lua` | 649 | 迁 **encode/framerate/mic try\*** 段 → `hif_rx_media.lua` | 中：URC 注册表分散 |
| `net_mqtt_host_proto.lua` | 432 | **暂不动**（2020–2031 已独立） | — |
| `mqtt_uplink.lua` | 345 | **暂不动** | — |
| `pir_ctrl.lua` | 656 | 业务模块，非本计划范围 | — |

**不推荐**：

- 合并 `hif_cmd_pir` + `hif_cmd_t31x` 等（丢失域边界）。  
- 把 `net_mqtt_downlink_*.lua` 并回 `downlink.lua`（已按 200x 域拆分，合并反增冲突）。

**若执行 P2-1（rx_media）**：

1. 主文件 `host_uart.lua` 增加 `rx_media.bind(ctx)`，顺序在 `rx.bind` 之后或合并注册。  
2. 更新 `HOST_UART_AT_DISPATCH.md`。  
3. 跑 P1-2 + 实机 AT encode/mic 冒烟。

---

### P3 — bind 样板与 ctx 头 ✅

| # | 任务 | 状态 |
|---|------|------|
| P3-1 | `tools/debug/_gen_bind_header.py` + `bind_header_specs.json` | **完成** |
| P3-2 | 延迟挂载 wrapper 约定写入专题 doc | **完成** |

```bash
python tools/debug/_gen_bind_header.py --check-all          # 11 子模块 drift 校验
python tools/debug/_gen_bind_header.py --emit hif_cmd_pir.lua
python tools/debug/_gen_bind_header.py --scan user/hif_cmd_link.lua
```

**约定**：`parseIpcStat` / `parseTfCard` / `hostQuery` / `idCfg` / `pushUsbIdle` 等 ctx 上 **晚于 rx.bind 才赋值** 的字段，子模块必须用 `local function foo(...) return C.foo(...) end`，**禁止** `local foo = C.foo` 快照。

---

### P4 — lib/ 与业务模块（低优先级）

| 模块 | 动作 |
|------|------|
| `lib/sys.lua` | 仅 bugfix，不拆 |
| `config.lua` | 可按域拆 JSON 加载器 **仅当** 行数 &gt; 800 且改配置频繁 |
| `app.lua` | **零拆分** |

---

## 6. 文件治理策略（「多文件」怎么读）

### 6.1 推荐心智模型

```
main.lua → app.lua → module_loader
                          ↓
              ┌───────────┴───────────┐
         host_uart 族            net_mqtt 族
         (T31x 串口)               (云端 MQTT)
              ↓                        ↓
    at / rx / cmd_* / ipc_*     topic/cfg/task↓
                                downlink_* / uplink_* / host_proto
```

- **找 AT/URC**：`hif_at` + `hif_rx` + `hif_cmd_*` + `hif_ipc_*`。  
- **找 200x/100x**：`net_mqtt_downlink*` / `mqtt_uplink*` / `net_mqtt_host_proto`。  
- **找连接/重连**：只看 `net_mqtt.lua` + `net_mqtt_bootstrap` + `net_mqtt_adapter`。

### 6.2 命名约定（保持）

| 前缀 | 含义 |
|------|------|
| `hif_cmd_*` | T31x **通知/设置** 类 AT（HOST→CAT1 方向为主） |
| `hif_ipc_*` | **查询/云状态/TF/编码/上电** 等 IPC 交互 |
| `hif_rx_*` | （若拆）纯 URC 行解析 |
| `net_mqtt_downlink_*` | 云端 **下行** 200x 域 |
| `mqtt_uplink_*` | 设备 **上行** 100x 域 |
| `net_mqtt_*` 短名 | 连接外围（topic/cfg/stat/hooks），**不含** cmd handler |

### 6.3 何时允许新增文件

满足 **全部** 条件才可新增子模块：

1. 现有文件 **&gt; 500 行** 或顶层 local 逼近 200；  
2. 新文件有 **单一协议域或生命周期**（非「再拆 200 行」）；  
3. 同步更新 P0 文档 + P1 静态检查；  
4. PR/提交说明 bind 顺序与回归项。

---

## 7. 执行路线图

| 阶段 | 时间盒 | 内容 | VERSION |
|------|--------|------|---------|
| **阶段 A** | 1–2 天 | P0 文档全套 + `_module_tree.py` | 不升 | **完成** |
| **阶段 B** | 1 天 | P1 静态检查 + 生成脚本加固 | 不升 | **完成** |
| **阶段 C** | 冻结 2 周 | **零新拆分**；仅 bugfix；静态脚本必跑 | 按行为 | **进行中** |
| **阶段 D** | ✅ | P2-1 `hif_rx`→`rx_dsl`+`rx_media` | 不升（纯迁） |
| **阶段 E** | 长期 | P3 bind 头生成器；`config` 仅在 &gt;800 行再评估 | 不升 | **P3 完成** |

```mermaid
flowchart LR
  A[P0 文档索引] --> B[P1 静态回归]
  B --> C[冻结观察期]
  C --> D{rx > 650?}
  D -->|是| E[P2 rx_media]
  D -->|否| F[维持现状]
  E --> F
```

---

## 8. 回归清单（协议族改动必做）

### 8.1 静态（每次提交）

```bash
python tools/debug/_protocol_regression_check.py   # 推荐：host_uart + net_mqtt 一次跑完
python tools/debug/_net_mqtt_regression_check.py
python tools/debug/_host_uart_regression_check.py
python tools/debug/_module_tree.py                  # 可选，对比行数漂移
```

### 8.2 实机 smoke（合并前 / 发版前）

```bash
python tools/debug/_protocol_smoke.py                    # 静态 + USB 日志 + MQTT 2001/2003/2005
python tools/debug/_protocol_smoke.py --skip-static      # 仅实机部分
python tools/debug/_protocol_smoke.py --imei 862323084068124   # 换 IMEI
python tools/debug/_mqtt_ip_lose_closed_loop.py --skip-flash --mqtt --log-sec 90
python tools/debug/_run_mqtt_autotest_params.py          # 全量 safe/extra（慢）
```

报告输出：`tools/debug/_protocol_smoke_report.txt`

| 域 | 项 |
|----|-----|
| 静态 | `_protocol_regression_check.py`（含 bind header 11 项） |
| USB 日志 | `mqtt_conack`、`HOST_UART_FIRST_AT`、`host_dl_drain` |
| MQTT | 2001→1001、2003→1003、2005→1005 |
| host_uart | `AT+HOSTEVT`、encode 查询、IPC 上电/关机、TF format |
| 闭环 | `_mqtt_ip_lose_closed_loop.py`（有 COM 口时） |

### 8.3 烧录

```bash
python tools/gui/flash/cat1_flash.py flash-script
```

---

## 9. 决策摘要（给 Reviewer 的一页纸）

| 问题 | 决策 |
|------|------|
| 文件太多要不要合并？ | **不合并**；用文档树 + 静态检查治理 |
| 还要不要继续拆？ | **默认冻结**；仅 &gt;500 行且边界清晰时单点动刀 |
| 下一刀砍谁？ | 唯一候选：`hif_rx.lua` → `rx_media`（可选） |
| app/config/pir 呢？ | app 冻结；其余低优先级 |
| lib 呢？ | 维持 17 文件，无拆分计划 |
| Flash 优化？ | 不靠减文件；见 `CODE_SIZE_OPTIMIZATION.md` |
| VERSION？ | 纯重构/doc/tool **不升**；行为 fix 单独升 patch |
| 工具收工？ | **是**（2026-08-31）：静态回归 + bind 头 + 行数基线 + smoke 脚本 |
| 实机阻塞？ | 当前无 COM 口；MQTT 862323084068231 无应答 — 接 USB 后跑 `_protocol_smoke.py` |

---

## 10. 相关文档

| 文档 | 关系 |
|------|------|
| [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md) | 历史拆分账本与 camelCase |
| [LUA_MODULES.md](LUA_MODULES.md) | **待 P0 更新** 为模块树 |
| [modules/README.md](modules/README.md) | **待 P0 更新** 子模块索引 |
| [HOST_UART_AT_DISPATCH.md](modules/HOST_UART_AT_DISPATCH.md) | AT/URC 真源 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](modules/NET_MQTT_DOWNLINK_DISPATCH.md) | 下行分发 + `ipAdapter` 约束 |
| [CODE_SIZE_OPTIMIZATION.md](CODE_SIZE_OPTIMIZATION.md) | Flash 体积（与文件数正交） |

---

*本计划书描述「拆分后如何养」；具体某刀的 diff 仍记入 `USER_LIB_OPTIMIZATION_NEXT.md` 账本表。*
