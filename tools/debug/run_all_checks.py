# -*- coding: utf-8 -*-
"""780EHM 一键静态护栏入口（commit 前 / 日常回归）。

用法：
    python tools/debug/run_all_checks.py

聚合子项（每项独立子进程，cwd=仓库根）：
    1. _ref_name_check.py           引用名护栏（loader/modCall/require 错名）
    2. _module_tree.py --diff       模块树行数漂移（基线 tools/debug/_module_tree_baseline.json）
    3. _protocol_regression_check.py  协议族静态回归（文件名长度 + host_uart/net_mqtt + bind header）
    4. _doc_module_ref_check.py     doc 与 user|lib 代码的 .lua 引用一致性（写 _doc_ref_report.txt）
    5. _doc_md_link_check.py        doc/ 内部 markdown 互链断链审计（EXEMPT 登记外部/待补引用）
    6. _doc_index_check.py          doc 导航完整性（README 收录覆盖 + 孤岛零容忍）

全部 PASS 时退出码 0，任一失败退出码 1。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEBUG = ROOT / "tools" / "debug"

CHECKS = (
    ("_ref_name_check.py", (), "引用名护栏（loader/modCall/require 错名，全库引用可解析）"),
    ("_module_tree.py", ("--diff",), "模块树行数漂移（对照 tools/debug/_module_tree_baseline.json）"),
    ("_protocol_regression_check.py", (), "协议族静态回归（文件名长度 + host_uart/net_mqtt + bind header --check-all）"),
    ("_doc_module_ref_check.py", (), "doc 与 user|lib 代码的 .lua 引用一致性（现状类须 0 需修复；输出 _doc_ref_report.txt）"),
    ("_doc_md_link_check.py", (), "doc/ 内部 markdown 互链断链审计（外部工程引用与待补文档走 EXEMPT 登记）"),
    ("_doc_index_check.py", (), "doc 导航完整性（顶层/modules 入 README 索引；迁移 stub 豁免；孤岛零容忍）"),
)


def main() -> int:
    print("== 780EHM 一键静态护栏 ==")
    print()
    results: list[tuple[str, str, bool]] = []
    for name, args, desc in CHECKS:
        path = DEBUG / name
        print(f"--- {name} ---")
        if desc:
            print(f"    {desc}")
        rc = subprocess.call([sys.executable, str(path), *args], cwd=str(ROOT))
        results.append((name, desc, rc == 0))
        print()
    print("== 汇总 ==")
    fail = 0
    for name, desc, ok in results:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}  {desc}")
        if not ok:
            fail += 1
    if fail:
        print(f"\nFAILED: {fail} 项未通过（修复后重跑本入口）")
        return 1
    print("\nALL PASS — 可提交")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
