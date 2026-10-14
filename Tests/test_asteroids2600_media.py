import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
from prepare_asteroids import REFERENCES, read_reference
from prepare_asteroids2600 import decode, prepare, window, content_digest, TABLES, SOURCE_SHA256


class Asteroids2600MediaTests(unittest.TestCase):
    def source(self):
        if not (ROOT / REFERENCES[0].archive).is_file():
            self.skipTest("Owner-supplied Asteroids 2600 archive unavailable")
        return read_reference(ROOT, REFERENCES[0])

    def test_rejects_carrier_changes_and_truncation(self):
        for data in (b"", bytes(8191), bytes(8192), bytes(8193)):
            with self.assertRaises(ValueError):
                decode(data)

    def test_window_has_explicit_bank_and_address_bounds(self):
        for bank, address, count in ((2, 0xD000, 1), (0, 0xCFFF, 1), (0, 0xDFFF, 2),
                                     (1, 0xF000, 0), (1, 0xE000, 1), (1, 0xFFFF, 2)):
            with self.assertRaises(ValueError):
                window(bytes(8192), bank, address, count)
        self.assertEqual(window(bytes(8192), 1, 0xFFFF, 1), b"\0")

    def test_all_tables_and_masks_are_fenced_to_selected_windows(self):
        rom = self.source()
        data, receipt = decode(rom)
        self.assertEqual(data["sourceSHA256"], SOURCE_SHA256)
        self.assertEqual(data["contentSHA256"], "22d0866eecfa11c3d8d39e7638964ffa12fc44a8c32a65e8645c1708b2b11c5b")
        self.assertEqual(content_digest(data), data["contentSHA256"])
        self.assertEqual(len(data["masks"]), 29)
        self.assertEqual(len(receipt["windows"]), 50)
        self.assertLess(len(json.dumps(data)), 64 * 1024)
        for name, (_, _, count) in TABLES.items():
            self.assertEqual(len(data["tables"][name]), count)
        for record in receipt["windows"]:
            start, size = record["rom_offset"], record["bytes"]
            self.assertEqual(hashlib.sha256(rom[start:start + size]).hexdigest(), record["sha256"])
        self.assertNotIn("rom", data)

    def test_changed_decoded_content_cannot_retain_canonical_identity(self):
        data, _ = decode(self.source())
        original = data["contentSHA256"]
        data["tables"]["horizontalIncreasing"][0x1D] ^= 1
        self.assertNotEqual(content_digest(data), original)

    def test_position_tables_preserve_selected_cartridge_ring_and_anomaly(self):
        data, _ = decode(self.source())
        tables = data["tables"]
        packed, codes, pixels = 0x1D, set(), set()
        for _ in range(160):
            self.assertNotIn(packed, codes)
            codes.add(packed)
            pixels.add((tables["horizontalHigh"][packed >> 4] + tables["horizontalLow"][packed & 15]) & 255)
            next_code = tables["horizontalIncreasing"][packed]
            packed = next_code
        self.assertEqual(packed, 0x1D)
        self.assertEqual(pixels, set(range(160)))
        # The selected D800 table is not the inverse of D700: $65 -> $83
        # changes decoded X from 13 to 14. Retain this byte-level behavior.
        self.assertEqual(tables["horizontalDecreasing"][0x65], 0x83)
        packed, seen = 0x1D, set()
        while packed not in seen:
            seen.add(packed)
            packed = tables["horizontalDecreasing"][packed]
        self.assertEqual(len(seen), 162)
        self.assertEqual(packed, 0x1D)

    def test_original_masks_use_integer_rows_and_source_digit_order(self):
        data, _ = decode(self.source())
        masks = {value["name"]: value for value in data["masks"]}
        self.assertEqual(masks["digit-1"]["rows"][0], 2)
        self.assertEqual(masks["digit-1"]["rows"][-1], 7)
        self.assertEqual(len(masks["asteroid-0"]["rows"]), 15)
        self.assertEqual(len(masks["asteroid-3"]["rows"]), 4)
        self.assertEqual(masks["ship-0"]["rows"][0], 0x10)
        self.assertEqual(masks["ship-0"]["rows"][-1], 0x7C)
        for mask in masks.values():
            self.assertTrue(all(type(row) is int and 0 <= row < 1 << mask["width"] for row in mask["rows"]))

    def test_preparation_rejects_archive_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / REFERENCES[0].archive).write_bytes(b"wrong archive")
            with self.assertRaises(ValueError):
                prepare(root)
            self.assertFalse((root / "Library").exists())


if __name__ == "__main__":
    unittest.main()
