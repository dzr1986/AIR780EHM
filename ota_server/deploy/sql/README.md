# SQL 说明

全新安装只执行 **`schema.sql`**。

原先拆开的 `migration_v2.sql` / `migration_v3.sql` / `fix_utf8.sql` 已并入 `schema.sql`：

| 旧文件 | 并入内容 |
|--------|----------|
| schema.sql | 库、devices、ota_tasks、项目/固件表 |
| migration_v2.sql | 项目、固件包、指定 IMEI、外键 |
| migration_v3.sql | devices.device_name / core_version / debug_enabled |
| fix_utf8.sql | utf8mb4、默认项目中文名 |

`schema.sql` **不含** 设备、任务、固件包等升级数据，只插入默认项目「4G 标准模块」。
