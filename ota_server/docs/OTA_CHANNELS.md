# Cat.1 对接自建 OTA

本文只讲 **本仓库 `ota_server` 与 Air780EHM 之间** 的升级。管理台、HTTP 拉包、MQTT 通知都属于这一套，与任何第三方云平台无关。

模组里 `libfota2` 的默认拉包逻辑仍保留在固件中；**本服务器从不调用、也不展示那条路径**。设备要升级到本服务，必须带上本服务的 `url`。

---

## 1. 怎么接到本服务器

| 条件 | 设备行为 |
|------|----------|
| MQTT **2004** 带 `url` | HTTP GET 该地址（管理台下发时总会带） |
| `FOTA_CFG.server_mode = "self"` | `AT+OTA` / 无 url 的 2004 也打 `self_url` |
| 未配 `self` 且 2004 无 `url` | 走模组 `libfota2` 默认地址，**不会访问本服务器** |

现网配置（`user/config.lua`）：

```lua
_G.FOTA_CFG = {
  server_mode = "self",
  self_url = "http://43.136.55.143/api/site/firmware_upgrade?",
}
```

---

## 2. 一次升级怎么走

```
1. 管理台：上传差分包 → 勾选升级全部或指定 IMEI
2. 管理台：填 IMEI + 目标版本 → 下发 OTA
3. 服务器 MQTT Publish → /panshi/device/{IMEI}/
4. 设备 1004 ota_accepted
5. 设备 HTTP GET  http://43.136.55.143/api/site/firmware_upgrade?imei=&firmware_name=&version=&project_key=
6. 本服务按当前版本匹配差分包：200 + bin，或 ≥300 无需升级
7. 设备 1004 stage=success → 约 1s 后重启
```

管理台下发的 2004：

```json
{
  "dataType": "2004",
  "action": "ota",
  "url": "http://43.136.55.143/api/site/firmware_upgrade?",
  "version": "2044.001.018",
  "timeout": 300000,
  "full_url": 0,
  "messageId": "ota-srv-xxxxxxxx"
}
```

`url` 以 `?` 结尾，`full_url=0`，模组自动附带 `imei` / `firmware_name` / `version` / `project_key`。  
HTTP 查询里的 `version` 是设备**当前**版本，用来匹配差分包；2004 里的 `version` 是目标版本，给任务台账用。

---

## 3. 管理台

地址：http://43.136.55.143/admin.html

| 菜单 | 做什么 |
|------|--------|
| 我的项目 | 项目 Key 须与固件 `PRODUCT_KEY` 一致 |
| 我的固件 | 上传差分 `.bin`；必须「升级全部」或「指定设备」 |
| 我的设备 | 允许 / 禁止某 IMEI 升级 |
| 下发升级 | MQTT 通知设备来本服务拉包 |
| 我的任务 | 2004 / 1004 状态 |
| 调试日志 | 每次 HTTP 检查的决策 |

操作细节见 [OTA_ADMIN.md](OTA_ADMIN.md)。点选升级见 [OTA_CONSOLE_UPGRADE.md](OTA_CONSOLE_UPGRADE.md)。

---

## 4. 版本号

| 位置 | 格式 | 例 |
|------|------|
| `user/main.lua` `VERSION` | 脚本 `XXX.YYY.ZZZ` | `001.000.018` |
| OTA HTTP / 管理台 | 内核.`XXX`.`ZZZ` | `2044.001.018` |

差分包的源版本必须等于设备当前内核版。样机已用云端脚本包从 `001.000.018` 升到 `001.000.019`（`2044.001.019`），步骤见 [OTA_REAL_DEVICE.md](OTA_REAL_DEVICE.md)。`server_mode=self` 已包含在 019 脚本中，`AT+OTA` / 无 url 的 2004 也会打本服务。

---

## 5. 相关文档

| 文档 | 内容 |
|------|------|
| [OTA_ADMIN.md](OTA_ADMIN.md) | 管理台逐步操作 |
| [OTA_CONSOLE_UPGRADE.md](OTA_CONSOLE_UPGRADE.md) | 后台怎么点升级 |
| [OTA_REAL_DEVICE.md](OTA_REAL_DEVICE.md) | 真机打包、上传、下发、确认 |
| [OTA_FOTA.md](OTA_FOTA.md) | 差分规则、循环保护 |
| [OTA_PROTOCOL.md](OTA_PROTOCOL.md) | HTTP / MQTT 字段 |
| [../deploy/DEPLOY.md](../deploy/DEPLOY.md) | 腾讯云部署 |
| [../../doc/MQTT_DOWNLINK.md](../../doc/MQTT_DOWNLINK.md) §6.7 | 2004 带 url |
