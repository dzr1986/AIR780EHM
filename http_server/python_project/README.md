# 现网 Python 快照（uploadVideo :7003）

本目录对应 `http_server/python_project`，从腾讯云 `/home/ubuntu/video_upload` 克隆。运行方式见 [../HOW_IT_RUNS.md](../HOW_IT_RUNS.md)。Java 替换件在 [../java_project](../java_project)。

监听 `http://43.136.55.143:7003/admin/api/v1/uploadVideo`，协议与南京后台
`http://112.86.146.218:7003/admin/api/v1/uploadVideo` 一致。

T31x 当前默认走本机，失败再回退南京。

## 协议

- 方法：`POST` multipart/form-data
- 字段：
  - `type`：AES-256-ECB + Base64，明文 `1`=动态侦测、`2`=回放
  - `file`：TS 文件
- 密钥：`7f3A9c82D1e64B5F90a7C3d8E2F6b410`
- 成功：HTTP 200，JSON 含 `"path"`（T31x 只认这两点）

```json
{
  "code": 200,
  "msg": "操作成功",
  "data": {
    "realName": "clip-20260817153000123.ts",
    "path": "/apps/video/dynamic/clip-20260817153000123.ts",
    "size": "0.01MB"
  }
}
```

## 部署（腾讯云）

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143
```

代码目录：`/home/ubuntu/video_upload`  
文件目录：`/home/ubuntu/video_upload/incoming`  
systemd：`video-upload.service`  
端口：**TCP 7003**（需在腾讯云安全组放行）

```bash
sudo systemctl status video-upload
journalctl -u video-upload -f
ls /home/ubuntu/video_upload/incoming
```

## 模拟上传

type=1 的密文（与 T31x / Java demo 一致）：`E/06stPxcWJoF8IkMn0xYw==`

```bash
curl -s -F "type=E/06stPxcWJoF8IkMn0xYw==" -F "file=@dummy.ts;filename=ch0_sim.ts" \
  http://43.136.55.143:7003/admin/api/v1/uploadVideo
```

或：

```powershell
python video_upload_server/simulate_upload.py --url http://43.136.55.143:7003/admin/api/v1/uploadVideo
```
