"""Tests for Tools/decode_pga2005_cameras.py.

Synthetic fixtures cover the .stn layout, condition semantics, situation
selection and the tri-click meter model. Real-media checks run only when the
ignored Library/SourceMedia tree is present.
"""
from pathlib import Path
import json
import random
import re
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import decode_pga2005_cameras as cam  # noqa: E402

MEDIA = ROOT / "Library/SourceMedia/pga2005"
EXECUTABLE = MEDIA / "engine/Executable"


def situation(stype=11, event=1, conditions=(), actions=(0,), flags=1, priority=100):
    """conditions: sequence of (bit, op, value) in ascending bit order."""
    record = bytearray(cam.SITUATION_SIZE)
    record[0], record[1] = stype, event
    mask = 0
    ops = [0xFFF0] * 10
    values = [0xFFF0] * 10
    for i, (bit, op, value) in enumerate(conditions):
        mask |= 1 << bit
        ops[i], values[i] = op, value
    struct.pack_into("<I", record, 2, mask)
    struct.pack_into("<10H", record, 6, *ops)
    struct.pack_into("<10I", record, 26, *values)
    slots = list(actions) + [cam.EMPTY_SLOT] * (10 - len(actions))
    struct.pack_into("<10h", record, 66, *slots)
    struct.pack_into("<I", record, 86, flags)
    record[90] = priority
    return bytes(record)


def action(atype=10, probability=100, flags=1, responses=(0,)):
    record = bytearray(cam.ACTION_SIZE)
    record[0], record[1] = atype, probability
    struct.pack_into("<I", record, 2, flags)
    slots = list(responses) + [cam.EMPTY_SLOT] * (30 - len(responses))
    struct.pack_into("<30h", record, 6, *slots)
    return bytes(record)


def camera_response(command=0, offset_ft=(0, 1, -15), path=0, start=1, flags=0, obj=5, tenths=0,
                    amount=0, extra=0, kind=0):
    record = bytearray(b"\xcd" * cam.RESPONSE_SIZE)
    record[0] = 13
    struct.pack_into("<I", record, 1, 0)
    record[5] = kind
    struct.pack_into("<i", record, 6, command)
    struct.pack_into("<3f", record, 10, *(v * 12.0 for v in offset_ft))
    struct.pack_into("<4i", record, 22, path, start, flags, obj)
    record[38] = tenths
    struct.pack_into("<i", record, 39, amount)
    record[43] = extra
    return bytes(record)


def build_stn(situations, actions, responses, names):
    header_size = cam.HEADER_SIZE
    o_sit = header_size
    o_act = o_sit + len(situations) * cam.SITUATION_SIZE
    o_res = o_act + len(actions) * cam.ACTION_SIZE
    header = struct.pack("<7I", 0x10005, len(situations), o_sit, len(actions), o_act, len(responses), o_res)
    body = b"".join(situations) + b"".join(actions) + b"".join(responses)
    strings = b"".join(n.encode("latin-1") + b"\0" for n in names)
    return header + body + strings + b"\0" * 32


def sample_script():
    situations = [
        situation(event=1, conditions=[(3, 4, 120), (12, 1, 5), (21, 5, 0x4)], actions=(0, 0, 1), priority=100),
        situation(event=1, conditions=[(12, 1, 5)], actions=(1,), priority=100),
        situation(event=1, conditions=[], actions=(1,), priority=200),
        situation(event=19, conditions=[(2, 0xFFFF, 0)], actions=(0,)),
    ]
    actions = [action(responses=(0, 1, 2)), action(responses=(3,), probability=65)]
    responses = [
        camera_response(command=0, offset_ft=(0, 1, -15), obj=5, tenths=30, flags=6),
        camera_response(command=1, offset_ft=(0, -1, 0), obj=5, start=2, tenths=30),
        camera_response(command=6, offset_ft=(0, 0, 0), path=-1, start=2, obj=-1, amount=70),
        camera_response(command=11, offset_ft=(0, 0, 0), path=-1, start=1, obj=-1, tenths=7),
    ]
    names = ["Near pin", "Generic flight", "Catch all", "Disabled", "Chase", "Hold",
             "Attach Ball (0,1,-15) (3 seconds)", "Target Ball (0,-1,0)", "Zoom 70%", "Pause (0.7 seconds)"]
    return build_stn(situations, actions, responses, names)


