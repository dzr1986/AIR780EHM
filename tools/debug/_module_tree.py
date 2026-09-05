# -*- coding: utf-8 -*-
"""输出 user/lib 模块行数树，供发布前对比漂移。

用法：
  python tools/debug/_module_tree.py
  python tools/debug/_module_tree.py --save-baseline
  python tools/debug/_module_tree.py --diff
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path(__file__).resolve().parent / "_module_tree_baseline.json"

PREFIX_GROUPS = (
    ("host_uart", "host_uart"),
    ("net_mqtt", "net_mqtt"),
)


def line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def collect() -> dict:
    out: dict = {"date": date.today().isoformat(), "user": {}, "lib": {}, "totals": {}}
    grand = 0
    for dir_name in ("user", "lib"):
        d = ROOT / dir_name
        rows = {f.relative_to(d).as_posix(): line_count(f) for f in sorted(d.rglob("*.lua"))}
        out[dir_name] = rows
        total = sum(rows.values())
        out["totals"][dir_name] = {"files": len(rows), "lines": total}
        grand += total
    out["totals"]["all"] = grand
    return out


def print_tree(data: dict) -> None:
    for dir_name in ("user", "lib"):
        rows = list(data[dir_name].items())
        rows.sort(key=lambda x: (-x[1], x[0]))
        total = data["totals"][dir_name]["lines"]
        nfiles = data["totals"][dir_name]["files"]
        print(f"=== {dir_name}/  ({nfiles} files, {total} lines) ===")
        seen: set[str] = set()
        if dir_name == "user":
            for prefix, _ in PREFIX_GROUPS:
                matched = [(n, f) for f, n in rows if prefix in f]
                if not matched:
                    continue
                sub = sum(n for n, _ in matched)
                print(f"  {prefix}*  ({len(matched)} files, {sub} lines)")
                for n, f in sorted(matched, key=lambda x: (-x[0], x[1])):
                    print(f"    {n:4}  {f}")
                seen.update(f for _, f in matched)
        others = [(n, f) for f, n in rows if f not in seen]
        if others:
            ototal = sum(n for n, _ in others)
            print(f"  other ({len(others)} files, {ototal} lines)")
            for n, f in sorted(others, key=lambda x: (-x[0], x[1])):
                if n >= 80:
                    print(f"    {n:4}  {f}")
        print()
    print(f"total lines (user+lib): {data['totals']['all']}")


def save_baseline(data: dict) -> None:
    BASELINE.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"baseline saved → {BASELINE.name} ({data['date']})")


def diff_baseline(data: dict) -> int:
    if not BASELINE.is_file():
        print(f"no baseline: run --save-baseline first", file=sys.stderr)
        return 1
    old = json.loads(BASELINE.read_text(encoding="utf-8"))
    fail = 0
    print(f"baseline date: {old.get('date')} → current: {data['date']}")
    for dir_name in ("user", "lib"):
        old_m = old.get(dir_name) or {}
        new_m = data.get(dir_name) or {}
        all_files = sorted(set(old_m) | set(new_m))
        changed = []
        for f in all_files:
            o, n = old_m.get(f), new_m.get(f)
            if o != n:
                changed.append((f, o, n))
        if changed:
            print(f"\n=== {dir_name}/ drift ({len(changed)} files) ===")
            for f, o, n in sorted(changed, key=lambda x: abs((x[2] or 0) - (x[1] or 0)), reverse=True):
                if o is None:
                    print(f"  + {f}: {n} lines (new)")
                elif n is None:
                    print(f"  - {f}: was {o} lines (removed)")
                else:
                    delta = n - o
                    print(f"  ~ {f}: {o} → {n} ({delta:+d})")
                fail += 1
    ot, nt = old.get("totals", {}).get("all"), data["totals"]["all"]
    if ot != nt:
        print(f"\ntotal: {ot} → {nt} ({nt - ot:+d})")
    if not fail:
        print("\nno file-level drift")
    return 1 if fail else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="user/lib 行数树")
    ap.add_argument("--save-baseline", action="store_true")
    ap.add_argument("--diff", action="store_true")
    args = ap.parse_args()
    data = collect()
    print_tree(data)
    if args.save_baseline:
        save_baseline(data)
    if args.diff:
        return diff_baseline(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
