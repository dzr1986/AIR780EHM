# 合宙 Cat.1 项目开发系统手册（doc/manual）

> **定位**：面向 **780EHM_PJ（Air780EHM LuatOS Cat.1 + T31x IPC）项目维护者**的开发系统手册。
> **读者**：改 `user/`、`lib/` 代码、做协议联调、查异常、跑产测/发布的人。
> **形态**：把 `doc/` 主题真源按**开发任务**重组为 7 卷；每卷内嵌**自包含速查表**，日常直查，不再翻目录。
> **更新**：2026-09-04 首版汇编；同日 v2 增补「§4 文档体系架构 / §5 使用路径与反向路由」。登记护栏：`python doc/_tools/doc_registry_check.py`（本目录已纳入主题检查）

---

## 0. 真源与维护约定（先读）

本手册是**「导航 + 速查汇编」**，不是新的真源：

1. **不移动、不删除**任何现有文档；主题真源保持唯一（`overview/` `mqtt/` `t31x/` `power/` `pir/` `modules/` `hardware/` `release/`）。
2. 每卷中每个速查块都标注 **真源**；**数值/字段/行为冲突一律以真源与代码为准**（代码 > 专题真源 > 手册速查）。
3. 手册速查的维护方式：**上游真源变更时，同步刷新本卷对应速查表**；禁止只改手册不修真源（会制造假真源）。
4. 新增知识仍写入**主题真源**，需要时在对应卷加「速查 + 链接」，不要在手册里展开大段协议正文。

### 速查块的两种粒度

| 标记 | 含义 | 何时用 |
|------|------|--------|
| `🟢 自包含` | 表已完整收编真源关键列，可直接当参考 | 高频查表（命令、常量、字段对照） |
| `🔗 指针` | 只给定位与路径，细节去真源 | 低频/易变的深链路（流程时序、排障案例） |

---

## 1. 卷清单

| 卷 | 文件 | 内容 | 典型场景 |
|----|------|------|----------|
| V1 | [MANUAL_V1_SYSTEM.md](MANUAL_V1_SYSTEM.md) | 系统与固件：双芯片架构、代码分层、启动顺序、配置索引、版本产物 | 进项目、理清"谁调谁"、找模块 |
| V2 | [MANUAL_V2_LUA_API.md](MANUAL_V2_LUA_API.md) | Lua API 与模块开发：命名真源、模块树、事件总线、config 片段、日志 | 改 Lua、新增模块、事件/命名审查 |
| V3 | [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) | MQTT 云协议：Topic、200x↔100x 对照、命令速查、上行事件 | 平台联调、上下行排障、加协议字段 |
| V4 | [MANUAL_V4_T31X.md](MANUAL_V4_T31X.md) | T31x 协同与 IPC：UART/AT 指令、HOSTEVT、唤醒链、IPC 监督与 alertCode | T31x 不听话、AT 交互、IPC 异常 |
| V5 | [MANUAL_V5_POWER.md](MANUAL_V5_POWER.md) | 电源电池低功耗：电量档位、rest/HOSTIDLE、T31x 供电链、USB、关机 | 耗电、误关机、不进低功耗 |
| V6 | [MANUAL_V6_PIR.md](MANUAL_V6_PIR.md) | PIR 与录像会话：触发/冷却、2010–2012↔1010–1012、提示音、TF | PIR 不录/漏录/多录、提示音不对 |
| V7 | [MANUAL_V7_TOOLCHAIN.md](MANUAL_V7_TOOLCHAIN.md) | 产测烧录发布：工具链清单、烧录流程、打包量产、文档护栏 | 烧录、量产、跑护栏、发版 |

---

## 2. 任务 → 卷 速查

