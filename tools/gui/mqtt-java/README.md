# Java 回放上传闭环工具（mqtt-java）

磐石 Cat.1 设备的 **MQTT 回放上传闭环测试台**（Java Swing 桌面版）。

通过 MQTT 向设备下发 2013 回放上传请求，实时跟踪设备上行的 1013 状态机
（排队 → 上传进度 → 完成/失败），并在界面显示信号质量与完整收发日志。

与 Python 版工具功能对等（`tools/gui/mqtt/mqtt_tools_gui.py --tab playback`），
适用于未安装 Python 环境或 Python GUI 异常的机器。

---

## 1. 闭环协议（2013 ↔ 1013）

```
下发 2013
  → MQTT 1013  stage=queued    reply=1    开始/已排队
  → MQTT 1013  stage=uploading reply=1    percent / sentBytes / totalBytes（实时进度）
  → MQTT 1013  stage=waiting_resp        文件已发完，等待 7003 回包
  → MQTT 1013  stage=uploaded  reply=0    完成（含 httpPath）
             或 stage=fail     reply=0    失败（含 ret / message）
```

- **reply=1**：过程态（排队中 / 上传中），进度条随 `percent` 更新
- **reply=0**：终态——`ret=0` 判定成功（进度置 100%），`ret≠0` 判定失败
- 需要 **T31 新固件**（`AT+UPLOADPROGRESS`）+ **Cat.1 新脚本**；
  旧固件仍只有 `queued + reply=0`，无进度字段

协议细节见 `doc/MQTT_2013_1013_UPLOAD_VIDEO.md`、`doc/MQTT_CLIP_UPLOAD_CLOSED_LOOP.md`。

---

## 2. 功能特性

| 功能 | 说明 |
|---|---|
| Broker 连接管理 | 地址/端口/用户名/密码/IMEI/ClientId 可视化配置，连接/断开按钮，自动重连 |
| 订阅上行 | 连接后自动订阅 `/panshi/app/{IMEI}/event`、`/status`、`/property` 三个主题 |
| 2013 回放下发 | 选择开始/结束时间（默认最近 5 分钟），一键发布回放上传请求 |
| 1013 闭环跟踪 | 状态标签 + 进度条实时推进：queued → uploading% → uploaded/fail |
| 信号质量显示 | 1003/1005 消息解析 CSQ/RSRP/RSSI/RSRQ/SNR/电量/工作模式，横幅展示 |
| 完整日志 | 带毫秒时间戳记录全部收发消息原文，自动滚动 |

---

## 3. 目录结构

```
mqtt-java/
├── README.md                    本说明
├── pom.xml                      Maven 构建定义（Paho 1.2.5 + Gson 2.10.1）
├── run.bat                      免 Maven 一键编译运行
├── .gitignore                   忽略 lib/、out/ 编译产物
└── src/main/java/com/panshi/mqtt/
    └── MqttClosedLoopApp.java   全部逻辑（单文件，约 430 行）
```

---

## 4. 环境要求

- **JDK 11 及以上**，`java` / `javac` 在 PATH 中
- 首次运行需联网（从 Maven Central 下载依赖 jar）
- 运行时依赖两个 jar（自动下载到 `lib/`）：
  - `org.eclipse.paho.client.mqttv3-1.2.5.jar`（MQTT 客户端）
  - `gson-2.10.1.jar`（JSON 解析）

---

## 5. 运行方法

### 方式一：双击脚本（推荐）

```bat
tools/gui/mqtt-java/run.bat
```

脚本自动完成：建 `lib/` `out/` 目录 → 下载缺失的 jar → `javac` 编译 → 启动 GUI。

### 方式二：Maven

```bash
mvn compile exec:java
```

### 方式三：Python 界面（未装 JDK 时）

```bat
tools/mqtt_tools_gui.bat --tab playback
```

---

## 6. 配置文件

程序启动时按以下优先级读取（与 Python 工具共用同一份配置）：

