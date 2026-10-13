import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from import_pga2005 import decode_tga, decode_dds, parse_course_ini, png_bytes
from inspect_pga2005 import safe_target


class CourseImportTests(unittest.TestCase):
    def test_duplicate_pivots_and_source_errors_are_preserved(self):
        result = parse_course_ini(b"[HOLE 1]\r\npar=4\r\npivot0=1,2,3\r\npivot0=4,5,6\r\nhandicap=16.16.16\r\nyardage=123,456\r\n")
        hole = result["holes"][0]
        self.assertEqual([p["xyz_raw"] for p in hole["pivots"]], [[1, 2, 3], [4, 5, 6]])
        self.assertEqual(hole["warnings"][0]["raw"], "16.16.16")
        self.assertEqual(hole["yardage"], [123, 456])

    def test_tga_origin_and_color_order(self):
        header = bytearray(18)
        header[2] = 2
        struct.pack_into("<HHBB", header, 12, 1, 2, 24, 0)
        w, h, rgba = decode_tga(bytes(header) + bytes((0, 0, 255, 255, 0, 0)))
        self.assertEqual((w, h), (1, 2))
        self.assertEqual(rgba, bytes((0, 0, 255, 255, 255, 0, 0, 255)))
        self.assertTrue(png_bytes(w, h, rgba).startswith(b"\x89PNG"))

    def test_tga_rle_overrun_is_rejected(self):
        header = bytearray(18)
        header[2] = 10
        struct.pack_into("<HHBB", header, 12, 1, 1, 24, 32)
        with self.assertRaises(ValueError):
            decode_tga(bytes(header) + bytes((129, 0, 0, 0)))

    def test_dds_dxt1_transparent_and_opaque(self):
        data = bytearray(136)
        data[:4] = b"DDS "
        struct.pack_into("<I", data, 4, 124)
        struct.pack_into("<II", data, 12, 4, 4)
        struct.pack_into("<II4s", data, 76, 32, 4, b"DXT1")
        struct.pack_into("<HHI", data, 128, 0, 0xffff, 3)
        _, _, rgba = decode_dds(bytes(data))
        self.assertEqual(rgba[:4], b"\0\0\0\0")
        self.assertEqual(rgba[4:8], b"\0\0\0\xff")

    def test_dds_dxt5_alpha_interpolation(self):
        data = bytearray(144)
        data[:4] = b"DDS "
        struct.pack_into("<I", data, 4, 124)
        struct.pack_into("<II", data, 12, 4, 4)
        struct.pack_into("<II4s", data, 76, 32, 4, b"DXT5")
        data[128:130] = bytes((255, 0))
        data[130:136] = (2).to_bytes(6, "little")
        struct.pack_into("<HHI", data, 136, 0xffff, 0, 0)
        _, _, rgba = decode_dds(bytes(data))
        self.assertEqual(rgba[:4], bytes((255, 255, 255, 218)))

    def test_path_traversal_is_rejected(self):
        with self.assertRaises(ValueError):
            safe_target(Path("/tmp/game-hub-test"), "../../escape.png")


if __name__ == "__main__":
    unittest.main()
