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

## 2. 现状盘点（2026-09-03 实测刷新）

> **修订**：本节由 08-31 基线更新为 **09-03 实测**（`user/` 58 + `lib/` 15 = 73）。**子模块名仅作语义分组**，真名/计数/行数真源见 [`LUA_MODULES.md`](LUA_MODULES.md) §1.1；行数可用 `python tools/debug/_module_tree.py` 刷新。

### 2.1 规模

| 目录 | `.lua` 文件数 | 总行数 | 说明 |
|------|---------------|--------------|------|
| `user/` | **58** | **13 579** | 业务 + 协议分发（config 编排 + 10 片段计入） |
| `lib/` | **15** | **2 533** | 策略/底层/常驻库 |
| **合计** | **73** | **16 112** | 仅 user/lib 根目录真源 |

### 2.2 两大协议族（user/，合计约 user 行数 62%）

> 下表为 09-03 实测文件清单（主文件行数标注）。**子模块名仅作语义分组**；完整行数与 bind 顺序见 [`LUA_MODULES.md`](LUA_MODULES.md) §1.1，本计划不再二次登记行数以防漂移。

#### host_uart 族（18 文件，主文件 692 行）

```
host_uart.lua (692)          ← 锁 / SYS_EVT / state / RX 行分发 / start / bind 编排
├── hif_cmd.lua (382)        ← AT 应答编排（子模块 bind 顺序固定）
│   ├── hif_cmd_usb.lua      USBRESET/RNDIS/USBRECOVERY
│   ├── hif_cmd_link.lua     P2P/GB28181/MQTT/SERV
│   ├── hif_cmd_pir.lua      HOSTEVT/PIRSTAT
│   ├── hif_cmd_t31x.lua     RECORD/UPLOAD/IPCSTAT NOTIFY
│   └── hif_cmd_wled.lua     WLED
├── hif_rx.lua               URC 行解析编排（cmd 之后 bind）
│   ├── hif_rx_dsl.lua       dsl：云态/TF/录制/IPC 状态行
│   └── hif_rx_media.lua     media：VENC/AUDIO/MIC/FRAMERATE 编码行
├── hif_ipc.lua (379)        ← IPC query/set 公共路径 + 子模块编排
│   ├── hif_ipc_rec.lua      UART 链路恢复 / qryHostStat
│   ├── hif_ipc_hostq.lua    RECORD/MIC/SOFTPHOTO query/set
│   ├── hif_ipc_cloud.lua    IPC 云状态/GB28181
│   ├── hif_ipc_power.lua    IPC 上电/关机/ready
│   ├── hif_ipc_tffmt.lua    TF format
│   └── hif_ipc_encode.lua   编码参数（VENC/AUDIO）
└── hif_at.lua (87)          ← AT_CMD_TABLE 编译（独立于 hif_cmd）
```

#### net_mqtt 族（13 文件，主文件 623 行）

```
net_mqtt.lua (623)           ← mqttTask / pubRaw / notifyPowerOff / DOWNLINK_HANDLERS
├── mqtt_conn.lua (342)      topic/配置/组网/快照（连接外围合一）
├── mqtt_uplink.lua (535)    100x 上行 + 1003 interval
│   ├── mqtt_ul_pir.lua      1010–1012 PIR 上行
│   └── mqtt_ul_upload.lua   1013 上传上行
├── mqtt_downlink.lua (191)  2001–2013 下行总线 + 待 T31x 队列
│   ├── mqtt_dl_ctrl.lua     2004 控制（reboot/off/ota/wled）
│   ├── mqtt_dl_dev.lua      2002 rest / 2003 status / 2006 identity
│   ├── mqtt_dl_pir.lua      2010/2011/2012 PIR
│   ├── mqtt_dl_tf.lua       TF 卡查询与格式化
│   └── mqtt_dl_upload.lua   2013 上传视频下行
├── mqtt_dispatch.lua (110)  下行 JSON 分发 + HOSTEVT/USB 钩子
└── mqtt_hproto.lua (473)    2020–2031 host query/set（经 UART）
```

> 旧名修订（09-03，已停用）：`net_mqtt_downlink*`→`mqtt_dl_*`、`mqtt_uplink_pir/upload`→`mqtt_ul_pir/upload`、`net_mqtt_host_proto`→`mqtt_hproto`、`net_mqtt_dispatch`→`mqtt_dispatch`；`topic/cfg/adapter/snap/hooks` 等连接外围已并入 `mqtt_conn`。

### 2.3 仍偏大但未动刀的 user/ 模块（09-03 实测）

| 文件 | 行数 | 策略 |
|------|------|------|
| `app.lua` | 972 | **冻结**（规则禁止再拆/合） |
| `pir_ctrl.lua` | 722 | 业务闭环，非协议分发，低优先级 |
| `battery_guard.lua` | 391 | 可接受 |
| `t31x_ctrl.lua` | 373 | 可接受 |
| `host_uart.lua` / `net_mqtt.lua` | 692 / 623 | 锁/连接任务冻结在主文件，新 handler 走子模块 |

> config 已于 09-03 前拆为「`config.lua`（26 行编排）+ 10 个片段」，不再作为单体巨石，见 [LUA_MODULES.md](LUA_MODULES.md) §1.1。
> 协议族内最大成品子文件 `mqtt_uplink`(535) / `hif_rx_dsl`(530) / `mqtt_hproto`(473) / `mqtt_conn`(342) 均已按域拆分完成、职责单一，**冻结期内不再拆**（判定同 [ARCHITECTURE_REVIEW_20260903.md](ARCHITECTURE_REVIEW_20260903.md) §2.1）。

