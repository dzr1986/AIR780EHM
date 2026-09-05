# -*- coding: utf-8 -*-
"""静态护栏自身的回归测试（refactor_plan P0）。

思路：把仓库的 user/ lib/ doc/overview/CONFIG.md 与 tools/debug/ 复制到临时目录，
注入 fixtures/ 里的样本，再以子进程运行护栏脚本（脚本用 __file__ 定位 ROOT，复制后自动指向临时仓库），
断言「应抓到的 FAIL 恰好出现、不该误报的不出现」。另含 _luatok 词法单测与「当前仓库全绿」基线。

运行：python -m unittest tools/debug/tests/test_guards.py -v
     或 python tools/debug/run_all_checks.py（第 10 项）
不引入 pytest 等新依赖。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEBUG = HERE.parent
ROOT = DEBUG.parents[1]
FIX = HERE / "fixtures"
sys.path.insert(0, str(DEBUG))
from _luatok import calls, strip_comments, strip_noncode, table_keys  # noqa: E402


class LuatokTests(unittest.TestCase):
    def test_string_containing_comment_marker_is_kept_as_code(self):
        src = 'local s = "a -- b"\nlocal t = 1 -- real\n'
        out = strip_comments(src)
        self.assertIn('"a -- b"', out)
        self.assertNotIn("real", out)

    def test_block_comment_and_line_count_preserved(self):
        src = "x = 1 --[[ multi\nline ]] y = 2\nz = 3"
        out = strip_noncode(src)
        self.assertEqual(out.count("\n"), src.count("\n"))
        self.assertNotIn("multi", out)
        self.assertIn("y = 2", out)

    def test_strings_blanked_but_positions_of_lines_kept(self):
        self.assertEqual(strip_noncode('a("K")'), 'a("")')

    def test_table_keys_single_and_multi_line(self):
        self.assertEqual(table_keys("{ a = 1, b = 2 }"), ["a", "b"])
        self.assertEqual(table_keys("{\n  a = 1,\n  b = { c = 3 },\n  d = f(1, 2),\n}"), ["a", "b", "d"])
        self.assertEqual(table_keys("{ a == b, c = 1 }"), ["c"])
        self.assertEqual(table_keys("not a table"), [])

    def test_calls_split_args_and_ignore_alias_definition(self):
        src = "local f = g.h\ng.h(1, function(x) return { q = 1 } end, { k = 2, m = 3 })\nx.g.h(9)"
        cs = calls(src, "g.h")
        self.assertEqual(len(cs), 1)
        self.assertEqual(len(cs[0].args), 3)
        self.assertEqual(table_keys(cs[0].args[2]), ["k", "m"])


def _run(tmp: Path, script: str, *args: str) -> tuple[int, str]:
    p = subprocess.run([sys.executable, str(tmp / "tools" / "debug" / script), *args],
                       capture_output=True, text=True, cwd=tmp)
    return p.returncode, p.stdout + p.stderr


class GuardSandbox(unittest.TestCase):
    """每个用例一个临时仓库副本。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="guards_"))
        for d in ("user", "lib"):
            shutil.copytree(ROOT / d, self.tmp / d)
        (self.tmp / "doc" / "overview").mkdir(parents=True)
        shutil.copy(ROOT / "doc" / "overview" / "CONFIG.md", self.tmp / "doc" / "overview" / "CONFIG.md")
        shutil.copytree(DEBUG, self.tmp / "tools" / "debug", ignore=shutil.ignore_patterns("tests", "__pycache__"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def inject(self, fixture: str, dest_name: str | None = None):
        shutil.copy(FIX / fixture, self.tmp / "user" / (dest_name or fixture))

    def append(self, rel: str, text: str):
        with open(self.tmp / rel, "a", encoding="utf-8") as f:
            f.write("\n" + text + "\n")

    # --- 基线：干净仓库三护栏全绿 ---
    def test_baseline_all_pass(self):
        for s in ("_gpio_opts_check.py", "_config_key_check.py", "_ref_name_check.py", "_undef_global_check.py"):
            rc, out = _run(self.tmp, s)
            self.assertEqual(rc, 0, f"{s} 基线应 PASS:\n{out}")

    # --- gpio：5 类样本 ---
    def test_gpio_opts_catches_all_shapes(self):
        self.inject("gpio_bad_opts.lua", "zz_gpio_probe.lua")
        rc, out = _run(self.tmp, "_gpio_opts_check.py")
        self.assertEqual(rc, 1)
        for key in ("bogus_key", "typo", "bad_override"):
            self.assertIn(f"opts.{key}", out, out)
        self.assertIn("未覆盖", out)
        self.assertNotIn("opts.x", out, "回调内嵌套表 { x = 1 } 不应被当成 opts 键")
        self.assertNotIn("opts.trigger_mode", out, "合法 snake 键不应误报")

    # --- config：字符串不算消费；单引号 cfgm.get 算 ---
    def test_config_dead_key_not_hidden_by_string_literal(self):
        self.append("user/flags.lua", "_G.ZZ_DEAD_CFG = { a = 1 }")
        self.inject("cfg_dead_key_string_only.lua", "zz_cfg_probe.lua")
        rc, out = _run(self.tmp, "_config_key_check.py")
        self.assertEqual(rc, 1)
        self.assertIn("ZZ_DEAD_CFG", out)
        self.assertIn("死配置", out)

    def test_config_single_quote_get_counts_as_consumer(self):
        self.append("user/flags.lua", "_G.ZZ_DEAD_CFG = { a = 1 }")
        self.inject("cfg_dead_key_consumed.lua", "zz_cfg_probe.lua")
        rc, out = _run(self.tmp, "_config_key_check.py")
        self.assertNotIn("死配置", out)          # 只剩索引漂移 FAIL
        self.assertIn("索引块与代码不一致", out)

    def test_config_write_doc_still_reports_failures(self):
        self.append("user/flags.lua", "_G.ZZ_DEAD_CFG = { a = 1 }")
        rc, out = _run(self.tmp, "_config_key_check.py", "--write-doc")
        self.assertEqual(rc, 1, "--write-doc 写完后仍须按剩余 FAIL 返回非零")
        self.assertIn("死配置", out)

    # --- ref_name：注释不算引用；真实错名 FAIL ---
    def test_ref_name_ignores_commented_module(self):
        self.inject("ref_name_commented.lua", "zz_ref_ok.lua")
        rc, out = _run(self.tmp, "_ref_name_check.py")
        self.assertEqual(rc, 0, out)

    def test_ref_name_flags_missing_host_uart_member_and_modcall_arity(self):
        self.inject("ref_name_member_bad.lua", "zz_ref_member.lua")
        rc, out = _run(self.tmp, "_ref_name_check.py")
        self.assertEqual(rc, 1)
        self.assertIn("noSuchFnZZ", out)
        self.assertIn("传 3 个实参", out)

    def test_undef_global_flags_misspelled_identifier(self):
        import shutil as _sh
        if not (_sh.which("luac5.3") or _sh.which("luac")):
            self.skipTest("no luac")
        self.inject("undef_global_bad.lua", "zz_undef.lua")
        rc, out = _run(self.tmp, "_undef_global_check.py")
        self.assertEqual(rc, 1)
        self.assertIn("LIMITMO_SHARED_ZZ", out)

    def test_undef_global_flags_late_top_level_local(self):
        import shutil as _sh
        if not (_sh.which("luac5.3") or _sh.which("luac")):
            self.skipTest("no luac")
        self.inject("undef_global_late_local.lua", "zz_late_local.lua")
        rc, out = _run(self.tmp, "_undef_global_check.py")
        self.assertEqual(rc, 1)
        self.assertIn("zzLateOwner", out)
        self.assertIn("先用后声明", out)

    def test_ref_name_flags_live_bad_require(self):
        self.inject("ref_name_live_bad.lua", "zz_ref_bad.lua")
        rc, out = _run(self.tmp, "_ref_name_check.py")
        self.assertIn("no_such_module_zz", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
