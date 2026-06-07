# lib/archive

历史/演示库，**不参与** `main.lua` 启动链。

## 主路径在用（`../` 根目录，共 9 个）

| 文件 | 用途 |
|------|------|
| `gpioUtil.lua` | GPIO 输入（pir / key） |
| `pir.lua` | PIR 硬件中断 |
| `led.lua` | LED 灯效（`user/ledCtrl`） |
| `battery.lua` | 电量 |
| `charge.lua` | [归档] 充电检测；主路径用 `user/charge.lua` |
| `sntpSync.lua` | 网络授时 |
| `mobileInfo.lua` | 蜂窝信息（无串口） |
| `watchdog.lua` | Air780 模组 WDT |
| `fota.lua` | **当前** OTA（MQTT 2004 → libfota2） |

串口由 **`lib/uartBridge.lua`** 统一管理。

## 本目录归档文件

| 文件 | 说明 |
|------|------|
| `fota.lua` | 旧版 FOTA 事件封装（已由 `../fota.lua` 替代） |
| `powerMode.lua` | 模组 `pm.WORK_MODE`（与 uartBridge 冲突） |
| `mqttSession.lua` / `mqttCommand.lua` / `mqttReport.lua` | 旧 MQTT 栈 |
| `netClient.lua` / `sleepMode.lua` | 旧网络/休眠 |
| `configMerge.lua` | 配置合并工具 |
| `pins.lua` / `gpioInput.lua` | GPIO 演示 |
| `pbCodec.lua` | Protobuf |
| `demoTask.lua` / `pwmTask.lua` / `airlbsTask.lua` | 演示任务 |

复用归档库时请自行 `require` 并接回 `user/app.lua`；MQTT 主路径为 **`user/net_mqtt.lua`**。
