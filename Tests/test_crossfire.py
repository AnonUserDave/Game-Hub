"""Offline format and source-identity gates; no original code is executed."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from analyze_crossfire_ghidra import address_image
from decode_crossfire import SPRITES, bonus_sprite_usage, sprite_rows


class CrossfireDecoderTests(unittest.TestCase):
    def test_seven_phase_row_stride(self):
        image = bytes([1, 2, 1, 2, 4, 8, 16, 32, 64, 64, 32, 16, 8, 4, 2, 1])
        self.assertEqual(sprite_rows(image, 0x300, 0), [[1, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 1]])
        self.assertEqual(sprite_rows(image, 0x300, 6), [[0, 0, 0, 0, 0, 0, 1], [1, 0, 0, 0, 0, 0, 0]])

    def test_truncation_and_dimensions_rejected(self):
        for image in [bytes([0, 2]), bytes([1, 33]), bytes([1, 2]) + bytes(13)]:
            with self.assertRaises(ValueError):
                sprite_rows(image, 0x300)
        with self.assertRaises(ValueError):
            sprite_rows(bytes(20), 0x2FF)

    def test_revision_gate_precedes_relocation(self):
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            address_image(bytes(27296))

    def test_local_selected_loader_copy_and_actor_records(self):
        path = Path(__file__).resolve().parents[1] / "Library/SourceMedia/retro/crossfire-apple-ii/program-01.bin"
        if not path.exists():
            self.skipTest("Owner-supplied selected Crossfire binary is absent")
        source = path.read_bytes()
        image = address_image(source)
        self.assertEqual(image[:0xD00], source[0x300:0x1000])
        self.assertEqual(image[0x4000 - 0x300:0x4000 - 0x300 + 4], bytes([0xA2, 0xFF, 0x9A, 0xD8]))
        self.assertEqual(image[0x5BB5 - 0x300:0x5BB5 - 0x300 + 7], bytes([0, 48, 0, 64, 0, 2, 3]))
        rows = sprite_rows(image, 0x6800)
        self.assertEqual((len(rows[0]), len(rows)), (21, 9))
        self.assertGreater(sum(map(sum, rows)), 0)

    def test_original_idle_bonus_pointer_shape_and_kind_specific_anchors(self):
        path = Path(__file__).resolve().parents[1] / "Library/SourceMedia/retro/crossfire-apple-ii/program-01.bin"
        if not path.exists(): self.skipTest("Owner-supplied selected Crossfire binary is absent")
        image = address_image(path.read_bytes())
        usage = bonus_sprite_usage(image)
        self.assertEqual(SPRITES["bonus-idle"], 0x6300)
        rows = sprite_rows(image, SPRITES["bonus-idle"])
        self.assertEqual((len(rows[0]), len(rows)), (21, 9))
        self.assertGreater(sum(map(sum, rows)), 0)
        self.assertEqual(usage["idle"]["kind"], 0)
        self.assertEqual(usage["idle"]["anchorDelta"], [4, 3])
        self.assertEqual(usage["collected"]["kinds"], [1, 2, 3, 4])
        self.assertEqual(usage["collected"]["anchorDelta"], [1, 4])
        self.assertEqual((usage["expiredKind"], usage["expiredPointer"]), (5, 0))
        corrupted = bytearray(image); corrupted[0x57D5 - 0x300] ^= 1
        with self.assertRaises(ValueError): bonus_sprite_usage(bytes(corrupted))


if __name__ == "__main__":
    unittest.main()
