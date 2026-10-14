"""Tests for Tools/decode_pga2005_render.py.

Synthetic INI text covers the engine reader semantics, the blend rules and the
vertex-colour and flare formulas. Real-media checks run only when the ignored
Library/SourceMedia tree holds the installed render presets.
"""
from pathlib import Path
import json
import math
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import decode_pga2005_render as render  # noqa: E402

MEDIA = ROOT / "Library/SourceMedia/pga2005"

SAMPLE = """#comment line
[GlobalLightingValues]
; comment
Diffuse=.7,.7,.9
SkydomeDiffuse=.8,.8,.9,.5
[TerrainContrast]
MidValue=1.0
Shift=1.0
Scale=.5
[TreeContrast]
MidValue=1.
Shift=0
Scale=1.0
[TreeAmbient]
value=3
[Fog]
Enabled=1;
Start=3000  ;works only if particle fog is off
End=125000
Color=.43,.43,.5
HPanStart=2000
HPanColor=.5,.5,.5
gFogNumParticles=250
[LensFlare]
Enabled=1
Position=40000,12000,50000
FlareOpacity = 0.10
SunOpacity = 1
FlareCount=2
Flare1Size = 2
Flare1Position = -.8
Flare1Texture = 3
Flare2Size = 1
Flare2Position = .5
SunTexture=1
SunSize = 2.0
CoronaCount=1
Corona1Size=1.5
Corona1Texture=2
[RainParameters]
on=1
m_density=0.35
m_color=0.75,0.75,0.75,0.0
dropVelocity=170
[SkydomeAnimationControls]
deltaU=0
deltaV=0.04
[SKY]
SKYTYPE=3
"""


class ReaderSemanticsTests(unittest.TestCase):
    def test_c_number_prefix_parsing(self):
        self.assertEqual(render.c_atof("3000  ;works"), 3000.0)
        self.assertEqual(render.c_atof(".11."), 0.11)
        self.assertEqual(render.c_atof("junk"), 0.0)
        self.assertEqual(render.c_atoi("1;"), 1)

    def test_three_component_colour_gets_unit_alpha(self):
        s = render.decode_preset(SAMPLE)
        self.assertEqual(s["global_lighting"]["diffuse"], [0.7, 0.7, 0.9, 1.0])
        self.assertEqual(s["global_lighting"]["skydome_diffuse"], [0.8, 0.8, 0.9, 0.5])

    def test_zero_float_keeps_previous_value(self):
        s = render.decode_preset(SAMPLE)
        self.assertEqual(s["tree_contrast"]["shift"], 0.85)  # Shift=0 ignored, Init default kept
        self.assertEqual(s["skydome_animation"]["delta_u"], 0.0)
        self.assertEqual(s["skydome_animation"]["delta_v"], 0.04)

    def test_contrast_flag_follows_scale_only(self):
        s = render.decode_preset(SAMPLE)
        self.assertTrue(s["terrain_contrast"]["enabled"])
        self.assertFalse(s["tree_contrast"]["enabled"])

    def test_pan_fog_falls_back_to_normal_fog(self):
        fog = render.decode_preset(SAMPLE)["fog"]
        self.assertEqual((fog["pan_start"], fog["pan_end"]), (3000.0, 125000.0))
        self.assertEqual(fog["pan_color"], [0.43, 0.43, 0.5, 1.0])
        self.assertEqual((fog["hpan_start"], fog["hpan_end"]), (2000.0, 125000.0))
        self.assertEqual(fog["hpan_color"], [0.5, 0.5, 0.5, 1.0])
        self.assertEqual(fog["particles"]["effective_count"], 40)

    def test_lens_flare_texture_indices_and_layout(self):
        lf = render.decode_preset(SAMPLE)["lens_flare"]
        self.assertEqual(lf["position"], [40000.0, 12000.0, 50000.0])
        self.assertEqual([f["texture"] for f in lf["flares"]], [2, 1])  # missing key reuses the running index
        self.assertEqual(lf["sun_texture"], 0)
        self.assertEqual(lf["coronas"], [{"size": 1.5, "texture": 1}])
        settings = render.decode_preset(SAMPLE)
        quads = render.flare_layout((100.0, 50.0), (800, 600), settings, {2: (64, 64), 1: (32, 32)})
        self.assertEqual(quads["sun"], (84, 34, 116, 66))  # +/- 8 * SunSize pixels
        # Position -0.8: 80% of the way from the screen centre back toward the sun.
        cx = 400 + (400 - 100) * -0.8
        self.assertEqual(quads["flares"][0], (int(cx - 64), int(300 + 250 * -0.8 - 64),
                                              int(cx + 64), int(300 + 250 * -0.8 + 64)))

    def test_rain_values(self):
        rain = render.decode_preset(SAMPLE)["rain"]
        self.assertEqual(rain["on"], 1)
        self.assertEqual(rain["target_drops"], 3500)
        self.assertIsNone(rain["drop_length"])
        self.assertEqual(render.rain_drop_count(3500, 4, 0), 2450)  # 3500 * (0.2 + 0 + 0.5)
        self.assertEqual(render.rain_drop_count(9500, 0, 0), 1000)