| 我现在要… | 去卷 | 第一站（真源） |
|-----------|------|----------------|
| 刚接手，想 1 小时内看懂系统 | V1 → V2 | [SYSTEM_ARCHITECTURE](../overview/SYSTEM_ARCHITECTURE.md) |
| 想按「设备正在做什么」顺着查：这一步为什么没发生、被哪个门禁拦了 | 先看工作流图再进卷 | [TECH_WORKFLOWS](../overview/TECH_WORKFLOWS.md)（W1–W10 每步给模块.函数 / 门禁 / 观测点） |
| 想知道固件有哪些模块、谁负责什么 | V1/V2 | [LUA_MODULES §1.1](../overview/LUA_MODULES.md) |
| 要给固件加一个 Lua 功能/模块 | V2 | [CAT1_API_NAMING](../overview/CAT1_API_NAMING.md) + [modules](../modules/README.md) |
| 平台要新加一条 MQTT 下行命令 | V3 | [MQTT_PROTOCOL §4](../mqtt/MQTT_PROTOCOL.md) + [MQTT_DOWNLINK](../mqtt/MQTT_DOWNLINK.md) |
| 设备没上线上报 1003，怎么查 | V3/V5 | [MQTT_PROTOCOL §3](../mqtt/MQTT_PROTOCOL.md) + [T31X_LOW_POWER](../power/T31X_LOW_POWER.md) |
| T31x 不响应 AT / 唤醒失败 | V4 | [T31X_4G_AT_INTERACTION](../t31x/T31X_4G_AT_INTERACTION.md) + [T31X_POWER_WAKEUP](../modules/T31X_POWER_WAKEUP.md) |
| IPC 异常上报/alertCode 含义 | V4 | [T31X_IPC_ALERT_CONTRACT](../t31x/T31X_IPC_ALERT_CONTRACT.md) |
| 设备耗电快 / 不进入低功耗 | V5 | [LOW_BATTERY_AND_LOW_POWER](../power/LOW_BATTERY_AND_LOW_POWER.md) |
| PIR 触发但不录像 / 缺录 | V6 | [PIR_CTRL_FLOW](../modules/PIR_CTRL_FLOW.md) |
| 烧录固件 / 产线量产 | V7 | [CAT1_FLASH_FLOW](../release/CAT1_FLASH_FLOW.md) |
| 改完代码跑文档护栏 | V7 | [MANUAL_V7_TOOLCHAIN §6](MANUAL_V7_TOOLCHAIN.md) |
| 文档里 API 名过时了 | V7 | `tools/sync_doc_naming.py`（[CAT1_API_NAMING §4](../overview/CAT1_API_NAMING.md)） |

---

## 3. 相关总览入口（卷外）

- 顶层文档索引：[doc/README.md](../README.md)（唯一入口）
- 系统级总览（新读者首选）：[overview/SYSTEM_ARCHITECTURE.md](../overview/SYSTEM_ARCHITECTURE.md)
- 技术工作流总图（运行时视角，与本手册同层互补）：[overview/TECH_WORKFLOWS.md](../overview/TECH_WORKFLOWS.md)
- 代码真源：仓库根 `user/`、`lib/`；不要在 `LuaTools/userprojs/` 副本里改代码。
- 本仓库其它工程：`http_server/` `ota_server/` `patch_server/` `video_upload_server/` 各自 `README`/`docs`（跨仓库链接见 [doc/README 外部工程相关文档](../README.md)）。

---

## 4. 文档体系架构（为什么这么组织）

这套文档本身被当成一个**系统**设计：需求驱动（读者只有"维护者/联调者"两类核心角色）→ 分四层隔离"导航 / 汇编 / 真源 / 代码"→ 用质量属性对应护栏防止漂移。理解分层后，新增文档放哪、改了什么该回写哪里都按 §4.3 与 §5 判断即可。

### 4.1 分层与真源权（L0–L3）

```text
L0 入口登记   doc/README.md ─── 唯一入口；登记 doc/ 全部主题 md（登记护栏管辖）
        │  ▼
L1 任务汇编   doc/manual/（本页任务矩阵 + MANUAL_V1…V7）+ overview/TECH_WORKFLOWS（运行时工作流）─── 速查汇编层，无真源权
        │  ▼
L2 主题真源   overview/ mqtt/ t31x/ power/ pir/ modules/ hardware/ release/ _audit/
        │  ▼            （每份知识唯一真源；冲突判据：代码 > 专题真源 > 手册速查）
L3 代码与工具  user/ lib/（固件代码，最高权威）· tools/ doc/_tools/（护栏与工具）
```

| 层 | 收录 | 真源权 | 写入入口 | 关键护栏 |
|----|------|--------|----------|----------|
| L0 | 目录/索引/登记 | 无（纯导航） | doc/README | `doc_registry_check` |
| L1 | 任务化速查与定位 | 无（汇编，标注真源） | 本页 §1 各卷 | `_doc_md_link_check` + §0 约定 3–4 |
| L2 | 知识本体（含观测台账） | **是** | 对应主题目录 | 登记护栏；`sync_doc_naming`（API 名） |
| L3 | 代码、可执行工具 | 最高（行为以代码为准） | `user/` `lib/` `tools/` | `_*_regression_check`、`run_all_checks` |

### 4.2 质量属性 → 机制 → 护栏

| 质量属性 | 本体系采用的机制 | 护栏 / 检查 |
|----------|------------------|-------------|
| **可寻性**（≤3 跳） | 顶层入口 → 任务矩阵（§2）→ 卷内 `🟢 自包含` 速查；每卷 header 有「手册链路」反链 | `_doc_md_link_check`（断链即失败）；登记护栏 |
| **防漂移** | 真源唯一（§0 判据）；速查分 `🟢 自包含`（收编关键列）与 `🔗 指针`（只定位）两档 | 自包含表对照真源抽查（[MANUAL_V7 §5](MANUAL_V7_TOOLCHAIN.md)）；改 API 跑 `sync_doc_naming` |
| **可演进**（低成本加内容） | §4.3 决策：先真源、后速查、阈值才开卷 | 新增文件受登记 + 互链双护栏覆盖 |
| **可观测** | 每轮文档维护追加 [doc/_audit/DOC_HEALTH_REPORT_20260904](../_audit/DOC_HEALTH_REPORT_20260904.md) | 归档（daily.md）人工核对 |
| **单一写入权** | 每份知识只有一个"真源位置 + 一个代码实现"；手册不二次展开协议正文（§0 约定 4） | 同上防漂移护栏 |

