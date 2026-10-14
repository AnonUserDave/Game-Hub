import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from prepare_asteroids import REFERENCES, parse_a78, parse_xex, prepare, read_reference


class AsteroidsMediaTests(unittest.TestCase):
    def test_a78_decodes_without_inventing_mapper(self):
        header = bytearray(128)
        header[0] = 1
        header[1:17] = b"ATARI7800       "
        header[17:49] = b"Test" + b" " * 28
        header[49:53] = (3).to_bytes(4, "big")
        header[100:128] = b"ACTUAL CART DATA STARTS HERE"
        info = parse_a78(bytes(header) + b"abc")
        self.assertEqual(info["title"], "Test")
        self.assertEqual(info["rom_bytes"], 3)
        self.assertEqual(info["rom_sha256"], hashlib.sha256(b"abc").hexdigest())
        self.assertNotIn("mapper", info)
        with self.assertRaises(ValueError):
            parse_a78(bytes(header) + b"ab")
        header[100] = 0
        with self.assertRaises(ValueError):
            parse_a78(bytes(header) + b"abc")

    def test_xex_keeps_records_and_file_offsets(self):
        carrier = b"\xff\xff" + struct.pack("<HH", 0x5500, 0x5502) + b"abc"
        carrier += b"\xff\xff" + struct.pack("<HH", 0x02e0, 0x02e1) + b"\x00\x55"
        records = parse_xex(carrier)
        self.assertEqual([(r["start"], r["end"], r["file_offset"]) for r in records],
                         [(0x5500, 0x5502, 6), (0x02e0, 0x02e1, 15)])

    def test_rejects_truncated_or_reversed_xex(self):
        invalid = [b"", b"\xff\xff", b"\xff\xff\x01", b"\xff\xff\xff\xff",
                   b"\xff\xff" + struct.pack("<HH", 2, 1),
                   b"\xff\xff" + struct.pack("<HH", 1, 5) + b"abc"]
        for carrier in invalid:
            with self.subTest(carrier=carrier), self.assertRaises(ValueError):
                parse_xex(carrier)

    def test_wrong_archive_hash_produces_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / REFERENCES[0].archive).write_bytes(b"different revision")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                prepare(root)
            self.assertFalse((root / "Library").exists())

    @unittest.skipUnless(all((ROOT / ref.archive).is_file() for ref in REFERENCES), "Owner-supplied archives unavailable")
    def test_selected_revisions_and_recovered_windows(self):
        evidence = json.loads((ROOT / "docs/research/evidence/asteroids-static.json").read_text())
        payloads = {ref.edition: read_reference(ROOT, ref) for ref in REFERENCES}
        for window in evidence["recovered_windows"]:
            data = payloads[window["edition"]]
            offset = window["payload_file_offset"]
            actual = hashlib.sha256(data[offset:offset + window["bytes"]]).hexdigest()
            self.assertEqual(actual, window["sha256"], window["behavior"])


if __name__ == "__main__":
    unittest.main()
