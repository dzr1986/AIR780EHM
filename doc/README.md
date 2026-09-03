# 780EHM_PJ 文档

## 术语（命名约定）

| 文档 | 说明 |
|------|------|
| [CAT1_API_NAMING.md](overview/CAT1_API_NAMING.md) | **Lua API 命名真源**（前缀口径：`pub*`/`dl*`/`snap*`/`sched*`/`build*`/`notify*`…；版本 001.000.151） |
| [T31X_NAMING.md](overview/T31X_NAMING.md) | 协处理器系列写法（`t31x` / `T31x` / `T31X`，与 API 驼峰无关） |
| [archive/T31_MIGRATION.md](archive/T31_MIGRATION.md) | 旧 T31 文档名迁移 |

**同步脚本**：`python tools/sync_doc_naming.py`（批量刷新 `doc/` 内 API 引用）。

## 文档目录（2026-09 主题归档）

| 目录 | 内容 | 分组入口 |
|------|------|------|
| [`overview/`](overview/) | 术语 / 总览 / 架构 / 配置 / 治理计划 | 见下文「总览与配置」 |
| [`hardware/`](hardware/) | 硬件 / GPIO / 指示灯 / 烧录口 | 见下文「硬件」 |
| [`power/`](power/) | 电源 / 低功耗 / USB / rest | 见下文「电源」 |
| [`pir/`](pir/) | PIR / 录像 / 提示音 | 见下文「PIR」 |
| [`mqtt/`](mqtt/) | MQTT / 编码 / 串口 AT / 视频上传 | 见下文「MQTT」 |
| [`t31x/`](t31x/) | T31x ↔ 4G 协作 / 监督 | 见下文「T31x」 |
| [`release/`](release/) | 烧录 / 发布 / 实机流程 | 见下文「发布」 |
| [`modules/`](modules/README.md) | 模块专题（模块树 / 事件 / 流程），独立索引 | 模块树真源 [LUA_MODULES.md](overview/LUA_MODULES.md) |
| [`_audit/`](_audit/) | ⚠ 历史 / 一次性记录 / 评审留档（不要求收录） | — |
| [`archive/`](archive/) | 旧路径迁移 stub（OTA 等） | 见顶部术语表 |

> 归档前 `doc/` 顶层为平铺单层；2026-09 起按内容主题物理分目录，
> 全仓 md/html 链接已随 `tools/debug/_doc_archive_by_topic.py` 重算，
> **本文件仍是唯一索引**，新文档请挂入对应主题目录并在此登记。

## 索引

### 总览与配置