1. `tools/gui/mqtt/profiles.json` 中 `active` 指向的 profile
2. `tools/gui/mqtt/config.json`
3. 内置默认值

| 字段 | 用途 | 默认值 |
|---|---|---|
| `broker` | MQTT 服务器地址 | `112.86.146.218` |
| `port` | 端口 | `2123` |
| `username` / `password` | 认证 | `fptop1` / 空 |
| `device_imei` | 目标设备 IMEI（决定订阅/发布主题） | 空 |
| `client_id` | 客户端 ID（留空自动生成随机后缀） | `platform-java-001` |

---

## 7. 界面与操作步骤

```
┌─ Broker/端口/用户/密码 ─ IMEI/ClientId ─ [连接] [断开] 状态 ─┐
│  信号横幅：1003/1005  CSQ/RSRP/RSSI/RSRQ/SNR/电量/工作模式     │
│  回放闭环 2013 → 开始 → 进度 → 完成                           │
│  开始时间 [__________] 结束时间 [__________] [最近5分钟]      │
│  [请求上传 2013]                                              │
│  状态: uploading  65%                                         │
│  ████████████░░░░░░░░░░░░░░░░░░░░░░░░  进度条                 │
│  日志区（时间戳 + 收发消息原文）                               │
└───────────────────────────────────────────────────────────────┘
```

1. 填好/确认连接参数，点 **连接**（自动订阅设备上行主题）
2. 设置回放时间范围（默认最近 5 分钟），或点 **最近5分钟** 刷新
3. 点 **请求上传 2013**，观察状态标签与进度条推进
4. 收到 `reply=0` 即闭环结束：成功显示 `httpPath`，失败显示 `ret`/`message`
5. 关闭窗口自动断开连接

---

## 8. 消息格式

### 下发 2013（发布到 `/panshi/device/{IMEI}/`）

```json
{
  "dataType": "2013",
  "messageId": "play-1700000000-abcd",
  "action": "upload_video",
  "needUpload": 1,
  "reason": "cloud",
  "videoType": 2,
  "beginTs": 1699999800,
  "endTs": 1700000100,
  "beginTime": "2023-11-15 10:00:00",
  "endTime": "2023-11-15 10:05:00"
}
```

### 上行 1013（设备 → app）

| 字段 | 含义 |
|---|---|
| `stage` | `queued` / `uploading` / `waiting_resp` / `uploaded` / `fail` |
| `reply` | `1`=过程态，`0`=终态 |
| `percent` | 上传进度 0-100（uploading 阶段） |
| `sentBytes` / `totalBytes` | 已发/总字节 |
| `ret` / `message` | 终态结果（ret=0 成功） |
| `httpPath` | 成功后文件地址 |
| `fileName` | 文件名 |

### 信号 1003 / 1005（横幅展示）

`csq` / `rsrp` / `rssi` / `rsrq` / `snr` / `remainPower` / `workMode`

---

## 9. 常见问题

| 现象 | 处理 |
|---|---|
| 提示未找到 java | 安装 JDK 11+ 并加入 PATH；或改用 Python 界面 `--tab playback` |
| 首次运行卡在"下载 Paho" | 确认可访问 `repo1.maven.org`；失败后重跑脚本会自动补下 |
| 连接失败 | 核对 profiles.json 的 broker/端口/账号密码；设备 IMEI 是否正确 |
| 下发后无 1013 反馈 | 确认固件版本支持 `AT+UPLOADPROGRESS`（旧固件只有 queued + reply=0） |
| 进度不更新 | 查看日志区原文，确认 1013 的 `stage` 字段是否带 `percent` |

---

## 10. 相关文档

- `doc/MQTT_2013_1013_UPLOAD_VIDEO.md` —— 2013/1013 协议定义
- `doc/MQTT_CLIP_UPLOAD_CLOSED_LOOP.md` —— 上传完成闭环
- `doc/MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md` —— 检测回放链路
- `tools/gui/mqtt/mqtt_tools_gui.py` —— Python 版工具（含 playback 页签）
