# 780EHM_PJ

技术文档：**[`doc/README.md`](doc/README.md)** · 模块树：**[`doc/overview/LUA_MODULES.md`](doc/overview/LUA_MODULES.md)** · 命名约定：**[`doc/overview/T31X_NAMING.md`](doc/overview/T31X_NAMING.md)** · API 真源：**[`doc/overview/CAT1_API_NAMING.md`](doc/overview/CAT1_API_NAMING.md)**

Air780EHM + T31x 摄像头 · LuatOS **方案1**（扁平 `user/` + 精简 `lib/`，真源共 **59 + 15 = 74** 个模块，2026-09-04 实测）。

## 架构一览

```
main.lua  ← VERSION / PRODUCT_KEY / 引导编排（18 步见 doc/overview/CODE_DOC_AUDIT.md §3）
  ├─ config.lua          26 行编排 → require 10 个 config 片段（全量 _G.X_CFG，见下）
  ├─ cell_boot.start()   [loader.enabled("cellular")] 蜂窝 SIM/APN 引导（lib/）
  ├─ usb_rndis.open()    [loader.enabled("rndis")] 可选 USB RNDIS
  ├─ net_mqtt.bootstrapNet()  [loader.enabled("mqtt")] MQTT 引导
  └─ app.start(peripheral, net_mqtt, t31x_ctrl)
       ├─ lib/uart_bridge → user/host_uart   T31x AT 业务（hif_* 族 18 文件）
       ├─ battery_guard / vbat / usb_charge / runtime_power   电量 / USB / rest 读路径
       ├─ pir_ctrl / peripheral / lib/led_ctrl / lp_wakeup    PIR 业务 / 外设 / 指示灯 / rest 唤醒
       ├─ net_mqtt + mqtt_*    云端唯一 MQTT（uplink / dl_* / hproto / dispatch）
       └─ t31x_ctrl / t31x_policy / t31x_notify / ipc_supv   协处理器电源门禁 / IPC 告警对账
```

> 完整族树与职责见 [`doc/overview/LUA_MODULES.md`](doc/overview/LUA_MODULES.md) §1.1（模块树为真源，勿手工复制清单）。

| 项 | 值 |
|----|-----|
| 配置真源 | `user/config.lua` 编排 → 片段 `features`/`cellular`/`t31x_burn`/`gpio_cfg`/`led_pir`/`battery`/`host`/`net`/`flags`/`events`（均在 `user/` 顶层，全部 `_G.X_CFG`） |
| 文档 | [`doc/`](doc)（[doc/README.md](doc/README.md) 全量索引） |
| 栈选择 | `APP_STACK = { mqtt = "net_mqtt", uart = "uart_bridge" }` |
| 核心固件 | `luatos.json` → Air780EHM SOC |
| 脚本区 | 量产约 **342KB / 512KB** 上限；可选裁剪见 [doc/power/CAT1_USER_LIB_SLIM.md](doc/power/CAT1_USER_LIB_SLIM.md) |

## 目录

| 路径 | 说明 |
|------|------|
| `user/` | 入口 / 编排 / config 片段 / MQTT 族 / T31x `hif_*` 族 / PIR / 外设 / FOTA / 授时 / `svc` 服务定位器（59 文件） |
| `lib/` | 驱动与公共库：串口 / GPIO / USB / 蜂窝引导 / 唤醒策略 / 加载器 / 系统（15 文件） |
| `doc/` | 文档库（按主题分目录：`overview/` `hardware/` `power/` `pir/` `mqtt/` `t31x/` `release/` `modules/`，`_audit/` 历史留档、`archive/` 迁移 stub；索引见 [doc/README.md](doc/README.md)） |
| `archive/` | 历史归档（已删模块留档、旧文档迁移表） |
| `firmware/` `量产/` | 发布固件产物（`.soc` / `.binpkg`）；**大部分被 `.gitignore` 忽略**，克隆后为空属正常，从量产包/发布流程获取 |
| `ota_server/` `http_server/` `video_upload_server/` `patch_server/` | 云侧服务端（Java / Python），**各自独立工程、独立部署**，与固件仅协议耦合；入口见各目录 `README` |
| `tools/` | 调试脚本（`tools/debug/` 静态护栏）、打包脚本 |

## lib/ 主路径（15）

| 文件 | 用途 |
|------|------|
| `uart_bridge.lua` | 串口唯一入口 |
| `gpio_util.lua` | GPIO 输入中断 / 输出初始化工具 |
| `config_manager.lua` | `_G.X_CFG` 统一读取（`cfgm.get`） |
| `module_loader.lua` | `load` / `enabled` / `opt` 模块加载 |
| `usb_charge.lua` | USB / 充电 / rest 门禁（`blocksHostIdle` / `blocks4gRest`） |
| `usb_rndis.lua` / `usb_vuart.lua` | RNDIS（可选）/ USB 虚拟串口 |
| `cell_boot.lua` | 蜂窝拨号引导：SIM/APN 探测、运营商映射、`IP_READY` 等待 |
| `led_ctrl.lua` | 红蓝 LED、开机序列、电量灯效 |
| `runtime_power.lua` | 运行态电量 / 在线 / rest 读路径收口 |
| `device_id.lua` | 设备标识（IMEI 等） |
| `utils.lua` / `sys.lua` / `watchdog.lua` / `libfota2.lua` | 工具 / 平台封装 / 模组 WDT / OTA 引擎 |

