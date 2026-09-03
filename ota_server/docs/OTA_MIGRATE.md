# 4G OTA 后台移植说明

本文说明：**`luat_ota` 现在放在哪**，以及把整套 OTA 升级后台迁到另一台机器时要搬什么、改什么。

现网：腾讯云 `43.136.55.143`，代码目录 `/home/ubuntu/ota_server`。  
SSH：`ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143`

日常运维见 [../deploy/DEPLOY.md](../deploy/DEPLOY.md)。IPC 文件服务见 [IPC_UPGRADE.md](IPC_UPGRADE.md)。

---

## 1. `luat_ota` 现在放在哪

**不在 Windows 本机，也不在 `application.yml` 写的 `127.0.0.1`。**

生产上库在 **云主机 Docker 里的 MySQL 容器** 中：

| 项 | 实际位置 |
|----|----------|
| 主机 | `43.136.55.143`（`/home/ubuntu/ota_server`） |
| 容器 | `ota_server-mysql-1`（`docker compose` 服务名 `mysql`） |
| 库名 | `luat_ota` |
| 账号 | `luat` / `luat123`（root：`root123`） |
| 对外监听 | **仅本机** `127.0.0.1:3306`（公网打不开 3306） |
| 数据落盘 | Docker 卷 **`ota_server_mysql_data`** → 容器内 `/var/lib/mysql` |

宿主机上看卷：

```bash
sudo docker volume inspect ota_server_mysql_data
# Mountpoint 一般是：
# /var/lib/docker/volumes/ota_server_mysql_data/_data
```

进库：

```bash
cd /home/ubuntu/ota_server
sudo docker compose exec mysql mysql -uluat -pluat123 luat_ota -e "SHOW TABLES;"
```

`application.yml` 里的 `jdbc:mysql://127.0.0.1:3306/luat_ota` 只给 **本机直接跑 JAR** 用。  
Docker 生产被 `docker-compose.yml` 覆盖为：

```text
SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/luat_ota?...
```

这里的主机名 `mysql` 是 Compose 服务名，只在 Docker 内网有效。迁机后只要还用同一份 Compose，**不必改成新机器的公网 IP**。

这个库给 **4G 模组 OTA 管理台**（项目、设备、固件包、升级任务）。  
**IPC 升级不写这个库**（文件在 `ipc_upgrade/files/`，模拟设备在 `ipc_upgrade/slot/`）。

---

## 2. 整套后台由哪些部分组成

迁机不是只拷 SQL。至少这五块要一起走：

```text
浏览器 / 模组 / IPC
        │
        ▼
Nginx :80 / :443 / :8008
        │
        ├─ /admin.html  /ipc.html  /admin/api  /api/site/...
        │         ▼
        │    ota-server（Java）
        │         ├─ MySQL 卷 mysql_data（库 luat_ota）
        │         ├─ ./firmware/     （模组 .bin）
        │         └─ MQTT 112.86.146.218:2123（现网 Broker，一般不搬）
        │
        └─ /downloads  + /ipc_upgrade
                  ▼
             ipc_upgrade/files/   ipc_upgrade/slot/
```

| 必须带走 | 路径（现网） | 不带走会怎样 |
|----------|--------------|--------------|
| 数据库 | Docker 卷 `ota_server_mysql_data`（库 `luat_ota`） | 管理台项目/设备/任务全空 |
| 模组固件文件 | `/home/ubuntu/ota_server/firmware/` | 设备能查到版本但拉不到 `.bin` |
| IPC 包 | `/home/ubuntu/ota_server/ipc_upgrade/files/` | `:8008/downloads/ipc.tar` 没有 |
| 代码与 Compose | `/home/ubuntu/ota_server` | 服务起不来 |
| 公网地址相关配置 | `docker-compose.yml` 里若干 URL | 设备仍去打旧 IP，升不了级 |

可选：`deploy/nginx/certs/`（自签 HTTPS）、`logs/`、`ipc_upgrade/slot/`（仅 x86demo 当前版本）。

MQTT Broker（`112.86.146.218:2123`）是现网共用的，**默认不搬**。新机器要能访问该地址。若 Broker 也换，再改 Compose 里的 `LUAT_MQTT_*`。

---

## 3. 迁到新机器：推荐步骤

下面假设新机也是 Ubuntu + Docker Compose，新公网 IP 记为 `NEW_IP`（或域名）。

### 3.1 在旧机导出数据库

```bash
ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143
cd /home/ubuntu/ota_server

sudo docker compose exec -T mysql \
  mysqldump -uroot -proot123 --databases luat_ota --single-transaction --routines --triggers \
  > /tmp/luat_ota.sql

ls -lh /tmp/luat_ota.sql
```

本机再拉回来：

```powershell
scp -i $env:USERPROFILE\.ssh\id_ed25519 `
  ubuntu@43.136.55.143:/tmp/luat_ota.sql `
  $env:TEMP\luat_ota.sql
```

### 3.2 拷固件和 IPC 文件

```powershell
scp -i $env:USERPROFILE\.ssh\id_ed25519 -r `
  ubuntu@43.136.55.143:/home/ubuntu/ota_server/firmware `
  ubuntu@43.136.55.143:/home/ubuntu/ota_server/ipc_upgrade `
  $env:TEMP\ota_data\
```

证书若要用 HTTPS，一并拷 `deploy/nginx/certs/`。

### 3.3 在新机放代码并改公网地址

把仓库放到新机（例如 `/home/ubuntu/ota_server`），把 `firmware/`、`ipc_upgrade/` 覆盖进去。

**必须改** `docker-compose.yml` 里所有旧 IP `43.136.55.143`：

| 变量 | 改成 |
|------|------|
| `LUAT_MQTT_OTA_PUBLIC_BASE_URL` | `http://NEW_IP`（模组 libfota2 拉包基址） |
| `LUAT_OTA_IPC_PUBLIC_DOWNLOAD_BASE` | `http://NEW_IP:8008` |
| `ipc-x86demo` 的 `PUBLIC_BASE` | `http://NEW_IP` |
| `ipc-x86demo` 的 `PUBLIC_DOWNLOAD_BASE` | `http://NEW_IP:8008` |

