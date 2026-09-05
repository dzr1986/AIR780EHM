# 780EHM_PJ 分阶段重构计划（基于 `docs/architecture_audit.md`，2026-09-04）

> **输入**：体检报告 §3 架构问题 A1–A11、§4 逻辑问题、§5 文档缺口、§6 优先级排序。
> **总原则**：先织网（护栏）→ 再解耦（分层/常量/并发模型）→ 再优化逻辑（状态机）→ 最后动对外接口。每阶段 ≤8 个文件、可独立编译与护栏全绿、可单独 review 与回退。
> **「对外接口」定义**（本计划口径）：平台/T31x/用户可感知的契约——MQTT `dataType` 与 JSON 字段、`AT+` 命令与应答格式、`_G.X_CFG` 配置键、OTA 契约、量产产物结构。**固件内部导出函数改名不算对外**，但须同步 `doc/overview/CAT1_API_NAMING.md`（`.cursor/rules/refactor-hard-constraints.mdc §1`）。对外接口变更集中在 **P10**。
> **每阶段通用验收**：`luac5.3 -p user/*.lua lib/*.lua` 全过；`python tools/debug/run_all_checks.py` 全 PASS；`python doc/_tools/doc_registry_check.py` PASS；有行为改动升 `VERSION`（`_doc_version_check` 联动）；模块行数变化刷 `_module_tree.py --save-baseline`。下文只列**阶段特有**的验收项。
> **通用回退**：每阶段一个独立 commit（或一个 PR），回退 = `git revert` 该 commit；阶段间无 API 交叉依赖，可单独撤回。

## 0. 阶段总览

| 阶段 | 主题 | 解决 | 文件数 | 行为面 | VERSION |
|---|---|---|---|---|---|
| P0 | 护栏 token 化 + 护栏单测 | A10 | 6 | 无 | 维持 |
| P0.5 | 文档纠偏（零代码） | §5.2/§5.3 6 项 | 6（doc） | 无 | 维持 |
| P1a | 依赖图 + 分层护栏（基线模式） | A6, §2.3 | 3 | 无 | 维持 |
| P1b | `utils` 反向桥迁出 lib | A6, §2.3 | 8 | 无 | 维持 |
| P2a | 超时常量单源 · hif_ipc 族 | §4.3 末行, A2 前置 | 7 | 无 | 维持 |
| P2b | 超时常量单源 · hif_cmd/rx + mqtt 族 | §4.3 末行 | 8 | 无 | 维持 |
| P3 | busy 键收敛为 `uart_session` | A2 | 6 | **有** | +1 |
| P4 | ACK 请求关联 ID | A1 | 7 | **有** | +1 | ← 复核后不实施（见 P4 节结论） |
| P5 | 错误返回约定统一 + message 词表 | §4.2, §5.1 | 6 | 无（字符串不变） | 维持 |
| P6a | PSM · 低功耗态单写点 | A3, A7, §4.1 | 5 | **有** | +1 |
| P6b | PSM · 录像态单入口 + 禁写护栏 | A3, §4.1 | 8 | **有** | +1 |
| P7a–c | ctx 三命名空间（三批，别名过渡） | A4 | 6 / 7 / 4 | 无 | 维持 | ← 改为 bind 时刻可用性 + spec 生成（见 P7 节结论） |
| P8 | 协议字段表驱动 + 文档 ⊆ 校验 | A8 | 6 | 无（字节等价） | 维持 | ← 护栏半落地，序列化重写不做（见 P8 节） |
| P9 | `modCall` 签名校验 + 重复实现收敛 | A5, §4.3 | 6 | 无 | 维持 | ← 执行时成员校验抓出 4 处 nil 调用并修复 → 实际 VERSION +1（159） |
| P10 | **对外接口变更**（1013 / hostevt_poll / 2011 文案 / hybrid 配置 / 构建口径） | A8, A9, A11 | 8 | **有，需云端+T31x 配合** | +1 |

依赖链：P0 → P0.5 → P1a → P1b → P2a → P2b → P3 → P4 → P5 → P6a → P6b → P7a → P7b → P7c → P8 → P9 → P10。P5、P8、P9 与主线弱耦合，可穿插；P10 必须最后且需联调窗口。

---

## P0 · 护栏 token 化 + 护栏单测

**目标**：A10——所有后续阶段的安全网。消灭正则各自实现字符串/注释/别名带来的漏报（本轮评审 4/4 抓到 3 条）。

