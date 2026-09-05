# 功能架构与分层优化（lib / user · 功能视角）

> **定位**：本文档与 [CODE_LAYERING_ARCHITECTURE.md](CODE_LAYERING_ARCHITECTURE.md)（代码层 L0–L4 切割真源，已执行）互补。
> - 既有文档回答"**代码按什么层放**"（基础设施 vs 业务）。
> - 本文档回答"**功能按什么域组织**"，并给出**拆分/合并清单**与**架构选型建议**（用户当前诉求）。
>
> **基线（2026-09-04 实测真源）**：`lib/` 15 + `user/` 59 = **74 个 `.lua` 模块**（P1b +`svc`）（另有 2 个 json），16 112 行。
> 入口 `main.lua` → `config`→`module_loader` → `app.start(peripheral, net_mqtt, t31x_ctrl)` → `sys.run()` 事件主循环。
> 版本 `001.000.156`。本图以下覆盖 74 模块的**功能分层**（与 [LUA_MODULES.md](LUA_MODULES.md) 模块树、[SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md) 系统视图互补）。

---

## 1. 功能架构总览（特性域 → 层 → 模块）

```
┌───────────────────────────────── 云 / 后台 ─────────────────────────────────┐
│ panshi MQTT broker ◄─/panshi/app{IMEI}──┐  自建 OTA(差分)    uploadVideo     │
│       ▲          /panshi/device{IMEI}/   │   HTTP GET 2004    :7003(T31x直传)│
└───────┴──────────────────────────────────┴──────────────────────────────────┘
        │ MQTT 200x→ / 100x↑(唯一会话)
        ▼
┌────────────────────────── L4 编排 / 入口（user）─────────────────────────────┐
│ main.lua       VERSION·蜂窝/RNDIS·bootstrapNet→app.start→sys.run             │
│ app.lua        事件订阅/低功耗|USB|PIR→MQTT桥/烧录态（972 行 · 冻结）          │
│ peripheral.lua 按键/LED/PIR 外设编排                                          │
│ config.lua     仅编排：features·cellular·t31x_burn·gpio_cfg·led_pir·         │
│                battery·host·net·flags·events → 全量 _G.X_CFG（L0.5 叶子）     │
└───────┬──────────────────────────────────────────────────────────────────────┘
        │ ① APP_EVENTS 事件总线（sys.publish/subscribe 横切）                   
        │ ② _G.X_CFG 仅经 config_manager 读取；子模块经 bind(C) 注入（零回环）    
        ▼                                                                      
┌────────────────────────── L3 业务协议 / 状态机（user）────────────────────────┐
│ ① MQTT 云面               ② T31x UART-AT 面                                  │
│  net_mqtt(主/任务/锁)        host_uart(主/锁/RX行分发)                          │
│  mqtt_conn · mqtt_dispatch  ├ hif_at（AT 表编译）                             │
│  mqtt_uplink(+mqtt_ul_pir)  ├ hif_cmd(+usb|link|pir|t31x|wled)                │
│  mqtt_downlink(+dl_ctrl|    ├ hif_rx(+dsl|media)                              │
│    dl_dev|dl_pir|dl_tf|     └ hif_ipc(+rec|hostq|cloud|power|tffmt|encode)    │
│    dl_upload)                mqtt_hproto(2020–31 → ②)                         │
│ ③ T31x 协作 / 产品业务                                                       │
│  t31x_ctrl(供电/唤醒) · t31x_policy(门禁) · t31x_notify · ipc_supv(1004/1011) │
│  host_event · pir_ctrl(录像会话) · battery_guard(三档) · vbat(ADC)            │
│  fota_svc · time_sync · sound_prompt · lp_wakeup · net_tcp(桩·默认未启用)     │
└───────┬──────────────────────────────────────────────────────────────────────┘
        │ require 方向严格向下：lib 不反向 require user（config 片段=共享常量例外）
        ▼
┌────────────────────────── L2 核心服务（lib）─────────────────────────────────┐
│ config_manager(配置中枢) · module_loader(裁剪/懒加载) · runtime_power(运行态)  │
│ cell_boot(蜂窝引导) · device_id · libfota2(OTA) · utils(helper/mkLogFns)      │
├────────────────────────── L1 硬件/通道驱动（lib）────────────────────────────┤
│ uart_bridge(唯一 uart.setup) · gpio_util · led_ctrl · watchdog                │
│ usb_rndis(蜂窝共享) · usb_charge · usb_vuart                                  │
├────────────────────────── L0 底座 ──────────────────────────────────────────┤
│ sys.lua(LuatOS 协程 fork · vendor 不改)   LuatOS 系统库(mqtt/socket/rtos/pm…) │
└───────────────────────────────────────────────────────────────────────────────┘

横切：APP_EVENTS 事件总线 · runtime_power 运行态中枢 · MODULE_FLAGS+module_loader 裁剪
      中心模块（require 引用 Top）：config_manager > utils > module_loader > runtime_power > host_uart
```

