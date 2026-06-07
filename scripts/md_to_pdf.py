#!/usr/bin/env python3
"""将 Markdown 转为 PDF（支持 mermaid 流程图，需联网加载 CDN）。"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import markdown
from markdown.extensions.tables import TableExtension
from playwright.sync_api import sync_playwright

HTML_SHELL = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<title>{title}</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<style>
  @page {{ margin: 18mm 16mm; }}
  body {{
    font-family: "Microsoft YaHei", "PingFang SC", "Noto Sans SC", sans-serif;
    font-size: 11pt;
    line-height: 1.55;
    color: #222;
    max-width: 100%;
    padding: 0 8px;
  }}
  h1 {{ font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 6px; }}
  h2 {{ font-size: 15pt; margin-top: 1.2em; color: #1a5276; }}
  h3 {{ font-size: 12.5pt; }}
  table {{ border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 10pt; }}
  th, td {{ border: 1px solid #bbb; padding: 6px 8px; }}
  th {{ background: #eef2f7; }}
  code {{ background: #f4f4f4; padding: 1px 4px; font-size: 9.5pt; }}
  pre {{ background: #f6f8fa; padding: 10px; overflow-x: auto; font-size: 9pt; }}
  pre.mermaid {{ background: #fff; border: 1px dashed #ccc; }}
  blockquote {{ border-left: 4px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }}
  a {{ color: #1565c0; }}
</style>
</head>
<body>
{body}
<script>
  mermaid.initialize({{ startOnLoad: true, theme: "neutral", securityLevel: "loose" }});
</script>
</body>
</html>
"""


def md_to_html(md_text: str) -> str:
    """mermaid 代码块 → <pre class=\"mermaid\"> 供浏览器渲染。"""
    parts: list[str] = []
    pattern = re.compile(r"```mermaid\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)
    last = 0
    for m in pattern.finditer(md_text):
        parts.append(md_text[last : m.start()])
        diagram = m.group(1).strip()
        parts.append(f'<pre class="mermaid">\n{diagram}\n</pre>\n\n')
        last = m.end()
    parts.append(md_text[last:])
    processed = "".join(parts)

    return markdown.markdown(
        processed,
        extensions=[
            TableExtension(),
            "fenced_code",
            "nl2br",
            "sane_lists",
        ],
    )


def generate_pdf(md_path: Path, pdf_path: Path) -> None:
    md_text = md_path.read_text(encoding="utf-8")
    title = md_path.stem
    body_html = md_to_html(md_text)
    full_html = HTML_SHELL.format(title=title, body=body_html)

    html_tmp = pdf_path.with_suffix(".html")
    html_tmp.write_text(full_html, encoding="utf-8")

    file_url = html_tmp.resolve().as_uri()
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.goto(file_url, wait_until="networkidle", timeout=120_000)
        page.wait_for_timeout(3000)
        page.pdf(
            path=str(pdf_path),
            format="A4",
            print_background=True,
            margin={"top": "18mm", "bottom": "18mm", "left": "16mm", "right": "16mm"},
        )
        browser.close()

    print(f"OK: {pdf_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Markdown → PDF (mermaid via CDN)")
    parser.add_argument("input", type=Path, help="输入 .md 路径")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="输出 .pdf 路径（默认同目录同名）",
    )
    args = parser.parse_args()
    md_path = args.input.resolve()
    if not md_path.is_file():
        print(f"文件不存在: {md_path}", file=sys.stderr)
        return 1
    pdf_path = (args.output or md_path.with_suffix(".pdf")).resolve()
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    generate_pdf(md_path, pdf_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