**改动范围**（6）：
- 新增 `tools/debug/_luatok.py`：最小 Lua 词法器（字符串/长字符串/行注释/块注释/标识符/数字/符号），提供 `tokens(text)`、`strip_noncode(text)`、`calls(text, name)`（解析实参列表）。
- 改 `tools/debug/_config_key_check.py`、`_gpio_opts_check.py`、`_ref_name_check.py`：用 `_luatok` 替换各自的 `strip_comment`/`RE_STR`/`split_args`。
- 新增 `tools/debug/tests/test_guards.py` + `tools/debug/tests/fixtures/`：固化本轮注入样本（单行错键、模块/函数别名、变量 opts、`setupInputEntry` overrides、字符串伪消费 `log.info("cfg","ZZ_DEAD_CFG")`、单引号 `cfgm.get('K')`）。
- 改 `tools/debug/run_all_checks.py`：第 10 项 `tests/test_guards.py`（`python -m pytest -q` 或纯 `unittest`，不引入新依赖）。

**执行步骤**：① 写 `_luatok` 并用现有三脚本的当前输出作回归基线（先保证结果不变）→ ② 三脚本切换到 token 流 → ③ 落固化样本，确认每个样本恰好触发预期 FAIL → ④ 挂入 `run_all_checks`。

**文档同步点**：`doc/manual/MANUAL_V7_TOOLCHAIN.md §5/§6`（护栏清单 +1、说明 token 化）；`doc/_audit/DOC_HEALTH_REPORT_20260904.md` 追加一节；`tools/README.md`。

**风险与回退**：token 化后若护栏变严（抓出此前漏报的真问题）→ 属收益，逐条按 P1+ 处理；若变松（漏掉原能抓的）→ 单测基线会红。回退：revert，三脚本回正则版。

**验收**：`run_all_checks.py` 10/10；`tests/test_guards.py` 全部样本 FAIL 复现、当前代码全 PASS；对 `git stash` 掉 R1 修复的 `gpio_util` 仍能 FAIL。

---

## P0.5 · 文档纠偏（零代码）

**目标**：§5.2/§5.3 中不依赖代码改动即可修正的 6 处不一致，避免后续阶段的 AI/人被误导。

**改动范围**（6，全 doc）：
- `.cursor/rules/air780ehm-source.mdc`：`hu_*` → `hif_*`（`alwaysApply` 规则，优先级最高）。
- `doc/overview/CALL_GRAPH.md`：§2「lib 不得 require user」改为「lib 不得 require user 业务模块；`config` 域（`config`/片段/`config_manager`/`module_loader`/`runtime_power`）属 L0 平台配置，lib 可依赖」；§1.1 心跳改 `APP_META.heartbeat_log_interval_ms`（默认 60s）。
- `doc/overview/CODE_LAYERING_ARCHITECTURE.md`：L0 补入 config 域，与 §2.3 实测一致。
- `README.md`：打包段补量产真源 `tools/pack_mass_prod.py` / `cat1_flash.py flash-script`，标注 `package_project.bat` 仅工程包；目录表标注 4 个服务目录为独立工程、`firmware/` 大部分 gitignore。
- `doc/release/RELEASE_v1.2.md`：补「当前脚本 155 / 量产内核 V20xx（待产线确认）」一行，并注明 `luatos.json core` 仅供 Luatools 调试。
- `doc/overview/CONFIG.md`：`config.mk FOTA_SERVER ?= iot` 与 `net.lua server_mode="self"` 默认不一致的说明。

**执行步骤**：一次提交；`_doc_md_link_check`、`doc_registry_check` 校验。
**文档同步点**：本阶段即文档。
**风险与回退**：无代码风险；内核号若产线未确认则写「待确认」而非猜测。
**验收**：4 条文档护栏 PASS；`rg "hu_" .cursor/rules` 为 0。

---

## P1a · 依赖图工具 + 分层护栏（基线模式）

**目标**：A6/§2.3——把「`lib` 不得依赖 user 业务」「config 片段/`config_manager` 禁 require `utils` 系」从文档红线变成机器拦截；先以**当前 11 条反向边为白名单基线**，保证零阻塞，后续阶段只允许基线收缩。

**改动范围**（3）：
- 新增 `tools/debug/_dep_graph.py`：固化体检用的抽边脚本（`require`/`loader`/`modCall`/`bind`/`utils` 懒加载五形态），输出 JSON + mermaid，可 `--scc` 列软环、`--reverse` 列 lib→user。
- 新增 `tools/debug/_layer_check.py`：规则表 `lib/* ↛ user/*`（`config` 域豁免）、`config 域 ↛ utils|module_loader 加载期`、`mqtt_*/hif_* 子模块 ↛ require 主文件`；`--save-baseline` 写 `_layer_baseline.json`，默认模式「新增反向边即 FAIL」。
- 改 `tools/debug/run_all_checks.py`：第 11 项。

