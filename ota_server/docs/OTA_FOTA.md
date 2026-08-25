# 4G 模组 FOTA 规则

对照模组 HTTP 升级接口（libfota2）整理的服务端规则。管理台操作见 [OTA_ADMIN.md](OTA_ADMIN.md)，真机云端升级见 [OTA_REAL_DEVICE.md](OTA_REAL_DEVICE.md)，闭环实测见 [OTA_CLOSED_LOOP.md](OTA_CLOSED_LOOP.md)。

参考：[模组 FOTA](https://docs.openluat.com/air780epm/luatos/app/ota/fota/)、[自建服务器](https://docs.openluat.com/air780epm/luatos/app/ota/fota3rd/)、[libfota2](https://docs.openluat.com/osapi/ext/libfota2/)。

---

## 1. HTTP 约定

设备用 GET 拉包。URL 不以 `###` 开头时，模组会自动附加 `imei`、`firmware_name`、`version`、`project_key`。

| 服务器响应 | 模组行为 |
|------------|----------|
| **200 / 206**，body 为升级文件且 **长度 &gt; 0** | 下载成功（回调 0），随后 `rtos.reboot()` |
| **200 / 206 但 body 为空** | 回调 4，升级失败 |
| **≥ 300**（本服务默认 404） | 无需升级 / 已最新（回调 4） |

本服务：**文件不存在或 0 字节一律不返回 200**；200 响应带 `Content-Length` 与 `Accept-Ranges: bytes`，支持 `Range` → **206**。

拉包地址：

```text
GET /api/site/firmware_upgrade?imei=&project_key=&firmware_name=&version=
```

MQTT 2004 下发的 `url` 以 `?` 结尾，由模组拼参（`full_url=0`）。

---

## 2. 脚本 / 内核

固件分 **core** 与 **script**。仅改脚本用全量 `.bin`；同时升内核必须用差分包。不同分区后缀的 `.soc`（`_1` / `_2`）不能互升。

脚本版本 `A.B.C`：B 无意义。允许升级当且仅当：

1. `A2 == A1` 且 `C2 > C1`
2. 或 `A2 > A1` 且 `C2 >= C1`

平台版本 `core.A.C`（如 `2044.001.010`）额外禁止 **core 回退**；core 升高且 A/C 不变视为只升内核。

错误差分（内核升了、脚本版本反而变低）会导致设备反复拉包。本服务对此类版本关系直接拒绝匹配。

---

## 3. 循环升级保护

同一 IMEI 在**设备上报版本未升高**的情况下，连续 6 次拿到同一目标包，自动 **禁止升级**，备注写明原因。

到 **我的设备** 点禁止按钮变为允许前，请确认差分包已修正。解除禁止会清零计数。

---

## 4. 固件投放

| 配置 | 效果 |
|------|------|
| 升级全部设备 | 项目下所有 IMEI 可匹配 |
| 指定设备 | 仅列表内 IMEI |
| 两者都不配 | 谁都升不了 |
| 允许升级 = 否 | 该固件不下发 |
| 设备禁止升级 | 该 IMEI 一律 ≥300 |

一个 IMEI 只能属于一个项目。首次带 `project_key` 请求会自动归属；已属其他项目 → **25**。

---

## 5. 触发方式

| 方式 | 说明 |
|------|------|
| 设备开机 / 定时 `libfota2.request` | 自己来拉，适合常电或 PSM 唤醒后检查 |
| 管理台 **固件升级** / MQTT 2004 | 立刻通知设备去拉本服务 URL |
| 闭环测试 | 模拟设备：准备包 → 拉包 → 上报 1004 |

PSM 设备必须等升级回调结束后再休眠，否则下载未完成会失败。
