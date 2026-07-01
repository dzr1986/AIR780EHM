# 780EHM_PJ

本仓库包含两部分：

1. **LuatOS 固件**（`user/`、`lib/`、根目录 `*.lua`/`config.mk`）：运行在 Air780EHM + T3x 摄像头硬件上的嵌入式固件，使用 Luatools 打包烧录。**无法在普通开发主机/CI 上运行**（需真实模组硬件），文档见 `README.md` 与 `doc/`。
2. **OTA 服务器**（`ota_server/`）：Spring Boot 3 + Maven + MySQL 的自建固件升级服务端，这是本仓库**唯一可在开发环境运行的应用**。完整说明见 `ota_server/README.md`。

## Cursor Cloud specific instructions

适用范围：`ota_server`（Spring Boot OTA 服务端）。固件部分不在云端可运行范围内。

### 服务与依赖
- **运行时**：系统已装 OpenJDK 21（项目 `pom.xml` 目标 `java.version=17`，兼容）、Maven 3.8、MySQL 8.0。这些是系统依赖，已随快照保留；更新脚本只刷新 Maven 依赖，不重装它们。
- **MySQL 不会随 VM 自动启动**，每次会话需手动启动：`sudo service mysql start`。数据库 `luat_ota`、用户 `luat`/`luat123`（与 `application.yml` 一致）已创建并随快照保留；若缺失则重建并执行 `mysql luat_ota < ota_server/deploy/sql/schema.sql`（JPA `ddl-auto=update` 也会自动建表）。

### 运行 OTA 服务（开发模式）
- 在 `ota_server/` 下：`mvn spring-boot:run`（监听 `:8080`）。
- 默认 `application.yml` 中 `luat.mqtt.enabled=false`，本地开发**无需** MQTT broker 即可启动；只测 HTTP OTA 逻辑时保持关闭即可（开启会尝试连外网 broker `112.86.146.218:2123`）。
- 管理台：`http://127.0.0.1:8080/admin.html`，Admin Token 默认 `dev-ota-token-change-me`（`application.yml` → `luat.ota.admin-token`）。
- 管理 API 需请求头 `X-Admin-Token`；设备 OTA 接口（`/api/site/firmware_upgrade`、`/luat/update`、`/health`）无需鉴权。

### 测试 / 构建 / lint
- 单元测试：`mvn test`（测试用 H2 内存库，不依赖 MySQL）。
- 构建：`mvn package`。仓库未配置独立 lint 插件，编译（`mvn compile`）即为静态检查。
- 差分包 `firmware/*.bin` 被 `.gitignore` 忽略；测试时可放任意 `.bin` 占位，匹配靠 manifest/DB 的版本号而非文件内容。
