# IPC 升级（ipc_upgrade + pack_tool）

T31 IPC（`ipc_device_gb28181`）远程升级走 **HTTP 文件下载**，不是 Cat.1 的 `libfota2`。  
升级包必须用工程里的 **`pack_tool`** 打出来，产物是 **`ipc.tar` + `ipc.json`**，设备按 json 里的 `url` 去拉 tar。

生产：`http://43.136.55.143`  
下载口（与真机一致）：`http://43.136.55.143:8008/downloads/ipc.tar`  
SSH：`ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143`

与 4G 模组 OTA（MQTT 2004 + `/api/site/firmware_upgrade`）是两条线，互不替代。模组 OTA 见 [OTA_CHANNELS.md](OTA_CHANNELS.md)。

---

## 1. pack_tool 产物（真机用法）

设备工程：

```text
/home/powersys/work/T31/hu_du/hu_ipcapp/ipc_device_org/ipc_device_gb28181/tools
  pack_tool   ipc_upgrade   ...
```

`pack_tool` 输出示例（版本 `1.0.30` → 目录 `1_0_30`）：

```text
1_0_30/ipc.tar
1_0_30/ipc.json
```

`ipc.json` 关键字段：

```json
{
	"url":	"http://43.136.55.143:8008/downloads/ipc.tar"
}
```

旧文件服务器是 `http://112.86.146.218:8008/downloads/ipc.tar`。现网对齐为上面这条 **`:8008`** URL。  
真机 `ipc_upgrade`：读 `ipc.json` → HTTP GET `url` 指向的 **`ipc.tar`** → 校验 → 写分区。

Windows 上直接打包（推荐），产物固定在 `tools/ipc/x.x.x/`：

```text
python ipc_upgrade/pack_tool.py -i D:\ipc_src -v 1.0.30
python ipc_upgrade/pack_tool.py --json-only -v 1.0.30
```

会生成 `tools/ipc/1.0.30/ipc.tar` 与 `tools/ipc/1.0.30/ipc.json`。

---

## 2. 闭环链路

```text
pack_tool（1_0_30/ipc.tar + ipc.json）
    │  ① 上传，服务器固定写成 ipc.tar + ipc.json
    ▼
Nginx :8008
    http://43.136.55.143:8008/downloads/ipc.tar
    http://43.136.55.143:8008/downloads/ipc.json
    │  ② FileUrl = ipc.json.url
    ▼
ipc_upgrade（真机 T31 或本仓库 x86demo）
    GET ipc.tar → MD5 → 解包落盘 → 升版本
    │  ③ DeviceUpgradeResult
    ▼
Windows UI 读 /ipc_upgrade/status
```

T31 进程重、交叉编译麻烦时，用云主机 **x86demo** 代替嵌入式：同样拉 `:8008/downloads/ipc.tar`、校验、解包、更新当前版本。

---

## 3. 已部署的服务

| 组件 | 地址 | 作用 |
|------|------|------|
| Nginx 8008 | http://43.136.55.143:8008/downloads/ipc.tar | **真机 FileUrl**（对齐 pack_tool） |
| Nginx 80 | http://43.136.55.143/downloads/ipc.tar | 同目录镜像，备用 |
| x86demo | http://43.136.55.143/ipc_upgrade/health | 模拟 IPC，`DEVICE_ID=T31-X86-DEMO` |
| 上传 | `POST /ipc_upgrade/api/packages` | 任意文件或 ipc.tar → 写成 `ipc.tar` + `ipc.json` |
| 下发 | `POST /ipc_upgrade/api/ipc_upgrade` | `{url/FileUrl, version, md5, sessionId}` |
| 状态 | `GET /ipc_upgrade/status` | 当前版本、最近任务 |

文件目录（宿主机）：`/home/ubuntu/ota_server/ipc_upgrade/files`  
设备槽位：`/home/ubuntu/ota_server/ipc_upgrade/slot/current.tar`（解包在 `slot/extract/`）

