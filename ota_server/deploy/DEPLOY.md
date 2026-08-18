# ota_server 生产部署说明

本文记录 **780EHM_PJ 自建 OTA 服务** 在腾讯云主机上的实际部署结果，以及日常运维方式。

协议与功能说明见上级 [README.md](../README.md)。

---

## 1. 部署信息

| 项 | 值 |
|----|----|
| 主机 | `43.136.55.143`（腾讯云 Ubuntu 22.04） |
| SSH | `ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143` |
| 代码目录 | `/home/ubuntu/ota_server` |
| 部署方式 | Docker Compose（MySQL + ota-server + Nginx） |
| 部署日期 | 2026-08-17 |

---

## 2. 访问地址

| 用途 | 地址 |
|------|------|
| 健康检查 | http://43.136.55.143/health （期望返回 `ok`） |
| Web 管理台 | http://43.136.55.143/admin.html |
| 设备拉包（libfota2） | `http://43.136.55.143/api/site/firmware_upgrade?` |
| 兼容路径 | http://43.136.55.143/luat/update |

管理台鉴权 Header：`X-Admin-Token`

当前 Token：

```
ota-7f3a9c2e4b18d6a0e5c1
```

管理台打开后自动填入 Token 并登录。MQTT 应显示「已连接」。

顶栏：**我的项目 / 我的设备 / 固件升级 / 我的任务 / 调试日志 / 闭环测试**。

| 按钮 | 行为 |
|------|------|
| 详情 | 查看 Key、设备数、固件数 |
| 编辑 | 改名称/描述/隐藏 |
| 设备列表 | IMEI、版本、固件名、允许升级 |
| 固件列表 | 版本、下载、允许升级、升级全部 |

操作说明见 [OTA_ADMIN.md](../docs/OTA_ADMIN.md)。

> 本机 **80 已对公网开放**。443 已在容器内监听（自签证书），但云安全组可能未放行，外网 HTTPS 会超时。设备走 HTTP，不影响升级。若要用 `https://43.136.55.143`，请在腾讯云安全组放行 **TCP 443**。

---

## 3. 架构

```
浏览器 / 设备
    │  HTTP :80  （公网）
    ▼
Nginx 容器
    │  HTTP :8080（Docker 内网）
    ▼
ota-server（Spring Boot）
    ├── MySQL 8.0（仅 127.0.0.1:3306）
    └── MQTT Broker  112.86.146.218:2123
```

| 容器 | 说明 | 对外端口 |
|------|------|----------|
| `ota_server-nginx-1` | 反向代理 | 80、443 |
| `ota_server-ota-server-1` | OTA 应用 | 无（仅内网 8080） |
| `ota_server-mysql-1` | 数据库 `luat_ota` | `127.0.0.1:3306` |

MQTT 下发 **不经过 Nginx**：ota-server 直连 Broker，向 `/panshi/device/{IMEI}/` 发布 `2004 action=ota`。

系统流程图见 [OTA_SYSTEM_FLOW.md](../docs/OTA_SYSTEM_FLOW.md)。

---

## 4. 关键配置

文件：`/home/ubuntu/ota_server/docker-compose.yml`

| 环境变量 | 当前值 | 说明 |
|----------|--------|------|
| `LUAT_OTA_ADMIN_TOKEN` | `ota-7f3a9c2e4b18d6a0e5c1` | 管理台 / 管理 API |
| `LUAT_OTA_LATEST_VERSION` | `2034.001.003` | 兜底目标版本 |
| `LUAT_MQTT_ENABLED` | `true` | 启用 MQTT 桥接 |
| `LUAT_MQTT_HOST` / `PORT` | `112.86.146.218` / `2123` | panshi Broker |
| `LUAT_MQTT_USERNAME` | `fptop1` | MQTT 账号 |
| `LUAT_MQTT_OTA_PUBLIC_BASE_URL` | `http://43.136.55.143` | 下发给设备的拉包基址 |

MySQL：

| 项 | 值 |
|----|----|
| 库名 | `luat_ota` |
| 用户 | `luat` / `luat123` |
| root | `root123` |
| 监听 | 仅本机 `127.0.0.1:3306` |

Nginx：`deploy/nginx/ota.conf`，`server_name _`，80 直接反代（不强制跳 HTTPS）。

