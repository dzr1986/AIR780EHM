#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doc/ 文档按内容主题归档工具（映射表长期保留作归档决策记录）。

分类依据 = doc/README.md 现有 8 个权威分组（术语/总览/硬件/电源/PIR/MQTT/T31x/发布），
收敛为 7 个主题子目录：
    overview/  术语·总览·架构·配置·治理计划
    hardware/  硬件/GPIO/指示灯/烧录口
    power/     电源/低功耗/USB/rest
    pir/       PIR/录像/提示音
    mqtt/      MQTT/编码/串口 AT/视频上传
    t31x/      T31x ↔ 4G 协作/监督
    release/   烧录/发布
历史/一次性/评审记录类 → doc/_audit/；OTA 旧路径迁移 stub → doc/archive/。

用法：
    python tools/debug/_doc_archive_by_topic.py --plan   # 仅打印搬迁计划
    python tools/debug/_doc_archive_by_topic.py --apply  # 执行 move + 全仓链接重算
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "doc"

# ---- 归档映射：文件名 -> 主题目录（doc/ 顶层文件全集） ----
MOVES: dict[str, str] = {
    # overview: 术语 / 总览 / 架构 / 配置 / 治理
    "CAT1_API_NAMING.md": "overview",
    "T31X_NAMING.md": "overview",
    "OPTIMIZATION_PLAN.md": "overview",
    "USER_LIB_OPTIMIZATION_NEXT.md": "overview",
    "USER_LIB_OPTIMIZATION_PLAN_20260830.md": "overview",
    "CODE_SIZE_OPTIMIZATION.md": "overview",
    "CONFIG.md": "overview",
    "CODE_DOC_AUDIT.md": "overview",
    "PROJECT_DOC.md": "overview",
    "CALL_GRAPH.md": "overview",
    "CODE_ANALYSIS.md": "overview",
    "LUA_MODULES.md": "overview",
    "CAT1_MODULE_FRAMEWORK.md": "overview",
    "TIME_SYNC.md": "overview",
    "SYSTEM_ARCHITECTURE.md": "overview",
    "CODE_LAYERING_ARCHITECTURE.md": "overview",
    "FUNCTIONAL_ARCHITECTURE.md": "overview",
    "ARCHITECTURE_REVIEW_20260903.md": "overview",
    "USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md": "overview",
    "CAT1_LOG_TAGS.md": "overview",
    # hardware: 硬件 / GPIO / 指示灯 / 烧录口
    "T31X_CAT1_GPIO.md": "hardware",
    "KEY_GPIO.md": "hardware",
    "T31X_BURN_MODE.md": "hardware",
    "LED_INDICATORS.md": "hardware",
    "PIR_HARDWARE.md": "hardware",
    # power: 电源 / 低功耗 / USB
    "CHARGE_BATTERY.md": "power",
    "LOW_BATTERY_AND_LOW_POWER.md": "power",
    "LOW_BATTERY_AND_LOW_POWER.pdf": "power",
    "WORK_MODE_PERSON_DETECT_PIR.md": "power",
    "PERSON_CNT_UART_MQTT_FLOW.md": "power",
    "LOW_POWER_ENTER_STRATEGY.md": "power",
    "BATTERY_REST_SWITCH_CONDITIONS.md": "power",
    "T31X_LOW_POWER.md": "power",
    "T31X_USB_HOSTIDLE.md": "power",
    "T31X_BATTERY_USB_T31X_OSCILLATION.md": "power",
    "POWER_USB_BATTERY_T31X_LOGIC.md": "power",
    "CAT1_LOWPWR_MQTT_TCP_STRATEGY.md": "power",
    "CAT1_SLIMMING_FLOW.md": "power",
    "CAT1_USER_LIB_SLIM.md": "power",
    "CAT1_LOGIC_SLIM.md": "power",
    "mqtt_battery_shutdown_flow.md": "power",
    # pir: PIR / 录像 / 提示音
    "PIR_PROTOCOL.md": "pir",
    "MQTT_2011_T31X_STOP_EXPLAINED.md": "pir",
    "PIR_TRIGGER_INTERVAL.md": "pir",
    "PIR_COOLDOWN_AND_COUNT.md": "pir",
    "T31X_RECORD_MQTT_FLOW.md": "pir",
    "BOOT_SHUTDOWN_SOUND.md": "pir",
    "mqtt_2010_2012_2011_pir_flow.md": "pir",
    "mqtt_2011_1011_flow.md": "pir",
    "mqtt_2012_1012_flow.md": "pir",
    # mqtt: MQTT / 编码 / 串口 AT / 视频上传
    "MQTT_PROTOCOL.md": "mqtt",
    "MQTT_2013_1013_UPLOAD_VIDEO.md": "mqtt",
    "MQTT_CLIP_UPLOAD_CLOSED_LOOP.md": "mqtt",
    "MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md": "mqtt",
    "MQTT_CLOUD_REMOTE_CTRL_FLOW.md": "mqtt",
    "T31X_IPC_CLOUD_EXCEPTION_REPORT.md": "mqtt",
    "MQTT_862323084068314.md": "mqtt",
    "MQTT_DOWNLINK_862323084068124.txt": "mqtt",
    "MQTT_DOWNLINK_862323084068314.txt": "mqtt",
    "mqtt_tfcard_format_flow.md": "mqtt",
    "MQTT_DOWNLINK.md": "mqtt",
    "MQTT_CLIENT_E2E_TEST.md": "mqtt",
    "MQTT_ALL_CMD_FLOW_TEST.md": "mqtt",
    "MQTT_231_CLOSED_LOOP_20260902.md": "mqtt",
    "REMOTE_ENCODE_CONFIG.md": "mqtt",
    "T31X_MQTT_PARAM_HOT_APPLY.md": "mqtt",
    "T31X_SOFTPHOTO_REPEAT_SWITCH.md": "mqtt",
    "T31X_ETH0_DHCP_SLOW_BOOT.md": "mqtt",
    "HOST_MQTT_UART.md": "mqtt",
    "MQTT_HOST_CONFIG_MODES.md": "mqtt",
    "UART_PROTOCOL.md": "mqtt",
    "MQTT_1003_STATUS_PATTERN.md": "mqtt",
    "MQTT_1013_BACKEND_GUIDE.md": "mqtt",
    "MQTT_2002_IPCPOWEROFF_T31_FLOW.md": "mqtt",
    "MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md": "mqtt",
    "CLIP_UPLOAD_CLOSED_LOOP_TEST.md": "mqtt",
    "allday_pir_record_backend_dispatch.md": "mqtt",
    "VIDEO_UPLOAD_SERVER.md": "mqtt",
    "UART_AT_COMMANDS.md": "mqtt",
    # t31x: T31x ↔ 4G 协作 / 监督
    "T31X_4G_FRAMEWORK.md": "t31x",
    "T31X_4G_AT_INTERACTION.md": "t31x",
    "T31X_CAT1_AT_COMMAND_SPEC.md": "t31x",
    "T31X_IPC_4G_INTERACTION.md": "t31x",
    "T31X_IPC_CAT1_COMM_COMPLETENESS.md": "t31x",
    "T31X_HOSTEVT_PROTOCOL.md": "t31x",
    "T31X_HOSTEVT_SLEEP.md": "t31x",
    "T31X_IPC_ALERT_CONTRACT.md": "t31x",
    "T31X_IPC_SUPERVISION_MODULE.md": "t31x",
    "T31X_IPC_CAT1_SUPERVISION.md": "t31x",
    "T31X_IPC_EXCEPTION_MQTT_UPLINK.md": "t31x",
    "T31X_IPC_ALERT_CODE_INDEX.md": "t31x",
    # release: 烧录 / 发布
    "CAT1_FLASH_FLOW.md": "release",
    "CAT1_FLASH_TOOL.md": "release",
    "CAT1_USB_RNDIS_CFG_CRASH_FLASH.md": "release",
    "RELEASE_v1.2.md": "release",
}

