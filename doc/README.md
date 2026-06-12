# 780EHM_PJ 文档

## 术语（命名约定）

**完整说明**：[T3X_NAMING.md](T3X_NAMING.md)（`t3x`/`T3x`/`T3X` 协处理器系列命名）。旧 **T31** 文档名见 [archive/T31_MIGRATION.md](archive/T31_MIGRATION.md)（根目录桩已删除）。

## 索引

### 总览与配置

| 文档 | 说明 |
|------|------|
| [CONFIG.md](CONFIG.md) | **配置索引**：`GPIO_IN`/`GPIO_OUT`、**§Air780 GPIO 编号对照**、`config.mk` 宏对照 |
| [CODE_DOC_AUDIT.md](CODE_DOC_AUDIT.md) | **代码↔文档核验流程**、`app.start` 真源顺序、修订记录 |
| [PROJECT_DOC.md](PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动顺序、require、事件流 |
| [CODE_ANALYSIS.md](CODE_ANALYSIS.md) | 架构与风险 |
| [TIME_SYNC.md](TIME_SYNC.md) | SNTP + `AT+TIMESET` 时间同步 |

### 硬件 / GPIO / 指示灯

| 文档 | 说明 |
|------|------|
| [T3X_CAT1_GPIO.md](T3X_CAT1_GPIO.md) | 原理图级引脚；**§1.1 固件 GPIO 全表** |
| [KEY_GPIO.md](KEY_GPIO.md) | 按键 / `key_config.lua` |
| [T3X_BURN_MODE.md](T3X_BURN_MODE.md) | **GPIO28 长按 → T3x 烧录**（电量/关停条件） |
| [LED_INDICATORS.md](LED_INDICATORS.md) | **指示灯专篇**：充电板灯 + 模组红蓝灯 |
| [PIR_HARDWARE.md](PIR_HARDWARE.md) | PIR 硬件与流程 |

### 电源 / 低功耗 / USB

| 文档 | 说明 |
|------|------|
| [CHARGE_BATTERY.md](CHARGE_BATTERY.md) | 充电、ADC（`vbat`）、MQTT 1003 |
| [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) | **低电量/USB/rest/T3x**（场景流程图 + 附录） |
| [T3X_LOW_POWER.md](T3X_LOW_POWER.md) | **低功耗可配置**：rest 主流程、**conack 与 1001/1002/1003** |
| [T3X_USB_HOSTIDLE.md](T3X_USB_HOSTIDLE.md) | **USB 插入 ↔ T3x/4G 低功耗互斥** |
| [T3X_BATTERY_USB_T3X_OSCILLATION.md](T3X_BATTERY_USB_T3X_OSCILLATION.md) | USB+低电量与 T3x 启停循环（纯分析） |
| [POWER_USB_BATTERY_T3X_LOGIC.md](POWER_USB_BATTERY_T3X_LOGIC.md) | 决策图、模块职责、已修复对照 |
| [CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](CAT1_LOWPWR_MQTT_TCP_STRATEGY.md) | **唤醒通道**：`LOW_POWER_WAKEUP_CFG.mode` mqtt/tcp |
| [CAT1_SLIMMING_FLOW.md](CAT1_SLIMMING_FLOW.md) | Cat.1 精简流程（门球量产步骤） |
| [CAT1_USER_LIB_SLIM.md](CAT1_USER_LIB_SLIM.md) | Cat.1 精简速查（`MODULE_FLAGS` / 懒加载） |
| [CAT1_LOGIC_SLIM.md](CAT1_LOGIC_SLIM.md) | **逻辑精简规划**（`cat1_slim_logic` 分支，不减功能） |

### PIR / 录像 / 提示音

| 文档 | 说明 |
|------|------|
| [PIR_PROTOCOL.md](PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [PIR_TRIGGER_INTERVAL.md](PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [PIR_COOLDOWN_AND_COUNT.md](PIR_COOLDOWN_AND_COUNT.md) | 冷却 vs 计数 |
| [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md) | **AT+RECORD + MQTT 1010/1011** |
| [BOOT_SHUTDOWN_SOUND.md](BOOT_SHUTDOWN_SOUND.md) | 开机/关机提示音 |

### MQTT / 编码 / 串口 AT

| 文档 | 说明 |
|------|------|
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) | MQTT 上下行（含 2006/2007、2021/2020） |
| [MQTT_862323084068314.md](MQTT_862323084068314.md) | **本机 IMEI 862323084068314** MQTT 联调手册 |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) | 下行命令手册 |
| [OTA_SERVER.md](OTA_SERVER.md) | **自建 OTA**（固件对接 + 部署清单，不改 lua） |
| [OTA_PROTOCOL.md](OTA_PROTOCOL.md) | **OTA 协议与升级流程分析**（HTTP + MQTT） |
| [OTA_FLOW.md](OTA_FLOW.md) | **完整流程 + 代码完整性清单** |
| [../ota_server/README.md](../ota_server/README.md) | OTA 服务端部署手册 |
| [REMOTE_ENCODE_CONFIG.md](REMOTE_ENCODE_CONFIG.md) | 远程视频/音频编码 2021/2020 / 1021/1020 |
| [HOST_MQTT_UART.md](HOST_MQTT_UART.md) | T3x `AT+MQTTCFG` 下发 4G MQTT |
| [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md) | MQTT 配置两种思路 |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) | T3x↔Cat.1 AT 一览 |

### T3x ↔ 4G 协作

| 文档 | 说明 |
|------|------|
| [T3X_4G_FRAMEWORK.md](T3X_4G_FRAMEWORK.md) | **协作框架简图（建议先读）** |
| [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) | AT 全量交互 |
| [T3X_CAT1_AT_COMMAND_SPEC.md](T3X_CAT1_AT_COMMAND_SPEC.md) | T3x→4G AT 规范（MQTT + TCP） |
| [T3X_IPC_4G_INTERACTION.md](T3X_IPC_4G_INTERACTION.md) | 分层、PIR/录像/rest 流程 |
| [T3X_IPC_CAT1_COMM_COMPLETENESS.md](T3X_IPC_CAT1_COMM_COMPLETENESS.md) | 双向 AT 对照与缺口 |
| [T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md) | GPIO29 低脉冲与 HOSTEVT |
| [T3X_HOSTEVT_SLEEP.md](T3X_HOSTEVT_SLEEP.md) | HOSTEVT 四条 AT 汇总 |

### 发布与其它

| 文档 | 说明 |
|------|------|
| [RELEASE_v1.2.md](RELEASE_v1.2.md) | v1.2 发布/备份说明 |
| [T3X_NAMING.md](T3X_NAMING.md) | T3x 命名约定 |
| [archive/T31_MIGRATION.md](archive/T31_MIGRATION.md) | 旧 T31 文档重定向表 |

---

**代码真源**：[`../user/config.lua`](../user/config.lua)、[`../user/app_config.lua`](../user/app_config.lua)、[`../user/key_config.lua`](../user/key_config.lua)、[`../user/main.lua`](../user/main.lua)（`PRODUCT_KEY`）。

**模块命名**（与 `user/*.lua` 一致）：`t3x_ctrl`、`t3x_policy`、`pir_ctrl`、`host_uart`、`vbat`；`require` 使用 snake_case。

**外部参考**（IPC 仓，本仓库无副本）：`docs/usb_debug_en_and_t3x_sleep_timing.md`、`docs/gpio_led_config.md`。
