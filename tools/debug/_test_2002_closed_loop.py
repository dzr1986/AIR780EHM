#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""2002 停 IPC 再断电 + 2001 探活 闭环。同时抓 Cat.1 USB 与 T31 COM7。"""
from __future__ import annotations

import json
import sys
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "gui" / "mqtt"))
sys.path.insert(0, str(ROOT / "tools" / "gui" / "flash"))
sys.path.insert(0, str(ROOT / "tools" / "debug"))

import cat1_flash as flash  # noqa: E402
from mqtt_tools_client import ToolsClient, _load_json  # noqa: E402

try:
    import serial
except ImportError:
    print("需要 pyserial")
    raise SystemExit(2)

T31_PORT = "COM7"
T31_BAUD = 115200
CAT1_KEYS = (
    "ipc_poweroff", "IPCPOWEROFF", "power off", "power on", "enter_sleep",
    "2002", "2001", "rest_enter", "rest_exit", "pir_watch", "person_detect",
    "gpio", "t31x_ctrl", "lowPower", "workMode", "ipcReady", "wakeup",
    "AT+IPC", "STAGE", "graceful", "hostIpc",
)


def _stamp() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


class FileLog:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fp = self.path.open("w", encoding="utf-8", errors="replace")
        self._lock = threading.Lock()

    def write(self, line: str) -> None:
        text = line if line.endswith("\n") else line + "\n"
        with self._lock:
            self._fp.write(text)
            self._fp.flush()

    def close(self) -> None:
        with self._lock:
            self._fp.close()


class Cat1Capture(threading.Thread):
    def __init__(self, out: FileLog):
        super().__init__(daemon=True, name="cat1-usb")
        self.out = out
        self.lines: list[str] = []
        self._stop = threading.Event()
        self.ok = False
        self.port = None
        self.err = ""

    def run(self) -> None:
        port = flash.find_log_port()
        self.port = port
        if not port:
            self.err = "NO_LOG_PORT"
            self.out.write("NO_LOG_PORT")
            return
        try:
            ser = serial.Serial(port, 921600, timeout=0.3)
            ser.dtr = True
            try:
                ser.write(flash.USB_LOG_ENABLE)
            except Exception:
                pass
        except Exception as exc:
            self.err = str(exc)
            self.out.write(f"OPEN_FAIL {exc}")
            return
        self.ok = True
        self.out.write(f"# open {port} 921600")
        ctx = {}
        try:
            while not self._stop.is_set():
                try:
                    chunk = ser.read(4096)
                except Exception as exc:
                    self.out.write(f"READ_ERR {exc}")
                    break
                if not chunk:
                    continue
                for msg in flash.decode_usb_log(ctx, chunk):
                    line = f"{_stamp()} {msg}"
                    self.lines.append(line)
                    self.out.write(line)
        finally:
            try:
                ser.close()
            except Exception:
                pass

    def stop(self) -> None:
        self._stop.set()


class T31Capture(threading.Thread):
    def __init__(self, out: FileLog):
        super().__init__(daemon=True, name="t31-com7")
        self.out = out
        self.raw = bytearray()
        self._stop = threading.Event()
        self.ok = False
        self.err = ""
        self._ser = None
        self._wlock = threading.Lock()

    def run(self) -> None:
        try:
            ser = serial.Serial(
                T31_PORT, T31_BAUD, timeout=0.2, write_timeout=3,
                xonxoff=False, rtscts=False, dsrdtr=False,
            )
        except Exception as exc:
            self.err = str(exc)
            self.out.write(f"OPEN_FAIL {exc}")
            return
        self._ser = ser
        self.ok = True
        self.out.write(f"# open {T31_PORT} {T31_BAUD}")
        try:
            self._kick_shell()
            while not self._stop.is_set():
                n = ser.in_waiting
                chunk = ser.read(n or 1)
                if chunk:
                    self.raw.extend(chunk)
                    text = chunk.decode("utf-8", errors="replace")
                    self.out.write(text if text.endswith("\n") else text)
        finally:
            try:
                ser.close()
            except Exception:
                pass

    def _kick_shell(self) -> None:
        ser = self._ser
        if not ser:
            return
        ser.write(b"\x03\r\n")
        ser.flush()
        time.sleep(0.25)
        ser.write(b"\r\n")
        ser.flush()
        time.sleep(0.4)
        buf = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        low = buf.lower()
        self.out.write(buf)
        if "login:" in low:
            ser.write(b"root\r\n")
            ser.flush()
            time.sleep(0.4)
            more = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
            self.out.write(more)
            if "password:" in more.lower():
                ser.write(b"\r\n")
                ser.flush()
                time.sleep(0.3)
        self.send(
            "echo T31_LOOP_START; date; pidof ipc; "
            "tail -n 20 /tmp/ipc/cat1_uart.log 2>/dev/null; "
            "tail -F /tmp/ipc/cat1_uart.log /tmp/ipc/app.log 2>/dev/null"
        )

    def send(self, cmd: str) -> None:
        ser = self._ser
        if not ser:
            return
        with self._wlock:
            try:
                ser.write((cmd.rstrip("\r\n") + "\r\n").encode("utf-8"))
                ser.flush()
                self.out.write(f"\n>>> {cmd}\n")
            except Exception as exc:
                self.out.write(f"SEND_FAIL {exc}\n")

    def text(self) -> str:
        return bytes(self.raw).decode("utf-8", errors="replace")

    def stop(self) -> None:
        self._stop.set()


