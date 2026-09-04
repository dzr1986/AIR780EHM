# user/lib 代码审计与死代码清理（2026-09-04）

> **结论先行**：冻结观察期内对 `user/`+`lib/` 全部 73 文件完成一轮**只读审查 + 零行为死代码清理**。
> 本次**不触碰**协议体/时序/回调顺序（遵守冻结规则与「只做纯重构」验收口径）；凡涉及行为/接口的发现**只入清单未实施**。
> 静态护栏 `run_all_checks.py` **ALL PASS（可提交）**；模块树基线已随清理同步刷新；`VERSION` 未升（纯重构零行为，仓库规则：行为面改动才升 patch）。

---

## 1. 方法与范围

- **范围**：`user/` 58 个 `.lua` + `lib/` 15 个 `.lua`（`config.lua`/`sys.lua`/`libfota2` 冻结除外，只作引用核验）。
- **方法**：按业务域 5 组**并行只读审查**（启动配置域 / 电源外设域 / MQTT·PIR 域 / hif 收发链路域 / IPC·T31x 域），每组以 `file:line`+证据回报；全部候选由主流程**人工复核**：整仓（`user|lib|tools|test|scripts|doc`）引用计数 + bind/loader/事件字符串表交叉核验。
- **判据**：
  - 可删 = 整仓引用 **0**，且非文档化公开接口，且不在 bind 头 spec 键内；
  - 可改（行为/接口/协议）→ **只列清单**，本分支不改；
  - 文档化但零消费的 API → 保留并记 P3 观察。
- **验收**：`python tools/debug/run_all_checks.py`（ref_name / module_tree / protocol_regression / doc_module_ref / doc_md_link / doc_index）全绿。

---

## 2. 本次已实施（6 处死代码清理，净减 `user/` 40 行：13 594→13 554；lib 不变）

| # | 文件（现） | 删除对象 | 证据（整仓引用） | 减行 |
|---|---|---|---|---|
| 1 | `user/host_uart.lua` | `noopFalse()` 定义 + ctx 导出键 `noopFalse` | 全仓仅定义+导出 2 处；bind spec 无子模块消费（rec 用 `noopIdle`） | −5 |
| 2 | `user/hif_ipc_cloud.lua` | `cachedGb28181Id()` 定义+导出 | 定义/导出各 1，零调用（真读走 `qryGb28181` 直写 state） | −5 |
| 3 | `user/hif_ipc_cloud.lua` | `cachedTfCard()` 定义+导出 | 定义/导出各 1，零调用 | −5 |
| 4 | `user/hif_ipc_cloud.lua` | 导出死别名 `shouldQryIpcStat` | 仅导出 1 处，零调用（真名 `canQueryT31` 在） | −1 |
| 5 | `user/mqtt_dl_pir.lua` | `queryT31xRecording()`+`t31xRecordingFlag()` 孤儿对 | 全仓引用仅本模块 2 处互指；bind 导出表（dlPirCfg/dlPirStop/dlPirStart/pirDetectExtra）不含 | −23 |
| 6 | `user/hif_ipc_power.lua` | 模块内零引用 local `setRecActive = C.setRecActive` | 该文件内无任何使用点（cloud 的快照同型但确有调用，未动） | −1 |

> 说明：① 清理对象均不在 `tools/debug/bind_header_specs.json` 的 `c/h/wrappers` 键内，`_gen_bind_header --check-all` 保持 PASS；② #5 删除的孤儿函数内部含 `hif.queryHostRecord` 潜在 nil 调用点，一并消除（同型问题在活路径仍存在，见 P0-A）；③ 模块树基线 `_module_tree_baseline.json` 已 `--save-baseline` 刷新（2026-09-04，73 文件 / 16 087 行）。

---

## 3. P0 —— 行为隐患（只清单，未实施）

| # | 位置 | 现象与证据 | 建议（供冻结后/实机验证后执行） |
|---|---|---|---|
| A | `user/mqtt_dl_pir.lua`（现约 :99）`stopHostRecord` | `hif.queryHostRecord(...)` 整仓**无定义/无别名**；rec/hostq 实际导出为 `qryHostRecord`（hostq spec 键 `qryHostRecord`）。触发路径：`dlPirStop`→`recordCtrlStop` 失败/超时后走 idle 快照回退 → nil 调用。doc（CAT1_MODULE_FRAMEWORK:264 等）仍宣称 host_uart 存在 query 前缀函数，属命名迁移遗留 | 低风险修法二选一：hostq 导出补 `queryHostRecord = qryHostRecord` 别名（对照既有 `queryHostRecordTime`/`setHostRecordTime` 先例）；或调用侧改 `qryHostRecord`。建议实机跑一次 2011 停录+host busy 场景确认 |
| B | `user/t31x_ctrl.lua:349` `gracePowOff` | `hif.resetHostLinkState()` 整仓**无定义**；真身为 `hif_ipc.lua:365 resetHostLink = recovery.resetHostLink`（`hif_ipc_rec.lua:130/179`）。每趟 IPC 关机路径在 `powerOff()` 后执行 → nil 调用 | 改 `hif.resetHostLink()` 或补别名 `resetHostLinkState`。建议实机验证关机链（确认此前是否已被上层 pcall 兜住） |
| C | `user/net.lua:30-33` + `user/mqtt_conn.lua:126-142` + `user/net_mqtt.lua:397/401/409/410` | MQTT_CFG 的 4 个业务字段（`autoreconn_ms=10000`/`min_connect_interval_sec=8`/`ip_lose_cooldown_sec=5`/`ip_ready_settle_ms=2000`）经 `mqttCfg()`→`normMqttCfg` 过滤后**恒为 nil**→全回退 TIMEOUT 默认：如 `ip_lose_cooldown` 意图 5s 实际跑 3s。配置意图丢失 | 低风险修复：`normMqttCfg` 透传这 4 个可选字段（仅配置接线，不改协议）。属行为面 → 需你确认后升 patch 实施 |

