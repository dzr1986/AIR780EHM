# 780EHM_PJ

Air780EHM + t3x 摄像头 · LuatOS **方案1**（扁平 `user/` + 精简 `lib/`）。

## 架构一览

```
main.lua
  └─ app.start(peripheral, net, t3x)
       ├─ uartBridge     唯一串口（AT / STR / HEX）
       ├─ net            唯一 MQTT（2003–2011 ↓ / 1001–1011 ↑）
       ├─ fota           MQTT 2004 OTA → libfota2
       ├─ pirCtrl + lib/pir
       ├─ t3x            协处理器电源 / 唤醒
       └─ peripheral     LED / 按键 / PIR 硬件
```

| 项 | 值 |
|----|-----|
| 配置真源 | `user/config.lua` |
| 栈选择 | `APP_STACK = { mqtt = "net", uart = "uartBridge" }` |
| MQTT 启动 | 上电 `bootMqtt` → `net_ready` → 常电联网 |
| 核心固件 | `luatos.json` → Air780EHM SOC |

## 目录

| 路径 | 说明 |
|------|------|
| `user/` | 入口、编排、MQTT、串口、t3x、PIR、外设（11 个 Lua） |
| `lib/` | 硬件与 FOTA 库（9 个，见下表） |
| `lib/archive/` | 旧 MQTT 栈、演示库（**不参与启动**） |

### lib/ 主路径（9）

| 文件 | 用途 |
|------|------|
| `gpioUtil.lua` | GPIO 输入 |
| `pir.lua` | PIR 硬件中断 |
| `led.lua` | LED 驱动 |
| `battery.lua` / `charge.lua` | 电量 / 充电 |
| `sntpSync.lua` | 授时 |
| `mobileInfo.lua` | 蜂窝信息 |
| `watchdog.lua` | 模组 WDT |
| `fota.lua` | OTA（MQTT 2004） |

### user/ 主路径（11）

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口 |
| `config.lua` | 全局配置、`MODULE_FLAGS`、`APP_EVENTS` |
| `app.lua` | 编排、低功耗、事件、MQTT/FOTA 启动 |
| `net.lua` | MQTT |
| `uartBridge.lua` | 串口 |
| `t3x.lua` | 协处理器 |
| `pirCtrl.lua` | PIR 业务 |
| `peripheral.lua` | 外设聚合 |
| `ledCtrl.lua` / `powerKey.lua` / `t3xKey.lua` | 外设子模块 |

## 文档导读

按阅读目的选择，避免重复翻阅：

| 文档 | 适合 |
|------|------|
| [user/MQTT_PROTOCOL.md](user/MQTT_PROTOCOL.md) | **MQTT 协议全文**（2003–2011 / 1001–1004 / 1011） |
| [user/MQTT_DOWNLINK.md](user/MQTT_DOWNLINK.md) | **下行命令手册**（按分类：配置/控制/电源/PIR/OTA） |
| [user/MQTT_DOWNLINK_862323084068124.txt](user/MQTT_DOWNLINK_862323084068124.txt) | 指定 IMEI 的 MQTTX 测试抄录 |
| [user/UART_PROTOCOL.md](user/UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [user/PIR_PROTOCOL.md](user/PIR_PROTOCOL.md) | PIR、2010 / 2011 / 1011 |
| [user/CALL_GRAPH.md](user/CALL_GRAPH.md) | 启动顺序、require、事件流速查 |
| [user/PROJECT_DOC.md](user/PROJECT_DOC.md) | 模块职责、GPIO、业务流程、调试 |
| [user/CODE_ANALYSIS.md](user/CODE_ANALYSIS.md) | 架构分析、风险与扩展点 |
| [lib/archive/README.md](lib/archive/README.md) | 归档库说明 |

> 历史配置说明见 [user/projectConfig.md](user/projectConfig.md)（**非**运行配置，以 `config.lua` 为准）。

## 功能开关（`MODULE_FLAGS`）

在 `user/config.lua` 中裁剪功能：

| 开关 | 默认 | 作用 |
|------|------|------|
| `mqtt` | true | 常电 MQTT |
| `fota` | true | OTA（2004 / AT+OTA） |
| `uart_bridge` | true | 串口桥 |
| `gpio` | true | LED / 按键 / PIR |
| `watchdog` | true | 模组看门狗 |
| `pmd_runtime` | true | USB 插拔 |
| `battery` / `charge` / `sntp` / `mobile_info` | true | 后台服务 |

## 打包

| 方式 | 说明 |
|------|------|
| 双击 `package_project.bat` | 调用 `pack.ps1`，生成 **`780EHM_PJ_YYYYMMDD.zip`** |
| `powershell -File pack.ps1` | 同上 |

压缩包包含：`user/`、`lib/`（含 archive）、`README.md`、`luatos.json`。  
烧录固件仍用 `luatos.json` + Luatools。

---

**版本** 1.0.0 · **更新** 2026-05-18