**执行步骤**：① `_dep_graph.py` 输出与体检报告 §2 数字一致（0 硬环 / 27 模块软环 / 11 反向边）→ ② `_layer_check --save-baseline` → ③ 挂入。
**文档同步点**：`doc/overview/CAT1_MODULE_FRAMEWORK.md §2.4`（红线改为「由 `_layer_check` 守护」）；`MANUAL_V7 §6`；`CALL_GRAPH.md §2` 引用 `_dep_graph.py` 为图的真源。
**风险与回退**：纯工具，无运行代码；误报只需调整规则表。
**验收**：`_layer_check` 基线 11 条全部命中且 PASS；人为在任一 lib 加 `require "pir_ctrl"` → FAIL。

---

## P1b · `utils` 反向桥迁出 lib

**目标**：A6——`lib/utils.lua` 不再懒加载 `host_uart`/`t31x_ctrl`/`uart_bridge`，`lib/` 回归业务无感；`_layer_check` 基线 11 → 9。

**改动范围**（8）：
- 新增 `user/svc.lua`（≤24 字节名；服务定位器：`hostUart()`/`uartBridge()`/`t31xOn()`，实现原样搬迁）。
- 改 `lib/utils.lua`：删三函数（保留其余）。
- 改调用方 `user/net_mqtt.lua`、`user/t31x_ctrl.lua`、`user/time_sync.lua`、`user/sound_prompt.lua`：`utils.hostUart()` → `svc.hostUart()`（`local svc = require "svc"`；`svc` 只 require `module_loader`，无环）。
- 改 `user/main.lua`：`__LUATOOLS_SCAN_ANCHOR__` 挂 `require "svc"`。
- 改 `tools/debug/_layer_baseline.json`：收缩基线。

**执行步骤**：① 建 `svc.lua` 并让 `utils` 三函数临时转调 `svc`（编译过、行为等价）→ ② 四个调用方切换 → ③ 删 `utils` 三函数 → ④ 收缩基线。每步可独立编译。
**文档同步点**：`doc/overview/CAT1_API_NAMING.md`（`utils.hostUart` → `svc.hostUart`，跑 `sync_doc_naming --dry-run` 后加规则）；`doc/overview/LUA_MODULES.md`（+1 模块，74）；`doc/modules/LIB_RUNTIME_UTILS.md`（utils 职责收窄）；`doc/overview/TECH_WORKFLOWS.md §0.2` 矩阵；`README.md` 模块数。
**风险与回退**：`svc` 在 `module_loader.load` 缓存下与原实现逐字等价，风险仅在 anchor 漏挂（Luatools 打包缺文件）——`_ref_name_check` 会抓。回退：revert。
**验收**：`_layer_check` 反向边 9；`_ref_name_check` 74 模块可解析；实机 `AT+GETCFG`、`AT+TIMESET` 路径（time_sync 经 svc 取 host_uart）正常。

---

## P2a · 超时常量单源 · hif_ipc 族

**目标**：§4.3 末行 / A2 前置——`acquire`/`boot`/`quiet`/`retry` 四类共享超时只在 `host_uart` ctx 定义一次，R4 首版「拿 quiet 常量当 acquire 预算」类错误不再可能。

**改动范围**（7）：`user/host_uart.lua`（`ctx.TMO_SHARED = { acquireCapMs=8000, hostIdleMs=2000, bootWaitMs, retryWaitMs=200, retryCapMs }`）、`user/hif_ipc.lua`、`user/hif_ipc_cloud.lua`、`user/hif_ipc_rec.lua`、`user/hif_ipc_hostq.lua`、`user/hif_ipc_power.lua`、`user/hif_ipc_tffmt.lua`。

**执行步骤**：① 抽取六文件 `TIMEOUT`/`TMO` 中语义相同的键，确认数值一致（不一致的先列出来由维护者决定取哪个，本阶段**不改数值**）→ ② 共享键迁到 ctx，模块特有键（`formatMs=120000`、`recOff=22000`）留本地 → ③ `bind_header_specs.json` 各子模块 `c` 加 `TMO_SHARED`。
**文档同步点**：`doc/modules/HOST_UART_AT_DISPATCH.md`（加「超时常量真源」小节）；`tools/debug/bind_header_specs.json`；`doc/overview/CONFIG.md`（若有超时改为可配，登记键）。
**风险与回退**：零行为（数值不变）；若发现同名不同值，属体检新发现，单独登记不在本阶段合并。
**验收**：`_gen_bind_header --check-all` 11/11；`rg "hostIdleMs\s*=\s*\d" user/hif_ipc*.lua` 仅 host_uart 一处。

