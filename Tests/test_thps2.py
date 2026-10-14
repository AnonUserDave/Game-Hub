import hashlib
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from decode_thps2 import psx_v4, trg_v2, texture_rgba, blockmap, command_list


def fixture():
    """First-party triangle, compact RGBs table and odd-height 4bpp image."""
    data = bytearray(struct.pack('<HHII', 4, 2, 0, 1))
    data += struct.pack('<IiiiIHHhhII', 0x42, 16777216, -8388608, 0, 0, 0, 0, 0, 0, 0, 0)
    data += struct.pack('<II', 1, 56)
    data += struct.pack('<4HI6hI', 8, 3, 1, 1, 16777216, 4096, 0, 4096, 0, 0, 0, 0xffff7fff)
    data += struct.pack('<12h', 0, 0, 0, 0, 4096, 0, 0, 0, 0, 4096, 0, 0)
    data += struct.pack('<4h', 0, 0, -4096, 0)
    data += struct.pack('<HH8BHHI8B', 0x1813, 28, 0, 1, 2, 0, 0, 1, 2, 0, 0, 0x10, 0, 0, 0, 3, 0, 0, 2, 0, 0)
    tags = len(data)
    struct.pack_into('<I', data, 4, tags)
    data += struct.pack('<II', 0x73424752, 12) + bytes([128, 128, 128, 0, 255, 0, 0, 0, 0, 255, 0, 0])
    data += struct.pack('<II', 0xffffffff, 0x12345678)
    data += struct.pack('<II', 1, 0xa5cf46b6)
    data += struct.pack('<II16H', 1, 0xa5cf46b6, 0, 0x001f, 0x03e0, *([0x8000] * 13))
    data += struct.pack('<I', 0)
    data += struct.pack('<II', 1, len(data) + 8)
    data += struct.pack('<4IHH', 0, 16, 0xa5cf46b6, 0, 3, 3)
    data += bytes([0x10, 0x32] * 3)
    return data


def triggers():
    # restart array needs absolute four-byte alignment after its link count.
    payload = bytearray(struct.pack('<HH3i3H', 8, 0, 4096, -4096, 8192, 0, 512, 0))
    payload += b'Start\0' + struct.pack('<H', 0xffff)
    first = 20
    return struct.pack('<4s4I', b'_TRG', 2, 2, first, first + len(payload)) + payload + struct.pack('<H', 255)


