# -*- coding: utf-8 -*-
"""分层依赖护栏（refactor_plan P1a）：把 CAT1_MODULE_FRAMEWORK §2.4 / CALL_GRAPH §2 的红线变成机器拦截。

规则（违反即计入「违规边」）：
  R1  lib/* ↛ user/* 业务模块。豁免：目标 ∈ CONFIG_DOMAIN（config 域属 L0 平台配置，lib 加载期可依赖）。
  R2  config 域（config + 10 片段 + config_manager）↛ utils / module_loader 加载期 require
      （require 环：config_manager→utils→module_loader→config_manager 会重入栈溢出）。
  R3  net_mqtt / host_uart 子模块 ↛ require 主文件（mqtt_* ↛ net_mqtt；hif_* ↛ host_uart），只能经 bind(ctx)。
  R4  AT 协议层（host_uart + hif_*）↛ 业务层（BIZ_LAYER：net_mqtt / pir_ctrl / battery_guard / t31x_policy /
      t31x_notify / time_sync / sound_prompt / fota_svc / ipc_supv / app / lp_wakeup / host_event / vbat），
      任何形态（require / loader / modCall）都算；业务联动应经 sys 事件由 app 桥接或经 ctx/provider 注入。
      t31x_ctrl（协处理器电源）视为基础设施，不在 BIZ_LAYER。2026-09-05 立基线 15 条，同日经 bizCall provider 收敛至 0。
  R5  vendor 锁（架构 I 条）：lib/sys.lua、lib/libfota2.lua 为合宙原厂脚本（Luatools 要求留在 lib/ 目录，不能物理
      挪到 vendor/），以 _vendor_lock.json 的 sha256 锁定；内容变更即 FAIL——改动必须显式 --save-baseline 并在
      LUA_MODULES.md「vendor」段登记原因。

基线模式：违规边先以 _layer_baseline.json 为白名单（当前 11 条反向边），默认「新增违规边即 FAIL；
基线内的边只能减少」。收缩基线：python tools/debug/_layer_check.py --save-baseline。

用法：
    python tools/debug/_layer_check.py                  # 校验
    python tools/debug/_layer_check.py --save-baseline  # 用当前违规边覆盖基线
退出码：0=无新增违规；1=有新增违规 / 基线文件缺失
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dep_graph import HARD_KINDS, build_graph, layer_of, modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path(__file__).resolve().parent / "_layer_baseline.json"
VENDOR_LOCK = Path(__file__).resolve().parent / "_vendor_lock.json"
VENDOR_FILES = ("lib/sys.lua", "lib/libfota2.lua")  # 合宙原厂脚本；勿动

CONFIG_FRAGMENTS = ("features", "cellular", "t31x_burn", "gpio_cfg", "led_pir", "battery", "host", "net", "flags", "events")
CONFIG_DOMAIN = {"config", "config_manager", "module_loader", "runtime_power", *CONFIG_FRAGMENTS}
CONFIG_STRICT = {"config", "config_manager", *CONFIG_FRAGMENTS}  # R2 主体
UTILS_FAMILY = {"utils", "module_loader"}
BIZ_LAYER = {"net_mqtt", "pir_ctrl", "battery_guard", "t31x_policy", "t31x_notify", "time_sync", "sound_prompt",
             "fota_svc", "ipc_supv", "app", "lp_wakeup", "host_event", "vbat"}


def is_at_layer(name: str) -> bool:
    return name == "host_uart" or name.startswith("hif_")


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
            if is_at_layer(s) and d in BIZ_LAYER:
                out.append(("R4", s, d, ks))
    return sorted(out)


def vendor_hashes() -> dict[str, str]:
    return {f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in VENDOR_FILES if (ROOT / f).exists()}


def vendor_violations() -> list[str]:
    if not VENDOR_LOCK.exists():
        return ["R5 _vendor_lock.json 缺失：先运行 --save-baseline"]
    lock = json.loads(VENDOR_LOCK.read_text(encoding="utf-8"))
    out = []
    for f, h in vendor_hashes().items():
        if lock.get(f) != h:
            out.append(f"R5 vendor 文件 {f} 内容与锁不一致（原厂脚本勿动；确需改动请 --save-baseline 并在 LUA_MODULES.md vendor 段登记）")
    for f in lock:
        if f not in VENDOR_FILES or not (ROOT / f).exists():
            out.append(f"R5 vendor 锁内文件 {f} 已不存在/不在 VENDOR_FILES")
    return out


def main() -> int:
    cur = violations()
    key = lambda v: f"{v[0]} {v[1]} -> {v[2]}"
    cur_keys = {key(v) for v in cur}
    if "--save-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(sorted(cur_keys), indent=1, ensure_ascii=False), encoding="utf-8")
        VENDOR_LOCK.write_text(json.dumps(vendor_hashes(), indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"baseline saved → {BASELINE.name}（{len(cur_keys)} 条）+ {VENDOR_LOCK.name}（{len(VENDOR_FILES)} 个 vendor 文件）")
        return 0
    print("== 分层依赖护栏 ==")
    print(f"    R1 lib↛user业务 / R2 config域↛utils系 / R3 子模块↛主文件 / R4 AT层↛业务层；当前违规边 {len(cur)} 条")
    if not BASELINE.exists():
        print(f"    [FAIL] 基线文件缺失：先运行 --save-baseline")
        return 1
    vend = vendor_violations()
    for m in vend:
        print(f"    [FAIL] {m}")
    base = set(json.loads(BASELINE.read_text(encoding="utf-8")))
    new = sorted(cur_keys - base)
    gone = sorted(base - cur_keys)
    for v in cur:
        tag = "NEW " if key(v) in new else "base"
        print(f"    [{tag}] {v[0]} {v[1]} -> {v[2]} [{v[3]}]")
    if gone:
        print(f"    基线中已消失 {len(gone)} 条（请 --save-baseline 收缩）：" + ", ".join(gone))
    if new or vend:
        print(f"\nFAILED: 新增违规边 {len(new)} 条 / vendor 锁 {len(vend)} 条（不得引入新的 lib→user 业务依赖 / config 域→utils / 子模块→主文件 / AT 层→业务层 / 改动原厂脚本）")
        return 1
    print(f"\nALL PASS — 无新增违规边（基线 {len(base)} 条{'，可收缩 ' + str(len(gone)) if gone else ''}）；vendor 锁 {len(VENDOR_FILES)} 文件一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
