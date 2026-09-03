# 现网视频上传服务（Python 快照 + Java 替换件）

`http_server` 只放 **uploadVideo :7003** 这一套，不含 `ota_server`。

| 目录 | 是什么 |
|------|--------|
| [python_project/](python_project/) | 2026-08-20 从 `43.136.55.143:/home/ubuntu/video_upload` 克隆的现网 Python |
| [java_project/](java_project/) | 协议兼容的 Java 后台，打 jar 后可在同一台机器替换 Python |
| [HOW_IT_RUNS.md](HOW_IT_RUNS.md) | 两种实现如何启动、如何收片 |

**不要同时跑** Python 和 Java（都默认 7003）。现网若切 Java，先 `systemctl stop video-upload`。
