import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from decode_pga2005_library import decode_materials
from decode_pga2005_holes import decode_holes


def fixtures():
    guid = bytes(range(16))
    tcr = bytearray(0x324)
    tcl = bytearray(0x324)
    for data in (tcr, tcl):
        struct.pack_into("<H", data, 0, 7)
        data[2:18] = guid
        struct.pack_into("<I", data, 0x3e, 0x324)
        struct.pack_into("<H", data, 0x50, 1)
    struct.pack_into("<H", tcr, 0x5e, 1)
    tcr[0x10c:0x11c] = guid
    struct.pack_into("<I", tcr, 0x80, 0x200)
    struct.pack_into("<I", tcl, 0x80, 0x1e0)
    struct.pack_into("<I", tcl, 0x7c, 0x200)
    struct.pack_into("<I", tcl, 0xe4, 0x220)
    struct.pack_into("<HI", tcl, 0x220 + 0x4d, 1, 0x280)
    struct.pack_into("<10fIh", tcl, 0x280, *([0.5] * 10), 2, 904)
    tcl[0x280 + 0x2e:0x280 + 0x2e + 20] = b"Fairway-label-20byte"
    tcl[0x280 + 0x42] = 7
    struct.pack_into("<I", tcl, 0x220 + 0xa, 0x8c1)
    name = b"fairway.tga\0"
    dds = bytearray(128)
    dds[:4] = b"DDS "
    struct.pack_into("<6I", dds, 4, 124, 0x100f, 1, 1, 4, 0)
    struct.pack_into("<I", dds, 28, 1)
    struct.pack_into("<II4sIIIII", dds, 76, 32, 0x41, b"\0" * 4, 32,
                     0xff0000, 0xff00, 0xff, 0xff000000)
    struct.pack_into("<I", dds, 108, 0x1000)
    dds += bytes((3, 2, 1, 255))
    payload = struct.pack("<I", len(dds)) + dds
    struct.pack_into("<IIIIHB", tcl, 0x200, len(tcl), len(tcl), len(tcl), len(name), 0, 0)
    tcl += name
    struct.pack_into("<IIIIHB", tcl, 0x1e0, len(tcl), len(tcl), len(tcl), len(payload), 0, 0)
    tcl += payload
    return bytes(tcr), bytes(tcl)


class MaterialTests(unittest.TestCase):
    def test_guid_descriptor_chain_and_original_surface(self):
        tcr, tcl = fixtures()
        with tempfile.TemporaryDirectory() as directory:
            result = decode_materials(tcr, [tcl], Path(directory), {0})
            material = result["materials"][0]
            self.assertEqual(result["source_tcr_sha256"], hashlib.sha256(tcr).hexdigest())
            self.assertEqual(result["libraries"][0]["sha256"], hashlib.sha256(tcl).hexdigest())
            self.assertEqual(material["name"], "fairway.tga")
            surface = material["surface_types"][0]
            self.assertEqual(surface["name"], "Fairway-label-20byte", "Label stops at +0x42")
            self.assertEqual((surface["flags"], surface["sound_id"], surface["lie_graphic_index"]), (2, 904, 7))
            self.assertEqual(material["section_flags"], 0x8c1)
            self.assertEqual((material["width"], material["height"]), (1, 1))
            self.assertTrue((Path(directory) / material["texture"]).read_bytes().startswith(b"\x89PNG"))
            self.assertEqual((Path(directory) / material["original_dds"]).read_bytes()[-4:], bytes((3, 2, 1, 255)))

    def test_mismatching_library_identity_is_rejected(self):
        tcr, tcl = fixtures()
        tcl = bytearray(tcl)
        tcl[2] ^= 1
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "Missing TCL"):
                decode_materials(tcr, [bytes(tcl)], Path(directory))

    def test_texture_descriptor_cannot_escape_file(self):
        tcr, tcl = fixtures()
        tcl = bytearray(tcl)
        struct.pack_into("<I", tcl, 0x1e0, len(tcl) - 1)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "invalid range"):
                decode_materials(tcr, [bytes(tcl)], Path(directory))

    def test_bad_dds_length_prefix_is_rejected(self):
        tcr, tcl = fixtures()
        tcl = bytearray(tcl)
        source = struct.unpack_from("<I", tcl, 0x1e0)[0]
        struct.pack_into("<I", tcl, source, 1)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "length prefix"):
                decode_materials(tcr, [bytes(tcl)], Path(directory))


class HoleTests(unittest.TestCase):
    def hole_fixture(self):
        data = bytearray(0x324)
        struct.pack_into("<H", data, 0, 7)
        struct.pack_into("<I", data, 0x3e, len(data))
        root = 0x250
        struct.pack_into("<I", data, 0xe0, root)
        struct.pack_into("<I", data, root, 0xd0)
        struct.pack_into("<H", data, root + 0x10, 1)
        struct.pack_into("<I", data, root + 0x12, 0x20)
        struct.pack_into("<6H", data, root + 0x20, 4, 309, 8, 1, 1, 1)
        struct.pack_into("<3I", data, root + 0x30, 0x40, 0x4c, 0x58)
        for offset in (0x40, 0x4c, 0x58):
            struct.pack_into("<3f", data, root + offset, 125.5, 81.25, -4.0)
        return data

    def test_native_positions_are_copied_without_transform(self):
        result = decode_holes(bytes(self.hole_fixture()))
        hole = result["holes"][0]
        self.assertEqual((hole["par"], hole["handicap"], hole["legacy_yardage"]), (4, 8, 309))
        self.assertEqual(hole["pins"][0]["xyz_raw"], [125.5, 81.25, -4.0])

    def test_hole_pointer_cannot_escape_information_block(self):
        data = self.hole_fixture()
        struct.pack_into("<I", data, 0x250 + 0x30, 0xd0)
        with self.assertRaisesRegex(ValueError, "escapes"):
            decode_holes(bytes(data))


if __name__ == "__main__":
    unittest.main()
