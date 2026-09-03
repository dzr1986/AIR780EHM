# 自建 OTA 服务器（780EHM_PJ 对接说明）

本项目使用 [`../`](..) 作为 **自建 HTTP OTA 服务端**（差分包、MySQL、MQTT 2004 触发、Nginx）。

端到端说明：[OTA_CHANNELS.md](OTA_CHANNELS.md)。部署：[../README.md](../README.md)。管理台：[OTA_ADMIN.md](OTA_ADMIN.md)。

---

## 设备怎么打到本服务

管理台下发 2004 **一定带 `url`**，现网脚本收到后就会 HTTP GET 本服务。

`user/config.lua` 现为：

```lua
FOTA_CFG.server_mode = "self"
FOTA_CFG.self_url = "http://43.136.55.143/api/site/firmware_upgrade?"
```

烧录该配置后，`AT+OTA` 无 url 也会打本服务。未烧录前，只要 2004 带 url 即可。

无 `url` 且未配 `self` 时，模组走 `libfota2` 默认地址，**不经过本服务器**。

对应协议：[MQTT_DOWNLINK.md](../../doc/mqtt/MQTT_DOWNLINK.md) **§6.7**。

---

## 兼容方式对照

| 升级触发方式 | 说明 |
|--------------|------|
| **管理台 / API 下发**（推荐） | MQTT 2004 含 `url` + `version` |
| MQTT 平台手动 Publish 2004 | 同上，必须带本服务 `url` |
| 2004 不带 url | 不打本服务（除非已烧 `server_mode=self`） |

---

## 方案组成

| 组件 | 路径 | 作用 |
|------|------|------|
| OTA 服务端 | `ota_server/` | 托管差分包、设备表、MQTT 触发 |
| Nginx HTTPS | `ota_server/deploy/nginx/` | 公网入口 |
| 固件（不改） | `user/fota_svc.lua` | 收到 2004+url 后 HTTP 拉包 |

---

## 典型升级流程（推荐）

```
1. 部署 ota_server（Docker）
2. Luatools 制作 dfota 差分包 → 上传到管理台
3. 管理台填 IMEI + 目标版本 → 「下发 OTA」
4. OTA 服务器 MQTT Publish → /panshi/device/{IMEI}/
5. 设备 net_mqtt → user/fota_svc.lua → libfota2 HTTP GET → 下载差分包
6. 设备 1004 stage=success → 重启
```

OTA 服务器下发的 MQTT 载荷示例：

```json
{
  "dataType": "2004",
  "action": "ota",
  "url": "https://你的域名/api/site/firmware_upgrade?",
  "version": "2034.001.003",
  "timeout": 300000,
  "full_url": 0,
  "messageId": "ota-srv-xxxx"
}
```

也可在 MQTT 平台**手动 Publish** 相同 JSON（与 §6.6 一致），无需 OTA 服务器触发。

---

## 版本号约定

| 位置 | 格式 | 示例 |
|------|------|------|
| `user/main.lua` `VERSION` | 脚本版 `XXX.YYY.ZZZ` | `001.000.002` |
| MQTT `version` / OTA 服务器 | IoT 版 `内核.XXX.ZZZ` | `2034.001.002` |

差分包 manifest 的 `sourceVersion` 须与设备**当前 IoT 版本**完全一致。

---

## 部署检查清单

- [ ] `ota_server` 已部署（`docker compose up -d`）
- [ ] Nginx HTTPS 域名与证书已配置
- [ ] `LUAT_MQTT_OTA_PUBLIC_BASE_URL` = 对外 HTTPS 基址
- [ ] `firmware/manifest.json` 源版本与现场设备一致
- [ ] 管理台 MQTT `connected: true`
- [ ] **固件未改 lua**，仍为原版 `FOTA_CFG.server_mode = "iot"`
- [ ] 试一台：管理台触发 → 设备 `1004 ota_accepted` → `stage:success`

---

## 相关文档

| 文档 | 内容 |
|------|------|
| [OTA_FLOW.md](OTA_FLOW.md) | **完整流程**（创建固件→MQTT 触发→HTTP 拉包→1004 回传）+ 代码完整性 |
| [OTA_PROTOCOL.md](OTA_PROTOCOL.md) | 协议字段详解 |
| [../README.md](../README.md) | 服务端部署、manifest、故障排查 |
| [MQTT_DOWNLINK.md](../../doc/mqtt/MQTT_DOWNLINK.md) §6.6 | 固件已支持的「自建 url」2004 格式 |
| [MQTT_PROTOCOL.md](../../doc/mqtt/MQTT_PROTOCOL.md) §4.4 | 2004 / 1004 OTA 协议 |

---

## 与模块默认云端并存

2004 **不带 `url`** 时，设备不会访问本服务：

- 带 `url` → 本服务 HTTP
- 不带 `url` → 模块默认云端

无需在固件里切换 `server_mode`。
