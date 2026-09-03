#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""host_uart cmd/ipc 子模块 bind 头生成与 drift 校验。

用法：
  python tools/debug/_gen_bind_header.py --check-all
  python tools/debug/_gen_bind_header.py --emit user/hu_cmd_pir.lua
  python tools/debug/_gen_bind_header.py --emit-all
  python tools/debug/_gen_bind_header.py --scan user/hu_cmd_link.lua

真源 spec：tools/debug/bind_header_specs.json
延迟挂载（须 wrapper，勿 local 快照）：parseIpcStat / parseTfCard / hostQuery / idCfg 等。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
USER = ROOT / "user"
SPECS_PATH = Path(__file__).resolve().parent / "bind_header_specs.json"

# 扫描 body 时忽略的 bind 头区域上限行数
MAX_HEADER_SCAN = 40

# 合并到同一 local 行的字段组（顺序保留）
C_GROUPS: list[list[str]] = [
    ["state", "hooks", "SYS_EVT", "E"],
    ["rspOnly", "rspBody", "rspFmt"],
    ["rspLine", "rspLineOk", "okTail"],
    ["modCall", "loader", "utils"],
    ["uartAcquire", "uartRelease"],
    ["encodeHex", "decodeHex"],
    ["hostNowMs", "t31xUartOff"],
    ["usbInserted", "usbBlockHost"],
    ["uart_bridge", "CRLF"],
    ["hostUsbCfg", "usbInserted"],
    ["RSP_ERROR", "LOG_TAG"],
]

H_GROUPS: list[list[str]] = [
    ["getCfg", "hostQuery", "hostSet"],
    ["defineQuery", "defineSet"],
    ["idCfgFn", "encodeCfgFn", "tfCardCfgFn"],
    ["ensT31xHost", "hostBoot"],
    ["qryHostStat", "qryHostRecord"],
]


def load_specs() -> dict:
    return json.loads(SPECS_PATH.read_text(encoding="utf-8"))


def read_lua(rel: str) -> str:
    return (USER / rel if not rel.startswith("user/") else ROOT / rel).read_text(encoding="utf-8")


def _is_wrapper_block(lines: list[str], i: int) -> bool:
    """local function foo(...) 且体仅为 return C/H/shared/recovery/hostq 委托。"""
    m = re.match(r"^(\s+)local function (\w+)\(", lines[i])
    if not m:
        return False
    indent, name = m.group(1), m.group(2)
    j = i + 1
    body: list[str] = []
    while j < len(lines):
        if re.match(rf"^{indent}end\s*$", lines[j]):
            break
        body.append(lines[j].strip())
        j += 1
    if len(body) != 1:
        return False
    return bool(
        re.match(
            rf"^return (C|H|shared|recovery|hostq)\.{re.escape(name)}\(",
            body[0],
        )
        or re.match(rf"^return C\.M\.\w+\(", body[0])
        or re.match(r"^return H\.\w+\(", body[0])  # wrappers: identityCfg -> H.idCfgFn
    )