## P2b · 超时常量单源 · hif_cmd/rx + mqtt 族

**目标**：同 P2a，覆盖剩余 10 个 `TIMEOUT` 表。
**改动范围**（8）：`user/hif_cmd.lua`、`user/hif_cmd_usb.lua`、`user/hif_cmd_wled.lua`（→ `TMO_SHARED`）；`user/net_mqtt.lua`（`ctx.TMO_SHARED`：`cloudStatQuery`、`ipcReadyWait`）、`user/mqtt_uplink.lua`、`user/mqtt_dl_pir.lua`、`user/mqtt_dl_tf.lua`、`user/mqtt_hproto.lua`。`app.lua`/`ipc_supv.lua` 的表为模块特有，不动。
**执行步骤 / 文档 / 风险 / 验收**：同 P2a；文档加 `doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md`「超时真源」小节。

---

## P3 · busy 键收敛为 `uart_session`（行为面）

**目标**：A2——破坏性会话（格式化 / 断电 / USB 恢复）期间，任何 `hostQuery`/`hostSet` 一律等待或 fallback，准入语义唯一；`isCloudBusy` 只读会话态。

**改动范围**（6）：`user/host_uart.lua`（`state.uart_session = nil|"tfformat"|"poweroff"|"usb_recovery"` + `enterSession/leaveSession`）、`user/hif_ipc.lua`（`hostQuery/hostSet` 准入：`state.uart_session ~= nil` → 与 busyKey 同路径 fallback）、`user/hif_ipc_cloud.lua`（`HU_BUSY_KEYS` 缩为 per-query 键 + `uart_session`）、`user/hif_ipc_tffmt.lua`、`user/hif_ipc_power.lua`、`user/hif_cmd_usb.lua`（三处 `xxx_busy = true` 改 `enterSession`）。

**执行步骤**：① 加 `uart_session` 与 enter/leave（旧 busy 键并行保留）→ ② `hostQuery/hostSet` 准入加会话判定 → ③ `isCloudBusy` 切到会话态 + per-query 键 → ④ 删 `tfcard_format_busy`/`ipc_poweroff_busy`/`uart_recovery_busy` 三个旧键（`rg` 确认它们不在 `AT+GETCFG` 快照 `getCnfgSnps` 输出中，T31x 侧无可见变化；`host_uart.lua:98-125` `state` 初值表同步删）。
**文档同步点**：`doc/modules/HOST_UART_AT_DISPATCH.md`（新增「串口并发模型：事务锁 / 会话 / per-query」一节，填 §5.1 缺口）；`doc/overview/TECH_WORKFLOWS.md W3` 门禁列；`doc/overview/USER_LIB_OPTIMIZATION_NEXT.md §6` 回归项；`CONFIG.md`（若 `AT+GETCFG` 字段变）。
**风险与回退**：行为面——格式化期间 2007 从「发出去」变「走缓存」，2002 断电期间 WLED 查询同理。回退 revert 即恢复旧 busy 键。
**验收**：VERSION +1；实机：2009 期间下发 2007 → 1007 回缓存且无 `AT+TFCARD?` 上串口；2002 enter 期间 2005 wled → `t31x_unavailable`/缓存；`_protocol_regression_check` 加「`state.xxx_busy = true` 只允许出现在 `enterSession`」断言。

---

## P4 · ACK 请求关联 ID（行为面）

> **执行结论（2026-09-05）：复核后不实施代码改动，状态改为「登记」。** 逐条推演后发现 `_seq` 方案无法兑现「只接受属于自己那次发送的应答」：
> ① T31x 应答不携带请求 ID，RX 侧对同类型行（如两次 `AT+TFCARD?` 的迟到 `+TFCARD:`）只能按「到达时刻的当前 seq」打标，迟到应答在下一次同类型发送之后到达时会带上新 seq，仍被接受——seq 不能区分它们；
> ② 跨类型抢答的唯一真实来源（`patchCloud` → `IPCSTAT_ACK`）已由 R2 `notify` 消除，其余 20 个 `*_ACK` 事件名已按类型区分，不同类型的等待方本就互不唤醒；
> ③ 同类型主动上报（T31x `AT+IPCSTAT=`/`AT+IPCSTATUS=` 推送）被当作应答时，数据语义等价且更新，不构成错误；
> ④ 迟到应答污染下一次同类型查询的既有缓解是 `hif_ipc.TMO.postQry = 300ms`（miss 后静默）+ 事务锁串行化。
> 因此 P4 的净效果是给 20 个发布点和 `sendAt` 加复杂度而不改变任何可观察行为，违反「不做无收益改动」。**替代处置**：体检 A1 降级为「设计约束登记」——若未来 T31x 协议加入请求 ID（如 `+TFCARD:<seq>,…`），再在 `sendAt`/`try*` 落地关联；本节原方案保留作为那时的实施稿。


