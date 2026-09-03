# 腾讯云视频上传服务：人形报警 / 回放如何落盘

> **现网**：`43.136.55.143`（腾讯云 Ubuntu）  
> **SSH**：`ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143`  
> **排查时间**：2026-08-20 13:10 CST  
> **仓库代码**：`video_upload_server/app.py` · 设备抽片 `ipc_device_ini/app/upload/`  
> **关联**：[CLIP_UPLOAD_CLOSED_LOOP_TEST.md](CLIP_UPLOAD_CLOSED_LOOP_TEST.md) · [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md) · [PERSON_CNT_UART_MQTT_FLOW.md](PERSON_CNT_UART_MQTT_FLOW.md)

结论先说：**人形报警和回放下载走同一套 HTTP 上传**。服务器**不解析 MQTT、不抽片、不区分「报警逻辑」**，只看 POST 里的 `type`：明文 `1` 进 `dynamic/`，`2` 进 `playback/`。MQTT 2013/1013 只在 Cat.1 上跑信令；文件由 T31 自己 POST 到本机 **Python `video-upload`（:7003）**。

---

## 1. 设备侧两条触发，服务器一条接口

```text
人形 IVS 上升沿（30s 冷却）
  → T31 clip_upload 抽 [事件-15s, 事件+15s]
  → POST uploadVideo  type=1（侦测）
  → 服务器写入 incoming/dynamic/

平台 MQTT 2013（任意时间窗，单段 ≤600s）
  → Cat.1 AT+UPLOADVIDEO
  → T31 clip_extract_window 按时间窗抽片
  → POST uploadVideo  type=2（回放）
  → 服务器写入 incoming/playback/
```

| | 人形报警 | 回放下载 |
|--|----------|----------|
| 谁触发 | T31 IVS 本地 | 平台 MQTT **2013** |
| 是否过 MQTT 传文件 | 否 | 否（2013/1013 只信令） |
| HTTP `type` | `1` → 目录 `dynamic` | `2` → 目录 `playback` |
| 设备 URL 优先级 | ① `:7003/admin/api/v1/uploadVideo` ② Nginx `:80` 同路径 ③ 旧机 `112.86.146.218:7003` | 同左 |

Cat.1 人形 `AT+PERSONCNT` **不再**转到 MQTT 后台；报警视频仍由 T31 HTTP 直传 7003。USB 占电脑、无 4G 时抽片会成功、HTTP 会 `Couldn't connect`，与服务器无关。

---

## 2. 这台机器实际在跑什么

登录后看到的是 **两套互不替代的栈**：视频上传在宿主机 systemd；OTA / IPC 升级在 Docker。

```text
公网 43.136.55.143
 ├── :7003  python3 app.py          ← 真机直接 POST（安全组需放行 TCP 7003）
 │            systemd: video-upload.service
 │            落盘 /home/ubuntu/video_upload/incoming/{dynamic,playback}/
 │
 ├── :80 / :443  Docker nginx
 │      ├ /admin/api/v1/  → host.docker.internal:7003   ← 7003 被墙时的备用门
 │      ├ /downloads/     → ipc.tar（IPC 固件，不是录像）
 │      ├ /ipc_upgrade/   → ipc-x86demo（模拟升级）
 │      └ /               → Java ota-server:8080（4G 模组 OTA）
 │
 └── :8008  同一 Nginx，只提供 IPC 升级包下载
```

### 2.1 处理录像的软件（本主题）

| 软件 | 怎么跑 | 作用 |
|------|--------|------|
| **Python 3.10.12** `/home/ubuntu/video_upload/app.py` | systemd `video-upload.service`，`User=ubuntu`，`Restart=always` | 兼容南京后台的 `uploadVideo`：收 multipart、解密 `type`、写 TS + 旁路 json |
| **systemd** `video-upload` | `/etc/systemd/system/video-upload.service` | 开机自启，监听 `0.0.0.0:7003` |
| **Docker Nginx** `nginx:1.25-alpine` | compose `ota_server-nginx-1` | 把 `:80/admin/api/v1/` 反代到宿主机 7003，`client_max_body_size 400m` |

现网进程（2026-08-20）：`pid 2715780`，自 2026-08-17 15:13 起一直 `active`。`ss` 可见 `0.0.0.0:7003` 属该 `python3`。

### 2.2 同机但不管录像的软件

| 容器 / 进程 | 作用 | 和报警/回放视频的关系 |
|-------------|------|------------------------|
| `ota_server-ota-server-1` Java | 4G 模组 OTA、管理台 `admin.html` / `ipc.html` | **不收 TS** |
| `ota_server-mysql-1` | OTA 库 | **不存录像** |
| `ota_server-ipc-x86demo-1` | 模拟 IPC 拉 `ipc.tar` 升级 | **不是**录像上传 |
| MQTT Broker | 在 **南京** `112.86.146.218:2123`，不在本机 | 2013/1013 信令走那边；本机 7003 **没有** 1883/2123 |

本机 **没有** 再跑一套 Java 录像后台。南京 `112.86.146.218:7003` 只是设备失败时的第三备。

---

## 3. 服务器收到 POST 之后做什么

入口：`POST /admin/api/v1/uploadVideo`，`Content-Type: multipart/form-data`。

| 字段 | 含义 |
|------|------|
| `type` | AES-256-ECB + Base64；也可明文 `1`/`2`。已知密文映射在 `app.py` 的 `KNOWN_TYPE_B64` |
| `file` | TS 文件，上限 400MB |

处理步骤（`UploadHandler._handle_upload`）：

