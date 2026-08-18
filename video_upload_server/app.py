#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""兼容南京后台的报警视频上传接口。

POST /admin/api/v1/uploadVideo
  multipart/form-data:
    type : AES-256-ECB + Base64（明文 "1"=侦测 "2"=回放）
    file : TS 视频

响应与南京后台同形，T31x 只要 HTTP 2xx 且 JSON 含 "path"。
"""
from __future__ import annotations

import cgi
import json
import os
import re
import sys
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("VIDEO_UPLOAD_HOST", "0.0.0.0")
PORT = int(os.environ.get("VIDEO_UPLOAD_PORT", "7003"))
ROOT = Path(os.environ.get("VIDEO_UPLOAD_ROOT", str(Path(__file__).resolve().parent)))
INCOMING = Path(os.environ.get("VIDEO_UPLOAD_DIR", str(ROOT / "incoming")))
MAX_BYTES = int(os.environ.get("VIDEO_UPLOAD_MAX_BYTES", str(400 * 1024 * 1024)))
AES_KEY = os.environ.get("VIDEO_UPLOAD_AES_KEY", "7f3A9c82D1e64B5F90a7C3d8E2F6b410")
TZ_CN = timezone(timedelta(hours=8))

# 与 T31x / Java demo 一致的 type 密文（AES-256-ECB PKCS7 + Base64）
KNOWN_TYPE_B64 = {
    "E/06stPxcWJoF8IkMn0xYw==": "1",
    "F8Wslm2+Dd3VlowtNJ5BTg==": "2",
}

TYPE_DIR = {
    "1": "dynamic",
    "2": "playback",
}


def _now_cn() -> datetime:
    return datetime.now(TZ_CN)


def _try_decrypt_type(b64_text: str) -> str | None:
    raw = (b64_text or "").strip()
    if not raw:
        return None
    if raw in ("1", "2"):
        return raw
    mapped = KNOWN_TYPE_B64.get(raw)
    if mapped:
        return mapped
    try:
        import base64
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding

        data = base64.b64decode(raw)
        cipher = Cipher(algorithms.AES(AES_KEY.encode("utf-8")), modes.ECB())
        decryptor = cipher.decryptor()
        padded = decryptor.update(data) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plain = unpadder.update(padded) + unpadder.finalize()
        text = plain.decode("utf-8").strip()
        if text in ("1", "2"):
            return text
    except Exception:
        pass
    try:
        from Crypto.Cipher import AES
        import base64

        data = base64.b64decode(raw)
        cipher = AES.new(AES_KEY.encode("utf-8"), AES.MODE_ECB)
        padded = cipher.decrypt(data)
        pad = padded[-1]
        if 1 <= pad <= 16:
            padded = padded[:-pad]
        text = padded.decode("utf-8").strip()
        if text in ("1", "2"):
            return text
    except Exception:
        pass
    return None


def _safe_filename(name: str) -> str:
    base = os.path.basename((name or "").replace("\\", "/"))
    base = re.sub(r"[^A-Za-z0-9._-]+", "_", base)
    if not base or base in (".", ".."):
        base = "clip.ts"
    if len(base) > 160:
        stem, ext = os.path.splitext(base)
        base = stem[:140] + (ext or ".ts")
    return base


def _human_size(n: int) -> str:
    mb = n / (1024.0 * 1024.0)
    if mb >= 0.01:
        return f"{mb:.2f}MB"
    return f"{n}B"


def _json_bytes(obj: dict, code: int = 200) -> tuple[bytes, int]:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    return body, code


class UploadHandler(BaseHTTPRequestHandler):
    server_version = "video-upload/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (_now_cn().strftime("%Y-%m-%d %H:%M:%S"), fmt % args))

    def _send(self, status: int, body: bytes, content_type: str = "application/json; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, obj: dict, status: int = 200) -> None:
        body, _ = _json_bytes(obj, status)
        self._send(status, body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path in ("/health", "/admin/api/v1/health"):
            self._send_json({"code": 200, "msg": "ok", "data": {"service": "uploadVideo"}})
            return
        if path in ("/", "/admin", "/admin/api/v1"):
            self._send(
                200,
                (
                    "<html><body><h3>uploadVideo</h3>"
                    "<p>POST /admin/api/v1/uploadVideo</p>"
                    "<p><a href='/admin/api/v1/videos'>list</a></p>"
                    "</body></html>"
                ).encode("utf-8"),
                "text/html; charset=utf-8",
            )
            return
        if path == "/admin/api/v1/videos":
            qs = parse_qs(parsed.query)
            limit = 50
            try:
                limit = min(200, max(1, int(qs.get("limit", ["50"])[0])))
            except ValueError:
                pass
            type_filter = (qs.get("type", [""])[0] or "").strip()
            begin_s = (qs.get("begin", [""])[0] or "").strip()
            end_s = (qs.get("end", [""])[0] or "").strip()
            items = []
            if INCOMING.exists():
                files = sorted(INCOMING.rglob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
                for f in files:
                    if not f.is_file() or f.suffix == ".json":
                        continue
                    st = f.stat()
                    rel = "/" + f.relative_to(INCOMING).as_posix()
                    vtype = "2" if rel.startswith("/playback/") else (
                        "1" if rel.startswith("/dynamic/") else ""
                    )
                    if type_filter in ("1", "2") and vtype != type_filter:
                        continue
                    mtime_dt = datetime.fromtimestamp(st.st_mtime, TZ_CN)
                    if begin_s:
                        try:
                            begin_dt = datetime.fromisoformat(begin_s.replace(" ", "T")).replace(tzinfo=TZ_CN)
                            if mtime_dt < begin_dt:
                                continue
                        except ValueError:
                            pass
                    if end_s:
                        try:
                            end_dt = datetime.fromisoformat(end_s.replace(" ", "T")).replace(tzinfo=TZ_CN)
                            if mtime_dt > end_dt:
                                continue
                        except ValueError:
                            pass
                    items.append(
                        {
                            "name": f.name,
                            "path": "/apps/video" + rel,
                            "size": _human_size(st.st_size),
                            "mtime": mtime_dt.isoformat(timespec="seconds"),
                            "type": vtype or "unknown",
                        }
                    )
                    if len(items) >= limit:
                        break
            self._send_json({"code": 200, "msg": "操作成功", "data": items})
            return
        if path.startswith("/apps/video/"):
            rel = path[len("/apps/video/") :]
            target = (INCOMING / rel).resolve()
            try:
                target.relative_to(INCOMING.resolve())
            except ValueError:
                self._send_json({"code": 404, "msg": "not found"}, 404)
                return
            if not target.is_file() or target.suffix == ".json":
                self._send_json({"code": 404, "msg": "not found"}, 404)
                return
            data = target.read_bytes()
            ctype = "video/MP2T" if target.suffix.lower() in {".ts", ".m2ts"} else "application/octet-stream"
            self._send(200, data, ctype)
            return
        self._send_json({"code": 404, "msg": "not found"}, 404)

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path != "/admin/api/v1/uploadVideo":
            self._send_json({"code": 404, "msg": "not found"}, 404)
            return
        try:
            self._handle_upload()
        except Exception as exc:
            sys.stderr.write("upload error: %r\n" % (exc,))
            self._send_json({"code": 500, "msg": "upload failed"}, 500)

    def _handle_upload(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            self._send_json({"code": 400, "msg": "empty body"}, 400)
            return
        if length > MAX_BYTES:
            self._send_json({"code": 413, "msg": "file too large"}, 413)
            return
        ctype = self.headers.get("Content-Type") or ""
        env = {
            "REQUEST_METHOD": "POST",
            "CONTENT_TYPE": ctype,
            "CONTENT_LENGTH": str(length),
        }
        form = cgi.FieldStorage(fp=self.rfile, headers=self.headers, environ=env, keep_blank_values=True)
        type_field = form.getfirst("type", "")
        file_item = form["file"] if "file" in form else None
        if file_item is None or not getattr(file_item, "file", None):
            self._send_json({"code": 400, "msg": "missing file"}, 400)
            return

        video_type = _try_decrypt_type(type_field) or "unknown"
        subdir = TYPE_DIR.get(video_type, "unknown")
        orig = _safe_filename(getattr(file_item, "filename", None) or "clip.ts")
        stamp = _now_cn().strftime("%Y%m%d%H%M%S") + "%03d" % (int(time.time() * 1000) % 1000)
        stem, ext = os.path.splitext(orig)
        if not ext:
            ext = ".ts"
        real_name = "%s-%s%s" % (stem, stamp, ext)
        dest_dir = INCOMING / subdir
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / real_name

        size = 0
        with dest.open("wb") as out:
            while True:
                chunk = file_item.file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_BYTES:
                    out.close()
                    dest.unlink(missing_ok=True)
                    self._send_json({"code": 413, "msg": "file too large"}, 413)
                    return
                out.write(chunk)

        if size <= 0:
            dest.unlink(missing_ok=True)
            self._send_json({"code": 400, "msg": "empty file"}, 400)
            return

        rel_path = "/apps/video/%s/%s" % (subdir, real_name)
        meta = {
            "realName": real_name,
            "origName": orig,
            "type": video_type,
            "typeCipher": type_field,
            "path": rel_path,
            "sizeBytes": size,
            "size": _human_size(size),
            "client": self.client_address[0],
            "savedAt": _now_cn().isoformat(timespec="seconds"),
        }
        dest.with_suffix(dest.suffix + ".json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        self.log_message(
            "saved %s type=%s size=%s from=%s",
            dest, video_type, _human_size(size), self.client_address[0],
        )
        self._send_json(
            {
                "code": 200,
                "msg": "操作成功",
                "data": {
                    "realName": real_name,
                    "path": rel_path,
                    "size": _human_size(size),
                    "type": video_type,
                },
            }
        )


def main() -> int:
    INCOMING.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((HOST, PORT), UploadHandler)
    print(
        "uploadVideo listening on http://%s:%d/admin/api/v1/uploadVideo dir=%s"
        % (HOST, PORT, INCOMING),
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("stop", flush=True)
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
