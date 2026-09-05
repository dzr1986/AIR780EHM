# Nginx `ota.conf` 解析

文件位置：`deploy/nginx/ota.conf`  
容器内挂载为：`/etc/nginx/conf.d/default.conf`  
现网入口：`http://43.136.55.143`（80）、`https://43.136.55.143`（443，自签）、`http://43.136.55.143:8008`（IPC 下载）

这份配置是整站的**唯一公网入口**：浏览器、Cat.1 模组、IPC 都先打到 Nginx，再按路径分到不同后端。MQTT 下发**不经过** Nginx。

---

## 1. 它在整条链里干什么

```text
公网
  :80 / :443
       ├─ /downloads/          → 磁盘 ipc_upgrade/files（IPC 包）
       ├─ /ipc_upgrade/        → ipc-x86demo:8010
       ├─ /admin/api/v1/       → 宿主机 :7003（报警视频，与 OTA 无关）
       └─ /                    → ota-server:8080
                                 （admin.html、ipc.html、/admin/api、模组拉包）

  :8008
       └─ /downloads/          → 同一份 ipc_upgrade/files
                                 （真机 ipc.json.url 用这个口）
```

Compose 里 Nginx 挂了三个目录：

| 宿主机 | 容器内 | 用途 |
|--------|--------|------|
| `deploy/nginx/ota.conf` | `/etc/nginx/conf.d/default.conf` | 本配置 |
| `deploy/nginx/certs/` | `/etc/nginx/certs/` | 443 证书 |
| `ipc_upgrade/files/` | `/var/www/fileserver/`（只读） | IPC `ipc.tar` / `ipc.json` |

改配置后：`sudo docker compose restart nginx`（或 `nginx -s reload`）。

---

## 2. 三个 `server` 块

配置里有 **3 个独立 server**，监听不同端口。80 和 443 的 `location` 内容相同，只是协议不同。

### 2.1 `listen 80` — 主入口（现网真正在用）

```nginx
server {
    listen 80;
    server_name _;
    client_max_body_size 32m;
    ...
}
```

| 指令 | 含义 |
|------|------|
| `listen 80` | 对外 HTTP。模组 libfota2、管理台默认都走这里 |
| `server_name _` | 不绑域名，任意 Host（含 IP `43.136.55.143`）都接 |
| `client_max_body_size 32m` | 默认上传上限 32MB（管理台传模组 `.bin`） |

现网 **没有** 把 80 跳转到 443。设备走 HTTP，这样最省事。

### 2.2 `listen 443 ssl http2` — 浏览器 HTTPS（可选）

```nginx
ssl_certificate     /etc/nginx/certs/fullchain.pem;
ssl_certificate_key /etc/nginx/certs/privkey.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
```

自签证书，浏览器会告警。安全组若未放行 443，外网 HTTPS 会超时，**不影响** 80 上的升级。

`listen ... http2` 在较新 Nginx 上会有弃用告警，可改成 `listen 443 ssl;` 再单独写 `http2 on;`，功能不变。

### 2.3 `listen 8008` — IPC 专用下载口

对齐真机 `pack_tool` / `ipc.json`：

```text
http://43.136.55.143:8008/downloads/ipc.tar
```

这个 server **只有** `/downloads/`，没有管理台、没有 Java 反代。真机只拉文件，不碰后台。

腾讯云安全组需要放行 **TCP 8008**，否则外网拉 tar 失败。

---

## 3. 路径怎么分流（80 / 443 相同）

Nginx 按 **最长前缀** 匹配 `location`，先写的专用路径优先于最后的 `location /`。

### 3.1 `/downloads/` → 本地文件，不进 Java

```nginx
location /downloads/ {
    alias /var/www/fileserver/;
    autoindex on;
    ...
}
```

| 指令 | 含义 |
|------|------|
| `alias /var/www/fileserver/` | URL `/downloads/ipc.tar` → 磁盘 `/var/www/fileserver/ipc.tar` |
| `autoindex on` | 浏览器打开 `/downloads/` 能看到文件列表 |
| `autoindex_exact_size off` | 大小显示成 KB/MB |
| `autoindex_localtime on` | 修改时间用本地时区 |
| `sendfile` / `tcp_nopush` / `tcp_nodelay` | 大文件下载性能 |

**`alias` 和 `root` 的差别：** 这里必须用 `alias`。若写成 `root /var/www/fileserver;`，会去找 `/var/www/fileserver/downloads/ipc.tar`（多一层 `downloads`），会 404。

