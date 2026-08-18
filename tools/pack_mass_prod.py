#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包 Cat.1 量产交付目录：固件 + 烧录工具。

用法（在仓库根目录）：
  python tools/pack_mass_prod.py
  python tools/pack_mass_prod.py 001.000.036
  python tools/pack_mass_prod.py --bump
  python tools/pack_mass_prod.py 001.000.037 --out 20260818_量产

默认输出目录：仓库根下「YYYYMMDD_量产」。
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import zipfile
from datetime import date
from pathlib import Path

FLASH_DIR = Path(__file__).resolve().parent / "gui" / "flash"
sys.path.insert(0, str(FLASH_DIR))

import cat1_flash as flash  # noqa: E402

REPO = flash.ROOT
FLASH_PY = FLASH_DIR / "cat1_flash.py"
FLASH_GUI_PY = FLASH_DIR / "cat1_flash_gui.py"
REQ_TXT = FLASH_DIR / "requirements-flash.txt"


def _err(msg: str) -> int:
    print(f"错误: {msg}", file=sys.stderr)
    return 1


def _info(msg: str) -> None:
    print(msg)


README_TXT = """Cat.1 量产烧录包（Air780EHM）
================================

本目录可单独拷贝到产线电脑。板子烧录只烧 Cat.1 模组，不是 T31。

一、环境（每台电脑首次）
  1. 安装 Python 3.10+（勾选 Add python.exe to PATH）
  2. 双击「烧录.bat」，会自动安装 pyserial / ectool / py7zr

二、烧录步骤（全量：底层 + 本包脚本）
  1. 用 USB 连模组下载口
  2. 按住板上 BOOT，再复位/上电；设备管理器应出现 1 个下载口
  3. 双击「烧录.bat」打开界面
  4. 点「下载本地量产文件到模组」
  5. 等日志提示成功后松开 BOOT，复位模组

也可双击「全量烧录-命令行.bat」，同样要先按住 BOOT。

三、本包文件
  firmware\\*.soc     USB 量产全量包（务必用这个烧）
  firmware\\*.bin     远程升级（FOTA）包，不是 USB 烧录文件
  *.luatos            LuatOS 工程包（Luatools / luatos-cli 导入用，含 user+lib 源码）
  tools\\             烧录工具源码
  量产包.json         标记本目录为量产包，烧录工具会优先用这里的固件

四、重新打包（需在完整代码仓库内）
  仓库根目录执行：
    python tools\\pack_mass_prod.py 001.000.036
    或双击 tools\\pack_mass_prod.bat ，后面加版本号
  本目录的「重新打包.bat」仅在本文件夹仍位于仓库根下时有效。
"""

BURN_BAT = r"""@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python >nul 2>&1
if errorlevel 1 (
  echo 未找到 Python。请先安装 Python 3.10+，并勾选 Add python.exe to PATH。
  pause
  exit /b 1
)
echo 安装/检查烧录依赖...
python -m pip install -q -r tools\requirements-flash.txt
if errorlevel 1 (
  echo 依赖安装失败。
  pause
  exit /b 1
)
python tools\cat1_flash_gui.py
if errorlevel 1 pause
"""

FLASH_CLI_BAT = r"""@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python >nul 2>&1
if errorlevel 1 (
  echo 未找到 Python。请先安装 Python 3.10+。
  pause
  exit /b 1
)
python -m pip install -q -r tools\requirements-flash.txt
echo.
echo 请先按住 BOOT 再复位/上电，看到下载口后再继续。
pause
python tools\cat1_flash.py flash-full --wait 90
if errorlevel 1 pause
"""

REPACK_BAT = r"""@echo off
chcp 65001 >nul
cd /d "%~dp0.."
if not exist "user\main.lua" (
  echo 当前目录不在代码仓库根下，无法重新打包。
  echo 请到仓库执行: python tools\pack_mass_prod.py 版本号
  pause
  exit /b 1
)
python tools\pack_mass_prod.py %*
if errorlevel 1 pause
"""