class ContainerTests(unittest.TestCase):
    def test_parses_header_records_and_names(self):
        raw = cam.parse_stn(sample_script())
        self.assertEqual(raw["version"], 0x10005)
        self.assertEqual(len(raw["situations"]), 4)
        self.assertEqual(raw["response_names"][-1], "Pause (0.7 seconds)")
        self.assertEqual(raw["record_sizes"], {"situation": 91, "action": 87, "response": 63})

    def test_rejects_truncated_and_inconsistent_files(self):
        data = sample_script()
        with self.assertRaises(cam.StnFormatError):
            cam.parse_stn(data[:10])
        with self.assertRaises(cam.StnFormatError):
            cam.parse_stn(data[:cam.HEADER_SIZE + 50])
        broken = bytearray(data)
        struct.pack_into("<I", broken, 4, 100000)  # huge situation count
        with self.assertRaises(cam.StnFormatError):
            cam.parse_stn(bytes(broken))
        no_strings = data[:data.index(b"Near pin")] + b"Near pin"
        with self.assertRaises(cam.StnFormatError):
            cam.parse_stn(no_strings)

    def test_rejects_dangling_action_reference(self):
        data = build_stn([situation(actions=(3,))], [action(responses=(0,))], [camera_response()],
                         ["s", "a", "r"])
        with self.assertRaises(cam.StnFormatError):
            cam.decode_script(data, "x.stn")


class DecodeTests(unittest.TestCase):
    def setUp(self):
        self.script = cam.decode_script(sample_script(), "b_camera.stn")

    def test_situation_fields(self):
        s = self.script["situations"][0]
        self.assertEqual(s["event_name"], "ball_in_flight")
        self.assertEqual([c["bit"] for c in s["conditions"]], [3, 12, 21])
        self.assertEqual([c["operator"] for c in s["conditions"]], ["lt", "eq", "any"])
        self.assertIn("10 ft", s["conditions"][0]["display"])
        self.assertEqual(s["conditions"][2]["display"], "ball_lie has green")
        self.assertEqual(s["actions"], [0, 0, 1])
        self.assertTrue(s["single_random_action"])
        self.assertEqual(s["rule"]["then"][0]["weight"], 2)
        self.assertTrue(self.script["situations"][3]["never_matches"])
        self.assertEqual(self.script["never_matching_situations"], [3])

    def test_action_flag_conversion_and_probability(self):
        a = self.script["actions"][0]
        self.assertTrue(a["all_responses_in_order"])
        self.assertEqual(a["effective_flags"], 0x4000)
        self.assertEqual(self.script["actions"][1]["probability_percent"], 65)

    def test_camera_response_fields(self):
        attach, target, zoom, pause = self.script["responses"]
        self.assertEqual(attach["command_name"], "attach")
        self.assertEqual(attach["object_name"], "ball")
        self.assertEqual(attach["offset_ft"], [0.0, 1.0, -15.0])
        self.assertEqual(attach["duration_s"], 3.0)
        self.assertEqual(attach["flag_names"], ["reset_view", "clear_queue", "kill_current"])
        self.assertEqual(attach["followed_by"]["command_name"], "attachment_offset")
        self.assertEqual(target["start_mode_name"], "with_previous")
        self.assertNotIn("reset_view", target["flag_names"])
        self.assertAlmostEqual(zoom["zoom_factor"], 0.7)
        self.assertAlmostEqual(zoom["vertical_fov_deg"], 45 / 0.49, places=2)
        self.assertEqual(pause["command_name"], "pause")
        self.assertAlmostEqual(pause["duration_s"], 0.7)
        self.assertIn("hold 0.7s", pause["summary"])

    def test_registry_role(self):
        self.assertEqual(self.script["role"], "BallCamera")
        self.assertTrue(self.script["registry_key"].endswith("\\Script\\BallCamera"))


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.situations = cam.decode_script(sample_script(), "x.stn")["situations"]

    def test_operator_semantics_match_engine(self):
        self.assertTrue(cam.condition_true(3, 0xFFFFFFFF, 5))  # unsigned compare
        self.assertTrue(cam.condition_true(7, 0x8, 0x41C8))   # "not all" is true for a single bunker bit
        self.assertFalse(cam.condition_true(8, 0x8, 0x41C8))
        self.assertTrue(cam.condition_true(6, 0, 1))
        self.assertFalse(cam.condition_true(0xFFFF, 1, 1))

    def test_more_conditions_win_priority_ties(self):
        values = {3: 100, 12: 5, 21: 0x4}
        chosen = cam.choose_situation(self.situations, 1, values, random.Random(1))
        self.assertEqual(chosen["name"], "Near pin")

    def test_lower_priority_byte_wins_and_catch_all(self):
        self.assertEqual(cam.choose_situation(self.situations, 1, {12: 5, 3: 999})["name"], "Generic flight")
        self.assertEqual(cam.choose_situation(self.situations, 1, {12: 6})["name"], "Catch all")
        self.assertIsNone(cam.choose_situation(self.situations, 19, {2: 1}))