按特性域的模块归属：

| 特性域 | 主要模块 | 所在层 |
|--------|----------|--------|
| 启动/编排 | `main` `app` `peripheral` `config`(底座) | L4/L0.5 |
| 蜂窝/网络 | `cell_boot` `net_mqtt` `mqtt_*` | L2/L3 |
| USB 通道 | `usb_charge` `usb_rndis` `usb_vuart` | L1/L2 |
| 主机 UART/AT | `host_uart` `hif_cmd*` `hif_rx*` `hif_ipc*` `hif_at` | L3 |
| 协处理器(T31x) | `t31x_ctrl` `t31x_policy` `t31x_notify` `ipc_supv` `hif_ipc*` | L3 |
| 传感/电源 | `vbat` `runtime_power` `battery_guard` `watchdog` | L2/L3 |
| 外设/指示 | `gpio_util` `led_ctrl` `peripheral` | L1/L3 |
| 媒体/PIR | `pir_ctrl` `sound_prompt` + `mqtt_dl_pir`/`mqtt_ul_pir` | L3 |
| OTA | `libfota2` `fota_svc` | L2/L3 |
| 时间 | `time_sync` | L3 |
| 框架底座 | `sys` `module_loader` `config_manager` `utils` | L0/L2 |

---

## 2. 当前分层模型（确认仍成立）

代码层 L0–L4 已在 `CODE_LAYERING_ARCHITECTURE.md` 固化，**依赖方向严格向下、无环**，本次不再重复。要点回顾：

- `lib` = 基础设施/驱动 + 共享核心服务（含 `runtime_power` 运行态中枢、`config` 共享常量）。
- `user` = 编排 + 业务协议 + 产品状态机。
- 已消解的违规：`utils`/`led_ctrl` 从 user 下沉 lib；`host_event`/`t31x_policy`/`t31x_notify`/`lp_wakeup` 从 lib 上浮 user；`runtime_power` 因被 lib 基础设施依赖而留 lib。

**唯一灰色点（非违规）**：`lib/*` 普遍 `require "config"`，而 `config.lua` 在 `user/`。但 `config` 是纯常量/引脚/开关/事件表（叶子节点，不 require 任何业务模块），应正式定为 **L0.5 共享配置底座**（lib 与 user 皆可依赖），无需移动文件。

---

## 3. 解耦机制（为什么当前架构本就健康）

1. **require 方向严格向下**：lib 不 require user 业务模块（仅 `config` 叶子）。
2. **`bind(C)` 依赖注入**消除 handler 子模块的 require 环：
   - `host_uart.start` → `hif_cmd.bind(ctx)` → `hif_cmd_link/pir/t31x/usb/wled`
   - `hif_rx.bind` → `hif_rx_dsl.bind(C)` → `hif_rx_media.bind(C, dsl)`
   - `hif_ipc.bind` → `hif_ipc_rec/hostq/cloud/power/tffmt/encode`
   - `net_mqtt.bind` → `mqtt_conn/uplink/downlink/dispatch/ipc_supv`
   - `mqtt_downlink.bind` → `mqtt_dl_dev/pir/ctrl/tf/upload` + `mqtt_hproto.register`
   - 子模块**零 require 父模块**，纯靠注入，无循环依赖。
3. **`APP_EVENTS` 事件总线**横向解耦（如 `usb_charge` 发布 `GPIO_USB_DET_CHANGED`，`app` 订阅）。
4. **`MODULE_FLAGS` + `module_loader`** 实现可选模块裁剪（USB/充电/4G rest 等可关）。

> 结论：架构骨架正确，**"优化"应是在其上做目录分组、拆 god module、纠偏，而非推倒重来。**

---

## 4. 拆分 / 合并清单（核心交付）

### 4.1 不建议"物理合并"的模块族

`hif_cmd_*`(6) / `hif_ipc_*`(6) / `hif_rx*`(3) / `mqtt_dl_*`(5) / `mqtt_ul_*`(2) 已是**逻辑单模块**（统一 `bind` 入口 + 公共路径）。物理合并会：
- 膨胀单文件到数千行，回归面大；
- **破坏 `MODULE_FLAGS` 粒度加载**（如关掉 PIR 上报仍会打包 pir 子模块）。

