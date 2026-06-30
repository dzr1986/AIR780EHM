# -*- coding: utf-8 -*-
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "user" / "config.lua"
lines = path.read_text(encoding="utf-8").splitlines()
out = []
for line in lines:
    if line.lstrip().startswith("--"):
        continue
    out.append(line)
text = "\n".join(out) + "\n"
orig = path.read_text(encoding="utf-8")
path.write_text(text, encoding="utf-8", newline="\n")
print(f"config.lua {len(orig)} -> {len(text)} (-{len(orig)-len(text)} bytes)")
