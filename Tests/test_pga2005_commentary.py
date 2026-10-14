"""Commentary (announcer.stn / analyst.stn) and gallery shot-rule import."""
import contextlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import import_pga2005_audio as audio  # noqa: E402

INSTALL = ROOT / "Library/SourceMedia/pga2005/install"
COMMENTARY = INSTALL / "Sounds_-_Commentary"
IMPORTED = ROOT / "Library/Imported/pga2005/audio"
MP3 = b"\xff\xfb\x90\x64" + bytes(96)  # one MPEG-1 layer III frame header (44.1 kHz)


def build_stn(situations, actions, responses):
    """situations: (class, sub, [(bit, op, value)], [action ids], flags, priority, description)
    actions: (type, probability, flags, [response ids], description)
    responses: (type, mode, name bytes, description)"""
    sits = b""
    for event_class, sub, conditions, action_ids, flags, priority, _ in situations:
        record = bytearray(0x5B)
        record[0], record[1] = event_class, sub
        mask = 0
        for bit, _, _ in conditions:
            mask |= 1 << bit
        struct.pack_into("<I", record, 2, mask)
        ordered = sorted(conditions)
        struct.pack_into("<10H", record, 6, *[c[1] for c in ordered], *([0xFFF0] * (10 - len(ordered))))
        struct.pack_into("<10I", record, 0x1A, *[c[2] for c in ordered], *([0xFFF0] * (10 - len(ordered))))
        struct.pack_into("<10H", record, 0x42, *action_ids, *([0xFFF0] * (10 - len(action_ids))))
        struct.pack_into("<I", record, 0x56, flags)
        record[0x5A] = priority
        sits += record
    acts = b""
    for kind, probability, flags, response_ids, _ in actions:
        record = bytearray(0x57)
        record[0], record[1] = kind, probability
        struct.pack_into("<I", record, 2, flags)
        struct.pack_into("<30H", record, 6, *response_ids, *([0xFFF0] * (30 - len(response_ids))))
        acts += record
    resp = b""
    for kind, mode, name, _ in responses:
        record = bytearray(63)
        record[0] = kind
        struct.pack_into("<I", record, 1, mode)
        record[5:5 + len(name)] = name
        resp += record
    descriptions = [s[-1] for s in situations] + [a[-1] for a in actions] + [r[-1] for r in responses]
    o_sit = 28
    o_act = o_sit + len(sits)
    o_resp = o_act + len(acts)
    header = struct.pack("<7I", 0x10005, len(situations), o_sit, len(actions), o_act, len(responses), o_resp)
    return header + sits + acts + resp + b"\0".join(d.encode() for d in descriptions) + b"\0" * 32


def announcer_fixture():
    return build_stn(
        situations=[(2, 1, [(3, 4, 156), (12, 1, 12), (21, 5, 4)], [0], 0, 100, "InFlight: Green/Close"),
                    (2, 19, [(27, 1, 1)], [1, 2], 1, 99, "IntroPlayer: Woods"),
                    (12, 7, [(26, 1, 1)], [3], 0, 231, "IntroFormat: Stroke")],
        actions=[(8, 61, 0, [0, 1, 0], "close"), (8, 100, 1, [2, 3], "intro sequence"),
                 (8, 50, 0, [4], "missing"), (8, 100, 0, [5], "placeholder")],
        responses=[(10, 0, b"IF54_01.wav", "a"), (10, 0, b"IF54_02.mp3", "b"), (10, 0, b"TH01_01.wav", "c"),
                   (11, 0, b"TH01_02.wav", "d"), (10, 0, b"Gone_01.wav", "e"), (10, 0, b"no commentary", "f")])


def analyst_fixture():
    return build_stn(
        situations=[(2, 2, [(1, 5, 2), (18, 1, 1), (21, 5, 0x4000)], [0], 0, 100, "PuttResult: 1Putt")],
        actions=[(8, 75, 0, [0], "one putt")],
        responses=[(11, 0, b"LI01_01.wav", "x")])


def gallery_fixture():
    return build_stn(
        situations=[(2, 1, [(12, 1, 10), (21, 5, 1)], [0], 0, 200, "In Flight - Drive - fairway"),
                    (5, 7, [], [1], 0, 100, "Background - Random cheers")],
        actions=[(12, 100, 0x10, [0, 1], "cheer"), (12, 15, 0x10, [1], "distant")],
        responses=[(12, 0, b"PGAChrHg06_0250013400.wav", "c1"), (12, 0, b"PGAClap01_0000003000.wav", "c2")])


