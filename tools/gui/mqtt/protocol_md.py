#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 MQTT 协议 Markdown 解析 dataType / 主题 / JSON 示例，供 GUI 识别与组包。"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

IMEI_RE = re.compile(r"\b(86\d{13})\b")
DT_RE = re.compile(r"\b([12]0\d{2})\b")
HEADING_RE = re.compile(
    r"^#{2,4}\s+(?:[\d.]+[a-z]?\s+)?`?(\d{4}(?:`?\s*/\s*`?\d{4})*)`?\s*[—\-–].+$",
    re.M,
)
PAIR_ROW_RE = re.compile(
    r"\|\s*\*{0,2}(20\d{2})\*{0,2}\s*\|\s*([^|]+?)\s*\|\s*\*{0,2}(10\d{2})\*{0,2}"
    r"(?:\s*\+\s*\*{0,2}\d{4}\*{0,2})?\s*\|\s*([^|]+?)\s*\|\s*([^|]+)\|",
)
JSON_FENCE_RE = re.compile(r"```(?:json)?\s*\n(\{[\s\S]*?\})\n```", re.M)
SUFFIX_RE = re.compile(r"`([A-Za-z][A-Za-z0-9_/]+)`")
BOLD_DT_RE = re.compile(r"\*\*([12]0\d{2})\*\*")

DANGER_ACTIONS = {"reboot", "off", "ota", "format"}
DANGER_TYPES = {"2009", "2011", "2012"}
T3X_TYPES = {
    "2006", "2007", "2009", "2012", "2013",
    "2020", "2021", "2022", "2023", "2024", "2025", "2026", "2027",
    "2028", "2029", "2030", "2031",
}


@dataclass
class ProtocolEntry:
    data_type: str
    direction: str
    name: str
    peer: str = ""
    topic_suffix: str = ""
    heading: str = ""
    examples: list[dict] = field(default_factory=list)
    notes: str = ""
    need_t3x: bool = False
    danger: bool = False

    def topic(self, imei: str) -> str:
        imei = (imei or "{IMEI}").strip()
        if self.direction == "down":
            return f"/panshi/device/{imei}/"
        suffix = self.topic_suffix or ""
        if suffix:
            return f"/panshi/app/{imei}/{suffix}"
        return f"/panshi/app/{imei}/#"


@dataclass
class ProtocolCatalog:
    path: str = ""
    title: str = ""
    imei: str = ""
    entries: dict[str, ProtocolEntry] = field(default_factory=dict)
    pairs: list[tuple[str, str]] = field(default_factory=list)

    def get(self, data_type: str) -> ProtocolEntry | None:
        return self.entries.get(str(data_type or "").strip())

    def downlink(self) -> list[ProtocolEntry]:
        rows = [e for e in self.entries.values() if e.direction == "down"]
        return sorted(rows, key=lambda e: e.data_type)

    def uplink(self) -> list[ProtocolEntry]:
        rows = [e for e in self.entries.values() if e.direction == "up"]
        return sorted(rows, key=lambda e: e.data_type)

    def identify(self, topic: str, payload: dict) -> dict:
        """根据主题 + JSON 识别协议条目，并做字段对照。"""
        dt = str(payload.get("dataType") or "").strip()
        entry = self.get(dt)
        variant = ""
        if dt == "1003":
            radio = [k for k in ("csq", "rssi", "rsrp", "rsrq", "snr") if payload.get(k) not in (None, "")]
            variant = "含信号强度" if radio else "无信号字段"
        elif dt == "1004":
            if payload.get("reply") in (1, "1"):
                variant = "控制回复（reply=1）"
            elif "stage" in payload:
                variant = "OTA 进度（stage）"
        elif dt == "1005":
            radio = [k for k in ("csq", "rssi", "rsrp", "rsrq", "snr") if payload.get(k) not in (None, "")]
            if radio:
                variant = "含信号强度"
        suffix = _topic_suffix(topic)
        name = entry.name if entry else "未收录"
        if variant:
            name = f"{name} · {variant}"
        expected = set()
        if entry:
            for ex in entry.examples:
                expected.update(ex.keys())
        expected.update({"dataType"})
        if entry and entry.direction == "up":
            expected.update({"deviceNo", "time"})
        if dt == "1003":
            expected.update({"csq", "rssi", "rsrp", "rsrq", "snr", "workMode", "interval"})
        present = set(payload.keys()) - {"_raw"}
        missing = sorted(expected - present) if expected else []
        extra = sorted(present - expected) if expected else []
        matched_suffix = bool(entry and entry.topic_suffix and suffix == entry.topic_suffix)
        if entry and entry.direction == "down":
            matched_suffix = topic.rstrip("/").endswith("/device/" + (self.imei or "")) or "/device/" in topic
        return {
            "dataType": dt or "?",
            "name": name,
            "direction": entry.direction if entry else _guess_direction(dt, topic),
            "peer": entry.peer if entry else "",
            "topic_suffix": entry.topic_suffix if entry else suffix,
            "heading": entry.heading if entry else "",
            "need_t3x": bool(entry and entry.need_t3x),
            "danger": bool(entry and entry.danger) or _payload_danger(payload),
            "known": entry is not None,
            "suffix_ok": matched_suffix if entry else None,
            "missing": missing,
            "extra": extra,
            "variant": variant,
        }


def _guess_direction(data_type: str, topic: str) -> str:
    if data_type.startswith("20"):
        return "down"
    if data_type.startswith("10"):
        return "up"
    if "/device/" in topic:
        return "down"
    if "/app/" in topic:
        return "up"
    return ""


