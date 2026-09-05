# -*- coding: utf-8 -*-
"""doc/ 下 markdown 互链断链审计（文件级目标存在性）。

规则：
  * 只审计仓库内 doc/ 的 *.md（含子目录，默认排除 doc/archive/ 与 doc/_audit/，可 --no-exclude-archive）。
  * 行内链接 [..](..) 与引用式链接 [..]: .. 的目标均计入。
  * 目标含 "#锚点" 时只看 # 前路径段（不校验锚点）。
  * http/https/mailto 等带 scheme 链接跳过。
  * 相对路径越过仓库根（如 ../t3x_linux/..）记为"越界"，视为外部仓库引用, 不判失败。
  * 其余目标相对当前 md 所在目录解析, 不存在则判断链。

用法:
  python tools/debug/_doc_md_link_check.py
  python tools/debug/_doc_md_link_check.py --no-exclude-archive   # archive 也纳入
退出码: 0=无断链; 1=存在断链
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "doc"

RE_INLINE = re.compile(r"!?\[[^]]*\]\(\s*([^)\s]+)(?:\s+[^)]*)?\)")
RE_REF = re.compile(r"^\s{0,3}\[[^]]+\]:\s*(\S+)", re.MULTILINE)
RE_FENCE = re.compile(r"(?ms)^`{3,}[^\n]*\n.*?^`{3,}[^\n]*$")

EXCLUDE_DIRS = ("archive", "_audit")

# 登记「本仓库缺失、但语义指向外部工程/待补文档」的引用。
# 命中(源 md 相对 doc 路径, 目标文件名) 时放行并在报告计数, 不判失败。
# 待对应文档在本仓库落地后, 应将条目移出本表并保持护栏全绿。
EXEMPT = {
    # 注：key 第一元素为源 md 相对 doc/ 的路径（含主题子目录，如 mqtt/…），
    # 与下方 key = (md.relative_to(DOC).as_posix(), target_name) 精确对齐。
    ("mqtt/allday_pir_record_backend_dispatch.md", "record_mode_and_storage_paths.md"),
    ("mqtt/allday_pir_record_backend_dispatch.md", "cat1_pir_mqtt_action_config.md"),
    ("mqtt/allday_pir_record_backend_dispatch.md", "gb28181_livegbs_alarm_e2e.md"),
    ("mqtt/allday_pir_record_backend_dispatch.md", "pir_person_detect_complementary_flow.md"),
    ("pir/mqtt_2010_2012_2011_pir_flow.md", "mqtt_cloud_uart_ipc_record_flow.md"),
    ("pir/mqtt_2010_2012_2011_pir_flow.md", "mqtt_backend_integration.md"),
    ("pir/mqtt_2010_2012_2011_pir_flow.md", "cat1_pir_mqtt_action_config.md"),
    ("mqtt/MQTT_862323084068314.md", "usb_recovery_backend_dispatch.md"),
    ("mqtt/mqtt_tfcard_format_flow.md", "media_fifo_flow.md"),
}


def iter_md() -> list[Path]:
    files = [p for p in sorted(DOC.rglob("*.md")) if p.is_file()]
    return files


def is_web(url: str) -> bool:
    return url.lower().startswith(("http://", "https://", "mailto:", "ftp://", "tel:", "www."))


def is_excluded(p: Path) -> bool:
    rel = p.relative_to(DOC)
    return any(rel.parts[0] == d for d in EXCLUDE_DIRS)


_ROOT_RESOLVED = ROOT.resolve()


def is_within_root(p: Path) -> bool:
    """按路径组件判断，避免手拼分隔符导致跨平台（Windows `\\` / POSIX `/`）误判。"""
    try:
        p.relative_to(_ROOT_RESOLVED)
        return True
    except ValueError:
        return False


def main() -> int:
    exclude_archive = "--no-exclude-archive" not in sys.argv
    files = [p for p in iter_md() if not (exclude_archive and is_excluded(p))]
    broken: list[tuple[Path, str, Path]] = []
    out_of_root: list[tuple[Path, str, Path]] = []
    exempt_hits: list[tuple[str, str]] = []
    total_links = 0
    for md in files:
        text = md.read_text(encoding="utf-8", errors="replace")
        text = RE_FENCE.sub("", text)  # 剥离 ``` 围栏代码块, 消除 [x](y) 形态伪链接
        dests: list[str] = []
        for m in RE_INLINE.finditer(text):
            dests.append(m.group(1).strip().rstrip(","))
        for m in RE_REF.finditer(text):
            dests.append(m.group(1).strip().rstrip(","))
        for dest in dests:
            if not dest or dest.startswith("<") and dest.endswith(">"):
                dest = dest.strip("<>")
            if not dest:
                continue
            if is_web(dest):
                continue
            if dest.startswith("#"):
                continue  # 站内锚
            path_part = dest.split("#", 1)[0].split("?", 1)[0]
            if not path_part:
                continue
            total_links += 1
            key = (md.relative_to(DOC).as_posix(), Path(path_part).name)
            if key in EXEMPT:
                exempt_hits.append(key)
                continue
            target = Path(path_part)
            cand = (md.parent / target).resolve()
            if not is_within_root(cand):
                out_of_root.append((md, dest, cand))
            elif not cand.exists():
                broken.append((md, dest, cand))
    if out_of_root:
        print(f"信息: 越界引用 {len(out_of_root)} 条（仓库外/其它工程目标, 不判失败）:")
        for md, d, cand in out_of_root:
            print("  - %s -> %s" % (md.relative_to(ROOT), d))
        print()
    print(f"=== doc md 互链审计 ({len(files)} 个 md, {total_links} 条文件级链接) ===")
    if exempt_hits:
        print(f"  豁免登记 {len(exempt_hits)} 条: 目标属外部工程/待补文档, 详见脚本 EXEMPT")
    if broken:
        for md, d, cand in broken:
            print("  FAIL  %s -> %s   [解析=%s]" % (md.relative_to(ROOT), d, cand))
        print()
        print(f"  断链 {len(broken)} 条")
        print()
        return 1
    print("  PASS  无断链")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