PACK_BAT = r"""@echo off
chcp 65001 >nul
cd /d "%~dp0.."
python tools\pack_mass_prod.py %*
if errorlevel 1 pause
"""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="打包 Cat.1 量产固件 + 烧录工具")
    p.add_argument(
        "version",
        nargs="?",
        default="",
        help="脚本版本 nnn.nnn.nnn，默认使用 user/main.lua 当前 VERSION",
    )
    p.add_argument("--bump", action="store_true", help="在当前 VERSION 上补丁号 +1")
    p.add_argument(
        "--out",
        dest="out_dir",
        default="",
        help="输出目录，默认 仓库根/YYYYMMDD_量产",
    )
    p.add_argument("--no-fota", action="store_true", help="不生成远程升级 .bin")
    p.add_argument(
        "--skip-repo-copy",
        action="store_true",
        help="不把产物再复制进仓库 firmware/量产 目录",
    )
    return p.parse_args()


def resolve_version(args: argparse.Namespace) -> str | None:
    current = flash.read_script_version()
    if args.bump:
        if not current:
            _err(f"{flash.MAIN_LUA} 没有 VERSION，无法 --bump")
            return None
        return flash.bump_script_version(current)
    ver = (args.version or "").strip()
    if ver:
        if not ver.replace(".", "").isdigit() or ver.count(".") != 2:
            _err(f"版本须为 nnn.nnn.nnn，当前={ver}")
            return None
        return ver
    if not current:
        _err(f"{flash.MAIN_LUA} 没有 VERSION = \"x.y.z\"")
        return None
    return current


def copy_into_repo_prod_dirs(soc_path: Path, fota_bin: Path | None) -> None:
    for d in flash.PROD_COPY_DIRS:
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy2(soc_path, d / soc_path.name)
        if fota_bin and fota_bin.is_file():
            shutil.copy2(fota_bin, d / fota_bin.name)
        _info(f"  仓库副本 {d / soc_path.name}")


def _luatos_toml(ver: str, soc_name: str | None) -> str:
    soc_line = f'soc_file = "firmware/{soc_name}"' if soc_name else "soc_file = \"\""
    return (
        f"[project]\n"
        f'name = "PANSHI_CAT1"\n'
        f'chip = "ec7xx"\n'
        f'version = "{ver}"\n'
        f'description = "Air780EHM 量产工程 {ver}"\n'
        f"\n"
        f"[build]\n"
        f'script_dirs = ["user/", "lib/"]\n'
        f'script_files = ["luatos.json"]\n'
        f'output_dir = "build/"\n'
        f"use_luac = true\n"
        f"bitw = 32\n"
        f"luac_debug = 0\n"
        f"ignore_deps = true\n"
        f'soc_script = "disable"\n'
        f'resource_dir = "resource/"\n'
        f"\n"
        f"[flash]\n"
        f"{soc_line}\n"
    )


def build_luatos_archive(out_dir: Path, ver: str, soc_name: str | None) -> Path:
    """打一份 luatos-cli / Luatools 可导入的 .luatos（标准 ZIP）。"""
    dest = out_dir / f"PANSHI_CAT1_{ver}.luatos"
    if dest.exists():
        dest.unlink()
    files = 0
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("luatos-project.toml", _luatos_toml(ver, soc_name))
        files += 1
        luatos_json = REPO / "luatos.json"
        if luatos_json.is_file():
            z.write(luatos_json, "luatos.json")
            files += 1
        for folder in ("user", "lib"):
            base = REPO / folder
            if not base.is_dir():
                continue
            for path in sorted(base.rglob("*")):
                if not path.is_file():
                    continue
                if path.name in flash.SKIP_PACK_NAMES:
                    continue
                rel = f"{folder}/{path.relative_to(base).as_posix()}"
                z.write(path, rel)
                files += 1
    _info(f"已生成工程包 {dest}  ({dest.stat().st_size / 1024:.1f} KB, {files} 个文件)")
    return dest


