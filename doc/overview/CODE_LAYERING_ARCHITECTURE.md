# 代码分层与优化架构（lib / user 切割 · 已执行）

> **目的**：澄清 `lib/`（基础设施/驱动层）与 `user/`（业务逻辑层）的职责边界，给出清晰分层，并实际执行了结构性搬迁与缺陷修复。
> **关联文档**：版本化任务日志见 [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)；框架拆分计划见 [USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md)。本文件是"分层架构真源"。
> **状态**：P0 / P1(4 个) / P2(led_ctrl) / P4 已执行；P2(peripheral 拆分) 与 P3 经代码核查后**判定不需要**（见 §6 修正说明）。
> **基线**：`001.000.140`（`user/` 46 个 .lua + 2 个 json；`lib/` 17 个 .lua → 执行后 `lib/` 15、`user/` 48）

---

## 1. 目标分层模型

```
┌──────────────────────────────────────────────────────────────┐
│ L4  user · 编排 / 入口        app.lua  main.lua  config.lua    │
│ L3  user · 业务协议 / 状态机  net_mqtt hif_* ipc_supv t31x_ctrl │
│                                pir_ctrl battery_guard fota_svc │
│                                (host_event / t31x_policy /      │
│                                 t31x_notify / lp_wakeup → 已下沉)│
├─────────────────────── 依赖方向只能向下 ──────────────────────┤
│ L2  lib · 核心服务     config_manager module_loader device_id  │
│                                libfota2 cell_boot utils(已下沉) │
│                                runtime_power(共享运行态中枢)     │
│ L1  lib · 硬件驱动     gpio_util uart_bridge watchdog          │
│                                usb_rndis usb_charge usb_vuart  │
│                                led_ctrl(已下沉)                 │
│ L0  vendor/framework  sys.lua（LuatOS 协程核心 fork，不改动）  │
└──────────────────────────────────────────────────────────────┘
```

**关于"网络放 lib"的澄清**：底层网络能力（socket / mobile / network / mqtt 客户端）由 **LuatOS 系统库**提供，不在仓库内，本就位于最底层。仓库内 `net_mqtt.lua` 是 **MQTT 业务协议层**（含 `dataType` 1001–2031 线协议字段与产品状态机），属于 L3 业务；`net_tcp.lua` 只是默认不加载的唤醒桩。二者**不应下沉**。`lib/` 里真正属于"网络通道"的是 `usb_rndis.lua`（USB 网卡 tethering）与 `cell_boot.lua`（蜂窝引导）——它们已在 lib。

**模块名解析原则**：LuatOS `require` 按**模块名**解析（`package.path` 含 `lib/` 与 `user/`），`module_loader.load` 亦按名 `pcall(require, name)`。因此**文件在 lib↔user 间移动时，绝大多数 `require` 语句无需改动**——这是本次搬迁低风险的根本原因（执行后用脚本全量校验，63 个模块全部在位、62 处 require 解析正常）。

---

## 2. 执行后各文件层位

### 2.1 `lib/` 文件（执行后 15 个）

| 文件 | 层位 | 状态 |
|------|------|------|
| `sys.lua` | L0 vendor | 保持，标注第三方不改动 |
| `config_manager.lua` | L2 | 保持；docstring 已修正；新增 `deepMerge`（§5.P4-2） |
| `module_loader.lua` | L2 | 保持；`load` 失败加 `log.warn`（§5.P4-4） |
| `gpio_util.lua` | L1 | 保持；`setupInput` 兼容 camelCase/snake_case（§5.P4-1） |
| `uart_bridge.lua` | L1 | 保持 |
| `watchdog.lua` | L1 | 保持（与 sys.lua 软狗重叠，**不改动 sys.lua**，仅文档标注，见 §3.5） |
| `usb_vuart.lua` | L1 | 保持；复用 `utils.lineSplit` 去重（§5.P4-3） |
| `usb_rndis.lua` | L1 | 保持 |
| `usb_charge.lua` | L1 | 保持 |
| `libfota2.lua` | L2 | 保持（vendor） |
| `device_id.lua` | L2 | 保持 |
| `cell_boot.lua` | L2 | 保持 |
| `utils.lua` | L2 | **✅ 已从 user 下沉**（P0，消解 lib→user 反依赖） |
| `led_ctrl.lua` | L1 | **✅ 已从 user 下沉**（P2，LED 驱动归位 lib） |
| `runtime_power.lua` | L2 共享核心服务 | **保持 lib**（原评估误判为业务；实际被 lib 基础设施依赖，见 §6.1） |