class MeterTests(unittest.TestCase):
    def meter_at(self, state, angle, **kwargs):
        meter = cam.TriClickMeter(**kwargs)
        meter.state, meter.angle = state, angle
        return meter

    def test_rates_by_difficulty_and_club(self):
        self.assertEqual([cam.tri_click_rate(level, 8) for level in range(4)], [200, 260, 325, 355])
        self.assertEqual([cam.tri_click_rate(level, cam.PUTTER) for level in range(4)], [170, 170, 200, 200])
        self.assertEqual(cam.tri_click_rate(1, 25), 230)
        self.assertEqual(cam.tri_click_rate(0, 25), 200)

    def test_power_snap_and_overswing(self):
        meter = self.meter_at(2, 91.5)
        meter.click()
        self.assertEqual(meter.power_angle, 90.0)
        self.assertEqual(meter.power, 1.0)
        self.assertEqual(meter.power_tick_color, "green")
        over = self.meter_at(2, 60.0)
        floor = over.floor
        over.click()
        self.assertAlmostEqual(over.power_angle, 84.0)
        self.assertAlmostEqual(over.power, (270 - 84) / 180)
        self.assertEqual(over.floor, int(floor * (1 - 30 / 150)))
        self.assertEqual(over.power_tick_color, "red")
        early = self.meter_at(2, 280.0)
        early.click()
        self.assertEqual(early.state, 2)  # power click ignored above 270

    def test_accuracy_snap_clamp_and_putter_sign(self):
        meter = self.meter_at(4, 268.5)
        meter.click()
        self.assertEqual(meter.direction_percent, 0.0)
        early = self.meter_at(4, 200.0)
        early.click()
        self.assertEqual(early.accuracy_angle, 229.0)
        self.assertAlmostEqual(early.direction_percent, -1.0)
        putter = self.meter_at(4, 290.5, club=cam.PUTTER)
        putter.click()
        self.assertAlmostEqual(putter.direction_percent, -(290.5 - 270) / 41)

    def test_full_simulation_and_misses(self):
        result = cam.simulate(1, [0])
        self.assertTrue(result["missed_power"])
        self.assertTrue(result["missed_direction"])
        self.assertTrue(0.555 <= result["power"] <= 0.662)
        self.assertEqual(result["direction"], 1.0)
        angles = [a for _, a, _ in result["trace"]]
        self.assertGreaterEqual(min(angles), cam.MIN_ANGLE)
        self.assertLessEqual(max(angles), cam.MAX_ANGLE)
        # Lift goes counter-clockwise from 270 before the backswing reverses.
        self.assertGreater(max(angles[:40]), 290)

    def test_clicked_swing_reaches_target_power(self):
        trace = cam.simulate(1, [], limit_ms=3000)["trace"]
        at_full = next(t for t, angle, state in trace if state == 2 and angle <= 90)
        result = cam.simulate(1, [at_full - 10, at_full + 700])
        self.assertFalse(result["missed_power"])
        self.assertAlmostEqual(result["power"], 1.0, delta=0.03)

    def test_two_click_has_no_direction(self):
        meter = self.meter_at(2, 120.0, two_click=True)
        meter.click()
        self.assertTrue(meter.finished)
        self.assertEqual(meter.direction_percent, 0.0)

    def test_lateral_offset_mapping(self):
        self.assertEqual(cam.click_lateral_offset(1, 1.0, 0.5), int(-150 * 0.25 + 0.5))
        self.assertEqual(cam.click_lateral_offset(3, 1.0, -1.0), 300)
        # ftol truncates toward zero after +0.5, so negative offsets round up: -399.5 -> -399.
        self.assertEqual(cam.click_lateral_offset(0, 1.0, 1.0, missed_direction=True), -399)
        boosted = cam.click_lateral_offset(1, 1.1, 0.5)
        self.assertEqual(boosted, int(-150 * 2 * 1.1 * 1.1 * 0.25 + 0.5))