证书（自签，仅 443）：

```
/home/ubuntu/ota_server/deploy/nginx/certs/fullchain.pem
/home/ubuntu/ota_server/deploy/nginx/certs/privkey.pem
```

---

## 5. 日常运维

SSH 登录后：

```bash
cd /home/ubuntu/ota_server
```

### 查看状态

```bash
sudo docker compose ps
sudo docker compose logs -f ota-server
sudo docker compose logs -f nginx
```

### 启停

```bash
sudo docker compose stop
sudo docker compose start
sudo docker compose restart ota-server
```

### 健康检查

```bash
curl -sS http://127.0.0.1/health
# 期望: ok

curl -sS -H "X-Admin-Token: ota-7f3a9c2e4b18d6a0e5c1" \
  http://127.0.0.1/admin/api/mqtt/status
```

### 查库

```bash
sudo docker compose exec mysql mysql -uluat -pluat123 luat_ota \
  -e "SELECT imei,current_version,target_version,ota_status FROM devices;"

sudo docker compose exec mysql mysql -uluat -pluat123 luat_ota \
  -e "SELECT imei,status,last_stage,target_version FROM ota_tasks ORDER BY id DESC LIMIT 10;"
```

审计日志：`/home/ubuntu/ota_server/logs/ota-audit.jsonl`

---

## 6. 更新代码并重新发布

本机（Windows PowerShell）打包上传后，在服务器重建：

```powershell
# 本机：打包（排除 git / 构建产物）
tar -czf $env:TEMP\ota_server.tar.gz `
  --exclude=.git --exclude=.specstory --exclude=target --exclude=logs --exclude=.idea `
  -C e:\CAT1\AIR780EHM ota_server

scp -i $env:USERPROFILE\.ssh\id_ed25519 `
  $env:TEMP\ota_server.tar.gz ubuntu@43.136.55.143:/tmp/
```

```bash
# 服务器
cd /home/ubuntu
# 保留证书、已上传固件、MySQL 数据卷
tar -xzf /tmp/ota_server.tar.gz
# 若覆盖了 certs，需重新生成或从备份拷回
cd /home/ubuntu/ota_server
sudo docker compose up -d --build
```

只改配置、不改 Java 代码时：

```bash
cd /home/ubuntu/ota_server
sudo docker compose up -d
# 仅改 Nginx：
sudo docker compose restart nginx
```

> MySQL 数据在 Docker volume `ota_server_mysql_data` 中，重建容器不会丢库。`firmware/` 是宿主机目录挂载，上传的差分包会保留。

---

## 7. 上传差分包并触发升级

首次部署时 `firmware/` 只有 `manifest.json`，**还没有 `.bin`**。设备拉包会 404，直到上传对应源版本的差分包。

### 管理台

1. 打开 http://43.136.55.143/admin.html
2. 填入 Admin Token，点 **登录 / 刷新**
3. **我的项目** → 目标项目行 **固件列表** → **创建固件**（选 `.bin` 会自动识别固件名/版本）
4. **固件升级**：填 IMEI + 目标版本，下发 MQTT 2004
5. **我的任务**：看创建人、开始/结束、状态、错误信息（可按 IMEI / 状态筛选、翻页）
6. **调试日志**：看设备 HTTP 拉包决策（升级 / 无需 / 25/26/27）

### API

```bash
# 触发指定设备
curl -X POST "http://43.136.55.143/admin/api/ota/trigger" \
  -H "X-Admin-Token: ota-7f3a9c2e4b18d6a0e5c1" \
  -H "Content-Type: application/json" \
  -d '{"imeis":["862323084068124"],"targetVersion":"2034.001.003"}'
```

版本号必须用 **IoT 格式**（如 `2034.001.002`），且差分包 `sourceVersion` 必须与设备当前版本完全一致。

---

## 8. 从零复现（新机器）

1. 安装 Docker（Ubuntu 仓库即可，国内官方 get.docker.com 可能被重置）：

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
```

2. 可选：配置镜像加速 `/etc/docker/daemon.json`（腾讯云内网）：

```json
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.m.daocloud.io"
  ]
}
```

```bash
sudo systemctl restart docker
```

