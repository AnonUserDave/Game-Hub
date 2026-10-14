import contextlib
import io
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import import_pga2005_audio as audio  # noqa: E402

INSTALL = ROOT / "Library/SourceMedia/pga2005/install"
IMPORTED = ROOT / "Library/Imported/pga2005/audio/audio.json"


# ---------------------------------------------------------------- fixtures
def riff(chunks):
    body = b"WAVE"
    for cid, payload, declared in chunks:
        size = len(payload) if declared is None else declared
        body += cid + struct.pack("<I", size) + payload + (b"\0" if len(payload) & 1 else b"")
    return b"RIFF" + struct.pack("<I", len(body)) + body


def fmt_chunk(tag, channels, rate, bits, align, extra=b""):
    payload = struct.pack("<HHIIHH", tag, channels, rate, rate * align, align, bits)
    if extra:
        payload += struct.pack("<H", len(extra)) + extra
    return (b"fmt ", payload, None)


def pcm16(samples):
    return struct.pack(f"<{len(samples)}h", *samples)


def read_frames(data):
    with wave.open(io.BytesIO(data)) as w:
        return w.getnchannels(), w.getframerate(), list(struct.unpack(f"<{w.getnframes() * w.getnchannels()}h",
                                                                  w.readframes(w.getnframes())))


def ima_encode(samples, channels, block_frames):
    """Reference IMA/DVI encoder; returns (bytes, block_align, reconstructed)."""
    blocks, recon = [], []
    state = [[0, 0] for _ in range(channels)]
    frames = len(samples) // channels
    for start in range(0, frames, block_frames):
        chunk = [samples[(start + f) * channels:(start + f + 1) * channels] for f in range(min(block_frames, frames - start))]
        header, planar = b"", [[] for _ in range(channels)]
        for c in range(channels):
            state[c][0] = chunk[0][c]
            header += struct.pack("<hBB", state[c][0], state[c][1], 0)
            planar[c].append(state[c][0])
        codes = [[] for _ in range(channels)]
        for f in range(1, block_frames):
            for c in range(channels):
                target = chunk[f][c] if f < len(chunk) else chunk[-1][c]
                predictor, index = state[c]
                step = audio.IMA_STEPS[index]
                diff, code = target - predictor, 0
                if diff < 0:
                    code, diff = 8, -diff
                if diff >= step: code |= 4; diff -= step
                if diff >= step >> 1: code |= 2; diff -= step >> 1
                if diff >= step >> 2: code |= 1
                delta = step >> 3
                if code & 1: delta += step >> 2
                if code & 2: delta += step >> 1
                if code & 4: delta += step
                predictor = audio.clamp16(predictor - delta if code & 8 else predictor + delta)
                state[c] = [predictor, min(88, max(0, index + audio.IMA_INDEX[code]))]
                codes[c].append(code)
                planar[c].append(predictor)
        body = b""
        for group in range(0, block_frames - 1, 8):
            for c in range(channels):
                nib = codes[c][group:group + 8]
                body += bytes(nib[i] | nib[i + 1] << 4 for i in range(0, 8, 2))
        blocks.append(header + body)
        for f in range(len(chunk)):
            recon.extend(planar[c][f] for c in range(channels))
    return b"".join(blocks), len(blocks[0]), recon


def stn_fixture():
    """Version 0x10005 script: 2 situations, 2 actions, 4 responses."""
    sit = bytearray(0x5B)
    sit[0], sit[1] = 3, 4
    struct.pack_into("<I", sit, 2, (1 << 2) | (1 << 5))
    struct.pack_into("<10H", sit, 6, 1, 3, *([0xFFF0] * 8))
    struct.pack_into("<10I", sit, 0x1A, 905, 40, *([0xFFF0] * 8))
    struct.pack_into("<10H", sit, 0x42, 0, *([0xFFF0] * 9))
    sit[0x5A] = 100
    sit2 = bytearray(0x5B)
    sit2[0], sit2[1] = 0, 16
    struct.pack_into("<10H", sit2, 6, *([0xFFF0] * 10))
    struct.pack_into("<10I", sit2, 0x1A, *([0xFFF0] * 10))
    struct.pack_into("<10H", sit2, 0x42, 1, *([0xFFF0] * 9))
    struct.pack_into("<I", sit2, 0x56, 1)
    sit2[0x5A] = 99
    acts = b""
    for responses in ((0, 1), (2, 3)):
        act = bytearray(0x57)
        act[0], act[1] = 2, 100
        struct.pack_into("<30H", act, 6, *responses, *([0xFFF0] * (30 - len(responses))))
        acts += act
    resp = b""
    for kind, mode, name in ((2, 1, b"BallRufEA1.wav"), (2, 1, b"BallRufEA2.wav"), (2, 2, b"BallCup1.wav"), (9, 0, b"\x07\x01")):
        record = bytearray(63)
        record[0] = kind
        struct.pack_into("<I", record, 1, mode)
        record[5:5 + len(name)] = name
        resp += record
    descriptions = [b"ball hits rough", b"ball falls in cup", b"*rough", b"*cup",
                    b"BallRuf1", b"BallRuf2", b"BallCup1", b"Set crowd"]
    header = struct.pack("<7I", 0x10005, 2, 28, 2, 28 + 2 * 0x5B, 4, 28 + 2 * 0x5B + 2 * 0x57)
    return header + sit + sit2 + acts + resp + b"\0".join(descriptions) + b"\0" * 32


