# -*- coding: utf-8 -*-
"""Generate OTA system flowcharts as drawio / SVG / HTML (no markdown)."""
from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parents[1] / "diagrams"
OUT.mkdir(exist_ok=True)

C_NAV = "#1b3a5f"
C_BOX = "#dae8fc"
C_BOX_B = "#6c8ebf"
C_DEC = "#fff2cc"
C_DEC_B = "#d6b656"
C_OK = "#d5e8d4"
C_OK_B = "#82b366"
C_BAD = "#f8cecc"
C_BAD_B = "#b85450"
C_SWIM = "#f5f8fb"
C_LINE = "#4d5d6d"


def svg_head(w: int, h: int, title: str) -> str:
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <title>{escape(title)}</title>
  <rect width="100%" height="100%" fill="#ffffff"/>
  <style>
    .t {{ font-family: "Microsoft YaHei","PingFang SC","Noto Sans SC",sans-serif; font-size: 14px; fill: #1f2d3d; }}
    .th {{ font-family: "Microsoft YaHei","PingFang SC","Noto Sans SC",sans-serif; font-size: 18px; font-weight: 700; fill: #1b3a5f; }}
    .ts {{ font-family: "Microsoft YaHei","PingFang SC","Noto Sans SC",sans-serif; font-size: 12px; fill: #5a6a7a; }}
    .tl {{ font-family: "Microsoft YaHei","PingFang SC","Noto Sans SC",sans-serif; font-size: 11px; fill: #1b3a5f; }}
  </style>
'''


def rect(x, y, w, h, fill, stroke, text, rx=8, ts="t") -> str:
    lines = escape(text).split("\n")
    mid = y + h / 2 - (len(lines) - 1) * 9
    tspans = "".join(
        f'<tspan x="{x + w/2}" dy="{0 if i == 0 else 18}">{ln}</tspan>'
        for i, ln in enumerate(lines)
    )
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>'
        f'<text class="{ts}" x="{x + w/2}" y="{mid + 5}" text-anchor="middle">{tspans}</text>\n'
    )


def diamond(cx, cy, w, h, text) -> str:
    pts = f"{cx},{cy - h/2} {cx + w/2},{cy} {cx},{cy + h/2} {cx - w/2},{cy}"
    lines = escape(text).split("\n")
    mid = cy - (len(lines) - 1) * 8
    tspans = "".join(
        f'<tspan x="{cx}" dy="{0 if i == 0 else 16}">{ln}</tspan>'
        for i, ln in enumerate(lines)
    )
    return (
        f'<polygon points="{pts}" fill="{C_DEC}" stroke="{C_DEC_B}" stroke-width="1.5"/>'
        f'<text class="ts" x="{cx}" y="{mid + 4}" text-anchor="middle">{tspans}</text>\n'
    )


def arrow(x1, y1, x2, y2, label="") -> str:
    extra = ""
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        extra = f'<text class="tl" x="{mx + 6}" y="{my - 6}">{escape(label)}</text>'
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{C_LINE}" stroke-width="1.4" marker-end="url(#arr)"/>'
        f"{extra}\n"
    )


def marker() -> str:
    return '''<defs>
  <marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
    <path d="M 0 0 L 10 5 L 0 10 z" fill="#4d5d6d"/>
  </marker>
</defs>
'''


def group(x, y, w, h, title) -> str:
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{C_SWIM}" stroke="#9aa8b5"/>'
        f'<rect x="{x}" y="{y}" width="{w}" height="28" rx="10" fill="{C_NAV}"/>'
        f'<rect x="{x}" y="{y + 18}" width="{w}" height="10" fill="{C_NAV}"/>'
        f'<text class="t" x="{x + 12}" y="{y + 19}" fill="#ffffff">{escape(title)}</text>\n'
    )


def write_deploy() -> str:
    s = [svg_head(1100, 620, "4G OTA 部署架构")]
    s.append(marker())
    s.append('<text class="th" x="40" y="36">4G OTA 部署架构</text>')
    s.append('<text class="ts" x="40" y="56">腾讯云 43.136.55.143 · MQTT 不经过 Nginx</text>')
    s.append(group(40, 80, 280, 480, "公网"))
    s.append(rect(80, 140, 200, 56, C_BOX, C_BOX_B, "浏览器管理台"))
    s.append(rect(80, 420, 200, 56, C_BOX, C_BOX_B, "4G 模组"))
    s.append(group(380, 80, 360, 480, "腾讯云 43.136.55.143"))
    s.append(rect(440, 140, 240, 56, C_BOX, C_BOX_B, "Nginx :80"))
    s.append(rect(440, 250, 240, 56, C_BOX, C_BOX_B, "ota-server :8080"))
    s.append(rect(440, 360, 240, 56, "#e1d5e7", "#9673a6", "MySQL  luat_ota"))
    s.append(rect(440, 460, 240, 56, "#e1d5e7", "#9673a6", "firmware 目录"))
    s.append(rect(800, 250, 240, 70, "#f5f5f5", C_LINE, "MQTT Broker\n112.86.146.218:2123"))
    s.append(arrow(280, 168, 440, 168, "HTTP Token"))
    s.append(arrow(280, 448, 440, 168, "HTTP 拉包"))
    s.append(arrow(560, 196, 560, 250))
    s.append(arrow(560, 306, 560, 360))
    s.append(arrow(560, 416, 560, 460))
    s.append(arrow(680, 278, 800, 278, "2004 / 1004"))
    s.append(arrow(280, 448, 800, 300, "MQTT 上下行"))
    s.append("</svg>")
    return "".join(s)


def write_upgrade() -> str:
    actors = [
        (80, "运维"),
        (250, "管理台"),
        (430, "ota-server"),
        (620, "MySQL"),
        (800, "MQTT"),
        (980, "4G 模组"),
    ]
    steps = [
        (130, 250, 430, "1 上传差分包"),
        (130, 430, 620, "2 写入固件库 / 文件"),
        (190, 250, 430, "3 POST /ota/trigger"),
        (190, 430, 800, "4 MQTT 2004 url+version"),
        (190, 800, 980, "5 /panshi/device/{IMEI}/"),
        (270, 980, 800, "6 1004 accepted"),
        (270, 800, 430, "7 任务 ACCEPTED"),
        (350, 980, 430, "8 GET firmware_upgrade"),
        (410, 430, 980, "9a 200 + bin"),
        (470, 430, 980, "9b 或 >=300"),
        (530, 980, 800, "10 1004 success"),
        (530, 800, 620, "11 版本/任务 SUCCESS"),
        (590, 980, 980, "12 模组重启"),
    ]
    s = [svg_head(1200, 680, "4G OTA 端到端升级")]
    s.append(marker())
    s.append('<text class="th" x="40" y="36">端到端升级主流程</text>')
    s.append('<text class="ts" x="40" y="56">控制面 MQTT 2004 · 数据面 HTTP 拉包 · 进度 1004</text>')
    for x, name in actors:
        s.append(rect(x - 55, 80, 110, 40, C_NAV, C_NAV, name, ts="t"))
        s.append(f'<line x1="{x}" y1="120" x2="{x}" y2="640" stroke="#c5d0da" stroke-width="2" stroke-dasharray="4 4"/>')
        s.append(f'<text class="t" x="{x}" y="80" text-anchor="middle" fill="#ffffff"></text>')
    # fix header text color - rect already has white? C_NAV fill with dark text is bad
    # redo actor headers with white text
    s = [svg_head(1200, 680, "4G OTA 端到端升级"), marker()]
    s.append('<text class="th" x="40" y="36">端到端升级主流程</text>')
    s.append('<text class="ts" x="40" y="56">控制面 MQTT 2004 · 数据面 HTTP 拉包 · 进度 1004</text>')
    for x, name in actors:
        s.append(f'<rect x="{x-55}" y="72" width="110" height="40" rx="8" fill="{C_NAV}" stroke="{C_NAV}"/>')
        s.append(f'<text class="t" x="{x}" y="97" text-anchor="middle" fill="#ffffff">{escape(name)}</text>')
        s.append(f'<line x1="{x}" y1="112" x2="{x}" y2="650" stroke="#c5d0da" stroke-width="2" stroke-dasharray="4 4"/>')
    colors = {
        9: (C_OK, C_OK_B),
        10: (C_BAD, C_BAD_B),
    }
    for y, x1, x2, label in steps:
        left, right = min(x1, x2), max(x1, x2)
        fill, stroke = C_BOX, C_BOX_B
        if label.startswith("9a"):
            fill, stroke = C_OK, C_OK_B
        elif label.startswith("9b"):
            fill, stroke = C_BAD, C_BAD_B
        s.append(f'<line x1="{left}" y1="{y}" x2="{right}" y2="{y}" stroke="{C_LINE}" stroke-width="1.4" marker-end="url(#arr)"/>')
        s.append(f'<rect x="{(left+right)/2 - 110}" y="{y-14}" width="220" height="28" rx="6" fill="{fill}" stroke="{stroke}"/>')
        s.append(f'<text class="ts" x="{(left+right)/2}" y="{y+5}" text-anchor="middle">{escape(label)}</text>')
    s.append("</svg>")
    return "".join(s)


def write_decision() -> str:
    s = [svg_head(980, 980, "拉包决策")]
    s.append(marker())
    s.append('<text class="th" x="40" y="36">HTTP 拉包决策</text>')
    s.append('<text class="ts" x="40" y="56">GET /api/site/firmware_upgrade</text>')
    s.append(rect(360, 80, 260, 48, C_BOX, C_BOX_B, "GET firmware_upgrade"))
    s.append(diamond(490, 190, 220, 80, "项目 Key 存在?"))
    s.append(rect(720, 170, 180, 44, C_BAD, C_BAD_B, "26 无效项目"))
    s.append(diamond(490, 300, 220, 80, "IMEI 项目冲突?"))
    s.append(rect(720, 280, 180, 44, C_BAD, C_BAD_B, "25 无权限"))
    s.append(diamond(490, 410, 220, 80, "设备禁止升级?"))
    s.append(rect(80, 390, 180, 44, C_BAD, C_BAD_B, ">=300"))
    s.append(diamond(490, 520, 220, 80, "固件名在库中?"))
    s.append(rect(720, 500, 180, 44, C_BAD, C_BAD_B, "27 无效固件"))
    s.append(diamond(490, 630, 240, 90, "源版本匹配\n目标更高 / 指定设备"))
    s.append(diamond(490, 760, 220, 80, "文件>0 字节?"))
    s.append(rect(80, 740, 180, 44, C_BAD, C_BAD_B, "404 空包"))
    s.append(diamond(490, 870, 240, 80, "连续同目标>=6?"))
    s.append(rect(80, 850, 200, 44, C_BAD, C_BAD_B, "禁止设备 >=300"))
    s.append(rect(720, 850, 200, 48, C_OK, C_OK_B, "200 / 206 返回 bin"))
    s.append(arrow(490, 128, 490, 150))
    s.append(arrow(600, 190, 720, 192, "否"))
    s.append(arrow(490, 230, 490, 260, "是"))
    s.append(arrow(600, 300, 720, 302, "冲突"))
    s.append(arrow(490, 340, 490, 370, "否"))
    s.append(arrow(380, 410, 260, 412, "禁止"))
    s.append(arrow(490, 450, 490, 480, "允许"))
    s.append(arrow(600, 520, 720, 522, "否"))
    s.append(arrow(490, 560, 490, 585, "是"))
    s.append(arrow(370, 630, 170, 412, "否"))
    s.append(arrow(490, 675, 490, 720, "是"))
    s.append(arrow(380, 760, 260, 762, "否"))
    s.append(arrow(490, 800, 490, 830, "是"))
    s.append(arrow(370, 870, 280, 872, "是"))
    s.append(arrow(610, 870, 720, 874, "否"))
    s.append("</svg>")
    return "".join(s)


def write_admin() -> str:
    s = [svg_head(1100, 420, "管理台业务")]
    s.append(marker())
    s.append('<text class="th" x="40" y="36">管理台业务流</text>')
    items = [
        (40, 100, "登录 Token"),
        (200, 100, "我的项目"),
        (360, 40, "我的设备"),
        (360, 100, "固件列表"),
        (360, 160, "固件升级"),
        (360, 220, "闭环测试"),
        (540, 40, "允许/禁止"),
        (540, 100, "创建固件"),
        (540, 160, "我的任务"),
        (720, 100, "指定 IMEI"),
        (720, 160, "调试日志"),
    ]
    for x, y, t in items:
        fill = C_OK if t in ("登录 Token", "我的项目") else C_BOX
        s.append(rect(x, y, 140, 44, fill, C_BOX_B if fill == C_BOX else C_OK_B, t))
    s.append(arrow(180, 122, 200, 122))
    s.append(arrow(340, 82, 360, 62))
    s.append(arrow(340, 122, 360, 122))
    s.append(arrow(340, 122, 360, 182))
    s.append(arrow(340, 122, 360, 242))
    s.append(arrow(500, 62, 540, 62))
    s.append(arrow(500, 122, 540, 122))
    s.append(arrow(500, 182, 540, 182))
    s.append(arrow(680, 122, 720, 122))
    s.append(arrow(680, 182, 720, 182))
    s.append(rect(40, 300, 1020, 80, "#f7f9fb", "#cfd6de",
                  "落库：ota_projects / devices / firmware_packages / ota_tasks    日志：ota-audit.jsonl"))
    s.append("</svg>")
    return "".join(s)


def drawio_cell(cid, value, style, x, y, w, h, parent="1", vertex=True) -> str:
    geom = f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/>'
    v = ' vertex="1"' if vertex else ""
    return f'<mxCell id="{cid}" value="{escape(value)}" style="{style}" parent="{parent}"{v}>{geom}</mxCell>'


def drawio_edge(cid, source, target, value="", parent="1") -> str:
    style = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeColor=#4d5d6d;"
    val = f' value="{escape(value)}"' if value else ""
    return (
        f'<mxCell id="{cid}"{val} style="{style}" edge="1" parent="{parent}" source="{source}" target="{target}">'
        f'<mxGeometry relative="1" as="geometry"/></mxCell>'
    )


BOX = "rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;fontFamily=Microsoft YaHei;fontSize=13;"
OK = "rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;fontFamily=Microsoft YaHei;fontSize=13;"
BAD = "rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;fontFamily=Microsoft YaHei;fontSize=13;"
DEC = "rhombus;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;fontFamily=Microsoft YaHei;fontSize=12;"
SWIM = "swimlane;startSize=28;fillColor=#1b3a5f;swimlaneFillColor=#f5f8fb;strokeColor=#9aa8b5;fontFamily=Microsoft YaHei;fontSize=13;fontColor=#ffffff;"
NAV = "rounded=1;whiteSpace=wrap;html=1;fillColor=#1b3a5f;fontColor=#ffffff;strokeColor=#1b3a5f;fontFamily=Microsoft YaHei;fontSize=13;"
PUR = "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;backgroundOutline=1;size=12;fillColor=#e1d5e7;strokeColor=#9673a6;fontFamily=Microsoft YaHei;fontSize=13;"


def page_deploy() -> str:
    cells = [
        '<mxCell id="0"/>',
        '<mxCell id="1" parent="0"/>',
        drawio_cell("g1", "公网", SWIM, 40, 40, 280, 360),
        drawio_cell("b1", "浏览器管理台", BOX, 50, 50, 180, 50, "g1"),
        drawio_cell("d1", "4G 模组", BOX, 50, 250, 180, 50, "g1"),
        drawio_cell("g2", "腾讯云 43.136.55.143", SWIM, 380, 40, 320, 360),
        drawio_cell("n1", "Nginx :80", BOX, 50, 50, 220, 50, "g2"),
        drawio_cell("a1", "ota-server :8080", BOX, 50, 140, 220, 50, "g2"),
        drawio_cell("m1", "MySQL luat_ota", PUR, 50, 230, 220, 70, "g2"),
        drawio_cell("mq", "MQTT Broker&#xa;112.86.146.218:2123", BOX, 760, 180, 220, 70),
        drawio_edge("e1", "b1", "n1", "HTTP Token"),
        drawio_edge("e2", "d1", "n1", "HTTP 拉包"),
        drawio_edge("e3", "n1", "a1"),
        drawio_edge("e4", "a1", "m1"),
        drawio_edge("e5", "a1", "mq", "2004 / 1004"),
        drawio_edge("e6", "d1", "mq", "MQTT 上下行"),
    ]
    return "".join(cells)


def page_upgrade() -> str:
    names = ["运维", "管理台", "ota-server", "MySQL", "MQTT", "4G 模组"]
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    xs = [40, 200, 380, 560, 740, 920]
    for i, (x, n) in enumerate(zip(xs, names), 1):
        cells.append(drawio_cell(f"h{i}", n, NAV, x, 40, 140, 40))
    steps = [
        ("s1", "1 上传差分包", 200, 110, 320, 40, OK),
        ("s2", "2 写入固件库与文件", 380, 170, 320, 40, BOX),
        ("s3", "3 POST /ota/trigger", 200, 230, 320, 40, BOX),
        ("s4", "4 MQTT 2004 url+version", 380, 290, 500, 40, BOX),
        ("s5", "5 模组收到 2004", 740, 350, 320, 40, BOX),
        ("s6", "6 1004 accepted", 380, 410, 500, 40, BOX),
        ("s7", "7 GET /api/site/firmware_upgrade", 380, 470, 500, 40, BOX),
        ("s8", "8a 200 + bin", 380, 530, 220, 40, OK),
        ("s9", "8b HTTP &gt;=300", 640, 530, 220, 40, BAD),
        ("s10", "9 1004 success → 版本落库 → 重启", 380, 600, 500, 40, OK),
    ]
    for cid, val, x, y, w, h, st in steps:
        cells.append(drawio_cell(cid, val, st, x, y, w, h))
    cells += [
        drawio_edge("ue1", "s1", "s2"),
        drawio_edge("ue2", "s2", "s3"),
        drawio_edge("ue3", "s3", "s4"),
        drawio_edge("ue4", "s4", "s5"),
        drawio_edge("ue5", "s5", "s6"),
        drawio_edge("ue6", "s6", "s7"),
        drawio_edge("ue7", "s7", "s8"),
        drawio_edge("ue8", "s7", "s9"),
        drawio_edge("ue9", "s8", "s10"),
    ]
    return "".join(cells)


def page_decision() -> str:
    cells = [
        '<mxCell id="0"/>',
        '<mxCell id="1" parent="0"/>',
        drawio_cell("a", "GET /api/site/firmware_upgrade", BOX, 320, 20, 280, 50),
        drawio_cell("b", "项目 Key 存在?", DEC, 330, 100, 260, 80),
        drawio_cell("c", "26 无效项目", BAD, 660, 118, 180, 44),
        drawio_cell("d", "IMEI 项目冲突?", DEC, 330, 210, 260, 80),
        drawio_cell("e", "25 无权限", BAD, 660, 228, 180, 44),
        drawio_cell("f", "设备禁止升级?", DEC, 330, 320, 260, 80),
        drawio_cell("g", "&gt;=300", BAD, 40, 338, 180, 44),
        drawio_cell("h", "固件名在库中?", DEC, 330, 430, 260, 80),
        drawio_cell("i", "27 无效固件", BAD, 660, 448, 180, 44),
        drawio_cell("j", "源版本匹配且目标更高&#xa;升级全部或指定 IMEI", DEC, 310, 540, 300, 100),
        drawio_cell("k", "文件存在且 &gt;0 字节?", DEC, 330, 670, 260, 80),
        drawio_cell("l", "404 拒绝空包", BAD, 40, 688, 180, 44),
        drawio_cell("m", "连续同目标 &gt;=6 次?", DEC, 330, 780, 260, 80),
        drawio_cell("n", "禁止该设备 &gt;=300", BAD, 40, 798, 200, 44),
        drawio_cell("o", "200 / 206 返回 bin", OK, 660, 798, 200, 50),
        drawio_edge("de1", "a", "b"),
        drawio_edge("de2", "b", "c", "否"),
        drawio_edge("de3", "b", "d", "是"),
        drawio_edge("de4", "d", "e", "冲突"),
        drawio_edge("de5", "d", "f", "否"),
        drawio_edge("de6", "f", "g", "禁止"),
        drawio_edge("de7", "f", "h", "允许"),
        drawio_edge("de8", "h", "i", "否"),
        drawio_edge("de9", "h", "j", "是"),
        drawio_edge("de10", "j", "g", "否"),
        drawio_edge("de11", "j", "k", "是"),
        drawio_edge("de12", "k", "l", "否"),
        drawio_edge("de13", "k", "m", "是"),
        drawio_edge("de14", "m", "n", "是"),
        drawio_edge("de15", "m", "o", "否"),
    ]
    return "".join(cells)


def page_admin() -> str:
    cells = [
        '<mxCell id="0"/>',
        '<mxCell id="1" parent="0"/>',
        drawio_cell("l", "登录 Token", OK, 40, 120, 140, 50),
        drawio_cell("p", "我的项目", BOX, 230, 120, 140, 50),
        drawio_cell("d", "我的设备", BOX, 430, 20, 140, 50),
        drawio_cell("f", "固件列表", BOX, 430, 120, 140, 50),
        drawio_cell("t", "固件升级 2004", BOX, 430, 220, 140, 50),
        drawio_cell("c", "闭环测试", BOX, 430, 320, 140, 50),
        drawio_cell("ban", "允许 / 禁止", BOX, 630, 20, 140, 50),
        drawio_cell("u", "创建固件", BOX, 630, 120, 140, 50),
        drawio_cell("task", "我的任务", BOX, 630, 220, 140, 50),
        drawio_cell("all", "指定 IMEI / 升级全部", BOX, 830, 120, 180, 50),
        drawio_cell("log", "调试日志", BOX, 830, 220, 140, 50),
        drawio_edge("ae1", "l", "p"),
        drawio_edge("ae2", "p", "d"),
        drawio_edge("ae3", "p", "f"),
        drawio_edge("ae4", "p", "t"),
        drawio_edge("ae5", "p", "c"),
        drawio_edge("ae6", "d", "ban"),
        drawio_edge("ae7", "f", "u"),
        drawio_edge("ae8", "u", "all"),
        drawio_edge("ae9", "t", "task"),
        drawio_edge("ae10", "t", "log"),
    ]
    return "".join(cells)


def wrap_page(name, pid, cells, w=1200, h=900) -> str:
    return (
        f'<diagram id="{pid}" name="{escape(name)}">'
        f'<mxGraphModel dx="1200" dy="800" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
        f'arrows="1" fold="1" page="1" pageScale="1" pageWidth="{w}" pageHeight="{h}" math="0" shadow="0">'
        f"<root>{cells}</root></mxGraphModel></diagram>"
    )


def write_drawio() -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<mxfile host="app.diagrams.net" type="device">'
        + wrap_page("1 部署架构", "p1", page_deploy(), 1100, 500)
        + wrap_page("2 升级主流程", "p2", page_upgrade(), 1200, 720)
        + wrap_page("3 拉包决策", "p3", page_decision(), 1000, 940)
        + wrap_page("4 管理台业务", "p4", page_admin(), 1100, 440)
        + "</mxfile>"
    )


def write_html(svgs: dict[str, str]) -> str:
    parts = [
        "<!DOCTYPE html><html lang='zh-CN'><head><meta charset='UTF-8'>",
        "<title>4G OTA 系统流程图</title>",
        "<style>body{font-family:'Microsoft YaHei',sans-serif;margin:24px;background:#f4f6f8;color:#1f2d3d}",
        "h1{font-size:22px} h2{font-size:16px;margin-top:28px}",
        ".card{background:#fff;border:1px solid #e4e8ee;border-radius:8px;padding:16px;margin:16px 0;overflow:auto}</style>",
        "</head><body><h1>4G OTA 系统流程图</h1>",
        "<p>可用浏览器打开本页后打印为 PDF。可编辑源文件：<code>ota-system.drawio</code>（diagrams.net）。</p>",
    ]
    titles = {
        "01-deploy.svg": "部署架构",
        "02-upgrade.svg": "端到端升级",
        "03-decision.svg": "拉包决策",
        "04-admin.svg": "管理台业务",
    }
    for name, title in titles.items():
        inner = svgs[name]
        inner = inner.split(">", 1)[1] if inner.startswith("<?xml") else inner
        # keep svg tag
        if inner.lstrip().startswith("svg"):
            pass
        parts.append(f"<h2>{escape(title)}</h2><div class='card'>")
        # embed full svg
        svg = svgs[name]
        if svg.startswith("<?xml"):
            svg = svg[svg.find("<svg"):]
        parts.append(svg)
        parts.append("</div>")
    parts.append("</body></html>")
    return "".join(parts)


def main() -> None:
    files = {
        "01-deploy.svg": write_deploy(),
        "02-upgrade.svg": write_upgrade(),
        "03-decision.svg": write_decision(),
        "04-admin.svg": write_admin(),
        "ota-system.drawio": write_drawio(),
    }
    files["ota-system.html"] = write_html(files)
    for name, content in files.items():
        path = OUT / name
        path.write_text(content, encoding="utf-8")
        print("wrote", path)


if __name__ == "__main__":
    main()
