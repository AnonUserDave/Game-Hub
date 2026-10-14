import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("night_driver", Path(__file__).parents[1] / "Tools/decode_night_driver.py")
night = importlib.util.module_from_spec(spec)
spec.loader.exec_module(night)


class NightDriverDecodeTests(unittest.TestCase):
    def test_bounded_malformed_packed_streams(self):
        with self.assertRaisesRegex(night.DecodeError, "Truncated"):
            night.decode_stream(b"", 0x80)
        with self.assertRaisesRegex(night.DecodeError, "unwritten"):
            night.decode_stream(bytes(2), 0x80)
        with self.assertRaisesRegex(night.DecodeError, "Oversized literal"):
            night.decode_stream(b"\xff" * 8, 0x80)
        with self.assertRaisesRegex(night.DecodeError, "bounds"):
            night.decode_stream(b"", 0)

    def test_end_marker_is_a_format_value(self):
        # No literals, then a match-length overflow: binary 100000000 with
        # continuation bits between the value bits. No CPU opcodes are present.
        bits = [0]
        value = [1] + [0] * 8
        for index, bit in enumerate(value):
            bits.append(bit)
            if index < 8:
                bits.append(1)
        bits += [0] * ((-len(bits)) % 8)
        bytes_read = bytes(sum(bits[start + bit] << (7 - bit) for bit in range(8)) for start in range(0, len(bits), 8))
        data, consumed = night.decode_stream(bytes_read[::-1], 0x80)
        self.assertEqual(data, b"")
        self.assertEqual(consumed, 3)

    def test_literal_output_bound(self):
        # Literal length 2, continuation=0; the same first bit byte retains the
        # end marker's leading bits while the two raw literal bytes are read.
        bits = [1, 1, 0, 0]  # value 10 with continuation 1 then 0.
        value = [1] + [0] * 8
        for index, bit in enumerate(value):
            bits.append(bit)
            if index < 8:
                bits.append(1)
        bits += [0] * ((-len(bits)) % 8)
        bit_bytes = [sum(bits[start + bit] << (7 - bit) for bit in range(8)) for start in range(0, len(bits), 8)]
        read_order = bytes([bit_bytes[0], ord("b"), ord("a"), *bit_bytes[1:]])
        self.assertEqual(night.decode_stream(read_order[::-1], 0x80)[0], b"ab")
        with self.assertRaisesRegex(night.DecodeError, "exceeds bound"):
            night.decode_stream(read_order[::-1], 0x80, max_output=1)

    def test_selected_program_identity_and_complete_local_decode(self):
        with self.assertRaisesRegex(night.DecodeError, "identity"):
            night.decode_program(bytes(4101))
        path = night.ROOT / "Library/SourceMedia/retro/night-driver-c64/program-00.bin"
        if not path.exists():
            self.skipTest("Original media intentionally omitted from clean clones")
        unpacked, game = night.decode_program(path.read_bytes())
        self.assertEqual(len(unpacked), 8449)
        self.assertEqual(night.sha256(unpacked), night.UNPACKED_SHA256)
        self.assertEqual(len(game), 8192)
        self.assertEqual(night.sha256(game), night.GAME_SHA256)
        self.assertEqual(game[-6:], bytes([0x24, 0xec, 0x3e, 0xe0, 0xb1, 0xeb]))
        # Keep the normal timer instruction, rather than the optional trainer.
        self.assertEqual(game[0xc0e], 0x01)


if __name__ == "__main__":
    unittest.main()
