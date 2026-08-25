#!/usr/bin/env python3
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTS = {".md", ".txt", ".html"}
SKIP_DIRS = {"cat1_host", "archive", ".git", "__pycache__"}

REPLS = [
    ("T3xX", "T3X"),
    ("syncStopFromT31", "syncStopFromT3x"),
    ("publishT31RecordStop", "publishT3xRecordStop"),
    ("getT31RecActive", "getT3xRecActive"),
    ("mayPowerT31", "mayPowerT3x"),
    ("isT31HostReady", "isT3xHostReady"),
    ("HOST_DL_NEEDS_T31", "HOST_DL_NEEDS_T3X"),
    ("notify_t31", "notify_t3x"),
    ("forward_to_t31", "forward_to_t3x"),
    ("t31_net_ursp", "t3x_net_ursp"),
    ("t31x_rest_percent", "t3x_rest_percent"),
    ("t31_rest_percent", "t3x_rest_percent"),
    ("t31x_linux", "t3x_linux"),
    ("t31x_", "t3x_"),
    ("T31X_", "T3X_"),
    ("T31X", "T3X"),
    ("t31x", "t3x"),
    ("T31x", "T3x"),
    ("T31ZX", "T3xZX"),
    ("T31_", "T3X_"),
    ("source=t31", "source=t3x"),
    ("t31_active", "t3x_active"),
    ("T31", "T3x"),
]

updated = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if os.path.splitext(fn)[1].lower() not in EXTS:
            continue
        path = os.path.join(dirpath, fn)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            orig = f.read()
        text = orig
        for a, b in REPLS:
            text = text.replace(a, b)
        if text != orig:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            updated += 1
            print("updated", os.path.relpath(path, ROOT))

print("total", updated)
