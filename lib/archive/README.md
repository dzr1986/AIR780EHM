# lib/archive

历史/演示库，**不参与** `main.lua` 启动链。

## 主路径在用（`../` 根目录，共 18 个）

| 文件 | 用途 |
|------|------|
| `gpio_util.lua` | GPIO 输入（pir / key） |
| `pir.lua` | PIR 硬件中断 |
| `led.lua` | LED 灯效（`user/led_ctrl`） |
| `adc_lib.lua` / `bat_core.lua` | ADC 采样与电量映射（`user/vbat` 编排） |
| `usb_charge.lua` | USB 充电检测 |
| `usb_rndis.lua` | RNDIS USB 网卡 |
| `uart_bridge.lua` | 唯一 `uart.setup` |
| `key.lua` | 按键（pwrkey/bootkey/ready） |
| `sntp_sync.lua` | 网络授时 |
| `cellular_bootstrap.lua` | 蜂窝/APN 拨号 |
| `mobile_info.lua` | 蜂窝信息（无串口） |
| `low_power_wakeup.lua` | 低功耗唤醒通道（mqtt/tcp） |
| `t3x_policy.lua` | T3x 上电/唤醒门禁 |
| `host_event.lua` | HOSTEVT 事件封装 |
| `watchdog.lua` | Air780 模组 WDT |
| `fota.lua` / `libfota2.lua` | OTA（MQTT 2004 → libfota2） |

T3x AT 业务在 **`user/host_uart.lua`**；MQTT 在 **`user/net_mqtt.lua`**。

## 本目录归档文件

| 文件 | 说明 |
|------|------|
| `fota.lua` | 旧版 FOTA 事件封装（已由 `../fota.lua` 替代） |
| `powerMode.lua` | 模组 `pm.WORK_MODE`（与 uart_bridge 冲突） |
| ~~旧 MQTT 栈~~ | 已移除；现行 **`user/net_mqtt.lua`**（见 [MQTT_PROTOCOL.md](../../doc/MQTT_PROTOCOL.md)） |
| `netClient.lua` / `sleepMode.lua` | 旧网络/休眠 |
| `configMerge.lua` | 配置合并工具 |
| `pins.lua` / `gpioInput.lua` | GPIO 演示 |
| `pbCodec.lua` | Protobuf |
| `demoTask.lua` / `pwmTask.lua` / `airlbsTask.lua` | 演示任务 |

复用归档库时请自行 `require` 并接回 `user/app.lua`；MQTT 主路径为 **`user/net_mqtt.lua`**。
