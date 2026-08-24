#!/usr/bin/env python3
"""x86 模拟 IPC：按 pack_tool 产物走 ipc_upgrade（ipc.json → :8008/downloads/ipc.tar）。"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import tarfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("BIND", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8010"))
DEVICE_ID = os.environ.get("DEVICE_ID", "T31-X86-DEMO")
FIRMWARE_NAME = os.environ.get("FIRMWARE_NAME", "T31_IPC")
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "http://43.136.55.143").rstrip("/")
PUBLIC_DOWNLOAD_BASE = os.environ.get("PUBLIC_DOWNLOAD_BASE", "http://43.136.55.143:8008").rstrip("/")
INTERNAL_DOWNLOAD_BASE = os.environ.get("INTERNAL_DOWNLOAD_BASE", "http://nginx").rstrip("/")
INTERNAL_DOWNLOAD_8008 = os.environ.get("INTERNAL_DOWNLOAD_8008", "http://nginx:8008").rstrip("/")
FILE_DIR = Path(os.environ.get("FILE_DIR", "/var/www/fileserver"))
SLOT_DIR = Path(os.environ.get("SLOT_DIR", "/app/slot"))
STATE_FILE = SLOT_DIR / "device.json"
IPC_TAR = "ipc.tar"
IPC_JSON = "ipc.json"
LOCK = threading.Lock()
TASKS: dict[str, dict] = {}


def now_ms() -> int:
    return int(time.time() * 1000)


def load_state() -> dict:
    SLOT_DIR.mkdir(parents=True, exist_ok=True)
    FILE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(FILE_DIR, 0o755)
    except OSError:
        pass
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    state = {
        "deviceId": DEVICE_ID,
        "firmwareName": FIRMWARE_NAME,
        "version": os.environ.get("VERSION", "1.0.0"),
        "state": "idle",
        "lastSessionId": None,
        "lastResult": None,
        "updatedAt": now_ms(),
    }
    save_state(state)
    return state


def save_state(state: dict) -> None:
    SLOT_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def md5_bytes(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def public_url(filename: str = IPC_TAR) -> str:
    return f"{PUBLIC_DOWNLOAD_BASE}/downloads/{filename}"


def url80(filename: str = IPC_TAR) -> str:
    return f"{PUBLIC_BASE}/downloads/{filename}"


def fetch_like_ipc(url: str) -> bytes:
    """模拟 ipc_upgrade HTTP GET。同机访问公网 IP 会 NAT 回环失败，改走容器内 nginx。"""
    fetch = url
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if host in ("43.136.55.143", "127.0.0.1", "localhost"):
        path = parsed.path or "/"
        query = ("?" + parsed.query) if parsed.query else ""
        if parsed.port == 8008:
            fetch = INTERNAL_DOWNLOAD_8008 + path + query
        else:
            fetch = INTERNAL_DOWNLOAD_BASE + path + query
    req = urllib.request.Request(fetch, method="GET", headers={"User-Agent": "ipc_upgrade-x86demo"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def parse_multipart(header: str, body: bytes) -> tuple[str | None, bytes | None, dict[str, str]]:
    m = re.search(r"boundary=([^;]+)", header or "", re.I)
    if not m:
        raise ValueError("missing multipart boundary")
    boundary = m.group(1).strip().strip('"').encode()
    parts = body.split(b"--" + boundary)
    filename = None
    filedata = None
    fields: dict[str, str] = {}
    for part in parts:
        if b"\r\n\r\n" not in part:
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        if data.endswith(b"\r\n"):
            data = data[:-2]
        fn_m = re.search(br'filename="([^"]+)"', head)
        name_m = re.search(br'name="([^"]+)"', head)
        if fn_m:
            filename = Path(fn_m.group(1).decode("utf-8", "replace")).name
            filedata = data
        elif name_m:
            fields[name_m.group(1).decode("utf-8", "replace")] = data.decode("utf-8", "replace")
    return filename, filedata, fields


def wrap_as_ipc_tar(filename: str, data: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        info = tarfile.TarInfo(name=filename or "payload.bin")
        info.size = len(data)
        info.mtime = int(time.time())
        tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def looks_like_tar(data: bytes) -> bool:
    if len(data) < 265:
        return False
    try:
        return tarfile.is_tarfile(io.BytesIO(data))
    except Exception:
        return False


def write_ipc_json(version: str, tar_bytes: bytes, extra: dict | None = None) -> dict:
    meta = {
        "name": "ipc",
        "version": version,
        "url": public_url(IPC_TAR),
        "md5": md5_bytes(tar_bytes),
        "size": len(tar_bytes),
        "file": IPC_TAR,
    }
    if extra:
        for k, v in extra.items():
            if k not in meta and v is not None:
                meta[k] = v
    dest = FILE_DIR / IPC_JSON
    dest.write_text(json.dumps(meta, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    try:
        os.chmod(dest, 0o644)
    except OSError:
        pass
    return meta


def install_tar(blob: bytes) -> dict:
    slot_tar = SLOT_DIR / "current.tar"
    slot_tar.write_bytes(blob)
    (SLOT_DIR / "current.md5").write_text(md5_bytes(blob), encoding="utf-8")
    extract_dir = SLOT_DIR / "extract"
    if extract_dir.exists():
        shutil.rmtree(extract_dir, ignore_errors=True)
    extract_dir.mkdir(parents=True, exist_ok=True)
    members: list[str] = []
    if looks_like_tar(blob):
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tar:
            try:
                tar.extractall(extract_dir, filter="data")
            except TypeError:
                tar.extractall(extract_dir)
            members = [m.name for m in tar.getmembers()]
    else:
        (extract_dir / "payload.bin").write_bytes(blob)
        members = ["payload.bin"]
    return {"members": members, "extracted": str(extract_dir)}


def run_ipc_upgrade(task: dict) -> None:
    session = task["sessionId"]
    state = load_state()
    try:
        task["stage"] = "downloading"
        url = task["url"]
        expect_md5 = (task.get("expectMd5") or "").lower() or None
        version = task["version"]

        if url.rstrip("/").lower().endswith(".json"):
            task["message"] = "ipc_upgrade HTTP GET ipc.json"
            with LOCK:
                state["state"] = "upgrading"
                state["lastSessionId"] = session
                save_state(state)
            raw_json = fetch_like_ipc(url)
            meta = json.loads(raw_json.decode("utf-8"))
            task["manifest"] = meta
            tar_url = (meta.get("url") or "").strip()
            if not tar_url:
                raise RuntimeError("ipc.json missing url")
            version = (meta.get("version") or version).strip()
            task["version"] = version
            if meta.get("md5"):
                expect_md5 = str(meta["md5"]).lower()
            task["message"] = "ipc_upgrade HTTP GET ipc.tar " + tar_url
            blob = fetch_like_ipc(tar_url)
        else:
            task["message"] = "ipc_upgrade HTTP GET FileUrl (ipc.tar)"
            with LOCK:
                state["state"] = "upgrading"
                state["lastSessionId"] = session
                save_state(state)
            blob = fetch_like_ipc(url)

        task["bytes"] = len(blob)
        got_md5 = md5_bytes(blob)
        task["md5"] = got_md5
        if expect_md5 and expect_md5 != got_md5:
            raise RuntimeError(f"md5 mismatch expect={expect_md5} got={got_md5}")
        if len(blob) == 0:
            raise RuntimeError("empty firmware")
        task["stage"] = "installing"
        task["message"] = "extract ipc.tar"
        installed = install_tar(blob)
        task["extract"] = installed
        with LOCK:
            state = load_state()
            state["version"] = version
            state["state"] = "idle"
            state["lastResult"] = "OK"
            state["updatedAt"] = now_ms()
            save_state(state)
        task["stage"] = "success"
        task["result"] = "OK"
        task["message"] = "DeviceUpgradeResult OK"
        task["deviceVersion"] = version
    except Exception as e:
        task["stage"] = "failed"
        task["result"] = "ERROR"
        task["message"] = str(e)
        with LOCK:
            state = load_state()
            state["state"] = "idle"
            state["lastResult"] = "ERROR"
            save_state(state)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print("[%s] " % time.strftime("%H:%M:%S") + (fmt % args), flush=True)

    def _json(self, code: int, obj) -> None:
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(raw)

    def _read(self) -> bytes:
        n = int(self.headers.get("Content-Length") or "0")
        return self.rfile.read(n) if n else b""

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        qs = parse_qs(urlparse(self.path).query)
        if path in ("/health", "/ipc_upgrade/health"):
            return self._json(200, {"ok": True, "role": "x86demo", "fn": "ipc_upgrade", "pack": "ipc.tar"})
        if path in ("/status", "/ipc_upgrade/status", "/api/status"):
            state = load_state()
            sid = qs.get("sessionId", [None])[0]
            if sid and sid in TASKS:
                state["task"] = TASKS[sid]
            elif TASKS:
                state["task"] = list(TASKS.values())[-1]
            return self._json(200, state)
        if path in ("/api/packages", "/ipc_upgrade/api/packages"):
            files = []
            for p in sorted(FILE_DIR.glob("*")):
                if p.is_file() and p.name != ".gitkeep":
                    files.append({
                        "filename": p.name,
                        "size": p.stat().st_size,
                        "url": public_url(p.name),
                        "url80": url80(p.name),
                        "url8008": public_url(p.name),
                    })
            manifest = None
            json_path = FILE_DIR / IPC_JSON
            if json_path.exists():
                try:
                    manifest = json.loads(json_path.read_text(encoding="utf-8"))
                except Exception:
                    manifest = None
            return self._json(200, {
                "packages": files,
                "ipc": {
                    "tar": IPC_TAR,
                    "json": IPC_JSON,
                    "url": public_url(IPC_TAR),
                    "manifest": manifest,
                },
            })
        if path.startswith("/api/tasks/") or path.startswith("/ipc_upgrade/api/tasks/"):
            sid = path.rsplit("/", 1)[-1]
            task = TASKS.get(sid)
            return self._json(200, task) if task else self._json(404, {"error": "task not found"})
        return self._json(404, {"error": "not found", "path": path})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path in ("/api/packages", "/ipc_upgrade/api/packages"):
            try:
                filename, data, fields = parse_multipart(self.headers.get("Content-Type", ""), self._read())
            except Exception as e:
                return self._json(400, {"error": str(e)})
            if not data:
                return self._json(400, {"error": "no file field"})
            version = (fields.get("version") or os.environ.get("VERSION") or "1.0.30").strip()
            name = (filename or IPC_TAR).lower()
            try:
                os.chmod(FILE_DIR, 0o755)
            except OSError:
                pass

            if name.endswith(".json"):
                try:
                    incoming = json.loads(data.decode("utf-8"))
                except Exception:
                    return self._json(400, {"error": "ipc.json invalid"})
                version = (incoming.get("version") or version).strip()
                tar_path = FILE_DIR / IPC_TAR
                if not tar_path.exists():
                    return self._json(400, {"error": "upload ipc.tar first"})
                meta = write_ipc_json(version, tar_path.read_bytes(), extra=incoming)
                info = {
                    "filename": IPC_JSON,
                    "size": (FILE_DIR / IPC_JSON).stat().st_size,
                    "md5": meta["md5"],
                    "version": version,
                    "url": meta["url"],
                    "url80": url80(IPC_TAR),
                    "url8008": meta["url"],
                    "manifest": meta,
                }
                return self._json(200, info)

            if name.endswith(".tar") or looks_like_tar(data):
                tar_bytes = data
            else:
                tar_bytes = wrap_as_ipc_tar(filename or "payload.bin", data)

            dest = FILE_DIR / IPC_TAR
            dest.write_bytes(tar_bytes)
            try:
                os.chmod(dest, 0o644)
            except OSError:
                pass
            meta = write_ipc_json(version, tar_bytes)
            info = {
                "filename": IPC_TAR,
                "size": len(tar_bytes),
                "md5": meta["md5"],
                "version": version,
                "url": meta["url"],
                "url80": url80(IPC_TAR),
                "url8008": meta["url"],
                "manifest": meta,
            }
            return self._json(200, info)

        if path in ("/api/ipc_upgrade", "/ipc_upgrade/api/ipc_upgrade", "/ipc_upgrade"):
            try:
                body = json.loads(self._read().decode("utf-8") or "{}")
            except Exception:
                return self._json(400, {"error": "invalid json"})
            filename = (body.get("filename") or "").strip()
            url = (body.get("url") or body.get("FileUrl") or "").strip()
            version = (body.get("version") or "").strip()
            if filename and not url:
                url = public_url(filename if filename.endswith((".tar", ".json")) else IPC_TAR)
            if not url:
                url = public_url(IPC_TAR)
            if not version:
                json_path = FILE_DIR / IPC_JSON
                if json_path.exists():
                    try:
                        version = json.loads(json_path.read_text(encoding="utf-8")).get("version") or ""
                    except Exception:
                        version = ""
            if not url or not version:
                return self._json(400, {"error": "url/filename and version required"})
            session = (body.get("sessionId") or body.get("SessionID") or "upg-" + uuid.uuid4().hex[:10])
            task = {
                "sessionId": session,
                "deviceId": body.get("deviceId") or DEVICE_ID,
                "firmwareName": body.get("firmwareName") or FIRMWARE_NAME,
                "url": url,
                "version": version,
                "expectMd5": (body.get("md5") or "").lower() or None,
                "stage": "accepted",
                "result": None,
                "message": "ipc_upgrade accepted",
                "createdAt": now_ms(),
            }
            TASKS[session] = task
            threading.Thread(target=run_ipc_upgrade, args=(task,), daemon=True).start()
            return self._json(200, {"ok": True, "sessionId": session, "task": task})
        return self._json(404, {"error": "not found", "path": path})


def main() -> int:
    load_state()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        f"ipc_x86demo listen {HOST}:{PORT} device={DEVICE_ID} files={FILE_DIR} "
        f"download={PUBLIC_DOWNLOAD_BASE}/downloads/{IPC_TAR}",
        flush=True,
    )
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
