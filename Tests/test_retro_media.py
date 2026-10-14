import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("retro_media", Path(__file__).parents[1] / "Tools/prepare_retro_media.py")
retro = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retro)


class RetroMediaTests(unittest.TestCase):
    def test_dos_sparse_file_and_binary_length(self):
        disk = bytearray(143360)
        vtoc = 17 * 4096
        disk[vtoc + 1:vtoc + 4] = bytes([17, 15, 3])
        disk[vtoc + 0x34:vtoc + 0x38] = bytes([35, 16, 0, 1])
        entry = vtoc + 15 * 256 + 11
        disk[entry:entry + 3] = bytes([18, 0, 4])
        disk[entry + 3:entry + 33] = bytes(c | 128 for c in b"TEST".ljust(30))
        ts = 18 * 4096
        disk[ts + 12:ts + 14] = bytes([18, 1])
        disk[ts + 16:ts + 18] = bytes([18, 2])  # sparse sector 1
        data = ts + 256
        disk[data:data + 4] = struct.pack("<HH", 0x4000, 513)
        disk[data + 4:data + 256] = b"a" * 252
        disk[ts + 512:ts + 517] = b"last!"
        file = retro.dos33_files(bytes(disk))[0]
        self.assertEqual(file["loadAddress"], 0x4000)
        self.assertEqual(file["data"], b"a" * 252 + bytes(256) + b"last!")
        disk[ts + 1:ts + 3] = bytes([18, 0])
        with self.assertRaisesRegex(retro.MediaError, "Cyclic"):
            retro.dos33_files(bytes(disk))

    def test_basic_quotes_rem_data_and_pointer_validation(self):
        text = bytes([0xBA]) + b'"\xba":' + bytes([0x83]) + b'\xba:' + bytes([0xB2]) + b'\xba'
        line = struct.pack("<HH", 0x801 + 5 + len(text), 10) + text + b"\0\0\0"
        listing = retro.applesoft_listing(line)
        self.assertIn('PRINT', listing)
        self.assertEqual(listing.count('PRINT'), 1)
        self.assertIn('DATA', listing)
        self.assertIn('REM', listing)
        self.assertEqual(len(retro.TOKENS), 107)
        bad = line[:-2] + struct.pack("<HH", 0x9000, 20) + bytes([0x80, 0, 0, 0])
        with self.assertRaisesRegex(retro.MediaError, "pointers"):
            retro.applesoft_listing(bad)

    def test_t64_ranges_and_load_address(self):
        header = bytearray(96)
        header[:19] = b"C64 tape image file"
        struct.pack_into("<HHH", header, 32, 0x101, 1, 1)
        header[64:66] = bytes([1, 0x82])
        struct.pack_into("<HHI", header, 66, 0x801, 0x804, 0)
        struct.pack_into("<I", header, 72, 96)
        data = bytes(header) + b"abc"
        file = retro.t64_files(data)[0]
        self.assertEqual(file["loadAddress"], 0x801)
        self.assertEqual(file["data"], b"abc")
        with self.assertRaisesRegex(retro.MediaError, "range"):
            retro.t64_files(data[:-1])

    def test_xex_preserves_ordered_overlays_and_rejects_truncation(self):
        data = b"\xff\xff" + struct.pack("<HH", 0x2000, 0x2001) + b"ab"
        data += struct.pack("<HH", 0x2001, 0x2001) + b"c"
        segments = retro.xex_segments(data)
        self.assertEqual([f["data"] for f in segments], [b"ab", b"c"])
        self.assertEqual(segments[1]["loadAddress"], 0x2001)
        with self.assertRaises(retro.MediaError):
            retro.xex_segments(data[:-1])
        with self.assertRaises(retro.MediaError):
            retro.xex_segments(data + b"\xff\xff")

    def test_local_selected_references_match_index(self):
        import json
        index = json.loads((retro.ROOT / "docs/research/evidence/retro-inventory.json").read_text())
        for game, name in retro.SELECTIONS.items():
            record = next(a for a in index["archives"] if a["id"] == game)
            archive = retro.ROOT / record["archive"]
            if not archive.exists():
                continue  # clean clones intentionally omit proprietary media
            payload, identity = retro.selected_payload(archive, record, name)
            self.assertEqual(retro.sha256(payload), identity["sha256"])
            if name.endswith('.do'):
                for file in retro.dos33_files(payload):
                    if file["type"] == 2:
                        self.assertTrue(retro.applesoft_listing(file["data"]).endswith('\n'))


if __name__ == "__main__":
    unittest.main()
