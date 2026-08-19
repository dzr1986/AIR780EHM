#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""回放时间窗匹配：任意用户时间 ↔ TF/国标录像段，再拆成 2013 抽片窗。

T31 `clip_extract_window` 按 [start,end] 扫 `/mnt/sdcard/media/vi0/ch0_开始_结束.ts`，
以 I 帧定位，不必文件名完全等于用户时间。上位机要做的是：

1. 列出录像段（国标 RecordInfo 或 TF 文件名）
2. 求与用户窗重叠的段，给用户看会抽到哪些文件
3. 把要下发的时间按单段最长 600 秒切开（Cat.1 `resolveUploadWindow` 会截前 600s）
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

FMT = "%Y-%m-%d %H:%M:%S"
TF_SEG_RE = re.compile(r"(ch0_(\d{14})_(\d{14})\.(ts|mp4))$", re.I)
MAX_UPLOAD_SEC = 600
CLOUD_VIDEO_BASES = (
    "http://43.136.55.143:7003",
    "http://43.136.55.143",
)
CLOUD_UA = "mqtt-tools-playback/1.0"


def parse_dt(text: str) -> datetime:
    s = (text or "").strip()
    if not s:
        raise ValueError("时间为空")
    if s.isdigit():
        n = int(s)
        if n > 10**12:
            n //= 1000
        return datetime.fromtimestamp(n)
    for fmt in (FMT, "%Y-%m-%dT%H:%M:%S", "%Y%m%d%H%M%S"):
        try:
            return datetime.strptime(s[:19] if "T" in s or " " in s else s, fmt)
        except ValueError:
            continue
    raise ValueError(f"无法解析时间：{text}")


def fmt_dt(dt: datetime) -> str:
    return dt.strftime(FMT)


def overlap(
    a0: datetime, a1: datetime, b0: datetime, b1: datetime
) -> tuple[datetime, datetime] | None:
    start = max(a0, b0)
    end = min(a1, b1)
    if end <= start:
        return None
    return start, end


def split_window(
    begin: datetime, end: datetime, max_sec: int = MAX_UPLOAD_SEC
) -> list[tuple[datetime, datetime]]:
    if end <= begin:
        raise ValueError("结束时间必须晚于开始时间")
    cap = max(1, int(max_sec or MAX_UPLOAD_SEC))
    out: list[tuple[datetime, datetime]] = []
    cur = begin
    while cur < end:
        nxt = min(end, cur + timedelta(seconds=cap))
        out.append((cur, nxt))
        cur = nxt
    return out


def match_segments(
    user_begin: datetime,
    user_end: datetime,
    segments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """返回与用户窗重叠的录像段，带 overlap_begin/overlap_end。"""
    if user_end <= user_begin:
        raise ValueError("结束时间必须晚于开始时间")
    hits: list[dict[str, Any]] = []
    for seg in segments or []:
        try:
            a = parse_dt(str(seg.get("begin") or ""))
            b = parse_dt(str(seg.get("end") or ""))
        except ValueError:
            continue
        ov = overlap(user_begin, user_end, a, b)
        if not ov:
            continue
        item = dict(seg)
        item["overlap_begin"] = fmt_dt(ov[0])
        item["overlap_end"] = fmt_dt(ov[1])
        hits.append(item)
    hits.sort(key=lambda x: x.get("overlap_begin") or "")
    return hits


def plan_uploads(
    user_begin: datetime,
    user_end: datetime,
    segments: list[dict[str, Any]] | None = None,
    max_sec: int = MAX_UPLOAD_SEC,
) -> dict[str, Any]:
    """规划 2013 时间窗。

    有录像段：用户窗 ∩ 重叠段并集，再按 max_sec 切开。
    无录像段：直接把用户窗切开（设备自己扫 TF）。
    """
    if user_end <= user_begin:
        raise ValueError("结束时间必须晚于开始时间")
    hits = match_segments(user_begin, user_end, segments or [])
    if hits:
        clip_b = parse_dt(hits[0]["overlap_begin"])
        clip_e = parse_dt(hits[-1]["overlap_end"])
        source = "overlap"
        note = f"与 {len(hits)} 段录像重叠，抽 {fmt_dt(clip_b)} ~ {fmt_dt(clip_e)}"
    else:
        clip_b, clip_e = user_begin, user_end
        source = "user"
        note = "列表里没有重叠段，仍按用户时间下发，由设备扫 TF"
    windows = [{"begin": fmt_dt(a), "end": fmt_dt(b)} for a, b in split_window(clip_b, clip_e, max_sec)]
    if len(windows) > 1:
        note += f"；拆成 {len(windows)} 条 2013（单段≤{max_sec}秒）"
    return {
        "user_begin": fmt_dt(user_begin),
        "user_end": fmt_dt(user_end),
        "clip_begin": fmt_dt(clip_b),
        "clip_end": fmt_dt(clip_e),
        "hits": hits,
        "windows": windows,
        "source": source,
        "note": note,
    }


ISO_DT_RE = re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})")