| 文档 | 说明 |
|------|------|
| [OPTIMIZATION_PLAN.md](overview/OPTIMIZATION_PLAN.md) | **逻辑架构优化计划**：阶段 0–3 已落地；阶段 4 冻结 |
| [USER_LIB_OPTIMIZATION_NEXT.md](overview/USER_LIB_OPTIMIZATION_NEXT.md) | **068 之后计划**：074 拆分残留收口 |
| [USER_LIB_OPTIMIZATION_PLAN_20260830.md](overview/USER_LIB_OPTIMIZATION_PLAN_20260830.md) | **050–068 已做记录**：访问器、事件表、去包装 |
| [CODE_SIZE_OPTIMIZATION.md](overview/CODE_SIZE_OPTIMIZATION.md) | **体积/表驱动瘦身记录**（不减功能；量产约 342KB/512KB） |
| [CONFIG.md](overview/CONFIG.md) | **配置索引**：`GPIO_IN`/`GPIO_OUT`、**§Air780 GPIO 编号对照**、`config.mk` 宏对照 |
| [CODE_DOC_AUDIT.md](overview/CODE_DOC_AUDIT.md) | **代码↔文档核验流程**、`app.start` 真源顺序、修订记录 |
| [PROJECT_DOC.md](overview/PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CALL_GRAPH.md](overview/CALL_GRAPH.md) | 启动顺序、require、事件流 |
| [CODE_ANALYSIS.md](overview/CODE_ANALYSIS.md) | 架构与风险 |
| [LUA_MODULES.md](overview/LUA_MODULES.md) | **模块树真源**（73 文件、config 片段族、设计原则） |
| [CAT1_MODULE_FRAMEWORK.md](overview/CAT1_MODULE_FRAMEWORK.md) | **模块框架**：`module_loader`/`config_manager`、生命周期/日志/事件约定 |
| [modules/README.md](modules/README.md) | **模块专题**（AT / MQTT / PIR / 电量 / T31x 唤醒） |
| [TIME_SYNC.md](overview/TIME_SYNC.md) | SNTP + `AT+TIMESET` 时间同步 |
| [SYSTEM_ARCHITECTURE.md](overview/SYSTEM_ARCHITECTURE.md) | **系统级架构总览**：子系统 / 核心模块 / 数据流（入口建议先读） |
| [CODE_LAYERING_ARCHITECTURE.md](overview/CODE_LAYERING_ARCHITECTURE.md) | **分层架构真源**：`lib/`（L0–L2）与 `user/`（L3–L4）切割，已执行 |
| [FUNCTIONAL_ARCHITECTURE.md](overview/FUNCTIONAL_ARCHITECTURE.md) | 功能架构与分层优化：**特性域 → 层 → 模块**（与分层文档互补） |
| [ARCHITECTURE_REVIEW_20260903.md](overview/ARCHITECTURE_REVIEW_20260903.md) | **架构体检报告与四主题裁决**（2026-09-03 冻结观察期） |
| [USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](overview/USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md) | **user/lib 框架优化计划书**（拆分后治理版，08-31 冻结） |
| [FUNCTION_NAME_MAP.md](_audit/FUNCTION_NAME_MAP.md) | ⚠ **历史**：旧缩写实验记录（新符号请引用 `CAT1_API_NAMING`） |
| [CAT1_LOG_TAGS.md](overview/CAT1_LOG_TAGS.md) | Cat.1 日志标签还原说明（`/mnt/share/user/` 镜像） |

### 硬件 / GPIO / 指示灯

| 文档 | 说明 |
|------|------|
| [T31X_CAT1_GPIO.md](hardware/T31X_CAT1_GPIO.md) | 原理图级引脚；**§1.1 固件 GPIO 全表** |
| [KEY_GPIO.md](hardware/KEY_GPIO.md) | 按键 / `config.lua` 的 `KEY_CONFIG` |
| [T31X_BURN_MODE.md](hardware/T31X_BURN_MODE.md) | **GPIO28 长按 → T31x 烧录**（电量/关停条件） |
| [LED_INDICATORS.md](hardware/LED_INDICATORS.md) | **指示灯专篇**：充电板灯 + 模组红蓝灯 |
| [PIR_HARDWARE.md](hardware/PIR_HARDWARE.md) | PIR 硬件与流程 |

### 电源 / 低功耗 / USB

