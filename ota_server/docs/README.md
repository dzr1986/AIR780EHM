# ota_server 文档

4G OTA 服务说明集中在本目录。部署与 API 总表见 [../README.md](../README.md)。

| 文档 | 内容 |
|------|------|
| [IPC_UPGRADE.md](IPC_UPGRADE.md) | **T31 IPC 升级**（Nginx 文件服务 + ipc_upgrade + x86demo + Windows UI） |
| [OTA_CHANNELS.md](OTA_CHANNELS.md) | **Cat.1 对接本服务器**（MQTT 2004 + HTTP 拉包） |
| [OTA_SYSTEM_FLOW.md](OTA_SYSTEM_FLOW.md) | **系统流程图**（部署、升级时序、拉包决策） |
| [OTA_ADMIN.md](OTA_ADMIN.md) | 管理台操作 |
| [OTA_CONSOLE_UPGRADE.md](OTA_CONSOLE_UPGRADE.md) / [PDF](OTA_CONSOLE_UPGRADE.pdf) | **后台怎么点升级**（上传包 → 下发 OTA） |
| [OTA_FOTA.md](OTA_FOTA.md) | 模组 FOTA 规则（版本号、空包、循环保护） |
| [OTA_REAL_DEVICE.md](OTA_REAL_DEVICE.md) | **真机云端脚本升级**（打包 → 上传 → 2004 → 1008 确认） |
| [OTA_CLOSED_LOOP.md](OTA_CLOSED_LOOP.md) | 闭环测试步骤与实测记录 |
| [OTA_FLOW.md](OTA_FLOW.md) | 端到端流程 + 代码完整性清单 |
| [OTA_SERVER.md](OTA_SERVER.md) | 固件对接（不改 lua） |
| [OTA_PROTOCOL.md](OTA_PROTOCOL.md) | HTTP / MQTT 协议字段 |
| [OTA_DATA.md](OTA_DATA.md) | MySQL 台账与启动默认数据 |
| [../deploy/DEPLOY.md](../deploy/DEPLOY.md) | 腾讯云 `43.136.55.143` 部署与运维 |

固件 Lua 专题仍在仓库 [`doc/modules/FOTA_SVC_FLOW.md`](../../doc/modules/FOTA_SVC_FLOW.md)。
