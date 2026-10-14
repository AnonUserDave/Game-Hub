import importlib.util
from pathlib import Path
import sys
import unittest


spec = importlib.util.spec_from_file_location("dig_dug", Path(__file__).parents[1] / "Tools/decode_dig_dug.py")
dig = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = dig
spec.loader.exec_module(dig)


def packed_bits(bits):
    bits += [0] * (-len(bits) % 8)
    return bytes(sum(bits[start + bit] << (7 - bit) for bit in range(8))
                 for start in range(0, len(bits), 8))[::-1]


class DigDugDecodeTests(unittest.TestCase):
    def test_run_markers_and_escaped_marker_values(self):
        stream = bytes([65, 0xE2, 4, 0xCB, 0xE7, 0xC7, 0xD6, 2, 0xCB, 0xC7, 3, 66])
        self.assertEqual(dig.decode_runs(stream), b"A" + bytes([0xCB]) * 4 + bytes([0xC7]) * 3
                         + bytes(3) + b"   B")

    def test_zero_counts_are_full_byte_runs_and_bounds_hold(self):
        self.assertEqual(dig.decode_runs(bytes([0xE2, 0, 90])), b"Z" * 256)
        self.assertEqual(dig.decode_runs(bytes([0xD6, 0])), bytes(256))
        self.assertEqual(dig.decode_runs(bytes([0xC7, 0])), b" " * 256)
        with self.assertRaisesRegex(dig.DecodeError, "exceeds bound"):
            dig.decode_runs(bytes([0xE2, 0, 90]), max_output=255)
        with self.assertRaisesRegex(dig.DecodeError, "bound"):
            dig.decode_runs(b"", max_output=0)

    def test_truncated_marker_operands_are_rejected(self):
        for stream in (bytes([0xE2]), bytes([0xE2, 2]), bytes([0xE7]), bytes([0xD6]), bytes([0xC7])):
            with self.subTest(stream=stream):
                with self.assertRaisesRegex(dig.DecodeError, "Truncated"):
                    dig.decode_runs(stream)

    def test_backward_end_marker_and_literal_match_are_format_values(self):
        table = bytearray(256)
        table[16] = 1  # synthetic first literal run of one
        table[48] = 1  # synthetic first match run of one
        # The first 8 bits are the supplied initial byte. Then one literal A,
        # a length-one match at distance one and a unary index-16 end marker.
        initial = 0b10100000  # selector=1; first seven bits of A=0100000
        bits = [1, 1, 0, 0, 0, 0] + [0] * 16 + [1]
        output, receipt = dig.decode_backward(packed_bits(bits), table, initial)
        self.assertEqual(output, b"AA")
        self.assertEqual((receipt.literal_bytes, receipt.match_bytes), (1, 1))
        with self.assertRaisesRegex(dig.DecodeError, "exceeds bound"):
            dig.decode_backward(packed_bits(bits), table, initial, max_output=1)

    def test_backward_bad_distance_width_and_truncation(self):
        table = bytearray(256)
        table[48] = 1
        # Empty literal run; nonempty match immediately references no output.
        with self.assertRaisesRegex(dig.DecodeError, "unwritten"):
            dig.decode_backward(b"", table, 0b11000000)
        table[0] = 17
        with self.assertRaisesRegex(dig.DecodeError, "bit width"):
            dig.decode_backward(b"", table, 0x80)
        with self.assertRaisesRegex(dig.DecodeError, "Truncated"):
            dig.decode_backward(b"", bytes(256), 0)
        with self.assertRaisesRegex(dig.DecodeError, "bounds"):
            dig.decode_backward(b"", b"", 0)

    def test_selected_media_layers_have_exact_hashes_and_extents(self):
        with self.assertRaisesRegex(dig.DecodeError, "identity"):
            dig.decode_program(bytes(16551))
        path = dig.ROOT / "Library/SourceMedia/retro/dig-dug-c64/program-00.bin"
        if not path.exists():
            self.skipTest("Original media intentionally omitted from clean clones")
        intro, second, game, receipt = dig.decode_program(path.read_bytes())
        self.assertEqual((len(intro), len(second), len(game)), (23044, 19333, 24490))
        self.assertEqual([dig.sha256(data) for data in (intro, second, game)],
                         [dig.INTRO_SHA256, dig.SECOND_STAGE_SHA256, dig.GAME_SHA256])
        self.assertEqual((receipt.literal_bytes, receipt.match_bytes), (6660, 16384))
        # The final body has a bounded $6000..$BFA9 range, trainer at $7090
        # and game at $8000. Recovery does not prove gameplay or timing.
        self.assertEqual(0x6000 + len(game), 0xBFAA)


if __name__ == "__main__":
    unittest.main()
