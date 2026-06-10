# 780EHM_PJ

技术文档：**[`doc/README.md`](doc/README.md)** · 命名约定：**[`doc/T3X_NAMING.md`](doc/T3X_NAMING.md)**（含 [T3X_RECORD_MQTT_FLOW.md](doc/T3X_RECORD_MQTT_FLOW.md) 录像 MQTT 流程）


Air780EHM + t3x 摄像头 · LuatOS **方案1**（扁平 `user/` + 精简 `lib/`）。

## 架构一览

```
main.lua
  require config, app_config, key_config
  [cellular_bootstrap] [rndis] net_mqtt.bootstrapNetwork()
  └─ app.start(peripheral, net_mqtt, t3x_ctrl)   ← 18 步，见 doc/CODE_DOC_AUDIT.md §3
       ├─ lib/uart_bridge    UART 驱动（UART_CFG）
       ├─ user/host_uart     T3x AT 业务（setupUartBridge 内同启）
       ├─ net_mqtt           唯一 MQTT（2001–2007/2010–2012/2020 ↓）
       ├─ net_tcp            专有 TCP（LOW_POWER_WAKEUP_CFG.mode=tcp 时懒加载）
       ├─ battery_guard      低电量 / USB 策略
       ├─ vbat + lib/adc_lib 电量采样
       ├─ pir_ctrl + lib/pir
       ├─ t3x_ctrl + t3x_ipc 协处理器电源 / 优雅断电
       └─ peripheral         LED / 按键 / PIR 硬件
```

| 项 | 值 |
|----|-----|
| 配置真源 | `user/config.lua`（硬件）+ `app_config.lua` / `key_config.lua` |
| 文档 | [`doc/`](doc/)（见 [doc/CONFIG.md](doc/CONFIG.md)） |
| 栈选择 | `APP_STACK = { mqtt = "net_mqtt", uart = "uart_bridge" }` |
| 核心固件 | `luatos.json` → Air780EHM SOC |
| 脚本区 | 约 **384KB** 上限；可选模块见 [`archive/slim/README.md`](archive/slim/README.md) |

## 目录

| 路径 | 说明 |
|------|------|
| `user/` | 入口、编排、MQTT、t3x_ctrl、PIR、外设 |
| `lib/` | 串口、GPIO、硬件与 FOTA 库 |
| `doc/` | 协议、硬件、配置说明（Markdown） |
| `lib/archive/` | 旧栈（不参与启动） |

### lib/ 主路径（snake_case）

| 文件 | 用途 |
|------|------|
| `uart_bridge.lua` | 串口唯一入口 |
| `gpio_util.lua` | GPIO 输入中断、输出 `init_level` 初始化 |
| `key.lua` | 按键 / 就绪 |
| `pir.lua` | PIR 硬件中断 |
| `led.lua` | LED 驱动 |
| `adc_lib.lua` / `bat_core.lua` | ADC 采样与电量换算 |
| `usb_charge.lua` | USB / 充电 GPIO |
| `sntp_sync.lua` / `cellular_bootstrap.lua` | 授时 / 蜂窝拨号 |
| `low_power_wakeup.lua` / `t3x_policy.lua` | 唤醒通道 mqtt/tcp / T3x 门禁 |
| `mobile_info.lua` / `watchdog.lua` / `fota.lua` | 蜂窝信息 / WDT / OTA |

### user/ 主路径

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口 |
| `config.lua` | `GPIO_IN` / `GPIO_OUT`（含 `init_level`）、`PIR_CFG`、`BATTERY_CFG`、MQTT… |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| 低功耗 MQTT/TCP 策略 | [doc/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](doc/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md) |
| user/lib 精简流程 | [doc/CAT1_SLIMMING_FLOW.md](doc/CAT1_SLIMMING_FLOW.md) |
| user/lib 精简速查 | [doc/CAT1_USER_LIB_SLIM.md](doc/CAT1_USER_LIB_SLIM.md) |
| `key_config.lua` | `KEY_CONFIG` |
| `app.lua` | 编排中心 |
| `net_mqtt.lua` | MQTT |
| `net_tcp.lua` | T3x TCP 业务通道 |
| `pir_ctrl.lua` / `led_ctrl.lua` | PIR 业务 / LED |
| `peripheral.lua` | 外设聚合 |
| `t3x_ctrl.lua` / `t3x_ipc.lua` | 协处理器 GPIO / IPC 断电 |
| `vbat.lua` / `battery_guard.lua` | 电池采样 / 电量保护 |
| `host_uart.lua` | T3x AT 协议与唤醒 |
| `sound_prompt.lua` / `time_sync.lua` | 提示音 / 时间同步 |

## GPIO 配置速查

在 `config.lua` 的 `GPIO_OUT` 中设置上电电平：

| 字段 | 含义 |
|------|------|
| `init_level` | `gpio.setup` 初始电平（0/1），默认灭/断电多为 **0** |
| `on_level` | 逻辑开启电平（LED 亮、t3x 供电多为 **1**） |

`GPIO_IN` 使用 `pull`、`trigger_mode`、`debounce_ms`、`active_level`（见 [doc/CONFIG.md](doc/CONFIG.md)）。

## 文档导读

完整列表：[doc/README.md](doc/README.md)

## 功能开关

在 `user/app_config.lua` → `MODULE_FLAGS` 中裁剪。

## 打包

`package_project.bat` / `pack.ps1` → `780EHM_PJ_YYYYMMDD.zip`（含 `user/`、`lib/`、`doc/`、`README.md`、`luatos.json`）。

---

**版本** 1.1.0 · **更新** 2026-06-10（文档与 `vbat`/`host_uart`/`publishConnectUplink` 对齐）
