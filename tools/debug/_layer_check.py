# -*- coding: utf-8 -*-
"""分层依赖护栏（refactor_plan P1a）：把 CAT1_MODULE_FRAMEWORK §2.4 / CALL_GRAPH §2 的红线变成机器拦截。

规则（违反即计入「违规边」）：
  R1  lib/* ↛ user/* 业务模块。豁免：目标 ∈ CONFIG_DOMAIN（config 域属 L0 平台配置，lib 加载期可依赖）。
  R2  config 域（config + 10 片段 + config_manager）↛ utils / module_loader 加载期 require
      （require 环：config_manager→utils→module_loader→config_manager 会重入栈溢出）。
  R3  net_mqtt / host_uart 子模块 ↛ require 主文件（mqtt_* ↛ net_mqtt；hif_* ↛ host_uart），只能经 bind(ctx)。

基线模式：违规边先以 _layer_baseline.json 为白名单（当前 11 条反向边），默认「新增违规边即 FAIL；
基线内的边只能减少」。收缩基线：python tools/debug/_layer_check.py --save-baseline。

用法：
    python tools/debug/_layer_check.py                  # 校验
    python tools/debug/_layer_check.py --save-baseline  # 用当前违规边覆盖基线
退出码：0=无新增违规；1=有新增违规 / 基线文件缺失
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dep_graph import HARD_KINDS, build_graph, layer_of, modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path(__file__).resolve().parent / "_layer_baseline.json"

CONFIG_FRAGMENTS = ("features", "cellular", "t31x_burn", "gpio_cfg", "led_pir", "battery", "host", "net", "flags", "events")
CONFIG_DOMAIN = {"config", "config_manager", "module_loader", "runtime_power", *CONFIG_FRAGMENTS}
CONFIG_STRICT = {"config", "config_manager", *CONFIG_FRAGMENTS}  # R2 主体
UTILS_FAMILY = {"utils", "module_loader"}


def violations() -> list[tuple[str, str, str, str]]:
    """返回 (rule, src, dst, kinds)。"""
    mods = modules()
    g = build_graph(mods)
    out: list[tuple[str, str, str, str]] = []
    for s, ds in g.items():
        ls = layer_of(s, mods)
        for d, kinds in ds.items():
            ks = "/".join(kinds)
            hard = bool(set(kinds) & HARD_KINDS)
            if ls == "lib" and layer_of(d, mods) == "user" and d not in CONFIG_DOMAIN:
                out.append(("R1", s, d, ks))
            if s in CONFIG_STRICT and d in UTILS_FAMILY and hard and not (s == "config_manager" and d == "module_loader"):
                # config_manager ↛ utils/module_loader；片段同理。module_loader → config_manager 方向是允许的
                out.append(("R2", s, d, ks))
            if hard and ((s.startswith("mqtt_") and d == "net_mqtt") or (s.startswith("hif_") and d == "host_uart")):
                out.append(("R3", s, d, ks))
    return sorted(out)


def main() -> int:
    cur = violations()
    key = lambda v: f"{v[0]} {v[1]} -> {v[2]}"
    cur_keys = {key(v) for v in cur}
    if "--save-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(sorted(cur_keys), indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"baseline saved → {BASELINE.name}（{len(cur_keys)} 条）")
        return 0
    print("== 分层依赖护栏 ==")
    print(f"    R1 lib↛user业务 / R2 config域↛utils系 / R3 子模块↛主文件；当前违规边 {len(cur)} 条")
    if not BASELINE.exists():
        print(f"    [FAIL] 基线文件缺失：先运行 --save-baseline")
        return 1
    base = set(json.loads(BASELINE.read_text(encoding="utf-8")))
    new = sorted(cur_keys - base)
    gone = sorted(base - cur_keys)
    for v in cur:
        tag = "NEW " if key(v) in new else "base"
        print(f"    [{tag}] {v[0]} {v[1]} -> {v[2]} [{v[3]}]")
    if gone:
        print(f"    基线中已消失 {len(gone)} 条（请 --save-baseline 收缩）：" + ", ".join(gone))
    if new:
        print(f"\nFAILED: 新增违规边 {len(new)} 条（不得引入新的 lib→user 业务依赖 / config 域→utils / 子模块→主文件）")
        return 1
    print(f"\nALL PASS — 无新增违规边（基线 {len(base)} 条{'，可收缩 ' + str(len(gone)) if gone else ''}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
