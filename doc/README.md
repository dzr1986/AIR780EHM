# 780EHM_PJ 文档

> **本文件是唯一入口**；主题大组各自带二级索引（2026-09-04 分层）。
> 登记护栏：`python doc/_tools/doc_registry_check.py`（主题 md 必须被本页或同主题 README 登记）。

## 建议阅读路径

三种视角进入同一套真源，按你手头的问题选：

| 视角 | 入口 | 适合 |
|------|------|------|
| **架构**（系统长什么样） | 1. [overview/SYSTEM_ARCHITECTURE.md](overview/SYSTEM_ARCHITECTURE.md) → 2. [overview/CODE_LAYERING_ARCHITECTURE.md](overview/CODE_LAYERING_ARCHITECTURE.md) → 3. [overview/CONFIG.md](overview/CONFIG.md) → 4. [mqtt/MQTT_PROTOCOL.md](mqtt/MQTT_PROTOCOL.md) → 5. [t31x/T31X_4G_FRAMEWORK.md](t31x/T31X_4G_FRAMEWORK.md) | 新读者、评审 |
| **技术工作流**（设备运行时先后发生什么） | **[overview/TECH_WORKFLOWS.md](overview/TECH_WORKFLOWS.md)**：W1 上电 → W2 入网/MQTT → W3 T31x 供电/串口 → W4 下行闭环 → W5 PIR/录像 → W6 上传 → W7 电源/低功耗/关机 → W8 OTA → W9 授时/提示音 → W10 监督排障 → W0 工程流；每步给 `模块.函数` / 协议 / 门禁 / 观测点 / 真源 | 排障、联调、理清「为什么这一步没发生」 |
| **开发任务**（我要改什么） | **[开发系统手册 manual/](manual/README.md)**（7 卷按任务重组，内嵌速查表） | 改 `user/`/`lib/`、加协议、烧录发版 |

> 三层都不是真源：数值/字段/行为冲突一律以代码 > 主题真源为准。

## 开发系统手册（manual/，面向维护者）

> 定位：**按开发任务**对主题真源做二次组织，内嵌自包含速查表。所有细节/数值以「真源」为准。
> 不移动、不删除任何主题文档；手册只是导航 + 速查汇编。

| 卷 | 内容 | 对象 |
|----|------|------|
| [MANUAL_V1_SYSTEM.md](manual/MANUAL_V1_SYSTEM.md) | 系统与固件：双芯片架构、代码分层、启动顺序、配置索引、版本与产物 | 任何进项目的人 |
| [MANUAL_V2_LUA_API.md](manual/MANUAL_V2_LUA_API.md) | Lua API 与模块开发：命名真源、模块树、事件总线、config 片段、日志 | 改 `user/`/`lib/` 的人 |
| [MANUAL_V3_MQTT.md](manual/MANUAL_V3_MQTT.md) | MQTT 云协议：Topic、200x↔100x 对照、上行/下行速查、常见流程 | 联调/平台/上行下行排障 |
| [MANUAL_V4_T31X.md](manual/MANUAL_V4_T31X.md) | T31x 协同与 IPC：UART/AT、HOSTEVT、唤醒链、IPC 监督与 alertCode | T31x 协作/异常排查 |
| [MANUAL_V5_POWER.md](manual/MANUAL_V5_POWER.md) | 电源电池低功耗：档位策略、rest/HOSTIDLE、T31x 供电、USB、关机 | 低功耗/耗电排查 |
| [MANUAL_V6_PIR.md](manual/MANUAL_V6_PIR.md) | PIR 与录像会话：触发/冷却、2010–2012↔1010–1012、提示音 | PIR 联调/缺录排查 |
| [MANUAL_V7_TOOLCHAIN.md](manual/MANUAL_V7_TOOLCHAIN.md) | 产测烧录发布：工具链、烧录、打包量产、文档护栏 | 产线/发布/文档维护 |

## 术语与命名

| 文档 | 说明 |
|------|------|
| [overview/CAT1_API_NAMING.md](overview/CAT1_API_NAMING.md) | **Lua API 命名真源**（前缀 `pub*`/`dl*`/`snap*`/…；对齐代码 001.000.155，151 批 rename 后无 API 变更） |
| [overview/T31X_NAMING.md](overview/T31X_NAMING.md) | 协处理器系列写法（`t31x` / `T31x` / `T31X`） |
| [overview/LUA_MODULES.md](overview/LUA_MODULES.md) | **模块树真源**（user 58 + lib 15 = 73） |