谁往这个目录写文件：Java `POST /admin/api/ipc/upload` 和 Python x86demo 上传；Nginx 只读。

### 3.2 `/ipc_upgrade/` → x86demo

```nginx
location /ipc_upgrade/ {
    client_max_body_size 64m;
    proxy_pass http://ipc-x86demo:8010/ipc_upgrade/;
    proxy_read_timeout 180s;
    proxy_request_buffering off;
}
```

`ipc-x86demo` 是 Compose 服务名，Docker 内网解析到模拟 IPC（端口 8010）。

网页 `ipc.html` 的登录接口走的是 **`/admin/api/ipc`**（进 Java），**不是** 这条。  
这条给：健康检查 `/ipc_upgrade/health`、以及不经过 Java 直接打 x86demo 的旧 GUI。

`proxy_request_buffering off`：上传大包时不先在 Nginx 里攒完再转发。

### 3.3 `/admin/api/v1/` → 宿主机 7003（报警视频）

```nginx
location /admin/api/v1/ {
    client_max_body_size 400m;
    proxy_pass http://host.docker.internal:7003;
}
```

**不是** 4G OTA 的 `/admin/api`。OTA 管理 API 是 `/admin/api/projects` 这类，走下面的 `location /` 进 Java。

`host.docker.internal` 在 Compose 里映射成宿主机网关，用来打本机另一个进程（报警 `uploadVideo`，最大 400MB）。没有 7003 服务时，打这条路径会失败，**不影响** OTA / IPC。

### 3.4 `location /` → Java `ota-server:8080`

剩下所有请求都进 Spring Boot，包括：

| URL | 用途 |
|-----|------|
| `/admin.html` | 4G 模组管理台 |
| `/ipc.html` | IPC 升级网页 |
| `/admin/api/**` | 管理 API（要 `X-Admin-Token`） |
| `/health` | 健康检查 |
| `/api/site/firmware_upgrade?` | 模组 libfota2 拉包 |
| `/firmware/*.bin` | 模组固件直链 |

超时 600 秒：拉大差分包、管理台操作可以比较慢。

---

## 4. 一张表对照现网 URL

| 你访问的地址 | Nginx 哪一段 | 真正落到哪 |
|--------------|--------------|------------|
| http://43.136.55.143/admin.html | `location /` :80 | ota-server 静态页 |
| http://43.136.55.143/ipc.html | `location /` :80 | ota-server 静态页 |
| http://43.136.55.143/admin/api/ipc/status | `location /` :80 | Java `IpcAdminController` |
| http://43.136.55.143/api/site/firmware_upgrade? | `location /` :80 | Java 模组 OTA |
| http://43.136.55.143/downloads/ipc.tar | `/downloads/` :80 | 磁盘 files |
| http://43.136.55.143:8008/downloads/ipc.tar | `/downloads/` :8008 | **同一份** 磁盘 files |
| http://43.136.55.143/ipc_upgrade/health | `/ipc_upgrade/` | Python x86demo |
| http://43.136.55.143/admin/api/v1/... | `/admin/api/v1/` | 宿主机 :7003 |

`:80/downloads/` 和 `:8008/downloads/` 是同一目录的两个门。真机 FileUrl 用 **8008**，和 `pack_tool` 一致。

---

## 5. 和 MQTT 的关系

| 通道 | 过 Nginx？ |
|------|------------|
| 浏览器打开管理台 | 是（80/443） |
| 模组 HTTP 拉 `.bin` | 是（80） |
| IPC 拉 `ipc.tar` | 是（8008，或 80 的 `/downloads/`） |
| MQTT 2004 下发升级命令 | **否**，ota-server 直连 `112.86.146.218:2123` |

2004 消息里的拉包 URL，来自 Compose 的 `LUAT_MQTT_OTA_PUBLIC_BASE_URL=http://43.136.55.143`，必须和 Nginx 80 对得上。

---

## 6. 改配置时注意

1. **不要**随便把 `location /` 写到 `/downloads/` 前面还用正则抢匹配；当前前缀匹配已经正确。  
2. 改 `alias` 末尾斜杠要成对：`location /downloads/` 对应 `alias .../fileserver/`。  
3. 只改 conf：`sudo docker compose restart nginx`。不必重建 Java。  
4. 现网安全组：80 必开；8008 给 IPC；443 可选。**不要**对公网开放 3306、8080。

证书与 HTTPS 操作细节仍见 [../deploy/nginx/README.md](../deploy/nginx/README.md)（其中「80 强制跳 443」与**当前** `ota.conf` 不一致：现网 80 直接提供服务）。
