import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import decode_pga2005_golfer as golfer  # noqa: E402
from decode_pga2005_golfer import FormatError  # noqa: E402

MEDIA = ROOT / "Library/SourceMedia/pga2005/install"


def words(*values):
    return b"".join(struct.pack(">H", v) for v in values)


def close(a, b, tol=1e-5):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


class RdatTests(unittest.TestCase):
    def test_literal_fill_copy_and_reverse_copy(self):
        stream = (words(0x8804) + b"ABCD"        # literal 4
                  + words(0x9802)                 # fill: distance 1, length 5
                  + words(0x1009)                 # copy: length 4 from 9 back
                  + words(0x8006))                # reverse copy: length 3, base = start-6+2
        out, used = golfer.rdat_decompress(stream, 16)
        self.assertEqual(used, len(stream))
        self.assertEqual(out[:9], b"ABCDDDDDD")
        self.assertEqual(out[9:13], b"ABCD")
        start = 13
        base = start - 6 + 2
        expected = bytes(out[base - k] for k in range(3))
        self.assertEqual(out[13:16], expected)

    def test_extended_length_and_long_distance(self):
        stream = words(0x8814) + bytes(range(20)) + words(0x7014) + bytes([2])
        out, _ = golfer.rdat_decompress(stream, 32)
        self.assertEqual(out[20:32], bytes(range(12)))

    def test_rejects_truncated_and_out_of_range(self):
        with self.assertRaises(FormatError):
            golfer.rdat_decompress(words(0x8804) + b"AB", 4)
        with self.assertRaises(FormatError):
            golfer.rdat_decompress(words(0x1009), 4)
        with self.assertRaises(FormatError):
            golfer.rdat_decompress(words(0x9802), 5)
        with self.assertRaises(FormatError):
            golfer.rdat_decompress(b"", 1 << 30)


def shoc(subtype: bytes, body: bytes) -> bytes:
    size = 20 + len(body)
    return b"COHS" + struct.pack("<III", size, 0, 0) + subtype[::-1] + body


class ContainerTests(unittest.TestCase):
    def fixture(self, payload=b"HELLO WORLD!"):
        shdr = shoc(b"SHDR", struct.pack("<I4sIII", 1, b"CHR "[::-1], 0, len(payload), 0) + bytes(24))
        compressed = words(0x8800 | len(payload)) + payload
        rdat = shoc(b"Rdat", bytes(0x40 - 20) + struct.pack("<I", len(payload)) + compressed)
        fill = b"LLIF" + struct.pack("<I", 16) + bytes(8)
        return b"LRTC" + struct.pack("<III", 0x18, 0, 0) + b"CNYS" + bytes(4) + shdr + fill + rdat

    def test_walk_and_payload(self):
        data = self.fixture()
        resources = golfer.read_container(data)
        self.assertEqual(len(resources), 1)
        self.assertEqual(resources[0]["tag"], "CHR ")
        self.assertEqual(resources[0]["kind"], 1)
        self.assertEqual(golfer.resource_payload(data, resources[0]), b"HELLO WORLD!")

    def test_rejects_bad_chunks(self):
        data = bytearray(self.fixture())
        with self.assertRaises(FormatError):
            golfer.read_container(b"XXXX" + bytes(data[4:]))
        data[0x18 + 4:0x18 + 8] = struct.pack("<I", 0xFFFFFF)
        with self.assertRaises(FormatError):
            golfer.read_container(bytes(data))

    def test_payload_size_mismatch(self):
        data = self.fixture()
        resource = golfer.read_container(data)[0]
        resource["size"] += 1
        with self.assertRaises(FormatError):
            golfer.resource_payload(data, resource)


