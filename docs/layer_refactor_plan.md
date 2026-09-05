# 逐层重构计划（L0 → L3）

> 自底向上：先收 HAL，再收平台抽象，再收业务边界，最后瘦身应用层。每阶段独立 commit、可独立编译、`run_all_checks` 全绿。  
> 真源：`AGENTS.md`、`.cursor/rules/arch-layering.mdc`。

## 阶段总览

| 阶段 | 层 | 目标 | 状态 |
|---|---|---|---|
| **L0** | HAL 驱动 | user/ 零硬件直调；`power_hal` / `adc_hal` / `gpio_util.getLevel` | **已完成**（2026-09-05） |
| **L1** | 平台抽象 | `runtime_power` 收口设备级 power 语义；config 域零业务泄漏 | **已完成**（2026-09-05） |
| **L2** | 业务逻辑 | AT/MQTT 族边界巩固；跨族常量进 `HOST_PROTO_TMO`；`patchCloud` 局部补丁一律 keepTs | **已完成**（2026-09-05，零 VERSION） |
| **L3** | 应用 | `app.lua` 只做装配（provider/事件/hooks），业务算法不下沉 | 持续 |

---

## L0 · HAL 驱动层（已完成）

### 决策 ADR-L0-01

**user/ 禁止直调 `pm.*` / `pmd.*` / `adc.*` / `gpio.get` / `uart.setup` 等**；全部经 lib/ 白名单模块：

| 模块 | 封装 |
|---|---|
| `lib/power_hal.lua` | `shutdown` / `reboot` / `hibernate` / `initPwkMode` / `initPmd` |
| `lib/adc_hal.lua` | `configure` / `open` / `close` / `readMv` |
| `lib/gpio_util.lua` | `getLevel`（原有 `setupInput/setupOutput` 不变） |

### 迁移清单（10 → 0 处 user 直调）

- `app.lua` → `powerHal` + `gpio_util.getLevel`
- `battery_guard.lua` → `powerHal.shutdown` fallback
- `t31x_ctrl.lua` → `powerHal.hibernate`
- `vbat.lua` → `adcHal`
- `peripheral.lua` → `gpio_util.getLevel`
- `main.lua` → `powerHal.initPwkMode`

### 护栏

`tools/debug/_hal_layer_check.py`（`run_all_checks` #14）：user/ 零容忍；lib/ 仅 12 个白名单文件可含 HAL 调用。

### 验收

- `rg` user 层 HAL 调用 = 0
- 行为等价（零行为，VERSION 维持 161）

---

## L1 · 平台抽象层（已完成，2026-09-05）

### 决策 ADR-L1-01

**设备级 `pm/pmd` 语义经 `runtime_power` 导出**，内部调 `power_hal`（L1→L0）；`user/` **零** `require "power_hal"`。

| API（`runtime_power`） | 原调用方 | 内部 |
|---|---|---|
| `requestDeviceShutdown()` | `app.onPowerOff`、`battery_guard` fallback | `power_hal.shutdown` |
| `requestDeviceReboot(delayMs)` | `app.onReboot` | `power_hal.reboot` |
| `requestModemHibernate()` | `t31x_ctrl.enterSleep`（modem hibernate 路径） | `power_hal.hibernate` |
| `initPwkMode()` | `main.lua` 冷启动 | `power_hal.initPwkMode` |
| `initPmd(onMsg)` | `app.setupPmd` | `power_hal.initPmd` |

PSM 低功耗态（`requestRest`/`requestNormal`）与设备关机/重启**正交**：前者改 `APP_RUNTIME.power.rest` + hooks；后者直接调 pm 原语。

### 护栏

`_hal_layer_check.py` 扩展：`user/` 出现 `require "power_hal"` → FAIL（负向 fixture `hal_require_power_bad.lua`）。

### 验收

- `rg 'require "power_hal"' user/` = 0
- 零行为，VERSION 维持 161

---

## L2 · 业务逻辑层（已完成，2026-09-05）

### 目标

1. **局部 `patchCloud` 统一 `keepTs=true`**（完整 `+IPCSTAT:` 快照仍走 `commitIpcStat(notify=true)`）  
2. **跨族同值常量**（3500/3000/800 ms）收进 `HOST_PROTO_TMO` 六键  
3. **AT 层 R4 维持 0**；禁止新增 `modCall` 业务调用  
4. **MQTT 族** 与 **AT 族** 互不 require

### 改动摘要

- `host.lua` `_G.HOST_PROTO_TMO` 扩展六键；`host_uart.TMO_SHARED`、`hif_ipc_*`、`mqtt_dl_pir`、`time_sync`、`sound_prompt` 改引  
- `hif_rx_dsl.patchCloud` 内部固定 `commitIpcStat(..., keepTs=true)`（WLED/TFCARD/ipcReady/cat1Link/alert 补丁不再刷新 `ipc_cloud_stat_ts`）

### 验收

- 实机：格式化/断电/1003/2011 回归（待办）  
- `AT+PIRSTAT?` 逐字比对（待办）  
- `run_all_checks` 全 PASS；VERSION 维持 161（架构一致性收口，非新语义）

---

## L3 · 应用层（进行中）

### 目标

- `app.buildBizProviders` 为 AT 层唯一业务入口（已完成 A 条）
- `bindPowerHooks` 为 PSM 副作用唯一入口（已完成 E 条）
- 逐步把 `app.lua` 内可下沉 L2 的纯策略迁出（**不拆文件**，F-01 冻结）

### 已完成（2026-09-05）

- **烧录模式策略** → `user/t31x_burn_ctrl.lua`（电量门禁、服务裁剪、`entBootMode`）；`app` 仅 `bind` + 事件桥；`state.t31x_burn_active` 收进 `t31xPolicy.isBurnActive()`
- **PIR→MQTT/T31x 桥** → `user/pir_app_bridge.lua`（停录上报、pir_watch 休眠、媒体唤醒）；`app` EVNT_HNDL 改引 bridge handler
- **`bootMqtt` 等网上限** → `MQTT_CFG.boot_net_wait_ms`（默认 300000）

### 下一步

- USB/电源边沿策略评估是否迁 `battery_guard` / `runtime_power`
- 实机：PIR 停录 1011、2011、pir_watch 休眠回归

---

## 提交节奏

每完成一层：

1. `python3 tools/debug/run_all_checks.py` 全 PASS  
2. `doc/overview/USER_LIB_OPTIMIZATION_NEXT.md` §8 一行  
3. 本文件阶段表改状态  
4. 有行为改动 → `VERSION +1`；纯 HAL 封装 → 维持