| 文档 | 说明 |
|------|------|
| [CHARGE_BATTERY.md](power/CHARGE_BATTERY.md) | 充电、ADC（`vbat`）、MQTT 1003 |
| [LOW_BATTERY_AND_LOW_POWER.md](power/LOW_BATTERY_AND_LOW_POWER.md) | **低电量/USB/rest/T31x**（场景流程图 + 附录） |
| [WORK_MODE_PERSON_DETECT_PIR.md](power/WORK_MODE_PERSON_DETECT_PIR.md) | **现行两种模式**：开机人形常电；仅 2002 才断 T31 用 PIR（已去掉低电自动进 PIR） |
| [PERSON_CNT_UART_MQTT_FLOW.md](power/PERSON_CNT_UART_MQTT_FLOW.md) | **有人看哪里、PERSONCNT 30s、skipped 不是过密、检测软件读数** |
| [WORK_MODE_BATTERY_20PCT.md](_audit/WORK_MODE_BATTERY_20PCT.md) | **历史**：电量 20% 切动态侦测（已被上一篇取代） |
| [LOW_POWER_ENTER_STRATEGY.md](power/LOW_POWER_ENTER_STRATEGY.md) | **电量 rest vs HOSTIDLE 30s 轮询**：是否矛盾、策略切换 |
| [BATTERY_REST_SWITCH_CONDITIONS.md](power/BATTERY_REST_SWITCH_CONDITIONS.md) | rest 切换：连续确认、最短常电、最短 rest |
| [T31X_LOW_POWER.md](power/T31X_LOW_POWER.md) | **低功耗可配置**：rest 主流程、**conack 与 1001/1002/1003** |
| [T31X_USB_HOSTIDLE.md](power/T31X_USB_HOSTIDLE.md) | **USB 插入 ↔ T31x/4G 低功耗互斥** |
| [T31X_BATTERY_USB_T31X_OSCILLATION.md](power/T31X_BATTERY_USB_T31X_OSCILLATION.md) | USB+低电量与 T31x 启停循环（纯分析） |
| [POWER_USB_BATTERY_T31X_LOGIC.md](power/POWER_USB_BATTERY_T31X_LOGIC.md) | 决策图、模块职责、已修复对照 |
| [CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](power/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md) | **唤醒通道**：`LOW_POWER_WAKEUP_CFG.mode` mqtt/tcp |
| [CAT1_SLIMMING_FLOW.md](power/CAT1_SLIMMING_FLOW.md) | Cat.1 精简流程（门球量产步骤） |
| [CAT1_USER_LIB_SLIM.md](power/CAT1_USER_LIB_SLIM.md) | Cat.1 精简速查（`MODULE_FLAGS` / 懒加载） |
| [CAT1_LOGIC_SLIM.md](power/CAT1_LOGIC_SLIM.md) | **逻辑精简规划**（`cat1_slim_logic` 分支，不减功能） |
| [mqtt_battery_shutdown_flow.md](power/mqtt_battery_shutdown_flow.md) | **MQTT 低电量关机**：≤3.4V 关机前上 1004 + 1003 |

### PIR / 录像 / 提示音

