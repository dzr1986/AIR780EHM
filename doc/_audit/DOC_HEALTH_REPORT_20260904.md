# 文档健康报告（2026-09-04 起，逐轮追加）

> 定位：`doc/manual/README.md` §4.2「可观测」承诺的台账。每轮文档维护在文末追加一节，
> 只记录**护栏结果、发现的结构性问题与处置**；知识本体不写在这里（写进对应主题真源）。
> 复查命令：`python tools/debug/run_all_checks.py`（第 5/6 项为文档护栏）+ `python doc/_tools/doc_registry_check.py`。

---

## 第 1 轮 · 2026-09-04（主题归档后首轮体检）

### 1.1 结论

| 项 | 结果 |
|----|------|
| md 文件数 / 文件级链接数 | 默认口径（不含 archive/_audit）127 → **131** / 1 423；全量口径 146 / 1 459 |
| 互链断链 | 修护栏前「假绿 0」；修护栏后 **33 条真实断链** → 处置后 **0** |
| 导航孤岛 / 登记缺口 | 0（`_doc_index_check` / `doc_registry_check` 均 PASS） |
| doc ↔ 代码 `.lua` 引用 | 现状类 0 需修复（`_doc_module_ref_check`） |

### 1.2 发现的结构性问题（均已处置）

| # | 问题 | 根因 | 处置 |
|---|------|------|------|
| 1 | `_doc_md_link_check.py` 在 Linux/macOS 上把**全部 1 386 条链接判为「越界」**，从而永远 PASS（假绿） | 越界判定手拼 Windows 分隔符 `"\\"` 做前缀比较，POSIX 下前缀永不匹配 | 改用 `Path.relative_to` 按路径组件判定（`is_within_root`），跨平台一致 |
| 2 | 主题归档提交 `aebceab` 把 4 篇发布文档移入 `doc/release/`，但 `.gitignore` 的 `release/`（本意忽略根目录发布包）**未根锚定**，新位置被忽略 → 文件从仓库消失，只存在于作者本机 | `.gitignore` 模式无 `/` 前缀 → 匹配任意层级 | `.gitignore` 改 `/release/`；从 `aebceab^` 恢复 `CAT1_FLASH_FLOW` / `CAT1_FLASH_TOOL` / `CAT1_USB_RNDIS_CFG_CRASH_FLASH` / `RELEASE_v1.2` 并重算相对链接 |
| 3 | 同一提交把 4 篇历史留档移入 `doc/_audit/`，而 `.gitignore` 仍有 `doc/_audit/`（旧「临时报告目录」语义）→ 同样丢失；`WORK_MODE_BATTERY_20PCT.md` 被 8 篇 power 主题文档共 13 处引用 | `_audit/` 语义已从「临时」变为「历史留档」（`doc/README.md` 登记），忽略规则未同步 | `.gitignore` 改为只忽略 `doc/_audit/*.json`（工具 JSON 快照）；恢复 `WORK_MODE_BATTERY_20PCT` / `FUNCTION_NAME_MAP` / `CAT1_TOOLCHAIN_TEST_REPORT` / `MQTT_AUTOTEST_LOG_862323084068124_20260818` 并重算链接 |
| 4 | `doc/manual/README.md` §4.2 引用的本报告从未入库（在被忽略目录中创建） | 同 #3 | 本文件即补齐 |
| 5 | `_doc_module_ref_check.py` 输出的 `_doc_ref_report.txt`（已入库）路径分隔符随运行平台漂移，Windows/Linux 交替运行产生无意义 diff | `os.path.relpath` 未归一 | 报告路径统一 posix `/` |

### 1.2b 同轮追加：文档 ↔ 代码口径漂移（均已处置）

| # | 问题 | 处置 |
|---|------|------|
| 6 | 10 处「当前版本 001.000.151 / 140」而代码已 154（升版只改 main.lua） | 统一到当前版本；新增 `tools/debug/_doc_version_check.py`（run_all_checks 第 9 项）锚定 10 处现状口径 |
| 7 | `CONFIG.md` 无「键在哪定义、谁在读」索引；9 处段落头仍写 `(config.lua)`，实际已拆到 `user/host.lua` 等片段；`config.mk`/`config.lua`/9 个片段头注释仍写「config/ 子目录」 | `_config_key_check.py --write-doc` 从代码生成 39 键索引写入标记块并校验漂移；段落头/注释全部纠正 |
| 8 | `CODE_LAYERING_ARCHITECTURE §5.P4-1` 写 gpio_util「已兼容 camel/snake」，代码在 9bcfc78 已回归 → 文档反向掩盖 P0 bug | 代码修复 + `_gpio_opts_check.py` 护栏 + 文档补回归史 |
| 9 | `T31X_POLICY_GATE.md:49` 与代码同写未注册键 `allow_mqtt_offline_wake_when_usb` | 代码/文档同改为已注册键 `block_mqtt_offline_wake_when_usb` |

### 1.3 经验沉淀（写入护栏 / 规范）

- **护栏必须在 CI 用的平台上至少跑过一次**：仅在 Windows 上验证的路径逻辑在 Linux 上呈现为「静默全通过」，比 FAIL 更危险。
- **`.gitignore` 忽略目录名时一律根锚定**（`/release/` 而非 `release/`），否则文档目录同名即被吞。
- **目录语义变更时同步检查忽略规则**：`_audit/` 从「临时」变「留档」，第一个受害者就是它自己的登记。
- **文档写「已修复」不等于代码仍修着**：重命名/瘦身提交会悄悄删掉兼容读；凡是「兼容两种写法」的承诺都应有静态护栏而非只靠文案。
- **版本号/键索引这类可从代码推导的内容，一律由脚本生成 + 校验**，手写必漂移。
- 恢复历史文件时不能直接 `git show` 落盘：主题归档后相对链接全部失效，需按 basename 索引重算（本轮用一次性脚本，40 处链接重定向，结果由互链护栏校验）。

### 1.4 复查

```
python tools/debug/_doc_md_link_check.py --no-exclude-archive   # 含 archive/_audit 全量
python tools/debug/run_all_checks.py                              # 9 项，含第 7/9 项文档同步护栏
python doc/_tools/doc_registry_check.py
```
