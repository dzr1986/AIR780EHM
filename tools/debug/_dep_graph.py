# -*- coding: utf-8 -*-
"""user/ + lib/ 模块依赖图抽取（refactor_plan P1a；docs/architecture_audit.md §2 数据真源）。

边形态（五种，源码经 _luatok 去注释后识别）：
    require    require "x" / require("x")               —— 模块加载期硬依赖
    bind       require("x").bind(...)                    —— 子模块装配（也是加载期）
    loader     loader.load("x") / loader.opt(flag, "x")  —— 运行期懒加载（module_loader 缓存）
    modCall    modCall("x", "fn", ...)                   —— 运行期字符串调用
    utils-lazy svc.hostUart() / svc.uartBridge() / svc.t31xOn()（P1b 前为 utils.*）—— 跨域懒加载桥

用法：
    python tools/debug/_dep_graph.py                 # 摘要：节点/边/硬环/软环/反向边
    python tools/debug/_dep_graph.py --json out.json # 导出 {src: {dst: [kinds]}}
    python tools/debug/_dep_graph.py --mermaid       # 打印核心模块 mermaid（实线加载期 / 虚线运行期）
    python tools/debug/_dep_graph.py --scc           # 列出全部强连通分量（软环）
    python tools/debug/_dep_graph.py --reverse       # 列出 lib → user 反向边

作为库：from _dep_graph import build_graph, layer_of, sccs, reverse_edges
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _luatok import strip_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
USER, LIB = ROOT / "user", ROOT / "lib"

HARD_KINDS = {"require", "bind"}
ALL_KINDS = HARD_KINDS | {"loader", "modCall", "utils-lazy"}

RE_REQUIRE = re.compile(r'require\s*\(?\s*["\']([A-Za-z_]\w*)["\']\s*\)?')
RE_BIND = re.compile(r'require\s*\(\s*["\']([A-Za-z_]\w*)["\']\s*\)\s*\.bind')
RE_LOADER = re.compile(r'loader\.(?:load|opt)\s*\(\s*(?:["\'][^"\']*["\']\s*,\s*)?["\']([A-Za-z_]\w*)["\']')
RE_MODCALL = re.compile(r'modCall\s*\(\s*["\']([A-Za-z_]\w*)["\']')
# 跨域懒加载桥：P1b 起位于 user/svc.lua（历史在 lib/utils），两种前缀都识别以便对比前后
RE_UTILS_LAZY = re.compile(r'(?:utils|svc)\.(hostUart|uartBridge|t31xOn)\s*\(')
UTILS_LAZY_TARGET = {"hostUart": "host_uart", "uartBridge": "uart_bridge", "t31xOn": "t31x_ctrl"}


def modules() -> dict[str, Path]:
    return {p.stem: p for p in sorted(USER.glob("*.lua")) + sorted(LIB.glob("*.lua"))}


def layer_of(name: str, mods: dict[str, Path] | None = None) -> str:
    mods = mods or modules()
    p = mods.get(name)
    return "lib" if p and p.parent.name == "lib" else "user"


def build_graph(mods: dict[str, Path] | None = None) -> dict[str, dict[str, list[str]]]:
    mods = mods or modules()
    g: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for name, p in mods.items():
        code = strip_comments(p.read_text(encoding="utf-8", errors="ignore"))
        for m in RE_BIND.finditer(code):
            g[name][m.group(1)].add("bind")
        for m in RE_REQUIRE.finditer(code):
            g[name][m.group(1)].add("require")
        for m in RE_LOADER.finditer(code):
            g[name][m.group(1)].add("loader")
        for m in RE_MODCALL.finditer(code):
            g[name][m.group(1)].add("modCall")
        for m in RE_UTILS_LAZY.finditer(code):
            g[name][UTILS_LAZY_TARGET[m.group(1)]].add("utils-lazy")
    return {s: {d: sorted(k) for d, k in ds.items() if d in mods and d != s} for s, ds in g.items()}


def sccs(graph: dict[str, dict[str, list[str]]], kinds: set[str], mods: dict[str, Path]) -> list[list[str]]:
    adj = {n: [] for n in mods}
    for s, ds in graph.items():
        for d, k in ds.items():
            if set(k) & kinds:
                adj[s].append(d)
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    stack: list[str] = []
    on: set[str] = set()
    out: list[list[str]] = []
    counter = [0]

    def dfs(v: str) -> None:
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in adj[v]:
            if w not in index:
                dfs(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1 or v in adj[v]:
                out.append(sorted(comp))

    for v in list(adj):
        if v not in index:
            dfs(v)
    return sorted(out, key=len, reverse=True)


def reverse_edges(graph, mods) -> list[tuple[str, str, list[str]]]:
    return sorted((s, d, k) for s, ds in graph.items() for d, k in ds.items()
                  if layer_of(s, mods) == "lib" and layer_of(d, mods) == "user")


CORE = ["app", "host_uart", "net_mqtt", "pir_ctrl", "t31x_ctrl", "t31x_policy", "t31x_notify", "battery_guard",
        "utils", "hif_cmd", "hif_ipc", "mqtt_downlink", "mqtt_conn", "ipc_supv", "time_sync", "sound_prompt",
        "cell_boot", "usb_rndis", "host_event", "lp_wakeup", "runtime_power", "module_loader", "config_manager",
        "uart_bridge", "usb_charge", "config"]


def mermaid(graph, mods) -> str:
    lines = ["flowchart TB"]
    for s in CORE:
        for d, k in sorted(graph.get(s, {}).items()):
            if d not in CORE:
                continue
            hard = bool(set(k) & HARD_KINDS)
            arrow = "-->" if hard else "-.->"
            lines.append(f"    {s} {arrow}|{'/'.join(k)}| {d}")
    return "\n".join(lines)


def main() -> int:
    mods = modules()
    graph = build_graph(mods)
    args = sys.argv[1:]
    if "--json" in args:
        out = Path(args[args.index("--json") + 1])
        out.write_text(json.dumps(graph, indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"written {out}")
        return 0
    if "--mermaid" in args:
        print(mermaid(graph, mods))
        return 0
    hard = sccs(graph, HARD_KINDS, mods)
    soft = sccs(graph, ALL_KINDS, mods)
    rev = reverse_edges(graph, mods)
    n_edges = sum(len(ds) for ds in graph.values())
    print(f"== 依赖图：{len(mods)} 模块 / {n_edges} 边 ==")
    print(f"    硬环（require/bind）: {len(hard)}")
    for c in hard:
        print("      ", c)
    print(f"    软环（含 loader/modCall/utils-lazy）: {len(soft)}，最大 {len(soft[0]) if soft else 0} 模块")
    if "--scc" in args:
        for c in soft:
            print("      ", c)
    print(f"    反向边 lib → user: {len(rev)}")
    if "--reverse" in args or True:
        for s, d, k in rev:
            print(f"       {s} -> {d} [{','.join(k)}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
