#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任意用户时间 ↔ 5 分钟 TS 段求交。"""
from datetime import datetime

from playback import match_segments, parse_dt, parse_record_list_text, plan_uploads, split_window


def _seg(a, b, name=""):
    return {"src": "国标/TF", "begin": a, "end": b, "name": name or f"{a}_{b}"}


def test_overlap_mid_file():
    segs = [
        _seg("2026-08-19 00:06:03", "2026-08-19 00:11:03", "a.ts"),
        _seg("2026-08-19 00:11:03", "2026-08-19 00:16:03", "b.ts"),
        _seg("2026-08-19 00:16:03", "2026-08-19 00:21:03", "c.ts"),
    ]
    hits = match_segments(parse_dt("2026-08-19 00:08:00"), parse_dt("2026-08-19 00:13:00"), segs)
    assert [h["name"] for h in hits] == ["a.ts", "b.ts"]
    assert hits[0]["overlap_begin"] == "2026-08-19 00:08:00"
    assert hits[0]["overlap_end"] == "2026-08-19 00:11:03"
    assert hits[1]["overlap_begin"] == "2026-08-19 00:11:03"
    assert hits[1]["overlap_end"] == "2026-08-19 00:13:00"


def test_split_over_600s():
    wins = split_window(parse_dt("2026-08-19 08:00:00"), parse_dt("2026-08-19 08:25:00"), 600)
    assert len(wins) == 3
    assert wins[0][1] == parse_dt("2026-08-19 08:10:00")
    assert wins[-1][1] == parse_dt("2026-08-19 08:25:00")


def test_plan_without_list_still_sends_user_window():
    plan = plan_uploads(parse_dt("2026-08-19 08:14:23"), parse_dt("2026-08-19 08:19:23"), None)
    assert plan["source"] == "user"
    assert len(plan["windows"]) == 1
    assert plan["windows"][0]["begin"] == "2026-08-19 08:14:23"


def test_parse_livegbs_paste():
    text = (
        "34020000001330000001  ch0_20260819000603_20260819001103.ts  "
        "2026-08-19T00:06:03  2026-08-19T00:11:03  5.52 MB\n"
        "34020000001330000001  ch0_20260819001103_20260819001603.ts  "
        "2026-08-19T00:11:03  2026-08-19T00:16:03  6.10 MB\n"
    )
    items = parse_record_list_text(text)
    assert len(items) == 2
    assert items[1]["begin"] == "2026-08-19 00:06:03"
    assert items[0]["end"] == "2026-08-19 00:16:03"


if __name__ == "__main__":
    test_overlap_mid_file()
    test_split_over_600s()
    test_plan_without_list_still_sends_user_window()
    test_parse_livegbs_paste()
    print("playback match ok", datetime.now().isoformat(timespec="seconds"))
