#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模拟 T31x 报警视频上传（multipart type+file）。"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

AES_KEY = "7f3A9c82D1e64B5F90a7C3d8E2F6b410"
KNOWN = {"1": "E/06stPxcWJoF8IkMn0xYw==", "2": "F8Wslm2+Dd3VlowtNJ5BTg=="}
DEFAULT_URL = "http://43.136.55.143:7003/admin/api/v1/uploadVideo"


def encrypt_type(video_type: str) -> str:
    if video_type in KNOWN:
        return KNOWN[video_type]
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives import padding
    import base64

    pad = padding.PKCS7(128).padder()
    data = pad.update(video_type.encode("utf-8")) + pad.finalize()
    cipher = Cipher(algorithms.AES(AES_KEY.encode("utf-8")), modes.ECB()).encryptor()
    return base64.b64encode(cipher.update(data) + cipher.finalize()).decode("ascii")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--file", default="")
    ap.add_argument("--type", default="1", choices=("1", "2"))
    ap.add_argument("--filename", default="")
    args = ap.parse_args()

    src = args.file
    tmp = None
    if not src:
        fd, tmp = tempfile.mkstemp(prefix="clip_sim_", suffix=".ts")
        os.write(fd, b"\x47" * 188 * 8 + b"SIMULATED_T31X_CLIP\n")
        os.close(fd)
        src = tmp
        print("using dummy file", src)
    path = Path(src)
    if not path.is_file():
        print("file not found:", src, file=sys.stderr)
        return 2
    fname = args.filename or path.name
    enc = encrypt_type(args.type)
    print("POST", args.url)
    print("type(plain)=%s type(b64)=%s file=%s as=%s size=%d" % (
        args.type, enc, path, fname, path.stat().st_size))

    import urllib.request

    boundary = "----ClipUploadBoundary7f3A9c82"
    file_bytes = path.read_bytes()
    chunks = []
    def add_field(name: str, value: bytes, filename: str | None = None, ctype: str | None = None):
        chunks.append(("--" + boundary + "\r\n").encode("ascii"))
        disp = 'Content-Disposition: form-data; name="%s"' % name
        if filename is not None:
            disp += '; filename="%s"' % filename
        chunks.append((disp + "\r\n").encode("utf-8"))
        if ctype:
            chunks.append(("Content-Type: %s\r\n" % ctype).encode("ascii"))
        chunks.append(b"\r\n")
        chunks.append(value)
        chunks.append(b"\r\n")

    add_field("type", enc.encode("ascii"))
    add_field("file", file_bytes, filename=fname, ctype="video/MP2T")
    chunks.append(("--" + boundary + "--\r\n").encode("ascii"))
    body = b"".join(chunks)
    req = urllib.request.Request(
        args.url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "multipart/form-data; boundary=%s" % boundary,
            "Content-Length": str(len(body)),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            print("HTTP", resp.status)
            print(raw.decode("utf-8", errors="replace"))
            return 0 if 200 <= resp.status < 300 else 1
    except Exception as exc:
        print("upload failed:", exc, file=sys.stderr)
        return 1
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
