#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""平台侧 MQTT 测试客户端（对齐 doc/MQTT_DOWNLINK_862323084068124.txt + Lua 实现）。

账号密码、Broker、IMEI 均在同目录 config.json。
差异说明：doc/MQTT_LUA_DOC_DIFF.md

  pip install -r tools/gui/mqtt/requirements-mqtt.txt
  python tools/gui/mqtt/mqtt_tools_client.py
  python tools/gui/mqtt/mqtt_tools_client.py --list
  python tools/gui/mqtt/mqtt_tools_client.py --send 2008
  python tools/gui/mqtt/mqtt_tools_client.py --run-safe
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import uuid
from pathlib import Path

from app_paths import app_dir, commands_path, config_path, repo_root  # noqa: E402

HERE = app_dir()
ROOT = repo_root()
CFG_PATH = config_path()
CMD_PATH = commands_path()


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _make_client(cid: str):
    import paho.mqtt.client as mqtt

    kwargs = {
        "client_id": cid,
        "protocol": mqtt.MQTTv311,
        "clean_session": True,
    }
    if hasattr(mqtt, "CallbackAPIVersion"):
        try:
            kwargs["reconnect_on_failure"] = True
            return mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, **kwargs)
        except TypeError:
            kwargs.pop("reconnect_on_failure", None)
            try:
                return mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, **kwargs)
            except TypeError:
                pass
    return mqtt.Client(**kwargs)