# 历史/一次性/评审记录 → _audit；OTA 迁移 stub → archive
TO_AUDIT: list[str] = [
    "FUNCTION_NAME_MAP.md",                           # ⚠历史：旧缩写实验，真源 CAT1_API_NAMING
    "WORK_MODE_BATTERY_20PCT.md",                     # 已被 WORK_MODE_PERSON_DETECT_PIR 取代
    "CAT1_TOOLCHAIN_TEST_REPORT.md",                  # 一次性测试报告 2026-08-17
    "MQTT_AUTOTEST_LOG_862323084068124_20260818.md",  # 一次性日志抄录
]
TO_ARCHIVE: list[str] = [
    "OTA_CHANNELS.md", "OTA_CONSOLE_UPGRADE.md", "OTA_FLOW.md", "OTA_LUAT_IOT_ADMIN_FLOW.md",
    "OTA_PROTOCOL.md", "OTA_REAL_DEVICE.md", "OTA_SELF.md", "OTA_SERVER.md",
]
KEEP_TOP = {"README.md"}

RE_INLINE = re.compile(r"!?\[[^]]*\]\((\s*[^)\s]+(?:\s+[^)]*)?)\)")
RE_REF = re.compile(r"^\s{0,3}\[([^]]+)\]:\s*(\S+)", re.MULTILINE)
RE_FENCE = re.compile(r"(?ms)^`{3,}[^\n]*\n.*?^`{3,}[^\n]*$")
RE_CODE = re.compile(r"(?<!`)(`[^`\n]+`)")