class QuaternionTests(unittest.TestCase):
    def test_euler_order_matches_engine_product(self):
        z, y, x = 1000, 20000, 40000
        expected = golfer.qmul(golfer.qmul(golfer._axis(0, x), golfer._axis(1, y)), golfer._axis(2, z))
        self.assertTrue(close(golfer._euler(z, y, x), expected))
        quarter = golfer._axis(2, 16384)
        self.assertTrue(close(quarter, (0, 0, math.sqrt(0.5), math.sqrt(0.5))))
        self.assertTrue(close(golfer.qrotate(quarter, (1, 0, 0)), (0, 1, 0)))

    def test_inverse_rigid_and_matrix(self):
        q = golfer.qnormalize((0.1, 0.2, 0.3, 0.9))
        t = (1.0, -2.0, 0.5)
        iq, it = golfer.inverse_rigid(q, t)
        p = golfer.qrotate(q, (0.3, 0.4, 0.5))
        p = tuple(p[k] + t[k] for k in range(3))
        back = golfer.qrotate(iq, p)
        self.assertTrue(close(tuple(back[k] + it[k] for k in range(3)), (0.3, 0.4, 0.5)))
        m = golfer.matrix_from(q, t)
        v = (0.3, 0.4, 0.5)
        mv = tuple(m[k] * v[0] + m[4 + k] * v[1] + m[8 + k] * v[2] + m[12 + k] for k in range(3))
        rv = golfer.qrotate(q, v)
        self.assertTrue(close(mv, tuple(rv[k] + t[k] for k in range(3))))


def ska_fixture():
    """Two channels: channel 0 constant Euler, channel 1 stream-B Z-axis plus translation."""
    frames = 2
    header = bytearray(0x100)
    struct.pack_into("<I", header, 0, 0)
    struct.pack_into("<hh", header, 0xC, frames, frames - 1)
    struct.pack_into("<f", header, 0x10, 1 / 30)
    struct.pack_into("<I", header, 0x1C, 2)
    struct.pack_into("<I", header, 0x2C, 32)
    struct.pack_into("<I", header, 0x40, 6)        # one constant Euler
    struct.pack_into("<I", header, 0x3C, 0)
    struct.pack_into("<I", header, 0x38, 4)        # stream B: 1 u16 per frame
    struct.pack_into("<I", header, 0x4, 0)
    struct.pack_into("<I", header, 0x4C, 12)       # translation frames
    struct.pack_into("<I", header, 0x50, 24)       # translation params
    struct.pack_into("<III", header, 0x58, 0, 1, 1)  # a_count, b_count, const_count
    struct.pack_into("<hh", header, 0x90, 1, 0)
    header[0xA0:0xA9] = b"IG_driver"
    header[0xB0:0xB4] = b"test"
    body = bytearray()
    body += struct.pack("<4I", 4, 0, 0, 0)          # channel 0: constant rotation
    body += struct.pack("<4I", 8 | 0x10, 0, 0, 0)   # channel 1: stream B + translation
    data = bytearray(header + body)
    data += bytes((-len(data)) % 16)
    data += struct.pack("<3H", 0, 0, 16384)         # constant: X rotation 90 degrees
    data += struct.pack("<2H", 16384, 32768)        # stream B per frame (Z axis)
    data += struct.pack("<6f", 0, 2, -1, 1, 0, 0)   # translation params
    data += struct.pack("<3H", 0, 0, 0) + struct.pack("<3H", 65535, 65535, 0)
    size54 = len(data) - (0x100 + 32)
    struct.pack_into("<I", data, 0x54, size54)
    bits = bytearray(4)
    bits[0] = 0b01                                   # stream-B channel 0 = mode 1 (Z axis)
    data += bytes(4) + bits                          # a_bits, b_bits
    return bytes(data)