---

## 4. P1 —— 疑似（需上下文/实机确认，本次不动）

| # | 位置 | 现象 |
|---|---|---|
| 1 | `user/gpio_cfg.lua` GPIO_IN.coproc_ready=pin29 vs GPIO_OUT.t31x_mcu_int=pin29 | 同一引脚同时配「输入中断」与「输出 init=1」，net_name 各异——疑似同 pin 双用途/冲突，需硬件图核对 |
| 2 | `lib/device_id.lua:25-26` | `getImei` 的 mobile 分支不过滤返回值 `"unknown"`，与上方 `validImei`（排除 "unknown"）语义不一致，会绕过 `getDeviceId` 的 `"unknown_device"` 兜底 |
| 3 | `user/pir_ctrl.lua:50-56` `STOP_STAT_KEY` | `STOP_REASON.DEVICE` 与 `.CLOUD` 均映射 `cnt_stop_cloud`——疑复制遗留（对照 TIMER/RETRIGGER/MANUAL 一一映射）；需与统计字段语义确认 |
| 4 | `user/hif_ipc_power.lua` `applyPowerOffSuccess` | 直接 `patchCloud({recordingt31x=0,...})` 绕过 `setRecActive`，与 hif_ipc.lua「统一 setRecActive 防快照/影子态不一致」的单写意图相悖（低置信，commitIpcStat 回填可能自洽） |

**静态复核收敛（2026-09-04，只读核验后留清单）**：

- **P1-1**：pin29 在 `gpio_cfg.lua` 内既配输入 `coproc_ready`（pulldown/rising/active=1，`peripheral.start` 消费 readyPin）又配输出 `t31x_mcu_int`（init=1/on=0，`t31x_ctrl.gpioEntries` 消费）——两条用途均真实被消费、非死配置；形态符合**开漏双向握手**（host 驱动唤醒、T31x 拉 ready），疑似故意设计。结论：维持「需硬件图/原理图核对」，代码不动。
- **P1-2**：确证不对称——`lib/device_id.lua:21-27 getImei()` 的 `mobile.imei()` 直返分支只挡空串、**不过滤 `"unknown"`**（对比第 13 行 `validImei` 排除 "unknown"），`getDeviceId()` 的 `"unknown_device"` 兜底可被字面 `"unknown"` 绕过。结论：维持清单，修复属行为面（冻结后 + 决定 IMEI 缺失时的期望身份值后再动）。（2026-09-04 §10 已授权修复 → VERSION 153）
- **P1-3**：**复核=语义自洽，非复制遗留（2026-09-04，见 §11）**——`DEVICE`/`CLOUD` 双键同映射 `cnt_stop_cloud` 覆盖两条同源「云停」回链：DEVICE 由 4G 侧 `reqStopCloud`（MQTT 2012/2010 下行）主动停录建模；CLOUD 由 T31x 固件 `record_notify` 回 `AT+RECORD=0,reason=cloud` 经 `syncStopT31x` 补记（词表见 `doc/t31x/T31X_IPC_ALERT_CODE_INDEX.md:87`）。本地停（timer/二次 PIR/manual）不落此键；`pubStopRec` 先置 recording=false，后到 `syncStopT31x` 不再 bump，无逐会话双计。代码不动（加防回归注释）。
- **P1-4**：**复核=自洽（2026-09-04，见 §10）**——`patchCloud`→`commitIpcStat` 在 `snap.recordingt31x ~= nil` 时回填 `state.t31x_rec_active`，`applyPowerOffSuccess` 直写 cloud 字段与 `setRecActive` 单写意图最终一致。

---

## 5. P2 —— 重复实现 / 坏味道（非行为面，冻结后可批量收敛，本次不动）

