#!/usr/bin/env python3
"""Windows 打包：生成 tools/ipc/x.x.x/ipc.tar + ipc.json。"""

from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
import sys
from pathlib import Path

DEFAULT_URL_BASE = "http://43.136.55.143:8008"
SKIP_NAMES = {".gitkeep", "ipc.tar", "ipc.json"}


def default_out_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent / "ipc"
    return Path(__file__).resolve().parents[1] / "tools" / "ipc"


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def version_folder(version: str) -> str:
    v = version.strip()
    if not v:
        raise ValueError("version empty")
    return v


def product_dir(version: str, out_root: Path | None = None) -> Path:
    root = out_root or default_out_root()
    folder = root / version_folder(version)
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def file_url(url_base: str) -> str:
    return url_base.rstrip("/") + "/downloads/ipc.tar"


def write_ipc_json(version: str, url_base: str, out_root: Path | None = None, tar_path: Path | None = None) -> dict:
    folder = product_dir(version, out_root)
    meta = {
        "name": "ipc",
        "version": version.strip(),
        "url": file_url(url_base),
        "file": "ipc.tar",
    }
    if tar_path is None:
        candidate = folder / "ipc.tar"
        if candidate.exists():
            tar_path = candidate
    if tar_path is not None and tar_path.exists():
        meta["md5"] = md5_file(tar_path)
        meta["size"] = tar_path.stat().st_size
    json_path = folder / "ipc.json"
    json_path.write_text(json.dumps(meta, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    return {"dir": str(folder), "json": str(json_path), **meta}


def _add_to_tar(tar: tarfile.TarFile, src: Path) -> None:
    src = src.resolve()
    if src.is_file():
        if src.name in SKIP_NAMES:
            return
        tar.add(str(src), arcname=src.name)
        return
    for child in sorted(src.iterdir()):
        if child.name in SKIP_NAMES:
            continue
        tar.add(str(child), arcname=child.name)


def pack(src: Path, version: str, url_base: str, out_root: Path | None = None) -> dict:
    src = src.resolve()
    if not src.exists():
        raise FileNotFoundError(src)
    folder = product_dir(version, out_root)
    tar_path = folder / "ipc.tar"
    with tarfile.open(tar_path, "w") as tar:
        _add_to_tar(tar, src)
    meta = write_ipc_json(version, url_base, out_root, tar_path)
    meta["tar"] = str(tar_path)
    return meta


def main() -> int:
    p = argparse.ArgumentParser(description="Windows pack_tool：产出 tools/ipc/x.x.x/ipc.tar + ipc.json")
    p.add_argument("--input", "-i", help="要打进 ipc.tar 的文件或目录")
    p.add_argument("--version", "-v", default="1.0.30")
    p.add_argument("--url-base", default=DEFAULT_URL_BASE)
    p.add_argument("--out", default=str(default_out_root()), help="产物根目录，默认 tools/ipc")
    p.add_argument("--json-only", action="store_true", help="只写 ipc.json，不打包")
    args = p.parse_args()
    out = Path(args.out)
    if args.json_only:
        info = write_ipc_json(args.version, args.url_base, out)
    else:
        if not args.input:
            raise SystemExit("--input 必填（或用 --json-only）")
        info = pack(Path(args.input), args.version, args.url_base, out)
    print(json.dumps(info, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