class THPS2DecoderTests(unittest.TestCase):
    def test_preserves_fixed_units_flags_uv_colors_and_short_palette(self):
        result = psx_v4(fixture())
        self.assertEqual(result.objects[0][1:4], (16777216, -8388608, 0))
        face = result.models[0].faces[0]
        self.assertEqual((face.flags, face.surface, face.indices, face.uv), (0x1813, 0x10, (0, 1, 2, 0), ((0, 0), (3, 0), (0, 2), (0, 0))))
        self.assertEqual(result.gouraud[:4], bytes([128, 128, 128, 0]))
        self.assertEqual(result.textures[0].storage_height, 3)
        self.assertEqual(result.textures[0].storage_width, 4)
        rgba = texture_rgba(result, result.textures[0])
        self.assertEqual(len(rgba), 36)
        self.assertEqual(rgba[:12], bytes([0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255]))
        self.assertEqual(rgba[12:24], rgba[:12])

    def test_rejects_truncation_bad_spans_indices_and_allocation_counts(self):
        raw = fixture()
        for end in (0, 7, 51, 80, len(raw) - 1):
            with self.assertRaises(ValueError):
                psx_v4(raw[:end])
        for offset, fmt, value in ((8, '<I', 100001), (52, '<I', 12), (118, '<H', 12), (120, '<B', 9), (132, '<I', 99)):
            bad = bytearray(raw)
            struct.pack_into(fmt, bad, offset, value)
            with self.assertRaises(ValueError):
                psx_v4(bad)

    def test_trg_restart_raw_commands_and_invalid_link_extent(self):
        data = triggers()
        result = trg_v2(data)
        self.assertEqual(result['nodes'][0]['name'], 'Start')
        self.assertEqual(result['nodes'][0]['position_fixed12'], (4096, -4096, 8192))
        self.assertEqual(result['nodes'][0]['undecoded_size'], 2)
        self.assertEqual(result['nodes'][1]['type'], 255)
        for offset, value in ((8, 100001), (12, 0), (16, 20)):
            bad = bytearray(data); struct.pack_into('<I', bad, offset, value)
            with self.assertRaises(ValueError):
                trg_v2(bad)

    def test_blockmap_membership_and_command_framing(self):
        data = struct.pack('<4i2H', -4096, -4096, 4096, 4096, 2, 2)
        for cell in ((0,), (), (1,), (0, 1)):
            data += struct.pack('<3I', 0, 0, len(cell)) + struct.pack('<' + 'I' * len(cell), *cell) + struct.pack('<I', 0)
        grid = blockmap(data, 0, len(data), 2)
        self.assertEqual(grid.cells, ((0,), (), (1,), (0, 1)))
        bad = bytearray(data); struct.pack_into('<I', bad, 32, 2)
        with self.assertRaises(ValueError):
            blockmap(bad, 0, len(bad), 2)
        raw = struct.pack('<H', 126) + b'SkHan_L\0' + struct.pack('<HH', 0xeeee, 147)
        commands = command_list(raw, 0, len(raw))
        self.assertEqual(commands[0]['string'], 'SkHan_L')
        self.assertEqual(commands[1]['opcode'], 0xeeee)
        self.assertEqual(len(commands), 2, 'Unknown command stops; its argument must not be treated as opcode')

    def test_real_selected_hangar_structure_and_source_identity(self):
        root = Path(__file__).resolve().parents[1] / 'Library/Imported/thps2/original/data'
        if not (root / 'SKHAN.PSX').is_file():
            self.skipTest('Ignored original THPS2 media not present')
        raw = (root / 'SKHAN.PSX').read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), '56cc7f02ac45e0772621e6d9866fda4562e8a71669a0dee826bd93512fe9e6f8')
        source = psx_v4(raw)
        self.assertEqual((len(source.objects), len(source.models), source.summary()['vertices'], source.summary()['faces']), (470, 471, 5368, 3231))
        library = psx_v4((root / 'SKHAN_L.PSX').read_bytes())
        self.assertEqual(set(source.texture_names), set(library.texture_names))
        self.assertEqual((len(library.palette4), len(library.palette8), len(library.textures)), (64, 39, 105))
        objects = psx_v4((root / 'SKHAN_O.PSX').read_bytes())
        self.assertEqual((len(objects.objects), objects.summary()['faces']), (20, 640))
        nodes = trg_v2((root / 'SKHAN_T.TRG').read_bytes())
        self.assertEqual((len(nodes['nodes']), nodes['node_types']['8'], nodes['node_types']['10']), (713, 14, 181))
        self.assertEqual(nodes['nodes'][0]['name'], 'Start')
        autoexec = next(n for n in nodes["nodes"] if n["type"] == 4)
        self.assertEqual([c["string"] for c in autoexec["commands"] if c["kind"] == "spool-in"], ["SkHan_l", "SkHan_O"])

    def test_real_trg_corpus_is_structurally_valid(self):
        root = Path(__file__).resolve().parents[1] / 'Library/Imported/thps2/original/data'
        paths = sorted(root.glob('*.TRG'))
        if not paths:
            self.skipTest('Ignored original THPS2 media not present')
        self.assertEqual(len(paths), 32)
        self.assertEqual(sum(len(trg_v2(p.read_bytes())['nodes']) for p in paths), 20220)


if __name__ == '__main__':
    unittest.main()
