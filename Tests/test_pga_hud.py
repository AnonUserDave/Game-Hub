from pathlib import Path
import json
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from import_pga2005_hud import HUD_IMAGES, convert


def tiny_dds():
    """One-pixel uncompressed A8R8G8B8 DDS."""
    dds = bytearray(128)
    dds[:4] = b"DDS "
    struct.pack_into("<6I", dds, 4, 124, 0x100f, 1, 1, 4, 0)
    struct.pack_into("<I", dds, 28, 1)
    struct.pack_into("<II4sIIIII", dds, 76, 32, 0x41, b"\0" * 4, 32, 0xff0000, 0xff00, 0xff, 0xff000000)
    struct.pack_into("<I", dds, 108, 0x1000)
    return bytes(dds) + bytes((3, 2, 1, 255))


class HUDImportTests(unittest.TestCase):
    def test_converts_present_images_and_reports_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory) / "Game"
            (game / "SwingMeter").mkdir(parents=True)
            (game / "SwingMeter/swingon.dds").write_bytes(tiny_dds())
            output = Path(directory) / "hud"
            manifest = convert(game, output)
            self.assertEqual([entry["name"] for entry in manifest["images"]], ["swing-on"])
            self.assertTrue((output / "swing-on.png").read_bytes().startswith(b"\x89PNG"))
            self.assertEqual(len(manifest["missing"]), len(HUD_IMAGES) - 1)
            self.assertEqual(json.loads((output / "hud.json").read_text())["schema_version"], 1)

    def test_every_club_has_plain_and_highlighted_art(self):
        clubs = [name for name in HUD_IMAGES if name.startswith("club-") and not name.endswith("-on")]
        self.assertTrue(all(f"{name}-on" in HUD_IMAGES for name in clubs))


if __name__ == "__main__":
    unittest.main()