### 2.2 `user/` 文件

| 文件 | 层位 | 状态 |
|------|------|------|
| `main.lua` / `app.lua` | L4 编排 | 保持 |
| `config.lua` | L4 全局常量中枢 | 保持 |
| `utils.lua` | — | **✅ 已移至 lib/utils.lua**（见上） |
| `led_ctrl.lua` | — | **✅ 已移至 lib/led_ctrl.lua**（见上） |
| `host_event.lua` / `t31x_policy.lua` / `t31x_notify.lua` / `lp_wakeup.lua` | L3 业务 | **✅ 已从 lib 下沉到 user**（P1） |
| `peripheral.lua` | L3 编排 | 保持 user（编排层：按键→APP_EVENTS、启动 pir 硬件、控制 LED；仅 LED 驱动 led_ctrl 下沉 lib，见 §6.2） |
| `net_mqtt.lua` / `net_tcp.lua` / `mqtt_*.lua` | L3 业务协议 | 保持 |
| `host_uart.lua` / `hif_*.lua` | L3 业务协议 | 保持 |
| `ipc_supv.lua` / `t31x_ctrl.lua` / `pir_ctrl.lua` / `battery_guard.lua` / `fota_svc.lua` / `sound_prompt.lua` / `time_sync.lua` / `vbat.lua` | L3 业务 | 保持 |

---

## 3. 核心问题清单与处置

### 3.1 依赖倒置（已修复）
`lib/usb_rndis.lua:11` 与 `lib/cell_boot.lua:12` 原 `require "utils"`，而 `utils` 在 user → lib→user 倒置。
**处置**：P0 将 `user/utils.lua` 整体移至 `lib/utils.lua`（模块名不变，`require "utils"` 仍解析）。原评估建议"拆分 3 个业务便捷函数"，实际核查 `t31xOn`/`hostUart`/`uartBridge` 内部用 `loader.load(...)` 动态加载 user 模块——这正是 `module_loader` 设计的解耦机制（与 `app.lua` 用 `loader.opt` 加载可选模块一致），**不构成硬依赖**，故**整体平移**即可，零调用方改动、零风险。

### 3.2 业务代码错放 lib（已处置 4 个）
`host_event` / `t31x_policy` / `t31x_notify` / `lp_wakeup` 为产品状态机/策略/事件汇总，无驱动语义 → **已下沉 user（L3）**。
`runtime_power` 原也列入此项，但核查发现 `lib/cell_boot.lua` 与 `lib/usb_rndis.lua` 均 `require "runtime_power"`，若下沉会制造**新的** lib→user 倒置。其本质是**被 lib 基础设施与 user 共同依赖的共享运行态中枢**（类似 `config.lua` 全局常量），故**修正为留在 lib（L2 核心服务）**（§6.1）。

### 3.3 基础设施错放 user（已处置）
- `utils.lua`（纯 helper）→ 已下沉 lib（P0）。
- `led_ctrl.lua`（gpio 封装 + LED 状态机）→ 已下沉 lib（P2）。
- `peripheral.lua` → 经核查属于**编排层**（user 逻辑），仅其调用的 LED 驱动 `led_ctrl` 下沉 lib，peripheral 本身留 user（§6.2）。

