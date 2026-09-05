# -*- coding: utf-8 -*-
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
dirs = [root / "user", root / "lib"]
pat_and = re.compile(r"\band\s+\w+\.\w+\s+then")
pat_type = re.compile(r"""type\([^)]+\)\s*==\s*['\"]table['\"]""")
pat_pcall = re.compile(r"\bpcall\s*\(")
pat_local = re.compile(r"^local\s+", re.M)
rows = []
for d in dirs:
    for p in sorted(d.glob("*.lua")):
        if p.name == "sys.lua":
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        rel = str(p.relative_to(root)).replace("\\", "/")
        rows.append((
            p.stat().st_size,
            len(t.splitlines()),
            len(pat_and.findall(t)),
            len(pat_type.findall(t)),
            len(pat_pcall.findall(t)),
            len(pat_local.findall(t)),
            rel,
        ))
rows.sort(reverse=True)
print("%8s %6s %7s %6s %6s %7s file" % ("bytes", "lines", "and.fn", "type=t", "pcall", "locals"))
tot = [0, 0, 0, 0, 0, 0]
for sz, ln, a, ty, pc, loc, rel in rows:
    print("%8d %6d %7d %6d %6d %7d %s" % (sz, ln, a, ty, pc, loc, rel))
    tot[0] += sz
    tot[1] += ln
    tot[2] += a
    tot[3] += ty
    tot[4] += pc
    tot[5] += loc
print("-" * 70)
print("%8d %6d %7d %6d %6d %7d TOTAL %d files" % (
    tot[0], tot[1], tot[2], tot[3], tot[4], tot[5], len(rows)))