3. 上传本仓库到 `/home/ubuntu/ota_server`。

4. 生成自签证书（无正式域名时）：

```bash
mkdir -p deploy/nginx/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout deploy/nginx/certs/privkey.pem \
  -out deploy/nginx/certs/fullchain.pem \
  -subj "/CN=43.136.55.143"
```

5. 确认 `docker-compose.yml` 中 `LUAT_MQTT_OTA_PUBLIC_BASE_URL` 为本机公网地址。

6. 启动：

```bash
cd /home/ubuntu/ota_server
sudo docker compose up -d --build
```

Dockerfile 为多阶段构建（Maven 编译 + JRE 运行），服务器上不需要预装 JDK / Maven。依赖走阿里云 Maven 镜像：`deploy/maven-settings.xml`。

---

## 9. 故障排查

| 现象 | 处理 |
|------|------|
| `/health` 不通 | `sudo docker compose ps`，看 nginx / ota-server 是否 Up；云安全组是否放行 80 |
| 管理台 401 | Token 与 `LUAT_OTA_ADMIN_TOKEN` 不一致 |
| MQTT `connected: false` | 看 `docker compose logs ota-server`；确认 Broker `112.86.146.218:2123` 可达 |
| 设备收不到 2004 | IMEI 是否 15 位；设备是否在线；管理台 MQTT 是否已连接 |
| 设备下载 404 | 未上传匹配 `sourceVersion` 的差分包 |
| 设备下载超时 | 确认公网 80 通；`LUAT_MQTT_OTA_PUBLIC_BASE_URL` 必须是设备能访问的地址 |
| 外网 HTTPS 超时 | 腾讯云安全组放行 TCP 443 |
| 编译失败 `FirmwareDeviceAssignment` | 已在 `FirmwareRegistryService` 补 import，重新 `docker compose up -d --build` |

---

## 10. 安全注意

- 当前 MySQL、Admin Token、MQTT 密码写在 `docker-compose.yml` 中，仅内网/运维可见，请勿把该文件发到公开仓库。
- MySQL 已绑定 `127.0.0.1`，外网不能直连 3306。
- 生产若绑定域名，建议换成正式证书，并把 `LUAT_MQTT_OTA_PUBLIC_BASE_URL` 改为 `https://你的域名`，同时在 Nginx 中改 `server_name`。
- 定期更换 `LUAT_OTA_ADMIN_TOKEN` 后执行 `sudo docker compose up -d` 即可生效。更换后需在管理台重新登录。

---

## 11. 数据存在 MySQL，启动会默认加载

项目、设备、固件、任务都在库 `luat_ota`（volume `ota_server_mysql_data`），不是只活在内存。启动时 `DataInitializer` 写入默认项目「4G 标准模块」和样机 IMEI（已有记录不覆盖版本）。详见 [OTA_DATA.md](../docs/OTA_DATA.md)。

打开管理台 → **我的设备**，应能看到 `862323084073637`、`862323084068314`、`862323084068124` 等。

---

## 12. 闭环测试

不插真机即可验证升级全流程。说明与实测记录见 [OTA_CLOSED_LOOP.md](../docs/OTA_CLOSED_LOOP.md)。

管理台：**闭环测试** → **HTTP 闭环**。

命令行：

```bash
python tools/sim_luat_client.py --mode http --base http://43.136.55.143
```

默认模拟 IMEI `862323084068999`。成功时设备当前版本变为 `2044.001.010`，任务为 SUCCESS。

2026-08-17 实测：HTTP 闭环 **PASS**，MQTT 闭环 **PASS**，已最新再拉包返回 404。

---

## 13. 我的任务

页面：http://43.136.55.143/admin.html → **我的任务**

| 列 | 字段 |
|----|------|
| 创建人 | `triggerSource`：管理员 / 批量任务 |
| 创建时间 | `createdAt` |
| 开始 / 结束 | 开始=`createdAt`，结束=`completedAt` |
| 状态 | 待下发 / 已下发 / 设备已受理 / 进行中 / 成功 / 失败 / 超时 |
| 备注 | 目标版本 + 最近 `stage` / `message` |
| 错误信息 | `errorMessage` |
| 翻页 | `page` / `size=20`，接口 `GET /admin/api/ota/tasks` |