**目标**：A1——`hostQuery/hostSet` 只接受属于自己那次发送的应答；同名 URC/主动上报/局部补丁不再抢答。

**改动范围**（7）：`user/host_uart.lua`（`state.uart_txn_seq` 单调递增；`ctx.nextTxnSeq()`）、`user/hif_ipc.lua`（`sendAt` 取 seq，`waitUntil` 后校验 `val and val._seq == seq`，不匹配继续等剩余预算）、`user/hif_rx_dsl.lua`（查询类 `try*` 发布时附 `_seq = state.uart_txn_seq`；URC/主动上报类不附 → 天然不匹配）、`user/hif_rx_media.lua`、`user/hif_cmd_t31x.lua`（`AT+IPCSTAT=` 主动上报保持 `notify=true` 但不带 seq）、`user/hif_ipc_tffmt.lua`（`TFFORMAT_ACK` 校验 seq，封迟到 STARTED）、`tools/debug/_protocol_regression_check.py`（断言「每个 `*_ACK` publish 点带 `_seq` 或注明为 URC」）。

**执行步骤**：① seq 基础设施 + `sendAt` 校验（RX 未附 seq 时 `_seq == nil` 视为「兼容旧行为」放行）→ ② 逐类 ACK 附 seq：IPCSTAT → RECORD → TFCARD → RECORDTIME → ENCODE/AUDIO → WLED → TFFORMAT → ③ 关闭兼容放行（`_seq == nil` 视为不匹配）→ ④ 护栏断言。每步可独立编译；步骤 ③ 前行为与今日等价。
**文档同步点**：`HOST_UART_AT_DISPATCH.md` 并发模型一节补「应答关联」；`doc/t31x/T31X_CAT1_AT_COMMAND_SPEC.md`（说明 4G 侧配对语义，协议字节不变）；`TECH_WORKFLOWS W3-5/W3-6`。
**风险与回退**：`waitUntil` 语义变更——若某 URC 实际是「应答」但被归为 URC，会导致查询超时走缓存（可观测：`hostQuery` fallback 日志）。分步骤合入，③ 单独 commit 便于回退到「兼容放行」。
**验收**：VERSION +1；`MQTT_ALL_CMD_FLOW_TEST` 全命令；专项：WLED 切换中并发 `AT+IPCSTAT?` 拿到真实应答；两次 2009 背靠背，第二次不被第一次的迟到 STARTED 解锁。

---

## P5 · 错误返回约定统一 + 1004/1009 message 词表

**目标**：§4.2、§5.1——三种返回形态收敛为「查询：`value | nil`；命令：`ok, reason`」，`error()` 不再承载业务码；平台可见的 `message` 字符串**不变**并成表。

**改动范围**（6）：`user/hif_ipc_tffmt.lua`（`error("uart_busy")` 等 → `return false, "uart_busy"`，删 `normalizeLuaErr`）、`user/hif_ipc_power.lua`、`user/mqtt_dl_tf.lua`（消费方适配）、`user/mqtt_dl_ctrl.lua`、`lib/utils.lua`（若有共享 `normalizeLuaErr` 类工具则删）、新增 `doc/mqtt/MQTT_REPLY_MESSAGES.md`（1004/1009/1013 `ret/message` 词表，真源标 `user/mqtt_dl_*.lua`）。
**执行步骤**：① 词表文档先落地（从代码 `rg 'reply\(-1, "'` 抽取）→ ② 逐文件改返回形态，`pcall` 只包平台 API → ③ `_protocol_regression_check` 加「`error("<小写下划线>")` 形态为 0」。
**文档同步点**：新 `MQTT_REPLY_MESSAGES.md` 登记进 `doc/mqtt/README.md`；`refactor-hard-constraints.mdc §5` 补返回约定一行；`MANUAL_V3_MQTT.md` 速查指针。
**风险与回退**：`message` 字节不变则平台无感；风险在遗漏某条 `error()` 的调用方仍 `pcall` 取 tail——护栏断言兜底。
**验收**：`rg 'error\("[a-z_]+"\)' user lib` 为 0；平台侧 1009 失败样例 `message` 与词表一致。

---

## P6a · PSM · 低功耗态单写点（行为面）