| # | 位置 | 说明 |
|---|---|---|
| 1 | `lib/utils.lua:141-145` vs `lib/config_manager.lua:32-38` | `parseBoolDef` 与 `bool` 布尔归一逻辑等价，可合并为单一 helper |
| 2 | `user/net.lua:16-20` vs `lib/watchdog.lua:16-20` | WDT 默认 `9000/3000` 双源（config 表 + 模块 runtime） |
| 3 | `user/host.lua:23` vs `lib/utils.lua:12` | `1704067200`（min_valid_unix）双源常量 |
| 4 | `user/host.lua` 多 cfg 块（TIME_SYNC/IDENTITY/TFCARD/TFCARD_FORMAT/RECORD/ENCODE/IPC） | 各块重复 `hostBootWaitMs=1500, t31x_power_wait_ms=800` 参数模板；改值需同步多处 |
| 5 | `user/hif_ipc_cloud.lua` `defaultCloudSkeleton`(9 键) vs `user/ipc_supv.lua` `CLOUD_STAT_KEYS`/`ipcCloudStatFields` | 同一云状态字段集、同序重复（上报字段禁区，只可收敛内部结构不可动字段） |
| 6 | `user/mqtt_dl_upload.lua:43-49` vs `user/mqtt_ul_upload.lua:30-36`；`user/mqtt_ul_pir.lua:35-40` vs `user/mqtt_ul_upload.lua:38-43`；`user/mqtt_uplink.lua:63-71` vs `:189-203` | `asNeedUpload`/`fmtStrField`/射频字段串（csq/rssi/rsrp/snr）逐字或近似重复 |
| 7 | `user/hif_ipc_hostq.lua` | 同一 setter/query 双名保留：`qryRecTime`/`queryHostRecordTime`、`setRecTime`/`setHostRecordTime`（文档兼容别名，mqtt_hproto 靠 fallback） |
| 8 | `user/config.lua:11` | `_G[_modname or (...)]` 引用未声明 `_modname`，仅靠 `(...)` 兜底——与其它模块「先 `local _modname=...`」写法不一致，依赖全局 nil（脆弱，暂无故障） |
| 9 | `user/t31x_burn.lua` 头注释 | Filename 自述为 config 子目录路径、Module 自述含 `boot_hold/ota_hold` 字段，实际文件位于 `user/` 根、表内无这两个字段，头注释与实体漂移 |

---

## 6. P3 —— 文档化接口零消费观察（保留，冻结期后评估）

| # | 位置 | 说明 |
|---|---|---|
| 1 | `doc/overview/CAT1_MODULE_FRAMEWORK.md:264`、`doc/power/CAT1_LOGIC_SLIM.md` | doc 记 host_uart 有 `setHostEncode`/query 前缀函数族；实现已迁 qry 前缀 + `setHostAudioEncode`/`setHostVideoEncode`（本仓 09-04 实测），`hif_ipc_encode` 的 `setHostEncode` wrapper 零调用。建议 doc 侧收敛到实现真名（qryHostRecord 等），调用侧见 P0-A |
| 2 | `doc/modules/LOW_POWER_WAKEUP.md:29-32` | 表列 `shouldCloseTcpOnEnterRest`/`shouldRestoreTcpOnExitRest`/`getModemHibernate`：前两者整仓零调用、后者恒 false 且被 app.lua 消费——属模式矩阵文档化接口，运行期无实际作用，冻结期后评估摘除或改文档 |
| 3 | `user/main.lua:60` `_G.buildIotOtaVersion` | 文档化 `_G` 导出（LUA_MODULES:186）整仓零消费；`validateBuildVersion`/`resolveIotOtaVersion` 有消费。保留 |
| 4 | `lib/watchdog.lua` `feed()`/`getConfig()` | 零外部消费但属 start/stop/getState API 族（LIB_RUNTIME_UTILS 记 getConfig 为调试快照）。保留 |
| 5 | `user/hif_ipc_encode.lua` `setHostEncode` wrapper | 与 doc 一致性见 P3-1；删除需先更新 doc，冻结期不动 |

---

## 7. 附带修复（doc 护栏缺口，非 lib/user 代码）

| # | 文件 | 修复 |
|---|---|---|
| 1 | `tools/debug/_doc_index_check.py` | `TOPIC_DIRS` 登记新增 `manual` 主题目录（此前 `doc/manual` 孤儿导致护栏 FAIL） |
| 2 | `doc/overview/T31X_NAMING.md` §8 | 「常见错误对照」行补「旧称」措辞，供 `_doc_module_ref_check` 按史实降级（错误写法列本属史实对照） |

---

## 8. 复查命令

```bash
# 已清理符号复核（应各仅剩 doc 提及、或 0 命中）
grep -rn "noopFalse\|cachedGb28181Id\|cachedTfCard\|shouldQryIpcStat\|t31xRecordingFlag\|queryT31xRecording" user lib
# 静态护栏（应 ALL PASS）
python tools/debug/run_all_checks.py
# 模块树漂移（基线已刷新至 2026-09-04）
python tools/debug/_module_tree.py --diff
```

---

## 9. 授权后实施（2026-09-04，P0 三连修复 → VERSION 001.000.152）

**触发**：用户「可以继续优化 lib user」→ 显式授权 §3 P0 清单落地（此前等待确认项）。