class FormulaTests(unittest.TestCase):
    def setUp(self):
        self.s = render.decode_preset(SAMPLE)

    def test_terrain_contrast_and_diffuse(self):
        # ((c/255 - 1) * 0.5 + 1) clamped, times Diffuse, times 255, truncated.
        r, g, b = render.terrain_color((0, 128, 255), self.s)
        self.assertEqual(r, int(0.5 * 0.7 * 255))
        self.assertEqual(g, int(((128 * 0.003921569 - 1) * 0.5 + 1) * 0.7 * 255))
        self.assertEqual(b, int(1.0 * 0.9 * 255))
        self.assertEqual(render.terrain_color((0, 128, 255), self.s, contrast_enabled=False),
                         (0, int(128 * 0.003921569 * 0.7 * 255), int(255 * 0.003921569 * 0.9 * 255)))

    def test_tree_grey_wraps_before_clamp(self):
        settings = render.decode_preset(SAMPLE)  # TreeAmbient 3, tree contrast off
        self.assertEqual(render.tree_grey(60, settings)[0], int(126 * 0.003921569 * 0.7 * 255))
        self.assertEqual(render.tree_grey(130, settings)[0], int(((133 * 2) & 0xFF) * 0.003921569 * 0.7 * 255))

    def test_blend_rules(self):
        upper_text = SAMPLE.replace("Start=3000", "Start=5000").replace("SKYTYPE=3", "SKYTYPE=4") \
            .replace("value=3", "value=8").replace("on=1", "on=0").replace("Flare1Position = -.8", "Flare1Position = .2") \
            .replace("FlareCount=2", "FlareCount=1").replace("Scale=.5", "Scale=1")
        lower, upper = render.decode_preset(SAMPLE), render.decode_preset(upper_text)
        out = render.blend(lower, upper, 0.25)
        self.assertEqual(out["fog"]["start"], 3500.0)
        self.assertEqual(out["sky_type"], 3)  # lower preset decides the sky
        self.assertEqual(out["tree_ambient"], 4)  # trunc(3 + 5 * 0.25)
        self.assertEqual(out["rain"]["on"], 1)
        self.assertEqual(out["skydome_animation"]["delta_v"], 0.0)  # Lerp zeroes the scroll
        self.assertAlmostEqual(out["terrain_contrast"]["scale"], 0.625)
        self.assertTrue(out["terrain_contrast"]["enabled"])  # flag is not interpolated
        self.assertAlmostEqual(out["lens_flare"]["flares"][0]["position"], -0.55)
        self.assertTrue(out["lens_flare"]["flares"][1]["upper_slot_unset"])


@unittest.skipUnless(any((MEDIA / d / "render40.ini").is_file() for d in render.SEARCH_DIRS),
                     "original render presets not extracted")
class RealPresetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = render.decode_all(render.find_executable_dir(MEDIA))
        cls.presets = [p["settings"] for p in cls.doc["presets"]]

    def test_row_structure(self):
        self.assertEqual(len(self.presets), 40)
        self.assertEqual([p["sky_type"] for p in self.presets[::5]], [1, 2, 3, 4, 5, 5, 5, 6])
        self.assertEqual([p["lens_flare"]["enabled"] for p in self.presets[::5]], [1, 1, 1, 1, 0, 0, 0, 0])
        self.assertEqual([p["rain"]["on"] for p in self.presets[::5]], [0, 0, 0, 0, 0, 0, 1, 1])
        for row in range(8):
            self.assertEqual(len({p["sky_type"] for p in self.presets[row * 5:row * 5 + 5]}), 1)

    def test_known_values(self):
        clear_noon = self.presets[2]
        self.assertEqual((clear_noon["fog"]["start"], clear_noon["fog"]["end"]), (5000.0, 150000.0))
        self.assertEqual(clear_noon["global_lighting"]["diffuse"], [1.0, 1.0, 1.0, 1.0])
        self.assertEqual(clear_noon["lens_flare"]["position"], [75000.0, 40000.0, 160000.0])
        self.assertFalse(clear_noon["terrain_contrast"]["enabled"])
        self.assertEqual(self.presets[0]["global_lighting"]["diffuse"], [0.7, 0.7, 0.9, 1.0])
        self.assertTrue(self.presets[0]["terrain_contrast"]["enabled"])

    def test_particle_fog_planes_match_linear_fog(self):
        for p in self.presets:
            part = p["fog"]["particles"]
            if part["effective_count"] and part["use_distance_fog"]:
                self.assertEqual((part["near_fog_plane"], part["far_fog_plane"]), (p["fog"]["start"], p["fog"]["end"]))

    def test_json_is_numbers_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "presets.json"
            render.write_json(self.doc, path)
            text = path.read_text()
            data = json.loads(text)
        self.assertEqual(len(data["presets"]), 40)
        self.assertNotIn(".dds", text)
        self.assertNotIn("NaN", text)
        for preset in data["presets"]:
            self.assertEqual(len(preset["source_sha256"]), 64)
            self.assertTrue(all(isinstance(v, (int, float)) for v in preset["settings"]["fog"]["color"]))
        self.assertTrue(math.isclose(data["default_sun_position"][2], 156948.265625))


if __name__ == "__main__":
    unittest.main()