def install_tree(root: Path, commentary=True):
    wav = (b"RIFF" + struct.pack("<I", 40) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 22050, 44100, 2, 16)
           + b"data" + struct.pack("<I", 4) + bytes(4))
    files = {"Sounds_-_Basic/basic.stn": build_stn([], [], []), "Sounds_-_Gallery/gallery.stn": gallery_fixture(),
             "Sounds_-_Gallery/PGAChrHg06_0250013400.wav": wav, "Sounds_-_Gallery/PGAClap01_0000003000.wav": wav,
             "Sounds_-_Interface/Click.wav": wav}
    if commentary:
        files |= {"Sounds_-_Commentary/announcer.stn": announcer_fixture(),
                  "Sounds_-_Commentary/analyst.stn": analyst_fixture(),
                  "Sounds_-_Commentary/IF54_01.mp3": MP3, "Sounds_-_Commentary/IF54_02.mp3": MP3 + b"\1",
                  "Sounds_-_Commentary/TH01_01.mp3": MP3 + b"\2", "Sounds_-_Commentary/TH01_02.mp3": MP3 + b"\3",
                  "Sounds_-_Commentary/LI01_01.mp3": MP3 + b"\4", "Sounds_-_Commentary/Unused.mp3": MP3}
    for name, data in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_bytes(data)


def run_import(tmp: Path, *extra):
    with contextlib.redirect_stdout(io.StringIO()):
        return audio.main(["--source", str(tmp / "install"), "--course-data", str(tmp / "none"),
                           "--courses-image", str(tmp / "none.b6i"), "--output", str(tmp / "out"),
                           "--courses", "PBL", "--materials-root", str(tmp), *extra])