def _topic_suffix(topic: str) -> str:
    parts = [p for p in (topic or "").split("/") if p]
    if len(parts) >= 4 and parts[0] == "panshi" and parts[1] == "app":
        return "/".join(parts[3:])
    return parts[-1] if parts else ""


def _payload_danger(payload: dict) -> bool:
    dt = str(payload.get("dataType") or "")
    if dt in DANGER_TYPES:
        return True
    action = str(payload.get("action") or "").lower()
    if action in DANGER_ACTIONS:
        return True
    return str(payload.get("lowPowerMode") or "") == "enter"


def _clean_cell(text: str) -> str:
    text = re.sub(r"\*\*|`", "", text or "")
    return re.sub(r"\s+", " ", text).strip()


def _first_suffix(cell: str) -> str:
    found = SUFFIX_RE.findall(cell or "")
    return found[0] if found else ""


def _ensure(catalog: ProtocolCatalog, data_type: str, **kwargs) -> ProtocolEntry:
    entry = catalog.entries.get(data_type)
    if entry is None:
        direction = "down" if data_type.startswith("20") else "up"
        entry = ProtocolEntry(data_type=data_type, direction=direction, name=kwargs.get("name") or data_type)
        catalog.entries[data_type] = entry
    for key, value in kwargs.items():
        if value in (None, "", [], False):
            continue
        cur = getattr(entry, key, None)
        if key == "examples" and isinstance(value, dict):
            if value not in entry.examples:
                entry.examples.append(value)
            continue
        if not cur:
            setattr(entry, key, value)
    entry.need_t3x = entry.need_t3x or data_type in T3X_TYPES
    entry.danger = entry.danger or data_type in DANGER_TYPES
    return entry


def parse_protocol_md(path: str | Path) -> ProtocolCatalog:
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    catalog = ProtocolCatalog(path=str(path))
    first_line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    catalog.title = first_line.lstrip("# ").strip() or path.name
    found_imei = IMEI_RE.findall(text)
    if found_imei:
        catalog.imei = found_imei[0]

    for m in PAIR_ROW_RE.finditer(text):
        down, down_name, up, up_name, suffix_cell = m.groups()
        suffix = _first_suffix(suffix_cell)
        _ensure(
            catalog, down,
            name=_clean_cell(down_name),
            peer=up,
            topic_suffix=suffix,
            direction="down",
        )
        _ensure(
            catalog, up,
            name=_clean_cell(up_name),
            peer=down,
            topic_suffix=suffix,
            direction="up",
        )
        catalog.pairs.append((down, up))

    headings: list[tuple[int, list[str], str]] = []
    for m in HEADING_RE.finditer(text):
        dts = DT_RE.findall(m.group(1))
        if dts:
            headings.append((m.start(), dts, m.group(0).lstrip("# ").strip()))
    headings.sort(key=lambda x: x[0])

    def heading_at(pos: int) -> tuple[list[str], str]:
        hit = ([], "")
        for start, dts, title in headings:
            if start <= pos:
                hit = (dts, title)
            else:
                break
        return hit

    for start, dts, title in headings:
        for dt in dts:
            _ensure(catalog, dt, heading=title)
            if not catalog.entries[dt].name or catalog.entries[dt].name == dt:
                name = title
                name = re.sub(r"`?\d{4}`?", "", name)
                name = re.sub(r"[—\-–→/]", " ", name)
                catalog.entries[dt].name = _clean_cell(name) or dt

    for m in JSON_FENCE_RE.finditer(text):
        raw = m.group(1).strip()
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        dt = str(obj.get("dataType") or "").strip()
        dts, title = heading_at(m.start())
        if not dt and dts:
            dt = dts[0]
            obj = dict(obj)
            obj["dataType"] = dt
        if not dt:
            continue
        entry = _ensure(catalog, dt, heading=title, examples=obj)
        if _payload_danger(obj):
            entry.danger = True

    return catalog


def merge_commands(catalog: ProtocolCatalog, commands: dict) -> list[dict]:
    """把 commands.json 测试项挂到协议条目上，返回可发送清单。"""
    out: list[dict] = []
    seen = set()
    for group in ("safe", "extra", "danger"):
        for item in commands.get(group) or []:
            row = dict(item)
            row["_group"] = group
            payload = row.get("payload") or {}
            dt = str(payload.get("dataType") or "")
            entry = catalog.get(dt)
            if entry:
                row.setdefault("name", entry.name)
                row.setdefault("need_t3x", entry.need_t3x)
                if group == "danger":
                    entry.danger = True
                if not entry.examples and payload:
                    entry.examples.append(dict(payload))
            if group == "danger" or _payload_danger(payload):
                row["danger"] = True
            out.append(row)
            seen.add(row.get("id") or dt)
    for entry in catalog.downlink():
        if entry.data_type in seen:
            continue
        if any(str((r.get("payload") or {}).get("dataType")) == entry.data_type for r in out):
            continue
        payload = dict(entry.examples[0]) if entry.examples else {"dataType": entry.data_type}
        payload["dataType"] = entry.data_type
        group = "danger" if entry.danger else ("extra" if entry.need_t3x else "safe")
        out.append({
            "id": entry.data_type,
            "name": entry.name,
            "expect": entry.peer or None,
            "payload": payload,
            "need_t3x": entry.need_t3x,
            "danger": entry.danger,
            "_group": group,
        })
    return out


def default_protocol_path(root: Path | None = None) -> Path:
    if root is not None:
        preferred = Path(root) / "doc" / "MQTT_PROTOCOL.md"
        if preferred.is_file():
            return preferred
    from app_paths import find_protocol_md
    return find_protocol_md()
