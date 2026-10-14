import struct
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from neversoft_assets import lzss, pre3, pkr2, collision_v9, collision_v10


class NeversoftAssetsTests(unittest.TestCase):
    def test_lzss_literals_overlap_and_initial_zero_ring(self):
        # Literal ABC at ring 0xfee, then overlapping six-byte match.
        self.assertEqual(lzss(bytes([7, 65, 66, 67, 0xee, 0xf3]), 9), b"ABCABCABC")
        self.assertEqual(lzss(bytes([0, 0, 0]), 3), b"\0\0\0")
        for data, count in [(b"\0\0", 3), (b"\x01A", 2), (b"\x01A", 0)]:
            with self.assertRaises(ValueError):
                lzss(data, count)

    def test_pre_paths_sizes_and_alignment(self):
        name = b"levels\\test.col\0"
        name += b"\0" * ((-len(name)) % 4)
        payload = b"ABC"
        body = struct.pack("<4I", 3, 0, len(name), 42) + name + payload + b"\0"
        data = struct.pack("<3I", len(body) + 12, 0xabcd0003, 1) + body
        entry = pre3(data)[0]
        self.assertEqual(entry.path, "levels/test.col")
        self.assertEqual(entry.read(data), payload)
        with self.assertRaises(ValueError):
            pre3(data[:-1])
        bad = data.replace(name, b"../outside\0".ljust(len(name), b"\0"))
        with self.assertRaises(ValueError):
            pre3(bad)

    def test_pkr_stored_directory_and_orphan_rejection(self):
        header = struct.pack("<4s3I", b"PKR2", 1, 1, 1)
        directory = struct.pack("<32s2I", b"data/\0", 56, 1)
        entry = struct.pack("<32si3I", b"test.psx\0", -2, 104, 3, 3)
        data = header + directory + entry + b"abc"
        self.assertEqual(pkr2(data)[0].path, "data/test.psx")
        self.assertEqual(pkr2(data)[0].read(data), b"abc")
        with self.assertRaises(ValueError):
            pkr2(data[:52] + struct.pack("<I", 0) + data[56:])

    @staticmethod
    def collision(fixed=False, small=False):
        header = struct.pack("<8I", 9, 1, 3, 0 if small else 1, 1 if small else 0,
                             0 if fixed else 3, 3 if fixed else 0, 0)
        obj = struct.pack("<IHHHBBI8f4I", 42, 2, 3, 1, small, fixed, 0,
                          0, 0, 0, 1, 4, 2, 0, 1, 0, 0, 0, 0)
        vertices = struct.pack("<9H", 0, 0, 0, 64, 0, 0, 0, 32, 0) if fixed else struct.pack("<9f", 0, 0, 0, 4, 0, 0, 0, 2, 0)
        raw = header + obj + vertices + b"\xff" * 3
        raw += b"\0" * ((-len(raw)) % 4)
        return raw + (struct.pack("<HH3Bx", 0x3000, 14, 0, 1, 2) if small else struct.pack("<HH3H", 0x3000, 14, 0, 1, 2))

    def test_fixed_float_and_small_large_faces_preserve_geometry(self):
        outputs = []
        for fixed in (False, True):
            for small in (False, True):
                out, report = collision_v9(self.collision(fixed, small))
                outputs.append(out)
                self.assertEqual(report["vertices"], 3)
                self.assertEqual(report["triangles"], 1)
                self.assertEqual(report["terrain_types"], {"14": 1})
        self.assertTrue(all(out == outputs[0] for out in outputs))

    def test_collision_rejects_bad_counts_index_version_and_nan(self):
        raw = self.collision()
        variants = [raw[:-1], struct.pack("<I", 10) + raw[4:],
                    raw[:8] + struct.pack("<I", 4) + raw[12:],
                    raw[:-2] + struct.pack("<H", 3),
                    raw[:96] + struct.pack("<f", float("nan")) + raw[100:]]
        for data in variants:
            with self.assertRaises(ValueError):
                collision_v9(data)

    def test_v10_requires_explicit_variant_and_preserves_geometry(self):
        raw = self.collision()
        v10 = struct.pack("<I", 10) + raw[4:]
        self.assertEqual(collision_v9(raw)[0], collision_v10(v10)[0])
        self.assertEqual(collision_v10(v10)[1]["format"], "collision-v10")

    def test_repeated_object_spans_fail_before_expanding_beyond_header_counts(self):
        raw = self.collision()
        header = bytearray(raw[:32])
        struct.pack_into("<I", header, 4, 2)
        first = raw[32:96]
        # Two object records alias the same source geometry. Their aggregate
        # expansion exceeds the header, even though every source span fits.
        duplicated_vertices = bytes(header) + first + first + raw[96:]
        second = bytearray(first)
        struct.pack_into("<H", second, 6, 0)  # No additional vertices.
        duplicated_faces = bytes(header) + first + bytes(second) + raw[96:]
        for decode, version in ((collision_v9, 9), (collision_v10, 10)):
            for data, expected in ((duplicated_vertices, "vertex"),
                                   (duplicated_faces, "face")):
                with self.subTest(version=version, total=expected):
                    data = struct.pack("<I", version) + data[4:]
                    with self.assertRaisesRegex(ValueError,
                                                f"object {expected} total exceeds header"):
                        decode(data)


if __name__ == "__main__":
    unittest.main()
