import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from decode_asteroids8bit import CODE_SHA256, SOURCE_SHA256, TABLE_SHA256, WINDOWS, decode, prepare
from prepare_asteroids import REFERENCES, read_reference


class Asteroids8BitDecoderTests(unittest.TestCase):
    def test_wrong_selected_source_fails_before_output(self):
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            decode(bytes(8717))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / REFERENCES[2].archive).write_bytes(b"wrong edition")
            with self.assertRaises(ValueError):
                prepare(root)
            self.assertFalse((root / "Library").exists())

    @unittest.skipUnless((ROOT / REFERENCES[2].archive).is_file(), "Owner-supplied archive unavailable")
    def test_actual_tables_shapes_and_hash_only_receipt(self):
        payload = read_reference(ROOT, REFERENCES[2])
        resources, receipt = decode(payload)
        self.assertEqual(resources["sourceSHA256"], SOURCE_SHA256)
        self.assertEqual(resources["codeSHA256"], CODE_SHA256)
        self.assertEqual(resources["waveCounts"], list(range(4, 17, 2)))
        self.assertEqual(len(resources["shipRows"]), 19 * 5)
        self.assertEqual(resources["extents"], [16, 5, 7, 12])
        self.assertEqual(resources["sine"][0], 0)
        self.assertEqual(resources["sine"][64], 127)
        tables = bytes(v for name in WINDOWS for v in resources[name])
        self.assertEqual(hashlib.sha256(tables).hexdigest(), TABLE_SHA256)
        for record in receipt["windows"]:
            offset, count = record["payload_file_offset"], record["bytes"]
            self.assertEqual(hashlib.sha256(payload[offset:offset + count]).hexdigest(), record["sha256"])
            self.assertNotIn("data", record)
            self.assertNotIn("values", record)

    @unittest.skipUnless((ROOT / REFERENCES[2].archive).is_file(), "Owner-supplied archive unavailable")
    def test_every_byte_mutation_rejects_selected_identity(self):
        payload = read_reference(ROOT, REFERENCES[2])
        for address, count in WINDOWS.values():
            modified = bytearray(payload)
            modified[6 + address - 0x5500 + count - 1] ^= 1
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                decode(bytes(modified))

    def test_committed_receipt_has_exact_selected_source_windows(self):
        receipt = json.loads((ROOT / "docs/research/evidence/asteroids8bit-lifecycle.json").read_text())
        self.assertEqual(receipt["source_sha256"], SOURCE_SHA256)
        self.assertEqual(receipt["table_sha256"], TABLE_SHA256)
        named = {r["name"]: r for r in receipt["windows"]}
        self.assertEqual(named["vbi"]["address"], "$6F2F")
        self.assertEqual(named["sound-callback"]["address"], "$72D7")


if __name__ == "__main__":
    unittest.main()