| 文档 | 说明 |
|------|------|
| [PIR_PROTOCOL.md](pir/PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [MQTT_2011_T31X_STOP_EXPLAINED.md](pir/MQTT_2011_T31X_STOP_EXPLAINED.md) | **2011 停录怎么读**：两层录像、复位掉电、1004/1011、`.part` 封口 |
| [PIR_TRIGGER_INTERVAL.md](pir/PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [PIR_COOLDOWN_AND_COUNT.md](pir/PIR_COOLDOWN_AND_COUNT.md) | 冷却 vs 计数 |
| [T31X_RECORD_MQTT_FLOW.md](pir/T31X_RECORD_MQTT_FLOW.md) | **AT+RECORD + MQTT 1010/1011** |
| [BOOT_SHUTDOWN_SOUND.md](pir/BOOT_SHUTDOWN_SOUND.md) | 开机/关机提示音 |
| [mqtt_2010_2012_2011_pir_flow.md](pir/mqtt_2010_2012_2011_pir_flow.md) | **2010 策略 / 2012 平台开录 / 2011 停录 与 PIR 协作** + 联调实操 |
| [mqtt_2011_1011_flow.md](pir/mqtt_2011_1011_flow.md) | **2011 停录 → 1011 上行**（4G ↔ T31x 协作） |
| [mqtt_2012_1012_flow.md](pir/mqtt_2012_1012_flow.md) | **2012 开录 → 1012 上行**（4G ↔ T31x 协作） |

### MQTT / 编码 / 串口 AT

| 文档 | 说明 |
|------|------|
| [MQTT_PROTOCOL.md](mqtt/MQTT_PROTOCOL.md) | MQTT 上下行（含 2006/2007、2021/2020、2024–2027、2012、**2013**） |
| [MQTT_2013_1013_UPLOAD_VIDEO.md](mqtt/MQTT_2013_1013_UPLOAD_VIDEO.md) | **2013↔1013**：国标 RecordInfo 列表 + MQTT 时间窗抽片（MQTT 不传文件） |
| [MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](mqtt/MQTT_CLIP_UPLOAD_CLOSED_LOOP.md) | **回放上传闭环**：2013 → queued → 进度 percent → reply=0；IPC / Cat.1 / Python+Java GUI |
| [MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md](mqtt/MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md) | **回放/人形上传**：串口 `UPLOADVIDEO`/`UPLOADPROGRESS`/`UPLOADRESULT` → 1013 |
| [MQTT_CLOUD_REMOTE_CTRL_FLOW.md](mqtt/MQTT_CLOUD_REMOTE_CTRL_FLOW.md) | **远程控制**：帧率/录像/人形（MQTT + AT + 时序） |
| [T31X_IPC_CLOUD_EXCEPTION_REPORT.md](mqtt/T31X_IPC_CLOUD_EXCEPTION_REPORT.md) | **T31x IPC 联网异常上报分析**（已上报 vs 缺口） |
| [MQTT_862323084068314.md](mqtt/MQTT_862323084068314.md) | **本机 IMEI 862323084068314** MQTT 联调手册 |
| [MQTT_DOWNLINK_862323084068124.txt](mqtt/MQTT_DOWNLINK_862323084068124.txt) | **IMEI 124** MQTTX 单行 JSON 抄录（含 2024–2027） |
| [mqtt_tfcard_format_flow.md](mqtt/mqtt_tfcard_format_flow.md) | **统一入口：TF 卡格式化 2009/1009**（协议、时序、错误码、联调日志） |
| [MQTT_DOWNLINK.md](mqtt/MQTT_DOWNLINK.md) | 下行命令手册 |
| [MQTT_CLIENT_E2E_TEST.md](mqtt/MQTT_CLIENT_E2E_TEST.md) | **MQTT 客户端 E2E 联调**（MQTTX / mosquitto / 冒烟清单） |
| [MQTT_ALL_CMD_FLOW_TEST.md](mqtt/MQTT_ALL_CMD_FLOW_TEST.md) | **全指令流程与实机结果**（`--run-all`、Cat.1 / T31x 对照） |
| [MQTT_231_CLOSED_LOOP_20260902.md](mqtt/MQTT_231_CLOSED_LOOP_20260902.md) | **IMEI 231** 2026-09-02 烧录 + `--run-safe` / extra / 开录·rest·关机·格式化·重启（`001.000.149`） |
| [../ota_server/docs/OTA_SERVER.md](../ota_server/docs/OTA_SERVER.md) | **自建 OTA**（固件对接 + 部署清单，不改 lua） |
| [OTA_CONSOLE_UPGRADE.md](archive/OTA_CONSOLE_UPGRADE.md) | **后台怎么点升级**（上传包 → 下发 OTA） |
| [../ota_server/docs/OTA_LUAT_IOT_ADMIN_FLOW.md](../ota_server/docs/OTA_LUAT_IOT_ADMIN_FLOW.md) | **合宙 IoT 项目列表 ↔ 管理台操作流程** |
| [../ota_server/docs/OTA_PROTOCOL.md](../ota_server/docs/OTA_PROTOCOL.md) | **OTA 协议与升级流程分析**（HTTP + MQTT） |
| [../ota_server/docs/OTA_FLOW.md](../ota_server/docs/OTA_FLOW.md) | **完整流程 + 代码完整性清单** |
| [../ota_server/README.md](../ota_server/README.md) | OTA 服务端部署手册 |
| [../video_upload_server/README.md](../video_upload_server/README.md) | **报警视频 uploadVideo**（7003，兼容南京后台） |
| [REMOTE_ENCODE_CONFIG.md](mqtt/REMOTE_ENCODE_CONFIG.md) | 远程视频/音频编码 2021/2020 / 1021/1020 |
| [T31X_MQTT_PARAM_HOT_APPLY.md](mqtt/T31X_MQTT_PARAM_HOT_APPLY.md) | **MQTT 设参动态生效**：2020–2031（不含 2013）不重启 `t31x_ipc` 进程 |
| [T31X_SOFTPHOTO_REPEAT_SWITCH.md](mqtt/T31X_SOFTPHOTO_REPEAT_SWITCH.md) | **软光敏**：重复切换、开灯仍黑白、日→夜品红闪；ISP/IRCUT 顺序 |
| [T31X_ETH0_DHCP_SLOW_BOOT.md](mqtt/T31X_ETH0_DHCP_SLOW_BOOT.md) | **重启后 eth0 有、IP 慢**：RNDIS DHCP Discover 停发 + 30s 重试 |
| [CAT1_USB_RNDIS_CFG_CRASH_FLASH.md](release/CAT1_USB_RNDIS_CFG_CRASH_FLASH.md) | **开机无网**：COM10 查 `usb_rndis cfg` 崩溃 → 修代码 → `flash-script` 烧录验收 |
| [HOST_MQTT_UART.md](mqtt/HOST_MQTT_UART.md) | T31x `AT+MQTTCFG` 下发 4G MQTT |
| [MQTT_HOST_CONFIG_MODES.md](mqtt/MQTT_HOST_CONFIG_MODES.md) | MQTT 配置两种思路 |
| [UART_PROTOCOL.md](mqtt/UART_PROTOCOL.md) | 串口 AT / STR / HEX |
| [MQTT_1003_STATUS_PATTERN.md](mqtt/MQTT_1003_STATUS_PATTERN.md) | **1003 状态上报规律**（IMEI 124 实测 1088 条 / interval=30s） |
| [MQTT_1013_BACKEND_GUIDE.md](mqtt/MQTT_1013_BACKEND_GUIDE.md) | **1013 上传视频后台对接**（业务平台/后台同事读） |
| [MQTT_2002_IPCPOWEROFF_T31_FLOW.md](mqtt/MQTT_2002_IPCPOWEROFF_T31_FLOW.md) | **2002 进低功耗**：先 UART 逐级停 IPC，再断 T31 供电 |
| [MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md](mqtt/MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md) | 远程配置：**麦克风 AI / 软光敏 / 音频编码**（Cat.1 → UART → IPC） |
| [CLIP_UPLOAD_CLOSED_LOOP_TEST.md](mqtt/CLIP_UPLOAD_CLOSED_LOOP_TEST.md) | **人形录像上传闭环实测**（T31 TF ↔ 腾讯云 uploadVideo） |
| [allday_pir_record_backend_dispatch.md](mqtt/allday_pir_record_backend_dispatch.md) | **全天录 vs PIR 事件录**：后台调度与 MQTT / GB28181 区分 |
| [VIDEO_UPLOAD_SERVER.md](mqtt/VIDEO_UPLOAD_SERVER.md) | **视频上传服务现网**：7003 进程 / 分目录落盘 / 运维（2026-08 快照） |
| [UART_AT_COMMANDS.md](mqtt/UART_AT_COMMANDS.md) | T31x↔Cat.1 AT 一览 |

### T31x ↔ 4G 协作

| 文档 | 说明 |
|------|------|
| [T31X_4G_FRAMEWORK.md](t31x/T31X_4G_FRAMEWORK.md) | **协作框架简图（建议先读）** |
| [T31X_4G_AT_INTERACTION.md](t31x/T31X_4G_AT_INTERACTION.md) | AT 全量交互 |
| [T31X_CAT1_AT_COMMAND_SPEC.md](t31x/T31X_CAT1_AT_COMMAND_SPEC.md) | T31x→4G AT 规范（MQTT + TCP） |
| [T31X_IPC_4G_INTERACTION.md](t31x/T31X_IPC_4G_INTERACTION.md) | 分层、PIR/录像/rest 流程 |
| [T31X_IPC_CAT1_COMM_COMPLETENESS.md](t31x/T31X_IPC_CAT1_COMM_COMPLETENESS.md) | 双向 AT 对照与缺口 |
| [T31X_HOSTEVT_PROTOCOL.md](t31x/T31X_HOSTEVT_PROTOCOL.md) | GPIO29 低脉冲与 HOSTEVT |
| [T31X_HOSTEVT_SLEEP.md](t31x/T31X_HOSTEVT_SLEEP.md) | HOSTEVT 四条 AT 汇总 |
| [T31X_IPC_ALERT_CONTRACT.md](t31x/T31X_IPC_ALERT_CONTRACT.md) | **IPC ↔ Cat.1 `alertCode` 共享契约**（`ipc_alert_contract.h` 真源） |
| [T31X_IPC_SUPERVISION_MODULE.md](t31x/T31X_IPC_SUPERVISION_MODULE.md) | **IPC ↔ Cat.1 监督模块架构**（两侧独立 + 契约对齐） |
| [T31X_IPC_CAT1_SUPERVISION.md](t31x/T31X_IPC_CAT1_SUPERVISION.md) | **Cat.1 ↔ IPC 联合异常监督机制**（读者：固件/联调/平台） |
| [T31X_IPC_EXCEPTION_MQTT_UPLINK.md](t31x/T31X_IPC_EXCEPTION_MQTT_UPLINK.md) | **IPC 异常 → MQTT 后台上行协议**与恢复态 |
| [T31X_IPC_ALERT_CODE_INDEX.md](t31x/T31X_IPC_ALERT_CODE_INDEX.md) | IPC_ALERT / `alertCode` **源码行号速查** |

### 发布与其它

| 文档 | 说明 |
|------|------|
| [CAT1_FLASH_FLOW.md](release/CAT1_FLASH_FLOW.md) | **Cat.1 烧录流程**：认 COM、免 BOOT、`flash-script`、烧完验收 |
| [CAT1_FLASH_TOOL.md](release/CAT1_FLASH_TOOL.md) | **Cat.1 USB 烧录工具**：图形界面 / 命令行，对齐 Luatools |
| [CAT1_USB_RNDIS_CFG_CRASH_FLASH.md](release/CAT1_USB_RNDIS_CFG_CRASH_FLASH.md) | **RNDIS cfg 崩溃实机流程**：COM10 排查 → 修复 → `flash-script`（勿用 mqtt_tools_gui 烧录） |
| [RELEASE_v1.2.md](release/RELEASE_v1.2.md) | v1.2 发布/备份说明 |
| [CAT1_TOOLCHAIN_TEST_REPORT.md](_audit/CAT1_TOOLCHAIN_TEST_REPORT.md) | **工具链与 MQTT 自动化测试报告**（2026-08-17，IMEI 124） |
| [MQTT_AUTOTEST_LOG_862323084068124_20260818.md](_audit/MQTT_AUTOTEST_LOG_862323084068124_20260818.md) | 自动测试 **GUI「日志」页抄录**（IMEI 124，2026-08-18） |
| [T31X_NAMING.md](overview/T31X_NAMING.md) | T31x 命名约定 |
| [archive/T31_MIGRATION.md](archive/T31_MIGRATION.md) | 旧 T31 文档重定向表 |

---

**代码真源**：[`../user/config.lua`](../user/config.lua)（26 行编排 → `features`/`cellular`/`gpio_cfg`/… 10 个 config 片段，见 [CONFIG.md](overview/CONFIG.md)）、[`../user/main.lua`](../user/main.lua)（`VERSION`/`PRODUCT_KEY`）。

**模块命名**（与 `user/*.lua` 一致）：`t31x_ctrl`、`t31x_policy`、`pir_ctrl`、`host_uart`、`vbat`；`require` 使用 snake_case。

**外部参考**（IPC 仓，本仓库无副本）：`docs/usb_debug_en_and_t31x_sleep_timing.md`、`docs/gpio_led_config.md`。