| # | 修复 | diff | 说明 |
|---|---|---|---|
| A | `user/hif_ipc_hostq.lua` 导出表补 `queryHostRecord = qryRecord` | +1 行别名 | 对照既有 `queryHostRecordTime` 双名先例（P2-7 模式）；经 `hif_ipc` `hang()` → `host_uart` `_M` 全链生效，消除 `mqtt_dl_pir.lua:99` `stopHostRecord` 的 nil 调用 |
| B | `user/t31x_ctrl.lua` `gracePowOff` 改调 `hif.resetHostLink()` | 1 行 | 旧名 `resetHostLinkState` 整仓仅此 1 个调用点、无其它消费者；真身 `hif_ipc_rec.lua:130` 经 api 表已挂到 `_M`（改调用点优于补全局别名） |
| C | `user/mqtt_conn.lua` `normMqttCfg` 透传 4 个可选调参 | +5 行透传 | `net_mqtt.lua:397/401/409/410` 恢复 `MQTT_CFG` 意图值（如 `ip_lose_cooldown` 3s→5s）；nil 时仍走 `TIMEOUT.*` 默认；`sameMqttCfg` 仅比 6 键，判定语义不受影响 |
| D | `user/main.lua` `VERSION 001.000.151 → 001.000.152` | 1 行 | 行为面修复升 patch（仓库规则：行为面改动才升 patch） |

**验证**：静态护栏 `python tools/debug/run_all_checks.py` ALL PASS（ref_name / module_tree / protocol_regression / doc 四族）；`_module_tree.py --diff` 无漂移（无新增/删除模块，仅改内容，树基线不受影响）。
**披露（未实机）**：A 需真机 2011 停录 + host busy 回退场景、B 需 IPC 关机链、C 需上线观察重连/冷却实际时序——静态修复按源码语义成立，真机窗口后补冒烟。

---

## 10. 授权后实施·第二波（2026-09-04，P1-2 行为修复 + P2-8/9 零行为 + P1-4/P2-1 复核）

**触发**：用户「继续优化可选方向…按你的方式来，可以授权修改」→ 自主选波次：可静态确证且语义明确的实施，需硬件图/行为敏感的仅复核不动。冻结边界（4.1/4.2 重构主题）未触碰。

| # | 动作 | 结论 |
|---|---|---|
| P1-2 | `lib/device_id.lua:26` mobile 分支改走 `validImei(id)` 过滤（含 `"unknown"`） | ✅ **实施**：`mobile.imei()="unknown"` 时不再绕过 `getDeviceId` 的 `"unknown_device"` 兜底；`getDisplayId` 不变（本就得 `"unknown"`）。消费方（mqtt deviceNo / hif_cmd AT 响应）语义收敛。行为面 → VERSION 153 |
| P1-4 | `applyPowerOffSuccess` 直写 `patchCloud({recordingt31x=0})` 绕过 `setRecActive` | 🔍 **复核=自洽，不动**：证据链 `hif_rx_dsl.lua:206-216 patchCloud` → `:189-204 commitIpcStat` 在 `snap.recordingt31x ~= nil` 时回填 `state.t31x_rec_active`（cloud 为准，与 `hif_ipc.lua:319-331` 注释单写意图一致）；`applyPowerOffSuccess` 先置 `host_ipc_status="idle"` 再 patch，`commitIpcStat` 的 `ipcReady==1` 才改 ready 不会覆盖。审计原「低置信」判定正确 |
| P2-1 | `config_manager.bool` vs `utils.parseBoolDef` 归一 | 🔍 **复核=收益趋零，不动**：`bool` 全仓零调用方（属 P3 保留类公开 helper）；`parseBoolDef` 仅 `pir_ctrl:73` 单消费；合并需新增 `config_manager→utils` 依赖，成本>收益 |
| P2-8 | `user/config.lua` 补 `local _modname = ...` 声明 | ✅ **实施**（零行为）：`module(_modname, package.seeall)` + `_G[_modname]=_M`，对齐全仓惯例（原依赖 `(...)` 兜底） |
| P2-9 | `user/t31x_burn.lua` 头注释漂移 | ✅ **实施**（零行为）：Module 行去掉虚构的 `boot_hold/ota_hold`，对齐实体键；Filename `config/xxx` 经核为 9 个 config 片段统一约定，**非漂移**（修正审计 P2-9 的 Filename 误判） |
| P2-2/3/4/5/6/7 | WDT 双源 / min_unix 常量 / host.lua 参数模板 / 云状态字段集 / 射频字段串 / 双名别名 | 🔍 **本轮不动**：分别存在行为敏感（默认源归属）、config 片段加载序依赖（utils 未先加载）、上报字段禁区、协议串拼错即改载荷（护栏不覆盖 JSON 上行）、有意保留别名（P2-7，mqtt_hproto fallback 依赖）等理由，留冻结期后/专项波次 |

**基线**：`_module_tree_baseline.json` 刷新（净 +3 行：device_id +2、config.lua +1）；`VERSION 001.000.152 → 153`。
**验证**：静态护栏 `run_all_checks.py` 全绿；未实机（mobile 无卡回 "unknown" 场景需真机去 SIM/飞行验证身份上报回退）。

---

## 11. 授权后实施·第三波（2026-09-04，P1-3 复核=自洽 + 防回归注释）

