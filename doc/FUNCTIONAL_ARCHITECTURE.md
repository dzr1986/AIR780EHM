# 功能架构与分层优化（lib / user · 功能视角）

> **定位**：本文档与 [CODE_LAYERING_ARCHITECTURE.md](CODE_LAYERING_ARCHITECTURE.md)（代码层 L0–L4 切割真源，已执行）互补。
> - 既有文档回答"**代码按什么层放**"（基础设施 vs 业务）。
> - 本文档回答"**功能按什么域组织**"，并给出**拆分/合并清单**与**架构选型建议**（用户当前诉求）。
>
> **基线**：`lib/` 15 个、 `user/` 48 个 `.lua`（含 2 个 json）。入口 `main.lua` → `app.start(peripheral, net, t31x_ctrl)` → `sys.run()` 事件主循环。

---

## 1. 功能架构总览（特性域 → 层 → 模块）

```
                         ┌─────────────────────────────────────────────┐
   编排/入口  (L4)        │ main · app(编排) · peripheral(外设编排)         │
                         └─────────────────────────────────────────────┘
   ┌─────────── 业务协议 / 状态机 (L3) ───────────┐
   │ 蜂窝/网络 : net_mqtt + mqtt_*  (1001–2031 线协议)          │
   │ USB/AT   : host_uart + hif_cmd_* + hif_rx_* + hif_ipc_*       │
   │ 协处理    : ipc_supv · t31x_ctrl/policy/notify(实为L2服务)  │
   │ 产品特性  : pir_ctrl · battery_guard · fota_svc ·           │
   │            sound_prompt · time_sync · lp_wakeup · host_event│
   └───────────────────────────────────────────────────────────┘
   ┌─────────── 核心服务 / 驱动 (L2 / L1) ─────────┐
   │ 传感/电源 : vbat · runtime_power · usb_charge · watchdog   │
   │ USB通道  : usb_rndis · usb_vuart                          │
   │ 蜂窝引导 : cell_boot · device_id                         │
   │ 框架     : config_manager · module_loader · utils · libfota2│
   │ 硬件驱动 : gpio_util · uart_bridge · led_ctrl            │
   └─────────────────────────────────────────────────────────┘
   ┌─────────── 底座 (L0 / L0.5) ────────────────┐
   │ sys(LuatOS协程) · config(共享常量/引脚/开关/事件表)        │
   └─────────────────────────────────────────────────────────┘

   横切 : APP_EVENTS 事件总线(sys.publish/subscribe) · APP_RUNTIME 运行态中枢
          MODULE_FLAGS 可选模块裁剪(module_loader) · _G 全局常量(PROJECT/VERSION)
```

按特性域的模块归属：

| 特性域 | 主要模块 | 所在层 |
|--------|----------|--------|
| 启动/编排 | `main` `app` `peripheral` `config`(底座) | L4/L0.5 |
| 蜂窝/网络 | `cell_boot` `net_mqtt` `mqtt_*` | L2/L3 |
| USB 通道 | `usb_charge` `usb_rndis` `usb_vuart` | L1/L2 |
| 主机 UART/AT | `host_uart` `hif_cmd*` `hif_rx*` `hif_ipc*` `hif_at` | L3 |
| 协处理器(T31x) | `t31x_ctrl` `t31x_policy` `t31x_notify` `ipc_supv` `hif_ipc*` | L2/L3 |
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

**可行性**：LuatOS `require` 按**模块名**解析（`package.path` 含 `lib/`、`user/` 及子目录），移动文件不改 `require` 语句；仅 `main.lua` 的 `__LUATOOLS_SCAN_ANCHOR__` 静态扫描锚点需同步列新路径。移动后跑 `python tools/debug/_module_tree.py --diff` 校验 63 模块全在位即可。
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
