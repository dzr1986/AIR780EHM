# V1 · 系统与固件总览

> **读者**：任何进项目的人；30 秒建立全局，再按需去 V2–V7。
> **真源**：[SYSTEM_ARCHITECTURE](../overview/SYSTEM_ARCHITECTURE.md)（系统级总览）· [CODE_LAYERING_ARCHITECTURE](../overview/CODE_LAYERING_ARCHITECTURE.md)（分层真源）· [CALL_GRAPH](../overview/CALL_GRAPH.md)（启动/调用）· [CONFIG](../overview/CONFIG.md)（配置索引）· [FUNCTIONAL_ARCHITECTURE](../overview/FUNCTIONAL_ARCHITECTURE.md)（功能域）
> **代码真源**：仓库根 `user/`、`lib/`（勿在 `LuaTools/userprojs/` 副本改代码）。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 本卷是全局入口；细走 [V2_LUA_API](MANUAL_V2_LUA_API.md) → [V4_T31X](MANUAL_V4_T31X.md) → [V3_MQTT](MANUAL_V3_MQTT.md) → [V5_POWER](MANUAL_V5_POWER.md) → [V6_PIR](MANUAL_V6_PIR.md) → [V7_TOOLCHAIN](MANUAL_V7_TOOLCHAIN.md)

---

## 1. 三十秒速览

- 这是一套**电池供电的 4G 可视化门球/摄像头**方案：`PIR 感应 → 录像/抓拍 → MQTT 信令 → 云端`。
- **双芯片**：`Air780EHM`（Cat.1 4G 模组，跑 LuatOS/Lua）承担入网、MQTT、FOTA、供电门控；`T31x`（Linux IPC）承担摄像头、编码、TF 录像、GB28181、抽片。两者之间只走 **UART AT + GPIO 电源/唤醒**。
- **云端三件套**：MQTT 信令 broker（现网 `112.86.146.218:2123`，panshi 主题）、自建 OTA（`43.136.55.143`，差分包升级）、视频上传服务（`uploadVideo` `:7003`）。
- **代码规模**：`user/` 58 + `lib/` 15 = 73 个 Lua 模块；量产脚本包约 **342KB / 512KB** Flash（2026-08 口径，见 [CODE_SIZE_OPTIMIZATION](../overview/CODE_SIZE_OPTIMIZATION.md)）。

```text
┌───────────┐  UART AT      ┌─────────────────┐  MQTT 200x/100x   ┌──────────────┐
│  T31x IPC │◄─────────────►│  Air780EHM       │◄─────────────────►│  panshi MQTT │──► 业务后台
│ Linux 摄像头│ GPIO 电源/唤醒  │  Cat.1 LuatOS/Lua │ HTTP FOTA/上传      │ broker:2123  │
└───────────┘                └─────────────────┘                    └──────────────┘
      │  TF 录像/抽片             ▲ USB RNDIS 共享蜂窝网给 T31x
      └──────────────────────────┘
```

## 2. 双芯片分工（🟢 自包含）

| 能力 | Cat.1（Air780EHM/Lua） | T31x（Linux IPC） |
|------|------------------------|-------------------|
| 蜂窝入网 / MQTT / FOTA | **负责** | 不直连 MQTT |
| 摄像头 / 编码 / 录像 / 抽片 | 不涉及 | **负责**（写 TF 卡 MP4/JPEG） |
| 供电与唤醒 T31x | **负责**（GPIO 可控，见 V5/V4） | 受控方 |
| 低功耗主流程（rest） | **主控**（断 T31x 供电进入） | 断电休眠 |
| PIR / 电池 / 充电管理 | **负责** | — |
| 异常上报（IPC 侧） | 收 UART 事件 → MQTT | 只经串口通知 4G |

T31x 侧详细协作见 [MANUAL_V4_T31X.md](MANUAL_V4_T31X.md)；云端协议见 [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md)。

## 3. 固件代码分层（🟢 自包含）

真源：[CODE_LAYERING_ARCHITECTURE](../overview/CODE_LAYERING_ARCHITECTURE.md) + [LUA_MODULES §1.1](../overview/LUA_MODULES.md)（模块树真源）。