### 4.3 演进决策（新增知识放哪）

| 场景 | 放哪 | 例 |
|------|------|----|
| 新观测 / 单日闭环记录 | `_audit/` 或主题观测 md，并登记 | `MQTT_1003_STATUS_PATTERN` |
| 新稳定知识（架构/协议/机制） | **主题真源**（L2），不写进手册正文 | alertCode 契约 → `t31x/` |
| 现卷速查缺一块高频表 | 在对应 `MANUAL_Vn` 加一行速查（标注真源） | 2002 exit/enter 表格化 |
| 全新开发域、跨 3+ 卷反复引用 | 开新 `MANUAL_` 卷 + 登记 + §1 卷清单登记 | （如新增"车载模式"再评估） |
| 只改了真源 | **同步刷新手册对应速查**（防漂移责任在手册侧） | 协议加字段 → V3 |

---

## 5. 使用路径与反向路由

### 5.1 读者路径

| 你是… | 路径 |
|--------|------|
| 新进维护者（<1h 建立全局） | [doc/README](../README.md) → [V1_SYSTEM](MANUAL_V1_SYSTEM.md)（三十秒速览）→ 按 §2 任务矩阵进入 |
| 改 Lua / 加模块 | [V2_LUA_API](MANUAL_V2_LUA_API.md)（命名/模块树/自检清单）→ 改完按 §5.2 回写 |
| 平台对接 / 协议联调 | [V3_MQTT](MANUAL_V3_MQTT.md) → 真源 [MQTT_PROTOCOL](../mqtt/MQTT_PROTOCOL.md) |
| T31x / 功耗 / 硬件排障 | [V4_T31X](MANUAL_V4_T31X.md) · [V5_POWER](MANUAL_V5_POWER.md) · [V6_PIR](MANUAL_V6_PIR.md) |
| 产测 / 烧录 / 发版 | [V7_TOOLCHAIN](MANUAL_V7_TOOLCHAIN.md) |
| 文档维护者 | [V7 §5](MANUAL_V7_TOOLCHAIN.md)（护栏与同步）→ §4 本页 |

### 5.2 反向路由：改了什么 → 回写哪里

> 改代码/协议后**不只改手册**：真源与手册同改，再跑护栏。判据仍见 §0 约定 2（代码 > 专题真源 > 手册速查）。

| 我改了… | 回写手册 | 回写主题真源（第一站） | 工具 / 护栏 |
|---------|----------|------------------------|-------------|
| `user/`/`lib/` 模块或导出函数 | V2（命名/模块树/族表） | [CAT1_API_NAMING](../overview/CAT1_API_NAMING.md) · [LUA_MODULES](../overview/LUA_MODULES.md) | `sync_doc_naming.py`；`_host_uart`/`_net_mqtt` regression |
| 事件总线/事件常量 | V2 §4 | `user/events.lua` · [APP_EVENT_BUS](../modules/APP_EVENT_BUS.md) | — |
| 配置片段 / 配置键 | V1 §5 + 相关卷 | [CONFIG](../overview/CONFIG.md) · `config.lua` | — |
| MQTT 命令 / 字段 / 周期 | V3（对照表/上行） | [MQTT_PROTOCOL](../mqtt/MQTT_PROTOCOL.md) · [MQTT_DOWNLINK](../mqtt/MQTT_DOWNLINK.md) · [PIR_PROTOCOL](../pir/PIR_PROTOCOL.md) | `_protocol_regression_check.py` |
| T31x AT / UART 交互 | V4 §3 | [T31X_4G_AT_INTERACTION](../t31x/T31X_4G_AT_INTERACTION.md) · [UART_AT_COMMANDS](../mqtt/UART_AT_COMMANDS.md) | `_host_uart_regression_check.py` |
| 低功耗 / USB / 关机行为 | V5 | `power/` 主题（[LOW_BATTERY_AND_LOW_POWER](../power/LOW_BATTERY_AND_LOW_POWER.md) 等） | — |
| PIR / 录像 / 提示音 | V6 | `pir/` 主题 · [PIR_CTRL_FLOW](../modules/PIR_CTRL_FLOW.md) | — |
| 版本号 / 发布产物 | V1 §6 + V7 | `user/main.lua` `VERSION` · `RELEASE_*` | `pack_mass_prod.py` |
| 护栏/工具脚本 | V7 | `tools/README.md` | `run_all_checks.py` |
