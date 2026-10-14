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
        source = path.read_bytes()
        self.assertEqual(result['sprites']['digRight0']['address'], hex(int.from_bytes(source[0x7A22 - decoder.BASE:0x7A24 - decoder.BASE], 'little')))
        self.assertEqual(result['sprites']['digLeft0']['address'], hex(int.from_bytes(source[0x7A24 - decoder.BASE:0x7A26 - decoder.BASE], 'little')))
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

    def test_hole_and_scoring_operands_come_from_selected_actual_instructions(self):
        path = ROOT / 'Library/SourceMedia/retro/apple-panic-apple-ii/program-01.bin'
        if not path.exists(): self.skipTest('Source-owned media are intentionally untracked')
        source = path.read_bytes()
        rules = decoder.rule_evidence(source)
        for name, value in [('player_odd_x_lookahead', 7), ('player_partial_hole_push', 7),
                            ('nearby_hole_distance_exclusive', 6), ('new_hole_clearance_exclusive', 9),
                            ('hole_row_slots', 14), ('stack_floor_spacing', 32), ('stack_terminal_row', 175),
                            ('unoccupied_full_hole_code', 5), ('occupied_full_hole_code', 133),
                            ('score_accumulator_count', 6), ('enemy_survivor_hole_push', 8)]:
            self.assertEqual(rules[name]['value'], value, name)
        self.assertTrue(rules['chain_insertion_after_first_zero']['extra_increment'])
        self.assertTrue(rules['enemy_occupied_hole_lookahead']['source_step_sequences_verified'])
        corrupt = bytearray(source); corrupt[0x8F44 - decoder.BASE] ^= 1
        with self.assertRaises(ValueError): decoder.rule_evidence(bytes(corrupt))

    def test_selected_hole_and_score_windows_match_reference_instructions(self):
        path = ROOT / 'Library/SourceMedia/retro/apple-panic-apple-ii/program-01.bin'
        reference = ROOT / 'Library/Research/apple-panic/reference-disassembly.asm'
        if not path.exists() or not reference.exists(): self.skipTest('Local original and annotated listing are intentionally untracked')
        comparison = decoder.reference_comparison(reference.read_text(), path.read_bytes())
        for name in ['player_hole_lookup', 'player_horizontal_holes', 'enemy_capture_dispatch_order',
                     'enemy_occupied_hole_lookahead', 'chain_accumulator_insertion', 'chain_crushing',
                     'chain_score_total', 'chain_strength_threshold', 'chain_accumulator_multiply', 'chain_survivor_push']:
            start, end = decoder.WINDOWS[name]
            self.assertFalse(any(start < int(row['address'], 16) + row['size'] and int(row['address'], 16) < end
                                 for row in comparison['mismatches']), name)

if __name__ == '__main__': unittest.main()
