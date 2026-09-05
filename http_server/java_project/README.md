# Java uploadVideo（可替换现网 Python :7003）

协议与 Python / 南京后台相同：`POST /admin/api/v1/uploadVideo`，T31 认 HTTP 2xx + JSON `"path"`。

Spring Boot 3.2 / Java 17，打成一个 `video-upload.jar`，systemd 前台跑。与 `python_project` **不要同时占 7003**。

## 本机构建

需要 JDK 17 + Maven。国内镜像：`maven-settings.xml`。

```powershell
cd e:\CAT1\AIR780EHM\http_server\java_project
mvn -s maven-settings.xml -q -DskipTests package
```

产物：`target/video-upload.jar`（约 20MB，已在腾讯云用 Maven Docker `mvn package` 打通，含单测）。

本地若已有该 jar、且安装了 JRE 17：

```powershell
$env:VIDEO_UPLOAD_PORT = "7003"
$env:VIDEO_UPLOAD_DIR  = "$PWD\incoming"
java -jar target\video-upload.jar
```

探测：

```powershell
curl.exe -sS http://127.0.0.1:7003/admin/api/v1/health
python ..\python_project\simulate_upload.py --url http://127.0.0.1:7003/admin/api/v1/uploadVideo --type 1
```

## 部署到 43.136.55.143

先停 Python，再上 Java（同一端口）：

```bash
sudo systemctl stop video-upload
sudo systemctl disable video-upload

sudo mkdir -p /home/ubuntu/video_upload_java/incoming/{dynamic,playback}
sudo chown -R ubuntu:ubuntu /home/ubuntu/video_upload_java
```

```powershell
scp -i $env:USERPROFILE\.ssh\id_ed25519 `
  e:\CAT1\AIR780EHM\http_server\java_project\target\video-upload.jar `
  e:\CAT1\AIR780EHM\http_server\java_project\systemd\video-upload-java.service `
  ubuntu@43.136.55.143:/tmp/
```

```bash
sudo mv /tmp/video-upload.jar /home/ubuntu/video_upload_java/
sudo mv /tmp/video-upload-java.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now video-upload-java
curl -sS http://127.0.0.1:7003/admin/api/v1/health
```

服务器要有 **JRE/JDK 17**：`java -version`。没有则 `sudo apt install -y openjdk-17-jre-headless`。

旧片若还在 `/home/ubuntu/video_upload/incoming`，可把 `VIDEO_UPLOAD_DIR` 指过去，或拷到 `video_upload_java/incoming`。

运行说明总览：[../HOW_IT_RUNS.md](../HOW_IT_RUNS.md)