**同步脚本**：`python tools/sync_doc_naming.py`（批量刷新 `doc/` 内 API 引用）。

## 主题目录（2026-09 主题归档）

| 目录 | 内容 | 索引 |
|------|------|------|
| [`overview/`](overview/README.md) | 术语 / 总览 / 架构 / 配置 / 治理计划 | [overview/README.md](overview/README.md)（含状态徽标） |
| [`hardware/`](hardware/) | 硬件 / GPIO / 指示灯 / 烧录口 | 本页下表 |
| [`power/`](power/README.md) | 电源 / 低功耗 / USB / 精简 | [power/README.md](power/README.md) |
| [`pir/`](pir/) | PIR / 录像 / 提示音 | 本页下表 |
| [`mqtt/`](mqtt/README.md) | MQTT / 编码 / 串口 AT / 视频上传 | [mqtt/README.md](mqtt/README.md) |
| [`t31x/`](t31x/README.md) | T31x ↔ 4G 协作 / 监督 | [t31x/README.md](t31x/README.md) |
| [`modules/`](modules/README.md) | 模块专题（host_uart / net_mqtt / user / lib） | [modules/README.md](modules/README.md) |
| [`manual/`](manual/README.md) | **开发系统手册**（面向维护者的 7 卷任务化汇编） | [manual/README.md](manual/README.md) |
| [`release/`](release/) | 烧录 / 发布 / 实机流程 | 本页下表 |
| [`_audit/`](_audit/) | ⚠ 历史 / 一次性记录 / 评审留档（不要求收录） | — |
| [`archive/`](archive/) | 旧路径迁移 stub / 历史快照 | 见下「旧文档迁移」 |

> 归档前 `doc/` 顶层为平铺单层；2026-09 起按内容主题物理分目录，全仓 md/html 链接
> 已随 `tools/debug/_doc_archive_by_topic.py` 重算。新文档挂入对应主题目录并在其二级索引登记。

## 硬件 / GPIO / 指示灯

> 工作流位置：引脚在 W1（`gpio_util` 装配）、W5（PIR）、W7（USB/按键/烧录）中被消费，见 [TECH_WORKFLOWS](overview/TECH_WORKFLOWS.md)。

| 文档 | 说明 |
|------|------|
| [hardware/T31X_CAT1_GPIO.md](hardware/T31X_CAT1_GPIO.md) | 原理图级引脚；**§1.1 固件 GPIO 全表** |
| [hardware/KEY_GPIO.md](hardware/KEY_GPIO.md) | 按键 / `config.lua` 的 `KEY_CONFIG` |
| [hardware/T31X_BURN_MODE.md](hardware/T31X_BURN_MODE.md) | GPIO28 长按 → T31x 烧录（电量/关停条件） |
| [hardware/LED_INDICATORS.md](hardware/LED_INDICATORS.md) | 指示灯专篇：充电板灯 + 模组红蓝灯 |
| [hardware/PIR_HARDWARE.md](hardware/PIR_HARDWARE.md) | PIR 硬件与流程 |

## PIR / 录像 / 提示音

