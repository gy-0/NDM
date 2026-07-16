#!/usr/bin/env python3
"""
Structural + unit tests for shipped reverse-engineering artifacts.

Drives real tools:
  - parse_segments.parse
  - protocol_message.parse_extension_message / constants

Fixtures live under reverse/fixtures/ (real segments.bin samples).
"""
from __future__ import annotations

import re
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # reverse/
REPO = ROOT.parent
TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import parse_segments  # noqa: E402
import protocol_message as proto  # noqa: E402
import ndm_crypto  # noqa: E402


class TestSegmentsFormat(unittest.TestCase):
    def test_4125_matches_documented_ranges(self):
        """Fixture from real task 4125; Range in log was 0-9595187 and 9595188-18207336."""
        path = ROOT / "fixtures" / "segments" / "4125_segments.bin"
        self.assertTrue(path.is_file(), f"missing fixture {path}")
        data = path.read_bytes()
        segs = parse_segments.parse(data)
        self.assertEqual(len(segs), 2)
        self.assertEqual(segs[0]["segmentId"], 0)
        self.assertEqual(segs[0]["start"], 0)
        self.assertEqual(segs[0]["end"], 9_595_187)
        self.assertEqual(segs[0]["next"], 1)
        self.assertEqual(segs[1]["segmentId"], 1)
        self.assertEqual(segs[1]["start"], 9_595_188)
        self.assertEqual(segs[1]["end"], 18_207_336)
        self.assertIn(segs[1]["next"], (-1, 0xFFFFFFFF))
        # inclusive length covers full Content-Range total 18207337
        total = segs[0]["length"] + segs[1]["length"]
        self.assertEqual(total, 18_207_337)

    def test_4125_log_excerpt_documents_same_ranges(self):
        excerpt = (ROOT / "fixtures" / "segments" / "4125_log_excerpt.txt").read_text()
        self.assertIn("Range = 0-", excerpt)
        self.assertIn("Range = 9595188-18207336", excerpt)
        self.assertIn("Content-Range: bytes 0-18207336/18207337", excerpt)

    def test_single_segment_fixture(self):
        path = ROOT / "fixtures" / "segments" / "3592_single.bin"
        segs = parse_segments.parse(path.read_bytes())
        self.assertEqual(len(segs), 1)
        self.assertEqual(segs[0]["segmentId"], 0)
        self.assertIn(segs[0]["next"], (-1, 0xFFFFFFFF))
        self.assertEqual(segs[0]["start"], 0)
        self.assertGreater(segs[0]["end"], 0)

    def test_bad_size_raises(self):
        with self.assertRaises(ValueError):
            parse_segments.parse(b"short")


class TestProtocolHostSide(unittest.TestCase):
    def test_endpoint_constants(self):
        self.assertEqual(proto.WS_URL, "ws://127.0.0.1:10007/download")
        self.assertEqual(proto.WS_SUBPROTOCOL, "neatextension.v1")
        self.assertEqual(proto.HOST_MSG_WAITING, "waiting")
        self.assertEqual(proto.HOST_MSG_NOWAITING, "nowaiting")

    def test_parse_roundtrip_betterndm_shape(self):
        raw = proto.build_extension_message(
            method="GET",
            url="https://example.com/file.zip",
            ltype="normal",
            page_title="Title",
            page_url="https://example.com/page",
            origin="https://example.com",
            referer="https://example.com/page",
            cookies="a=b",
            file_size=12345,
            content_type="application/zip",
            filename="file.zip",
        )
        msg = proto.parse_extension_message(raw)
        self.assertEqual(msg.method, "GET")
        self.assertEqual(msg.url, "https://example.com/file.zip")
        self.assertEqual(msg.ltype, "normal")
        self.assertEqual(msg.page_title, "Title")
        self.assertEqual(msg.origin, "https://example.com")
        self.assertEqual(msg.referer, "https://example.com/page")
        self.assertEqual(msg.cookies, "a=b")
        self.assertEqual(msg.file_size, 12345)
        self.assertEqual(msg.content_type, "application/zip")
        self.assertEqual(msg.filename, "file.zip")
        headers = msg.to_request_headers()
        self.assertTrue(any(h.startswith("Cookie:") for h in headers))
        self.assertTrue(any(h.startswith("Origin:") for h in headers))

    def test_missing_url_raises(self):
        with self.assertRaises(ValueError):
            proto.parse_extension_message("1:GET\r\n6:normal\r\n")

    def test_betterndm_source_contains_endpoint(self):
        bg = (ROOT / "extension" / "BetterNDM" / "bg.js").read_text(errors="ignore")
        self.assertIn("127.0.0.1:10007", bg)
        self.assertIn("neatextension.v1", bg)
        self.assertIn("ShowPanel", bg)
        self.assertIn('"1:"', bg.replace(" ", "") or "1:")
        # BetterNDM minified still has 1: concatenation
        self.assertIn('1:"', bg) or self.assertIn("1:", bg)

    def test_host_strings_dump_contains_protocol(self):
        strings = (ROOT / "dumps" / "all_strings.txt").read_text(errors="ignore")
        for needle in (
            "neatextension.v1",
            "waiting",
            "nowaiting",
            "ShowPanelChrome=1",
            "Sec-WebSocket-Protocol",
            "Starting WebSocketServer...",
        ):
            self.assertIn(needle, strings, f"host dump missing {needle}")


