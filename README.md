# 780EHM_PJ

Air780EHM + t3x 摄像头 · LuatOS **方案1**（扁平 `user/` + 精简 `lib/`）。

## 架构一览

```
main.lua
  └─ app.start(peripheral, net, t3x)
       ├─ lib/uart_bridge   唯一串口（AT / STR / HEX）
       ├─ net               唯一 MQTT（2003–2011 ↓ / 1001–1011 ↑）
       ├─ fota              MQTT 2004 OTA → libfota2
       ├─ pir_ctrl + lib/pir
       ├─ t3x               协处理器电源 / 唤醒
       └─ peripheral        LED / 按键 / PIR 硬件
```

| 项 | 值 |
|----|-----|
| 配置真源 | `user/config.lua`（硬件）+ `app_config.lua` / `key_config.lua` |
| 文档 | [`doc/`](doc/)（见 [doc/CONFIG.md](doc/CONFIG.md)） |
| 栈选择 | `APP_STACK = { mqtt = "net", uart = "uart_bridge" }` |
| 核心固件 | `luatos.json` → Air780EHM SOC |

## 目录

| 路径 | 说明 |
|------|------|
| `user/` | 入口、编排、MQTT、t3x、PIR、外设 |
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
| `sntp_sync.lua` / `mobile_info.lua` | 授时 / 蜂窝信息 |
| `watchdog.lua` / `fota.lua` | WDT / OTA |

### user/ 主路径

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口 |
| `config.lua` | `GPIO_IN` / `GPIO_OUT`（含 `init_level`）、`PIR_CFG`、`BATTERY_CFG`、MQTT… |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| `key_config.lua` | `KEY_CONFIG` |
| `app.lua` | 编排中心 |
| `net.lua` | MQTT |
| `pir_ctrl.lua` / `led_ctrl.lua` | PIR 业务 / LED |
| `peripheral.lua` | 外设聚合 |
| `t3x.lua` / `bat_adc.lua` | 协处理器 / 电池采样 |

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

**版本** 1.0.0 · **更新** 2026-05-21
