# 4G OTA 系统流程图

生产入口：http://43.136.55.143/admin.html  
设备拉包：`GET /api/site/firmware_upgrade?imei=&project_key=&firmware_name=&version=`

操作细节见 [OTA_ADMIN.md](OTA_ADMIN.md)，协议见 [OTA_PROTOCOL.md](OTA_PROTOCOL.md)，FOTA 规则见 [OTA_FOTA.md](OTA_FOTA.md)。

---

## 1. 部署与组件

```mermaid
flowchart TB
  subgraph pub [公网]
    Browser[浏览器管理台]
    Device[4G 模组]
  end

  subgraph cloud [腾讯云 43.136.55.143]
    Nginx[Nginx :80]
    App[ota-server :8080]
    MySQL[(MySQL luat_ota)]
    Disk[firmware 目录]
  end

  Broker[MQTT Broker<br/>112.86.146.218:2123]

  Browser -->|HTTP Token| Nginx --> App
  Device -->|HTTP 拉包| Nginx --> App
  App --> MySQL
  App --> Disk
  App -->|2004 下发 / 1004 订阅| Broker
  Device -->|MQTT 上下行| Broker
```

MQTT **不经过 Nginx**：应用直连 Broker。  
Topic：下行 `/panshi/device/{IMEI}/`，上行 `/panshi/app/{IMEI}/event`。

---

## 2. 端到端升级（主流程）

```mermaid
sequenceDiagram
  actor Ops as 运维
  participant Admin as 管理台
  participant OTA as ota-server
  participant DB as MySQL
  participant MQTT as Broker
  participant Dev as 4G 模组

  Ops->>Admin: 上传差分包 / 指定 IMEI
  Admin->>OTA: POST firmware-packages/upload
  OTA->>DB: firmware_packages + 指定设备
  OTA->>OTA: 文件写入 firmware/

  Ops->>Admin: 固件升级 下发
  Admin->>OTA: POST /ota/trigger
  OTA->>DB: 写入 ota_tasks PUBLISHED
  OTA->>MQTT: 2004 action=ota url=? version=
  MQTT->>Dev: /panshi/device/{IMEI}/

  Dev->>MQTT: 1004 ota_accepted
  MQTT->>OTA: 订阅 event
  OTA->>DB: 任务 ACCEPTED

  Dev->>OTA: GET firmware_upgrade?imei&version
  alt 匹配到差分包
    OTA-->>Dev: 200 + bin Content-Length>0
    OTA->>DB: ota_status=IN_PROGRESS 循环计数+1
  else 已最新 / 禁止 / 无包
    OTA-->>Dev: HTTP >=300
  end

  Dev->>MQTT: 1004 starting / success
  MQTT->>OTA: handleMqttUplink
  OTA->>DB: current_version=目标 任务 SUCCESS
  Dev->>Dev: rtos.reboot
```

固件 lua **不用改**：2004 带 `url` 时，模组按该地址拉包。

---

## 3. 拉包决策

```mermaid
flowchart TD
  A[GET /api/site/firmware_upgrade] --> B{项目 Key 是否存在}
  B -->|否| C[26 无效项目]
  B -->|是| D{IMEI 是否已属其他项目}
  D -->|冲突| E[25 无权限]
  D -->|否或首次绑定| F{设备是否禁止升级}
  F -->|禁止| G[>=300]
  F -->|允许| H{固件名是否在库中}
  H -->|无此固件| I[27 无效固件]
  H -->|有| J{源版本匹配且目标更高<br/>升级全部或指定 IMEI<br/>版本规则 canUpgrade}
  J -->|否| G
  J -->|是| K{文件存在且大于 0 字节}
  K -->|否| L[404 拒绝空包]
  K -->|是| M{同一源版本连续下发同一目标 >=6}
  M -->|是| N[禁止该设备 >=300]
  M -->|否| O[200 / 206 返回 bin]
```

版本规则：脚本 `A.B.C` 中 B 无意义；允许 A 不变且 C 增大，或 A 增大且 C 不减小；禁止 core 回退。

---

## 4. 管理台业务

```mermaid
flowchart LR
  Login[登录 Token] --> P[我的项目]
  P --> D[我的设备]
  P --> F[固件列表]
  F --> U[创建固件]
  U --> All[升级全部 / 指定 IMEI]
  D --> Ban[允许 / 禁止升级]
  P --> T[固件升级 2004]
  T --> Task[我的任务]
  T --> Log[调试日志]
  P --> Loop[闭环测试]
```

| 菜单 | 落库 |
|------|------|
| 我的项目 | `ota_projects` |
| 我的设备 | `devices` |
| 固件列表 | `firmware_packages` / `firmware_device_assignments` |
| 固件升级 | MQTT 2004 + `ota_tasks` |
| 我的任务 | `ota_tasks` |
| 调试日志 | `logs/ota-audit.jsonl` |
| 闭环测试 | 模拟 IMEI `862323084068999` |

---

## 5. 数据落库

```mermaid
flowchart LR
  subgraph write [写入]
    Seed[启动种子]
    HTTP[设备首次拉包]
    Admin[管理台]
    MQTT1004[1004 上行]
  end

  subgraph tables [MySQL]
    Proj[ota_projects]
    Dev[devices]
    Fw[firmware_packages]
    Assign[firmware_device_assignments]
    Task[ota_tasks]
  end

  Seed --> Proj
  Seed --> Dev
  Seed --> Fw
  HTTP --> Dev
  Admin --> Proj
  Admin --> Dev
  Admin --> Fw
  Admin --> Assign
  Admin --> Task
  MQTT1004 --> Dev
  MQTT1004 --> Task
```

重启应用容器不丢数据（volume `ota_server_mysql_data`）。已有 IMEI 的真实版本不会被种子覆盖。