**触发**：用户「继续优化上面代码」（@编程专家.Skill）→ 同口径：可静态确证 + 语义明确的实施，需硬件图/行为敏感仅复核。本波清理审计 P1 末项 **P1-3**。

| # | 动作 | 结论 |
|---|---|---|
| P1-3 | `pir_ctrl.lua:50-56` `STOP_STAT_KEY` 中 DEVICE 与 CLOUD 同映射 `cnt_stop_cloud` | 🔍 **复核=语义自洽，非复制遗留**。证据链：① 枚举产生集（pir_ctrl 全函数核验）：`reason` 写入仅四类来源——`reqStopCloud`（云下行 2012/2010，mqtt_dl_pir:223 / mqtt_dl_tf:87）→ 内部建模 `DEVICE`；`handlePirRetrigger`→`PIR_RETRIGGER`；`suspend`/pubStopRec→`MANUAL`；`app.onPirTimer`→`TIMER`；T31x 回链 `hif_cmd_t31x uartRecord(0)`/`hif_ipc_cloud reconcileRecord`→`syncStopT31x(reason)` 透传开放字符串。② `CLOUD` 键消费：T31x 固件 `record_notify.c` 以 `AT+RECORD=0,reason=cloud` 上报（权威词表 `doc/t31x/T31X_IPC_ALERT_CODE_INDEX.md:87`）→ `STOP_STAT_KEY["cloud"]` 命中补记。③ 无双计：`reqStopCloud→pubStopRec(DEVICE)` 的 `endRecSession` 先置 `recording=false` 并 bump，T31x 随后回链 `syncStopT31x("cloud")` 时 `wasRecording=false` 不再 bump；对账场景仅当 4G 侧此前未 bump 才补记一次。④ 无污染：本地停（timer/二次 PIR/低电→suspend→MANUAL）均不落 cloud 键。**结论：代码逻辑不动**；在映射表加 5 行防回归注释（两键来源 + 无双计依据 + 词表引用），防后续误删/误归一。零行为 → VERSION 不升 |

**基线**：`_module_tree_baseline.json` 刷新（pir_ctrl.lua +6 行注释；无模块增删）。
**验证**：静态护栏 `run_all_checks.py` 全绿；注释改动无 lint。
**备注**：顺带发现 `doc/t31x/T31X_IPC_ALERT_CODE_INDEX.md:87` 的「`host_uart.lua:604–628`」为拆分前行号历史叙述（现真源 `hif_cmd_t31x.lua`），doc 行号引用按史实降级惯例不追改。

## 12. 授权后实施·第四波（2026-09-04，t31x 唤醒门配置键大小写静默失效修复）

**触发**：用户「lib user 在逻辑上可以继续优化么」（@编程专家.Skill）→ Wayfinder 收敛：doc 优化轮遗留代码侧疑点（`t31x_policy.lua` cfgm.get 键名 vs `battery.lua` `_G` 注册键名大小写不一致）经静态取证为**真实静默失效 bug**。

| # | 修复 | 证据链 |
|---|---|---|
| 1 | `user/t31x_policy.lua:22` `cfgm.get("T31X_POLICY_CFG")` → `cfgm.get("t31x_POLICY_CFG")` | ① 写入侧 `user/battery.lua:77` 注册 **`_G.t31x_POLICY_CFG`**（`t31x_` 前缀小写为本域命名规范：T31X_NAMING.md §8 / MANUAL_V2_LUA_API.md）；② `lib/config_manager.lua` `get(name)=_G[name]` **大小写敏感**、无注册表归一 → 读全大写键恒 nil → 回退 `{}`；③ 全仓 cfgm.get("T31X_…") 消费仅此 1 处，config.lua 未注册大写键（对照：`t31x_BURN_CFG` 由 app.lua 同键名直读 `_G`，一致无 bug）；④ 修复后读侧对齐写入侧，`battery.lua` 表内 11 个字段真实生效 |
| 2 | `user/main.lua` VERSION `001.000.153 → 154` | 行为面修复升 patch（仓库规则） |

**行为差异评估（修复后 policyCfg 从空表 → 真实配置）**：
- 字段判型多为 `X ~= false`（opt-out 默认放行）→ `true` 与 `nil` 语义一致，wled/PIR rest 白名单、`block_wake_in_low_power`/`block_mqtt_offline_wake*` 等无行为变化；
- 电量阈值显式值（`block_wake_below_percent=5`/`block_wake_below_mv=3400`）与兜底 guard 值（`pir_suspend_percent=5`/`shutdown_mv=3400`）人工对齐 → 现行为不变，但**消除「只调 POLICY 不生效」的静默失效**；
- 差异点 ①：`enabled = LOW_POWER_CFG.enabled`（`FEATURE_CFG.low_power ~= false`，默认 true）→ 仅关低功耗编译（enabled=false）时门禁真正恒通过，对齐 `T31X_POLICY_GATE.md:20`「enabled=false 门禁恒通过」文档宣称；② `mqtt_offline_wake_cooldown_sec=120` 生效（MQTT 掉线 120s 冷却窗口内不再二次硬唤醒 T31x，省电意图落地）。
- 顺带修正 `policyCfg()` 键名规范注释（防回归：勿改全大写）。