class SkaTests(unittest.TestCase):
    def test_layout_and_sampling(self):
        clip = golfer.parse_ska(ska_fixture())
        self.assertEqual(clip["frame_count"], 2)
        self.assertEqual(clip["club_bone"], "IG_driver")
        f0 = golfer.sample_ska(clip, 0)
        self.assertTrue(close(f0[0][1], (math.sqrt(0.5), 0, 0, math.sqrt(0.5))))
        self.assertTrue(close(f0[1][1], (0, 0, math.sqrt(0.5), math.sqrt(0.5))))
        self.assertTrue(close(f0[1][2], (0, -1, 0)))
        f1 = golfer.sample_ska(clip, 1)
        self.assertTrue(close(f1[1][1], (0, 0, 1, 0), 1e-6))
        self.assertTrue(close(f1[1][2], (2, 1, 0)))

    def test_layout_size_mismatch_rejected(self):
        with self.assertRaises(FormatError):
            golfer.parse_ska(ska_fixture() + b"\0\0\0\0")

    def test_clip_round_trip_and_phases(self):
        clip = golfer.parse_ska(ska_fixture())
        clip["events"] = [(0, 0.0333), (1, 0.0333), (2, 0.0333)]
        skeleton = {"bones": [
            {"parent": -1, "bind_local": {"rotation": [0, 0, 0, 1], "translation": [0, 0, 0]}},
            {"parent": 0, "bind_local": {"rotation": [0, 0, 0, 1], "translation": [0, 1, 0]}}]}
        frames, flags = golfer.clip_poses(clip, skeleton)
        self.assertEqual(flags, [2, 1 | 4])
        data = golfer.write_clip(clip, frames, flags)
        back = golfer.read_clip(data)
        self.assertEqual(back["channel_flags"], [2, 5])
        self.assertAlmostEqual(back["fps"], 30, places=4)
        # Output quaternions are the conjugate (Hamilton parent ⊗ local convention).
        self.assertTrue(close(back["poses"][0][0][0], (-math.sqrt(0.5), 0, 0, math.sqrt(0.5))))
        self.assertEqual(golfer.swing_phases(clip)["downswing"], [1, 1])


class MeshTests(unittest.TestCase):
    def model_fixture(self):
        blob = bytearray(0x400)
        # palette: register -4 <- blend 1, register -8 <- blend 0
        struct.pack_into("<2I", blob, 0x100, (0x4FC << 16) | 4, (0x4F8 << 16) | 0)
        stride, base = 18, 0x140
        verts = [(0, 0, 0, -4), (32767, 0, 0, -8), (0, 32767, 0, -4)]
        for i, (x, y, z, w) in enumerate(verts):
            struct.pack_into("<4h3h2h", blob, base + 0x40 + stride * i, x, y, z, w, 0, 0, 16384, 4096, 2048)
        struct.pack_into("<3H", blob, 0x200 + 0x40, 0, 1, 2)
        buffers = [{"offset": 0, "size": 0, "count": 2, "type": 0x700004},
                   {"offset": 0x100, "size": 16, "count": 2, "type": 0x1808},
                   {"offset": base, "size": 0xA0, "count": 3, "type": 0x71},
                   {"offset": 0x200, "size": 0x50, "count": 3, "type": 0x2}]
        model = {"blob": bytes(blob), "buffers": buffers, "lists": [0, 1, 2, 3],
                 "nodes": [[0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0]],
                 "batches": [0xFFFF, 2, 3, 3], "position_scale": 2.0,
                 "slots": [{"name": "skin", "uv_transform": [1, 1, 0, 0]}], "layers": [0], "sets": {}}
        skin = {"blends": [[(0, 1.0)], [(1, 0.75), (0, 0.25)]]}
        return model, skin

    def test_palette_registers_scale_and_uv(self):
        model, skin = self.model_fixture()
        lists = golfer.node_buffer_lists(model)
        node = golfer.decode_node(model, skin, model["nodes"][0], lists[0])
        self.assertEqual([v[3] for v in node["vertices"]], [1, 0, 1])
        self.assertTrue(close(node["vertices"][1][0], (32767 * 2 / 32768, 0, 0)))
        self.assertTrue(close(node["vertices"][0][1], (0, 0, 1)))
        self.assertTrue(close(node["vertices"][0][2], (1.0, 0.5)))
        self.assertEqual(node["triangles"], [(0, 1, 2)])

    def test_batch_totals_and_registers_validated(self):
        model, skin = self.model_fixture()
        model["batches"] = [0xFFFF, 2, 2, 3]
        with self.assertRaises(FormatError):
            golfer.decode_node(model, skin, model["nodes"][0], golfer.node_buffer_lists(model)[0])
        model, skin = self.model_fixture()
        model["batches"] = [0xFFFF, 1, 3, 3]
        model["buffers"][1]["count"] = 1
        with self.assertRaises(FormatError):
            golfer.decode_node(model, skin, model["nodes"][0], golfer.node_buffer_lists(model)[0])

    def test_mesh_orientation_and_binary_round_trip(self):
        model, skin = self.model_fixture()
        character = {"model": model, "skin": skin}
        mesh = golfer.build_mesh(character)
        self.assertEqual(mesh["triangles"], [(0, 1, 2)])
        self.assertEqual(mesh["submeshes"][0]["base"]["texture"], "skin")
        data = golfer.write_mesh(mesh)
        back = golfer.read_mesh(data)
        self.assertEqual(len(back["vertices"]), 3)
        self.assertEqual(back["indices"], (0, 1, 2))
        self.assertEqual(back["submeshes"], [(0, 3, 0, 3)])
        joints, weights = back["vertices"][0][3], back["vertices"][0][4]
        self.assertEqual(joints[:2], (1, 0))
        self.assertEqual(sum(weights), 255)
        self.assertEqual(len(data), 56 + 3 * golfer.VERTEX_BYTES + 8 + 16)