class CommentaryImportTests(unittest.TestCase):
    def test_scripts_files_and_placeholders(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            install_tree(tmp / "install")
            self.assertEqual(run_import(tmp), 0)
            out = tmp / "out"
            table = json.loads((out / audio.COMMENTARY_FILE).read_text())
            manifest = json.loads((out / audio.COMMENTARY_FILES_FILE).read_text())["files"]
            self.assertEqual(set(table["scripts"]), {"announcer", "analyst", "gallery"})
            self.assertEqual(table["event_masks"]["2"], 0x6FFFFFDF)
            announcer = table["scripts"]["announcer"]
            close = announcer["situations"][0]
            self.assertEqual((close["c"], close["s"], close["p"], close["one"]), (2, 1, 100, False))
            self.assertEqual(close["if"], [[3, "lt", 156], [12, "eq", 12], [21, "any_bits", 4]])
            self.assertTrue(announcer["situations"][1]["one"])
            # Duplicate response ids weight the least-played choice; keep them.
            self.assertEqual(announcer["actions"][0]["r"], [0, 1, 0])
            self.assertEqual((announcer["actions"][0]["p"], announcer["actions"][0]["seq"]), (61, False))
            self.assertTrue(announcer["actions"][1]["seq"])
            responses = announcer["responses"]
            # .wav names resolve to the shipped .mp3 (SoundResponse::SetAbsolutePath 0x10217277).
            self.assertEqual(responses[0], {"t": 10, "f": "commentary/IF54_01.mp3"})
            self.assertEqual(responses[3]["t"], 11)
            self.assertEqual(responses[4], {"t": 10, "f": None, "n": "Gone_01.wav"})
            self.assertEqual(responses[5], {"t": 10, "f": None, "n": "no commentary"})
            summary = table["summary"]["announcer"]
            self.assertEqual((summary["silent_placeholders"], summary["missing_files"]), (1, ["Gone_01.wav"]))
            self.assertEqual(summary["event_class_subs"], ["2/1", "2/19", "12/7"])
            # Gallery: only the class-2 shot rules; files point at the crowd import.
            gallery = table["scripts"]["gallery"]
            self.assertEqual([s["c"] for s in gallery["situations"]], [2])
            self.assertEqual(gallery["responses"][0]["f"], "crowd/PGAChrHg06_0250013400.wav")
            self.assertEqual(gallery["actions"][0]["fl"], 0x10)
            # MP3s are copied unchanged; unreferenced files are not imported.
            self.assertEqual(set(manifest), {f"commentary/{n}.mp3" for n in ("IF54_01", "IF54_02", "TH01_01", "TH01_02", "LI01_01")})
            for key, info in manifest.items():
                data = (out / key).read_bytes()
                self.assertEqual(data, (tmp / "install/Sounds_-_Commentary" / Path(key).name).read_bytes())
                self.assertEqual(audio.sha256(data), info["sha256"])
            # Commentary stays out of audio.json's file table.
            main = json.loads((out / "audio.json").read_text())
            self.assertFalse(any(k.startswith("commentary/") for k in main["files"]))
            self.assertEqual(main["commentary_file"], audio.COMMENTARY_FILE)
            self.assertNotIn("commentary", main)

    def test_without_commentary(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            install_tree(tmp / "install")
            self.assertEqual(run_import(tmp, "--no-commentary"), 0)
            table = json.loads((tmp / "out" / audio.COMMENTARY_FILE).read_text())
            self.assertEqual(set(table["scripts"]), {"gallery"})
            self.assertFalse((tmp / "out/commentary").exists())

    def test_missing_scripts_only_warn(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            install_tree(tmp / "install", commentary=False)
            self.assertEqual(run_import(tmp), 0)
            table = json.loads((tmp / "out" / audio.COMMENTARY_FILE).read_text())
            self.assertEqual(set(table["scripts"]), {"gallery"})
            main = json.loads((tmp / "out/audio.json").read_text())
            self.assertTrue(any("announcer.stn not found" in w for w in main["warnings"]))


def bounds(conditions, bit):
    """Inclusive integer interval allowed by eq/gt/lt conditions on one bit."""
    low, high = 0, 2**32 - 1
    for b, op, value in conditions:
        if b != bit:
            continue
        if op == "eq":
            low, high = max(low, value), min(high, value)
        elif op == "gt":
            low = max(low, value + 1)
        elif op == "lt":
            high = min(high, value - 1)
    return low, high


@unittest.skipUnless((COMMENTARY / "announcer.stn").is_file(), "original media not present")
class RealCommentaryTests(unittest.TestCase):
    def test_original_scripts_decode(self):
        announcer = audio.parse_stn((COMMENTARY / "announcer.stn").read_bytes())
        analyst = audio.parse_stn((COMMENTARY / "analyst.stn").read_bytes())
        self.assertEqual((len(announcer["situations"]), len(announcer["actions"]), len(announcer["responses"])), (1055, 907, 4270))
        self.assertEqual((len(analyst["situations"]), len(analyst["actions"]), len(analyst["responses"])), (436, 469, 2298))
        self.assertEqual({a["type"] for a in announcer["actions"] + analyst["actions"]}, {8})
        self.assertEqual({r["type"] for r in announcer["responses"]}, {10, 11})
        self.assertEqual({r["type"] for r in analyst["responses"]}, {11})
        subs = {(s["event_class"], s["event_sub"]) for s in announcer["situations"]}
        self.assertEqual(subs, {(2, 1), (2, 19), (9, 28), (9, 29), (10, 10), (12, 0), (12, 6), (12, 7), (12, 8)})
        subs = {(s["event_class"], s["event_sub"]) for s in analyst["situations"]}
        self.assertEqual(subs, {(1, 3), (2, 2), (2, 19), (12, 8)})
        self.assertFalse(any(s["match_any_bit"] or s["flags"] & 2 for s in announcer["situations"] + analyst["situations"]))
        # Tiger Woods is golfer model type 1 (bit 27) in the player intros.
        woods = [s for s in announcer["situations"] if s["description"].startswith("IntroPlayer: 1stTee/Woods")]
        self.assertIn({"bit": 27, "op": "eq", "value": 1}, woods[0]["conditions"])

    def test_class2_conditions_use_provided_values(self):
        mask = audio.EVENT_MASKS[2][0]
        gallery = audio.parse_stn((INSTALL / "Sounds_-_Gallery/gallery.stn").read_bytes())
        for script in (gallery, audio.parse_stn((COMMENTARY / "announcer.stn").read_bytes()),
                       audio.parse_stn((COMMENTARY / "analyst.stn").read_bytes())):
            for situation in script["situations"]:
                if situation["event_class"] == 2:
                    self.assertEqual(situation["mask"] & ~mask, 0, situation["description"])

    def test_bit3_equals_bit15_makes_some_rules_unreachable(self):
        # ShotEvent writes the same distance to bits 3 and 15 (0x102146cb), so
        # a rule needing b3 > 160 yd and b15 < 4 ft can never fire.
        dead = []
        for name in ("Sounds_-_Gallery/gallery.stn", "Sounds_-_Commentary/announcer.stn", "Sounds_-_Commentary/analyst.stn"):
            for situation in audio.parse_stn((INSTALL / name).read_bytes())["situations"]:
                if situation["event_class"] != 2:
                    continue
                conditions = [(c["bit"], c["op"], c["value"]) for c in situation["conditions"]]
                b3, b15 = bounds(conditions, 3), bounds(conditions, 15)
                if max(b3[0], b15[0]) > min(b3[1], b15[1]):
                    dead.append(situation["description"].strip())
        self.assertIn("In Flight - Approach <4ft to pin", dead)
        self.assertIn("React: Approach/CloseToPinV", dead)

    @unittest.skipUnless((IMPORTED / audio.COMMENTARY_FILES_FILE).is_file(), "commentary import has not been run")
    def test_imported_commentary_matches_manifest(self):
        manifest = json.loads((IMPORTED / audio.COMMENTARY_FILES_FILE).read_text())["files"]
        self.assertGreater(len(manifest), 3000)
        for key, info in manifest.items():
            data = (IMPORTED / key).read_bytes()
            self.assertEqual(audio.sha256(data), info["sha256"], key)
            self.assertEqual(info["sha256"], info["source"]["sha256"], key)
        table = json.loads((IMPORTED / audio.COMMENTARY_FILE).read_text())
        for name in ("announcer", "analyst", "gallery"):
            for response in table["scripts"][name]["responses"]:
                if response["f"]:
                    self.assertTrue((IMPORTED / response["f"]).is_file(), response["f"])


if __name__ == "__main__":
    unittest.main()
