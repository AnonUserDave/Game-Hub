import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from decode_dig_dug_graphics import (Body, GAME_SHA256, GraphicsError, decode,
    decode_nibbles, decode_run_nibbles, decode_sparse_sprites, prepare,
    reflect_sprite, source_level_index, sprite_indices, transform_twelve_rows)


class DigDugGraphicsTests(unittest.TestCase):
    def test_nibble_dictionary_and_terminator_are_bounded(self):
        values, consumed = decode_nibbles(bytes([0x23, 0xA0, 255, 99]), bytes(range(16)))
        self.assertEqual(values, bytes([2, 3, 10, 0]))
        self.assertEqual(consumed, 3)
        for stream, lookup, limit in [(b"\x12", bytes(range(16)), 32),
                                      (b"\x12\xff", b"short", 32),
                                      (b"\x12\xff", bytes(range(16)), 1)]:
            with self.assertRaises(GraphicsError):
                decode_nibbles(stream, lookup, limit)

    def test_sparse_sprite_prefix_columns_and_zero_rows(self):
        prefix = bytes(range(12))
        frames = decode_sparse_sprites(bytes([0x81, 0xA2, 9, 8, 7, 6]), prefix)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][:3], bytes(3))
        self.assertEqual(frames[0][3:15], prefix)
        self.assertEqual(frames[0][15:21], bytes([9, 0, 8, 7, 0, 6]))
        self.assertEqual(frames[0][21:], bytes(42))
        self.assertEqual(decode_sparse_sprites(bytes([0, 1]), prefix), [bytes(63)])

    def test_sparse_sprite_rejects_truncated_height_and_frame_overflow(self):
        prefix = bytes(12)
        for stream in [b"\x00", bytes([0, 0]), bytes([20, 2]),
                       bytes([0x91, 0xE1, 1, 2, 3]), bytes([0, 0xE1, 1, 2]),
                       bytes([0, 1]) * 129]:
            with self.subTest(stream_length=len(stream)), self.assertRaises(GraphicsError):
                decode_sparse_sprites(stream, prefix)

    def test_run_nibble_zero_count_is256_and_bounds_are_enforced(self):
        literals = bytes(range(8))
        output, consumed = decode_run_nibbles(bytes([0x81, 0]), literals)
        self.assertEqual(output, bytes([0x55]) * 256 + b"\x01")
        self.assertEqual(consumed, 2)
        output, _ = decode_run_nibbles(bytes([0xA2, 0]), literals)
        self.assertEqual(output, bytes([0x55, 0x55, 2]))
        with self.assertRaises(GraphicsError):
            decode_run_nibbles(bytes([0x81, 0]), literals, limit=256)
        with self.assertRaises(GraphicsError):
            decode_run_nibbles(b"\x12", literals)

    @staticmethod
    def pack(pixels):
        return bytes(sum(pixels[row][column + pair] << (6 - pair * 2) for pair in range(4))
                     for row in range(21) for column in range(0, 12, 4))

    def test_source_sprite_reflections_match_independent_pixels(self):
        pixels = [[(row * 3 + column) % 4 for column in range(12)] for row in range(21)]
        frame = self.pack(pixels)
        expected = self.pack([row[::-1] for row in pixels])
        self.assertEqual(reflect_sprite(frame), expected)
        self.assertEqual(reflect_sprite(reflect_sprite(frame)), frame)
        vertical = self.pack(pixels[:12][::-1] + [[0] * 12 for _ in range(9)])
        self.assertEqual(reflect_sprite(frame, vertical=True), vertical)
        self.assertEqual(sprite_indices(frame), [value for row in pixels for value in row])
        with self.assertRaises(GraphicsError):
            reflect_sprite(bytes(64))

    def test_source_nine_bit_rotate_matches_independent_quarter_turn(self):
        pixels = [[(row * 3 + column * 2 + row // 3) % 4 for column in range(12)] for row in range(21)]
        frame = self.pack(pixels)
        # Shift distances describe9-bit rotation through initial zero carry.
        # Their independent2-bit pixel consequence is a90-degree left turn.
        shifts = bytes([9 - 6, 9 - 4, 9 - 2, 0, 2, 4, 6])
        masks = bytes([3 << (2 * i) for i in range(4)] + [0, 0, 255])
        rotated = [[pixels[column][11 - row] for column in range(12)] for row in range(12)]
        expected = self.pack(rotated + [[0] * 12 for _ in range(9)])
        self.assertEqual(transform_twelve_rows(frame, shifts, masks), expected)
        with self.assertRaises(GraphicsError):
            transform_twelve_rows(frame, bytes([8] * 7), masks)

    def test_all_source_level_bytes_fold_to_last_four(self):
        for level in range(256):
            expected = level if level < 16 else 12 + (level - 12) % 4
            self.assertEqual(source_level_index(level), expected)
        for level in [-1, 256]:
            with self.assertRaises(GraphicsError):
                source_level_index(level)

    def test_wrong_body_and_changed_revision_do_not_write_outputs(self):
        with self.assertRaisesRegex(GraphicsError, "identity"):
            decode(bytes(24_576))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Library/SourceMedia/retro/dig-dug-c64"
            source.mkdir(parents=True)
            (source / "game.bin").write_bytes(bytes(24_576))
            with self.assertRaises(GraphicsError):
                prepare(root)
            self.assertFalse((root / "Library/Prepared").exists())

    @unittest.skipUnless((ROOT / "Library/SourceMedia/retro/dig-dug-c64/game.bin").is_file(), "Owner-supplied corrected body unavailable")
    def test_selected_body_all_formats_and_fenced_receipt(self):
        body = (ROOT / "Library/SourceMedia/retro/dig-dug-c64/game.bin").read_bytes()
        prepared, receipt = decode(body)
        self.assertEqual(receipt["body_sha256"], GAME_SHA256)
        self.assertEqual(receipt["sprite_stream_frame_counts"], [50, 2, 9, 4, 3])
        self.assertEqual(receipt["decoded_nibble_table_bytes"], [316, 426, 208, 224])
        self.assertEqual(receipt["decoded_bitmap_pattern_bytes"], 287)
        self.assertEqual(len(prepared["sprites"]), 112)
        self.assertTrue(all(len(record["bytes"]) == 63 for record in prepared["sprites"]))
        self.assertEqual(len(prepared["levels"]["layouts"]), 16)
        self.assertEqual(sum(record["available"] for record in prepared["levels"]["spawns"]), 15)
        self.assertFalse(prepared["levels"]["spawns"][0]["available"])
        expected_slots = [21, 19, 17, 15, 13, 11, 9, 7, 6, 5, 4, 3, 2]
        expected_indices = list(range(12, -1, -1))
        for record in prepared["levels"]["spawns"][1:]:
            self.assertEqual([placement["slot"] for placement in record["placements"]], expected_slots)
            self.assertEqual([placement["recordIndex"] for placement in record["placements"]], expected_indices)
        for record in receipt["windows"]:
            offset, count = record["body_offset"], record["bytes"]
            self.assertEqual(hashlib.sha256(body[offset:offset + count]).hexdigest(), record["sha256"])
            self.assertNotIn("data", record)
        resource = Body(body)
        with self.assertRaises(GraphicsError):
            resource.block(60)
        with self.assertRaises(GraphicsError):
            resource.read(0xD800, 1024)
        changed = bytearray(body); changed[0x8C8B - 0x6000] ^= 1
        with self.assertRaises(GraphicsError):
            decode(bytes(changed))

    def test_committed_receipt_contains_counts_hashes_and_explicit_unknowns(self):
        receipt = json.loads((ROOT / "docs/research/evidence/dig-dug-graphics.json").read_text())
        self.assertEqual(receipt["body_sha256"], GAME_SHA256)
        self.assertEqual(receipt["unresolved_spawn_records"], 1)
        self.assertTrue(any("font" in limit for limit in receipt["limits"]))
        self.assertNotIn("sprites", receipt)
        self.assertNotIn("levels", receipt)


if __name__ == "__main__":
    unittest.main()
