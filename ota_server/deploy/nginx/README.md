# Nginx HTTPS 部署说明

本文说明如何为 OTA 服务器配置 **HTTPS 公网入口**。完整背景见上级 [README.md](../README.md)。

---

## 为什么需要 Nginx

| 问题 | 说明 |
|------|------|
| 模块需要公网 URL | Air780 通过蜂窝网拉差分包，服务器必须有公网地址 |
| 合宙 libfota2 默认 HTTP | 模块侧原生 HTTP GET；生产环境用 Nginx 终结 TLS |
| 统一入口 | 一个域名同时服务 OTA 下载、管理台、管理 API |

数据流：

```
模块  ──HTTPS GET──►  Nginx :443  ──HTTP──►  ota-server :8080
```

MQTT 下发给设备的 `url` 字段必须是 Nginx 对外的 **HTTPS 基址**。

---

## 1. 准备证书

将证书放到：

```
deploy/nginx/certs/
├── fullchain.pem    # 完整证书链
└── privkey.pem      # 私钥
```

### 生产环境

- 云厂商 SSL 证书（阿里云、腾讯云等）
- 或 Let's Encrypt（需域名解析到本机）

### 测试环境（自签，模块可能不信任，仅适合 curl 验证）

在 `ota_server` 目录执行：

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout deploy/nginx/certs/privkey.pem \
  -out deploy/nginx/certs/fullchain.pem \
  -subj "/CN=ota.yourcompany.com"
```

将 `ota.yourcompany.com` 换成你的域名。

---

## 2. 修改 Nginx 配置

编辑 `deploy/nginx/ota.conf`，将所有 `ota.example.com` 替换为你的域名：

```nginx
server_name ota.yourcompany.com;
```

主要配置说明：

| 配置 | 值 | 说明 |
|------|-----|------|
| `listen 443 ssl` | HTTPS 入口 | 对外服务端口 |
| `listen 80` | HTTP | 自动 301 跳转到 HTTPS |
| `client_max_body_size 32m` | 上传限制 | 管理台上传差分包最大 32MB |
| `proxy_pass http://ota-server:8080` | 后端 | Docker 网络内 Spring Boot |

---

## 3. 与 OTA 服务联动（必做）

在 `docker-compose.yml` 的 `ota-server` 环境变量中设置：

```yaml
LUAT_MQTT_OTA_PUBLIC_BASE_URL: "https://ota.yourcompany.com"
```

**必须与 Nginx 对外 HTTPS 地址完全一致**（含 `https://`，不含末尾 `/`）。

服务器拼出的 MQTT 下发 URL 示例：

```
https://ota.yourcompany.com/api/site/firmware_upgrade?
```

设备 libfota2 会在此 URL 后自动追加 `imei=...&version=...` 等参数。

---

## 4. 启动

全栈启动（推荐）：

```bash
cd ota_server
mvn -DskipTests package
docker compose up -d --build
```

仅重启 Nginx（改配置后）：

```bash
docker compose restart nginx
```

---

## 5. 验证

```bash
# 健康检查
curl -k https://ota.yourcompany.com/health
# 期望: ok

# 模拟设备 OTA 请求（源版本低于 manifest 目标版本时应 200）
curl -k -I "https://ota.yourcompany.com/luat/update?imei=862323084068124&firmware_name=PANSHI_CAT1_LuatOS-SoC_Air780EHM&version=2034.001.002"

# 管理台
# 浏览器打开 https://ota.yourcompany.com/admin.html
```

---

## 6. 常见问题

### Nginx 启动失败：证书找不到

确认 `deploy/nginx/certs/` 下存在 `fullchain.pem` 和 `privkey.pem`，且 docker-compose 已挂载该目录。

### 模块下载超时

1. 域名是否解析到服务器公网 IP
2. 防火墙是否放行 443
3. `LUAT_MQTT_OTA_PUBLIC_BASE_URL` 是否与浏览器访问地址一致

### 只用 IP 不用域名

可将 `server_name` 改为 `_` 或你的 IP，证书 CN 也需匹配。生产仍建议使用域名 + 正式证书。

---

## 7. 与 MQTT 的关系

Nginx 只负责 **HTTP OTA 下载** 通道。MQTT 触发由 `ota-server` 直连 Broker，不经过 Nginx：

| 通道 | 经过 Nginx | 说明 |
|------|------------|------|
| MQTT 2004 下发 | 否 | ota-server → Broker → 设备 |
| HTTP 差分包下载 | 是 | 设备 → Nginx → ota-server |
| 管理台 / 管理 API | 是 | 浏览器 → Nginx → ota-server |
