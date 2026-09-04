# 云侧服务端代码体检报告（2026-09-04）

> 范围：`ota_server`（src + ota_cat1_ipc/site + docs）、`patch_server`（= ota_server 源码快照）、`http_server`（python_project + java_project）、`video_upload_server`，外加全仓敏感信息 / 产物入库扫描。
> 方法：3 组并行只读审查（子 Agent 检索收集）→ 主流程对 P0/P1 关键断言逐一源码抽验复核后成稿。
> **验收口径：只读审计，本报告不改任何代码**（审计修复分离；服务端不在固件冻结范围内，修复动作等确认后单独进行）。
> 代码行号为复核时的实测；标注「(SA)」= 子 Agent 定位、主流程未逐字复核，引用前请复核。

## 0. 项目形态总览

| 子项目 | 规模 / 栈 | 性质 | 配置真源 |
|---|---|---|---|
| `ota_server/` | ~98 java（`src/` 与 `ota_cat1_ipc/site/` 两棵树）+ Spring Boot 3.2 / Java 17 / JPA / MySQL8 / Paho MQTT | 4G 模组差分 FOTA：HTTP 拉包 + 管理台 + MQTT 2004 触发 | `src/main/resources/application.yml`（生产经环境变量覆盖） |
| `patch_server/` | `ota_server/src` 的字节级一致源码子集（10 java）+ docs/tools/deploy | **旧阶段导出快照**（不可独立构建，无 pom/yml） | — |
| `http_server/` | Python 现网版 `python_project` + Java 替换件 `java_project`（同 7003） | 视频上传 7003 的两种实现 | 各 project 内配置 |
| `video_upload_server/` | `app.py`（Python 标准库单文件）+ systemd | 报警视频上传/列表/回放（公网 7003/80） | 环境变量（`app.py` 默认值） |

---

## 1. P0 —— 安全 / 数据 / 阻断（需处置）

### P0-1 现网凭据明文入库且跨端多副本扩散（真凭据，风险最高）

全仓存在 **4 类真凭据硬编码**，且同时出现在固件、服务配置、compose、工具脚本、前端页面与文档中（每处重复都扩大一次暴露面）。复核源证据：

- **MQTT Broker 口令**（用户 `fptop1`）：固件 `user/net.lua:28`；服务端 `ota_server/src/main/resources/application.yml:44`；`docker-compose.yml`（3 份）；`tools/gui/mqtt/profiles.json:11`、`config.json:6`；`tools/debug/_test_cat1_ota_e2e.py:19`；文档 6+ 处（`doc/mqtt/MQTT_DOWNLINK.md:21` 等）。
- **OTA 管理令牌**（`X-Admin-Token`）：`tools/ui.json:5`、`sim_luat_client.py:16`、`ota_qt_api.py:22`、`ota_test_gui.py:25`；前端 `admin.html:101` / `ipc.html:61` 预填；`.env.example:2`；compose 默认值；`ota_server/docs/OTA_REAL_DEVICE.md` 等。
- **视频 type AES-256 密钥**（32 hex，`7f3A9c…E2F6b410`）：`video_upload_server/app.py:30`（env 默认）、`simulate_upload.py:12`、`README.md:16`；`http_server/python_project/app.py:30`；`http_server/java_project/.../application.yml:22`、`UploadProperties.java:10`。
- **DB 口令 `luat123`**（user `luat`，`jdbc:...luat_ota`）与 **product key** `ThOoUo…0d5x`：`application.yml:11-12`；`DataInitializer.java:30`；schema.sql 种子；compose。

结论 / 处置方向：真凭据应以 **env / docker secret / 密钥管理**注入，代码与文档只留占位；**口令轮换 + git 历史清理**需纳入计划。product key 本身随量产固件半公开（刻在 `user/main.lua PRODUCT_KEY`），单独作为设备鉴权凭据强度不足（见 P0-3）。

**git 历史实证（收口复核）**：`git log --all -S` 三类真凭据均自初始提交 `2e30e57 add full project` 即入库，并在此后多个 commit 反复复写（含 `328b7ef` OTA 服务端首建、`1c623c0` 模块重命名、`bbf04a6` 工具链同步等）。即：**每份历史 clone / 分支均永久携带真凭据**，仅删当前工作区文件不足以止血，「历史清理（filter-repo/失陷轮换）」为必做项（需与部署确认，未实施）。

### P0-2 公网无鉴权暴露端点群（读类 = 数据泄露面）— nginx 部署实证

