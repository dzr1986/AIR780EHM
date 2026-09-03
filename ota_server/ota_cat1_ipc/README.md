# 空站迁移包（ota_cat1_ipc）

把 **4G OTA + IPC 网站** 装到新机器用。  
**带数据库表结构，不带现网升级数据**（没有旧设备、任务、固件包、ipc.tar）。

## 目录

| 路径 | 作用 |
|------|------|
| `sql/schema.sql` | 四份 SQL 合成后的空库（与 `deploy/sql/schema.sql` 相同） |
| `docker-compose.yml` | 空库模板，`LUAT_OTA_SEED_DEMO_DATA=false` |
| `pack.ps1` | 从上级 `ota_server` 生成 `site/`（不含 .bin / ipc.tar / 日志） |
| `deploy.ps1` | Windows：打包，可选 scp 到新机并启动 |
| `deploy.sh` | Linux 新机：写 `.env`、自签证书、`docker compose up` |
| `site/` | 运行 `pack.ps1` 后生成的可部署目录 |

`schema.sql` 已合并：`schema.sql` + `migration_v2.sql` + `migration_v3.sql` + `fix_utf8.sql`。只插入默认项目「4G 标准模块」，没有 IMEI、没有任务。

## 本机先打包

```powershell
cd e:\CAT1\AIR780EHM\ota_server\ota_cat1_ipc
.\pack.ps1
```

## 部署到新机器

新机需：Docker、Docker Compose、开放 **TCP 80、8008**（443 可选）。

```powershell
cd e:\CAT1\AIR780EHM\ota_server\ota_cat1_ipc
.\deploy.ps1 -PublicHost 新公网IP -SshTarget ubuntu@新公网IP
```

只打包、自己拷：

```powershell
.\deploy.ps1 -PublicHost 新公网IP
# 然后把整个 ota_cat1_ipc 拷到新机
# ssh 后：
#   cd /home/ubuntu/ota_cat1_ipc/site
#   chmod +x deploy.sh
#   ./deploy.sh 新公网IP
```

打开：

- http://新IP/admin.html
- http://新IP/ipc.html  
Token 默认 `ota-7f3a9c2e4b18d6a0e5c1`（见 `site/.env`）。

新环境是空库：自己建设备、上传模组固件、在 IPC 页上传 `ipc.tar`。真机首次拉包会自动写入 `devices`。

## 不会拷走的东西

- 现网 MySQL 里的设备 / 任务 / 固件记录
- `firmware/*.bin`
- `ipc_upgrade/files/ipc.tar`
- 审计日志

## 和现网的关系

现网 `43.136.55.143` 不受影响。本目录是一份干净副本。若新机仍用同一 MQTT Broker，`.env` 里 `MQTT_*` 可保持现网值。
