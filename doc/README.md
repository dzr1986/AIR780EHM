# 780EHM_PJ 文档

| 文档 | 说明 |
|------|------|
| [CONFIG.md](CONFIG.md) | **配置索引**：`GPIO_IN`/`GPIO_OUT`、**§Air780 GPIO 编号对照** |
| [PROJECT_DOC.md](PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动顺序、require、事件流 |
| [CODE_ANALYSIS.md](CODE_ANALYSIS.md) | 架构与风险 |
| [T31_CAT1_GPIO.md](T31_CAT1_GPIO.md) | 原理图级引脚；**§1.1 固件 GPIO 全表** |
| [T31_WAKE_PROTOCOL.md](T31_WAKE_PROTOCOL.md) | GPIO29→PB27 低脉冲与 AT+WAKEVT |
| [KEY_GPIO.md](KEY_GPIO.md) | 按键 / `key_config.lua` |
| [T31_BURN_MODE.md](T31_BURN_MODE.md) | **GPIO28 长按 → T31 烧录**（电量/关停条件） |
| [CHARGE_BATTERY.md](CHARGE_BATTERY.md) | 充电、ADC、MQTT 1003 |
| [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) | **低电量 vs 低功耗**：指示灯、MQTT、`battery_guard` 分级保护 |
| [PIR_HARDWARE.md](PIR_HARDWARE.md) | PIR 硬件与流程 |
| [PIR_TRIGGER_INTERVAL.md](PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [PIR_COOLDOWN_AND_COUNT.md](PIR_COOLDOWN_AND_COUNT.md) | **冷却 vs 计数**（概念与 AT 字段） |
| [PIR_PROTOCOL.md](PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [T31_CAT1_AT_COMMAND_SPEC.md](T31_CAT1_AT_COMMAND_SPEC.md) | **T31→4G AT 规范（MQTT + TCP 双链路）** |
| [T31_4G_FRAMEWORK.md](T31_4G_FRAMEWORK.md) | **T31↔4G 协作框架（简图，建议先读）** |
| [T31_4G_AT_INTERACTION.md](T31_4G_AT_INTERACTION.md) | T31↔4G AT 全量交互、PIR 状态 AT 查询 |
| [HOST_MQTT_UART.md](HOST_MQTT_UART.md) | T31 `AT+MQTTCFG` 下发 4G MQTT |
| [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md) | MQTT 配置两种思路（等 T31 / 上电自动连+覆盖） |
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) | MQTT 上下行（含 **§1.1 App Topic 用法**） |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) | 下行命令手册（含 MQTT.fx Publish/Subscribe） |

代码真源：`../user/config.lua`、`../user/app_config.lua`、`../user/key_config.lua`。

**模块命名**（与 `user/*.lua` 一致）：`t3x_ctrl`、`led_ctrl`、`pir_ctrl`；`require` 使用同名（如 `require "t3x_ctrl"`）。硬件/协处理器仍称 **t3x**。
