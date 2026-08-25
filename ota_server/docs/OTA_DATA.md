# 数据落库与默认台账

项目、设备、固件、任务保存在 MySQL 库 `luat_ota`（Docker volume `ota_server_mysql_data`）。重启或重建应用容器不会丢数据。

---

## 1. 表

| 表 | 管理台 | 谁写入 |
|----|--------|--------|
| `ota_projects` | 我的项目 | 启动种子 / 新建项目 |
| `devices` | 我的设备 | 启动种子 / 添加设备 / 首次 HTTP 拉包自动归属 |
| `firmware_packages` | 固件列表 | 启动种子 / 创建固件 / 闭环准备 |
| `firmware_device_assignments` | 指定设备 | 创建固件时填写 IMEI |
| `ota_tasks` | 我的任务 | MQTT 2004 下发 |
| `logs/ota-audit.jsonl` | 调试日志 | 每次 `/api/site/firmware_upgrade` |

查库：

```bash
cd /home/ubuntu/ota_server
sudo docker compose exec mysql mysql -uluat -pluat123 --default-character-set=utf8mb4 luat_ota \
  -e "SELECT imei,device_name,current_version,firmware_name,ota_enabled FROM devices;"
```

---

## 2. 启动默认数据

`DataInitializer` 在应用启动时写入（**已有 IMEI 不覆盖版本**）：

| IMEI | 版本 | 说明 |
|------|------|------|
| `862323084073637` | `2044.001.001` | 云端同步样机 |
| `862323084068314` | `2034.001.002` | 现场机 |
| `862323084068124` | `2034.001.002` | 文档样机 |
| `862323084068999` | `2044.001.002` | 模拟客户端 |

默认项目：**4G 标准模块**，Key=`ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x`。  
库里还没有固件时，写入一包 `2044.001.001 → 2044.001.010`（升级全部）。

---

## 3. 闭环落库

```
启动 → MySQL 已有项目/设备/固件
  → 管理台设备、固件列表可见
  → 固件升级下发 2004 → ota_tasks
  → GET 拉包 → devices.ota_status=IN_PROGRESS，审计日志
  → 1004 success → devices.current_version 更新，ota_tasks=SUCCESS
```

命令行：`python tools/sim_luat_client.py --mode http`  
管理台：**闭环测试** → **HTTP 闭环**。

真机首次带 `project_key` 拉包，会自动写入 `devices`。
