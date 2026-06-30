# 自建 OTA 服务器（780EHM_PJ 对接说明）

本项目使用 [`../ota_server/`](../ota_server/) 作为 **自建 HTTP OTA 服务端**（差分包、MySQL、MQTT 2004 触发、Nginx HTTPS）。

完整部署手册：[../ota_server/README.md](../ota_server/README.md)

---

## 重要：固件代码无需修改

780EHM_PJ **现有固件已兼容**自建 OTA，**不要改** `user/fota_svc.lua`、`user/config.lua` 里的 OTA 逻辑。

| 文件 | 保持原样 |
|------|----------|
| `user/fota_svc.lua` | 已支持 MQTT 2004 下行带 `url` 字段（见 §6.6） |
| `user/config.lua` → `FOTA_CFG` | 保持 `server_mode = "iot"` 即可 |
| `user/main.lua` | `PRODUCT_KEY` / `VERSION` 不变 |

### 为什么不用改固件？

`user/fota_svc.lua` 的 `buildIotOpts()` **本来就有**这条逻辑：

```
MQTT 2004 载荷里若有 url  →  直接用该 url 调 libfota2
MQTT 2004 载荷里若无 url  →  走合宙 IoT（product_key + version）
```

自建 OTA 服务器触发升级时，会在 MQTT 2004 里**带上 `url`**，因此设备自动走自建 HTTP，与 `FOTA_CFG.server_mode` 无关。

对应文档：[MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) **§6.6 OTA（自建 url）**（固件侧早已实现）。

---

## 兼容方式对照

| 升级触发方式 | 固件是否需改 | 说明 |
|--------------|--------------|------|
| **OTA 服务器管理台 / API**（推荐） | **否** | 服务器 MQTT 下发 2004，payload 含 `url` + `version` |
| MQTT 平台手动 Publish 2004 | **否** | 同上，见 §6.6 示例 JSON |
| 合宙 IoT 云（2004 不带 url） | **否** | 仍走原有合宙 IoT 逻辑 |
| 改 `config.lua` custom_url | 否（不推荐） | 非必须；仅在没有 MQTT 下发 url 时才需要考虑 |

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
| [ota_server/README.md](../ota_server/README.md) | 服务端部署、manifest、故障排查 |
| [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) §6.6 | 固件已支持的「自建 url」2004 格式 |
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) §4.4 | 2004 / 1004 OTA 协议 |

---

## 合宙 IoT 云（仍可用，与自建并存）

2004 **不带 `url`** 时，设备仍走合宙 IoT（`product_key` + `version`），与自建 OTA **互不冲突**：

- 带 `url` → 自建 HTTP（OTA 服务器或手动 MQTT）
- 不带 `url` → 合宙云

无需在固件里切换 `server_mode`。