class ToolsClient:
    def __init__(self, cfg: dict, commands: dict):
        self.cfg = cfg
        self.commands = commands
        self.imei = str(cfg["device_imei"])
        self.qos = int(cfg.get("qos") or 1)
        self.timeout = float(cfg.get("reply_timeout_sec") or 12)
        self.pub_topic = f"/panshi/device/{self.imei}/"
        self.sub_topic = f"/panshi/app/{self.imei}/#"
        self._lock = threading.Lock()
        self._inbox: list[tuple[str, dict]] = []
        self._connected = threading.Event()
        self._client = None

    def all_cmds(self) -> list[dict]:
        out = []
        for group in ("safe", "extra", "danger"):
            for item in self.commands.get(group) or []:
                row = dict(item)
                row["_group"] = group
                out.append(row)
        return out

    def find_cmd(self, cid: str) -> dict | None:
        cid = cid.strip()
        dtype_hit = None
        for item in self.all_cmds():
            if item["id"] == cid:
                return item
            if dtype_hit is None and item["payload"].get("dataType") == cid:
                dtype_hit = item
        return dtype_hit

    def connect(self) -> None:
        import socket

        import paho.mqtt.client as mqtt  # noqa: F401

        cid = str(self.cfg.get("client_id") or f"platform-test-{uuid.uuid4().hex[:8]}")
        if cid == self.imei:
            raise SystemExit("ClientId 不能与设备 IMEI 相同，请改 config.json")
        prev_to = socket.getdefaulttimeout()
        socket.setdefaulttimeout(10)
        cli = _make_client(cid)
        cli.username_pw_set(self.cfg.get("username") or "", self.cfg.get("password") or "")
        cli.on_connect = self._on_connect
        cli.on_message = self._on_message
        cli.on_disconnect = self._on_disconnect
        if self.cfg.get("ssl"):
            cli.tls_set()
        print(f"正在连接 {self.cfg['broker']}:{self.cfg['port']} …")
        try:
            cli.connect(self.cfg["broker"], int(self.cfg["port"]), int(self.cfg.get("keepalive") or 60))
        finally:
            socket.setdefaulttimeout(prev_to)
        cli.loop_start()
        self._client = cli
        if not self._connected.wait(15):
            raise SystemExit("连接 Broker 超时")
        print(f"已连接 {self.cfg['broker']}:{self.cfg['port']}  ClientId={cid}")
        print(f"订阅 {self.sub_topic}  发布 {self.pub_topic}")

    def close(self) -> None:
        if self._client:
            self._client.loop_stop()
            self._client.disconnect()

    def _on_connect(self, client, _userdata, _flags, rc, *_extra):
        if rc == 0:
            client.subscribe(self.sub_topic, self.qos)
            self._connected.set()
        else:
            print(f"连接失败 rc={rc}")

    def _on_disconnect(self, _client, _userdata, rc, *_extra):
        if rc != 0:
            print(f"断开 rc={rc}")

    def _on_message(self, _client, _userdata, msg):
        raw = msg.payload.decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {"_raw": raw}
        with self._lock:
            self._inbox.append((msg.topic, data))
        dt = data.get("dataType", "?")
        print(f"  << {dt}  {msg.topic}\n     {raw[:400]}")

    def publish(self, payload: dict, message_id: str | None = None) -> dict:
        body = dict(payload)
        if message_id or "messageId" not in body:
            body["messageId"] = message_id or f"t-{int(time.time())}-{uuid.uuid4().hex[:6]}"
        line = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        print(f"  >> {body.get('dataType')}  {self.pub_topic}\n     {line}")
        self._client.publish(self.pub_topic, line, qos=self.qos)
        return body

    def wait_reply(self, expect: str | None, after_n: int, timeout: float | None = None, message_id: str | None = None) -> dict | None:
        expects = []
        if isinstance(expect, (list, tuple)):
            expects = [str(x) for x in expect if x]
        elif expect:
            expects = [str(expect)]
        if not expects:
            time.sleep(0.4)
            return None
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[after_n:]
            for _topic, data in newer:
                if str(data.get("dataType")) not in expects:
                    continue
                got_mid = data.get("messageId")
                if message_id and got_mid and str(got_mid) != str(message_id):
                    continue
                return data
            time.sleep(0.05)
        return None

    def send_cmd(self, item: dict, *, danger_ok: bool = False) -> bool:
        if item.get("_group") == "danger" and not danger_ok and item.get("destructive"):
            print(f"跳过破坏性命令 {item['id']}（加 --danger）")
            return False
        if item.get("_group") == "danger" and not danger_ok:
            print(f"跳过危险命令 {item['id']}（加 --danger）")
            return False
        with self._lock:
            n = len(self._inbox)
        sent = self.publish(item["payload"])
        timeout = float(item.get("timeout_sec") or self.timeout)
        if item.get("need_t31x"):
            timeout = max(timeout, 35)
        got = self.wait_reply(item.get("expect"), n, timeout, sent.get("messageId"))
        if not item.get("expect"):
            print(f"  -- {item['id']} 已发送（按 Lua 无固定应答）")
            return True
        if got:
            extra = ""
            if got.get("ret") is not None:
                extra = f" ret={got.get('ret')} message={got.get('message', '')}"
            ret = got.get("ret")
            fail_nz = (item.get("need_t31x") or item.get("_group") == "extra") and not item.get("allow_nonzero_ret")
            if fail_nz and ret is not None and str(ret) not in ("0", "0.0"):
                print(f"  FAIL {item['id']} → {got.get('dataType')}{extra} messageId={got.get('messageId', sent.get('messageId'))}")
                return False
            print(f"  OK {item['id']} → {got.get('dataType')}{extra} messageId={got.get('messageId', sent.get('messageId'))}")
            return True
        print(f"  TIMEOUT {item['id']} 未收到 {item.get('expect')}（T31x 未就绪时属预期）")
        return False

    def _saw_boot_since(self, after_n: int) -> bool:
        with self._lock:
            newer = self._inbox[after_n:]
        for _topic, data in newer:
            if str(data.get("dataType")) == "1008" and str(data.get("messageId") or "") == "boot":
                return True
        return False

    def _wait_mqtt_after_boot(self, seconds: float = 45.0) -> bool:
        print(f"  !! 检测到 1008 messageId=boot，等待 MQTT 恢复最多 {seconds:.0f}s")
        deadline = time.time() + seconds
        with self._lock:
            n = len(self._inbox)
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[n:]
            for _topic, data in newer:
                dt = str(data.get("dataType") or "")
                if dt in ("1001", "1003") or (dt == "1008" and str(data.get("messageId") or "") != "boot"):
                    print(f"  !! MQTT 已恢复 dataType={dt}")
                    return True
            time.sleep(0.2)
        print("  !! MQTT 恢复超时")
        return False

    def run_group(
        self,
        group: str,
        *,
        danger_ok: bool = False,
        include_destructive: bool = False,
        include_tf_format: bool = False,
    ) -> dict:
        ok = fail = skip = 0
        for item in self.commands.get(group) or []:
            item = dict(item)
            item["_group"] = group
            if item.get("manual_only"):
                skip += 1
                print(f"\n=== SKIP {item['id']} {item['name']}（仅 GUI OTA闭环 / 手动）===")
                continue
            if item.get("tf_format") or item.get("id") == "2009fmt":
                if not include_tf_format:
                    skip += 1
                    print(f"\n=== SKIP {item['id']} {item['name']}（TF 格式化，需 --tf-format）===")
                    continue
            elif item.get("skip_auto") and not include_destructive:
                skip += 1
                print(f"\n=== SKIP {item['id']} {item['name']}（破坏性，需 --danger-all）===")
                continue
            print(f"\n=== {item['id']} {item['name']} ===")
            with self._lock:
                n_before = len(self._inbox)
            if self.send_cmd(item, danger_ok=danger_ok or group != "danger"):
                ok += 1
            else:
                fail += 1
            if self._saw_boot_since(n_before):
                self._wait_mqtt_after_boot(45.0)
        print(f"\n{group} 完成：成功 {ok}，超时/失败 {fail}，跳过 {skip}")
        return {"ok": ok, "fail": fail, "skip": skip}

    def run_safe(self) -> dict:
        return self.run_group("safe", danger_ok=False)

    def wait_pred(self, after_n: int, timeout: float, pred) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[after_n:]
            for _topic, data in newer:
                if pred(data):
                    return data
            time.sleep(0.05)
        return None

    def run_ota_loop(self, version: str, url: str = "", timeout_ms: int = 300000) -> bool:
        """2008 查版本 → 2004 ota → 1004 accepted/stage → 重启后 1008。"""
        item = self.find_cmd("2004ota") or {}
        payload = dict((item.get("payload") or {}))
        payload["dataType"] = "2004"
        payload["action"] = "ota"
        payload["version"] = version
        payload["timeout"] = int(timeout_ms)
        payload["full_url"] = int(payload.get("full_url") or 0)
        if url:
            payload["url"] = url
        if not payload.get("url"):
            payload["url"] = "http://43.136.55.143/ota/api/site/firmware_upgrade?"
        print(f"\n=== OTA 闭环 target={version} url={payload['url']} ===")
        with self._lock:
            n0 = len(self._inbox)
        sent = self.publish({"dataType": "2008"})
        got = self.wait_reply("1008", n0, 15, sent.get("messageId"))
        if not got:
            print("  FAIL 无 1008，设备可能未订阅或 IMEI 不对")
            return False
        before = str(got.get("firmwareVersion") or "")
        print(f"  升级前 firmwareVersion={before} scriptVersion={got.get('scriptVersion')}")
        if before and before == version:
            print("  OK 已是目标版本")
            return True
        with self._lock:
            n1 = len(self._inbox)
        sent = self.publish(payload)
        mid = str(sent.get("messageId") or "")

        def is_accepted(data: dict) -> bool:
            if str(data.get("dataType")) != "1004":
                return False
            if str(data.get("message") or "") != "ota_accepted":
                return False
            got_mid = data.get("messageId")
            if mid and got_mid and str(got_mid) != mid:
                return False
            return True

        acc = self.wait_pred(n1, 20, is_accepted)
        if not acc:
            print("  FAIL 无 1004 ota_accepted")
            return False
        print("  设备已受理 ota_accepted")
        stage_timeout = max(60.0, timeout_ms / 1000.0)
        deadline = time.time() + stage_timeout
        failed = None
        saw_success = False
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[n1:]
            for _topic, data in newer:
                if str(data.get("dataType")) != "1004":
                    continue
                stage = str(data.get("stage") or "")
                if stage == "failed":
                    failed = data
                    break
                if stage == "success":
                    saw_success = True
                    print("  拉包成功 stage=success，等待重启后 1008")
                    break
            if failed or saw_success:
                break
            time.sleep(0.2)
        if failed:
            print(f"  FAIL 拉包 stage=failed ret={failed.get('ret')} {failed.get('message')}")
            return False
        reboot_deadline = time.time() + 180
        last_q = 0.0
        while time.time() < reboot_deadline:
            with self._lock:
                newer = self._inbox[n1:]
            for _topic, data in newer:
                if str(data.get("dataType")) != "1008":
                    continue
                fw = str(data.get("firmwareVersion") or "")
                if fw == version:
                    print(f"  OK 闭环通过 firmwareVersion={fw}")
                    return True
                if fw:
                    print(f"  .. 1008 firmwareVersion={fw}（尚未到目标）")
            now = time.time()
            if now - last_q >= 8:
                last_q = now
                self.publish({"dataType": "2008"})
            time.sleep(0.3)
        print("  FAIL 重启后未升到目标版本")
        return False

    def interactive(self) -> None:
        print("命令: list | send <id> | safe | danger <id> | quit")
        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            if line in {"q", "quit", "exit"}:
                break
            if line == "list":
                self.print_list()
                continue
            if line == "safe":
                self.run_safe()
                continue
            parts = line.split(maxsplit=1)
            if parts[0] in {"send", "danger"} and len(parts) == 2:
                item = self.find_cmd(parts[1])
                if not item:
                    print("未知 id，先 list")
                    continue
                self.send_cmd(item, danger_ok=(parts[0] == "danger" or item.get("_group") != "danger"))
                continue
            print("未知命令")

    def print_list(self) -> None:
        for item in self.all_cmds():
            flag = item["_group"]
            t31x = " T31x" if item.get("need_t31x") else ""
            print(f"  [{flag:6}] {item['id']:10} {item['name']} → {item.get('expect') or '-'}{t31x}")


