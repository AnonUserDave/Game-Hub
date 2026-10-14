import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("breakout2600", ROOT / "Tools/prepare_breakout2600.py")
breakout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(breakout)


class Breakout2600PreparationTests(unittest.TestCase):
    def selected(self):
        archive = ROOT / "Breakout_Atari-2600_ROM_EN.zip"
        if not archive.is_file():
            self.skipTest("Original media intentionally omitted from clean clones")
        return breakout.inspect_archive(archive)

    def test_archive_identity_is_checked_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "wrong.zip"
            archive.write_bytes(b"wrong source")
            with self.assertRaisesRegex(ValueError, "identity"):
                breakout.inspect_archive(archive)

    def test_selected_tables_and_effective_companion_font_order(self):
        rom, metadata = self.selected()
        self.assertEqual(metadata["tables"]["colorCodes"]["bytes"][4:10], [0x86, 0xc6, 0x16, 0x26, 0x36, 0x46])
        self.assertEqual(metadata["tables"]["rowAudioFrequency"]["bytes"], [10, 12, 16, 18, 22, 28])
        hud = breakout.decode_hud(rom)
        self.assertEqual(hud["digitRows"][2], [7, 1, 7, 4, 7])
        self.assertEqual(hud["digitRows"][5], [7, 4, 7, 1, 7])
        self.assertEqual(hud["sourceSHA256"], breakout.ROM_SHA256)

    def test_companion_table_disagreement_is_rejected(self):
        data = bytearray(2048)
        data[0x100] = 1
        with self.assertRaisesRegex(ValueError, "Companion"):
            breakout.decode_hud(data)

    def test_all_selected_bytes_and_direct_edges_have_static_classification(self):
        rom, _ = self.selected()
        listing = ROOT / "Library/Research/breakout2600/disassembly.txt"
        if not listing.is_file():
            self.skipTest("Optional local Ghidra listing has not been prepared")
        record = breakout.verify_static_coverage(rom, listing)
        self.assertEqual(record["instructionCount"], 946)
        self.assertEqual(record["instructionByteCount"], 1810)
        self.assertEqual(record["classifiedDataAndPaddingBytes"], 238)
        self.assertEqual(record["unclassifiedBytes"], 0)
        self.assertEqual(record["uncoveredDirectTransferTargets"], [])
        writes = [entry["address"] for entry in record["wallTransitionReferences"] if entry["instruction"].startswith("STA")]
        self.assertEqual(writes, ["0xf192", "0xf1a3", "0xf4a2", "0xf749"])

    def test_static_listing_cannot_omit_or_change_the_rebuild_path(self):
        rom, _ = self.selected()
        listing = ROOT / "Library/Research/breakout2600/disassembly.txt"
        if not listing.is_file():
            self.skipTest("Optional local Ghidra listing has not been prepared")
        source = listing.read_text()
        with tempfile.TemporaryDirectory() as directory:
            test = Path(directory) / "listing.txt"
            test.write_text("\n".join(line for line in source.splitlines() if not line.startswith("f4a2 ")))
            with self.assertRaisesRegex(ValueError, "unclassified"):
                breakout.verify_static_coverage(rom, test)
            test.write_text(source.replace("f4a2 85 de", "f4a2 85 df"))
            with self.assertRaisesRegex(ValueError, "byte identity"):
                breakout.verify_static_coverage(rom, test)


if __name__ == "__main__":
    unittest.main()
