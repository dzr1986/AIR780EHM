# 780EHM_PJ 文档

## 术语（命名约定）

**完整说明**：[T3X_NAMING.md](T3X_NAMING.md)（`t3x`/`T3x`/`T3X` 协处理器系列命名）。

| 文档 | 说明 |
|------|------|
| [CONFIG.md](CONFIG.md) | **配置索引**：`GPIO_IN`/`GPIO_OUT`、**§Air780 GPIO 编号对照** |
| [PROJECT_DOC.md](PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动顺序、require、事件流 |
| [CODE_ANALYSIS.md](CODE_ANALYSIS.md) | 架构与风险 |
| [T3X_CAT1_GPIO.md](T3X_CAT1_GPIO.md) | 原理图级引脚；**§1.1 固件 GPIO 全表** |
| [T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md) | GPIO29→PB27 低脉冲与 AT+HOSTEVT / HOSTEVTCLR |
| [KEY_GPIO.md](KEY_GPIO.md) | 按键 / `key_config.lua` |
| [T3X_BURN_MODE.md](T3X_BURN_MODE.md) | **GPIO28 长按 → T3x 烧录**（电量/关停条件） |
| [CHARGE_BATTERY.md](CHARGE_BATTERY.md) | 充电、ADC、MQTT 1003 |
| [LED_INDICATORS.md](LED_INDICATORS.md) | **指示灯专篇**：充电板灯 + 模组红蓝灯、规则与调试 |
| [T3X_LOW_POWER.md](T3X_LOW_POWER.md) | **低功耗可配置**：双端开关、rest 主流程、**MQTT conack 与 1001/1002/1003**、验证清单 |
| [T3X_IPC_4G_INTERACTION.md](T3X_IPC_4G_INTERACTION.md) | **T3x↔4G 总览**：分层、PIR/录像/rest 流程、优化记录、验证清单 |
| [T3X_IPC_CAT1_COMM_COMPLETENESS.md](T3X_IPC_CAT1_COMM_COMPLETENESS.md) | **T3x App ↔ Cat.1 Lua 通讯完善度**：双向 AT 对照、时序闭环、缺口与验证 |
| [T3X_HOSTEVT_SLEEP.md](T3X_HOSTEVT_SLEEP.md) | **HOSTEVT 四条 AT**：`HOSTEVT?`/`CLR`/`HOSTIDLE` 汇总、消费、休眠 |
| [T3X_USB_HOSTIDLE.md](T3X_USB_HOSTIDLE.md) | **USB 插入 ↔ T3x/4G 低功耗互斥**（`+CAT1:USB` / `HOSTIDLE:USB`，780EHM_PJ） |
| [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) | **低电量/USB/rest/T3x**（文首场景流程图 + 附录查表） |
| [POWER_USB_BATTERY_T3X_LOGIC.md](POWER_USB_BATTERY_T3X_LOGIC.md) | 架构维护（决策图、模块职责、已修复对照） |
| [RELEASE_v1.2.md](RELEASE_v1.2.md) | **v1.2 发布/备份说明** |
| [BOOT_SHUTDOWN_SOUND.md](BOOT_SHUTDOWN_SOUND.md) | **开机/关机提示音**：T3x 播放、4G 编排、AT 协议与场景 |
| [PIR_HARDWARE.md](PIR_HARDWARE.md) | PIR 硬件与流程 |
| [PIR_TRIGGER_INTERVAL.md](PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [PIR_COOLDOWN_AND_COUNT.md](PIR_COOLDOWN_AND_COUNT.md) | **冷却 vs 计数**（概念与 AT 字段） |
| [PIR_PROTOCOL.md](PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md) | **T3x 录像状态 AT+RECORD + MQTT 1010/1011** |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [T3X_CAT1_AT_COMMAND_SPEC.md](T3X_CAT1_AT_COMMAND_SPEC.md) | **T3x→4G AT 规范（MQTT + TCP 双链路）** |
| [T3X_4G_FRAMEWORK.md](T3X_4G_FRAMEWORK.md) | **T3x↔4G 协作框架（简图，建议先读）** |
| [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) | T3x↔4G AT 全量交互、PIR 状态 AT 查询 |
| [HOST_MQTT_UART.md](HOST_MQTT_UART.md) | T3x `AT+MQTTCFG` 下发 4G MQTT |
| [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md) | MQTT 配置两种思路（等 T3x / 上电自动连+覆盖） |
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) | MQTT 上下行（含 **§1.1 App Topic 用法**） |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) | 下行命令手册（含 MQTT.fx Publish/Subscribe） |

代码真源：`../user/config.lua`、`../user/app_config.lua`、`../user/key_config.lua`。

**模块命名**（与 `user/*.lua` 一致）：`t3x_ctrl`、`t3x_policy`、`pir_ctrl`；`require` 使用同名。4G 与协处理器主程序（`app/cat1/`）统一用 **T3x/t3x**。
