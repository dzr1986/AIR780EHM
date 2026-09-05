# -*- coding: utf-8 -*-
"""一次性批量缩短 user/lib 模块名（LuatOS 文件名 <= 24 bytes）。"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# old_stem -> new_stem（require 名 = 文件名去 .lua）
# batch1 已完成；batch2 统一 mqtt_* / hu_* 主壳
RENAMES = {
    "net_mqtt_dl_ctrl": "mqtt_dl_ctrl",
    "net_mqtt_dl_upload": "mqtt_dl_upload",
    "net_mqtt_ul_upload": "mqtt_ul_upload",
    "net_mqtt_dl_pir": "mqtt_dl_pir",
    "net_mqtt_ul_pir": "mqtt_ul_pir",
    "net_mqtt_dl_tf": "mqtt_dl_tf",
    "net_mqtt_hproto": "mqtt_hproto",
    "net_mqtt_uplink": "mqtt_uplink",
    "net_mqtt_conn": "mqtt_conn",
    "host_uart_cmd": "hu_cmd",
    "host_uart_ipc": "hu_ipc",
    "host_uart_rx": "hu_rx",
    "host_uart_at": "hu_at",
}

SCAN_DIRS = [
    ROOT / "user",
    ROOT / "lib",
    ROOT / "tools" / "debug",
    ROOT / ".cursor" / "rules",
    ROOT / "doc",
]

TEXT_SUFFIX = {".lua", ".py", ".json", ".md", ".mdc", ".ini"}


def rename_files() -> None:
    for old, new in RENAMES.items():
        for base in (ROOT / "user", ROOT / "lib"):
            old_path = base / f"{old}.lua"
            new_path = base / f"{new}.lua"
            if old_path.is_file():
                if new_path.exists():
                    raise SystemExit(f"target exists: {new_path}")
                old_path.rename(new_path)
                print("rename", old_path.relative_to(ROOT), "->", new_path.name)


def patch_text() -> None:
    items = sorted(RENAMES.items(), key=lambda x: len(x[0]), reverse=True)
    for d in SCAN_DIRS:
        if not d.is_dir():
            continue
        for path in d.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIX:
                continue
            if path.name == "_rename_lua_modules.py":
                continue
            text = path.read_text(encoding="utf-8")
            orig = text
            for old, new in items:
                text = text.replace(old, new)
            if text != orig:
                path.write_text(text, encoding="utf-8")
                print("patch", path.relative_to(ROOT))


def verify_lengths(max_bytes: int = 24) -> None:
    bad = []
    for base in (ROOT / "user", ROOT / "lib"):
        if not base.is_dir():
            continue
        for path in base.glob("*.lua"):
            n = len(path.name.encode("utf-8"))
            if n > max_bytes:
                bad.append((n, path.name))
    if bad:
        raise SystemExit("still over limit: " + ", ".join(f"{n}:{f}" for n, f in bad))
    print("all user/lib lua names <=", max_bytes, "bytes")


def main() -> None:
    rename_files()
    patch_text()
    verify_lengths()
    print("done")


if __name__ == "__main__":
    main()