### 网页管理台（推荐）

登录：http://43.136.55.143/ipc.html  
Token 与管理台相同：`ota-7f3a9c2e4b18d6a0e5c1`（`X-Admin-Token`）  
4G OTA 顶栏也可点 **IPC 升级**。

登录后先在设备表把目标 IMEI 的 **IPC 权限** 点成「允许」（默认禁止），再勾选设备上传并下发。升级记录写在该 IMEI 的设备台账（`ipc_version` / `ipc_status` / `ipc_enabled`）。实验室拉包仍走 x86demo。

| 接口 | 说明 |
|------|------|
| `GET /admin/api/ipc/status?imei=` | 登录校验 + IMEI 列表 + 选中设备 IPC 状态 |
| `PUT /admin/api/ipc/devices/{imei}/enabled` | `{enabled:true/false}` 单台允许/禁止 IPC 升级 |
| `POST /admin/api/ipc/devices/batch` | `{action:enable\|disable, imeis:[...]}` 批量权限 |
| `POST /admin/api/ipc/upload` | multipart `file` + `version` + 可选 `imei` |
| `POST /admin/api/ipc/upgrade` | `{imei, version, url, md5}`，IMEI 必填且须已允许 |
| `GET /admin/api/ipc/tasks/{id}?imei=` | 任务进度，成功则回写该 IMEI |
| `GET /admin/api/ipc/file/ipc.tar` | 登录后下载到本机 |

---

## 4. Windows 测试工具

推荐 Qt 统一工具（4G + IPC、多主题）：

```text
python ota_server\tools\ota_qt_gui.py
python ota_server\tools\ota_qt_gui.py --once-ipc
```

双击 `tools\ota_qt_gui.bat`。旧版仅 IPC 打包：`tools\ipc_upgrade_gui.bat`。

全部在 Windows 完成，不必再跑 Linux `./pack_tool`：

1. 填 **版本**（写入 `ipc.json`，例如 `1.0.30`）  
2. **生成 ipc.json** → `tools\ipc\1.0.30\ipc.json`  
3. **选择 IPC 文件**，点 **打包成 ipc.tar** → `tools\ipc\1.0.30\ipc.tar`  
4. **1. 上传 ipc.tar + ipc.json** → 推到服务器 `/downloads/`  
5. **2. 下发 ipc_upgrade** → 通知设备去拉包升级（见下一节）  
6. 或直接 **一键闭环**（打包 + 上传 + 升级）

产物目录固定：`E:\CAT1\AIR780EHM\ota_server\tools\ipc\x.x.x\`。

无界面：

```text
python tools\ipc_upgrade_gui.py --once D:\ipc.bin 1.0.30
```

成功最后一行：`PASS`。

---

## 5. 「2. 下发 ipc_upgrade」会执行什么

这一步**不会**再打包，也**不会**再上传。它只通知云主机上的 **x86demo**（设备 `T31-X86-DEMO`）执行一次模拟升级。

前提：必须先点过 **1. 上传**，界面里已经有 `ipc.tar` 的下载地址。没有的话会报「请先上传 ipc.tar」。

### 5.1 界面发出的命令

`POST http://43.136.55.143/ipc_upgrade/api/ipc_upgrade`，正文例如：

```json
{
  "deviceId": "T31-X86-DEMO",
  "filename": "ipc.tar",
  "url": "http://43.136.55.143:8008/downloads/ipc.tar",
  "FileUrl": "http://43.136.55.143:8008/downloads/ipc.tar",
  "version": "1.0.30",
  "md5": "上传时算出的 md5",
  "sessionId": "upg-xxxxxxxx"
}
```

### 5.2 设备侧（x86demo）逐步做什么

