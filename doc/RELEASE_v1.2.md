# Release v1.2（备份说明）

> 标签：`v1.2`  
> 打包名建议：`780EHM_PJ_v1.2_20260602.zip`  
> 固件版本字符串：`APP_META.version` / `BUILD_TAG` = **v1.2**

---

## 本版主要变更

| 类别 | 内容 |
|------|------|
| 蜂窝 | `lib/cellular_bootstrap.lua` — IMSI/ICCID 运营商识别、联通 APN、`mobile.reset` 重试 |
| 时间同步 | `user/time_sync.lua` + `cat1_host/time_sync.c` — `AT+TIMESET` / `AT+TIME?` |
| 电量/USB/T3x | `lib/t3x_policy.lua` 统一门禁；`LOW_BATTERY` / `POWER_USB` 文档 v1.2 |
| MQTT | SIM 1005 增加 `operator` / `operatorName` |
| 配置 | `CELLULAR_CFG`、`MODULE_FLAGS.cellular` |

---

## 本地打包与提交

磁盘空间充足时在仓库根目录执行：

```powershell
.\scripts\release_v1.2.ps1
```

或手动：

```powershell
git add user lib doc cat1_host luatos.json README.md scripts
git commit -m "Release v1.2: cellular, time-sync, battery-usb-t3x docs"
git tag -a v1.2 -m "v1.2 backup"
```

---

## v1.2 电量/T3x 修复（相对 v1_20260529 文档缺口）

- rest / 低电（≤15%）下 MQTT 离线、`notify_host` 不再误唤醒 T3x
- 启动先 `initPowerStatus`，低电无 USB 时 `bootPowerOn` 跳过上电
- `recover_rest_percent=18`、`pir_resume_percent=20`

可选优化见 [POWER_USB_BATTERY_T3X_LOGIC.md](POWER_USB_BATTERY_T3X_LOGIC.md) §4。

---

## 上一版参考

- 字符串版本曾用 `v1_20260529`
- Git 标签以 **`v1.2`** 为准
