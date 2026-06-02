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
| 电量/USB/T31 | 文档 `POWER_USB_BATTERY_T31_LOGIC.md`；`LOW_BATTERY` §9～§10 |
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
git commit -m "Release v1.2: cellular, time-sync, battery-usb-t31 docs"
git tag -a v1.2 -m "v1.2 backup"
```

---

## 已知未在本版代码修复项

见 [POWER_USB_BATTERY_T31_LOGIC.md](POWER_USB_BATTERY_T31_LOGIC.md) §6（如 rest 下 MQTT 离线仍唤醒 T31）。

---

## 上一版参考

- 字符串版本曾用 `v1_20260529`
- Git 标签以 **`v1.2`** 为准
