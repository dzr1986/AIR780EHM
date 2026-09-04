# mqtt — MQTT / 编码 / 串口 AT / 视频上传

> **唯一入口**：[doc/README.md](../README.md)；本页为 mqtt 二级索引（2026-09-04 分层）。
> **代码**：`user/net_mqtt.lua` 及 `mqtt_*`/`mqtt_dl_*`/`mqtt_ul_*` 子模块（树见 [LUA_MODULES.md](../overview/LUA_MODULES.md)）。
> **模块专题**（下载分发/上行职责）：[modules/README.md](../modules/README.md)「net_mqtt 子模块索引」。

## 协议与规范（真源，先读 📌）

| 文档 | 说明 |
|------|------|
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) 📌 | **MQTT 协议总纲**：200x↔100x 对照、上下行明细、Topic（57KB，含 2013） |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) | **下行命令手册**（平台 → 设备字段全集；GUI 自动测试载入） |
| [MQTT_862323084068314.md](MQTT_862323084068314.md) | 协议手册 — 设备 `…8314`（连接/主题/全命令；两机主题勿混） |
| [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) | T31x ↔ Cat.1 串口 AT 一览 |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | 串口 AT / STR / HEX 基础 |
| [HOST_MQTT_UART.md](HOST_MQTT_UART.md) | T31x `AT+MQTTCFG` 下发 4G MQTT |
| [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md) | MQTT 配置两种思路 |
| [REMOTE_ENCODE_CONFIG.md](REMOTE_ENCODE_CONFIG.md) | 远程视频/音频编码 2021/2020 · 1021/1020 |

## 业务 / 流程专题

| 文档 | 说明 |
|------|------|
| [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md) | 2013↔1013：国标 RecordInfo + 时间窗抽片（MQTT 不传文件） |
| [MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md) | 回放上传闭环：2013 → queued → percent → reply=0 |
| [MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md](MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md) | 串口 UPLOADVIDEO/PROGRESS/RESULT → 1013 |
| [MQTT_CLOUD_REMOTE_CTRL_FLOW.md](MQTT_CLOUD_REMOTE_CTRL_FLOW.md) | 远程控制：帧率/录像/人形（MQTT + AT + 时序） |
| [MQTT_2002_IPCPOWEROFF_T31_FLOW.md](MQTT_2002_IPCPOWEROFF_T31_FLOW.md) | 2002 进低功耗：先 UART 逐级停 IPC，再断 T31 供电 |
| [mqtt_tfcard_format_flow.md](mqtt_tfcard_format_flow.md) | TF 卡格式化 2009/1009（协议/时序/错误码/联调日志） |
| [T31X_MQTT_PARAM_HOT_APPLY.md](T31X_MQTT_PARAM_HOT_APPLY.md) | MQTT 设参 2020–2031 动态生效（不重启 `t31x_ipc`） |
| [T31X_SOFTPHOTO_REPEAT_SWITCH.md](T31X_SOFTPHOTO_REPEAT_SWITCH.md) | 软光敏：重复切换、开灯仍黑白；ISP/IRCUT 顺序 |
| [MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md](MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md) | 远程配置：麦克风 AI / 软光敏 / 音频编码 |
| [allday_pir_record_backend_dispatch.md](allday_pir_record_backend_dispatch.md) | 全天录 vs PIR 事件录：后台调度与 MQTT / GB28181 区分 |
| [MQTT_1013_BACKEND_GUIDE.md](MQTT_1013_BACKEND_GUIDE.md) | 1013 上传视频后台对接（业务平台/后台同事读） |

## 实测 / 联调 / 记录

| 文档 | 说明 |
|------|------|
| [MQTT_1003_STATUS_PATTERN.md](MQTT_1003_STATUS_PATTERN.md) | 1003 状态上报规律（IMEI 124 实测 1088 条，**76KB 大数据报表**） |
| [MQTT_ALL_CMD_FLOW_TEST.md](MQTT_ALL_CMD_FLOW_TEST.md) | 全指令流程与实机结果（`--run-all`、Cat.1 / T31x 对照） |
| [MQTT_CLIENT_E2E_TEST.md](MQTT_CLIENT_E2E_TEST.md) | MQTT 客户端 E2E 联调（MQTTX / mosquitto / 冒烟清单） |
| [MQTT_231_CLOSED_LOOP_20260902.md](MQTT_231_CLOSED_LOOP_20260902.md) | IMEI 231 2026-09-02 烧录 + `--run-safe` 闭环 |
| [T31X_IPC_CLOUD_EXCEPTION_REPORT.md](T31X_IPC_CLOUD_EXCEPTION_REPORT.md) | T31x IPC 联网异常上报分析（已上报 vs 缺口） |
| [T31X_ETH0_DHCP_SLOW_BOOT.md](T31X_ETH0_DHCP_SLOW_BOOT.md) | 重启后 eth0 有、IP 慢：RNDIS DHCP Discover 停发 + 30s 重试 |
| [CLIP_UPLOAD_CLOSED_LOOP_TEST.md](CLIP_UPLOAD_CLOSED_LOOP_TEST.md) | 人形录像上传闭环实测（T31 TF ↔ 腾讯云 uploadVideo） |
| [VIDEO_UPLOAD_SERVER.md](VIDEO_UPLOAD_SERVER.md) | 视频上传服务现网：7003 进程 / 落盘 / 运维（2026-08 快照） |

> MQTTX 单行 JSON 抄录（非 md，不入登记）：[MQTT_DOWNLINK_862323084068124.txt](MQTT_DOWNLINK_862323084068124.txt)（IMEI 124，含 2024–2027）· [MQTT_DOWNLINK_862323084068314.txt](MQTT_DOWNLINK_862323084068314.txt)（IMEI 314）。