不必改：

- `SPRING_DATASOURCE_URL` 里的主机名 `mysql`（仍是容器名）
- MySQL 库名 `luat_ota`、账号密码（除非你主动改）

`application.yml` 里的 `127.0.0.1` **不用改**，Docker 不会用它。

Nginx：`deploy/nginx/ota.conf` 当前是 `server_name _`，换 IP 一般不用动。若改成域名，把 `server_name` 换成域名并换证书。

### 3.4 新机启动，再导入库

```bash
cd /home/ubuntu/ota_server
sudo docker compose up -d --build
# 等 mysql healthy、ota-server 起来

# 把 dump 拷到新机后导入（会覆盖同名库）
sudo docker compose exec -T mysql mysql -uroot -proot123 < /tmp/luat_ota.sql
sudo docker compose restart ota-server
```

若新机是空库、只想初始化空表，不必导入 dump：首次启动会跑 `deploy/sql/schema.sql`，管理台是空的，可重新建项目、上传固件。

### 3.5 云安全组 / 防火墙

新机至少放行：

| 端口 | 谁用 |
|------|------|
| TCP 80 | 管理台、模组拉包 |
| TCP 8008 | IPC `ipc.tar` 下载（真机 FileUrl） |
| TCP 22 | SSH |
| TCP 443 | 可选，浏览器 HTTPS |

**不要**把 `3306` 放到公网。Compose 已绑 `127.0.0.1:3306`。

### 3.6 设备侧要改什么

- **Cat.1 模组**：OTA 拉包 URL 来自 MQTT 2004 里下发的地址。新后台只要 `LUAT_MQTT_OTA_PUBLIC_BASE_URL` 已改，**之后新下发的升级**会指向新机。已经写死旧 IP 的固件脚本要改脚本或重新下发。
- **IPC 真机**：`ipc.json` 的 `url` 必须是 `http://NEW_IP:8008/downloads/ipc.tar`。在新机网页重新上传一次即可生成。
- **管理台 Token**：默认可沿用 `ota-7f3a9c2e4b18d6a0e5c1`，建议迁机后改 `LUAT_OTA_ADMIN_TOKEN` 并同步改 `admin.html` / `ipc.html` 预填值。

---

## 4. 验收清单

在新机上：

```bash
curl -sS http://NEW_IP/health
# 期望: ok

curl -sS -o /dev/null -w "%{http_code}\n" http://NEW_IP/admin.html
curl -sS -o /dev/null -w "%{http_code}\n" http://NEW_IP/ipc.html

curl -sS -H "X-Admin-Token: ota-7f3a9c2e4b18d6a0e5c1" \
  http://NEW_IP/admin/api/projects

curl -sS -H "X-Admin-Token: ota-7f3a9c2e4b18d6a0e5c1" \
  http://NEW_IP/admin/api/ipc/status
```

浏览器打开：

- http://NEW_IP/admin.html 能登录，项目/设备还在（若已导库）
- http://NEW_IP/ipc.html 能登录，上传后 http://NEW_IP:8008/downloads/ipc.tar 为 200

模组：管理台对一台测试设备下发升级，确认 2004 里的 URL 已是 `http://NEW_IP/...`，设备能拉到包。

---

## 5. 只迁网站、不迁数据

推荐直接用仓库里的空站包：

`e:\CAT1\AIR780EHM\ota_server\ota_cat1_ipc`

说明见该目录 [README.md](../ota_cat1_ipc/README.md)。四份 SQL 已合成 `schema.sql`，不含设备/任务/固件记录。

```powershell
cd e:\CAT1\AIR780EHM\ota_server\ota_cat1_ipc
.\deploy.ps1 -PublicHost 新公网IP -SshTarget ubuntu@新公网IP
```

新环境从零开始时：

1. 拷代码，改第 3.3 节里的公网 URL  
2. `docker compose up -d --build`（空 `luat_ota` + `schema.sql`）  
3. 打开管理台建项目、上传模组固件  
4. IPC 在 `/ipc.html` 重新上传  

旧机上的设备台账、历史任务不会出现在新机。

---

## 6. 常见误区

| 误区 | 实际 |
|------|------|
| 改 `application.yml` 的 `127.0.0.1` 为新 IP | Docker 生产看的是 Compose 的 `SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/luat_ota` |
| 只拷 Java / HTML，不导库、不拷 `firmware/` | 管理台空，或有记录但下载 404 |
| 库迁了但没改 `LUAT_MQTT_OTA_PUBLIC_BASE_URL` | 后台在新机，设备仍去旧 IP 拉包 |
| 把 3306 映射到 `0.0.0.0` | 数据库暴露公网，不要这样做 |
| 以为 IPC 也在 `luat_ota` 里 | IPC 只在磁盘文件目录 |

---

## 7. 现网速查

| 项 | 值 |
|----|----|
| 库 | `luat_ota` @ Docker 卷 `ota_server_mysql_data` |
| 查库 | `sudo docker compose exec mysql mysql -uluat -pluat123 luat_ota` |
| 管理台 | http://43.136.55.143/admin.html |
| IPC 后台 | http://43.136.55.143/ipc.html |
| 模组拉包 | http://43.136.55.143/api/site/firmware_upgrade? |
| IPC 拉包 | http://43.136.55.143:8008/downloads/ipc.tar |
