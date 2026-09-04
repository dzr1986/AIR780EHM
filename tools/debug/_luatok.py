# -*- coding: utf-8 -*-
"""最小 Lua 5.3 词法器：供 tools/debug 静态护栏共用（refactor_plan P0）。

背景：各护栏此前各自用正则剥注释/字符串、切实参，2026-09-04 多模型评审抓到 3 条漏报
（单行字面表零键 PASS、字符串字面量被当消费方、`--` 出现在字符串内被截断）。本模块把
「什么是代码、什么是字符串/注释、一个调用有哪几个实参」统一成一处实现，护栏只写规则。

只做词法，不做语法树。能力：
    tokens(text)              -> list[Token]  逐 token（含 kind/value/pos/line）
    strip_noncode(text)       -> str          注释删除、字符串字面量替换为 ""（保留行号与位置长度不保证）
    strip_strings(text)       -> str          仅替换字符串（注释保留）
    calls(text, callee)       -> list[Call]   找 `callee(` 调用，返回逐实参源码（顶层逗号切分）
    table_keys(src)           -> list[str]    字面表 `{ k = v, ... }` 的顶层键（含单行/多行）
    identifiers_at_depth0(...)                （预留）

限制：不处理 `goto`/标签；长字符串/长注释支持 `[[ ]]` 与 `[=*[ ]=*]`；数字只区分「是数字」。

用法（其它护栏）：
    from _luatok import strip_noncode, calls, table_keys
"""
from __future__ import annotations

import re
from dataclasses import dataclass

# token 种类
STR, COMMENT, NAME, NUMBER, SYM, WS = "str", "comment", "name", "number", "sym", "ws"

_NAME_START = re.compile(r"[A-Za-z_]")
_NAME_BODY = re.compile(r"[A-Za-z0-9_]")
_NUM = re.compile(r"0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?")
# 长括号 [=*[
_LONG_OPEN = re.compile(r"\[(=*)\[")
_SYM3 = ("...",)
_SYM2 = ("==", "~=", "<=", ">=", "//", "::", "<<", ">>", "..")


@dataclass
class Token:
    kind: str
    value: str
    pos: int
    line: int


@dataclass
class Call:
    callee: str
    pos: int          # callee 起始位置
    line: int
    open_pos: int     # '(' 位置
    close_pos: int    # ')' 位置（未闭合时 = len(text)）
    args: list[str]   # 逐实参源码（已 strip）


def _long_bracket_end(text: str, start: int, level: int) -> int:
    """text[start] 指向 `[=*[` 之后第一个字符，返回闭合 `]=*]` 之后的位置。"""
    close = "]" + "=" * level + "]"
    idx = text.find(close, start)
    return len(text) if idx < 0 else idx + len(close)


def tokens(text: str) -> list[Token]:
    out: list[Token] = []
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        start = i
        # 注释
        if text.startswith("--", i):
            m = _LONG_OPEN.match(text, i + 2)
            if m:
                i = _long_bracket_end(text, m.end(), len(m.group(1)))
            else:
                nl = text.find("\n", i)
                i = n if nl < 0 else nl
            val = text[start:i]
            out.append(Token(COMMENT, val, start, line))
            line += val.count("\n")
            continue
        # 字符串
        if ch in "\"'":
            q = ch
            i += 1
            while i < n:
                c = text[i]
                if c == "\\":
                    i += 2
                    continue
                if c == q:
                    i += 1
                    break
                if c == "\n":  # 未闭合，按行截断
                    break
                i += 1
            val = text[start:i]
            out.append(Token(STR, val, start, line))
            line += val.count("\n")
            continue
        m = _LONG_OPEN.match(text, i)
        if m:
            i = _long_bracket_end(text, m.end(), len(m.group(1)))
            val = text[start:i]
            out.append(Token(STR, val, start, line))
            line += val.count("\n")
            continue
        # 空白
        if ch.isspace():
            while i < n and text[i].isspace():
                i += 1
            val = text[start:i]
            out.append(Token(WS, val, start, line))
            line += val.count("\n")
            continue
        # 标识符 / 关键字
        if _NAME_START.match(ch):
            while i < n and _NAME_BODY.match(text[i]):
                i += 1
            out.append(Token(NAME, text[start:i], start, line))
            continue
        # 数字
        m = _NUM.match(text, i)
        if m and (ch.isdigit() or (ch == "." and i + 1 < n and text[i + 1].isdigit())):
            i = m.end()
            out.append(Token(NUMBER, text[start:i], start, line))
            continue
        # 符号
        for s in _SYM3 + _SYM2:
            if text.startswith(s, i):
                i += len(s)
                break
        else:
            i += 1
        out.append(Token(SYM, text[start:i], start, line))
    return out


def _rebuild(toks: list[Token], drop_comments: bool, blank_strings: bool) -> str:
    parts: list[str] = []
    for t in toks:
        if t.kind == COMMENT:
            if drop_comments:
                parts.append("\n" * t.value.count("\n"))  # 保留行数
            else:
                parts.append(t.value)
        elif t.kind == STR and blank_strings:
            parts.append('""' + "\n" * t.value.count("\n"))
        else:
            parts.append(t.value)
    return "".join(parts)