def extract_bind_header(text: str) -> tuple[str, int, int]:
    lines = text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^function bind\(", ln):
            start = i + 1
            break
    if start is None:
        return "", 0, 0
    end = start
    while end < len(lines):
        ln = lines[end]
        if ln.strip() == "" or ln.lstrip().startswith("--"):
            end += 1
            continue
        if re.match(r'^\s+local cfgm = require "config_manager"', ln):
            end += 1
            continue
        if re.match(r"^\s+local .+ = (C|H|shared|recovery|hostq)\.", ln):
            end += 1
            continue
        if re.match(r"^\s+local function \w+\(", ln):
            if _is_wrapper_block(lines, end):
                while end < len(lines) and not re.match(r"^\s+end\s*$", lines[end]):
                    end += 1
                end += 1  # skip closing end
                continue
            break
        break
    return "\n".join(lines[start:end]), start, end


def scan_body_usage(text: str, header_end: int) -> dict[str, set[str]]:
    body = "\n".join(text.splitlines()[header_end:])
    usage: dict[str, set[str]] = {"C": set(), "H": set(), "shared": set(), "recovery": set(), "hostq": set()}
    for prefix in usage:
        for m in re.finditer(rf"\b{prefix}\.(\w+)", body):
            usage[prefix].add(m.group(1))
    return usage


def grouped_locals(prefix: str, fields: list[str], src: str) -> list[str]:
    """按 C_GROUPS/H_GROUPS 合并 emit local 行。"""
    remaining = list(fields)
    out: list[str] = []
    groups = C_GROUPS if prefix == "C" else H_GROUPS if prefix == "H" else []
    used: set[str] = set()
    for grp in groups:
        pick = [f for f in grp if f in remaining]
        if len(pick) >= 2:
            lhs = ", ".join(pick)
            rhs = ", ".join(f"{src}.{f}" for f in pick)
            out.append(f"    local {lhs} = {rhs}")
            used.update(pick)
    for f in remaining:
        if f not in used:
            out.append(f"    local {f} = {src}.{f}")
    return out


def emit_wrapper(name: str, src: str = "C") -> str:
    return (
        f"    local function {name}(...)\n"
        f"        return {src}.{name}(...)\n"
        f"    end"
    )


def emit_header(spec: dict, mod_spec: dict) -> str:
    lines: list[str] = []
    bind_args = mod_spec.get("bind_args", "C")
    lines.append(f"function bind({bind_args})")
    if mod_spec.get("requires_sys"):
        pass  # require "sys" 在文件顶，不在 bind 内
    if mod_spec.get("requires_cfgm"):
        lines.append('    local cfgm = require "config_manager"')

    delayed = set(spec.get("delayed_c_wrappers") or [])
    wrapper_names: set[str] = set()
    for w in mod_spec.get("wrappers") or []:
        wrapper_names.add(w[0] if isinstance(w, list) else w)

    c_fields = list(mod_spec.get("c") or [])
    h_fields = list(mod_spec.get("h") or [])
    shared_fields = list(mod_spec.get("shared") or [])

    # 延迟挂载的不做 local 快照
    c_direct = [f for f in c_fields if f not in delayed and f not in wrapper_names]
    lines.extend(grouped_locals("C", c_direct, "C"))
    lines.extend(grouped_locals("H", h_fields, "H"))
    for f in shared_fields:
        lines.append(f"    local {f} = shared.{f}")

    for inj in mod_spec.get("inject") or []:
        name, expr = inj[0], inj[1]
        lines.append(f"    local {name} = {expr}")

    for w in mod_spec.get("wrappers") or []:
        if isinstance(w, list):
            name, expr = w[0], w[1]
            lines.append(
                f"    local function {name}(...)\n        return {expr}(...)\n    end"
            )
        elif w in delayed or w not in c_direct:
            lines.append(emit_wrapper(w))

    return "\n".join(lines) + "\n"


def normalize_header(header: str) -> set[str]:
    keys: set[str] = set()
    for ln in header.splitlines():
        m = re.match(r"^\s+local\s+(.+?)\s*=", ln)
        if m:
            for part in m.group(1).split(","):
                keys.add(part.strip())
        m2 = re.match(r"^\s+local function (\w+)\(", ln)
        if m2:
            keys.add(f"fn:{m2.group(1)}")
    return keys


def check_module(name: str, spec: dict, mod_spec: dict) -> tuple[bool, list[str]]:
    path = USER / name
    if not path.is_file():
        return False, [f"MISSING {name}"]
    text = path.read_text(encoding="utf-8")
    header, start, end = extract_bind_header(text)
    expected = emit_header(spec, mod_spec)
    exp_keys = normalize_header(expected)
    act_keys = normalize_header(header)

    wrapper_names: set[str] = set()
    for w in mod_spec.get("wrappers") or []:
        wrapper_names.add(w[0] if isinstance(w, list) else w)

    issues: list[str] = []
    # spec 声明的 direct 字段 + inject + wrapper 名
    declared: set[str] = set()
    for f in mod_spec.get("c") or []:
        if f not in set(spec.get("delayed_c_wrappers") or []) and f not in {
            (w[0] if isinstance(w, list) else w) for w in (mod_spec.get("wrappers") or [])
        }:
            declared.add(f)
    for f in mod_spec.get("h") or []:
        declared.add(f)
    for f in mod_spec.get("shared") or []:
        declared.add(f)
    for inj in mod_spec.get("inject") or []:
        declared.add(inj[0])
    for w in mod_spec.get("wrappers") or []:
        declared.add(f"fn:{w[0] if isinstance(w, list) else w}")

    missing = declared - act_keys
    if missing:
        issues.append(f"  missing bindings: {sorted(missing)}")

    allowed_c = set(mod_spec.get("c") or []) | wrapper_names
    for inj in mod_spec.get("inject") or []:
        allowed_c.add(inj[0])
    allowed_h = set(mod_spec.get("h") or [])
    allowed_shared = set(mod_spec.get("shared") or []) | set(mod_spec.get("shared_inline") or [])

    usage = scan_body_usage(text, end)
    for u in usage.get("C") or set():
        if u not in allowed_c and u != "M":
            issues.append(f"  body uses C.{u} but not in spec")
    for u in usage.get("H") or set():
        if u not in allowed_h:
            issues.append(f"  body uses H.{u} but not in spec")
    for u in usage.get("shared") or set():
        if u not in allowed_shared:
            issues.append(f"  body uses shared.{u} but not in spec")

    return len(issues) == 0, issues


def cmd_check_all(spec: dict) -> int:
    modules = spec.get("modules") or {}
    fail = 0
    print(f"=== bind header check ({len(modules)} modules) ===")
    for name, mod_spec in sorted(modules.items()):
        ok, issues = check_module(name, spec, mod_spec)
        print(f"  {'PASS' if ok else 'FAIL':4} {name}")
        for line in issues:
            print(line)
        if not ok:
            fail += 1
    print(f"\n合计: {len(modules)}, 失败 {fail}")
    return 1 if fail else 0


def cmd_emit(name: str, spec: dict) -> int:
    mod_spec = (spec.get("modules") or {}).get(name)
    if not mod_spec:
        print(f"unknown module in spec: {name}", file=sys.stderr)
        return 1
    print(emit_header(spec, mod_spec), end="")
    return 0


def cmd_emit_all(spec: dict) -> int:
    for name, mod_spec in sorted((spec.get("modules") or {}).items()):
        print(f"--- {name} ---")
        print(emit_header(spec, mod_spec), end="")
        print()
    return 0


def cmd_scan(path: str) -> int:
    text = read_lua(path)
    name = Path(path).name
    _, _, end = extract_bind_header(text)
    usage = scan_body_usage(text, end)
    print(f"=== scan {name} (body from line {end + 1}) ===")
    for prefix, fields in sorted(usage.items()):
        if fields:
            print(f"  {prefix}: {', '.join(sorted(fields))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="host_uart bind 头生成/校验")
    ap.add_argument("--check-all", action="store_true", help="对照 bind_header_specs.json 校验全部子模块")
    ap.add_argument("--emit", metavar="FILE", help="输出建议 bind 头（如 hu_cmd_pir.lua）")
    ap.add_argument("--emit-all", action="store_true", help="输出全部子模块 bind 头")
    ap.add_argument("--scan", metavar="PATH", help="扫描 body 中 C/H/shared 引用")
    args = ap.parse_args()

    spec = load_specs()
    if args.check_all:
        return cmd_check_all(spec)
    if args.emit:
        return cmd_emit(Path(args.emit).name, spec)
    if args.emit_all:
        return cmd_emit_all(spec)
    if args.scan:
        return cmd_scan(args.scan)
    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
