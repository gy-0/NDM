#!/usr/bin/env python3
"""
NDM preference string crypto — recovered from binary via radare2.

Evidence:
  reverse/dumps/r2/encryptString_disasm.txt
  reverse/dumps/r2/aes_encrypt_full.txt

Algorithm (NSData AES256 + NeatNsUtils encryptString:):
  - AES-256-CBC
  - Key: UTF-8 password "SG2921", zero-padded to 32 bytes
  - IV: 16 zero bytes
  - PKCS#7 padding
  - Output: Base64 (NSData base64EncodedStringWithOptions:0)

Verified: encrypt(b"") == "BqhotGJODXhOF2DHpxSOGQ=="
(matches empty HTTP_PassWord / HTTPS_PassWord / FTP_PassWord in live prefs).
"""
from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

# Hardcoded app key recovered at 0x1000ca1b0 (str.cstr.SG2921)
NDM_AES_KEY_PASSWORD = b"SG2921"
NDM_AES_KEY = NDM_AES_KEY_PASSWORD.ljust(32, b"\x00")
ZERO_IV = b"\x00" * 16


def _openssl(mode: str, data: bytes) -> bytes:
    """mode: 'e' encrypt or 'd' decrypt."""
    with tempfile.NamedTemporaryFile(delete=False) as fin:
        fin.write(data)
        fin.flush()
        in_path = fin.name
    out_path = in_path + ".out"
    try:
        cmd = [
            "openssl",
            "enc",
            f"-{mode}",
            "-aes-256-cbc",
            "-K",
            NDM_AES_KEY.hex(),
            "-iv",
            ZERO_IV.hex(),
            "-in",
            in_path,
            "-out",
            out_path,
        ]
        # openssl 3 may want -provider; default works on macOS LibreSSL/OpenSSL
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode("utf-8", "replace") or "openssl failed")
        return Path(out_path).read_bytes()
    finally:
        Path(in_path).unlink(missing_ok=True)
        Path(out_path).unlink(missing_ok=True)


def encrypt_string(plaintext: str) -> str:
    """Match NeatNsUtils +encryptString:"""
    raw = plaintext.encode("utf-8")
    ct = _openssl("e", raw)
    return base64.b64encode(ct).decode("ascii")


def decrypt_string(b64: str) -> str:
    """Match NeatNsUtils +decryptString:"""
    ct = base64.b64decode(b64)
    pt = _openssl("d", ct)
    return pt.decode("utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] not in ("enc", "dec"):
        print("Usage: ndm_crypto.py enc|dec <text-or-base64>", file=sys.stderr)
        return 2
    op, payload = argv[1], argv[2]
    if op == "enc":
        print(encrypt_string(payload))
    else:
        print(decrypt_string(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
