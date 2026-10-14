import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('apple_panic_decoder', ROOT / 'Tools/decode_apple_panic.py')
decoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decoder)

class ApplePanicDecoderTests(unittest.TestCase):
    def test_wrong_identity_and_truncation_are_rejected(self):
        for data in [b'', bytes(decoder.LENGTH), bytes(decoder.LENGTH - 1)]:
            with self.assertRaises(ValueError): decoder.decode(data)

    def test_static_listing_comparison_detects_patch(self):
        source = bytearray(decoder.LENGTH)
        source[0x7000 - decoder.BASE:0x7004 - decoder.BASE] = bytes([0xA9, 3, 0x69, 2])
        reference = '         ORG $7000\n         LDA #$03\n         ADC #$01\n'
        comparison = decoder.reference_comparison(reference, bytes(source))
        self.assertEqual(comparison['compared_bytes'], 4)
        self.assertEqual(comparison['matching_bytes'], 2)
        self.assertEqual(comparison['mismatches'][0]['address'], '0x7002')

    def test_reference_address_drift_is_rejected(self):
        with self.assertRaises(ValueError):
            decoder.reference_comparison('         ORG $7000\nL_7001\n         RTS\n', bytes(decoder.LENGTH))

    def test_original_source_tables_and_masks_when_local_media_present(self):
        path = ROOT / 'Library/SourceMedia/retro/apple-panic-apple-ii/program-01.bin'
        if not path.exists(): self.skipTest('Source-owned media are intentionally untracked')
        result = decoder.decode(path.read_bytes())
        self.assertEqual(result['sourceControls'], {'right': 'K', 'left': 'J', 'up': 'I', 'down': 'M', 'dig': 'A', 'fill': 'S'})
        self.assertEqual(result['enemyCounts'], [3, 5, 8])
        self.assertEqual(len(result['layouts']), 4)
        self.assertEqual(len(result['enemyTypes']), 16)
        self.assertEqual(result['enemyTypes'][0], [0] * 8)
        self.assertEqual(result['enemyTypes'][-1], [2] * 8)
        self.assertEqual(len(result['sprites']), 16)
        for sprite in result['sprites'].values():
            self.assertEqual(sprite['width'], 21)
            self.assertEqual(len(sprite['rows']), sprite['height'])
            self.assertTrue(all(0 <= row < 1 << 21 for row in sprite['rows']))
        corrupt = bytearray(path.read_bytes()); corrupt[-1] ^= 1
        with self.assertRaises(ValueError): decoder.decode(bytes(corrupt))

    def test_evidence_fences_every_function_window_to_present_payload(self):
        for start, end in decoder.WINDOWS.values():
            self.assertGreaterEqual(start, decoder.BASE)
            self.assertLessEqual(end, decoder.BASE + decoder.LENGTH)
            self.assertLess(start, end)

if __name__ == '__main__': unittest.main()
