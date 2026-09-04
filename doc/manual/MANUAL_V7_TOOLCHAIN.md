# V7 · 产测 / 烧录 / 发布 / 工具链

> **读者**：烧录、量产、发版、跑文档/代码护栏、复用调试脚本的人。
> **真源**：`tools/README.md`（仓库根工具目录，doc 外不参与 md 互链检查）· `doc/release/`（无独立 README，由 doc/README 登记）· 各工具自身 `--help`/源码注释。
> **代码真源**：仓库根 `tools/`、`doc/_tools/`、`config.mk`、`pack.ps1`、`package_project.bat`、`luatos.json`。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V1_SYSTEM](MANUAL_V1_SYSTEM.md)（产物/版本）· [V2_LUA_API](MANUAL_V2_LUA_API.md)（改码后回写）

---

## 1. 三十秒速查

| 我要… | 用 |
|--------|-----|
| 日常三件事（流程检测/烧录/MQTT 测试） | 双击 `tools/` 下三个 bat（[§2](#2-日常图形工具-gui)） |
| 产线量产交付 | `python tools/pack_mass_prod.py <版本>` → `{日期}_量产/`（[§4](#4-量产与发布)） |
| 烧一台机 | `tools/cat1_flash_gui.py` 或 release 流程（[§3](#3-烧录流程)） |
| 改完代码自检 | 回归/护栏脚本（[§6](#6-代码护栏与回归)） |
| 改完文档自检 | 登记 + 链接护栏（[§5](#5-文档护栏与同步)） |

## 2. 日常图形工具（gui）

`tools/README.md`：**日常请只进 `gui/`**，双击三个 bat：

| bat | 干什么 | 备注 |
|-----|--------|------|
| `flow_monitor_gui.bat` | 流程检测 GUI（1003 状态观测等） | 对应 `tools/flow_monitor_gui.py` |
| `cat1_flash_gui.bat` | Cat.1 烧录 GUI | 对应 `tools/cat1_flash_gui.py`（另见 release 文档） |
| `mqtt_tools_gui.bat` | MQTT 测试 GUI（加载 MQTT_PROTOCOL 做 200x 命令测试） | 对应 `tools/gui/mqtt/mqtt_tools_gui.py` |

## 3. 烧录流程

真源：[CAT1_FLASH_FLOW](../release/CAT1_FLASH_FLOW.md)（烧录主流程）· [CAT1_FLASH_TOOL](../release/CAT1_FLASH_TOOL.md)（GUI/CLI 工具）· [CAT1_USB_RNDIS_CFG_CRASH_FLASH](../release/CAT1_USB_RNDIS_CFG_CRASH_FLASH.md)（RNDIS cfg 崩溃恢复实机流程）。

| 环节 | 要点 |
|------|------|
| 认 COM | 先确认设备枚举的 COM（含 RNDIS cfg 崩溃场景的 COM10 排查） |
| 免 BOOT | 本方案烧录免手动进 BOOT |
| 烧写 | `flash-script`/AgentBoot（`tools/agentboot/`） |
| 烧完验收 | 验版本/行为，见 CAT1_FLASH_FLOW 末尾清单 |

## 4. 量产与发布

| 项 | 命令/位置 | 说明 |
|----|-----------|------|
| 量产打包 | `python tools/pack_mass_prod.py <VERSION>`（如 `001.000.036`） | 生成 `{日期}_量产/`（固件 + 烧录工具，见 `tools/README.md`） |
| 仓库产物 | 根 `量产/`、`firmware/`、`780EHM_PJ_v1.2_*.zip` | 固件镜像（soc/bin/binpkg）与发布归档 |
| 编译裁剪 | 根 `config.mk` | 与 `lib/` 模块 `MODULE_FLAGS`/懒加载配合（[CAT1_SLIMMING_FLOW](../power/CAT1_SLIMMING_FLOW.md)） |
| 工程配置 | `luatos.json` / `VERSION` | 合宙 IoT 工程与版本 |
| 打包脚本 | `pack.ps1` / `package_project.bat` | 项目打包辅助 |
| 版本发布说明 | [RELEASE_v1.2](../release/RELEASE_v1.2.md) | v1.2 发布/备份说明 |

## 5. 文档护栏与同步

| 脚本 | 干什么 | 什么时候跑 |
|------|--------|------------|
| `python doc/_tools/doc_registry_check.py` | **登记护栏**：doc 主题下每个 md 必须被顶层或同主题 README 登记 | 新增/移动文档后（本手册目录已在检查范围） |
| `python tools/debug/_doc_md_link_check.py` | **互链护栏**：doc 内 md 文件级互链断链（外部/待补走 EXEMPT） | 改链接后 |
| `python tools/sync_doc_naming.py` | 把 `doc/` 里的历史 API 别名收敛到真名 | 改 API 名后（见 [CAT1_API_NAMING §4](../overview/CAT1_API_NAMING.md)） |
| `python tools/debug/_doc_archive_by_topic.py` | 按主题归档并重算全仓 md/html 链接 | doc 重新分目录时 |
| `doc/_tools/doc_registry_check.py --export` | 打印待补登记行草稿 | 护栏报未登记时 |
| 抽查 `doc/manual/` 各卷 `🟢 自包含` 表与真源一致性 | 发现速查表数值/字段与真源漂移（人工核对，无自动化脚本） | 协议/API/功耗行为上游变更后；发布前 |

## 6. 代码护栏与回归

| 脚本（tools/debug/） | 覆盖 | 场景 |
|----------------------|------|------|
| `_host_uart_regression_check.py` | host_uart 族（AT 表/bind）静态回归 | 动 `host_uart`/`hif_*` 后 |
| `_net_mqtt_regression_check.py` | net_mqtt 族（命名/分发）静态回归 | 动 `mqtt_*`/`net_mqtt` 后 |
| `_protocol_regression_check.py` | 协议层一致性 | 协议相关改动后 |
| `_gen_bind_header.py --check-all` | hif bind 头与代码一致 | 动 bind 后（`--emit hif_cmd_xxx.lua` 生成） |
| `_module_tree.py` / `_ref_name_check.py` | 模块树/引用名一致性 | 模块改名后 |
| `run_all_checks.py` | 汇总运行主要检查 | 发布前整跑 |

## 7. 调试与一次性脚本族（tools/debug/，按用途选）

| 族 | 脚本（名前缀） | 干什么 |
|----|----------------|--------|
| T31x 推机 | `tools/t31x/` | 把编译好的 ipc 经 COM7 推到 T31 |
| COM7 交互/恢复 | `_com7_cmd` / `_com7_probe` / `_com7_raw` / `_com7_recover` / `_com7_uart_check` / `_com7_unstick_ps2` | 串口命令、探测、恢复、反卡死 |
| 抓包/观测 | `_cat1_log_watch` / `_log_snapshot` / `_watch_1003_status` / `_watch_reboot` / `_reboot_capture` / `_usb_capture` / `_usb_lua_dump` / `_boot_wait` / `_eth0_check` | 日志/1003/重启/USB/eth0 观测 |
| 自动化实测 | `_test_2002_closed_loop` / `_test_cat1_ota_e2e` / `_run_mqtt_autotest_params` / `_loop_2013_playback` / `_reboot_then_2007_2011` / `_clip_upload_audit` / `_clip_upload_full_audit` / `_test_1003_radio` | 单场景闭环/E2E 实测 |
| 一次性补丁/改名 | `_patch_t31_*` / `_reset_syscfg_boot` / `_rename_lua_modules` / `_strip_config_comments` / `_shorten_logs` | 定点补丁与历史治理 |
| GUI 后端 | `tools/gui/` | 三个图形界面实现 |

> 脚本多为**一次性/诊断用途**，新维护优先看是否已有可复用脚本；不要造第四个"同款"脚本。

## 8. 发布检查清单（维护约定）

- [ ] 烧录产物出自 `pack_mass_prod.py`（量产）或 release 流程（单台）。
- [ ] 代码护栏整跑：`run_all_checks.py` + 相关 regression。
- [ ] 文档护栏：`doc_registry_check.py` + `_doc_md_link_check.py` 双 PASS。
- [ ] API 改名则跑 `sync_doc_naming.py`，检查 `git diff -- doc/` 只有收敛差异。
- [ ] 版本同步：`user/main.lua` `VERSION`、`luatos.json`、发布说明 [RELEASE_*](../release/)、[CAT1_API_NAMING](../overview/CAT1_API_NAMING.md) 头部版本口径。

## 9. 相关文档

- 文档顶层索引：[doc/README](../README.md)（登记手册与全部主题）
- 精简单测流程：[CAT1_SLIMMING_FLOW](../power/CAT1_SLIMMING_FLOW.md)
- 服务端配套：`ota_server`/`video_upload_server`/`http_server`/`patch_server`（[doc/README 外部工程](../README.md)）
- 工具链自动化报告（留档）：[CAT1_TOOLCHAIN_TEST_REPORT](../_audit/CAT1_TOOLCHAIN_TEST_REPORT.md)（2026-08-17，IMEI 124）
