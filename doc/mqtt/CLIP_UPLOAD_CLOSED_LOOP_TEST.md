# 人形检测录像上传闭环测试（T31 TF 卡 ↔ 腾讯云 uploadVideo）

> **实测时间**：2026-08-19 22:30（CST）  
> **设备**：T31 COM7 @ 115200 · 国标 ID `34020000001310989442`  
> **上传地址**：`http://43.136.55.143:7003/admin/api/v1/uploadVideo`  
> **源码**：`ipc_device_ini/app/upload/` · 编译参数见 WSL `ipc_device_ini/Makefile`

---

## 1. 结论摘要

| 场景 | TF 卡 `upload_clip/` | 后台 7003 | 说明 |
|------|----------------------|-----------|------|
| **信号差 / 出网失败** | `.ts` 堆积，`.st` 为 `pending` 或 `failed` | 无对应记录 | 抽片成功，HTTP 三轮 URL 均 `Couldn't connect` |
| **信号好 / 上传成功** | `.st` 为 `uploaded` 且带 `http_path`；**.ts 仍可能保留 3 天** | 有同名 key 的 TS | 易误判为「没上传」，实为 `keep_uploaded_days=3` 未删媒体 |
| **本次实测（4G 正常）** | 470 对 `.ts`/`.st`（**429 failed + 17 uploaded**） | 13 条 dynamic | 最近 13 条 key **100% 重合**；更早 17 条为信号差时期失败堆积 |

**关键认知**：不能只看 `upload_clip/` 里有没有 `.ts`，必须读 `.st` 的 `status` 和 `http_path`，再与 `GET /admin/api/v1/videos` 对比。

---

## 2. 端到端数据流

```text
人形检测 (MD)
  → clip_upload_request() 抽片 [start-15s, end+15s]
  → /mnt/sdcard/media/vi0/upload_clip/{deviceId}-{date}-{uploadTsMs}.ts
  → 旁路 .st 状态文件（pending → uploading → uploaded/failed）
  → HTTP POST multipart 到 uploadVideo（type=1 侦测 / type=2 回放）
  → 成功：.st.status=uploaded，写入 http_path；TS 按 keep_uploaded_days 决定是否删除
  → 失败：保留 TS，retries++，30s 后重试（最多 max_retries=5）
```

### 2.1 上传 URL 优先级（`video_http_upload.c`）

1. 配置项 `url`（`syscfg` / 编译 `-DCLIP_UPLOAD_URL`）
2. `CLIP_UPLOAD_PRIMARY_URL` → `http://43.136.55.143:7003/admin/api/v1/uploadVideo`
3. `CLIP_UPLOAD_PRIMARY_ALT_URL` → `http://43.136.55.143/admin/api/v1/uploadVideo`（Nginx 80）
4. `CLIP_UPLOAD_FALLBACK_URL` → 编译时指定，默认南京 `112.86.146.218:7003`

WSL 编译示例：

```bash
cd /mnt/d/项目/linfeng/AIR780EHM/ipc_device_ini
make CLIP_UPLOAD_URL=http://43.136.55.143:7003/admin/api/v1/uploadVideo \
     CLIP_UPLOAD_FALLBACK_URL=http://43.136.55.143:7003/admin/api/v1/uploadVideo
```

### 2.2 文件名与对比 key

| 位置 | 文件名格式 | 对比用 key |
|------|------------|------------|
| 设备 TF | `{deviceId}-{YYYYMMDD}-{uploadTsMs}.ts` | `{deviceId}-{YYYYMMDD}-{uploadTsMs}` |
| 后台 | `{key}-{serverSaveStamp}.ts` | 同上 `{deviceId}-{YYYYMMDD}-{uploadTsMs}` |

示例：

- 设备：`34020000001310989442-20260819-1787149847373.ts`
- 后台：`34020000001310989442-20260819-1787149847373-20260819223105193.ts`
- key：`34020000001310989442-20260819-1787149847373`

### 2.3 `.st` 状态文件字段

```ini
status=uploaded          # pending | uploading | uploaded | failed
file=34020000001310989442-20260819-1787149847373.ts
device_id=34020000001310989442
message_id=person        # 人形检测触发
upload_ts=1787149847373
http_path=/apps/video/dynamic/34020000001310989442-20260819-1787149847373-20260819223105193.ts
start=1787149832
end=1787149862
type=1                   # 1=侦测 2=回放
retries=0
updated=1787149863
```

---

## 3. 实测快照（2026-08-19）

### 3.1 COM7 设备侧

