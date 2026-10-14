"""Tests for the .x parser and the vegetation/sky decoder.

Synthetic fixtures always run. Real-data checks run only when the ignored
original media (and, for floor checks, the generated terrain.ghpc) exist.
"""
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import pga2005_xfile as X  # noqa: E402
from decode_pga2005_library import CourseFile  # noqa: E402
from import_pga2005 import decode_dds  # noqa: E402
import decode_pga2005_objects as O  # noqa: E402

MEDIA = ROOT / "Library/SourceMedia/pga2005"
PBL = MEDIA / "disc3/COURSES/PBL"
INSTALL = MEDIA / "install"

TEXT_X = b"""xof 0303txt 0032
template Unused { <11111111-2222-3333-4444-555555555555> DWORD a; }
Frame Root {
 FrameTransformMatrix { 1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1;; }
 Frame Child {
  FrameTransformMatrix { 2,0,0,0, 0,2,0,0, 0,0,2,0, 0,0,0,1;; }
  Mesh Leafy {
   7;
   0;0;0;, 2;0;0;, 0;2;0;, 2;2;0;,
   5;5;5;, 6;5;5;, 5;6;5;;
   3;
   3;0,1,2;, 3;1,3,2;, 3;4,5,6;;
   MeshNormals { 2; 0;0;1;, 0;1;0;; 3; 3;0,0,0;, 3;0,0,0;, 3;1,1,1;; }
   MeshTextureCoords { 7; 0;1;, 1;1;, 0;0.5;, 1;0.5;, 0;0;, 1;0;, 0;1;; }
   MeshVertexColors { 1; 4;1.0;0.5;0.25;1.0;;; }
   MeshMaterialList { 2; 3; 0, 0, 1;
    Material { 1;1;1;1;; 4.0; 0;0;0;; 0;0;0;; TextureFilename { "C:/art/leaf.tga"; } }
    Material { 0.5;0.5;0.5;1;; 2.0; 0;0;0;; 0;0;0;; TextureFilename { "bark.tga"; } }
   }
  }
 }
}
"""


def binary_x(name=b"Tri"):
    """Hand-built binary .x: one Frame containing a one-triangle textured Mesh."""
    out = bytearray(b"xof 0303bin 0032")

    def token(t):
        out.extend(struct.pack("<H", t))

    def name_token(text):
        token(1)
        out.extend(struct.pack("<I", len(text)) + text)

    def ints(*values):
        token(6)
        out.extend(struct.pack("<I", len(values)) + struct.pack(f"<{len(values)}I", *values))

    def floats(*values):
        token(7)
        out.extend(struct.pack("<I", len(values)) + struct.pack(f"<{len(values)}f", *values))

    name_token(b"Frame"); name_token(b"Root"); token(10)
    name_token(b"Mesh"); name_token(name); token(10)
    ints(3); floats(0, 0, 0, 1, 0, 0, 0, 1, 0); ints(1, 3, 0, 1, 2)
    name_token(b"MeshTextureCoords"); token(10); ints(3); floats(0, 0, 1, 0, 0, 1); token(11)
    name_token(b"MeshMaterialList"); token(10); ints(1, 1, 0)
    name_token(b"Material"); token(10); floats(1, 1, 1, 1, 8, 0, 0, 0, 0, 0, 0)
    name_token(b"TextureFilename"); token(10)
    token(2); out.extend(struct.pack("<I", 9) + b"tex.tga\0\0"); token(20)   # string + WORD ';'
    token(11); token(11); token(11)
    token(11); token(11)
    return bytes(out)


