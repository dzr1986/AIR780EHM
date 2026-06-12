# 780EHM_PJ

技术文档：**[`doc/README.md`](doc/README.md)** · 命名约定：**[`doc/T3X_NAMING.md`](doc/T3X_NAMING.md)**（含 [T3X_RECORD_MQTT_FLOW.md](doc/T3X_RECORD_MQTT_FLOW.md) 录像 MQTT 流程）

Air780EHM + T3x 摄像头 · LuatOS **方案1**（扁平 `user/` + 精简 `lib/`）。

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
       ├─ user/vbat          电量 ADC 采样（自包含）
       ├─ pir_ctrl           PIR 硬件 + 业务 + PIRSTAT 统计
       ├─ t3x_ctrl           协处理器电源 / IPC 优雅断电 / ready 轮询
       └─ peripheral         LED / 按键 / PIR 硬件启动
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
| `user/` | 入口、编排、MQTT、t3x_ctrl、PIR、外设、OTA、授时 |
| `lib/` | 串口、GPIO 工具、USB/蜂窝/唤醒/策略等公共库 |
| `doc/` | 协议、硬件、配置说明（Markdown） |
| `lib/archive/` | 旧栈（不参与启动） |

### lib/ 主路径（参与启动）

| 文件 | 用途 |
|------|------|
| `uart_bridge.lua` | 串口唯一入口 |
| `gpio_util.lua` | GPIO 输入中断、输出初始化 |
| `usb_charge.lua` | USB / 充电 GPIO |
| `usb_rndis.lua` | RNDIS（可选） |
| `cellular_bootstrap.lua` | 蜂窝拨号引导 |
| `low_power_wakeup.lua` / `t3x_policy.lua` | 唤醒通道 mqtt/tcp / T3x 门禁 |
| `host_event.lua` / `device_id.lua` / `usb_policy.lua` | HOSTEVT / IMEI / USB 策略 |
| `watchdog.lua` | 模组 WDT |

按键、PIR 硬件、LED、电池采样、FOTA、SNTP 授时已合并进 `user/`（见下表）。

### user/ 主路径

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口 |
| `config.lua` | `GPIO_IN` / `GPIO_OUT`、`PIR_CFG`、`BATTERY_CFG`、MQTT… |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| `key_config.lua` | `KEY_CONFIG` |
| `app.lua` | 编排中心 |
| `net_mqtt.lua` | MQTT |
| `net_tcp.lua` | T3x TCP 业务通道（LuatTools 清单必需；MQTT 模式懒加载） |
| `pir_ctrl.lua` | PIR 硬件中断、冷却、录像会话、PIRSTAT |
| `led_ctrl.lua` | 红蓝 LED、开机序列、电量灯效 |
| `peripheral.lua` | 外设聚合（含按键逻辑） |
| `t3x_ctrl.lua` | 协处理器 GPIO / IPC 断电 / ready |
| `vbat.lua` / `battery_guard.lua` | 电池采样 / 电量保护 |
| `host_uart.lua` | T3x AT 协议与唤醒 |
| `fota_svc.lua` | MQTT 2004 OTA（HTTP 走 libfota2） |
| `sound_prompt.lua` / `time_sync.lua` | 提示音 / 时间同步 |

精简与开关说明：[doc/CAT1_SLIMMING_FLOW.md](doc/CAT1_SLIMMING_FLOW.md) · [doc/CAT1_USER_LIB_SLIM.md](doc/CAT1_USER_LIB_SLIM.md) · 低功耗策略 [doc/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](doc/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md)

## GPIO 配置速查

在 `config.lua` 的 `GPIO_OUT` 中设置上电电平：

| 字段 | 含义 |
|------|------|
| `init_level` | `gpio.setup` 初始电平（0/1），默认灭/断电多为 **0** |
| `on_level` | 逻辑开启电平（LED 亮、T3x 供电多为 **1**） |

`GPIO_IN` 使用 `pull`、`trigger_mode`、`debounce_ms`、`active_level`（见 [doc/CONFIG.md](doc/CONFIG.md)）。

## 文档导读

完整列表：[doc/README.md](doc/README.md)

## 功能开关

在 `user/app_config.lua` → `MODULE_FLAGS` 中裁剪。

## 打包

`package_project.bat` / `pack.ps1` → `780EHM_PJ_YYYYMMDD.zip`（含 `user/`、`lib/`、`doc/`、`README.md`、`luatos.json`）。

---

**版本** 1.2.0 · **更新** 2026-06-11（文档与模块合并 / MQTT 1003 `usbInserted` 对齐）