| 层 | 目录 | 角色 | 代表 |
|----|------|------|------|
| L0–L2 常驻底层 | `lib/`（15） | 策略/底层/常驻库，模块化可裁 | `sys` `utils` `module_loader` `config_manager` `runtime_power` `libfota2` `cell_boot` `usb_charge` `usb_rndis` `usb_vuart` `uart_bridge` `gpio_util` `device_id` `watchdog` `led_ctrl` |
| L3 业务模块 | `user/`（59） | 四大族：config 11 / host_uart 18 / net_mqtt 13 / 其它业务 17（含 `svc` 服务定位器） | 见下表 |
| 入口 | `user/main.lua` | 固件入口（`VERSION`/`PRODUCT_KEY`/`BUILD_TAG`），167 行 | — |

**user/ 四大族**（语义分组，详见 [modules/README](../modules/README.md) 各子模块索引表）：

| 族 | 文件数 | 职责 | 入口/代表文件 |
|----|--------|------|---------------|
| config 族 | 11 | 配置真源（`_G.X_CFG` 表） | `config.lua`（26 行编排）+ 片段（`features` `cellular` `gpio_cfg` `events` …） |
| host_uart 族 | 18 | T31x ↔ Cat.1 UART AT 链路 | `host_uart.lua`（主）+ `hif_at` `hif_cmd*` `hif_rx*` `hif_ipc*` |
| net_mqtt 族 | 13 | 云端 MQTT 协议 | `net_mqtt.lua`（主）+ `mqtt_conn` `mqtt_uplink` `mqtt_downlink` `mqtt_dl_*` `mqtt_ul_*` `mqtt_dispatch` `mqtt_hproto` |
| 其它业务 | 16 | 电源/外设/PIR/IPC 监管 | `app.lua` `battery_guard.lua` `vbat.lua` `t31x_ctrl.lua` `t31x_policy.lua` `pir_ctrl.lua` `ipc_supv.lua` `time_sync.lua` `sound_prompt.lua` `fota_svc.lua` `net_tcp.lua` `lp_wakeup.lua` `host_event.lua` `led_pir.lua` … |

## 4. 启动与生命周期（🟢 自包含骨架）

真源：[CALL_GRAPH](../overview/CALL_GRAPH.md) · [LUA_MODULES §2](../overview/LUA_MODULES.md) · [modules/APP_EVENT_BUS](../modules/APP_EVENT_BUS.md)。

```text
main.lua ─► module_loader 装载 config 族（先配置后业务）
        ─► app.start() 编排：外设/电池/vbat → 蜂窝入网 → net_mqtt 连接 → 时间同步 → host_uart 启动
        ─► 事件总线 APP_EVENTS 驱动运行期协作（低功耗/USB/PIR/IPC 桥）
```

- **模块加载**：`config.lua` 26 行负责把 config 片段与业务模块装好；运行期跨模块访问走**懒加载 API**（`svc.hostUart()`/`uartBridge()` 等），禁止业务侧持 `_G` 别名（见 [LUA_MODULES §4](../overview/LUA_MODULES.md)）。
- **事件总线**：`APP_EVENTS` 常量定义在 config 片段 `events.lua`，用 `sys.publish/subscribe`（合宙）承载；见 [MANUAL_V2 §4](MANUAL_V2_LUA_API.md)。
- **连接启动**：`lib/cell_boot.lua` 完成 SIM/APN 与入网，就绪后 `net_mqtt.bootstrapNet()`；详见 [modules/CELLULAR_BOOTSTRAP](../modules/CELLULAR_BOOTSTRAP.md)。

## 5. 配置体系（🟢 自包含骨架）

真源：[CONFIG](../overview/CONFIG.md)（配置索引，含 `GPIO_IN`/`GPIO_OUT`、Air780 GPIO 编号、`config.mk` 宏对照）· `user/` 内 config 族。

| 面 | 位置 | 说明 |
|----|------|------|
| Lua 运行时配置 | `user/config.lua` + 片段 | 全部 `_G.X_CFG` 表（如 `LOW_POWER_CFG`、`SOUND_CFG`），片段在 `user/` 顶层，见 `config.lua` 注释真源 |
| 编译期宏 | 仓库根 `config.mk` | 控制裁剪/特性，与 `lib/` 模块 `MODULE_FLAGS`/懒加载配合（见 [power/CAT1_SLIMMING_FLOW](../power/CAT1_SLIMMING_FLOW.md)） |
| 平台 OTA/产物 | `luatos.json` / `VERSION` | 合宙 IoT 工程配置；`user/main.lua` `VERSION` |
| GPIO 硬件表 | `user/gpio_cfg.lua` | `GPIO_IN`/`GPIO_OUT` 登记，编号口径见 [hardware/T31X_CAT1_GPIO](../hardware/T31X_CAT1_GPIO.md) |

