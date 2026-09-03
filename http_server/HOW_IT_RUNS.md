# http_server 是如何运行的

本目录有两套实现，**协议相同**，端口都是 **7003**，不能同时听：

| | [python_project](python_project/) | [java_project](java_project/) |
|--|-------------------------------|-----------------------------|
| 现网状态 | 2026-08-20 正在跑（见 `RUNTIME.txt`） | 仓库新增，用来替换 Python |
| 进程 | `python3 app.py` | `java -jar video-upload.jar` |
| systemd | `python_project/systemd/video-upload.service` | `java_project/systemd/video-upload-java.service` |
| 落盘 | `incoming/dynamic/`、`incoming/playback/` | 同左（目录用环境变量指） |

OTA / Nginx / MySQL 不在这里，见仓库 `ota_server/`。协议与现网库存：[doc/VIDEO_UPLOAD_SERVER.md](../doc/VIDEO_UPLOAD_SERVER.md)

---

## 1. 公共协议（两套都认）

IPC 不走 MQTT 传文件。人形 `type=1`、回放 `type=2`，都是：

```text
POST /admin/api/v1/uploadVideo
  multipart: type=AES-256-ECB+Base64（或明文 1/2）, file=TS
  → 2xx JSON 且含 "path" 即成功
  → 1 写入 incoming/dynamic/ ，2 写入 incoming/playback/
```

备用入口（同机 Nginx，不在本目录）：`http://43.136.55.143/admin/api/v1/uploadVideo` → 反代到宿主机 7003。

| 方法 | 路径 | 作用 |
|------|------|------|
| GET | `/health`、`/admin/api/v1/health` | 探活 |
| GET | `/admin/api/v1/videos?limit=&type=&begin=&end=` | 列表 |
| GET | `/apps/video/dynamic\|playback/*.ts` | 下文件（**Java 有**；现网 Python 快照没有） |
| POST | `/admin/api/v1/uploadVideo` | 收片 |

---

## 2. Python 现网怎么跑

```text
开机
  → systemd video-upload
  → /usr/bin/python3 /home/ubuntu/video_upload/app.py
  → ThreadingHTTPServer(0.0.0.0:7003)
```

单元要点：`User=ubuntu`，`Restart=always`，`VIDEO_UPLOAD_DIR=/home/ubuntu/video_upload/incoming`。  
标准库 HTTP，无 Docker。每个请求一条线程。`type` 先查密文表，再 AES。

本机：

```powershell
cd e:\CAT1\AIR780EHM\http_server\python_project
$env:VIDEO_UPLOAD_DIR = "$PWD\incoming"
python app.py
```

---

## 3. Java 替换件怎么跑

Spring Boot 3.2 + Java 17，内嵌 Tomcat，**一个 fat jar**，systemd 前台拉起，和 Python 一样不进 Docker。

```text
mvn package
  → target/video-upload.jar
开机
  → systemd video-upload-java
  → java -Xms64m -Xmx256m -jar /home/ubuntu/video_upload_java/video-upload.jar
  → Tomcat 0.0.0.0:7003
```

| 环境变量 | 默认 | 含义 |
|----------|------|------|
| `VIDEO_UPLOAD_HOST` | `0.0.0.0` | 绑定地址 |
| `VIDEO_UPLOAD_PORT` | `7003` | 端口 |
| `VIDEO_UPLOAD_DIR` | `incoming`（现网建议绝对路径） | 落盘根 |
| `VIDEO_UPLOAD_AES_KEY` | 与 T31 相同 | 解密 `type` |
| `VIDEO_UPLOAD_MAX_BYTES` | 400MB | 单文件上限 |

构建与部署步骤见 [java_project/README.md](java_project/README.md)。服务器需要 `openjdk-17-jre-headless`。

切现网时 **先停 Python**，否则 `Address already in use`：

```bash
sudo systemctl stop video-upload
sudo systemctl disable video-upload
sudo systemctl enable --now video-upload-java
```

`VIDEO_UPLOAD_DIR` 可仍指向 `/home/ubuntu/video_upload/incoming`，旧片不用搬。

本机：

```powershell
cd e:\CAT1\AIR780EHM\http_server\java_project
mvn -s maven-settings.xml -DskipTests package
$env:VIDEO_UPLOAD_DIR = "$PWD\incoming"
java -jar target\video-upload.jar
```

---

## 4. 一次请求在 Java 里做什么

```text
POST multipart
  → UploadController.upload
  → TypeCipherService 解密 type（明文 / 已知 Base64 / AES-256-ECB）
  → VideoStorageService 安全化文件名 + 东八区时间戳
  → incoming/{dynamic|playback}/{stem}-{stamp}.ts
  → 旁路 .ts.json
  → {"code":200,"msg":"操作成功","data":{"path":"/apps/video/...", ...}}
```

T31 只认 2xx + `"path"`。不转码、不鉴权、不发 MQTT。

---

## 5. 和仓库其它目录

| 路径 | 角色 |
|------|------|
| `http_server/python_project/` | 现网 Python 快照 |
| `http_server/java_project/` | Java 替换件（本文重点） |
| `video_upload_server/` | 开发中的 Python（列表筛选 + 下载，比现网快照新） |
| `ota_server/` | 同机 OTA / Nginx / IPC 升级，**不是** 7003 |