**目标**：A3/A7/§4.1——`runtime_power` 持有低功耗状态与转移表，`app.onEnter/ExitLowPower`、`battery_guard.enterBatRest`、2002、`AT+LOWPOWER` 四入口只发「请求事件」，转移是否发生由一处判定（`usbBlocks4g`、烧录态、已在目标态）。落地 `ARCHITECTURE_REVIEW_POWER_PSM.md` R1 主案。

**改动范围**（5）：`lib/runtime_power.lua`（`requestRest(reason)`/`requestNormal(reason)` + 转移表 + 唯一 `setLowPowerMode` 写点 + `POWER_ENTERED/EXITED_REST` 发布）、`user/app.lua`（`onEnterLowPower/onExitLowPower` 瘦身为「副作用执行器」：`t31x.enterSleep`/`pubRest`/`notifyUsbIdle`，由 PSM 回调触发）、`user/battery_guard.lua`（`enterBatRest` → `requestRest("battery")`）、`user/mqtt_dl_dev.lua`（2002 → request）、`user/hif_cmd.lua`（`AT+LOWPOWER` → request）。
**执行步骤**：① `runtime_power` 加请求接口，内部先直接转调现有 `app` 回调（行为等价）→ ② 四入口切到请求接口 → ③ 门禁（USB/烧录/幂等）从四处搬进转移表 → ④ `app` 删除重复门禁。
**文档同步点**：`doc/modules/LOW_POWER_WAKEUP.md`（状态机图替换为 PSM）；`doc/power/LOW_BATTERY_AND_LOW_POWER.md` 场景表指向 PSM；`TECH_WORKFLOWS W7` 状态图与步骤表；`ARCHITECTURE_REVIEW_POWER_PSM.md` 标「R1 已落地」；`CAT1_API_NAMING.md`（新接口）。
**风险与回退**：**高**——触及 USB 插拔/2002/电量/AT 四条路径时序，历史震荡区。必须有真机窗口 + `PWR_BUDGET.md` 前后电流对比。回退 revert 单 commit。
**验收**：VERSION +1；`rg "setLowPowerMode\(" user lib` 仅 `runtime_power` 一处；实机 `WORK_MODE_PERSON_DETECT_PIR.md` 全场景表逐条过；USB 插拔 10 次无震荡（1002/1001 序列一一对应）。

## P6b · PSM · 录像态单入口 + 禁写护栏（行为面）

**目标**：A3——`hif_ipc.setRecActive` 成为 `t31x_rec_active`/`cloud.recordingt31x` 唯一写点；`reconcileRecord` 只读不写。
**改动范围**（8）：`user/hif_ipc.lua`、`user/hif_cmd_t31x.lua`、`user/hif_ipc_cloud.lua`、`user/hif_ipc_power.lua`、`user/hif_rx_dsl.lua`、`user/host_uart.lua`、`user/mqtt_dl_pir.lua`（7 处直写改调 `setRecActive`），`tools/debug/_protocol_regression_check.py`（断言 `t31x_rec_active\s*=` 与 `recordingt31x\s*=` 只在 `hif_ipc.setRecActive` 出现）。
**执行步骤**：① 护栏先写（当前会 FAIL，作为待办清单）→ ② 逐文件改 → ③ 护栏转绿。
**文档同步点**：`doc/modules/PIR_CTRL_FLOW.md`、`doc/pir/MQTT_2011_T31X_STOP_EXPLAINED.md`（录像态真源说明）；`TECH_WORKFLOWS W5-5`。
**风险与回退**：中——`commitIpcStat` 回填与 `setRecActive` 语义须逐字等价（audit §10 P1-4 已证自洽），风险在 `applyPowerOffSuccess` 直写路径的顺序。
**验收**：VERSION +1；护栏断言绿；实机 2011/2012/PIR 二次触发/T31x 主动 `AT+RECORD=0` 四条停录路径 1011 各一次不重复。

---

## P7a–c · ctx 三命名空间（别名过渡，三批）

> **执行结论（2026-09-05）：命名空间拆分不实施，改为「bind 时刻可用性推导 + spec 由生成」单 commit 落地。** 理由：ctx 字面表已按类别分组注释；三命名空间需重写 11 个头部与生成器全部匹配，零行为且收益仅可读性；而历史事故（107/108、158 前 `mqtt_dl_pir.hif.patchCloud` nil）的共同根因是「头部快照的键在 bind 时尚未挂到 ctx」，命名空间不解决。现 `_gen_bind_header --check-all` 按装配顺序推导每个子模块 bind 时 `C`/`H` 可用键集合并拦截越界快照；`--sync-specs` 让 `bind_header_specs.json` 的 c/h 由头部生成。详见 `HOST_UART_AT_DISPATCH.md §10`。