→ **不物理合并**，改用目录分组表达（见 4.2）。

### 4.2 建议"目录分组"（纯文件重组，零逻辑改动，低风险）

| 目标子目录 | 归入模块 |
|-----------|----------|
| `user/hif/cmd/` | `hif_cmd` + `hif_cmd_link/pir/t31x/usb/wled` |
| `user/hif/rx/` | `hif_rx` + `hif_rx_dsl` + `hif_rx_media` |
| `user/hif/ipc/` | `hif_ipc` + `hif_ipc_rec/hostq/cloud/power/tffmt/encode` + `hif_at` |
| `user/mqtt/` | `net_mqtt` + `net_tcp` + `mqtt_*`(13) |

**可行性（2026-09-04 修正）**：⚠️ 目录分组会**改变模块全名**——LuatOS `require` 按 `package.path` 以**模块名**找文件，`user/hif/hif_cmd.lua` 无法被 `require "hif_cmd"` 命中（除非扩 `package.path` 并全局同步所有 `require`/`loader.load` 名串与 `__LUATOOLS_SCAN_ANCHOR__`）。即"移动即改名"工程，非零改动；模块边界已由 `hif_*`/`mqtt_*` 前缀自描述 → **不建议优先做**（详见 §7.3）。
**收益**：目录即文档，显式表达"同一子系统"，新读者 30 秒看懂边界。

### 4.3 建议"拆分"（god module）

| 模块 | 体量/问题 | 建议拆分 |
|------|-----------|----------|
| `user/app.lua` | 横跨烧录模式、USB 边沿/电源、低功耗进出、PIR→MQTT 桥、心跳、FOTA、RNDIS、事件订阅、GPIO | **冻结中**（[ARCHITECTURE_REVIEW_20260903](ARCHITECTURE_REVIEW_20260903.md) §6 S2）：纯迁移 `app_power` / `app_pir_bridge` / `app_burn` + ctx 注入，`EVNT_HNDL` 仍集中；解锁后执行 |
| `user/pir_ctrl.lua` | 含 GPIO 中断、冷却、录像会话、云端启停、PIRSTAT 统计、多事件发布 | 受 app 冻结连带；解锁后视需要再评估 `pir_hw`(中断/触发) / `pir_session`(录像会话/冷却) / `pir_report`(PIRSTAT/上行桥) |
| `user/config.lua` | ✅ 已完成：config 片段拆分（`features`/`cellular`/`gpio_cfg`/`led_pir`/`battery`/`host`/`net`/`flags`/`events`） | `config.lua` 仅保留编排 |

### 4.4 建议"重新归类 / 纠偏"

- **`t31x_ctrl` / `t31x_policy` / `t31x_notify`**：实为 **L2 协处理器服务**（被几乎所有模块当底层依赖 require），建议在文档与目录上归为 L2；若追求 lib/user 纯净，可整体移入 `lib/t31x/`（纯移动，因 `config`/`runtime_power` 已下沉 lib，无新违规）。
- **`peripheral.lua`**：维持 L3 编排（定论，见既有文档 §6.2），仅当其继续膨胀时再拆。
- **`net_tcp.lua`**：默认不加载的唤醒桩（`mode=tcp` 未启用），**标注"实验性/未启用"或删除**，避免误导。

### 4.5 小修（运行期耦合点）

- `user/host_uart.lua:587/611` 在回调里 `require "t31x_ctrl"`（动态硬耦合）。改为**启动期注入** `opts.t31x`（`app` 已 require `t31x_ctrl` 可经 `opts` 传入），使依赖图在启动期可见、可静态分析。

> **已纠正的误判**：早前审计称 `vbat.lua` 直写 `APP_RUNTIME` 造成"双通道"。经核查 `vbat.lua:194` 实际调用 `runtimePower.setBattery(...)`，**走 runtime_power 访问器**，无违规。无需改动。

---

## 5. 架构选型：哪个更好？

| 方案 | 做法 | 评价 |
|------|------|------|
| **A（推荐）沿用** | 保留 bind(C) 注入 + 事件总线 + MODULE_FLAGS 裁剪的分层模型；执行 §4.2 目录分组 + §4.3 拆 2–3 个 god module + §4.4 纠偏 + §4.5 小修 | ✅ 零重构风险、保留可选加载粒度、解耦本就良好。治标更治本 |
| **B 物理合并** | 把 `hif_*`/`mqtt_*` 各自合并成单文件 | ❌ 破坏 MODULE_FLAGS 粒度、单文件数千行、回归面大 |
| **C 形式化接口注册表** | 引入 interface/impl 注册机制替代 bind(C) | ❌ 过度设计，对固件收益低、改动大 |