def split_segments(text: str) -> list[tuple[str, bool]]:
    """把 md 文本切成 (segment, is_code) 列表：fence(```) 与 inline code(``) 视为代码。"""
    segs: list[tuple[str, bool]] = []
    pos = 0
    for m in RE_FENCE.finditer(text):
        if m.start() > pos:
            segs.append((text[pos:m.start()], False))
        segs.append((m.group(0), True))
        pos = m.end()
    if pos < len(text):
        segs.append((text[pos:], False))
    return segs


def norm_key(p: Path) -> str:
    """Windows 大小写不敏感环境下的比较键（仅作字典查找用，不用于输出路径）。"""
    return os.path.normcase(str(Path(p)))


def real_abs(src_dir: Path, body: str) -> str:
    """把相对路径 body 拼到 src_dir，返回保留磁盘真实大小写的绝对路径字符串。"""
    p = src_dir / body
    # abspath 不做 normcase；对已存在部分 resolve 会纠正为磁盘真实大小写
    return os.path.normpath(os.path.abspath(str(p)))


def rel_posix(src_dir: Path, tgt_abs: str) -> str:
    return os.path.relpath(tgt_abs, str(src_dir)).replace("\\", "/")


def reroot_href(href: str, src_old_dir: Path, src_new_dir: Path,
                moved: dict[str, str]) -> str:
    """把链接目标（去掉 #锚点 后的本地相对路径）从旧源目录重算到新源目录。

    moved: norm_key(旧绝对) -> 新绝对路径（保留原大小写）。命中则指向新位置，
    否则目标文件未移动——输出路径必须保留原大小写，不可经 normcase。
    """
    body = href.split("#", 1)[0].split("?", 1)[0]
    if not body:
        return href
    old_abs = real_abs(src_old_dir, body)
    key = norm_key(Path(old_abs))
    if key in moved:
        new_abs = moved[key]
    else:
        new_abs = old_abs
    anchor = href[len(body):]
    return rel_posix(src_new_dir, new_abs) + anchor


def rewrite_text(text: str, src_old: Path, src_new: Path,
                 moved: dict[str, str], plain_map: dict[str, str]) -> tuple[str, int]:
    """重写一个文本文件的链接 href（非代码段）与纯文本 doc/ 旧路径。返回(新文本, href改动数)。"""
    n = [0]

    def sub_inline(m: re.Match) -> str:
        raw = m.group(0)
        head = raw.split("(", 1)[0]
        inner = m.group(1).strip()
        if not inner:
            return raw
        body = inner
        # 剥掉 title 字符串（形如 "xxx"），仅处理本地路径首 token
        tok = body.split()[0] if body.split() else body
        if tok.startswith(("<", "#", "http://", "https://", "mailto:", "tel:")):
            return raw
        new = reroot_href(tok, src_old.parent, src_new.parent, moved)
        n[0] += 1
        return f"{head}({new})"

    def sub_ref(m: re.Match) -> str:
        label, target = m.group(1), m.group(2)
        body = target.split("#", 1)[0].split("?", 1)[0]
        if body.startswith(("<", "#", "http://", "https://", "mailto:")):
            return m.group(0)
        new = reroot_href(body, src_old.parent, src_new.parent, moved)
        anchor = target[len(body):]
        n[0] += 1
        return f"[{label}]: {new}{anchor}"

    parts = split_segments(text)
    out: list[str] = []
    for seg, is_code in parts:
        if is_code:
            out.append(seg)
            continue
        seg = RE_INLINE.sub(sub_inline, seg)
        seg = RE_REF.sub(sub_ref, seg)
        # 纯文本 doc/<旧名> → doc/<新目录>/<旧名>（代码段已跳过；链接 href 已被更新不会再命中旧名）
        for old_name, new_path in plain_map.items():
            if old_name in seg:
                # 只替换非链接位置：href 形如 (...old_name...) 已变新，此处残余多为显示文本
                seg = seg.replace(f"doc/{old_name}", new_path)
        out.append(seg)
    return "".join(out), n[0]


