import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'Tools'))
import decode_asteroids7800 as decoder


class Asteroids7800MediaTests(unittest.TestCase):
    def payload(self):
        source = ROOT / 'Library/SourceMedia/asteroids/atari7800.a78'
        if not source.is_file():
            self.skipTest('Selected original media is absent')
        return source.read_bytes()

    def test_selected_tables_and_content_identity(self):
        package = decoder.decode_payload(self.payload())
        self.assertEqual(package['tables']['waveCaps'], [8, 12, 14, 16])
        self.assertEqual(package['tables']['scoreBCDHigh'], [1, 0, 0, 5, 16, 2, 0, 0])
        self.assertEqual(len(package['frames']), 813)
        self.assertEqual(decoder.content_digest(package), '12917c9cac4f193f1a2dab07a8a2955b44ada245aba4ac648392d319ec87798d')

    def test_bad_identity_rejected_before_decode(self):
        with self.assertRaises(ValueError):
            decoder.decode_payload(b'\0' * 16512)
        payload = bytearray(self.payload()); payload[128] ^= 1
        with self.assertRaises(ValueError):
            decoder.decode_payload(payload)

    def test_rows_reverse_pages_and_color_pairs(self):
        rom = bytearray(16384)
        rom[15 * 256 + 1] = 0b01101100
        rom[1] = 0b11100100
        image = decoder.graphics(rom, 0xC000, 1, 1)
        self.assertEqual(image['pixels'][:4], [1, 2, 3, 0])
        self.assertEqual(image['pixels'][-4:], [3, 2, 1, 0])
        self.assertEqual(image['width'], 4)

    def test_graphics_bounds(self):
        for bank, low, width, height in [(0xD000, 0, 1, 16), (0xC000, 255, 2, 16),
                                         (0xC000, 0, 0, 16), (0xC000, 0, 1, 17)]:
            with self.assertRaises(ValueError):
                decoder.graphics(bytes(16384), bank, low, width, height)

    def test_table_windows_are_bounded_and_actual_bytes(self):
        payload = self.payload()
        for name, (address, count) in decoder.TABLES.items():
            self.assertGreaterEqual(address, 0xC000)
            self.assertLessEqual(address + count, 0x10000)
            self.assertEqual(len(payload[address - 0xC000 + 128:address - 0xC000 + 128 + count]), count)
        self.assertEqual(len(decoder.TABLES), 44)


if __name__ == '__main__':
    unittest.main()
