# 代码架构体检报告与四主题裁决（2026-09-03）

> **结论先行**：工程代码架构主体已处于**收敛期**（2026-08-31 治理计划的"冻结观察期"内，至约 09-14）。
> 体检发现：**不存在必须立即动的架构问题**；真正的缺口是**文档-代码漂移**与**待冻结期后解锁的两项可选重构**。
> 你勾选的四个优化方向中，**两项被仓库硬约束明令禁止**（详见 §4 裁决表），报告给出各自的解锁条件与替代建议。

---

## 1. 本次"优化"所依据的约束真源（必须先满足）

| 约束文件 | 与本任务直接相关的条款 |
|---|---|
| `.cursor/rules/air780ehm-source.mdc`（alwaysApply） | ① 只改仓库根 `user/`、`lib/`；② **不要合并、不要再拆 `app`**；③ `host_uart`/`net_mqtt` 已拆完，锁/`SYS_EVT`/连接任务留在主文件；④ `_G.xxx=` 写入仅限 `config.lua` / `main.lua` 平台约定 |
| `.cursor/rules/lua-luatos.mdc` | ① 模块保持合宙惯例 `module(_modname, package.seeall)` + `_G[_modname] = _M`，**不要改成 `local M = {}` / metatable OOP**；② 内部状态用 `local`，声明先于使用；③ 公开接口沿用 `is/get/set/start/stop` |
| `doc/USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md`（2026-08-31） | P4：`app.lua` **零拆分**；§6.3 新增子模块需四条件全满足；§7 阶段 C = 冻结 2 周（**进行中**） |

> 注：以上是工程历次会话固化的规则与计划。它们**不禁止**体检与文档治理，只限制了"怎么改代码"。

---

## 2. 现状基线（本次实测，非文档口径）

| 口径 | 实测（2026-09-03） | 文档口径 | 漂移 |
|---|---|---|---|
| `user/*.lua` 文件数 | **58** | 50（8-31 计划） | +8 |
| `lib/*.lua` 文件数 | **15** | 17 | −2 |
| 真源合计 | **73** | 67 | +6 |
| `user/` 总行数 | 13 579 | ~12 273 | +1 306 |
| `lib/` 总行数 | 2 533 | ~2 586 | −53 |
| 工作区在途改动 | `user/hif_cmd_usb.lua`（USBRESET 本地复位 ok 分支，功能改动） | — | 勿被重构覆盖 |
| 当前 `VERSION` | `001.000.151`（`user/main.lua`） | — | 有行为改动须升 patch |

### 2.1 模块规模分布（user + lib，>400 行才列出）

```
app.lua 972 · pir_ctrl 722 · host_uart 692 · net_mqtt 623 · mqtt_uplink 535
hif_rx_dsl 530 · mqtt_hproto 473 · battery_guard 391 · lib/sys 394
hif_cmd 382 · hif_ipc 379 · lib/cell_boot 373 · t31x_ctrl 373 · mqtt_conn 342
hif_ipc_hostq 339 · mqtt_dl_pir 321 · lib/usb_rndis 311 · hif_ipc_cloud 307
```

对照 8-31 计划的"停止条件（>500 行且职责单一才评估）"：
- `app`：规则禁止拆分 → 维持。
- `host_uart` / `net_mqtt`（主文件 692 / 623）：规则禁止再拆连接任务/锁 → 维持；新 handler 走子模块。
- `pir_ctrl`（722）：业务闭环、无协议分发边界 → 与计划一致**维持**（如需动，须先解锁冻结并新增 `APP_PIR_CONFIG` 之外更细边界）。
- `mqtt_uplink` / `mqtt_hproto` / `hif_rx_dsl`：已按域拆分后的成品，不再动。

### 2.2 模块命名/引用一致性（重点体检项）

对 8-31 计划与 `LUA_MODULES.md` 中出现的模块名逐一对照实际文件：

| 文档中的名字 | 实际文件 | 结论 |
|---|---|---|
| `app_config` / `key_config` | 不存在（已并入 config 片段） | 文档过期 |
| `ipc_supervision` / `ipc_alert_contract` | 实际为 `ipc_supv` / `t31x_notify` 等 | 文档过期 |
| `low_power_wakeup` | 实际为 `lp_wakeup` | 文档过期 |
| `usb_policy` / `cellular_bootstrap` / `net_mqtt_topic` 等 17 个外围 | 均已并入 `mqtt_conn` / `cell_boot` 等 | 文档过期（8-31 计划 §2 的树是"当时期望"而非现值） |
| `require "..."` 对上述名字的引用 | 全库 **0 处** | 无死代码/无运行期风险 |