def build_plan_rows() -> list[tuple[str, str]]:
    rows = [(name, topic) for name, topic in sorted(MOVES.items())]
    rows += [(name, "_audit") for name in TO_AUDIT]
    rows += [(name, "archive") for name in TO_ARCHIVE]
    return rows


def main() -> int:
    apply = "--apply" in sys.argv
    rows = build_plan_rows()

    top_files = {p.name for p in DOC.iterdir() if p.is_file()}
    declared = set(MOVES) | set(TO_AUDIT) | set(TO_ARCHIVE) | KEEP_TOP
    undeclared = sorted(top_files - declared)
    if undeclared:
        print("!! doc 顶层未声明文件（拒绝执行）: %s" % undeclared)
        return 2

    # 搬迁表
    plan: list[tuple[Path, Path]] = []
    for name, topic in rows:
        plan.append((DOC / name, DOC / topic / name))

    if not apply:
        print("=== doc 主题归档搬迁计划 (%d 项) ===" % len(plan))
        from collections import Counter
        cnt: Counter = Counter()
        for oldp, newp in plan:
            topic = newp.parent.name
            cnt[topic] += 1
            print("  %-55s -> %s/" % (f"doc/{oldp.name}", topic))
        print("\n目标目录分布:")
        for k in sorted(cnt):
            print("  %-10s %d" % (k + "/", cnt[k]))
        return 0

    # ---- 1) 全仓链接重算（必须在移动前：旧路径 resolve 才能命中 moved 表） ----
    plain_map: dict[str, str] = {}
    for name, topic in rows:
        plain_map[name] = f"doc/{topic}/{name}"

    # 移动表：norm_key(旧绝对) -> 新绝对路径（保留原大小写）
    moved: dict[str, str] = {}
    for name, topic in rows:
        moved[norm_key(DOC / name)] = str(DOC / topic / name)

    skip_dirs = {".git", "_logs", "_cache", "__pycache__", "node_modules", "dist"}
    changed_files = changed_links = 0
    for root, dirs, files in os.walk(ROOT):
        rootp = Path(root)
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith(".")]
        for f in files:
            ext = f.lower().rsplit(".", 1)[-1] if "." in f else ""
            if ext != "md" and not (ext in ("txt", "html") and rootp.is_relative_to(DOC)):
                continue
            src = rootp / f
            # 源文件自身若将被移动：其链接以 doc/顶层为旧基准、topic/ 子目录为新基准重算
            src_new = src
            if norm_key(src) in moved:
                src_new = Path(moved[norm_key(src)])
            try:
                text = src.read_text(encoding="utf-8")
            except Exception:
                text = src.read_text(encoding="utf-8", errors="ignore")
            out, n = rewrite_text(text, src, src_new, moved, plain_map)
            if out != text:
                src.write_text(out, encoding="utf-8")
                changed_files += 1
                changed_links += n
    print("rewrote links in %d files (%d link targets)" % (changed_files, changed_links))

    # ---- 2) 执行搬迁 ----
    for name, topic in rows:
        oldp, newp = DOC / name, DOC / topic / name
        newp.parent.mkdir(parents=True, exist_ok=True)
        oldp.replace(newp)
    print("moved %d files" % len(plan))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