> 工作流位置：[TECH_WORKFLOWS W5](overview/TECH_WORKFLOWS.md#w5-pir-触发--录像拍照--上行)（GPIO30 → 冷却 → 唤醒 T31x → AT+RECORD → 1010/1011/1012）· W9（提示音）。

| 文档 | 说明 |
|------|------|
| [pir/PIR_PROTOCOL.md](pir/PIR_PROTOCOL.md) | PIR / 2010 / 2011 |
| [pir/MQTT_2011_T31X_STOP_EXPLAINED.md](pir/MQTT_2011_T31X_STOP_EXPLAINED.md) | 2011 停录怎么读：两层录像、复位掉电、1004/1011、`.part` 封口 |
| [pir/PIR_TRIGGER_INTERVAL.md](pir/PIR_TRIGGER_INTERVAL.md) | PIR 冷却间隔 |
| [pir/PIR_COOLDOWN_AND_COUNT.md](pir/PIR_COOLDOWN_AND_COUNT.md) | 冷却 vs 计数 |
| [pir/T31X_RECORD_MQTT_FLOW.md](pir/T31X_RECORD_MQTT_FLOW.md) | AT+RECORD + MQTT 1010/1011 |
| [pir/BOOT_SHUTDOWN_SOUND.md](pir/BOOT_SHUTDOWN_SOUND.md) | 开机/关机提示音 |
| [pir/mqtt_2010_2012_2011_pir_flow.md](pir/mqtt_2010_2012_2011_pir_flow.md) | 2010/2012/2011 与 PIR 协作 + 联调实操 |
| [pir/mqtt_2011_1011_flow.md](pir/mqtt_2011_1011_flow.md) | 2011 停录 → 1011 上行（4G ↔ T31x 协作） |
| [pir/mqtt_2012_1012_flow.md](pir/mqtt_2012_1012_flow.md) | 2012 开录 → 1012 上行（4G ↔ T31x 协作） |

## 发布与实机流程

| 文档 | 说明 |
|------|------|
| [release/CAT1_FLASH_FLOW.md](release/CAT1_FLASH_FLOW.md) | Cat.1 烧录流程：认 COM、免 BOOT、`flash-script`、烧完验收 |
| [release/CAT1_FLASH_TOOL.md](release/CAT1_FLASH_TOOL.md) | Cat.1 USB 烧录工具：图形界面 / 命令行，对齐 Luatools |
| [release/CAT1_USB_RNDIS_CFG_CRASH_FLASH.md](release/CAT1_USB_RNDIS_CFG_CRASH_FLASH.md) | RNDIS cfg 崩溃实机流程：COM10 排查 → 修复 → `flash-script` |
| [release/RELEASE_v1.2.md](release/RELEASE_v1.2.md) | v1.2 发布/备份说明 |

> 工具链与自动化测试报告（_audit 留档）：[CAT1_TOOLCHAIN_TEST_REPORT.md](_audit/CAT1_TOOLCHAIN_TEST_REPORT.md)（2026-08-17，IMEI 124）· [MQTT_AUTOTEST_LOG_862323084068124_20260818.md](_audit/MQTT_AUTOTEST_LOG_862323084068124_20260818.md)（GUI 日志抄录，IMEI 124）。

## 外部工程相关文档

> 跨仓库参考（不入 doc/ 主题登记，链接相对本页出发）：

| 文档 | 说明 |
|------|------|
| [../ota_server/docs/OTA_SERVER.md](../ota_server/docs/OTA_SERVER.md) | 自建 OTA（固件对接 + 部署清单，不改 lua） |
| [../ota_server/docs/OTA_LUAT_IOT_ADMIN_FLOW.md](../ota_server/docs/OTA_LUAT_IOT_ADMIN_FLOW.md) | 合宙 IoT 项目列表 ↔ 管理台操作流程 |
| [../ota_server/docs/OTA_PROTOCOL.md](../ota_server/docs/OTA_PROTOCOL.md) | OTA 协议与升级流程分析（HTTP + MQTT） |
| [../ota_server/docs/OTA_FLOW.md](../ota_server/docs/OTA_FLOW.md) | 完整流程 + 代码完整性清单 |
| [../ota_server/README.md](../ota_server/README.md) | OTA 服务端部署手册 |
| [../video_upload_server/README.md](../video_upload_server/README.md) | 报警视频 uploadVideo（7003，兼容南京后台） |

## 旧文档迁移

| 文档 | 说明 |
|------|------|
| [archive/OTA_CONSOLE_UPGRADE.md](archive/OTA_CONSOLE_UPGRADE.md) | 后台怎么点升级（上传包 → 下发 OTA） |
| [archive/T31_MIGRATION.md](archive/T31_MIGRATION.md) | T31 → T31X 旧文档重定向表（指向现行文件） |

---

**代码真源**：[`../user/config.lua`](../user/config.lua)（26 行编排 → `features`/`cellular`/`gpio_cfg`/… 10 个 config 片段，见 [overview/CONFIG.md](overview/CONFIG.md)）、[`../user/main.lua`](../user/main.lua)（`VERSION`/`PRODUCT_KEY`）。

**模块命名**（与 `user/*.lua` 一致）：`t31x_ctrl`、`t31x_policy`、`pir_ctrl`、`host_uart`、`vbat`；`require` 使用 snake_case。

**外部参考**（IPC 仓，本仓库无副本）：`docs/usb_debug_en_and_t31x_sleep_timing.md`、`docs/gpio_led_config.md`。