class TextureTests(unittest.TestCase):
    def test_directory_record_and_dxt1(self):
        record = bytearray(88)
        record[:6] = b"htface"
        struct.pack_into("<IHHHH", record, 16, 0, 1, 0xFFFF, 0, 1)
        struct.pack_into("<4H", record, 64, 4, 4, 0xFFFF, 0)
        record[72], record[73] = 0x0C, 1
        directory = golfer.parse_texture_directory(bytes(record), 0, 88)
        entry = directory["htface"]
        self.assertEqual((entry["width"], entry["height"], entry["format"]), (4, 4, 0x0C))
        block = struct.pack("<HHI", 0xF800, 0x001F, 0)    # all texels color0 = red
        fxx = block + bytes(8)
        entry["mips"] = [(0, 8)]
        w, h, rgba = golfer.decode_texture(fxx, entry)
        self.assertEqual((w, h), (4, 4))
        self.assertEqual(rgba[:4], bytes((255, 0, 0, 255)))

    def test_rejects_unknown_format_and_size(self):
        entry = {"format": 0x06, "width": 4, "height": 4, "mips": [(0, 64)]}
        with self.assertRaises(FormatError):
            golfer.decode_texture(bytes(64), entry)
        entry = {"format": 0x0C, "width": 8, "height": 8, "mips": [(0, 8)]}
        with self.assertRaises(FormatError):
            golfer.decode_texture(bytes(64), entry)
        with self.assertRaises(FormatError):
            golfer.parse_texture_directory(bytes(90), 0, 90)


class SkeletonTests(unittest.TestCase):
    def test_bind_world_and_inverse(self):
        root_q = (0.0, 0.0, math.sqrt(0.5), math.sqrt(0.5))
        character = {
            "skeleton": {"bones": [{"name": "root", "parent": -1}, {"name": "child", "parent": 0}]},
            "skin": {"bind": [(golfer.qconj(root_q), (0, 0, 0)), ((0, 0, 0, 1), (1, 0, 0))]}}
        skeleton = golfer.build_skeleton(character)
        child = skeleton["bones"][1]
        self.assertTrue(close(child["bind_world"]["translation"], (0, 1, 0)))
        m = child["inverse_bind_matrix"]
        self.assertTrue(close((m[12], m[13], m[14]), (-1, 0, 0)))
        self.assertEqual(skeleton["bones"][-1]["name"], "IG_Gball1")