> **`_G` 写入边界**：`_G.xxx=` 写操作**只允许**出现在 `config.lua`/`main.lua` 平台约定内；模块仅允许 `_G[_modname] = _M`（合宙惯例）。审查规则见 [overview/ARCHITECTURE_REVIEW_20260903](../overview/ARCHITECTURE_REVIEW_20260903.md)。

## 6. 版本与产物（🟢 自包含骨架）

| 项 | 值/来源 | 说明 |
|----|---------|------|
| 脚本 `VERSION` | `user/main.lua`（文档侧当前同步版本 **001.000.156**，见 [CAT1_API_NAMING](../overview/CAT1_API_NAMING.md) 头） | 出现在 1008.`scriptVersion` |
| OTA `version`（合宙 IoT） | `内核号.001.xxx`，如 `2044.001.004` | `firmwareVersion` 口径 = `rtos.version` 内核号 + 脚本版本首段.末段；**不是** `main.lua` 的 `VERSION` |
| `project` / `buildTag` | 如 `PANSHI_CAT1` / `v20260730` | 1008/BASEINFO 字段 |
| 量产包 | `量产/` 目录（bin/soc/binpkg 三件套），~342KB | 打包见 [MANUAL_V7_TOOLCHAIN.md](MANUAL_V7_TOOLCHAIN.md) |
| 固件镜像 | `firmware/`、`780EHM_PJ_v1.2_20260602.zip` | 发布归档，见 [release/RELEASE_v1.2](../release/RELEASE_v1.2.md) |

## 7. 仓库目录地图（🟢 自包含）

| 目录 | 内容 |
|------|------|
| `user/` `lib/` | **固件 Lua 真源**（74 模块），改代码只动这里 |
| `doc/` | 项目文档（主题真源 + 本手册 + `_audit/` 留档） |
| `tools/` | 工具链（烧录/监控/协议测试/护栏脚本，见 [MANUAL_V7](MANUAL_V7_TOOLCHAIN.md)） |
| `release/` `量产/` `firmware/` `*.zip` | 产物/发布（注：`量产`、`firmware` 为仓库根；`doc/release/` 是发布流程文档） |
| `http_server/` `ota_server/` `patch_server/` `video_upload_server/` | 配套服务端（各自仓库/文档，见 [doc/README 外部工程](../README.md)） |
| `config.mk` `luatos.json` `pack.ps1` `package_project.bat` | 编译裁剪/打包脚本（[MANUAL_V7 §3](MANUAL_V7_TOOLCHAIN.md)） |
| `scripts/` `archive/` | 历史/一次性脚本与文档快照 |

> 目录细节若与真源冲突，以 [doc/README](../README.md) 与 [SYSTEM_ARCHITECTURE](../overview/SYSTEM_ARCHITECTURE.md) 为准。

## 8. 深潜入口

- 想改 **Lua 模块/API** → [MANUAL_V2_LUA_API.md](MANUAL_V2_LUA_API.md)
- 想联调 **MQTT** → [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md)
- 想处理 **T31x 协作/IPC** → [MANUAL_V4_T31X.md](MANUAL_V4_T31X.md)
- 想排查 **功耗/低电** → [MANUAL_V5_POWER.md](MANUAL_V5_POWER.md)
- 想查 **PIR/录像** → [MANUAL_V6_PIR.md](MANUAL_V6_PIR.md)
- 想跑 **工具链/烧录/发布** → [MANUAL_V7_TOOLCHAIN.md](MANUAL_V7_TOOLCHAIN.md)
- 功能域分解视图 → [FUNCTIONAL_ARCHITECTURE](../overview/FUNCTIONAL_ARCHITECTURE.md)；风险与重构建议 → [CODE_ANALYSIS](../overview/CODE_ANALYSIS.md)