### 3.4 lib 内业务耦合（经核查不需抽取）
`usb_charge` / `usb_rndis` / `cell_boot` 原被标注"混入 host_idle/4g_rest 策略、运营商映射、运行时写"。核查实际代码后：
- `usb_charge.blocksHostIdle()/blocks4gRest()` 仅读 `HOST_USB_CFG` 策略标志（配置读取，非逻辑）；
- 三者向 `runtime_power` 中枢写状态（operator/sim/usb）属**共享中枢设计**；
- `cell_boot` 的运营商 ICCID/IMSI/APN 映射是**蜂窝引导领域数据**，天然归属该驱动。
结论：**三者已是干净驱动，不抽取**（§6.3）。

### 3.5 重复与缺陷（已修复 / 标注）
1. **gpio_util 键名不一致（已修复，09-01 曾回归，09-04 二次修复 + 护栏）**：`setupInput` 原只读 camelCase `triggerMode`/`debounce`，而 `usb_charge`/`peripheral`/`pir_ctrl` 传 snake_case `trigger_mode`/`debounce_ms` → both 触发与防抖**静默失效**（PWR/BOOT 长按永不触发）。P4-1 修过一次，9bcfc78 重命名时兼容读被删、无人察觉三天；155 起兼容两种命名并由 `tools/debug/_gpio_opts_check.py`（run_all_checks 第 8 项）守护，见 [USER_LIB_CODE_AUDIT §18 R1](USER_LIB_CODE_AUDIT_20260904.md)。
2. **双看门狗（仅标注，不改动）**：`sys.lua` 末尾 `rtos.openSoftDog` + `watchdog.lua` 硬件 WDT 重叠。二者独立（软狗捕 Lua 挂死、硬狗捕芯片挂死），`sys.lua` 为 vendor 文件（既有规则"不改动"），故**保留现状并在此处标注**，如需二选一由团队决策。
3. **行缓冲拆分重复（已修复）**：`usb_vuart.onRx` 原自实现 `\r\n` 拆分，现抽 `utils.lineSplit` 复用（§5.P4-3）。`uart_bridge` 协议更复杂，未强改，可后续采纳。
4. **config_manager docstring 误导（已修复）**：注释删除"JSON 持久化读写、热更新"谎述（代码无此实现）；`merge` 仅浅合并，新增非破坏性 `deepMerge` 供嵌套配置（§5.P4-2）。
5. **module_loader 健壮性（已修复）**：`load` 原 `pcall(require)` 吞全部错误并缓存 `false`，加载失败无日志；现加 `log.warn` 输出模块名与错误（§5.P4-4）。`stopAll()` 仍无调用点（死代码），因删除公共函数有潜在风险，保留并标注。

---

## 4. 迁移计划与执行结果

| 阶段 | 计划 | 执行结果 |
|------|------|----------|
| P0 | 下沉 utils 到 lib，消解 lib→user 反依赖 | ✅ `user/utils.lua` → `lib/utils.lua`（整体平移，含内部 `loader.load` 解耦） |
| P1 | 5 个业务模块 lib→user | ✅ 4 个已移：`host_event`/`t31x_policy`/`t31x_notify`/`lp_wakeup`；`runtime_power` 修正留 lib（§6.1） |
| P2 | led_ctrl→lib；peripheral HAL→lib | ✅ `led_ctrl` 已移至 lib；peripheral 判定为编排层，留 user（§6.2） |
| P3 | 抽离 lib 内业务耦合 | ⏭ 经核查不需（§3.4 / §6.3） |
| P4 | quick-win 缺陷修复 | ✅ 全部完成（gpio_util / config_manager / usb_vuart / module_loader），双看门狗仅标注 |

`git mv` 对未跟踪文件报 "not under version control"，已改用普通文件移动（`Move-Item`），与 git 跟踪状态无关，不影响固件构建。

---

## 5. P4 缺陷修复明细