## user/ 主路径（59）

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口：VERSION 校验、蜂窝/RNDIS/MQTT 引导、`app.start`、`sys.run` |
| `config.lua` | 配置编排（26 行，仅按依赖顺序 require 片段） |
| `features.lua` / `cellular.lua` / `t31x_burn.lua` / `gpio_cfg.lua` / `led_pir.lua` / `battery.lua` / `host.lua` / `net.lua` / `flags.lua` / `events.lua` | **config 片段**：`FEATURE_CFG` / `CELLULAR_CFG` / 烧录门禁 / `GPIO_IN·OUT`+`KEY_CONFIG` / `LED·WLED·PIR_CFG` / `BATTERY_CFG` / T31x 服务 / `UART·WDT·MQTT·FOTA_CFG` / `MODULE_FLAGS` / `APP_EVENTS` |
| `app.lua` | 编排中心：事件订阅、低功耗、USB/PIR 联动（**冻结不拆**） |
| `host_uart.lua` | T31x AT 主文件（锁 / SYS_EVT / state）+ 子模块 `hif_cmd_*` / `hif_rx*` / `hif_ipc_*` |
| `net_mqtt.lua` | MQTT 主文件 + 子模块 `mqtt_conn` / `mqtt_dispatch` / `mqtt_uplink` / `mqtt_dl_*` / `mqtt_hproto` |
| `net_tcp.lua` | T31x TCP 业务通道（`MODULE_FLAGS` 懒加载） |
| `pir_ctrl.lua` | PIR 硬件中断、冷却、录像会话、PIRSTAT |
| `peripheral.lua` | 外设聚合（LED / 按键 / PIR 硬件启动） |
| `t31x_ctrl.lua` / `t31x_policy.lua` / `t31x_notify.lua` | 协处理器 GPIO / IPC 断电 / ready / 上电门禁 / 唤醒三级链 |
| `ipc_supv.lua` | IPC 告警对账（`alertCode` / `map1011` / `reconcile`；原 `ipc_supervision` + `ipc_alert_contract` 并入） |
| `vbat.lua` / `battery_guard.lua` | 电池 ADC 采样 / 电量保护 |
| `lp_wakeup.lua` / `host_event.lua` / `fota_svc.lua` / `sound_prompt.lua` / `time_sync.lua` | rest 唤醒通道 / HOSTEVT / MQTT 2004 OTA / 提示音 / 授时 |

精简与开关说明：[doc/power/CAT1_SLIMMING_FLOW.md](doc/power/CAT1_SLIMMING_FLOW.md) · [doc/power/CAT1_USER_LIB_SLIM.md](doc/power/CAT1_USER_LIB_SLIM.md) · 低功耗策略 [doc/power/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](doc/power/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md)

## GPIO 配置速查

引脚与按键在 `user/gpio_cfg.lua`（`GPIO_IN` / `GPIO_OUT` / `KEY_CONFIG`）：

| 字段 | 含义 |
|------|------|
| `init_level` | `gpio.setup` 初始电平（0/1），默认灭/断电多为 **0** |
| `on_level` | 逻辑开启电平（LED 亮、T31x 供电多为 **1**） |

`GPIO_IN` 使用 `pull`、`trigger_mode`、`debounce_ms`、`active_level`（见 [doc/overview/CONFIG.md](doc/overview/CONFIG.md)）。

## 功能开关

`user/flags.lua` → `MODULE_FLAGS` 裁剪服务；`FEATURE_CFG` 见 `user/features.lua`（[doc/power/CAT1_USER_LIB_SLIM.md](doc/power/CAT1_USER_LIB_SLIM.md)）。

## 打包

| 用途 | 命令 | 说明 |
|------|------|------|
| **量产交付（真源）** | `python tools/pack_mass_prod.py <脚本版本>` | 生成 `{日期}_量产/`（固件 + 烧录工具），见 [doc/release/CAT1_FLASH_FLOW.md](doc/release/CAT1_FLASH_FLOW.md) |
| **单台烧录** | `python tools/gui/flash/cat1_flash.py flash-script` | 只刷脚本区、免 BOOT；不要用 Luatools debug99 |
| 工程源码包（归档/交付源码） | `package_project.bat` / `pack.ps1` → `780EHM_PJ_YYYYMMDD.zip` | 含 `user/`、`lib/`、`doc/`、`README.md`、`luatos.json`；**不是**烧录产物 |

> `luatos.json` 的 `core`（V2034）仅供 Luatools 打开工程调试；量产内核以 [doc/release/RELEASE_v1.2.md](doc/release/RELEASE_v1.2.md) 登记的内核号为准。

---

**工程包** v1.2 · **固件 VERSION** `001.000.160`（`user/main.lua`）· **更新** 2026-09-04（架构/配置口径对齐 74 模块真源；152–160 为审计/重构行为修复；模块名与引导链以 `user/`、`lib/` 实测为准）