**基线**：`_module_tree_baseline.json` 刷新（t31x_policy.lua +2 行注释；无模块增删）。
**验证**：静态护栏 `run_all_checks.py` ALL PASS（EXIT=0）；read_lints 0 诊断。
**披露（未实机）**：cooldown 生效与 enabled=false 门禁关闭两差异需真机低电/MQTT 掉线场景冒烟；静态按源码语义成立。

## 13. 授权后实施·第五波（2026-09-04，§12 静默失效 bug 的防回归双防线，零行为）

**触发**：用户「继续上面的优化」→ 前波修复后核查 `cfgm.get` 消费键（34 个）与 `_G` 注册键全量一致，无新确证缺陷；将第四波 root cause（`config_manager.get` 直查 `_G[name]`、大小写敏感、nil 恒空表回退且零告警）视为脆弱土壤，补**静态 + 运行期双防线**防同族复发。

| # | 防线 | 文件 | 说明 |
|---|---|---|---|
| 1 | 静态 | `tools/debug/_config_key_check.py`（新增） | 扫描 user/+lib/：`cfgm.get("<NAME>")` 消费键须 ⊆ `_G.<NAME>` 精确同键名注册（大小写敏感，正捕 §12 形态）。未来任何消费键错名/大小写不一 → 静态 FAIL。`BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard` 别名注册形态已覆盖 |
| 2 | 静态 | `tools/debug/run_all_checks.py` | 注册为第 7 项检查（入口 docstring 同步） |
| 3 | 运行期 | `lib/config_manager.lua` `get()` | 未注册键路径加**一次性** `log.warn`（`warnOnce` 去重，`if log and log.warn` 防呆，文案含大小写提示）；正常路径零日志新增、逻辑零变更 |

**可行性取证（无假阳性）**：
- config 片段经 `config.lua` 同步 require 全部注册后才返回，消费方模块均 `require "config"` 前置（如 `host_uart:31-32` + 顶层 `cfgm.get("APP_EVENTS")`）；无运行期动态新增配置键 → 运行期告警仅命中真缺失。
- `cfgm.merge/num/bool("字符串")` 零调用 → 无 resolve 误告警。
- lib 内日志均 `if log and` 防呆惯例对齐（utils/sys 先例）。

**验证**：新 check 首跑 ALL PASS（现库全部消费键精确注册，含 §12 修复后）；基线刷新（lib config_manager.lua +12 行注释/告警）；`run_all_checks.py` 全 7 项 ALL PASS（EXIT=0）；read_lints 0 诊断。
**版本**：零行为防线，`VERSION` 维持 001.000.154。

---

## 14. 授权后实施·第六波（2026-09-04，破冻结第一波：P2-1/2/3 处置 + require 环结构约束发现，零行为）

**触发**：用户「授权破冻结吧 你继续优化」→ 冻结期禁项（§5 P2 / §6 P3）首次获准处置。

**关键发现：require 依赖环结构约束（新，修正 P2-1/P2-3 的"可归一"假设）**
- `lib/module_loader.lua:7` `require "config"` + `:8` `require "config_manager"`。
- 推论：① **任何 config 片段不得 require 经 module_loader 依赖 config 的 lib**（config 加载中重入 → 栈溢出）；② **config_manager 不得 require utils**（`config_manager→utils→module_loader→config_manager` 重入环）。
- 故 P2-1（bool/parseBoolDef 归并为单一 helper）与 P2-3（min_unix 常量单源）**在现有分层下不可代码归一**，双实现/双源是**必要的结构性设计**，只能注释互链防漂移。

| # | 处置 | 位置 | 说明 |
|---|---|---|---|
| P2-2 | 收敛 | `lib/watchdog.lua` | 模块内 5 处 `9000/3000` 字面量 → 模块级 `DEF_TIMEOUT_MS`/`DEF_FEED_IV_MS`（net.lua `WDT_CFG` = 产品权威默认，DEF = 内置兜底，职责分层；行为逐字节等价） |
| P2-1 | 登记约束 | `lib/config_manager.lua` bool + `lib/utils.lua` parseBoolDef | 各加注释：语义等价声明 + 「require 环禁互引，两处须同步维护」 |
| P2-3 | 登记约束 | `lib/utils.lua` MIN_VALID_UNIX + `user/host.lua` TIME_SYNC_CFG.min_valid_unix | 各加注释互链：config 片段禁 require lib → 同值手动同步 |
| P2-4/5/6/7 | 留后续 | — | 跨 cfg 块模板收敛（行为敏感）、云字段禁区、射频串收敛、双名兼容——各需独立波次评估 |
| P3-1~5 | 留后续 | — | doc 收敛 + wrapper 摘除（先 doc 后码，牵 _doc_module_ref_check） |

**验证**：`run_all_checks.py` 全 7 项 ALL PASS（EXIT=0）；read_lints 0 诊断；模块树基线刷新。
**版本**：零行为收敛，`VERSION` 维持 001.000.154。

---

## 15. 授权后实施·第七波（2026-09-04，破冻结第二波：P2-4 + P3-1/5 + require 环规范，零行为）