class ClubTests(unittest.TestCase):
    def test_kind_from_set_suffixes(self):
        self.assertEqual(golfer.club_kind({"shadow": [0], "nike_dv": [1], "ea_dv": [2], "default": [3]}), "driver")
        self.assertEqual(golfer.club_kind({"cl_bb_wg": [1], "nike_pro_pwg": [2], "ea_wg": [3]}), "wedge")
        self.assertEqual(golfer.club_kind({"cl_bb_w": [1], "ea_w": [2]}), "fairway_wood")
        self.assertEqual(golfer.club_kind({"cl_bb_7I": [1]}), "iron7")
        with self.assertRaises(FormatError):
            golfer.club_kind({"shadow": [0], "default": [1]})

    def test_clb_header_and_sizes_validated(self):
        with self.assertRaises(FormatError):
            golfer.parse_clb(struct.pack("<4I", 2, 2, 2, 3))
        with self.assertRaises(FormatError):      # record sizes disagree
            golfer.parse_clb(struct.pack("<4I", 1, 1, 1, 1) + struct.pack("<IfII", 0, 0.7, 0x40, 0x50))
        with self.assertRaises(FormatError):      # implausible head length
            golfer.parse_clb(struct.pack("<4I", 1, 1, 1, 1) + struct.pack("<IfII", 0, 9.0, 0x40, 0x40))

    def test_hand_relative_club_channel_resolved_to_rig_space(self):
        quarter = (0.0, 0.0, math.sqrt(0.5), math.sqrt(0.5))      # +90 degrees about Z
        skeleton = {"bones": [
            {"name": "IG_rig", "parent": -1}, {"name": golfer.CLUB_HAND_BONE, "parent": 0},
            {"name": golfer.CLUB_ROOT_BONE, "parent": 0}]}
        pose = [((0, 0, 0, 1), (0, 0, 0)), (quarter, (1, 0, 0)), ((0, 0, 0, 1), (0, 1, 0))]
        self.assertFalse(golfer.resolve_club_space([list(pose)], skeleton, 0x02))
        frames = [list(pose)]
        self.assertTrue(golfer.resolve_club_space(frames, skeleton, golfer.SKA_CLUB_IN_RIGHT_HAND))
        q, t = frames[0][2]
        self.assertTrue(close(t, (0, 0, 0)))                     # hand (1,0,0) + rotated (0,1,0) -> (-1,0,0)
        self.assertTrue(close(q, quarter))
        world = golfer.world_pose(skeleton, frames[0])
        self.assertTrue(close(world[2][1], (0, 0, 0)))

    def test_pose_interpolation(self):
        half = (0.0, math.sin(math.pi / 4), 0.0, math.cos(math.pi / 4))
        frames = [[((0, 0, 0, 1), (0, 0, 0))], [(half, (2, 0, 0))]]
        mid = golfer.pose_at(frames, 30, 1 / 60)
        self.assertTrue(close(mid[0][1], (1, 0, 0)))
        self.assertTrue(close(mid[0][0], (0, math.sin(math.pi / 8), 0, math.cos(math.pi / 8))))
        self.assertEqual(golfer.pose_at(frames, 30, 5)[0][1], (2, 0, 0))