class OutputTests(unittest.TestCase):
    def test_run_writes_documents_for_synthetic_media(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "media"
            (source / "engine/Executable").mkdir(parents=True)
            (source / "engine/Executable/b_camera.stn").write_bytes(sample_script())
            output = Path(directory) / "out"
            result = cam.run(source, output)
            cameras = json.loads((output / "cameras.json").read_text())
            swing = json.loads((output / "swing.json").read_text())
            self.assertEqual(cameras["schema_version"], 1)
            self.assertEqual([s["file"] for s in cameras["scripts"]], ["b_camera.stn"])
            self.assertIn("d_camera.stn", result["missing"])
            self.assertIsNone(swing["engine_verification"])
            self.assertEqual(len(swing["difficulty_levels"]), 4)


@unittest.skipUnless((EXECUTABLE / "d_camera.stn").is_file(), "original media not present")
class RealMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scripts = {name: cam.decode_script((EXECUTABLE / name).read_bytes(), name)
                       for name in cam.SCRIPT_FILES if (EXECUTABLE / name).is_file()}

    def test_counts_and_versions(self):
        expected = {"d_camera.stn": (153, 88, 181), "s_camera.stn": (7, 6, 13), "f_camera.stn": (4, 13, 19),
                    "b_camera.stn": (6, 7, 13), "Replay.stn": (13, 3, 1), "anim.stn": (6, 6, 6)}
        for name, counts in expected.items():
            script = self.scripts[name]
            self.assertEqual(script["version"], "0x10005")
            self.assertEqual((len(script["situations"]), len(script["actions"]), len(script["responses"])), counts)

    def test_decoded_fields_agree_with_designer_names(self):
        offsets = durations = amounts = 0
        mismatched = []
        for name, script in self.scripts.items():
            for r in script["responses"]:
                if r["response_type"] != 13 or r["kind"] != 0:
                    continue
                m = re.search(r"\((-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+)\)", r["name"])
                if m and r["command"] in (0, 1):
                    if [float(v) for v in m.groups()] == r["offset_ft"]:
                        offsets += 1
                    else:
                        mismatched.append(r["name"])
                m = re.search(r"([\d.]+) seconds?", r["name"])
                if m:
                    self.assertAlmostEqual(float(m.group(1)), r["duration_s"], msg=r["name"])
                    durations += 1
                m = re.search(r"(?:Zoom|Letter ?[Bb]ox) (\d+)", r["name"])
                if m:
                    self.assertEqual(int(m.group(1)), r["amount"], r["name"])
                    amounts += 1
        self.assertEqual((offsets, durations, amounts), (142, 70, 39))
        self.assertEqual(len(mismatched), 4)  # stale names, e.g. "Attach Golfer (0,10,-18)" stores -24

    def test_known_rules(self):
        b = self.scripts["b_camera.stn"]
        self.assertEqual(b["responses"][0]["offset_ft"], [0.0, 1.0, -15.0])
        flight = next(s for s in b["situations"] if s["name"] == "In Flight - Bling Bling")
        self.assertIn("flight_index == 7", flight["rule"]["when"])
        d = self.scripts["d_camera.stn"]
        putt = next(s for s in d["situations"] if s["name"].startswith("Ball Impact - Putt  (4f<Pin<7f)"))
        self.assertEqual([(c["bit"], c["operator"], c["value"]) for c in putt["conditions"]][2:],
                         [(3, "lt", 84), (15, "gt", 48)])
        self.assertEqual(len(d["never_matching_situations"]), 3)
        f = self.scripts["f_camera.stn"]
        self.assertEqual(sorted({a for s in f["situations"] for a in s["actions"]}), [9, 12])
        replay = self.scripts["Replay.stn"]
        self.assertEqual([a["probability_percent"] for a in replay["actions"]], [80, 65, 100])

    @unittest.skipUnless((EXECUTABLE / "Engine.dll").is_file(), "Engine.dll not present")
    def test_engine_constants_verify(self):
        report = cam.verify_engine((EXECUTABLE / "Engine.dll").read_bytes())
        self.assertTrue(report["matches_expected_build"])
        failures = [c for c in report["constants"] + report["immediates"] if not c["verified"]]
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