def main(argv: list[str] | None = None) -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="Cat.1 MQTT 平台测试客户端")
    ap.add_argument("--config", default=str(CFG_PATH))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--send", metavar="ID", help="发送一条命令（如 2008 / 2010q）")
    ap.add_argument("--run-safe", action="store_true", help="跑只读查询")
    ap.add_argument("--run-extra", action="store_true", help="跑 extra 设置项")
    ap.add_argument("--run-danger", action="store_true", help="跑可逆危险项（开/停录），不含重启关机")
    ap.add_argument("--run-all", action="store_true", help="全指令：查询+设置+T31x+rest/关机拦截+最后重启；格式化需另加 --tf-format")
    ap.add_argument("--ota-loop", action="store_true", help="MQTT 2004 OTA 闭环（须 --ota-version）")
    ap.add_argument("--ota-version", default="", help="目标 firmwareVersion，如 2044.001.147")
    ap.add_argument("--ota-url", default="", help="拉包 URL，默认生产 /ota/api/site/firmware_upgrade?")
    ap.add_argument("--danger", action="store_true", help="允许发送 danger 分组（不含 skip_auto）")
    ap.add_argument("--danger-all", action="store_true", help="含重启/关机/进 rest（不含 TF 格式化）")
    ap.add_argument("--tf-format", action="store_true", help="含 TF 卡格式化（2009 reboot=0）")
    ap.add_argument("--listen", type=float, default=0, help="连接后只监听 N 秒")
    args = ap.parse_args(argv)

    cfg = _load_json(Path(args.config))
    commands = _load_json(CMD_PATH)
    if not args.list:
        cfg["client_id"] = f"platform-test-{uuid.uuid4().hex[:8]}"
    cli = ToolsClient(cfg, commands)
    if args.list:
        cli.print_list()
        return 0
    cli.connect()
    try:
        if args.listen:
            print(f"监听 {args.listen:.0f}s …")
            time.sleep(args.listen)
            return 0
        if args.send:
            item = cli.find_cmd(args.send)
            if not item:
                print("未知命令 id")
                return 2
            ok = cli.send_cmd(item, danger_ok=args.danger)
            return 0 if ok else 1
        if args.run_safe:
            st = cli.run_safe()
            return 0 if st.get("fail", 0) == 0 else 1
        if args.ota_loop:
            if not args.ota_version.strip():
                print("请加 --ota-version，例如 2044.001.147")
                return 2
            ok = cli.run_ota_loop(args.ota_version.strip(), args.ota_url.strip())
            return 0 if ok else 1
        if args.run_extra:
            cli.run_group("extra", danger_ok=True)
            return 0
        if args.run_all:
            print("\n######## 先停录，再全指令 ########")
            pre = cli.find_cmd("2011pre") or cli.find_cmd("2011")
            if pre:
                cli.send_cmd(dict(pre, _group="danger"), danger_ok=True)
            time.sleep(3)
            cli.run_group("safe", danger_ok=False)
            cli.run_group("extra", danger_ok=True)
            cli.run_group(
                "danger",
                danger_ok=True,
                include_destructive=True,
                include_tf_format=bool(args.tf_format),
            )
            return 0
        if args.run_danger or args.danger_all:
            cli.run_group(
                "danger",
                danger_ok=True,
                include_destructive=bool(args.danger_all),
                include_tf_format=bool(args.tf_format),
            )
            return 0
        if args.tf_format:
            item = cli.find_cmd("2009fmt")
            if not item:
                print("未知命令 2009fmt")
                return 2
            ok = cli.send_cmd(item, danger_ok=True)
            return 0 if ok else 1
        cli.interactive()
        return 0
    finally:
        cli.close()


if __name__ == "__main__":
    raise SystemExit(main())
