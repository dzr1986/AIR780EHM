# 780EHM_PJ 文档

| 文档 | 说明 |
|------|------|
| [CONFIG.md](CONFIG.md) | **配置索引**：`GPIO_IN`/`GPIO_OUT` 字段、`init_level`、文件命名 |
| [PROJECT_DOC.md](PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动顺序、require、事件流 |
| [CODE_ANALYSIS.md](CODE_ANALYSIS.md) | 架构与风险 |
| [T31_CAT1_GPIO.md](T31_CAT1_GPIO.md) | 原理图级引脚（T31 + Air780） |
| [T31_WAKE_PROTOCOL.md](T31_WAKE_PROTOCOL.md) | GPIO29→PB27 低脉冲与 AT+WAKEVT |
| [KEY_GPIO.md](KEY_GPIO.md) | 按键 / `key_config.lua` |
| [T31_BURN_MODE.md](T31_BURN_MODE.md) | **GPIO28 长按 → T31 烧录**（电量/关停条件） |
| [CHARGE_BATTERY.md](CHARGE_BATTERY.md) | 充电、ADC、MQTT 1003 |
| [PIR_HARDWARE.md](PIR_HARDWARE.md) | PIR 硬件与流程 |
| [PIR_TRIGGER_INTERVAL.md](PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [PIR_PROTOCOL.md](PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) | MQTT 上下行 |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) | 下行命令手册 |

代码真源：`../user/config.lua`、`../user/app_config.lua`、`../user/key_config.lua`。

**模块命名**（与 `user/*.lua` 一致）：`t3x_ctrl`、`led_ctrl`、`pir_ctrl`；`require` 使用同名（如 `require "t3x_ctrl"`）。硬件/协处理器仍称 **t3x**。