def snapshot(cli: ToolsClient, after_n: int) -> list[dict]:
    with cli._lock:
        return [dict(d) for _t, d in cli._inbox[after_n:]]


def send_and_collect(cli: ToolsClient, item: dict, extra_wait: float = 0) -> dict:
    with cli._lock:
        n = len(cli._inbox)
    print(f"\n=== {item['id']} {item.get('name', '')} ===")
    sent = cli.publish(item["payload"])
    timeout = float(item.get("timeout_sec") or cli.timeout)
    got = cli.wait_reply(item.get("expect"), n, timeout, None)
    ok = got is not None or not item.get("expect")
    if extra_wait > 0:
        time.sleep(extra_wait)
    ups = snapshot(cli, n)
    if not ok and find_up(ups, str((item.get("expect") or [""])[0] if isinstance(item.get("expect"), list) else item.get("expect") or "")):
        ok = True
    print(f"  {'OK' if ok else 'FAIL'} {item['id']}")
    return {"id": item["id"], "ok": ok, "uplinks": ups}


def find_up(ups: list[dict], dt: str, pred=None) -> dict | None:
    for u in ups:
        if str(u.get("dataType")) != str(dt):
            continue
        if pred is None or pred(u):
            return u
    return None


def last_status(ups: list[dict]) -> dict | None:
    hit = None
    for u in ups:
        if str(u.get("dataType")) == "1003":
            hit = u
    return hit