| 阶段 | 做什么 |
|------|--------|
| `accepted` | 接到命令，后台线程开始跑 |
| `downloading` | HTTP GET `FileUrl`（`ipc.tar`）。同机访问公网 IP 会 NAT 回环失败，容器内改打 `http://nginx:8008/downloads/ipc.tar` |
| 校验 | 计算 MD5，和上传时的值比对；空文件直接失败 |
| `installing` | 写成 `slot/current.tar`；能解包则解到 `slot/extract/` |
| `success` | 设备版本改成界面填的版本，相当于 `DeviceUpgradeResult OK` |
| `failed` | 任一环节出错，`lastResult=ERROR`，版本不改 |

`url` 若是 `…/downloads/ipc.json`，会先 GET json，再按其中的 `url` 拉 `ipc.tar`（更贴近真机）。

### 5.3 界面怎么确认结果

大约 30 秒内反复查询：

- `GET /ipc_upgrade/api/tasks/{sessionId}`：看 `stage` / `message`
- `GET /ipc_upgrade/status`：看设备当前版本

设备版本和目标版本一致 → 日志里 **PASS**。

### 5.4 执行完毕后东西在哪

第 2 步会改云主机模拟设备槽，成功后界面再把同一份包**拉回 Windows 本机**。也可以单独点 **3. 拉取到本地**。

本机（拉取结果）：

`E:\CAT1\AIR780EHM\ota_server\tools\ipc\1.0.30\pulled\`

| 文件 | 来源 |
|------|------|
| `pulled/ipc.tar` | GET `http://43.136.55.143:8008/downloads/ipc.tar` |
| `pulled/ipc.json` | GET `http://43.136.55.143:8008/downloads/ipc.json` |

本机（打包产物，第 2 步不改）：`E:\CAT1\AIR780EHM\ota_server\tools\ipc\1.0.30\ipc.tar`

云主机设备槽：`/home/ubuntu/ota_server/ipc_upgrade/slot/`

| 路径 | 是什么 |
|------|--------|
| `slot/current.tar` | 刚拉下来的升级包（`ipc.tar` 原样） |
| `slot/current.md5` | 该包的 MD5 |
| `slot/extract/` | 解包后的文件（tar 里有什么就有什么） |
| `slot/device.json` | 设备状态：当前版本、上次结果、sessionId |

上传时放到下载目录的包还在（给下次拉）：

| 路径 | 公网地址 |
|------|----------|
| `/home/ubuntu/ota_server/ipc_upgrade/files/ipc.tar` | http://43.136.55.143:8008/downloads/ipc.tar |
| `/home/ubuntu/ota_server/ipc_upgrade/files/ipc.json` | http://43.136.55.143:8008/downloads/ipc.json |

SSH 查看：

```bash
ls -la /home/ubuntu/ota_server/ipc_upgrade/slot/
ls -la /home/ubuntu/ota_server/ipc_upgrade/slot/extract/
cat /home/ubuntu/ota_server/ipc_upgrade/slot/device.json
```

### 5.5 不会做什么

不会刷真机 T31 的 flash。当前打的是云主机模拟器。  
真机要自己走原来的 `ipc_upgrade`，去拉同一条 `http://43.136.55.143:8008/downloads/ipc.tar`。

查任务：`GET /ipc_upgrade/api/tasks/{sessionId}`  
查设备：`GET /ipc_upgrade/status`

---

## 6. 接口

### 上传

`POST /ipc_upgrade/api/packages`  
`Content-Type: multipart/form-data`  
字段：`file`（`ipc.tar` 或任意文件）、可选 `version`（如 `1.0.30`）。

- 已是 tar → 原样存为 **`ipc.tar`**  
- 普通文件 → 打进 tar 再存为 **`ipc.tar`**  
- 同时写 **`ipc.json`**，`url` 固定为 `http://43.136.55.143:8008/downloads/ipc.tar`

返回：