两层证据闭环：① 应用层鉴权拦截器仅覆盖 `/admin/api/**`（`WebConfig.java:17-20`，已复核）；② **部署层 nginx 证实这些端点挂在公网且无 ACL/IP 白名单/限流**（`ota_server/deploy/nginx/ota.conf`，已复核；另 `ota_cat1_ipc/site/deploy/nginx/ota.conf` 为同尺寸复制件）：

- `listen 80`（注释自述「公网 IP 部署：80 直接反代，设备 libfota2 走 HTTP」）与 `listen 443` 的 `location /` 全量反代 `ota-server:8080` → 以下全部公网可达：
  - `GET /firmware/{filename}`（`LuatOtaController.java:59-71`）：可拉取 firmware 目录内**任意文件**（未发布/未上线的差分包、`manifest.json` 内部清单），仅靠 `loadDirectFile` 的 `normalize + startsWith` 防穿越，无鉴权、无扩展名白名单。
  - `GET /api/site/firmware_upgrade`、`/luat/update`：无设备身份校验（见 P0-3）。
- `location /downloads/`：`alias /var/www/fileserver/` + **`autoindex on`**，在 **80 / 443 / 8008 三个端口**全部开启 → IPC 固件目录公网目录列举 + 任意文件下载（`ota.conf:11-19/66-74/115-123`；注释明示真机 `ipc.json.url = http://IP:8008/downloads/ipc.tar`）。独立静态目录无任何鉴权层。
- `location /admin/api/v1/` 反代 `host.docker.internal:7003`（现网 video_upload_server Python 版）→ 其 `GET /admin/api/v1/videos`（列表，`app.py:153-203`）与 `GET /apps/video/*.ts`（回放下载，`app.py:204-218`）**无任何鉴权**，经公网 80/443 直达 → 现场报警录像可被任意人枚举/下载。

上传本身无鉴权属协议性限制（T31 侧仅有固定 AES 密钥且密钥已在代码公开，见 P0-1），但**读端必须收紧**。处置方向：读端加令牌 / IP 白名单 / 内网隔离 / 签名 URL；`/firmware/*` 仅允许已 release 文件 + 扩展名白名单；`/downloads/` 关 autoindex 并做防列举。

### P0-3 设备拉包缺乏服务端侧身份校验（可冒用拿包）

`FirmwareService.java:95-106`（已复核）：仅校验「project_key 存在」+「未绑定 IMEI 时绑定」，project key 为代码内固定值（`DataInitializer.DEFAULT_KEY`）且随固件公开；`application.yml:32 allowed-imeis: []` 默认恒空。即**任一方知道固定 key + 自报 imei** 即可请求差分包；imei 归属无服务端白名单/签名校验兜底。处置方向：allowed-imeis 落地为必填白名单（非空默认拒绝）或引入设备级签名 / 拉包地址签名 URL。

---

## 2. P1 —— 应修