**结论：选 A。** 当前架构本质健康，问题集中在"目录扁平导致子系统边界不显"和"少数 god module 横向膨胀"。优化方向是**目录分组 + 拆 god module + 纠偏**，而不是换架构。

---

## 6. 执行建议（按风险排序）

| 优先级 | 动作 | 涉及文件 | 风险 |
|--------|------|----------|------|
| P0 | 目录分组 `hif/cmd` `hif/rx` `hif/ipc` `mqtt/`（纯移动 + 更新扫描锚点） | 全部 `hif_*` `mqtt_*` `net_tcp` `main.lua` | 低 |
| P0 | `host_uart` 改为启动期注入 `opts.t31x`，去除运行期 `require` | `host_uart.lua` `app.lua` | 低 |
| P1 | 拆分 `app.lua`（冻结：见 [ARCHITECTURE_REVIEW_20260903](ARCHITECTURE_REVIEW_20260903.md) §6 S2） | `app.lua` | 中 |
| P1 | 拆分 `pir_ctrl.lua`（hw/session/report） | `pir_ctrl.lua` | 中 |
| P1 | 归并/标注 `t31x_*` 为 L2 服务（文档 + 可选 `lib/t31x/`） | `t31x_*` `host_uart.lua` | 低–中 |
| P2 | 标注/删除未启用的 `net_tcp.lua` 桩 | `net_tcp.lua` | 低 |
| P2 | 拆分巨型 `config.lua`（hw/feature/runtime） | `config.lua` | 低（可选） |

> 验证手段（接硬件前必跑）：
> ```bash
> python tools/debug/_gen_bind_header.py --check-all
> python tools/debug/_host_uart_regression_check.py
> python tools/debug/_net_mqtt_regression_check.py
> python tools/debug/_module_tree.py --diff
> ```

---

## 7. 简洁与命名体检（2026-09-04 源码实读审计）

> 依据：对 `user/` + `lib/` 73 个 `.lua` 逐文件通读抽样，全部证据取自代码而非文档。
>
> **2026-09-04 执行记录（本批已落地，代码与文档同步）**
> - N1/N2：事件 key 统一 `T31X_*`/`PIR_WAKE_T31X`（对齐 [T31X_NAMING.md](T31X_NAMING.md) 规范），事件值改 `"battery_update"` —— `events.lua` + 全部发布/订阅点（app/pir_ctrl/hif_cmd_t31x/hif_ipc_cloud）。
> - N3/N4：local / ctx 键收敛全拼 —— `batteryGuard`/`ipcSupv`（app、net_mqtt、mqtt_uplink、mqtt_dl_pir）、`t31xCtrl`（sound_prompt、main）。
> - N5（**实为死引用修复**）：`host_uart` 现导出 `hostBusy`（已无 `isHuBusy`），`ipc_supv` 两处 `hostUart.isHuBusy()` 原会 `attempt to call a nil value` → 修为 `hostUart.hostBusy()`；`hif_ipc_cloud` 私有 `isHuBusy`→`isCloudBusy`。⚠️ 属行为面修复，发布请评估并升 `main.lua` VERSION。
> - N6：`main.lua` 全拼化 —— `validateBuildVersion`/`buildIotOtaVersion`/`resolveIotOtaVersion`（`_G` 面与 LUA_MODULES 文档名一致）、local `coreVersion`/`startNetwork`；引用方 mqtt_uplink / mqtt_dl_ctrl / fota_svc 已同步。
> - N7：分层约定已写入 [CAT1_API_NAMING.md](CAT1_API_NAMING.md) §3.1。
> - N8：本文件 §1 图与 [CALL_GRAPH.md](CALL_GRAPH.md) 启动链/依赖表已按真源刷新（config 片段、module_loader、cell_boot / lp_wakeup / usb_vuart）。
> - S2：`host_uart.lua` start() 的 require 兜底已加注释。
> - **目录分组：沿用平铺**（user 建立子目录曾致烧录异常；不改目录，边界仍由 `hif_*`/`mqtt_*` 前缀表达）。
> 待办：实机事件链路冒烟（BATTERY_UPDATE / T31X_IPC_ALERT / PIR_WAKE）、S3 可选聚合、app/pir 拆分（09-14 后）。

### 7.1 命名：不一致证据（按影响排序）

> 下表为实读审计原文（file:line 为审计时点）；各条处置状态见上方执行记录（N5 实际为死引用修复而非改名）。