1. 校验 `Content-Length`、必须有 `file`。
2. 解密 / 映射 `type` → `1` 或 `2`；解不出则目录叫 `unknown`。
3. 安全化文件名，拼上服务器落盘时间戳：`{原名}-{yyyyMMddHHmmssSSS}.ts`。
4. 写入  
   - type=1 → `/home/ubuntu/video_upload/incoming/dynamic/`  
   - type=2 → `/home/ubuntu/video_upload/incoming/playback/`
5. 同目录写一份 `{文件名}.ts.json` 元数据（origName、type、size、client IP、savedAt）。
6. HTTP 200 JSON（T31 只认 **2xx + 含 `"path"`**）：

```json
{
  "code": 200,
  "msg": "操作成功",
  "data": {
    "realName": "34020000001310989442-20260820-1787158236148-20260820005215714.ts",
    "path": "/apps/video/playback/34020000001310989442-20260820-1787158236148-20260820005215714.ts",
    "size": "15.91MB",
    "type": "2"
  }
}
```

公开路径约定：磁盘 `incoming/{subdir}/file.ts` ↔ URL `/apps/video/{subdir}/file.ts`。

其它接口：

| 方法 | 路径 | 作用 |
|------|------|------|
| GET | `/admin/api/v1/health` 或 `/health` | `{"service":"uploadVideo"}` |
| GET | `/admin/api/v1/videos?limit=200&type=1\|2` | 按 mtime 列文件 |
| GET | `/apps/video/dynamic/*.ts` `/apps/video/playback/*.ts` | 直接下 TS |

**服务不做的事**：转码、切片、鉴权登录、按国标 ID 建库、通知 MQTT、自动删过期文件。就是收文件、分目录、给列表。

Nginx 备用路径：`http://43.136.55.143/admin/api/v1/uploadVideo` → 容器 Nginx → `host.docker.internal:7003`。现网本机探测 `:80` 与 `:7003` 的 health 都是 **200**。大文件必须打 `/admin/api/v1/`（400MB），不要打到 OTA 的 `location /`（全局 32MB）。

---

## 4. 现网落盘快照（2026-08-20 13:10）

| 项 | 值 |
|----|----|
| 根目录 | `/home/ubuntu/video_upload/incoming` 合计 **558MB** |
| `dynamic/`（type=1 人形） | **448** 个 `.ts`，约 **494MB** |
| `playback/`（type=2 回放） | **9** 个 `.ts`，约 **65MB** |
| 磁盘 | `/` 69G 用了 15G（22%） |
| 样机国标 ID | `34020000001310989442`（对应 IMEI `862323084068124`） |

最近真实回放（约 2026-08-20 00:50–00:52，约 16MB 一段，另有 83KB 短片）：

```text
incoming/playback/34020000001310989442-20260820-1787158236148-20260820005215714.ts   15.91MB
```

最近真实人形（约 2026-08-20 00:13–00:44，约 0.8–1.3MB 一段，对应 ±15s 抽片）：

```text
incoming/dynamic/34020000001310989442-20260820-1787157842787-20260820004419097.ts    0.83MB
```

13:03 还有来自 `223.73.185.54` 的 8 字节模拟件（国标号 `...99999`），是联调用的，不是真机。

journal 可见正常保存日志：

```text
saved .../incoming/dynamic/...ts type=1 size=... from=<公网IP>
saved .../incoming/playback/...ts type=2 size=... from=<公网IP>
"POST /admin/api/v1/uploadVideo HTTP/1.1" 200 -
```

---

## 5. 运维

```bash
ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143

sudo systemctl status video-upload
journalctl -u video-upload -f
ls -lt /home/ubuntu/video_upload/incoming/dynamic | head
ls -lt /home/ubuntu/video_upload/incoming/playback | head

curl -sS http://127.0.0.1:7003/admin/api/v1/health
curl -sS 'http://127.0.0.1:7003/admin/api/v1/videos?limit=5&type=1'
curl -sS 'http://127.0.0.1:7003/admin/api/v1/videos?limit=5&type=2'
```

外网：

```text
http://43.136.55.143:7003/admin/api/v1/health
http://43.136.55.143:7003/admin/api/v1/videos?limit=20
http://43.136.55.143/admin/api/v1/health          # Nginx 80 反代
```

重启（会断正在传的 POST）：

```bash
sudo systemctl restart video-upload
```

代码在 `/home/ubuntu/video_upload/`，改 `app.py` 后需 `restart`。仓库同步源是本仓库 `video_upload_server/`。

若直连 **:7003** 超时、**:80** 通：腾讯云安全组未放行 TCP 7003，设备应走备用 URL（固件里已有 `:80` 第二条）。

---

## 6. 和别的文档怎么分工

| 文档 | 写什么 |
|------|--------|
| **本文** | 服务器收到片之后：进程、端口、分目录、现网快照 |
| [PERSON_CNT_UART_MQTT_FLOW.md](PERSON_CNT_UART_MQTT_FLOW.md) | 人形 UART / 不再刷 MQTT；抽片仍 HTTP |
| [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md) | 回放信令 2013→1013，HTTP 是第二步 |
| [CLIP_UPLOAD_CLOSED_LOOP_TEST.md](CLIP_UPLOAD_CLOSED_LOOP_TEST.md) | 设备 TF `.st` 与 7003 列表对照 |
| [video_upload_server/README.md](../video_upload_server/README.md) | 协议字段与部署单元 |
| [http_server/HOW_IT_RUNS.md](../http_server/HOW_IT_RUNS.md) | Python 现网进程与 Java 替换件如何启动 |
| [ota_server/docs/NGINX_OTA_CONF.md](../ota_server/docs/NGINX_OTA_CONF.md) | Nginx 路径分流（含 `/admin/api/v1/` → 7003） |
