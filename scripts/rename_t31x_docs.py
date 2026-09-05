#!/usr/bin/env python3
# 将仓库内 4G 业务侧 t3x/T3x/T3X 统一改名为 t31x/T31x/T31X。
# 覆盖：代码标识符 + 配置键 + MQTT 线协议字段(source=t3x) + 事件常量(PIR_WAKE_T3X/T3X_*) + 文档 + 工具。
# 模块文件(t3x_ctrl.lua 等)一并改名，并更新 require 与回归脚本引用。
#
# 自动排除：IPC 芯片/平台侧目录(firmware/ ota_server http_server video_upload_server t31x_ipc 量产)
#           与历史目录(archive .specstory)以及 .git/__pycache__ 等。
# 用占位符保护仅出现在文档的「芯片/平台 token」(media_plat/t3x、toolchain/t3x、t3x_linux、
#   t3x_runtime、IPC_PLATFORM_T3X、PLATFORM=t3x、lib/t3x/ 目录、T3X_JPEG 宏)，
#   避免与真实硬件目录 media_plat/t31x(已是 t31x) 混淆。
# 幂等：重跑不会二次改写。
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTS = {".lua", ".json", ".py", ".md", ".txt", ".html", ".csv", ".xml",
        ".js", ".sh", ".mk", ".yaml", ".yml", ".toml", ".ini", ".cfg"}
SKIP_DIRS = {"archive", "firmware", "ota_server", "http_server",
             "video_upload_server", "t31x_ipc", "量产", ".git", "__pycache__",
             "node_modules", "cat1_host", "dist", "build", ".vscode", ".idea",
             ".specstory"}

# 芯片/平台 token（仅文档出现），必须保持 t3x 不变
PROTECTED = [
    "media_plat/t3x",
    "toolchain/t3x",
    "lib/t3x/",
    "t3x_linux",
    "t3x_runtime",
    "IPC_PLATFORM_T3X",
    "PLATFORM = t3x",
    "PLATFORM=t3x",
    "T3X_JPEG",
]
PROTECTED.sort(key=len, reverse=True)
PH = {f"@@PROT{i}@@": p for i, p in enumerate(PROTECTED)}
TRIPLE = [("T3X", "T31X"), ("T3x", "T31x"), ("t3x", "t31x")]


def transform(text):
    for i, p in enumerate(PROTECTED):
        text = text.replace(p, f"@@PROT{i}@@")
    for a, b in TRIPLE:
        text = text.replace(a, b)
    for ph, p in PH.items():
        text = text.replace(ph, p)
    return text


def transform_name(name):
    for a, b in TRIPLE:
        name = name.replace(a, b)
    return name


changed, renamed = [], []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if os.path.splitext(fn)[1].lower() not in EXTS:
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                orig = f.read()
        except Exception as e:
            print("skip-read", os.path.relpath(path, ROOT), e)
            continue
        new = transform(orig)
        if new != orig:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(new)
            changed.append(path)
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if os.path.splitext(fn)[1].lower() not in EXTS:
            continue
        newname = transform_name(fn)
        if newname != fn:
            src = os.path.join(dirpath, fn)
            dst = os.path.join(dirpath, newname)
            if os.path.exists(dst):
                print("CONFLICT", os.path.relpath(dst, ROOT))
                continue
            os.rename(src, dst)
            renamed.append((src, dst))

print("changed files:", len(changed))
print("renamed files:", len(renamed))
for s, d in renamed:
    print("  RENAME", os.path.relpath(s, ROOT), "->", os.path.relpath(d, ROOT))