> 结论：**文档滞后于代码（方向相反），代码内部无悬空引用**。可维护性痛点主要在"找文件"环节，不在运行时。

---

## 3. 体检结论：是否需要优化？

| 层面 | 判定 | 依据 |
|---|---|---|
| 运行期架构 | ✅ 无需动 | 启动链（main→config→loader→app）、事件总线 `APP_EVENTS`、`runtime_power` 访问器收口、协议族 ctx bind 均已成型，且与规则一致 |
| 模块导出惯例 | ✅ 合规、不要动 | 73 文件全部 `module(_modname, package.seeall)`，与 `lua-luatos.mdc` 完全一致 |
| `_G` 使用边界 | ✅ 合规 | `_G.xxx=` 仅出现在 main 与 config 片段；模块仅 `_G[_modname]=_M`（惯例要求） |
| 文档-代码一致性 | ⚠️ **需要治理**（低成本、高收益） | §2.2 列表：模块树、计数、文件命名三处已过时 |
| 仓库卫生 | ⚠️ 低优先级 | 根目录混入 `*.7z`、`_temp_*.log`、`datasheet/`、`http_server/` 等非固件产物（不进 git 则无害，进 git 则建议收纳） |
| 工作流 | ⚠️ 提示 | `hif_cmd_usb.lua` 有在途功能改动，回归前先合入/评审，勿与重构混提 |

---

## 4. 四主题裁决表（对你勾选方向的逐条裁定）

| # | 你勾选的方向 | 裁决 | 理由 / 依据 | 若要执行（解锁条件） |
|---|---|---|---|---|
| 4.1 | 拆分巨型模块（含 `app.lua` 972） | **禁止执行** | `.cursor/rules`：「不要合并、**不要再拆 `app`**」；8-31 计划 P4「`app.lua` 零拆分」，冻结期内零新拆分 | 冻结期后（≥09-14）更新 `.cursor` 规则与计划书，明确解除 app 冻结；再按 §6 路线动刀 |
| 4.2 | 接口与全局治理（消 seeall / `_G` 泄漏） | **禁止执行（按当前惯例定义）** | `lua-luatos.mdc`：模块保持合宙惯例，**不要改成 `local M = {}`**；且体检证实当前 `_G` 边界合规，**不存在"泄漏事故"**，只有规则要求的导出 | 若目标是"显式接口 + 去 `_G`"，需先修订规则允许新模块风格（影响全部 73 文件调用方，属大规模行为面改动，强烈建议单开分支分族迁移） |
| 4.3 | 启动/生命周期统一 | **部分可做（但无需改）** | 体检未发现启动链失序/竞态；现有 `module_loader.load/opt/start/stopAll` + `main`→`app.start` 编排已统一。低风险可做项见 §5 | — |
| 4.4 | 只出体检报告不改码（含新 doc） | ✅ **本次交付** | 本文件即体检 + 裁决 + 路线图 | — |

---

## 5. 当前冻结期内建议执行的低风险项（不动行为）

| # | 项 | 类型 | 收益 | 验收 | 状态 |
|---|---|---|---|---|---|
| L1 | 重写 `doc/LUA_MODULES.md` 模块树与计数（73 文件、真实文件名单、修正 §3.x 引用） | 文档 | 新人 15 分钟定位任意 handler | 任意模块名 ≤2 次点击到文件 | ✅ **09-03 完成** |
| L2 | 修正 8-31 计划 §2 规模/树为现值，并标注"子模块名仅作语义分组、真名见 LUA_MODULES" | 文档 | 消除维护者按旧名找文件的挫败 | diff 审阅 | ✅ **09-03 完成** |
| L3 | `doc/modules/README.md` 补子模块索引表 | 文档 | 见 L1 | 链接可点通 | ✅ **09-03 完成** |
| L4 | 仓库收纳：`.gitignore` 补 `*.7z / *.log / datasheet/`（如未忽略）；根目录产物迁入 `archive/` | 仓库卫生 | 缩小仓库噪音 | `git status` 干净 | ✅ **09-04 完成**（ignore 补齐；`patch_server.7z` 与 3 个 `_temp_rename_*.log` 迁入 `archive/`） |
| L5 | 冻结期满前对 `hif_cmd_usb.lua` 在途改动单独评审合入 | 流程 | 避免与后续重构混提 | 代码评审 | ✅ **09-04 评审完成**（协议族静态回归 ALL PASS；合入建议刷新 VERSION 日期标记并跑实机 USB 复位冒烟） |