| # | 类别 | 位置 | 说明（证据已抽验，除标注 SA 外） |
|---|---|---|---|
| 1 | 配置多真源漂移 | `application.yml:31` `admin-token: dev-ota-token-change-me` vs `OtaProperties.java:20` 默认 `changeme` vs tools/.env/前端实载 `ota-7f3…`（均复核）；同类：`application.yml:25 latest-version: 2034.001.003` vs `OtaProperties.java:14` 默认 `2034.001.002` | 占位默认值与「实际在用令牌」并存，谁是真源不明；误用占位会直接 401，误用实测值则泄露。应收敛为单真源 + 环境注入 |
| 2 | 启动自种数据 | `config/DataInitializer.java:45-142`（全文复核） | 无开关的 `ApplicationRunner`：空库时必种 4 台**仿真实 IMEI 样机**（含 `862323084068314` 等真机号，仅空字段才补——空库全新部署时会全量写入台账）+ 写入伪文本差分包 `seed_2044001001_to_2044001010.bin` 且 `upgradeAll=true`。若生产库全新/被清空重建，源版本 2044.001.001 设备会被指向假包。`ota_cat1_ipc/site/application.yml:38` 有 `seed-demo-data` 配置而 `src` 无——配置项与代码对不上。建议：加 `@ConditionalOnProperty` 且默认关 |
| 3 | 循环升级防护依赖结果回传闭环（**结论修正：收口复核后降级**） | `DeviceService.noteUpgradeOffered:345-368`、`updateFromMqttEvent:285-296`、`FirmwareService.applyLoopGuard:280-289`（已复核） | 同一 (源→目标) 连续下发 6 次且设备仍报旧版本即 `otaEnabled=false`。清零路径：MQTT success（→`clearLoopProtection`）或设备上报新版本使 loop 失配（`noteUpgradeOffered` 按双版本同 loop 才累计）。MQTT 桥默认 `enabled: false`（`application.yml:39`）时清零主要依赖 HTTP 上报新版本。误封前提窄（真实成功却持续以旧版本拉包且成功事件缺失），且运维有 unban 通道（batch/unban，`DeviceService:166`）。**非逻辑缺陷**，维持关注并在文档注明防护机制即可，降出「应修」档 |
| 4 | IMEI 唯一性非 DB 约束 | `Device.java:14-15 @Column(unique=true)` + `ddl-auto: update`（`application.yml:16`，已复核） | `ddl-auto:update` 对存量表不补唯一索引；首连并发两请求同 IMEI find-or-create+save 可抛唯一冲突→拉包失败。建议 schema.sql 显式 UNIQUE + 幂等 upsert |
| 5 | HTTP 语义文档漂移 | 代码 `LuatOtaController.java:43-56`（复核）：`403/400` 外层 + `X-Ota-Error-Code: 25/26/27` 头 | 文档 `docs/OTA_ADMIN.md:73-77`、`OTA_PROTOCOL.md:99` 以「HTTP 码 = 25/26/27」表述、把 403 写成「IMEI 不在白名单」→ 运维按文档排查看错响应面。文档应改为描述 X-Ota-Error-Code 头 |
| 6 | 上传边界偏松 | `AdminController.java:101-106`（已复核） | 仅 `endsWith(".bin")` 小写精确校验原始文件名（multipart filename 客户端可控），`.BIN`/大小写变体被拒、改名可绕过，无魔数/内容校验。建议魔数 + 统一小写后缀 + 落盘名与文件名解耦 |
| 7 | DB TLS 关闭 | `application.yml:10`（复核） | `useSSL=false&allowPublicKeyRetrieval=true` 作为生产模板默认；公网/云 RDS 应走 TLS + 证书校验 |
| 8 | 视频上传静默容忍 | `app.py:257-258`（复核） | type 解密失败/未知时静默落 `unknown/` 目录且回 200 成功；异常文件（伪造 type）长期堆积。建议拒收或告警 + 定期清理 unknown/ |

---

## 3. P2 —— 重复 / 异味

| # | 类别 | 位置 | 说明 |
|---|---|---|---|
| 1 | **三份源码树并存且漂移** | `ota_server/src/`（主） vs `ota_server/ota_cat1_ipc/site/`（迁移/精简版，`Device.java` 等尺寸不同） vs `patch_server/ota_server/`（字节级一致源码子集快照 + 同源 docs/tools/deploy） | 核心 OTA 决策逻辑三树一致，外围已漂移；patch 快照缺 pom/yml **不可独立构建**，易误改。建议：`src` 为唯一真源，`ota_cat1_ipc` 由打包脚本生成，`patch_server` 目录按 ARCHITECTURE_REVIEW_20260903 归档方案处理 |
| 2 | 产物/归档工作区残留 | 根 `780EHM_PJ_v1.2_20260602.zip`（无 ignore 覆盖，疑入库）、根 `ps01masch260318.pdf`（与 datasheet 重复）；5 处 `.7z`（多数已被 gitignore 覆盖）、`dist/firmware` 数十个 `.soc/.bin/.binpkg`、`http_server/java_project/target/video-upload.jar`(18.86MB，已 ignore) | 建议核实根目录两文件是否入库并迁 archive/；其余确认 ignore 生效即可 |
| 3 | 整段内存读文件 | `LuatOtaController.java:103-109`（复核） | Range 请求 `readNBytes((int)size)` 整段进内存（上限 32MB），非流式。建议 `StreamingResponseBody` / `ResourceRegion` |
| 4 | 死代码 / 弱实现 | `DeviceRepository.findUpgradeCandidates()`（SA）；`LoopTestService.exclusiveForImei` 全固件 O(n×m) 扫描；DEFAULT_KEY/FW/IMEI 常量在 `DataInitializer` / `LoopTestService` 重复；`MqttOtaBridgeService` MQTT 桥失败仅 log 静默下线 | 死代码可删；常量收敛到 `OtaProperties`；MQTT 断连建议暴露健康状态/告警 |
| 5 | 双实现协议对账（待验证） | `http_server/python_project` 现网版 vs `java_project` 替换件 vs `video_upload_server` | 三份实现字段/路由行为需人工逐项 diff 清单（Python 现网版无列表/下载路由等已知差异）；建议定唯一 Java 版为真源后删并 |