def write_kit(
    out: Path,
    ver: str,
    soc_path: Path,
    fota_bin: Path | None,
) -> None:
    fw_dir = out / "firmware"
    tools_dir = out / "tools"
    fw_dir.mkdir(parents=True, exist_ok=True)
    tools_dir.mkdir(parents=True, exist_ok=True)

    shutil.copy2(soc_path, fw_dir / soc_path.name)
    if fota_bin and fota_bin.is_file():
        shutil.copy2(fota_bin, fw_dir / fota_bin.name)

    shutil.copy2(FLASH_PY, tools_dir / "cat1_flash.py")
    shutil.copy2(FLASH_GUI_PY, tools_dir / "cat1_flash_gui.py")
    shutil.copy2(REQ_TXT, tools_dir / "requirements-flash.txt")

    luatos_path = build_luatos_archive(out, ver, soc_path.name)

    core = flash.core_from_soc_name(soc_path)
    iot = flash.script_to_iot_version(ver, core)
    meta = {
        "kind": "cat1_mass_prod",
        "chip": "Air780EHM",
        "version": ver,
        "firmwareVersion": iot,
        "date": date.today().strftime("%Y%m%d"),
        "soc": soc_path.name,
        "fota": fota_bin.name if fota_bin and fota_bin.is_file() else None,
        "luatos": luatos_path.name,
    }
    (out / "量产包.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (out / "README.txt").write_text(README_TXT, encoding="utf-8-sig")
    (out / "烧录.bat").write_text(BURN_BAT, encoding="utf-8")
    (out / "全量烧录-命令行.bat").write_text(FLASH_CLI_BAT, encoding="utf-8")
    (out / "重新打包.bat").write_text(REPACK_BAT, encoding="utf-8")


def main() -> int:
    if not (REPO / "user" / "main.lua").is_file():
        return _err("请在代码仓库内运行本脚本（找不到 user/main.lua）")
    if not FLASH_PY.is_file() or not FLASH_GUI_PY.is_file():
        return _err(f"找不到烧录工具 {FLASH_DIR}")

    args = parse_args()
    ver = resolve_version(args)
    if not ver:
        return 1

    current = flash.read_script_version()
    if ver != current:
        try:
            flash.write_script_version(ver)
        except ValueError as e:
            return _err(str(e))
        _info(f"已改 VERSION {current} → {ver}")
    else:
        _info(f"使用当前 VERSION={ver}")

    pack_args = argparse.Namespace(out="", include_core=False)
    rc = flash.cmd_pack(pack_args)
    if rc:
        return rc
    script_bin = REPO / "dist" / "script.bin"
    template = flash.find_template_soc(ver)
    if template is None:
        return _err("找不到 V2044 Air780EHM 量产 .soc 模板（firmware/ 或 量产/）")
    _info(f"量产模板 {template}")
    try:
        soc_path = flash.rebuild_prod_soc(script_bin, template, ver)
    except Exception as e:
        return _err(str(e))
    _info(f"已生成量产 SOC {soc_path}  ({soc_path.stat().st_size / 1024:.0f} KB)")

    core = flash.core_from_soc_name(template)
    iot = flash.script_to_iot_version(ver, core)
    fota_bin = REPO / "dist" / f"PANSHI_CAT1_{iot}_LuatOS-SoC_Air780EHM.bin"
    if args.no_fota:
        fota_bin = None
        _info("已跳过远程升级 .bin（--no-fota）")
    else:
        try:
            flash.build_script_fota_bin(soc_path, fota_bin)
            head = fota_bin.read_bytes()[:4]
            _info(f"远程升级 {fota_bin.name}  {fota_bin.stat().st_size} 字节  magic={head.hex()}")
        except Exception as e:
            _info(f"远程升级 .bin 未生成（USB 烧录仍可用）: {e}")
            fota_bin = None

    if not args.skip_repo_copy:
        _info("复制到仓库量产目录：")
        copy_into_repo_prod_dirs(soc_path, fota_bin)

    out_name = (args.out_dir or "").strip() or f"{date.today():%Y%m%d}_量产"
    out = Path(out_name)
    if not out.is_absolute():
        out = REPO / out
    write_kit(out, ver, soc_path, fota_bin)

    bat = REPO / "tools" / "pack_mass_prod.bat"
    if not bat.is_file():
        bat.write_text(PACK_BAT, encoding="utf-8")

    _info("")
    _info(f"量产包已生成: {out}")
    _info(f"  脚本版本 {ver}    平台版本 {iot}")
    _info(f"  USB 烧录: {soc_path.name}")
    if fota_bin and fota_bin.is_file():
        _info(f"  远程升级: {fota_bin.name}")
    _info("  产线入口: 烧录.bat")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