```text
目录：/mnt/sdcard/media/vi0/upload_clip/
.ts / .st 数量：470
  status=uploaded：17
  status=failed：429
  status=pending：0
网络：eth0 10.23.139.118，网关 10.23.139.119（Cat.1 4G）
ping 43.136.55.143：0% 丢包，RTT 43–79ms
```

抽样 `.st`（已上传但仍留 TS）：

```ini
status=uploaded
http_path=/apps/video/dynamic/34020000001310989442-20260819-1787149847373-20260819223105193.ts
type=1
message_id=person
```

**原因**：默认 `keep_uploaded_days=3`（`clip_upload_worker.c`），上传成功后 **不立即删 `.ts`**，仅 `keep_uploaded_days=0` 时立刻 `unlink(ts)`。

### 3.2 后台 API

```bash
curl -s "http://43.136.55.143:7003/admin/api/v1/videos?limit=200"
curl -s "http://43.136.55.143:7003/admin/api/v1/health"
```

2026-08-19 22:33 自动对比（`tools/debug/clip_closed_loop_compare.py`）：

- 后台 **13 条**，设备最近 30 条 key 中 **13 条 overlap（100%）**
- **17 条 device_only**：均为更早时段 `status=failed` 的历史堆积（约 08:00–14:00 UTC 段），后台无记录
- 完整 JSON：`doc/_audit/clip_closed_loop.json`

| key（截断显示） | 后台 mtime | 大小 |
|-----------------|------------|------|
| …-1787149918198 | 22:32 附近 | ~0.86MB |
| …-1787149847373 | 22:31:05 | 0.86MB |
| …-1787149763364 | 22:29:41 | 0.96MB |
| …（共 12 条近期） | 22:11–22:32 | 0.94–1.12MB |

### 3.3 信号差时的历史日志（参考）

`T31X_4GCAT/20260818_量产/tools/_logs/` 中可见：

```text
[clip_upload] extract ok -> .../upload_clip/34020000001310989442-20260817-....ts
[clip_upload] http upload curl fail url=http://43.136.55.143:7003/...: Couldn't connect to server
（依次尝试 7003 / 80 / 南京 fallback，均失败）
```

典型原因：USB 插电脑时 T31 走 USB 出网失败；或 4G 未就绪。

---

## 4. 闭环测试步骤

### 4.1 前置条件

- [ ] T31 串口 **COM7 115200** 未被 Xshell 占用
- [ ] Cat.1 已注网，T31 `ping 43.136.55.143` 通
- [ ] 若测 4G：拔掉 USB 或确认不走 `usbNetdev=0` 的 USB 路由
- [ ] 服务器 7003 安全组已放行

### 4.2 A 组：信号差（预期 TF 堆积、后台无记录）

1. 制造弱网：屏蔽天线 / 未插 SIM / USB 占网
2. 触发人形检测（PIR + MD）
3. COM7 确认抽片：

   ```bash
   ls -la /mnt/sdcard/media/vi0/upload_clip/*.ts | tail -5
   cat /mnt/sdcard/media/vi0/upload_clip/<最新>.ts.st
   ```

4. 期望：`.st` 为 `pending` 或 `failed`，`http_path` 为空
5. 后台：`curl .../videos` **不应**出现新 key

### 4.3 B 组：信号恢复（预期补传、后台出现）

1. 恢复 4G，`ping 43.136.55.143` 正常
2. 等待 clip worker 重试（失败 30s 间隔，启动时 `clip_store_scan_retry` 也会扫盘）
3. 期望：`.st` → `uploaded`，`http_path` 有值
4. 后台：同 key 出现在 `/admin/api/v1/videos`

### 4.4 C 组：信号好即时上传（预期 TF 仍有 TS 但已 uploaded）

1. 正常 4G 下触发人形
2. 对比脚本（本仓库）：

   ```powershell
   python tools/debug/clip_closed_loop_compare.py
   ```

3. 判定标准：
   - **闭环成功**：最近 N 条 key 在 `overlap` 中，且 `.st` 为 `uploaded`
   - **假阳性堆积**：`.ts` 存在但 `.st.status=uploaded` → 已上传，仅未删 TS

### 4.5 对比命令速查

**设备（COM7 shell）**

```sh
ls -1 /mnt/sdcard/media/vi0/upload_clip/*.ts 2>/dev/null | wc -l
ls -1 /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | wc -l
grep -l '^status=uploaded' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | wc -l
grep -l '^status=failed' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | wc -l
grep -h '^file=' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | tail -20
cat /mnt/sdcard/media/vi0/upload_clip/<file>.ts.st
```

**后台（无需 SSH，HTTP 即可）**

```powershell
curl.exe -s "http://43.136.55.143:7003/admin/api/v1/videos?limit=200&type=1"
curl.exe -s "http://43.136.55.143:7003/admin/api/v1/health"
```