class TestStorageSpecs(unittest.TestCase):
    def test_schema_fixture_has_required_tables(self):
        sql = (ROOT / "fixtures" / "neatdb_schema.sql").read_text()
        self.assertIn("CREATE TABLE", sql)
        self.assertIn("downloads", sql)
        self.assertIn("auths", sql)
        self.assertIn("headers", sql)
        for col in (
            "url",
            "method",
            "filename",
            "ltype",
            "filesize",
            "category",
            "status",
            "bandwidthlimit",
            "connections",
            "resumable",
            "pageurl",
            "postdata",
            "folderpath",
            "urla",
        ):
            self.assertIn(col, sql)

    def test_schema_loads_in_sqlite(self):
        sql = (ROOT / "fixtures" / "neatdb_schema.sql").read_text()
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            conn = sqlite3.connect(tmp.name)
            conn.executescript(sql)
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            self.assertIn("downloads", tables)
            self.assertIn("auths", tables)
            self.assertIn("headers", tables)
            cols = {
                r[1]
                for r in conn.execute("PRAGMA table_info(downloads)")
            }
            self.assertIn("url", cols)
            self.assertIn("status", cols)
            conn.close()

    def test_settings_spec_lists_core_keys(self):
        text = (ROOT / "specs" / "06_SETTINGS.md").read_text()
        for key in (
            "DownloadDirectory",
            "MaxConnections",
            "BandWidthLimit",
            "HTTP_IsActive",
            "LastDownloadID",
            "AppAutoStart",
        ):
            self.assertIn(key, text)


class TestNdmCryptoFromBinary(unittest.TestCase):
    """AES path recovered via radare2 disassembly of encryptString: / CCCrypt."""

    def test_empty_password_matches_live_prefs_ciphertext(self):
        # Observed in com.NeatDownloadManager.plist for empty proxy passwords
        self.assertEqual(
            ndm_crypto.encrypt_string(""),
            "BqhotGJODXhOF2DHpxSOGQ==",
        )

    def test_roundtrip(self):
        for s in ("", "password", "hello-世界", "SG2921"):
            self.assertEqual(ndm_crypto.decrypt_string(ndm_crypto.encrypt_string(s)), s)

    def test_key_material(self):
        self.assertEqual(ndm_crypto.NDM_AES_KEY_PASSWORD, b"SG2921")
        self.assertEqual(len(ndm_crypto.NDM_AES_KEY), 32)
        self.assertTrue(ndm_crypto.NDM_AES_KEY.startswith(b"SG2921"))
        self.assertTrue(ndm_crypto.NDM_AES_KEY.endswith(b"\x00" * (32 - 6)))


class TestSpecCoverage(unittest.TestCase):
    REQUIRED_SPECS = [
        "00_OVERVIEW.md",
        "01_SOURCE_LAYOUT.md",
        "02_OBJC_CLASSES.md",
        "03_ENGINE.md",
        "04_SEGMENTS_FORMAT.md",
        "05_DATABASE.md",
        "06_SETTINGS.md",
        "07_BROWSER_PROTOCOL.md",
        "08_UI.md",
        "09_STATE_MACHINES.md",
        "10_GAPS.md",
        "11_APP_LIFECYCLE.md",
        "12_MODULE_BOUNDARIES.md",
    ]

    def test_all_specs_exist_and_nontrivial(self):
        for name in self.REQUIRED_SPECS:
            path = ROOT / "specs" / name
            self.assertTrue(path.is_file(), name)
            body = path.read_text()
            self.assertGreater(len(body), 200, f"{name} too short / stub")
            # no pure TODO-only stubs
            self.assertFalse(
                body.strip().upper() == "TODO",
                f"{name} is TODO stub",
            )

    def test_gaps_classifies_open_items(self):
        gaps = (ROOT / "specs" / "10_GAPS.md").read_text()
        self.assertIn("P0", gaps)
        self.assertIn("AES", gaps)
        # segments state mislabel closed
        self.assertTrue(
            "segmentId" in gaps or "已关闭" in gaps or "G02" in gaps
        )

    def test_readme_indexes_specs(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("specs/", readme)
        self.assertIn("BetterNDM", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