def parse_record_list_text(text: str) -> list[dict[str, Any]]:
    """从 LiveGBS 表格粘贴 / ls 输出解析录像段。

    支持：
    - ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts
    - 一行里两个 ISO 时间（开始、结束），如 2026-08-19T00:06:03
    """
    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or line.lower().startswith("通道") or ".part" in line.lower():
            continue
        name = ""
        begin_s = end_s = ""
        m = TF_SEG_RE.search(line)
        if m:
            name, a, b, _ext = m.group(1), m.group(2), m.group(3), m.group(4)
            try:
                begin_s = fmt_dt(datetime.strptime(a, "%Y%m%d%H%M%S"))
                end_s = fmt_dt(datetime.strptime(b, "%Y%m%d%H%M%S"))
            except ValueError:
                begin_s = end_s = ""
        if not begin_s:
            times = ISO_DT_RE.findall(line)
            if len(times) >= 2:
                try:
                    begin_s = fmt_dt(parse_dt(times[0]))
                    end_s = fmt_dt(parse_dt(times[1]))
                except ValueError:
                    begin_s = end_s = ""
                if not name:
                    bits = line.split()
                    name = next((x for x in bits if x.startswith("ch0_")), bits[1] if len(bits) > 1 else "")
        if not begin_s or not end_s:
            continue
        key = (begin_s, end_s)
        if key in seen:
            continue
        seen.add(key)
        size = ""
        sm = re.search(r"(\d+(?:\.\d+)?)\s*MB", line, re.I)
        if sm:
            size = sm.group(0)
        day = parse_dt(begin_s).strftime("%Y%m%d")
        out.append({
            "src": "国标/TF",
            "begin": begin_s,
            "end": end_s,
            "name": name or f"ch0_{parse_dt(begin_s).strftime('%Y%m%d%H%M%S')}_{parse_dt(end_s).strftime('%Y%m%d%H%M%S')}.ts",
            "size": size,
            "path": f"/mnt/sdcard/media/vi0/{day}/{name}" if name else "",
        })
    out.sort(key=lambda x: x["begin"], reverse=True)
    return out


def parse_tf_listing(text: str, win_begin: datetime, win_end: datetime) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or ".part" in line.lower():
            continue
        m = TF_SEG_RE.search(line)
        if not m:
            continue
        name, a, b, _ext = m.group(1), m.group(2), m.group(3), m.group(4)
        try:
            seg_b = datetime.strptime(a, "%Y%m%d%H%M%S")
            seg_e = datetime.strptime(b, "%Y%m%d%H%M%S")
        except ValueError:
            continue
        if seg_e <= win_begin or seg_b >= win_end:
            continue
        size = ""
        parts = line.split()
        if len(parts) >= 5 and parts[4].isdigit():
            size = parts[4]
        day = a[:8]
        out.append({
            "src": "国标/TF",
            "begin": fmt_dt(seg_b),
            "end": fmt_dt(seg_e),
            "name": name,
            "size": size,
            "path": f"/mnt/sdcard/media/vi0/{day}/{name}",
        })
    out.sort(key=lambda x: x["begin"], reverse=True)
    return out


def cloud_get_json(path: str, query: dict | None = None, timeout: float = 12.0) -> Any:
    qs = ("?" + urlencode(query, safe=":- ")) if query else ""
    last_err: Exception | None = None
    for base in CLOUD_VIDEO_BASES:
        url = base.rstrip("/") + path + qs
        try:
            req = Request(url, headers={"User-Agent": CLOUD_UA})
            with urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw)
        except Exception as e:
            last_err = e
    raise RuntimeError(f"NETWORK {last_err or 'cloud unreachable'}")


def cloud_playback_items(win_begin: datetime | None = None, win_end: datetime | None = None) -> list[dict[str, Any]]:
    obj = cloud_get_json("/admin/api/v1/videos", {"limit": "200", "type": "2"})
    items = obj.get("data") if isinstance(obj, dict) else None
    if not isinstance(items, list):
        items = []
    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        mtime = str(it.get("mtime") or "")
        path = str(it.get("path") or "")
        mt = None
        if mtime:
            try:
                mt = datetime.fromisoformat(mtime.replace("Z", "+00:00"))
                if mt.tzinfo:
                    mt = mt.replace(tzinfo=None)
            except ValueError:
                mt = None
        if win_begin and win_end and mt:
            if mt < win_begin - timedelta(minutes=2) or mt > win_end + timedelta(minutes=30):
                continue
        begin_s = fmt_dt(mt) if mt else mtime
        out.append({
            "src": "已上传",
            "begin": begin_s,
            "end": "",
            "name": it.get("name") or Path(path).name,
            "size": it.get("size") or "",
            "path": path,
        })
    return out


def download_cloud_file(rel_path: str, dest_dir: Path) -> Path:
    rel = rel_path if str(rel_path).startswith("/") else "/" + str(rel_path)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / Path(rel).name
    last_err: Exception | None = None
    for base in CLOUD_VIDEO_BASES:
        url = base.rstrip("/") + rel
        try:
            req = Request(url, headers={"User-Agent": CLOUD_UA})
            with urlopen(req, timeout=60) as resp:
                dest.write_bytes(resp.read())
            return dest
        except Exception as e:
            last_err = e
    raise RuntimeError(f"NETWORK {last_err or 'download fail'}")