# ------------------------------------------------------------------- tests
class AdpcmTests(unittest.TestCase):
    def test_ms_adpcm_hand_vector_and_clamp(self):
        block = bytes([0]) + struct.pack("<hhh", 16, 100, 50) + bytes([0x11, 0xF0])
        self.assertEqual(audio.decode_ms_adpcm(block, 1, len(block), b""), [50, 100, 116, 132, 116, 116])
        block = bytes([1]) + struct.pack("<hhh", 16, 30000, 0) + bytes([0x77])
        self.assertEqual(audio.decode_ms_adpcm(block, 1, len(block), b"")[2:], [32767, 32767])
        self.assertEqual(len(audio.decode_ms_adpcm(block * 2, 1, len(block), b"", total=5)), 5)

    def test_ms_adpcm_stereo_interleave_and_custom_coefficients(self):
        extra = struct.pack("<HH", 1012, 1) + struct.pack("<hh", 256, 0)
        block = bytes([0, 0]) + struct.pack("<hhhhhh", 16, 16, 10, -10, 5, -5) + bytes([0x1F])
        self.assertEqual(audio.decode_ms_adpcm(block, 2, len(block), extra), [5, -5, 10, -10, 26, -26])
        with self.assertRaises(audio.FormatError):
            audio.decode_ms_adpcm(bytes([3]) + bytes(8), 1, 9, extra)

    def test_ima_round_trip_matches_reference_decoder_state(self):
        for channels in (1, 2):
            signal = [int(9000 * math.sin(i / (5 + c))) for i in range(300) for c in range(channels)]
            data, align, expected = ima_encode(signal, channels, 1 + 8 * 6)
            decoded = audio.decode_ima_adpcm(data, channels, align, total=len(signal) // channels)
            self.assertEqual(decoded, expected)
            # After the step size has adapted, the codec tracks the signal.
            half = len(signal) // 2
            self.assertLess(max(abs(a - b) for a, b in zip(decoded[half:], signal[half:])), 1500)

    def test_wav_conversion_paths(self):
        samples = [0, 1000, -1000, 32767, -32768, 7]
        canonical = riff([fmt_chunk(1, 1, 22050, 16, 2), (b"data", pcm16(samples), None)])
        out, info = audio.convert_wav(canonical)
        self.assertEqual((out, info["conversion"]), (canonical, "copied"))
        messy = riff([fmt_chunk(1, 1, 11025, 16, 2, b""), (b"data", pcm16(samples) + b"\x01", None),
                      (b"LIST", b"INFOabc", None), (b"\0\0\0\0", b"", 999)])
        out, info = audio.convert_wav(messy)
        self.assertEqual(info["conversion"], "rewritten_canonical_pcm")
        self.assertEqual(read_frames(out), (1, 11025, samples))
        truncated = riff([fmt_chunk(1, 2, 22050, 16, 4), (b"data", pcm16([1, 2, 3, 4, 5]), 400)])
        self.assertEqual(read_frames(audio.convert_wav(truncated)[0])[2], [1, 2, 3, 4])
        eight = riff([fmt_chunk(1, 1, 8000, 8, 1), (b"data", bytes([128, 255, 0]), None)])
        self.assertEqual(read_frames(audio.convert_wav(eight)[0])[2], [0, 127 << 8, -128 << 8])
        block = bytes([0]) + struct.pack("<hhh", 16, 100, 50) + bytes([0x11, 0xF0])
        adpcm = riff([fmt_chunk(2, 1, 22050, 4, len(block), struct.pack("<HH", 6, 0)),
                      (b"fact", struct.pack("<I", 5), None), (b"data", block, None)])
        out, info = audio.convert_wav(adpcm)
        self.assertEqual((info["conversion"], read_frames(out)[2]), ("decoded_ms_adpcm", [50, 100, 116, 132, 116]))
        for bad in (b"RIFX" + bytes(40), riff([(b"data", b"", None)]),
                    riff([fmt_chunk(0x55, 1, 22050, 16, 2), (b"data", b"", None)])):
            with self.assertRaises(audio.FormatError):
                audio.convert_wav(bad)

    def test_mp3_header(self):
        info = audio.mp3_info(b"ID3\x03\0\0\0\0\0\x02" + b"xx" + b"\xff\xfb\x90\x64" + bytes(100))
        self.assertEqual((info["sample_rate"], info["channels"]), (44100, 2))
        with self.assertRaises(audio.FormatError):
            audio.mp3_info(bytes(200))


class ScriptTests(unittest.TestCase):
    def test_stn_tables_conditions_and_descriptions(self):
        stn = audio.parse_stn(stn_fixture())
        rough, cup = stn["situations"]
        self.assertEqual((rough["event_class"], rough["event_sub"], rough["priority"]), (3, 4, 100))
        self.assertEqual(rough["conditions"], [{"bit": 2, "op": "eq", "value": 905}, {"bit": 5, "op": "gt", "value": 40}])
        self.assertEqual((cup["single_action"], cup["priority"], cup["description"]), (True, 99, "ball falls in cup"))
        self.assertEqual(stn["responses"][2]["mode"], "loop")
        self.assertEqual(stn["responses"][3]["kind"], "command")
        self.assertEqual(audio.situation_files(stn, cup), [["BallCup1.wav"]])
        self.assertEqual(stn["responses"][0]["channel"], "ambient")
        with self.assertRaises(audio.FormatError):
            audio.parse_stn(stn_fixture()[:200])

    def test_snd_ini_emitters(self):
        text = """[amb_ocean_loop]
frequency=100
volume=75
loop=1
[Birds]
frequency=20
[Birds]
frequency=99
[Sound 0]
hole=1
type=4
point0=0,0,0
point1=18000,0,0
points=2
folder=amb_ocean_loop
file0=ocean.wav
files=1
[Sound 1]
hole=2
type=4
point0=10,20,30
point1=4320,0,0
points=2
folder=Birds
file0=a.wav
file1=b.wav
files=2
[Sound 2]
hole=2
type=4
point0=10,20,30
points=2
folder=Birds
file0=a.wav
files=1
"""
        parsed = audio.parse_snd_ini(text, origin=(-288.0, 0.0, 7781.0))
        self.assertEqual(parsed["folders"]["amb_ocean_loop"], {"frequency_percent": 100, "volume_percent": 75, "loop": True, "defined": True})
        self.assertEqual(parsed["folders"]["Birds"]["frequency_percent"], 20)  # first section wins
        self.assertEqual(parsed["duplicate_sections"], ["Birds"])
        global_bed, birds, broken = parsed["emitters"]
        self.assertTrue(global_bed["global_2d"])
        self.assertNotIn("center_world_inches", global_bed)
        self.assertEqual((birds["radius_inches"], birds["center_world_inches"]), (4320.0, [408.0, 240.0, -7421.0]))
        self.assertTrue(broken["effectively_silent"])
        self.assertEqual(broken["missing_points"], [1])

    def test_cls_ini_sounds(self):
        text = """'====sounds====
[DuckQuack]
type=sound
file=..\\..\\Generic\\Sounds\\Amb_ShoreBirds\\bird_duck_05.wav
volume=0.1
RepeatLow=30000
RepeatHigh=50000
DistanceLow=5
DistanceHigh=350
[DuckA]
sound=DuckQuack
"""
        (sound,) = audio.parse_cls_ini(text)
        self.assertEqual((sound["folder"], sound["file"], sound["volume"]), ("Amb_ShoreBirds", "bird_duck_05.wav", 0.1))
        self.assertEqual((sound["repeat_ms"], sound["distance_inches"], sound["actors"]), ([30000, 50000], [60.0, 4200.0], ["DuckA"]))


class ImporterTests(unittest.TestCase):
    def test_end_to_end_synthetic_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            install, courses, out = tmp / "install", tmp / "courses", tmp / "out"
            wav = riff([fmt_chunk(1, 1, 22050, 16, 2), (b"data", pcm16([1, 2, 3, 4]), None)])
            files = {"Sounds_-_Basic/basic.stn": stn_fixture(), "Sounds_-_Basic/BallRufEA1.wav": wav,
                     "Sounds_-_Basic/BallRufEA2.wav": wav, "Sounds_-_Basic/BallCup1.wav": wav,
                     "Sounds_-_Gallery/gallery.stn": stn_fixture().replace(b"ball falls in cup", b"other description"),
                     "Sounds_-_Interface/Click.wav": wav, "Sounds_-_Interface/KaChing.mp3": b"\xff\xfb\x90\x64" + bytes(64),
                     "Courses_-_Generic/Sounds/Birds/a.wav": wav, "Courses_-_Generic/Sounds/Other/a.wav": wav,
                     "Courses_-_Generic/Sounds/Amb_bees/Bees1.wav": wav}
            block = bytes([0]) + struct.pack("<hhh", 16, 100, 50) + bytes([0x11, 0xF0])
            files["Sounds_-_Interface/scale.wav"] = riff([fmt_chunk(2, 1, 22050, 4, len(block), struct.pack("<HH", 6, 0)),
                                                          (b"data", block, None)])
            for name, data in files.items():
                (install / name).parent.mkdir(parents=True, exist_ok=True)
                (install / name).write_bytes(data)
            (courses / "PBL/CLS").mkdir(parents=True)
            tcr = bytearray(0x324)
            struct.pack_into("<3f", tcr, 0x318, -288.0, 0.0, 7781.0)
            (courses / "PBL/PBL.TCR").write_bytes(bytes(tcr))
            (courses / "PBL/SND.INI").write_bytes(b"[Birds]\r\nfrequency=20\r\nvolume=80\r\n[Sound 1]\r\nhole=1\r\ntype=4\r\n"
                                                  b"point0=10,20,30\r\npoint1=4320,0,0\r\npoints=2\r\nfolder=Birds\r\n"
                                                  b"file0=a.wav\r\nfile1=missing.wav\r\nfiles=2\r\n")
            (courses / "PBL/CLS/CLS.INI").write_bytes(b"[Buzz]\ntype=sound\nfile=..\\..\\Generic\\Sounds\\Amb_bees\\Bees1.wav\n")
            with contextlib.redirect_stdout(io.StringIO()):
                code = audio.main(["--source", str(install), "--course-data", str(courses), "--courses-image", str(tmp / "none.b6i"),
                                   "--output", str(out), "--courses", "PBL", "--materials-root", str(tmp)])
            self.assertEqual(code, 0)
            table = json.loads((out / "audio.json").read_text())
            rules = json.loads((out / audio.RULES_FILE).read_text())
            self.assertNotIn("rules", table)
            self.assertEqual(len(rules["rules"]["basic"]["situations"]), 2)
            rough = table["events"]["ball.hit.rough"]
            self.assertEqual(rough["files"], ["gameplay/BallRufEA1.wav", "gameplay/BallRufEA2.wav"])
            self.assertEqual((rough["random"], rough["preload"], rough["positional"]), ("least_played_uniform", True, True))
            self.assertTrue(table["events"]["ball.cup"]["loop"])
            self.assertEqual(table["surface_sound_ids"]["905"][0]["event"], "ball.hit.rough")
            self.assertEqual(read_frames((out / "interface/scale.wav").read_bytes())[2], [50, 100, 116, 132, 116, 116])
            self.assertEqual(table["files"]["interface/scale.wav"]["source"]["path"], "Sounds_-_Interface/scale.wav")
            self.assertEqual((out / "interface/KaChing.mp3").read_bytes()[:2], b"\xff\xfb")
            course = table["courses"]["PBL"]
            self.assertEqual(course["emitters"][0]["files"], ["a.wav"])
            self.assertEqual(course["ambient_folders"]["Birds"]["files"], ["ambient/Birds/a.wav"])
            self.assertEqual(course["emitters"][0]["center_world_inches"], [408.0, 240.0, -7421.0])
            self.assertEqual(course["course_life_sounds"][0]["files"], ["ambient/Amb_bees/Bees1.wav"])
            self.assertIn({"file": "missing.wav", "folder": "Birds", "context": "PBL SND.INI Sound 1"}, table["missing_sources"])
            self.assertIn("weather.wind_strong", {u["event"] for u in table["unresolved_events"]})
            for key, info in table["files"].items():
                data = (out / key).read_bytes()
                self.assertEqual(audio.sha256(data), info["sha256"])
            self.assertFalse(list(out.rglob("*.partial")))

    def test_source_index_prefers_folder_and_refuses_ambiguous_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            for folder in ("A", "B"):
                (Path(tmp) / folder).mkdir()
                (Path(tmp) / folder / "x.wav").write_bytes(b"")
            index = audio.SourceIndex(Path(tmp))
            self.assertEqual(index.find("X.WAV", folder="b").parent.name, "B")
            self.assertIsNone(index.find("x.wav", folder="C"))


@unittest.skipUnless((INSTALL / "Sounds_-_Basic/basic.stn").is_file(), "original media not present")
class RealMediaTests(unittest.TestCase):
    def test_original_scripts_decode(self):
        basic = audio.parse_stn((INSTALL / "Sounds_-_Basic/basic.stn").read_bytes())
        self.assertEqual((len(basic["situations"]), len(basic["actions"]), len(basic["responses"])), (53, 53, 117))
        by = {s["description"]: s for s in basic["situations"]}
        rough = by["ball hits rough"]
        self.assertEqual([c for c in rough["conditions"] if c["bit"] == 2], [{"bit": 2, "op": "eq", "value": 905}])
        self.assertEqual(audio.situation_files(basic, by["ball hits branches"]),
                         [[f"BallBranch{i}.wav" for i in range(1, 10)], ["BallLeaf1.wav", "BallLeaf2.wav"]])
        self.assertEqual(by["ball hits fairway"]["priority"], 101)
        gallery = audio.parse_stn((INSTALL / "Sounds_-_Gallery/gallery.stn").read_bytes())
        self.assertEqual((len(gallery["situations"]), len(gallery["responses"])), (199, 784))
        music = audio.parse_stn((INSTALL / "Sounds_-_Music/music.stn").read_bytes())
        self.assertEqual([r["file"] for r in music["responses"]][:2], ["shell1.mp3", "endmus.wav"])

    def test_scale_wav_is_ms_adpcm_and_decodes(self):
        out, info = audio.convert_wav((INSTALL / "Sounds_-_Interface/scale.wav").read_bytes())
        self.assertEqual((info["source_codec"], info["frames"]), ("ms_adpcm", 1804))
        self.assertEqual(read_frames(out)[2][:4], [0, -483, -236, 376])

    def test_dry_run_import_is_complete(self):
        source = audio.CourseSource(audio.DEFAULT_COURSE_DATA, audio.DEFAULT_IMAGE)
        try:
            result = audio.Importer(INSTALL, Path("/nonexistent-dry-run"), ["PBL", "TUR"], source, music=True,
                                    dry_run=True, materials_root=ROOT / "Library/Imported/pga2005").run()
        finally:
            source.close()
        self.assertEqual(result["unresolved_events"], [])
        missing = {m["file"] for m in result["missing_sources"]}
        self.assertEqual(missing, {"01503_0000007000.wav", "02008_0000004000.wav", "02109_0000006000.wav",
                                   "02311_0200014000.wav", "PGAMssd99b_0000000000.wav", "PGAMssd99c_0000000000.wav", "PGASS202.wav"})
        self.assertLess(result["totals_bytes"]["all"] - result["totals_bytes"].get("music", 0), 32_000_000)
        if result["courses"]["PBL"]["provenance"].get("snd_ini"):
            self.assertEqual(len(result["courses"]["PBL"]["emitters"]), 606)

    @unittest.skipUnless(IMPORTED.is_file(), "audio import has not been run")
    def test_imported_files_match_manifest(self):
        table = json.loads(IMPORTED.read_text())
        for key, info in table["files"].items():
            data = (IMPORTED.parent / key).read_bytes()
            self.assertEqual(audio.sha256(data), info["sha256"], key)
            if key.endswith(".wav"):
                self.assertEqual(data[20:22], b"\x01\x00", key)  # PCM


if __name__ == "__main__":
    unittest.main()