**目标**：A4——`host_uart` 70 键 ctx 拆为 `ctx.const`（`SYS_EVT`/`TMO_SHARED`/`RSP_*`）、`ctx.io`（`sendString`/`rspFmt`/`uartAcquire`…）、`ctx.state`（唯一可变表）；`bind_header_specs.json` 由 `_gen_bind_header --emit-all` 生成。

**改动范围**：
- **P7a**（6）：`user/host_uart.lua`（新建三命名空间，**旧平铺键保留为别名**）、`user/hif_cmd.lua`、`hif_cmd_usb`、`hif_cmd_link`、`hif_cmd_pir`、`hif_cmd_t31x`（头部改读命名空间）。
- **P7b**（7）：`hif_cmd_wled`、`hif_ipc`、`hif_ipc_cloud`、`hif_ipc_rec`、`hif_ipc_hostq`、`hif_ipc_power`、`hif_ipc_tffmt`。
- **P7c**（4）：`hif_rx`、`hif_rx_dsl`、`hif_rx_media`；`host_uart.lua` 删平铺别名；`tools/debug/_gen_bind_header.py` 输出命名空间形态并重生成 `bind_header_specs.json`。
**执行步骤**：别名过渡保证 a/b 单独可编译；c 删别名前 `rg "C\.[a-z]" user/hif_*` 应为 0。
**文档同步点**：`HOST_UART_AT_DISPATCH.md` bind 约定一节；`CAT1_MODULE_FRAMEWORK.md`；`bind_header_specs.json` 头注释改「生成物，勿手改」。
**风险与回退**：纯机械，`_gen_bind_header --check-all` + `_host_uart_regression_check` 全覆盖；风险仅在 `C.M` 延迟挂载模式误改为快照（108 事故），护栏 bind 顺序断言兜底。
**验收**：三批各自 `--check-all` 11/11；c 后 ctx 顶层仅 3 键。

---

## P8 · 协议字段表驱动 + 文档 ⊆ 校验

> **执行结论（2026-09-05）：护栏半已落地，序列化重写不做。** `_uplink_schema_check.py`（`run_all_checks` #12）静态对照 `MQTT_DOWNLINK`/`MQTT_PROTOCOL` 中 10xx 样例键集 ⊆ 代码可发字段，缺口基线登记 6 键（1013 进度 5 键、1004 `hostEvtPollMs`）——正是 P10 输入。把 `string.format` 手拼改为字段表序列化需逐 dataType 黄金样本逐字节比对，离线无真机/无 LuatOS 运行时无法可靠生成样本；字段顺序/空值/引号差异一旦漏检即为对外协议回归，收益（可读性）不抵风险，登记为可选后续。


**目标**：A8——10xx 上行字段以 Lua 表声明（`fields = { deviceNo=…, dataType=…, … }` → 统一序列化），`MQTT_DOWNLINK.md` 中各 10xx JSON 样例的键集 ⊆ 代码字段表由护栏校验；输出字节与今日**逐字等价**。
**改动范围**（6）：`user/mqtt_uplink.lua`（序列化 helper + 1001–1009）、`user/mqtt_ul_pir.lua`（1010–1012）、`user/mqtt_ul_upload.lua`（1013）、`user/mqtt_downlink.lua`（`pubReply` 走 helper）、`tools/debug/_protocol_regression_check.py`（文档样例键集 ⊆ 字段表；字段顺序快照比对）、`doc/mqtt/MQTT_DOWNLINK.md`（样例块加 `<!-- SCHEMA:1013 -->` 标记供护栏定位）。
**执行步骤**：① 先写序列化 helper 并用现有 `string.format` 输出做黄金样本（每个 dataType 一份，进 `tools/debug/tests/fixtures/`）→ ② 逐 dataType 切换，样本逐字节比对 → ③ 护栏接入文档样例。
**文档同步点**：`MQTT_DOWNLINK.md` 标记；`MANUAL_V3_MQTT.md`；`NET_MQTT_DOWNLINK_DISPATCH.md`。
**风险与回退**：字段顺序/空值处理若与手拼不一致会被黄金样本抓住；回退 revert。
**验收**：黄金样本全等；护栏对文档 §10b 的 1013 `stage` 字段应报「文档有、代码无」——这正是 P10 的输入。

---

## P9 · `modCall` 签名校验 + 重复实现收敛

