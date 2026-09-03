#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Markdown 转成中文 PDF（Windows 用黑体）。"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from fpdf import FPDF

FONT = r"C:\Windows\Fonts\simhei.ttf"


class MdPdf(FPDF):
    def footer(self) -> None:
        self.set_y(-12)
        self.set_font("heiti", size=8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 8, f"{self.page_no()}", align="C")
        self.set_text_color(0, 0, 0)


def strip_md(text: str) -> str:
    text = text.replace("`", "")
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text.replace("→", "->").replace("─", "-").replace("├", "+").replace("└", "+").replace("│", "|")


def parse_table(lines: list[str]) -> list[list[str]]:
    rows = []
    for line in lines:
        if re.match(r"^\s*\|?\s*-{2,}", line.replace("|", " | ")):
            continue
        if set(line.strip()) <= set("|- :"):
            continue
        cells = [strip_md(c.strip()) for c in line.strip().strip("|").split("|")]
        if cells:
            rows.append(cells)
    return rows


def render(md_path: Path, pdf_path: Path) -> None:
    text = md_path.read_text(encoding="utf-8")
    pdf = MdPdf(format="A4")
    pdf.set_auto_page_break(auto=True, margin=16)
    pdf.add_font("heiti", fname=FONT)
    pdf.add_font("heiti", style="B", fname=FONT)
    pdf.add_page()
    pdf.set_title(md_path.stem)

    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        if not line.strip():
            pdf.ln(3)
            i += 1
            continue

        if line.strip() == "---":
            pdf.ln(2)
            y = pdf.get_y()
            pdf.set_draw_color(200, 200, 200)
            pdf.line(16, y, 194, y)
            pdf.ln(4)
            i += 1
            continue

        if line.startswith("```"):
            buf = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            pdf.set_x(pdf.l_margin)
            pdf.set_fill_color(245, 246, 248)
            pdf.set_font("heiti", size=8)
            block = strip_md("\n".join(buf))
            pdf.multi_cell(0, 4.2, block if block else " ", fill=True)
            pdf.ln(2)
            pdf.set_x(pdf.l_margin)
            continue

        if line.strip().startswith("|"):
            tbl = [line]
            i += 1
            while i < len(lines) and lines[i].strip().startswith("|"):
                tbl.append(lines[i])
                i += 1
            rows = parse_table(tbl)
            if rows:
                pdf.set_x(pdf.l_margin)
                pdf.set_font("heiti", size=8)
                with pdf.table(text_align="LEFT") as table:
                    for r in rows:
                        row = table.row()
                        for cell in r:
                            row.cell(cell or " ")
                pdf.ln(3)
                pdf.set_x(pdf.l_margin)
            continue

        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            title = strip_md(m.group(2))
            sizes = {1: 18, 2: 14, 3: 12}
            pdf.ln(2 if level > 1 else 0)
            pdf.set_x(pdf.l_margin)
            pdf.set_font("heiti", size=sizes[level])
            pdf.multi_cell(0, 8, title)
            pdf.ln(1)
            i += 1
            continue

        if re.match(r"^\d+\.\s+", line) or line.lstrip().startswith("- "):
            pdf.set_x(pdf.l_margin)
            pdf.set_font("heiti", size=10)
            pdf.multi_cell(0, 6, strip_md(line.strip()))
            i += 1
            continue

        pdf.set_x(pdf.l_margin)
        pdf.set_font("heiti", size=10)
        pdf.multi_cell(0, 6, strip_md(line))
        i += 1

    pdf.output(str(pdf_path))


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/NGINX_OTA_CONF.md")
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".pdf")
    render(src, dst)
    print(dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