**SSH（可选，本机需 `~/.ssh/id_ed25519`）**

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519 ubuntu@43.136.55.143
# 服务目录见 video_upload_server/README.md，incoming/dynamic/
```

---

## 5. 工具脚本

| 脚本 | 作用 |
|------|------|
| `tools/debug/_com7_probe.py` | COM7 登录 + 执行 shell 命令 |
| `tools/debug/_com7_status.py` | 轻量 COM7 命令发送 |
| `tools/debug/clip_closed_loop_compare.py` | 自动：设备 .st 统计 + 后台 API 对比，输出 JSON |
| `doc/_audit/clip_upload_full_audit.json` | 最近一次自动对比结果 |
| `video_upload_server/simulate_upload.py` | 模拟 POST 验证 7003 |

---

## 6. 常见问题

### Q1：TF 里很多 `.ts`，是不是都没上传？

不一定。先看 `.st`：

- `status=uploaded` + 有 `http_path` → **已上传**，TS 因 `keep_uploaded_days=3` 暂留
- `status=failed/pending` → **未上传或重试中**

### Q2：1013 成功但后台没有片？

1013 只表示 Cat.1 已把 `AT+UPLOADVIDEO` 交给 T31 排队；HTTP 上传是第二步。USB 占网时常见抽片成功、HTTP 失败。

### Q3：如何减少 TF 占用？

- 编译/配置 `keep_uploaded_days=0`（上传后立即删 TS）
- 或定期 `clip_store_cleanup` 清理过期 uploaded/failed

### Q4：`CLIP_UPLOAD_FALLBACK_URL` 填什么？

现网腾讯云：`http://43.136.55.143:7003/admin/api/v1/uploadVideo`  
与 PRIMARY 相同即可作第三备；原默认南京地址仅在现网 7003 不可达时使用。

---

## 7. 判定矩阵

| .st status | http_path | 后台有 key | .ts 存在 | 判定 |
|------------|-----------|------------|----------|------|
| uploaded | 有 | 有 | 有/无 | ✅ 闭环成功（TS 可能未删） |
| uploaded | 有 | 无 | 有 | ⚠️ 设备认为成功，需查服务器/路径 |
| pending/failed | 无 | 无 | 有 | ⏳ 待传或信号差 |
| failed | 无 | 无 | 有 | ❌ 超过 max_retries，需人工介入 |
| pending | 无 | 有 | 无 | ⚠️ 异常，查重复上传或手工删 TS |

---

## 8. 补传逻辑修复（2026-08-19）

### 8.1 根因

原 `clip_store_scan_retry()` 对 **`status=failed` 且 `retries >= max_retries(5)`** 的条目直接 `continue`，永不重试。  
worker 空闲时也只 `cleanup`，**不会周期性扫盘**，导致信号恢复后 429 条历史 failed 永久堆积。

### 8.2 修改（`ipc_device_ini/app/upload/`）

| 文件 | 改动 |
|------|------|
| `clip_store.c` | 新增 `clip_store_reset_exhausted_failed()`：将 failed+有TS 重置为 pending/retries=0 |
| `clip_upload_worker.c` | **init** 时 cooldown=0 全量 reset + scan；**空闲每 60s** 再 scan（failed cooldown=300s） |

### 8.3 烧录后实测（约 45s）

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| status=failed | 429 | **0** |
| status=pending | 0 | 413（补传队列中） |
| status=uploaded | 17 | 36 |
| 后台 videos | 13 | **32** |

补传进行中；队列上限 8 条并发，其余 pending 会逐步消化。

### 8.4 编译与烧录

```bash
# WSL 编译
cd /mnt/d/项目/linfeng/AIR780EHM/ipc_device_ini
CLIP_UPLOAD_URL='http://43.136.55.143:7003/admin/api/v1/uploadVideo' \
CLIP_UPLOAD_FALLBACK_URL='http://43.136.55.143:7003/admin/api/v1/uploadVideo' \
./run_t31x.sh -j4
```

```powershell
# COM7 烧录（需关闭 SecureCRT 占用 COM7）
python T31X_4GCAT/20260818_量产/tools/t31x/t31x_lrz_push.py `
  --local D:\项目\linfeng\AIR780EHM\ipc_device_ini\t31x_ipc --restart --port COM7
```

---

## 9. 相关文档
- [../video_upload_server/README.md](../../video_upload_server/README.md) — 7003 服务部署
- [../ipc_device_ini/docs/mqtt_2013_1013_clip_upload_flow.md](../../../ipc_device_ini/docs/mqtt_2013_1013_clip_upload_flow.md) — T31 抽片实现细节