> L1–L3 本质是 8-31 计划 P0 的"收尾未竟项"（计划书里自己标注了 `LUA_MODULES.md`"待 P0 更新为模块树"）——已随 09-03 文档治理补上（L2 落地于 `USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md` §2，L3 落地于 `modules/README.md`）。

---

## 6. 冻结期后可选重构路线（先解锁、再动刀）

仅当你确认要推翻"app 冻结 / module 惯例"两条规则后，按以下顺序执行（每刀独立提交、跑静态回归）：

1. **解锁前准备**：改 `.cursor/rules` 两处 + `USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md` §4 标记"已解锁，重开 app 评审"。
2. **动刀顺序（推荐由低风险到高风险）**：
   - S1 启动链收口：把 `main.lua` 中 RNDIS/蜂窝引导抽为 `boot/` 编排（属 main 域，不违反 app 冻结，规则允许）——若想保留 main 极简也可不做。
   - S2 `app.lua` 拆分（最高风险）：按 8-31 教训，**不以行数为界**；可议边界为 `app_power`（低功耗/关机/重启/USB 电源）/ `app_pir_bridge`（PIR→MQTT/t31x 桥）/ `app_burn`（烧录门禁）。先做**纯迁移**（工厂函数 + ctx 注入，参照 `host_uart` 的 `bind(C)` 模式），`EVNT_HNDL` 仍集中，绑定顺序契约化；跑实机 smoke（低功耗进出/烧录/PIR 三条主链）。
   - S3 module 显式接口迁移（波及最广）：按族迁移（lib 常驻 → hif 协议族 → 业务模块），每族：`return M` + 调用方补 `local X = require`，`_G` 仅留 `main/config`；每族跑静态回归 + 对应实机用例。
3. **硬性护栏**：每次提交跑 `python tools/debug/_protocol_regression_check.py` + `_module_tree.py --diff`；行为面改动才升 `VERSION` patch。
4. **验收**：S2/S3 完成后，`module()` 只剩 main/config 且 `_G[_modname]` 可摘；app 各拆分文件 ≤400 行且职责在文件名可读。

---

## 7. 相关文档与命令

| 项 | 位置 |
|---|---|
| 拆分后治理计划 | `doc/USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md` |
| 历史拆分账本 | `doc/USER_LIB_OPTIMIZATION_NEXT.md` |
| 模块/事件总线专题 | `doc/LUA_MODULES.md` · `doc/modules/APP_EVENT_BUS.md` |
| 硬约束 | `.cursor/rules/air780ehm-source.mdc` · `.cursor/rules/lua-luatos.mdc` |
| 静态回归 | `python tools/debug/_protocol_regression_check.py` 等（见计划书 §8） |

## 8. 09-04 续补（工具层与文档真源收敛）

| 项 | 动作 | 说明 |
|---|---|---|
| 护栏基线 | `tools/debug/_module_tree_baseline.json` 由 08-31 `hu_*` 时代刷新为 09-04 `hif_*` 现值（58 / 15 / 16 112 行） | 恢复 `_module_tree.py --diff` 护栏（此前基线名旧，diff 全部误报） |
| 回归口径 | `_host_uart_regression_check.py` 改为 `hif_*` 18 文件 + 12 项静态；`_net_mqtt_regression_check.py` 3 项对齐现值；`_gen_bind_header.py`/spec 11 模块键与字段对齐（`t31xUartOff`、wled/hostq 惰性 `defineQuery/defineSet`） | `_protocol_regression_check.py` 全绿 |
| 死工具归档 | hu 时代一次性生成器 6 个（读已删 `hu_*.lua` 源、被 `_gen_bind_header.py` 取代）→ `archive/tools_hu_era/` | git mv，留档不删 |
| 文档真源 | `SYSTEM_ARCHITECTURE.md` §4.2/§5 文件名对齐（`cellular(cell_boot)`→`cell_boot`、删不存在的 `low_power_wakeup`/`sysplus`、补 `led_ctrl`） | 全文 `.lua` 引用 40 处经验证全部命中真源 |
| 保留不动 | `_patch_t31_*`（远程 T31 C 源码工具）、`_rename_lua_modules.py`（改名账本）、doc 中「旧称/对照」表 | 非漂移，有意保留 |

---

*版本：2026-09-04 续 · 基线 `VERSION 001.000.151` · 本报告只读审计，未改动任何运行代码。*