---

## 4. P3 —— 文档 / 建议

- `ota_server/README.md:688-689` 称管理台在 `resources/static/admin.html`，但 `src` 树无 static（实际 Nginx 供 admin.html）(SA)。
- `README.md:134-144` 版本优先级描述缺「firmware_packages（registry）层」，与 `FirmwareService.evaluate` 实际主路径不一致 (SA)。
- `ota_cat1_ipc/README.md:50` 默认 Token 声称在 `site/.env`，与 Java 侧默认不一致（同 P1-1）。
- `app.py:34-37` `KNOWN_TYPE_B64` 密文表写死→AES-ECB 对该字段形同虚设（密钥+密文都在代码里）；建议保留仅作协议兼容，明确其非安全机制（README 明示即可）。
- 生产 IP 硬编码散布：`43.136.55.143`、`112.86.146.218`、`…219` 出现在 `application.yml:37/40`、`OtaProperties.java:25`、固件 `user/net.lua:24/36/37`、多份 doc 与 SSH 示例。属公开端点但建议收敛到部署配置，README 的 SSH 连接串示例建议改 `$USER@$HOST` 占位。

---

## 5. 处置建议（待确认后单独实施）

| 优先级 | 动作 | 风险 | 前置条件 |
|---|---|---|---|
| 1 | 凭据外置 + 轮换 + 文档去密（P0-1） | 部署配置改动、需重新分发 | 确认服务端当前部署形态（Docker? 单机?） |
| 2 | 读端鉴权收紧（P0-2：video 列表/下载、ota /firmware 下载加 token 或内网白名单） | 低，兼容读路径 | 需确认 GUI 回放与固件拉包的实际调用方 |
| 3 | allowed-imeis 默认全拒 + IMEI 白名单落地（P0-3） | 中，影响现网拉包 | 需现网设备清单 |
| 4 | DataInitializer 开关默认关（P1-2）、Device IMEI UNIQUE（P1-4）、文档纠偏（P1-5） | 低 | 无 |
| 5 | 源码树收敛：src 为真源、删 patch_server 重复、清理根目录归档（P2-1/2） | 低-中 | 无（工作区卫生） |

## 6. 未验证 / 已知限制（如实披露，收口复核后更新）

- 全程**静态审查**，未运行 mvn/python 测试与真机/联调验证（环境无设备、无 DB）。
- **已消除的待验证项**（2026-09-04 收口复核）：
  - git 历史凭据：`git log --all -S` 实证真凭据自初始提交入库且多版本复写 → 并入 P0-1（§7 记录）。
  - nginx 可达性：`deploy/nginx/ota.conf` 实证公网 80/443/8008、无 ACL → 并入 P0-2（§7 记录）。
- 残余 (SA)：P2-4 死代码定位、P3 文档漂移行号、P2-5 `http_server` 三实现协议 diff 未逐项复核，引用前请先复核。
- `http_server` Java/Python 三实现协议差异未逐项 diff（P2-5 待验证）。

## 7. 收口复核记录（2026-09-04，只读，不改码）

| # | 复核动作 | 结论 |
|---|---|---|
| 1 | `git log --all -S` 三类真凭据 | 自 `2e30e57`（初始提交）即入库，`328b7ef`/`1c623c0`/`bbf04a6` 等持续复写 → P0-1「历史清理必做」升级为实证 |
| 2 | `ota_server/deploy/nginx/ota.conf` 全文 | 80/443 `location /` 全量反代 8080（`/firmware/*`、拉包接口公网可达）；`/downloads/` alias + `autoindex on` × 80/443/8008（目录列举 + 任意下载，无鉴权）；`/admin/api/v1/`→7003 → P0-2 增补静态目录端点、危害定级「远程实证」 |
| 3 | `FirmwareService` 1-90、129-289、`DeviceService` 全文、`OtaProperties` 全文 | `isDeviceAllowed` 白名单空即放行确证 P0-3 默认配置根因；evaluate 三段主路径（registry→manifest→fallback）与 loop-guard 落点复核 |
| 4 | P1-1 / P1-6 行号复核 | `OtaProperties.java:20 changeme`、`:14 latestVersion 2034.001.002`（vs yml 两处漂移）；`AdminController.java:101-106` `.bin` 校验——原 (SA) 升为已复核 |
| 5 | P1-3 结论复核 | loop 计数按 (源,目标) 双相同累计、成功事件清零路径存在、MQTT 桥默认关、运维 unban 通道齐备 → **误封定性过重，降级为「防护依赖闭环」**（见 §2 行 3） |
