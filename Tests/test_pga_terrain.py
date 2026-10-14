import math
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from decode_pga2005_terrain import decode, packed_coordinate


class TerrainDecodeTests(unittest.TestCase):
    def fixture(self):
        table = 0x324
        size = table + 0x136
        data = bytearray(size + 20)
        struct.pack_into("<H", data, 0, 7)
        struct.pack_into("<I", data, 0x3e, size)
        struct.pack_into("<H", data, 0x46, 1)
        struct.pack_into("<I", data, 0x104, table)
        struct.pack_into("<ff", data, 0xd8, 4, 2)
        struct.pack_into("<fff", data, 0x318, 10, 20, 30)
        struct.pack_into("<IIII", data, table, size, size, size, 20)
        struct.pack_into("<4H", data, table + 0x33, 1, 0, 0, 0)
        data[size:size + 12] = bytes((0, 4, 0, 0, 8, 0, 0, 6, 0, 10, 20, 30))
        struct.pack_into("<ff", data, size + 12, 0.25, 0.75)
        return data, size, table

    def test_source_mixed_byte_order_and_sign_extension(self):
        self.assertEqual(packed_coordinate(bytes((4, 0x79, 0x3a)), 0), 0x43a79)
        self.assertEqual(packed_coordinate(bytes((15, 255, 255)), 0), -1)
        self.assertEqual(packed_coordinate(bytes((8, 0, 0)), 0), -524288)

    def test_scale_origin_color_uv_and_output_layout(self):
        data, _, _ = self.fixture()
        output, report = decode(bytes(data), mesh=False)
        self.assertEqual(len(output), 36 + 24)
        self.assertEqual(output[:4], b"GHPC")
        xyz = struct.unpack_from("<fff", output, 36)
        self.assertEqual(xyz, (12, 22, 33))
        self.assertEqual(output[48:52], bytes((10, 20, 30, 255)))
        self.assertEqual(struct.unpack_from("<ff", output, 52), (0.25, 0.75))
        self.assertEqual(report["point_count"], 1)

    def test_reject_bad_table_and_payload_bounds(self):
        data, _, table = self.fixture()
        struct.pack_into("<I", data, table, len(data) - 1)
        with self.assertRaises(ValueError):
            decode(bytes(data))
        data, _, _ = self.fixture()
        struct.pack_into("<I", data, 0x104, 0xffffffff)
        with self.assertRaises(ValueError):
            decode(bytes(data))

    def test_reject_unsupported_version_and_nonfinite_scale(self):
        data, _, _ = self.fixture()
        struct.pack_into("<H", data, 0, 8)
        with self.assertRaises(ValueError):
            decode(bytes(data))

    def mesh_fixture(self):
        data, size, table = self.fixture()
        payload = bytearray(171)
        payload[:20] = data[size:size + 20]
        payload[20:40] = payload[:20]
        payload[40:60] = payload[:20]
        struct.pack_into("<3H", payload, 60, 0, 1, 2)
        struct.pack_into("<I", payload, 66 + 0x18, 1)
        struct.pack_into("<iIiII", payload, 66 + 0x41, -6, 1, -66, 3, 10)
        data = data[:size] + payload
        struct.pack_into("<I", data, table + 12, len(payload))
        struct.pack_into("<4H", data, table + 0x33, 3, 0, 0, 0)
        struct.pack_into("<I", data, table + 0x81, 66)
        return data, size

    def test_original_group_indices_and_material_are_preserved(self):
        data, _ = self.mesh_fixture()
        output, report = decode(bytes(data))
        self.assertEqual(struct.unpack_from("<IIII", output, 4), (2, 3, 1, 1))
        self.assertEqual(struct.unpack_from("<4I", output, 44 + 3 * 24), (0, 1, 2, 10))
        self.assertEqual(report["material_triangle_counts"], {10: 1})

    def test_group_out_of_range_indices_are_rejected(self):
        data, size = self.mesh_fixture()
        struct.pack_into("<H", data, size + 60, 3)
        with self.assertRaises(ValueError):
            decode(bytes(data))
        data, _, _ = self.fixture()
        struct.pack_into("<f", data, 0xd8, math.nan)
        with self.assertRaises(ValueError):
            decode(bytes(data))


if __name__ == "__main__":
    unittest.main()