class XFileTests(unittest.TestCase):
    def test_text_frames_meshes_normals_uvs_materials(self):
        xf = X.parse(TEXT_X)
        self.assertEqual(xf.format, "txt")
        self.assertIn("Unused", xf.templates)
        mesh, = xf.meshes()
        self.assertEqual(mesh.name, "Leafy")
        self.assertEqual(mesh.frame_path, ["Root", "Child"])
        self.assertEqual(mesh.matrix[12:15], [10.0, 20.0, 30.0], "Child scale then parent translation")
        self.assertEqual(mesh.matrix[0], 2.0)
        self.assertEqual(mesh.faces, [[0, 1, 2], [1, 3, 2], [4, 5, 6]])
        self.assertEqual(mesh.face_materials, [0, 0, 1])
        self.assertEqual([m.textures for m in mesh.materials], [["C:/art/leaf.tga"], ["bark.tga"]])
        self.assertEqual(mesh.colors[4], (1.0, 0.5, 0.25, 1.0))
        arrays = mesh.render_arrays(apply_matrix=True)
        self.assertEqual(len(arrays["indices"]), 9)
        self.assertEqual(arrays["material_ranges"], [(0, 0, 6), (1, 6, 3)])
        self.assertEqual(arrays["positions"][0], (10.0, 20.0, 30.0))
        self.assertEqual(arrays["positions"][1], (14.0, 20.0, 30.0))
        self.assertAlmostEqual(arrays["normals"][-1][1], 1.0)

    def test_binary_matches_text_semantics_and_word_string_terminator(self):
        xf = X.parse(binary_x())
        self.assertEqual(xf.format, "bin")
        mesh, = xf.meshes()
        self.assertEqual(mesh.positions, [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
        self.assertEqual(mesh.faces, [[0, 1, 2]])
        self.assertEqual(mesh.uvs[2], (0.0, 1.0))
        self.assertEqual(mesh.materials[0].textures, ["tex.tga"])
        self.assertEqual(mesh.materials[0].power, 8.0)

    def test_rejects_malformed_inputs(self):
        with self.assertRaises(X.XFileError):
            X.parse(b"xof 0303tzip0032" + b"\0" * 8)
        with self.assertRaises(X.XFileError):
            X.parse(b"not an x file at all")
        with self.assertRaises(X.XFileError):
            X.parse(TEXT_X.replace(b"3;4,5,6;;", b"3;4,5,9;;")).meshes()
        with self.assertRaises(X.XFileError):
            X.parse(binary_x()[:-6])
        with self.assertRaises(X.XFileError):
            X.parse(TEXT_X.replace(b'"bark.tga"', b"12"))

    def test_top_level_material_reference(self):
        data = TEXT_X.replace(b"Frame Root {", b"Material Shared { 0;1;0;1;; 1.0; 0;0;0;; 0;0;0;; }\nFrame Root {")
        data = data.replace(b'Material { 0.5;0.5;0.5;1;; 2.0; 0;0;0;; 0;0;0;; TextureFilename { "bark.tga"; } }',
                            b"{ Shared }")
        mesh, = X.parse(data).meshes()
        self.assertEqual(mesh.materials[1].name, "Shared")
        self.assertEqual(mesh.materials[1].face_color, (0.0, 1.0, 0.0, 1.0))

    def test_matrix_helpers(self):
        a = X.IDENTITY[:]
        a[12:15] = [1.0, 2.0, 3.0]
        b = [0.0] * 16
        b[0] = b[5] = b[10] = 2.0
        b[15] = 1.0
        self.assertEqual(X.multiply(a, b)[12:15], [2.0, 4.0, 6.0])


# --------------------------------------------------------------- fixtures

def dds_argb(pixels):
    """1-row A8R8G8B8 DDS from (r, g, b, a) tuples."""
    width = len(pixels)
    header = bytearray(128)
    header[:4] = b"DDS "
    struct.pack_into("<6I", header, 4, 124, 0x100f, 1, width, width * 4, 0)
    struct.pack_into("<I", header, 28, 1)
    struct.pack_into("<II4sIIIII", header, 76, 32, 0x41, b"\0" * 4, 32, 0xff0000, 0xff00, 0xff, 0xff000000)
    struct.pack_into("<I", header, 108, 0x1000)
    body = b"".join(bytes((b, g, r, a)) for r, g, b, a in pixels)
    return bytes(header) + body


def tree_x():
    return TEXT_X.replace(b"FrameTransformMatrix { 1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1;; }",
                          b"FrameTransformMatrix { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1;; }") \
                 .replace(b"FrameTransformMatrix { 2,0,0,0, 0,2,0,0, 0,0,2,0, 0,0,0,1;; }",
                          b"FrameTransformMatrix { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1;; }")


def small_poly(material, width=4.0, height=10.0):
    """tagPolyObject with one 8-point/4-face crossed-quad group (32-byte points)."""
    points = [(-width / 2, 0, 0, 0xffffffff, 0, 1), (width / 2, 0, 0, 0xffffffff, 1, 1),
              (-width / 2, height, 0, 0xffffffff, 0, 0), (width / 2, height, 0, 0xffffffff, 1, 0)] * 2
    data = bytearray(0x3d + 0x2c)
    struct.pack_into("<6f", data, 0, -width / 2, 0, -1, width / 2, height, 1)
    struct.pack_into("<II", data, 0x18, 1, 8)
    vertex_offset = len(data)
    for x, y, z, c, u, v in points:
        data += struct.pack("<3fI2f2f", x, y, z, c, u, v, 0, 0)
    index_offset = len(data)
    data += struct.pack("<12H", 0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6)
    struct.pack_into("<IiIiII", data, 0x3d, 0, index_offset, 4, vertex_offset, 8, material)
    return bytes(data)


def course_fixture():
    guid = bytes(range(16))
    textures = [("leaf.tga", 0x500008, (0, 255, 0, 0)), ("bark.tga", 0x2, (90, 60, 30, 255)),
                ("obtest.x.tga", 0x400009, (0, 128, 0, 200))]
    # ---- TCL
    tcl = bytearray(0x600)
    struct.pack_into("<H", tcl, 0, 7)
    tcl[2:18] = guid
    struct.pack_into("<H", tcl, 0x50, len(textures))
    struct.pack_into("<H", tcl, 0x48, 1)
    names, images, sections, surfaces = 0x330, 0x370, 0x3b0, 0x4b0
    struct.pack_into("<I", tcl, 0x7c, names)
    struct.pack_into("<I", tcl, 0x80, images)
    struct.pack_into("<I", tcl, 0xe4, sections)
    struct.pack_into("<I", tcl, 0x78, 0x5c0)
    for i, (name, flags, color) in enumerate(textures):
        section = sections + i * 83
        struct.pack_into("<I", tcl, section + 0xa, flags)
        struct.pack_into("<HI", tcl, section + 0x4d, 1, surfaces + i * 68)
        struct.pack_into("<10f", tcl, surfaces + i * 68, *([0.5] * 10))
    struct.pack_into("<I", tcl, 0x3e, 0x600)
    payloads = []
    for i, (name, flags, color) in enumerate(textures):
        payloads.append((names + i * 19, name.encode() + b"\0"))
        dds = dds_argb([color] * 4)
        payloads.append((images + i * 19, struct.pack("<I", len(dds)) + dds))
    x_bytes = tree_x()
    tree = struct.pack("<IIf", 12, 12 + len(x_bytes), 1.0) + x_bytes
    payloads.append((0x5c0, tree))
    for descriptor, payload in payloads:
        struct.pack_into("<IIIIHB", tcl, descriptor, len(tcl), len(tcl), len(tcl), len(payload), 0, 0)
        tcl += payload
    # ---- TCR
    patch_table = 0x400
    header_bytes = patch_table + 0x136
    tcr = bytearray(header_bytes)
    struct.pack_into("<H", tcr, 0, 7)
    tcr[2:18] = bytes(16)
    struct.pack_into("<I", tcr, 0x3e, header_bytes)
    struct.pack_into("<HH", tcr, 0x46, 1, 1)                      # 1 patch, 1 object type
    struct.pack_into("<H", tcr, 0x50, 3)                          # 3 materials
    struct.pack_into("<H", tcr, 0x5e, 1)
    tcr[0x10c:0x11c] = guid
    struct.pack_into("<I", tcr, 0x104, patch_table)
    struct.pack_into("<IIIII", tcr, 0x80, 0x3c0, 0, 0, 0, 0)
    for material in range(3):                                     # material m -> TCL texture m
        struct.pack_into("<H", tcr, 0x3c0 + material * 19 + 4, material)
    for field, location in ((0x6c, 0x350), (0x78, 0x370), (0x70, 0x390)):
        struct.pack_into("<I", tcr, field, location)
        struct.pack_into("<IIIIHB", tcr, location, 0, 0, 0, 0, 0, 0)   # library object 0, library 0
    patch = bytearray()
    records = [(100, 4, -50, 2.0, 1, 0, 90, 4, -60, 110, 24, -40),
               (-200, 3, 300, 0.5, 5, 0, -205, 3, 295, -195, 8, 305)]
    for record in records:
        patch += struct.pack("<hhhfBBhhhhhh", *record)
    patch_source = len(tcr)
    tcr += patch
    small = small_poly(2)
    small_source = len(tcr)
    tcr += small
    struct.pack_into("<IIIIHB", tcr, 0x390, small_source, 0, small_source, len(small), 0, 0)
    struct.pack_into("<H", tcr, 0x68, 1)                          # one panorama block (reuses the quad)
    struct.pack_into("<I", tcr, 0x84, 0x330)
    struct.pack_into("<IIIIHB", tcr, 0x330, small_source, 0, small_source, len(small), 0, 0)
    base = patch_table
    struct.pack_into("<IIII", tcr, base, patch_source, patch_source, patch_source, len(patch))
    struct.pack_into("<ii", tcr, base + 0x13, 1000, 2000)        # origin x, z
    struct.pack_into("<i", tcr, base + 0x4d, 500)                # origin y
    struct.pack_into("<h", tcr, base + 0x2f, len(records))
    struct.pack_into("<I", tcr, base + 0x55, 0)
    struct.pack_into("<H", tcr, base + 0x61, 0x3)                # hole 3, base layer
    struct.pack_into("<I", tcr, base + 0x89, len(patch))
    return bytes(tcr), bytes(tcl)


def ghpc_fixture(layer=3, height=503.0):
    vertices = [(0.0, height, 0.0), (5000.0, height, 0.0), (0.0, height, 5000.0), (-5000.0, height, -5000.0)]
    triangles = [(0, 1, 2, 7), (0, 2, 3, 7), (0, 3, 1, 7)]
    out = bytearray(b"GHPC" + struct.pack("<IIII6fI", 3, len(vertices), len(triangles), 1,
                                          -5000, height, -5000, 5000, height, 5000, 1))
    for v in vertices:
        out += struct.pack("<3f4B2f", *v, 0, 0, 0, 255, 0, 0)
    for t in triangles:
        out += struct.pack("<4I", *t)
    out += struct.pack("<5I", layer, 0, len(vertices), 0, len(triangles))
    return bytes(out)


class ObjectDecoderTests(unittest.TestCase):
    def test_instances_origin_rotation_scale_and_layer(self):
        tcr, _ = course_fixture()
        rows, info = O.decode_instances(CourseFile(tcr, "TCR"))
        self.assertEqual(len(rows), 2)
        first, second = rows
        self.assertEqual(first["position"], (1100, 504, 1950))
        self.assertEqual(first["bounds_min"], (1090, 504, 1940))
        self.assertEqual((first["hole"], first["layer"], first["type"]), (3, 3, 0))
        self.assertEqual(first["rotation_index"], 1)
        self.assertEqual(second["rotation_byte"], 5)
        self.assertEqual(second["rotation_index"], 0, "byte 5 wraps to 2*pi -> index 0")
        self.assertAlmostEqual(first["scale"], 2.0)
        self.assertEqual(info["trailing_duplicate_bytes"], 0)

    def test_instance_matrix_matches_compute_tree_matrix(self):
        m = O.instance_matrix((10, 20, 30), 1, 2.0)
        a = O.ROTATION_STEP
        x = 1 * m[0] + 0 * m[4] + 0 * m[8] + m[12]
        z = 1 * m[2] + 0 * m[6] + 0 * m[10] + m[14]
        self.assertAlmostEqual(x, 10 + 2 * math.cos(a))
        self.assertAlmostEqual(z, 30 - 2 * math.sin(a))
        self.assertEqual(m[5], 2.0)
        self.assertAlmostEqual(O.ROTATION_STEP, 2 * math.pi / 5, places=6)

    def test_course_decode_models_leaf_cards_billboard_and_ghom(self):
        tcr, tcl = course_fixture()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            result = O.decode_course_objects(tcr, [tcl], out, b"[HOLE 3]\nHolePanId=1\nPanRotate=0\n")
            objects = result["objects"]
            self.assertEqual(objects["summary"]["instances"], 2)
            pan = objects["panoramas"]
            self.assertEqual(len(pan["blocks"]), 1)
            self.assertEqual(pan["blocks"][0]["groups"][0]["texture_name"], "obtest.x.tga")
            self.assertEqual(pan["per_hole_ini"], {"3": {"HolePanId": "1", "PanRotate": "0"}})
            model = objects["models"]["0:0"]
            self.assertEqual(model["name"], "obtest")
            lod0, = model["lods"]
            self.assertEqual(lod0["leaf_count"], 1)
            self.assertEqual(lod0["triangle_count"], 1)
            kinds = {m["texture_name"]: m["kind"] for m in lod0["materials"]}
            self.assertEqual(kinds, {"leaf.tga": "leaf_card", "bark.tga": "mesh"})
            mesh = O.read_ghom((out / lod0["mesh"]).read_bytes())
            center, half = mesh["leaves"][0][0:3], mesh["leaves"][0][3]
            self.assertEqual(center, (1.0, 1.0, 0.0))
            self.assertEqual(half, 1.0)
            self.assertEqual(mesh["leaves"][0][4:8], (0.0, 0.0, 1.0, 0.5), "1-v: top-left uv origin")
            self.assertEqual(len(mesh["indices"]), 3)
            self.assertEqual(mesh["ranges"], [(1, 0, 3)])
            self.assertEqual(mesh["vertices"][0][8:12], (255, 128, 64, 255))
            billboard = model["billboard"]
            self.assertEqual(billboard["texture_name"], "obtest.x.tga")
            self.assertEqual(billboard["width_local"], 4.0)
            self.assertEqual(billboard["tcr_material"], 2)
            self.assertEqual([m["tcr_material"] for m in lod0["materials"]], [0, 1])
            leaf_texture = next(t for t in objects["textures"] if t["name"] == "leaf.tga")
            self.assertEqual(leaf_texture["alpha"]["fraction_cut"], 1.0)
            self.assertTrue((out / leaf_texture["texture"]).exists())
            rows = result["instances"]["holes"]["3"]
            self.assertEqual(rows[0][:6], [0, 1100, 504, 1950, 1, 2.0])
            floor = O.validate_floor(result["instance_rows"], ghpc_fixture())
            self.assertEqual(floor["checked"], 2)
            self.assertAlmostEqual(floor["max_abs"], 1.0, places=3)
            other_hole = O.validate_floor(result["instance_rows"], ghpc_fixture(layer=4))
            self.assertEqual(other_hole["no_floor"], 2, "a different hole's floor must not be used")
            bounds = O.validate_bounds(result, out)
            self.assertEqual(bounds["instances"], 2)

    def test_layer_predicate(self):
        self.assertTrue(O.accepts(0x3, 0x423))
        self.assertTrue(O.accepts(0x23, 0x423))
        self.assertFalse(O.accepts(0x43, 0x423))
        self.assertFalse(O.accepts(0x4, 0x423))

    def test_ghom_round_trip_and_size_check(self):
        vertices = [((0, 0, 0), (0, 1, 0), (0, 0), (1, 2, 3, 4)), ((1, 0, 0), (0, 1, 0), (1, 0), (1, 2, 3, 4)),
                    ((0, 1, 0), (0, 1, 0), (0, 1), (1, 2, 3, 4))]
        data = O.ghom_bytes(vertices, [0, 1, 2], [(0, 0, 3)], [((0, 5, 0), 2.0, (0, 0), (1, 1), 1)])
        mesh = O.read_ghom(data)
        self.assertEqual(len(data), 64 + 3 * 36 + 12 + 12 + 36)
        self.assertEqual(mesh["bounds_max"], (2.0, 7.0, 2.0))
        self.assertEqual(mesh["leaves"][0][8], 1)
        with self.assertRaises(ValueError):
            O.read_ghom(data[:-1])
        with self.assertRaises(ValueError):
            O.ghom_bytes(vertices, [0, 1, 3], [], [])

    def test_sky_pan_block_and_fast_dds_path(self):
        guid = bytes(range(16, 32))
        tcl = bytearray(0x500)
        struct.pack_into("<H", tcl, 0, 7)
        tcl[2:18] = guid
        struct.pack_into("<HH", tcl, 0x50, 1, 0)
        struct.pack_into("<H", tcl, 0x68, 1)
        struct.pack_into("<I", tcl, 0x7c, 0x330)
        struct.pack_into("<I", tcl, 0x80, 0x350)
        struct.pack_into("<I", tcl, 0x84, 0x370)
        struct.pack_into("<I", tcl, 0xe4, 0x390)
        struct.pack_into("<I", tcl, 0x390 + 0xa, 0x1003)
        struct.pack_into("<HI", tcl, 0x390 + 0x4d, 1, 0x400)
        struct.pack_into("<I", tcl, 0x3e, 0x500)
        pixels = [(10, 20, 30, 40), (200, 100, 50, 255)]
        dds = dds_argb(pixels)
        self.assertEqual(O.decode_dds_fast(dds), decode_dds(dds))
        pan = bytearray(small_poly(0))
        pan[0x20:0x29] = b"test.obj\0"
        for descriptor, payload in ((0x330, b"cloud.tga\0"), (0x350, struct.pack("<I", len(dds)) + dds),
                                    (0x370, bytes(pan))):
            struct.pack_into("<IIIIHB", tcl, descriptor, len(tcl), len(tcl), len(tcl), len(payload), 0, 0)
            tcl += payload
        with tempfile.TemporaryDirectory() as directory:
            sky = O.decode_sky(bytes(tcl), Path(directory),
                               render_presets={"render1.ini": b"#Clear\n[SKY]\nSKYTYPE=1\n"},
                               course_ini=b"[SkyDome]\nScaleX=1\nYOffset=1\n")
            dome, = sky["domes"]
            self.assertEqual((dome["sky_type"], dome["name"]), (1, "test.obj"))
            group, = dome["groups"]
            self.assertTrue(group["cloud_layer"] and group["alpha_blend"])
            mesh = O.read_ghom((Path(directory) / dome["mesh"]).read_bytes())
            self.assertEqual(mesh["flags"], 0)
            self.assertEqual(len(mesh["indices"]), 12)
            self.assertEqual(mesh["vertices"][0][8:12], (255, 255, 255, 255))
            self.assertEqual(sky["render_presets"][0]["SKY.SKYTYPE"], "1")
            self.assertEqual(sky["course_ini"]["SkyDome"]["YOffset"], "1")


@unittest.skipUnless((INSTALL / "Data-Golfball/ball01.x").exists(), "original install media absent")
class RealXFileTests(unittest.TestCase):
    def test_ball_and_tee(self):
        ball, = X.load(INSTALL / "Data-Golfball/ball01.x").meshes()
        self.assertEqual((len(ball.positions), len(ball.faces)), (2113, 1076))
        tee, = X.load(INSTALL / "Courses_-_Generic/tee01.x").meshes()
        self.assertEqual((len(tee.positions), len(tee.faces)), (32, 48))
        self.assertTrue(tee.materials[0].textures[0].endswith("tee.tga"))
        self.assertEqual(len(tee.render_arrays()["indices"]), sum(len(f) - 2 for f in tee.faces) * 3)

    def test_every_supplied_x_file_parses(self):
        for path in sorted(MEDIA.rglob("*.x")):
            with self.subTest(path=path.name):
                for mesh in X.load(path).meshes():
                    mesh.render_arrays(apply_matrix=True)


@unittest.skipUnless((PBL / "PBL.TCR").exists() and (PBL / "PBL.TCL").exists(), "PBL course media absent")
class RealPebbleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tcr = (PBL / "PBL.TCR").read_bytes()
        cls.tcl = (PBL / "PBL.TCL").read_bytes()

    def test_instance_counts_types_and_layers(self):
        rows, _ = O.decode_instances(CourseFile(self.tcr, "TCR"))
        self.assertEqual(len(rows), 45063)
        self.assertEqual(sorted({r["hole"] for r in rows}), list(range(1, 19)))
        self.assertEqual({r["layer"] & ~0x1f for r in rows}, {0})
        self.assertEqual(max(r["type"] for r in rows), 20)
        per_hole = {h: sum(1 for r in rows if r["hole"] == h) for h in range(1, 19)}
        self.assertEqual((per_hole[1], per_hole[7], per_hole[18]), (2597, 2265, 1877))

    def test_tree_models_leaf_textures_and_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            result = O.decode_course_objects(self.tcr, [self.tcl], out)
            objects = result["objects"]
            self.assertEqual(objects["summary"]["object_types"], 21)
            names = {m["name"] for m in objects["models"].values()}
            self.assertIn("obtree01", names)
            self.assertIn("obbush02", names)
            for model in objects["models"].values():
                self.assertEqual([l["lod"] for l in model["lods"]], [0, 1, 2])
                self.assertGreater(model["lods"][0]["leaf_count"], 0)
            leaves = [t for t in objects["textures"] if t["section_flags"] & O.LEAF_SECTION_FLAG]
            self.assertTrue(leaves)
            for texture in leaves:
                self.assertGreater(texture["alpha"]["fraction_cut"], 0.2, texture["name"])
                self.assertLess(texture["alpha"]["fraction_cut"], 0.9, texture["name"])
            terrain = ROOT / "Library/Imported/pga2005/PBL/terrain.ghpc"
            if terrain.exists():
                hole7 = [r for r in result["instance_rows"] if r["hole"] == 7]
                floor = O.validate_floor(hole7, terrain.read_bytes())
                self.assertEqual(floor["no_floor"], 0)
                self.assertLessEqual(floor["max_abs"], 2.5)


@unittest.skipUnless((INSTALL / "CoursesRoot/skydome.TCL").exists(), "sky media absent")
class RealSkyTests(unittest.TestCase):
    def test_eight_domes_and_stormy_cloud_layers(self):
        with tempfile.TemporaryDirectory() as directory:
            sky = O.decode_sky((INSTALL / "CoursesRoot/skydome.TCL").read_bytes(), Path(directory))
            self.assertEqual(len(sky["domes"]), 8)
            self.assertEqual(sky["domes"][0]["groups"][0]["texture_name"], "sunny.tga")
            stormy = sky["domes"][5]
            self.assertEqual([g["cloud_layer"] for g in stormy["groups"]], [False, True, True])
            json.dumps(sky)


if __name__ == "__main__":
    unittest.main()