**触发**：用户「继续授权 1 2 3」（1=P2-4 host cfg 模板收敛，2=P3-1/5 doc 收敛 + wrapper 摘除，3=框架文档沉淀 require 环约束）。

| # | 处置 | 位置 | 说明 |
|---|---|---|---|
| P2-4 | 收敛 | `user/host.lua` | 8+7 处 `hostBootWaitMs=1500`/`t31x_power_wait_ms=800` → 模块级标量 `HOST_BOOT_WAIT_MS`/`T31X_POWER_WAIT_MS`（用标量非表，避免 cfg 表共享可变引用；改值只改一处；行为逐字节等价） |
| P3-5 | 摘除 | `user/hif_ipc_encode.lua` | 删 `setHostEncode(scope)` 零调用 wrapper（定义 −6 行 + bind 导出键 −1，共 −8 行）；`queryHostEncode`/`setHostVideoEncode`/`setHostAudioEncode` 保留 |
| P3-1 | doc 收敛 | `doc/overview/CAT1_MODULE_FRAMEWORK.md`（第 9.6 节 264 行后） | 补「后续演化」注记：encode query/set 迁至 hif_ipc_encode、setHostEncode 拆分 + wrapper 摘除、host_uart query* 前缀为兼容别名（真名 qry*，hostq:319-323）；`doc/power/CAT1_LOGIC_SLIM.md` 84 行「合并 setHostEncode(scope)」建议标「不再采纳」注（readonly 历史 doc 允许加注不判 fail） |
| 规范 | 沉淀 | `doc/overview/CAT1_MODULE_FRAMEWORK.md` §2.4 | require 依赖环约束（config 片段 / config_manager 禁 require utils 系 lib；config 域值无法单源共享；检查点） |
| 佐证 | 复核 | — | P0-A 已闭环：`hif_ipc_hostq.lua:320` 已补 `queryHostRecord` 兼容别名，`mqtt_dl_pir:99` 调用有效（真名 `qryHostRecord`） |

**验证**：`run_all_checks.py` 全 7 项 ALL PASS（EXIT=0）；read_lints 0 诊断；`_gen_bind_header --check-all` PASS（hif_ipc_encode spec 无 wrappers 键）；模块树基线刷新。
**版本**：零行为收敛，`VERSION` 维持 001.000.154。

---

## 16. 授权后实施·第八波（2026-09-04，破冻结第三波：P2-5 + P2-6 + P2-7，零行为）

**触发**：用户「下一步三个项 都处理吧 / 继续」→ §14 尾注「P2-5/6/7 待授权后续」本波全量处置。

| # | 处置 | 位置 | 说明 |
|---|---|---|---|
| P2-5 | 收敛（单源） | `user/hif_ipc_cloud.lua` + `user/ipc_supv.lua` | 云状态 9 键 + 上报序唯一真源 = `hif_ipc_cloud.CLOUD_STAT_KEYS`：`defaultCloudSkeleton` 改由清单造骨架（0 兜底 + ipcReady/recordingt31x/wledEnable/cat1Link 计算键覆盖）；经 `host_uart._M` 新增导出 `cloudStatKeys()` 供消费方取用。`ipc_supv` 删本地 CLOUD_STAT_KEYS 清单与 9 字段字面量格式串（原 3 行超长 format），改按清单逐键 `string.format(',"%s":%d', …)` 拼装 → **1003 IPCSTAT 输出逐字节等价**（字段名/序/数值语义零改动，符合「上报字段禁区只收敛内部结构」） |
| P2-6 | 收敛（单源） | `user/net_mqtt.lua` + `mqtt_dl_upload`/`mqtt_ul_upload`/`mqtt_ul_pir` | `asNeedUpload`/`fmtStrField` 删 3 处逐字副本，单源定义于 `net_mqtt` ctx（`C.asNeedUpload`/`C.fmtStrField`，与 escJson 同层注入）；三叶子 bind 处 `local x = C.x` 取用。同函数体 → 同输出（纯函数、无 upvalue 差异），上行/下行 JSON 载荷字节不变 |
| P2-6b | 复核=保持 | `user/mqtt_uplink.lua` | `radioExtraFields`（csq/rssi/rsrp/rsrq/snr 5 字段）vs `pubSimInfo`（csq/rssi/rsrp/snr 4 字段，无 rsrq）仅为**近似重复**：字段集/所属 schema 不同、顺序交错，均属 1001/1002 载荷契约，机械抽「射频公共子串」会引入按 schema 参数化枚举（更易错）→ 保持逐字段枚举，函数头加注释互链防误判 |
| P2-7 | 登记（有意保留） | `user/hif_ipc_hostq.lua` | 双名（`qry*`/`set*` 内部真名 + `queryHost*`/`setHostRecordTime` 对外名）复核=有意保留：`mqtt_hproto:225-245` 以「长名 `or` 短名」fallback 跨版本消费，删任一名破坏兼容链；`tools/debug/_host_uart_regression_check.py:90-93` 已护栏守护。导出区补注释登记保留原因 + 禁删指引（含 `queryHostRecord` 同族） |