def hay(lines: list[str], *needles: str) -> bool:
    blob = "\n".join(lines).lower()
    return any(n.lower() in blob for n in needles)


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    outdir = ROOT / "tools" / "_logs" / ts
    outdir.mkdir(parents=True, exist_ok=True)
    cat1_log = FileLog(outdir / "cat1_usb.log")
    t31_log = FileLog(outdir / "t31_uart.log")
    session = FileLog(outdir / "session.log")
    print(f"日志目录 {outdir}")

    cat1 = Cat1Capture(cat1_log)
    t31 = T31Capture(t31_log)
    cat1.start()
    t31.start()
    time.sleep(1.2)
    session.write(f"cat1 port={cat1.port} ok={cat1.ok} err={cat1.err}")
    session.write(f"t31 ok={t31.ok} err={t31.err}")
    if not cat1.ok:
        print(f"Cat.1 日志口失败: {cat1.err}")
    if not t31.ok:
        print(f"T31 COM7 失败（仍继续 MQTT）: {t31.err}")

    cfg = _load_json(ROOT / "tools" / "gui" / "mqtt" / "config.json")
    cfg["client_id"] = f"platform-test-{uuid.uuid4().hex[:8]}"
    commands = _load_json(ROOT / "tools" / "gui" / "mqtt" / "commands.json")
    cli = ToolsClient(cfg, commands)

    def cmd(cid: str) -> dict:
        item = dict(cli.find_cmd(cid) or {})
        if not item:
            raise SystemExit(f"未知命令 {cid}")
        item["_group"] = "danger"
        return item

    checks: list[dict] = []
    results: list[dict] = []

    def add_check(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        flag = "PASS" if ok else "FAIL"
        line = f"[{flag}] {name}  {detail}"
        print(line)
        session.write(line)

    try:
        cli.connect()
        deadline = time.time() + 25
        ready = False
        while time.time() < deadline:
            with cli._lock:
                ups = [d for _t, d in cli._inbox]
            if find_up(ups, "1008") or find_up(ups, "1003") or find_up(ups, "1001"):
                ready = True
                break
            time.sleep(0.4)
        session.write(f"mqtt_ready={ready}")
        time.sleep(1.0)

        r2008 = send_and_collect(cli, cmd("2008"), 0.4)
        results.append(r2008)
        u1008 = find_up(r2008["uplinks"], "1008")
        ver = (u1008 or {}).get("scriptVersion") or (u1008 or {}).get("firmwareVersion") or ""
        add_check("2008 版本", r2008["ok"] and u1008 is not None, f"scriptVersion={ver}")

        r2003a = send_and_collect(cli, cmd("2003"), 0.8)
        results.append(r2003a)
        st0 = last_status(r2003a["uplinks"]) or {}
        add_check(
            "2003 基线",
            r2003a["ok"] and st0.get("dataType") == "1003",
            f"lowPowerMode={st0.get('lowPowerMode')} workMode={st0.get('workMode')} ipcReady={st0.get('ipcReady')}",
        )
        if str(st0.get("lowPowerMode")) == "rest":
            print("已在 rest，先 2002exit 拉回常电再测断电")
            send_and_collect(cli, cmd("2002exit"), 20.0)
            r2003a = send_and_collect(cli, cmd("2003"), 1.0)
            results.append(r2003a)
            st0 = last_status(r2003a["uplinks"]) or {}
            add_check(
                "预热后常电",
                str(st0.get("lowPowerMode")) == "normal",
                f"lowPowerMode={st0.get('lowPowerMode')} workMode={st0.get('workMode')} ipcReady={st0.get('ipcReady')}",
            )
        rec = str(st0.get("recordingT31x") or "0")
        print(f"基线 recordingT31x={rec}；不发 2011（RECORDCTRL 会堵住 T31 UART，IPCPOWEROFF 收不到）")

        r2001a = send_and_collect(cli, cmd("2001"), 1.2)
        results.append(r2001a)
        u1001a = find_up(r2001a["uplinks"], "1001")
        st_after_ping = last_status(r2001a["uplinks"])
        mode_unchanged = True
        if st_after_ping and st0:
            mode_unchanged = st_after_ping.get("lowPowerMode") == st0.get("lowPowerMode")
        add_check("2001 探活回 1001", u1001a is not None, "主题 wakeup，只证明 MQTT 通")
        add_check("2001 不改功耗", mode_unchanged, "探活后 lowPowerMode 未因 2001 改变")

        r_enter = send_and_collect(cli, cmd("2002enter"), 8.0)
        results.append(r_enter)
        time.sleep(75)
        enter_ups = r_enter["uplinks"] + snapshot(cli, 0)
        # snapshot(cli,0) is all inbox; filter by time-ish using enter_ups from after send n is better.
        # Re-collect from the send point stored in r_enter only, plus later wait already included 8s.
        # After extra 22s, grab new ones:
        with cli._lock:
            later = [dict(d) for _t, d in cli._inbox]
        u1004e = find_up(later, "1004", lambda d: str(d.get("action") or "") in ("rest_enter", "enter") or "rest_enter" in str(d.get("message") or ""))
        if u1004e is None:
            u1004e = find_up(r_enter["uplinks"], "1004")
        u1002e = find_up(later, "1002", lambda d: str(d.get("lowPowerMode")) == "enter")
        st_rest = None
        for u in reversed(later):
            if str(u.get("dataType")) == "1003":
                if str(u.get("lowPowerMode")) == "rest" or str(u.get("workMode")) == "pir_watch":
                    st_rest = u
                    break
                if st_rest is None:
                    st_rest = u
        add_check(
            "2002enter → 1004 rest_enter",
            u1004e is not None and str(u1004e.get("ret", 0)) in ("0", "0.0", "0"),
            f"action={ (u1004e or {}).get('action') } ret={(u1004e or {}).get('ret')} msg={(u1004e or {}).get('message')}",
        )
        add_check("2002enter → 1002 enter", u1002e is not None, f"reason={(u1002e or {}).get('reason')}")
        ipc0 = False
        for u in later:
            if str(u.get("dataType")) != "1003":
                continue
            if str(u.get("lowPowerMode")) != "rest":
                continue
            if str(u.get("ipcReady")) in ("0", "0.0"):
                ipc0 = True
                break
        add_check(
            "断电后 1003 值守",
            bool(st_rest) and str(st_rest.get("lowPowerMode")) == "rest" and str(st_rest.get("workMode")) == "pir_watch",
            f"lowPowerMode={(st_rest or {}).get('lowPowerMode')} workMode={(st_rest or {}).get('workMode')} ipcReady={(st_rest or {}).get('ipcReady')}",
        )
        add_check(
            "断电后 ipcReady=0",
            ipc0,
            "值守后曾出现 ipcReady=0；PIR 再唤醒会回到 1，不算失败",
        )

        r2001b = send_and_collect(cli, cmd("2001"), 1.0)
        results.append(r2001b)
        u1001b = find_up(r2001b["uplinks"], "1001")
        add_check("rest 下 2001 仍回 1001", u1001b is not None, "rest 探活成功，不代表已出 rest")
        r2003b = send_and_collect(cli, cmd("2003"), 0.8)
        results.append(r2003b)
        st_rest2 = last_status(r2003b["uplinks"]) or {}
        add_check(
            "2001 后仍 rest",
            str(st_rest2.get("lowPowerMode")) == "rest",
            f"lowPowerMode={st_rest2.get('lowPowerMode')} workMode={st_rest2.get('workMode')} ipcReady={st_rest2.get('ipcReady')}",
        )

        r_exit = send_and_collect(cli, cmd("2002exit"), 8.0)
        results.append(r_exit)
        time.sleep(18)
        with cli._lock:
            later2 = [dict(d) for _t, d in cli._inbox]
        u1004x = find_up(r_exit["uplinks"], "1004")
        u1002x = find_up(later2, "1002", lambda d: str(d.get("lowPowerMode")) == "exit")
        st_on = None
        for u in reversed(later2):
            if str(u.get("dataType")) == "1003" and str(u.get("lowPowerMode")) in ("normal", "0"):
                st_on = u
                break
        if st_on is None:
            st_on = last_status(later2)
        add_check(
            "2002exit → 1004 rest_exit",
            u1004x is not None and str(u1004x.get("ret", 0)) in ("0", "0.0", "0"),
            f"action={(u1004x or {}).get('action')} ret={(u1004x or {}).get('ret')}",
        )
        add_check("2002exit → 1002 exit 或 1003 常电", u1002x is not None or str((st_on or {}).get("lowPowerMode")) == "normal",
                  f"1002exit={u1002x is not None} lowPowerMode={(st_on or {}).get('lowPowerMode')} ipcReady={(st_on or {}).get('ipcReady')}")

        r2003c = send_and_collect(cli, cmd("2003"), 1.0)
        results.append(r2003c)
        st_final = last_status(r2003c["uplinks"]) or {}
        add_check(
            "退出后常电",
            str(st_final.get("lowPowerMode")) == "normal",
            f"lowPowerMode={st_final.get('lowPowerMode')} workMode={st_final.get('workMode')} ipcReady={st_final.get('ipcReady')}",
        )

        time.sleep(2)
        cat1_blob = "\n".join(cat1.lines)
        t31_blob = t31.text()
        no_yield = "yield from outside" not in cat1_blob.lower()
        add_check("无 yield 崩溃", no_yield, "事件回调里不得 sys.wait")
        add_check(
            "Cat.1 发出 AT+IPCPOWEROFF",
            "ipcpoweroff_tx" in cat1_blob.lower() or "AT+IPCPOWEROFF" in cat1_blob.upper(),
            "host_uart ipcpoweroff_tx",
        )
        got_ok = (
            "ipcpoweroff_rx OK" in cat1_blob
            or 'ipcpoweroff_rx", "OK' in cat1_blob
            or "ipc_poweroff_done ack" in cat1_blob.lower()
        )
        got_timeout = "ipc_poweroff_done timeout" in cat1_blob.lower()
        add_check(
            "Cat.1 等到 OK 再断电",
            got_ok and not got_timeout,
            "ipc_poweroff_done ack；timeout 视为 T31 未应答",
        )
        t31_at = "IPCPOWEROFF" in t31_blob.upper()
        t31_stage = "STAGE" in t31_blob.upper() and "IPCPOWEROFF" in t31_blob.upper()
        cat1_stage = "ipcpoweroff_rx" in cat1_blob.lower() and "STAGE" in cat1_blob.upper()
        add_check(
            "T31 处理 IPCPOWEROFF",
            t31_at or cat1_stage or got_ok,
            "COM7 见 IPCPOWEROFF，或 Cat.1 收到 STAGE/OK",
        )
        add_check(
            "T31 回了 STAGE 或 OK",
            t31_stage or cat1_stage or got_ok,
            "不能只靠 GPIO 超时断电",
        )

        time.sleep(12)
        r2006 = send_and_collect(cli, cmd("2006"), 2.0)
        results.append(r2006)
        add_check("上电后 2006 标识", r2006["ok"], "T31 UART 应已恢复")

    finally:
        try:
            cli.close()
        except Exception:
            pass
        cat1.stop()
        t31.stop()
        time.sleep(0.4)
        cat1_log.close()
        t31_log.close()

    failed = [c for c in checks if not c["ok"]]
    summary = {
        "dir": str(outdir),
        "pass": len(checks) - len(failed),
        "fail": len(failed),
        "checks": checks,
        "fails": [c["name"] for c in failed],
    }
    (outdir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    session.write(json.dumps(summary, ensure_ascii=False, indent=2))
    session.close()
    print(f"\n合计 PASS {summary['pass']}  FAIL {summary['fail']}")
    if failed:
        print("失败项: " + ", ".join(c["name"] for c in failed))
        return 1
    print("闭环 OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
