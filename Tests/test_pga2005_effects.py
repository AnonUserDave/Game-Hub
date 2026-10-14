import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))

import import_pga2005_effects  # noqa: E402

INSTALL = ROOT / "Library/SourceMedia/pga2005/install"


class EffectsImportTests(unittest.TestCase):
    @unittest.skipUnless((INSTALL / "CoursesRoot/sand01.dds").is_file(), "original install not extracted")
    def test_converts_original_effect_art(self):
        with tempfile.TemporaryDirectory() as out:
            manifest = import_pga2005_effects.convert(INSTALL, Path(out))
            self.assertEqual(manifest["missing"], [])
            self.assertEqual(set(manifest["sprites"]), {"sand", "grass", "splash", "divot-mark", "divot"})
            self.assertEqual(set(manifest["meshes"]), {"tee", "divot1", "divot2", "divot3"})
            tee = manifest["meshes"]["tee"]
            heights = tee["positions"][1::3]
            # 57 source units with a 13-unit head: a 2-1/8 in tee in millimetres.
            self.assertAlmostEqual((max(heights) - min(heights)) * tee["meters_per_unit"], 0.057, places=3)
            self.assertEqual(len(tee["indices"]) % 3, 0)
            saved = json.loads((Path(out) / "effects.json").read_text())
            self.assertEqual(saved["schema_version"], 1)
            for name in manifest["sprites"]:
                self.assertTrue((Path(out) / f"{name}.png").is_file())


if __name__ == "__main__":
    unittest.main()