@unittest.skipUnless((MEDIA / "Golfer/chars/01char.xbx").is_file(), "original media absent")
class RealMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.character, cls.provenance = golfer.load_character(MEDIA, "01")
        cls.mesh = golfer.build_mesh(cls.character)
        cls.skeleton = golfer.build_skeleton(cls.character)

    def test_character_identity_and_counts(self):
        self.assertIn("EXPORTED\\HT.CHX", self.provenance["export_path"])
        self.assertEqual(self.provenance["chr_bytes"], 0x4BB00)
        self.assertEqual(len(self.mesh["vertices"]), 5959)
        self.assertEqual(len(self.mesh["triangles"]), 6900)
        self.assertEqual(len(self.skeleton["bones"]), 102)
        self.assertEqual(self.character["model"]["sets"]["GloveOn"], [1])

    def test_bind_pose_dimensions(self):
        ys = [v[0][1] for v in self.mesh["vertices"]]
        self.assertAlmostEqual(max(ys) - min(ys), 2.04, places=2)
        head = next(b for b in self.skeleton["bones"] if b["name"] == "IG_Head")
        self.assertGreater(head["bind_world"]["translation"][1], 0.7)
        foot = next(b for b in self.skeleton["bones"] if b["name"] == "IG_LFoot")
        self.assertLess(foot["bind_world"]["translation"][1], -0.9)
        self.assertGreater(foot["bind_world"]["translation"][0], 0)  # character's left is +X

    def test_all_motion_clips_parse_exactly(self):
        motions = (MEDIA / "Golfer/chars/motions.tbf").read_bytes()
        entries = golfer.read_tbf(motions)
        self.assertEqual(len(entries), 1166)
        for name, (offset, size) in entries.items():
            clip = golfer.parse_ska(motions[offset:offset + size])
            self.assertIn(clip["channels"], (101, 102, 103), name)
        offset, size = entries["tdlful50.ska"]
        clip = golfer.parse_ska(motions[offset:offset + size])
        self.assertEqual(clip["frame_count"], 321)
        self.assertEqual(golfer.swing_phases(clip)["downswing"], [48, 63])

    def test_textures_decode(self):
        fxx = (MEDIA / "Golfer/CHARTEX/01alltex.fxx").read_bytes()
        entry = self.character["textures"]["htface"]
        w, h, rgba = golfer.decode_texture(fxx, entry)
        self.assertEqual((w, h), (256, 256))
        self.assertEqual(len(rgba), 256 * 256 * 4)

    def test_run_writes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = golfer.run(MEDIA, Path(tmp), "01", ["tdlful50"], None, False)
            mesh = golfer.read_mesh((Path(tmp) / "golfer_mesh.bin").read_bytes())
            self.assertEqual(len(mesh["vertices"]), 5959)
            clip = golfer.read_clip((Path(tmp) / "clips/tdlful50.pgaclip").read_bytes())
            self.assertEqual(len(clip["poses"]), 321)
            self.assertEqual(manifest["mesh"]["triangles"], 6900)
            self.assertTrue((Path(tmp) / "textures/htface.png").is_file())
            clubs = golfer.read_mesh((Path(tmp) / "club_mesh.bin").read_bytes())
            self.assertEqual(len(clubs["submeshes"]), len(manifest["clubs"]["submeshes"]))
            self.assertTrue((Path(tmp) / "textures/nikeigndvr.png").is_file())

    def test_clubs_decode_with_their_head_lengths(self):
        clubs, source = golfer.load_clubs(MEDIA)
        self.assertEqual(source["clb_bytes"], 0xA1070)
        lengths = {c["kind"]: round(c["head_length"], 3) for c in clubs}
        self.assertEqual(lengths, {"driver": 0.717, "fairway_wood": 0.717, "putter": 0.486,
                                   "iron3": 0.586, "iron7": 0.522, "wedge": 0.498})
        mesh = golfer.build_club_mesh(clubs, self.skeleton, golfer.TIGER_CLUB_HEADS)
        self.assertEqual(set(mesh["clubs"]), set(lengths))
        for sub in mesh["submeshes"]:
            self.assertTrue(set(sub["bones"]) <= {98, 99, 100}, sub)
        heads = [s for s in mesh["submeshes"] if s["part"] == "head"]
        self.assertTrue(all(s["bones"] == [100] for s in heads))

    def test_full_swings_meet_the_ball_at_impact(self):
        """Hand-relative club channels plus per-club head lengths put the club
        on the ball (rig origin) at each clip's impact event."""
        clubs, _ = golfer.load_clubs(MEDIA)
        mesh = golfer.build_club_mesh(clubs, self.skeleton, golfer.TIGER_CLUB_HEADS)
        motions = (MEDIA / "Golfer/chars/motions.tbf").read_bytes()
        entries = golfer.read_tbf(motions)
        for kind, (swing, address) in golfer.CLUB_MOTIONS.items():
            offset, size = entries[swing + ".ska"]
            clip = golfer.parse_ska(motions[offset:offset + size])
            frames, _ = golfer.clip_poses(clip, self.skeleton)
            impact = next(t for i, t in clip["events"] if i == 2)
            pose = golfer.pose_at(frames, 1 / clip["seconds_per_frame"], impact)
            low = golfer.club_contact(self.skeleton, pose, mesh["clubs"][kind], mesh)
            self.assertLess(math.hypot(low[0], low[2]), 0.2, (kind, swing, low))
            self.assertLess(abs(low[1]), 0.15, (kind, swing, low))
            offset, size = entries[address + ".ska"]
            clip = golfer.parse_ska(motions[offset:offset + size])
            frames, _ = golfer.clip_poses(clip, self.skeleton)
            low = golfer.club_contact(self.skeleton, frames[-1], mesh["clubs"][kind], mesh)
            self.assertLess(abs(low[1]), 0.05, (kind, address, low))       # soled at address
            self.assertLess(math.hypot(low[0], low[2]), 0.15, (kind, address, low))


if __name__ == "__main__":
    unittest.main()