```json
{
  "filename": "ipc.tar",
  "size": 10240,
  "md5": "...",
  "version": "1.0.30",
  "url": "http://43.136.55.143:8008/downloads/ipc.tar",
  "url8008": "http://43.136.55.143:8008/downloads/ipc.tar",
  "url80": "http://43.136.55.143/downloads/ipc.tar",
  "manifest": {
    "name": "ipc",
    "version": "1.0.30",
    "url": "http://43.136.55.143:8008/downloads/ipc.tar",
    "md5": "...",
    "size": 10240,
    "file": "ipc.tar"
  }
}
```

下发接口与设备侧步骤见第 5 节。

---

## 7. 运维

| 路径 | 内容 |
|------|------|
| `deploy/nginx/ota.conf` | `/downloads`、`:8008`、`/ipc_upgrade` 反代 |
| `ipc_upgrade/pack_tool.py` | 兼容真机 pack_tool 的打包脚本 |
| `ipc_upgrade/x86demo/` | x86 模拟 IPC |
| `ipc_upgrade/files/` | 对外下载目录（`ipc.tar` / `ipc.json`） |
| `tools/ipc_upgrade_gui.py` | Windows UI |

发布：

```powershell
scp -i $env:USERPROFILE\.ssh\id_ed25519 -r `
  e:\CAT1\AIR780EHM\ota_server\ipc_upgrade `
  e:\CAT1\AIR780EHM\ota_server\deploy\nginx\ota.conf `
  e:\CAT1\AIR780EHM\ota_server\docker-compose.yml `
  ubuntu@43.136.55.143:/tmp/ipc_up/
```

服务器：

```bash
cd /home/ubuntu/ota_server
sudo docker compose up -d --build nginx ipc-x86demo
```

健康检查：

```bash
curl -sS http://127.0.0.1/ipc_upgrade/health
curl -sSI http://43.136.55.143:8008/downloads/ipc.tar
curl -sS http://43.136.55.143:8008/downloads/ipc.json
curl -sS http://43.136.55.143/ipc_upgrade/status
```

若 `:8008` 外网不通，在腾讯云安全组放行 **TCP 8008**。

---

## 8. 真机怎么接

1. 在 T31 工程 `tools/pack_tool` 打出 `1_0_30/ipc.tar` + `ipc.json`  
2. 把 `ipc.tar` 放到本服务器 `/downloads/`（Windows UI 上传，或 `scp` 到 `ipc_upgrade/files/ipc.tar`）  
3. `ipc.json` 的 `url` 写成 `http://43.136.55.143:8008/downloads/ipc.tar`  
4. 把该 json / FileUrl 发给 IPC，设备走原有 `ipc_upgrade` 拉 tar 写 flash  

x86demo 不替代 flash；它只证明 **pack_tool 包格式 + :8008 文件服务 + 下发 + 拉包 + 结果** 这条控制面已通。

---

## 9. 闭环实测

环境：腾讯云 `43.136.55.143`，x86demo `T31-X86-DEMO`。实测日期 2026-08-18。

用仓库 `pack_tool.py` 打出 `1_0_30/ipc.tar` + `ipc.json`（`url` = `:8008/downloads/ipc.tar`），再走 Windows `--once`：

| 步骤 | 结果 |
|------|------|
| `GET /ipc_upgrade/health` | `ok`，`fn=ipc_upgrade`，`pack=ipc.tar` |
| 上传 `1_0_30/ipc.tar` | 10240 字节，MD5 `d4447c7edc7f5508575d1bc58a86243a`，写成 `/downloads/ipc.tar` + `ipc.json` |
| 公网 `GET http://43.136.55.143:8008/downloads/ipc.tar` | HTTP **200**，10240 字节 |
| `POST /ipc_upgrade/api/ipc_upgrade` FileUrl=`:8008/downloads/ipc.tar` | accepted → downloading → installing → **success** |
| 设备版本 | **1.0.1 → 1.0.30**，`DeviceUpgradeResult OK`，解包成员 `ipc_x86_1.0.1.bin` |

结论：pack_tool 包格式、`:8008/downloads/ipc.tar` 文件服务、`ipc_upgrade` 拉包校验解包、结果回读均已打通。