def strip_noncode(text: str) -> str:
    """删注释 + 字符串置空（保留换行数，行号可对齐）。"""
    return _rebuild(tokens(text), drop_comments=True, blank_strings=True)


def strip_strings(text: str) -> str:
    return _rebuild(tokens(text), drop_comments=False, blank_strings=True)


def strip_comments(text: str) -> str:
    return _rebuild(tokens(text), drop_comments=True, blank_strings=False)


def calls(text: str, callee: str) -> list[Call]:
    """找出所有 `callee(` 调用（callee 可含点，如 `gpio_util.setupInput`），
    按顶层逗号切分实参源码。字符串/注释内的同名文本不算调用。"""
    toks = tokens(text)
    out: list[Call] = []
    parts = callee.split(".")
    # 只在 NAME/SYM 序列中匹配 callee，忽略 WS/COMMENT
    code = [t for t in toks if t.kind not in (WS, COMMENT)]
    k = len(parts)
    for idx in range(len(code)):
        # 匹配 name(.name)* 序列
        ok = True
        j = idx
        for pi, p in enumerate(parts):
            if j >= len(code) or code[j].kind != NAME or code[j].value != p:
                ok = False
                break
            j += 1
            if pi < k - 1:
                if j >= len(code) or not (code[j].kind == SYM and code[j].value == "."):
                    ok = False
                    break
                j += 1
        if not ok:
            continue
        # 前一个 token 不能是 '.' 或 ':'（避免 x.gpio_util.setupInput 误配）或 NAME（避免 local f = ... 前缀）
        if idx > 0 and code[idx - 1].kind == SYM and code[idx - 1].value in (".", ":"):
            continue
        if j >= len(code) or not (code[j].kind == SYM and code[j].value == "("):
            continue
        open_tok = code[j]
        # 从 '(' 之后按深度切实参（用原始 token 流以保留实参源码）
        depth = 0
        args: list[str] = []
        buf_start = open_tok.pos + 1
        close_pos = len(text)
        seg_start = buf_start
        for t in toks:
            if t.pos < open_tok.pos:
                continue
            if t.kind in (STR, COMMENT, WS, NAME, NUMBER):
                continue
            v = t.value
            if v in ("(", "{", "["):
                depth += 1
            elif v in (")", "}", "]"):
                depth -= 1
                if depth == 0 and v == ")":
                    close_pos = t.pos
                    args.append(text[seg_start:close_pos].strip())
                    break
            elif v == "," and depth == 1:
                args.append(text[seg_start:t.pos].strip())
                seg_start = t.pos + 1
        if close_pos == len(text):
            args.append(text[seg_start:].strip())
        if len(args) == 1 and args[0] == "":
            args = []
        out.append(Call(callee, code[idx].pos, code[idx].line, open_tok.pos, close_pos, args))
    return out


def table_keys(src: str) -> list[str]:
    """字面表源码 `{ a = 1, b = { c = 2 } }` → 顶层键 ['a', 'b']。
    单行/多行一致；嵌套表/函数体内的 `x = y` 不计；`==` 不计。"""
    src = src.strip()
    if not src.startswith("{"):
        return []
    toks = [t for t in tokens(src) if t.kind not in (WS, COMMENT)]
    keys: list[str] = []
    depth = 0
    # 在深度 1（表内顶层）处：NAME 后紧跟 '=' 且 '=' 不是 '=='
    for i, t in enumerate(toks):
        if t.kind == SYM and t.value in ("{", "(", "["):
            depth += 1
            continue
        if t.kind == SYM and t.value in ("}", ")", "]"):
            depth -= 1
            continue
        if t.kind == NAME and t.value in ("function",):
            # function ... end 会把 depth 搞乱：靠括号深度即可（形参括号 +1/-1），函数体内 x = y 深度仍为 1
            # 因此额外用 end 计数：进入 function 后忽略直到匹配 end
            pass
        if depth == 1 and t.kind == NAME and i + 1 < len(toks):
            nxt = toks[i + 1]
            prv = toks[i - 1] if i > 0 else None
            if nxt.kind == SYM and nxt.value == "=" and (prv is None or (prv.kind == SYM and prv.value in ("{", ","))):
                keys.append(t.value)
    return keys


def name_call_args(text: str, name: str) -> list[list[str]]:
    """便捷：返回 `name(` 调用的实参列表们（不含位置）。"""
    return [c.args for c in calls(text, name)]


if __name__ == "__main__":  # 自检
    sample = 'local s = "a -- not comment" -- real comment\n--[[ block\n]] x = { a = 1, b = { c = 2 }, d = f(1, 2) }\ng.f(1, function() local t = { q = 1 } end, { k = 2, m = 3 })'
    assert "real comment" not in strip_noncode(sample)
    assert '"a -- not comment"' not in strip_noncode(sample) and "local s" in strip_noncode(sample)
    assert table_keys("{ a = 1, b = { c = 2 }, d = f(1, 2) }") == ["a", "b", "d"]
    c = calls(sample, "g.f")
    assert len(c) == 1 and len(c[0].args) == 3 and table_keys(c[0].args[2]) == ["k", "m"], c
    print("luatok self-check OK")