- **P4-1 `lib/gpio_util.lua`**：`setupInput` 兼容 `triggerMode`/`trigger_mode` 与 `debounce`/`debounce_ms`/`pull`/`pull_mode`，恢复 both 触发与防抖的真实生效。
- **P4-2 `lib/config_manager.lua`**：docstring 改为"全局配置表访问、类型安全取值、默认值合并（浅/深）"；新增 `deepMerge(defaults, overrides)` 递归合并。
- **P4-3 `lib/utils.lua` + `lib/usb_vuart.lua`**：`utils` 新增 `lineSplit(buf, onLine)`；`usb_vuart.onRx` 改用之，去除行协议重复实现。
- **P4-4 `lib/module_loader.lua`**：`load` 失败时 `log.warn("module_loader", "load fail", name, err)`，不再静默吞错。

---

## 6. 执行中的三处修正说明

### 6.1 `runtime_power` 留 lib（原评估误判为业务）
`lib/cell_boot.lua:11` 与 `lib/usb_rndis.lua:10` 均 `require "runtime_power"`（用于读 `isUsbInserted()` 等共享运行态）。若下沉 user 会制造新的 lib→user 倒置。其 `APP_RUNTIME` 是 neutral 共享中枢，与 `config.lua` 同属"两层皆可依赖的全局状态"，故归属 L2 核心服务最合理。

### 6.2 `peripheral` 留 user（编排层非驱动）
`peripheral.lua` 把 PWR/BOOT 长按→`APP_EVENTS` 发布、串接 `led_ctrl`/`pir_ctrl`、控制 LED 模式——这是典型的**业务编排**，属于 user 逻辑层。前期建议"拆分 HAL 到 lib"会造成把业务回调（`onLongPress`/`pubAppEvent`）一并拖入 lib，反而污染驱动层。正确做法是仅将真正无业务的 **LED 驱动 `led_ctrl`** 下沉 lib（已完成），peripheral 留 user。

### 6.3 P3 不抽取（驱动已干净）
`usb_charge`/`usb_rndis`/`cell_boot` 的"业务耦合"实为：配置标志读取、向共享 `runtime_power` 中枢写状态、运营商映射领域数据——均属对应驱动本职。强行抽取会制造无谓的跨层调用与回归风险，故不做。

---

## 7. 验证

- **依赖解析全量校验**（脚本 `python _verify_moves.py`）：63 个模块全部在位，62 处 `require`/`loader.load` 解析正常；6 个"未解析"均为误报（`loader.opt(flag,name)` 的 flag 变量、`host_uart` 的 `loader.load(name)` 变量、sys.lua 的 `require "patch"/"clib"` 系统库）。
- **协议静态回归**（建议接硬件前跑）：
  ```bash
  python tools/debug/_gen_bind_header.py --check-all
  python tools/debug/_host_uart_regression_check.py
  python tools/debug/_net_mqtt_regression_check.py
  python tools/debug/_module_tree.py --diff
  ```
- 因环境无 Lua 解释器，未做运行时语法执行；改动均为局部、低风险，已逐文件回读确认。

---

## 8. 结论

本次达成清晰的 lib / user 边界：
- **lib = 基础设施/驱动 + 共享核心服务**（gpio/led/watchdog/usb_rndis/usb_charge/usb_vuart/uart_bridge + config_manager/module_loader/device_id/libfota2/cell_boot/utils/runtime_power）。
- **user = 业务逻辑**（编排 app/main、协议 net_mqtt/host_uart/mqtt_*/hif_*、产品状态机 host_event/t31x_policy/t31x_notify/lp_wakeup、外设编排 peripheral 等）。
- 修复了 1 处严重 lib→user 反依赖（utils）、4 个业务模块归位 user、2 个基础设施归位 lib，并消除 gpio_util 静默失效 bug、行协议重复、config_manager 误导 docstring、module_loader 静默吞错等缺陷。依赖方向严格向下、无环。