| # | 证据（file:line） | 问题 | 建议 |
|---|---|---|---|
| N1 | `events.lua:34/36-42`：`PIR_WAKE_t31x`、`t31x_SNAPSHOT_DONE`、`t31x_RECORD_ACTIVE`、`t31x_IPC_ALERT`… | 事件 key 的 `t31x_` 前缀小写，与其余全大写 key 规则冲突 | key 统一 `T31X_*`（UPPER_SNAKE）；值保持小写 snake |
| N2 | `events.lua:44` `BATTERY_UPDATE = "BATTERY_UPDATE"` | 事件值全库唯一大写，破坏"值=小写 snake" | 值改 `"battery_update"` |
| N3 | `app.lua:21/23` `bttrGrd`、`ipcSprv` vs 文件名 `ipc_supv`；`net_mqtt` 局部又写 `ipc_sup` | 同一目标多拼写 + 缩写粒度不一 | local 统一：`batteryGuard`、`ipcSupv` |
| N4 | 同模块 `t31x_ctrl`（app.lua:24、sound_prompt 等）vs `t31xCtrl`（net_mqtt:17、mqtt_hproto、pir_ctrl） | local 接收名风格分裂 | 全库统一一种（推荐 `t31xCtrl`） |
| N5 | `host_uart` 导出 `isHuBusy`、内部 `HU_*` | `hu` 时代缩写唯一残留 | 导出改名 `isHostUartBusy`（先 grep 调用方） |
| N6 | `main.lua:12/19/34/50/145` `valBuildVer/bldIotOtaVer/resIotOtaVer/coreVrsn/strtNetw` | 缩写过短；且 `_G` 三个导出名与 LUA_MODULES 文档名（validateBuildVersion…）漂移 | local 改全拼（`strtNetw→startNetwork`）；`_G` 三函数：改真名或改文档，二选一 |
| N7 | `app.state.mqtt_started`、pir session `last_stop_reason`（snake）vs opts/API camelCase vs 配置键 snake | 字段命名无显式分层成文 | 在 [CAT1_API_NAMING.md](CAT1_API_NAMING.md) 补约定：函数/opts=camel · state/持久化字段=snake · 配置键=snake（不改） |
| N8 | [CALL_GRAPH.md](CALL_GRAPH.md) §1 仍写 `require config, app_config, key_config`、`cellular_bootstrap.start()` | 文档漂移（真源 main.lua:82-125 为 config 片段+`cell_boot`） | 文档按真源刷新 |

### 7.2 简洁：主要发现与处置

| # | 证据 | 说明 | 处置 |
|---|---|---|---|
| S1 | 50+ 文件顶部样板 | 重复 `require config_manager` + `module(...)` + `utils.mkLogFns` + 3 行 local | Lua 无宏，**接受**；维持 `mkLogFns` 收窄 |
| S2 | `host_uart.lua:638` `opts.t31x or require "t31x_ctrl"` | 注入已就位，require 兜底使依赖图启动期非全静态 | 保留兜底 + 注释"仅兼容裸启动"；app 必经注入（低风险，冻结期可做） |
| S3 | JSON 片段 `string.format` 散点（mqtt_conn/uplink/ipc_supv） | 无统一构造器 | 按需抽 `utils.buildJson(fields)` 后逐步替换 |
| S4 | `net_tcp`（桩）· `module_loader.stopAll`（无调用）· 双看门狗 | 死/桩代码 | 维持"标注不清零"（已在 ARCHITECTURE_REVIEW §5/§3.5 标注） |
| S5 | 全库抽查 | 协议族函数由 spec/ctx 驱动，**无 >80 行命令函数** | ✅ 通过，无待拆函数 |

### 7.3 处置状态（2026-09-04 批后）

| 项 | 状态 |
|---|---|
| N1–N6、S2、N7、N8 | ✅ 已执行（见上方执行记录） |
| 目录分组（§4.2） | ❌ 沿用平铺（用户约束：user 子目录曾致烧录异常；需在 `package.path` 层面另行验证才可重议） |
| S3 JSON 聚合 / S4 桩清理 | 可选优化，维持"按需 / 标注不清零" |
| 实机冒烟 | ⏳ 接硬件必跑：`_gen_bind_header.py --check-all`、`_host_uart_regression_check.py`、`_net_mqtt_regression_check.py`、`_module_tree.py --diff`；事件链路 BATTERY_UPDATE / T31X_IPC_ALERT / PIR_WAKE |
| app/pir_ctrl 拆分 | ⏳ 维持 [ARCHITECTURE_REVIEW_20260903.md](ARCHITECTURE_REVIEW_20260903.md) §6 S2/S3（09-14 后） |