**佐证**：P2-5 单源跨模块边界可行（`ipc_supv → host_uart` 单向依赖，无 require 环；host_uart 模块体在 require 返回前已完成 hif_ipc_cloud bind 装配 → 模块加载期取 `hostUart.cloudStatKeys()` 恒可用）；新增 host API 面仅 `cloudStatKeys`（非 AT 命令，消费方仅 ipc_supv）。
**验证**：`run_all_checks.py` 全 7 项 ALL PASS（EXIT=0）；read_lints 0 诊断；模块树基线刷新（user/ 58 文件 13576 行）。
**版本**：零行为收敛，`VERSION` 维持 001.000.154。

---

## 17. 授权后实施·第九波（2026-09-04，破冻结第四波：P3-2 + P3-3 + P3-4 复核收口，零行为）

**触发**：用户「继续处理」→ 盘点审计账本，P0×3 / P1-2/3/4 / P2×9 / P3-1/5 均已处置，**仅余 §6 P3-2/3/4**（文档化接口零消费观察）→ 本波收口。

| # | 处置 | 位置 | 说明 |
|---|---|---|---|
| P3-2 | 接线+登记 | `user/lp_wakeup.lua` | 3 个模式矩阵策略谓词（LOW_POWER_WAKEUP.md §2 真源）复核：`getModemHibernate`（恒 false 占位）唯一消费者 `app.lua:134`；`shouldCloseTcpOnEnterRest`/`shouldRestoreTcpOnExitRest` 此前零消费——`onEnterRest`/`onExitRest` 钩子内联 `isMqttMode`/`isTcpMode` **绕过谓词**，属半接线漂移 → 钩子改以谓词为决策点（谓词即模式别名，**行为逐位等价**），死导出转活；谓词族加注释登记意图 + 撤销条件（勿绕回内联判型；getModemHibernate 不承载 LOW_POWER_CFG 真源） |
| P3-3 | 复核=保留 | `user/main.lua:59-61` | OTA 版本 `_G` 导出三连复核：`validateBuildVersion`/`resolveIotOtaVersion` 被 mqtt_uplink:91/318、mqtt_dl_ctrl:133、fota_svc:59/95 **经 `_G` 活消费**；仅 `buildIotOtaVersion` 仓内零消费（纯内部构造函数，main.lua:54/72 走 local）——`_G` 导出属与兄弟同族的 Luat 调试台/工具链统一入口（LUA_MODULES.md §3.1 登记）→ 保留 + 注释登记撤销条件（工具链接入点迁移后可同族摘除） |
| P3-4 | 复核=保留 | `lib/watchdog.lua` | `feed()`/`getConfig()` 零外部直连复核：`start`/`stop` 由 `app.setupWatchdog`（app.lua:364-373）消费；feed/getConfig 属 start/feed/stop/getState/getConfig **标准看门狗 API 族**（LIB_RUNTIME_UTILS.md §2.1 登记，getConfig=调试快照）→ 保留 + 注释登记，勿按死代码摘除 |

**佐证（grep 复核，G2'）**：`buildIotOtaVersion` 全仓（user/lib/tools/test/scripts/doc）仅 main.lua 定义/导出 + 3 doc 提及，无第五方；`shouldCloseTcpOnEnterRest`/`shouldRestoreTcpOnExitRest` 仅 lp_wakeup.lua 定义 + LOW_POWER_WAKEUP.md 表（改后由 onEnter/onExitRest 消费）；`watchdog.feed/getConfig` 全库无 `.feed()`/`.getConfig()` 直连（lib/watchdog 内部 `wdt.feed()` 为 LuatOS 原生 API，非模块导出）。

**收口意义**：§6 P3 五行全部闭环（P3-1/5 = §15，P3-2/3/4 = 本波）→ **审计 P0/P1/P2/P3 全清单处置完毕**；P1-1（pin29 双用途）仅剩唯一「待硬件图」项，代码层零残留。
**验证**：`run_all_checks.py` 全 7 项 ALL PASS（EXIT=0）；read_lints 0 诊断；模块树基线刷新（user/ 58 文件 13584 行 / lib/ 15 文件 2559 行）。
**版本**：零行为收敛，`VERSION` 维持 001.000.154。

---

*§1–§8 审计结论不变；§3 P0-A/B/C（§9）、§4 P1-2 与 §5 P2-8/9（§10）、§4 P1-3（§11）、§12 键大小写修复、§13 防回归双防线、§14 破冻结第一波（P2-2 + P2-1/3 约束登记）、§15 破冻结第二波（P2-4 + P3-1/5 + require 环规范）、§16 破冻结第三波（P2-5/6/7）、§17 破冻结第四波（P3-2/3/4 复核收口）已处置；P2-1/P2-3 因 require 环定稿为「双实现/双源 + 互链注释」（§14）；**P0/P1/P2/P3 全清单已闭环，仅剩 P1-1（pin29 双用途，待硬件图）**。基线 `VERSION`：001.000.154 · 静态护栏全绿（含 `_config_key_check.py`），实机验证待真机窗口。*
