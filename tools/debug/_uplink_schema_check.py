# -*- coding: utf-8 -*-
"""上行 JSON 字段：文档样例键集 ⊆ 代码可发字段（refactor_plan P8 护栏半）。

背景：10xx 上行由 `pubUplink{ dataType, fields = string.format('...') }` 手拼，文档 `MQTT_DOWNLINK.md`/`MQTT_PROTOCOL.md`
的 JSON 样例与代码无机器对照——1013 `stage`/`fileName` 等「文档写了、代码没发」的偏差只能人工发现（audit §18.3）。

做法（静态，不执行 Lua）：
  * 文档侧：扫 doc/mqtt/MQTT_DOWNLINK.md、MQTT_PROTOCOL.md 的 ```json 围栏块，`dataType` 为 10xx 的视为上行样例，
    取顶层键集（json 解析失败则退化为 `"key":` 正则）。同一 dataType 多个样例取并集。
  * 代码侧：user/mqtt_*.lua、net_mqtt.lua、ipc_supv.lua、hif_ipc_cloud.lua 中所有形如 JSON 键的字符串字面量
    （`"key":` 拼接片段、`CLOUD_STAT_KEYS` 清单、fmtUplink 基础键）构成「代码可发字段全集」（文件级并集，宁松勿误报）。
  * 缺口 = 文档键 − 代码全集，按 dataType 列出；以 _uplink_schema_baseline.json 为已知缺口基线，**新增缺口即 FAIL**，
    基线内缺口只报告（它们是 P10 对外接口阶段的输入）。

  * 黄金样本（架构 G 条，可选）：tests/fixtures/uplink_golden/<dataType>.json 存在时（由 _uplink_golden_capture.py 真机采集），
    额外校验「真机键集 ⊆ 代码全集」（不一致直接 FAIL，样本即真源），并把「文档键 − 真机键」作为文档漂移提示打印。

用法：
    python tools/debug/_uplink_schema_check.py                 # 校验（对照基线）
    python tools/debug/_uplink_schema_check.py --save-baseline # 用当前缺口覆盖基线
退出码：0=无新增缺口；1=有新增缺口 / 基线缺失
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _luatok import strip_comments, tokens, STR  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DOCS = (ROOT / "doc" / "mqtt" / "MQTT_DOWNLINK.md", ROOT / "doc" / "mqtt" / "MQTT_PROTOCOL.md")
CODE = [ROOT / "user" / "net_mqtt.lua", ROOT / "user" / "ipc_supv.lua", ROOT / "user" / "hif_ipc_cloud.lua"] + sorted(
    (ROOT / "user").glob("mqtt_*.lua"))
BASELINE = Path(__file__).resolve().parent / "_uplink_schema_baseline.json"
GOLDEN_DIR = Path(__file__).resolve().parent / "tests" / "fixtures" / "uplink_golden"

RE_FENCE = re.compile(r"```json\s*\n(.*?)```", re.S)
RE_KEY = re.compile(r'"([A-Za-z_]\w*)"\s*:')
RE_DT = re.compile(r'"dataType"\s*:\s*"?(1\d{3})"?')
RE_JSON_KEY_LIKE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def doc_samples() -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for d in DOCS:
        if not d.exists():
            continue
        for m in RE_FENCE.finditer(d.read_text(encoding="utf-8", errors="ignore")):
            block = m.group(1)
            dt = RE_DT.search(block)
            if not dt:
                continue
            keys: set[str] = set()
            try:
                obj = json.loads(block)
                if isinstance(obj, dict):
                    keys = set(k for k in obj.keys() if RE_JSON_KEY_LIKE.match(k))
            except Exception:
                keys = set(RE_KEY.findall(block))
            out.setdefault(dt.group(1), set()).update(keys)
    return out


def code_universe() -> set[str]:
    keys: set[str] = set()
    for f in CODE:
        text = strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
        for t in tokens(text):
            if t.kind != STR:
                continue
            body = t.value[1:-1] if len(t.value) >= 2 else ""
            # 拼接片段 ',"a":%d,"b":"%s"' → 逐键
            for k in RE_KEY.findall(body):
                keys.add(k)
            # 纯键名字面量（CLOUD_STAT_KEYS 清单、表驱动键）
            if RE_JSON_KEY_LIKE.match(body):
                keys.add(body)
    return keys


def gaps() -> dict[str, list[str]]:
    code = code_universe()
    out: dict[str, list[str]] = {}
    for dt, keys in sorted(doc_samples().items()):
        miss = sorted(k for k in keys if k not in code)
        if miss:
            out[dt] = miss
    return out


def golden_samples() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    if not GOLDEN_DIR.is_dir():
        return out
    for p in sorted(GOLDEN_DIR.glob("1*.json")):
        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
            out[str(obj.get("dataType") or p.stem)] = list(obj.get("keys") or [])
        except Exception:
            continue
    return out


def golden_check(samples_doc: dict[str, set[str]]) -> int:
    """真机键 ⊆ 代码全集（FAIL 计数）；文档键 − 真机键 仅提示。"""
    gold = golden_samples()
    if not gold:
        print("    黄金样本：无（tests/fixtures/uplink_golden/ 为空；真机 MQTT_CFG.golden_tap=true 后跑 _uplink_golden_capture.py）")
        return 0
    uni = code_universe()
    fails = 0
    for dt, keys in sorted(gold.items()):
        miss = [k for k in keys if k not in uni]
        for k in miss:
            fails += 1
            print(f"    [FAIL] 黄金样本 {dt} 含键 `{k}`，代码可发字段全集里没有（样本过期或代码删字段未重采）")
        drift = sorted(samples_doc.get(dt, set()) - set(keys))
        if drift:
            print(f"    [info] {dt}: 文档样例有、真机样本无 {drift}（可能为可选字段，或文档漂移）")
    print(f"    黄金样本 {len(gold)} 个 dataType 已比对")
    return fails


def main() -> int:
    cur = gaps()
    if "--save-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(cur, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"baseline saved → {BASELINE.name}（{sum(len(v) for v in cur.values())} 键 / {len(cur)} dataType）")
        return 0
    print("== 上行字段：文档样例键 ⊆ 代码可发字段 ==")
    samples = doc_samples()
    print(f"    文档上行样例 {len(samples)} 个 dataType；代码可发字段全集 {len(code_universe())} 键")
    if not BASELINE.exists():
        print("    [FAIL] 基线缺失：先 --save-baseline")
        return 1
    base = json.loads(BASELINE.read_text(encoding="utf-8"))
    new = 0
    for dt, miss in sorted(cur.items()):
        known = set(base.get(dt, []))
        for k in miss:
            tag = "base" if k in known else "NEW "
            if k not in known:
                new += 1
            print(f"    [{tag}] {dt}: 文档有、代码不发 `{k}`")
    gone = {dt: sorted(set(v) - set(cur.get(dt, []))) for dt, v in base.items()}
    gone = {dt: v for dt, v in gone.items() if v}
    if gone:
        print(f"    基线中已补齐（请 --save-baseline 收缩）：{gone}")
    gold_fails = golden_check(samples)
    if new or gold_fails:
        print(f"\nFAILED: 新增文档-代码字段缺口 {new} 个 / 黄金样本越界键 {gold_fails} 个（文档新写的上行字段代码未实现，或代码删了字段未改文档/未重采样本）")
        return 1
    total = sum(len(v) for v in cur.values())
    print(f"\nALL PASS — 无新增缺口（基线登记 {total} 键，属 P10 对外接口待办）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