**目标**：A5、§4.3——`_ref_name_check` 校验 `modCall("m","fn", args…)` 实参数 ≤ 目标形参数；收敛 5 组重复实现中零行为的 4 组。
**改动范围**（6）：`tools/debug/_ref_name_check.py`；`user/hif_rx_dsl.lua` + `user/hif_ipc_power.lua`（`logPowerOffRx` 单源到 ctx.io）；`user/mqtt_ul_pir.lua`（删自建 `optTable` 用 `utils.optTable`）；`user/hif_cmd_t31x.lua`（TF present 归一改 `utils.to01`）；`user/hif_ipc_cloud.lua`（`defaultCloudSkeleton` 用 `ipcReadyFrom`）。`config_manager.bool`/`utils.parseBoolDef` 双实现因 require 环**保留**（P1a 护栏已守）。
**文档同步点**：`USER_LIB_CODE_AUDIT_20260904.md` P2 表对应行标「已收敛」；`CAT1_API_NAMING.md`。
**风险与回退**：零行为；`to01` 边界（`"1"`/`true`）与手写 `==1` 的差异需先用单测样本确认再切。
**验收**：`_ref_name_check` 对人为多传一个实参的 `modCall` FAIL；重复实现 `rg` 计数归 1。

---

## P10 · 对外接口变更（最后阶段，需云端 / T31x / 产线配合）

**目标**：A8、A9、A11 中涉及平台契约、T31x 固件、配置键、构建口径的变更，集中一次联调窗口处理。

**改动范围**（8）：
- `user/mqtt_ul_upload.lua` + `user/mqtt_dl_upload.lua`：1013 补 `stage`（`queued/uploaded/fail`）、`fileName`、`videoType`、`reply` 终态语义；`need=1` 防抖按 `messageId` 去重。
- `user/hif_at.lua` + `user/hif_cmd_t31x.lua`：新增 `AT+UPLOADPROGRESS=` 解析 → 1013 进度（**需 T31x 固件同步实现**）；`+UPLOADNEED` 解析 `file/msgId/type/alarmTs`。
- `user/mqtt_dl_ctrl.lua`：`hostevt_poll`/`hostevt_poll_query` 实现**或**从文档删除（产品定）。
- `user/battery.lua`：删 hybrid 6 字段 + `LOW_POWER_ENTER_STRATEGY`（**配置键删除 = 对外**；若产品保留 hybrid，则改为先实现状态机再留键）。
- `doc/mqtt/MQTT_DOWNLINK.md`（§10b 对齐、2011 即时 1004 文案以现网为准）、`doc/mqtt/UART_AT_COMMANDS.md`、`doc/overview/CONFIG.md`、`luatos.json`（`core` 改为产线确认的内核并注明）。

**执行步骤**：① 产品/云端/T31x 三方确认清单（本阶段前置门）→ ② 代码按 P8 字段表加字段（护栏立即从「文档有代码无」转绿）→ ③ T31x 固件带 `UPLOADPROGRESS` 后联调 → ④ 配置键删除随 `--write-doc` 刷索引。
**文档同步点**：`MQTT_DOWNLINK.md`、`UART_AT_COMMANDS.md`、`T31X_CAT1_AT_COMMAND_SPEC.md`、`CONFIG.md`（键索引自动）、`MQTT_1013_BACKEND_GUIDE.md`、`RELEASE_*`、`MANUAL_V3/V4`。
**风险与回退**：平台若未同步解析新字段，多出的 JSON 键一般无害，但 `reply` 语义变化会影响后台状态机——需后台确认；`AT+UPLOADPROGRESS` 在旧 T31x 固件上为未知命令，4G 侧须容错 `ERROR`。回退按子项 revert；配置键删除不可热回退（需重烧），故最后做。
**验收**：VERSION +1；`MQTT_CLIP_UPLOAD_CLOSED_LOOP` 闭环用例含进度上报；后台 1013 状态机端到端；`_config_key_check` 39 → 33 键 PASS；`luatos.json core` 与量产实测 `firmwareVersion` 前缀一致。

---

## 附：每阶段 review 清单（模板）

- [ ] 文件数 ≤ 8，且全部在本阶段「改动范围」内（多出的文件 = 越界，拆到下一阶段）
- [ ] `luac5.3 -p` + `run_all_checks.py` 全绿；行数变化已刷基线
- [ ] 「文档同步点」逐项对勾；接口变更（含内部导出函数改名）已进 `CAT1_API_NAMING.md`
- [ ] 行为面阶段：`VERSION` +1，`USER_LIB_OPTIMIZATION_NEXT.md §6` 回归项已加，实机记录附 commit
- [ ] 零行为阶段：能用「输出逐字等价」或「护栏断言」之一证明
- [ ] 回退方式已写明（单 commit revert / 分步 commit 定点回退）