### 2.4 lib/ 状态

15 文件、最大 `sys.lua`（394 行）、`cell_boot.lua`（373 行）。`host_event`/`t31x_policy`/`t31x_notify`/`lp_wakeup` 已按业务归属迁回 `user/`（见 [LUA_MODULES.md](LUA_MODULES.md) §1.1）。**无 urgent 拆分需求**；优化重心在 user 协议族与文档/tooling。

### 2.5 已暴露的结构性风险

| 风险 | 实例 | 教训 |
|------|------|------|
| 生成/手工合并导致 **死代码** | `hif_rx.lua` 注册表嵌在 `tryIpcParam` 之后 | 子模块 `return M` / 注册表必须在函数块外；生成脚本需 `\nend\n` 防护 |
| **模块名 shadowing** | `IP_LOSE` 回调参数 `adapter` 遮蔽 `net_mqtt_adapter`（该外围现并入 `mqtt_conn`） | 回调参数用 `ipAdapter` 等前缀，文档写进约束 |
| **bind 顺序依赖** | ipc：`recovery → hostq → cloud → power` | 主文件 bind 顺序即契约，改顺序必跑回归 |
| **文档与代码脱节** | `LUA_MODULES.md` 曾写「19 user 模块」而实际已达 73 | **已治理**（09-03 L1–L3）：以 [`LUA_MODULES.md`](LUA_MODULES.md) §1.1 模块树为唯一真源，行数用 `_module_tree.py` 刷新，禁止手写计数 |

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

| 08-31 候选 | 09-03 状态 | 说明 |
|------|------|------|
| `hif_rx.lua`（649 单体） | ✅ 已拆 | 现为编排壳（69 行）；URC 行解析已分 `hif_rx_dsl.lua`(530) / `hif_rx_media.lua`(275) |
| `net_mqtt_host_proto.lua` | ✅ 已更名 | → `mqtt_hproto.lua`(473)，保持独立（2020–2031） |
| `mqtt_uplink.lua` | 冻结 | 成品 535 行（含 1003 interval），职责单一，不拆 |
| `pir_ctrl.lua` | 冻结 | 业务模块（722 行），非本计划范围 |

**不推荐**：

- 合并 `hif_cmd_pir` + `hif_cmd_t31x` 等（丢失域边界）。  
- 把 `mqtt_dl_*.lua` 并回 `mqtt_downlink.lua`（已按 200x 域拆分，合并反增冲突）。

> P2 为 08-31 候选清单，rx 拆分与 `mqtt_hproto` 更名均已在 09-03 前落地；冻结期内不再新增候选。行数以 `python tools/debug/_module_tree.py` 实测为准，勿沿用本表手写值。

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
    at / rx / cmd_* / ipc_*     mqtt_conn/task↓
                                mqtt_dl_* / mqtt_ul_* / mqtt_hproto
```

- **找 AT/URC**：`hif_at` + `hif_rx` + `hif_cmd_*` + `hif_ipc_*`。  
- **找 200x/100x**：`mqtt_dl_*` / `mqtt_uplink`（+`mqtt_ul_*`） / `mqtt_hproto`。  
- **找连接/重连**：只看 `net_mqtt.lua` + `mqtt_conn.lua`（topic/cfg/adapter/snap 已并入 `mqtt_conn`）。

### 6.2 命名约定（保持）

| 前缀 | 含义 |
|------|------|
| `hif_cmd_*` | T31x **通知/设置** 类 AT（HOST→CAT1 方向为主） |
| `hif_ipc_*` | **查询/云状态/TF/编码/上电** 等 IPC 交互 |
| `hif_rx_dsl_*` / `hif_rx_media_*` | URC 行解析（已按 dsl/media 拆分） |
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
| 下一刀砍谁？ | rx 拆分（`rx_dsl`/`rx_media`）已于 09-03 前完成；冻结期无候选 |
| app/config/pir 呢？ | app 冻结；config 已拆片段；pir 低优先级 |
| lib 呢？ | 维持 15 文件，无拆分计划 |
| Flash 优化？ | 不靠减文件；见 `CODE_SIZE_OPTIMIZATION.md` |
| VERSION？ | 纯重构/doc/tool **不升**；行为 fix 单独升 patch |
| 工具收工？ | **是**（2026-08-31）：静态回归 + bind 头 + 行数基线 + smoke 脚本 |
| 实机阻塞？ | 当前无 COM 口；MQTT 862323084068231 无应答 — 接 USB 后跑 `_protocol_smoke.py` |

---

## 10. 相关文档

| 文档 | 关系 |
|------|------|
| [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md) | 历史拆分账本与 camelCase |
| [LUA_MODULES.md](LUA_MODULES.md) | **09-03 已重写**为模块树（user 58 + lib 15 = 73） |
| [modules/README.md](modules/README.md) | **09-03 已更新**子模块索引（对齐真实文件名） |
| [HOST_UART_AT_DISPATCH.md](modules/HOST_UART_AT_DISPATCH.md) | AT/URC 真源 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](modules/NET_MQTT_DOWNLINK_DISPATCH.md) | 下行分发 + `ipAdapter` 约束 |
| [CODE_SIZE_OPTIMIZATION.md](CODE_SIZE_OPTIMIZATION.md) | Flash 体积（与文件数正交） |

---

*本计划书描述「拆分后如何养」；具体某刀的 diff 仍记入 `USER_LIB_OPTIMIZATION_NEXT.md` 账本表。*
