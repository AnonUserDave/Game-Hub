#!/usr/bin/env python3
"""Decode original PGA Tour 2005 vegetation instances, tree meshes and the sky dome.

Static, standard-library decoder. Nothing from the original game executes.
Layouts come from CourseData.dll/Engine.dll analysis recorded in
docs/research/PGA2005-OBJECTS.md (addresses, confidence, open questions).

Course trees (all PBL "objects" are vegetation; houses, rails and ball washers
are baked into the terrain patches):

* Instances are per-patch ``tagSurfaceStructureCompressed`` records (24 bytes)
  at patch payload offset ``u32(desc+0x55)``, count ``s16(desc+0x2f)``
  (``tagPatch::Num3DTrees``). Positions are s16 offsets from the patch's
  integer origin (``desc+0x13`` x, ``desc+0x4d`` y, ``desc+0x17`` z). Each
  instance inherits its patch's ``PatchLayerInfoS`` (``desc+0x61``), so it
  belongs to one hole world exactly like the terrain.
* Instance type ``k`` indexes the TCR object tables (count ``u16 hdr+0x48``).
  TCR ``+0x6c``/``+0x78`` 19-byte descriptors give the library object index
  (``+4``) and library number (``+18 >> 2``).
* Renderable tree LODs are embedded binary DirectX ``.x`` files in the TCL:
  ``+0x78`` LOD0 (skinned, optional animation), ``+0x88`` LOD1, ``+0xd4``
  LOD2 (library version > 4). Leaf materials (texture-section flag
  ``0x100000``) are converted to camera-facing leaf cards as
  ``CTreeSkinMesh::CreateCleanPoints`` does. LOD3 is a camera-facing
  cylindrical billboard sized from the TCR ``+0x70`` "small" polyObject.

Sky: ``Courses\\Skydome.tcl`` pan blocks (``hdr+0x84``, count ``hdr+0x68``)
are polyObject domes; the active block is ``SKYTYPE - 1``.

Outputs (raw, left-handed source inches like terrain.ghpc):
``<course>/objects/{objects.json,instances.json,meshes/*.ghom,textures/*}``
and ``sky/{sky.json,meshes/*.ghom,textures/*}``. GHOM is documented in
``GHOM_FORMAT`` below and in the research note.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_pga2005_library import CourseFile, surface_records  # noqa: E402
from import_pga2005 import atomic_write, decode_dds, png_bytes  # noqa: E402
import pga2005_xfile  # noqa: E402

COURSE_DLL_SHA256 = "36664435b88646e6b96d55f81573e1fdb73ee88e7f54762c4a723c693832e82c"
ENGINE_DLL_SHA256 = "94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728"
DESCRIPTOR_BYTES = 19
PATCH_STRIDE = 0x136
SURFACE_STRUCTURE_BYTES = 24
POLY_GROUP_BYTES = 0x2c
POLY_GROUPS = 0x3d
ROTATION_STEP = struct.unpack("<f", bytes.fromhex("7cd9a03f"))[0]   # 2*pi/5 as float32 (0x1002adb0, 0x102d96bc)
STANDARD_SELECTOR = 0x420
LEAF_SECTION_FLAG = 0x100000
TREE_SECTION_FLAG = 0x8
CLOUD_SECTION_FLAG = 0x1000
ALPHA_BLEND_SECTION_FLAG = 0x1
VEGETATION_ALPHA_REF = 150          # D3DRS_ALPHAREF 0x96 in CRVegetation::SetupRenderStates
TREE_LOD_DISTANCES = {"lod1": 540, "lod2": 1800, "lod3": 14400, "transition": 18000}

GHOM_MAGIC = b"GHOM"
GHOM_VERSION = 1
GHOM_HEADER = struct.Struct("<4s7I6f2I")      # 64 bytes
GHOM_VERTEX = struct.Struct("<3f3f2f4B")      # 36 bytes
GHOM_RANGE = struct.Struct("<3I")
GHOM_LEAF = struct.Struct("<3ff2f2fI")         # 36 bytes
GHOM_HAS_NORMALS = 1
GHOM_FORMAT = {
    "file": "*.ghom, little-endian",
    "header": "64 bytes: magic 'GHOM', u32 version=1, u32 vertex_count, u32 index_count, "
              "u32 range_count, u32 leaf_count, u32 vertex_stride=36, u32 flags (bit0 normals valid), "
              "f32 bounds_min[3], f32 bounds_max[3] (vertices and leaf-card extents), u32 reserved[2]",
    "vertex": "36 bytes: f32 position[3], f32 normal[3], f32 uv[2] (top-left origin, repeat), u8 rgba[4]",
    "indices": "u32[index_count], triangle list, clockwise front faces in the left-handed source frame",
    "ranges": "range_count x (u32 material, u32 first_index, u32 index_count); material indexes the JSON 'materials' list",
    "leaf_cards": "leaf_count x (f32 center[3], f32 half_size, f32 uv_min[2], f32 uv_max[2], u32 material); "
                  "draw each as a camera-facing square center +/- half_size along camera right/up; uv_min "
                  "is the top-left corner",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ------------------------------------------------------------------ helpers

def decode_dds_fast(dds: bytes):
    """A8R8G8B8 fast path (sky textures); everything else uses import_pga2005.decode_dds."""
    if len(dds) >= 128 and dds[:4] == b"DDS ":
        height, width = struct.unpack_from("<II", dds, 12)
        flags, fourcc, bits, rm, gm, bm, am = struct.unpack_from("<II4sIIII", dds, 80)
        if (flags & 0x40 and not flags & 4 and bits == 32 and (rm, gm, bm, am) ==
                (0xff0000, 0xff00, 0xff, 0xff000000) and 0 < width <= 8192 and 0 < height <= 8192):
            count = width * height * 4
            if 128 + count <= len(dds):
                src = dds[128:128 + count]
                out = bytearray(count)
                out[0::4], out[1::4], out[2::4], out[3::4] = src[2::4], src[1::4], src[0::4], src[3::4]
                return width, height, bytes(out)
    return decode_dds(dds)


def alpha_stats(rgba: bytes, reference: int = VEGETATION_ALPHA_REF) -> dict:
    alpha = rgba[3::4]
    total = len(alpha)
    histogram = [0] * 256
    for value in range(256):
        histogram[value] = alpha.count(value)
    below = sum(histogram[:reference])
    return {"pixels": total, "alpha_below_ref": below, "fraction_cut": round(below / total, 4) if total else 0,
            "alpha_zero": histogram[0], "alpha_full": histogram[255],
            "distinct_alpha_values": sum(1 for h in histogram if h)}


class TextureStore:
    """Writes each referenced library texture once as original DDS plus base-level PNG."""

    def __init__(self, root: Path, prefix: str = "textures"):
        self.root, self.prefix, self.entries = root, prefix, {}

    def add(self, key: str, name: str, dds: bytes, extra: dict | None = None) -> dict:
        if key in self.entries:
            return self.entries[key]
        stem = f"{self.prefix}/{key}"
        dds_path, png_path = self.root / (stem + ".dds"), self.root / (stem + ".png")
        width, height, rgba = decode_dds_fast(dds)
        if not (dds_path.exists() and dds_path.read_bytes() == dds and png_path.exists()):
            atomic_write(dds_path, dds)
            atomic_write(png_path, png_bytes(width, height, rgba))
        entry = {"key": key, "name": name, "texture": stem + ".png", "original_dds": stem + ".dds",
                 "width": width, "height": height,
                 "dds_fourcc": dds[84:88].decode("ascii", errors="replace").rstrip("\0") or "RGB",
                 "dds_sha256": sha256(dds), "rgba_sha256": sha256(rgba), "alpha": alpha_stats(rgba)}
        if extra:
            entry.update(extra)
        self.entries[key] = entry
        return entry


def library_texture(library: CourseFile, library_index: int, texture_index: int, store: TextureStore,
                    extra: dict | None = None) -> dict:
    count = library.u16(0x50)
    if not 0 <= texture_index < count:
        raise ValueError(f"Library {library_index}: texture index {texture_index} out of range")
    payload, descriptor = library.descriptor(0x80, texture_index)
    if len(payload) < 132 or payload[4:8] != b"DDS " or struct.unpack_from("<I", payload)[0] != len(payload) - 4:
        raise ValueError(f"Library {library_index} texture {texture_index}: unsupported payload")
    name_payload, _ = library.descriptor(0x7c, texture_index)
    _, section = surface_records(library, texture_index)
    info = {"library_index": library_index, "texture_index": texture_index,
            "section_flags": section["flags"], "source_descriptor": descriptor}
    info.update(extra or {})
    return store.add(f"library-{library_index}-texture-{texture_index:04d}", library.text(name_payload),
                     payload[4:], info)


def texture_names(library: CourseFile) -> dict[str, int]:
    names = {}
    for i in range(library.u16(0x50)):
        payload, _ = library.descriptor(0x7c, i)
        names.setdefault(library.text(payload).lower(), i)
    return names


def ordered_libraries(course: CourseFile, libraries: list[CourseFile]) -> list[CourseFile]:
    by_guid = {lib.guid_bytes: lib for lib in libraries}
    count = course.u16(0x5e)
    if not 0 < count <= 64:
        raise ValueError("Unsupported course library reference count")
    ordered = []
    for i in range(count):
        guid = course.range(0x10c + i * 16, 16, header=True)
        if guid not in by_guid:
            raise ValueError(f"Missing TCL for library GUID {uuid.UUID(bytes_le=guid)}")
        ordered.append(by_guid[guid])
    return ordered


def table_entry(file: CourseFile, field: int, index: int) -> dict:
    offset = file.u32(field) + index * DESCRIPTOR_BYTES
    file.range(offset, DESCRIPTOR_BYTES, header=True)
    source, location, data_location, count, references, flags = struct.unpack_from("<IIIIHB", file.data, offset)
    return {"descriptor_offset": offset, "source_offset": source, "index": location,
            "data_location": data_location, "bytes": count, "flags": flags, "library": flags >> 2}


def poly_object(data: bytes, label: str) -> dict:
    """tagPolyObject: bounds f32[6], u32 groups +0x18, 44-byte groups at +0x3d, 32-byte points."""
    if len(data) < POLY_GROUPS:
        raise ValueError(f"{label}: truncated polyObject")
    bounds = struct.unpack_from("<6f", data, 0)
    group_count = struct.unpack_from("<I", data, 0x18)[0]
    if group_count > 4096 or POLY_GROUPS + group_count * POLY_GROUP_BYTES > len(data):
        raise ValueError(f"{label}: invalid polyObject group count")
    groups = []
    for g in range(group_count):
        flags, index_offset, faces, vertex_offset, vertices, material = struct.unpack_from(
            "<IiIiII", data, POLY_GROUPS + g * POLY_GROUP_BYTES)
        if (index_offset < 0 or vertex_offset < 0 or index_offset + faces * 6 > len(data)
                or vertex_offset + vertices * 32 > len(data)):
            raise ValueError(f"{label}: group {g} escapes the payload")
        points = [struct.unpack_from("<3fI2f2f", data, vertex_offset + k * 32) for k in range(vertices)]
        triangles = [struct.unpack_from("<3H", data, index_offset + k * 6) for k in range(faces)]
        if any(i >= vertices for t in triangles for i in t):
            raise ValueError(f"{label}: group {g} index out of range")
        groups.append({"flags": flags, "material": material, "points": points, "triangles": triangles})
    return {"bounds": bounds, "groups": groups}


def name_from_texture_path(path: str) -> str:
    return path.replace("\\", "/").rsplit("/", 1)[-1].lower()


# --------------------------------------------------------------- GHOM files

def ghom_bytes(vertices: list, indices: list[int], ranges: list[tuple], leaves: list[tuple],
               has_normals: bool = True) -> bytes:
    extents = [v[0] for v in vertices]
    for center, half, *_ in leaves:
        extents.append(tuple(center[i] - half for i in range(3)))
        extents.append(tuple(center[i] + half for i in range(3)))
    lo = [min(p[i] for p in extents) if extents else 0.0 for i in range(3)]
    hi = [max(p[i] for p in extents) if extents else 0.0 for i in range(3)]
    if any(not 0 <= i < len(vertices) for i in indices) or len(indices) % 3:
        raise ValueError("GHOM index out of range or not a triangle list")
    out = bytearray(GHOM_HEADER.pack(GHOM_MAGIC, GHOM_VERSION, len(vertices), len(indices), len(ranges),
                                     len(leaves), GHOM_VERTEX.size, GHOM_HAS_NORMALS if has_normals else 0,
                                     *lo, *hi, 0, 0))
    for position, normal, uv, rgba in vertices:
        out += GHOM_VERTEX.pack(*position, *normal, *uv, *rgba)
    out += struct.pack(f"<{len(indices)}I", *indices)
    for material, first, count in ranges:
        out += GHOM_RANGE.pack(material, first, count)
    for center, half, uv_min, uv_max, material in leaves:
        out += GHOM_LEAF.pack(*center, half, *uv_min, *uv_max, material)
    return bytes(out)


def read_ghom(data: bytes) -> dict:
    """Reference reader used by tests and validation."""
    if len(data) < GHOM_HEADER.size:
        raise ValueError("Truncated GHOM header")
    magic, version, nv, ni, nr, nl, stride, flags, *rest = GHOM_HEADER.unpack_from(data, 0)
    if magic != GHOM_MAGIC or version != GHOM_VERSION or stride != GHOM_VERTEX.size:
        raise ValueError("Not a GHOM v1 file")
    expected = GHOM_HEADER.size + nv * stride + ni * 4 + nr * GHOM_RANGE.size + nl * GHOM_LEAF.size
    if expected != len(data):
        raise ValueError("GHOM size does not match its counts")
    offset = GHOM_HEADER.size
    vertices = [GHOM_VERTEX.unpack_from(data, offset + i * stride) for i in range(nv)]
    offset += nv * stride
    indices = list(struct.unpack_from(f"<{ni}I", data, offset))
    offset += ni * 4
    ranges = [GHOM_RANGE.unpack_from(data, offset + i * GHOM_RANGE.size) for i in range(nr)]
    offset += nr * GHOM_RANGE.size
    leaves = [GHOM_LEAF.unpack_from(data, offset + i * GHOM_LEAF.size) for i in range(nl)]
    return {"flags": flags, "bounds_min": tuple(rest[0:3]), "bounds_max": tuple(rest[3:6]), "vertices": vertices,
            "indices": indices, "ranges": ranges, "leaves": leaves}


def write_mesh(root: Path, data: bytes) -> str:
    path = f"meshes/mesh-{sha256(data)[:16]}.ghom"
    target = root / path
    if not (target.exists() and target.read_bytes() == data):
        atomic_write(target, data)
    return path


# ------------------------------------------------------------- tree meshes

def leaf_card(mesh, triangle) -> tuple:
    """CTreeSkinMesh::CreateCleanPoints (CourseData 0x100112e0): the leaf's first
    triangle gives the box; centre = box centre, half size = half the Y extent,
    UV rectangle = (min u, min 1-v) .. (max u, max 1-v)."""
    ps = [mesh.positions[i] for i in triangle]
    uvs = [mesh.uvs[i] if i < len(mesh.uvs) else (0.0, 0.0) for i in triangle]
    lo = [min(p[k] for p in ps) for k in range(3)]
    hi = [max(p[k] for p in ps) for k in range(3)]
    center = tuple((lo[k] + hi[k]) * 0.5 for k in range(3))
    flipped = [1.0 - uv[1] for uv in uvs]
    return (center, (hi[1] - lo[1]) * 0.5, (min(uv[0] for uv in uvs), min(flipped)),
            (max(uv[0] for uv in uvs), max(flipped)))


def build_tree_mesh(xfile: bytes, resolve) -> tuple[bytes, dict]:
    """Return GHOM bytes and metadata for one embedded tree .x LOD.

    ``resolve(texture_file_name) -> (material dict)`` must give at least
    ``section_flags``. Non-leaf triangles keep the file's per-vertex UVs
    (new-style trees are not V-flipped by TreeSkinnedMeshC::ChangeToTerrainVertex).
    """
    xf = pga2005_xfile.parse(xfile)
    materials, material_index = [], {}
    vertices, lookup, by_material, leaves = [], {}, {}, []
    stats = {"meshes": 0, "polygons": 0, "triangles": 0, "leaf_triangles": 0, "unpaired_leaf_triangles": 0,
             "leaf_pairs_without_shared_edge": 0, "bones": 0}
    for mesh in xf.meshes():
        stats["meshes"] += 1
        stats["bones"] += len(mesh.skin_weights)
        matrix = mesh.matrix
        local_materials = []
        for material in mesh.materials:
            texture = name_from_texture_path(material.textures[0]) if material.textures else ""
            key = texture
            if key not in material_index:
                info = dict(resolve(texture))
                info.update({"x_texture_file": material.textures[0] if material.textures else None,
                             "face_color": list(material.face_color), "power": material.power})
                material_index[key] = len(materials)
                materials.append(info)
            local_materials.append(material_index[key])
        if not local_materials:
            raise ValueError("Tree mesh without materials")
        normal_matrix = pga2005_xfile.normal_matrix(matrix)
        y_scale = math.sqrt(matrix[4] ** 2 + matrix[5] ** 2 + matrix[6] ** 2)
        first_leaf_triangle = {}
        has_normals = bool(mesh.normals) and len(mesh.normal_faces) == len(mesh.faces)
        pending_leaf = {}
        for f, face in enumerate(mesh.faces):
            stats["polygons"] += 1
            local = mesh.face_materials[f] if f < len(mesh.face_materials) else 0
            material = local_materials[local]
            leaf = bool(materials[material]["section_flags"] & LEAF_SECTION_FLAG)
            for k in range(1, len(face) - 1):
                corners = (0, k, k + 1)
                triangle = (face[0], face[k], face[k + 1])
                stats["triangles"] += 1
                if leaf:
                    stats["leaf_triangles"] += 1
                    # D3DX keeps two triangles per leaf; the first gives the card.
                    if material in pending_leaf:
                        del pending_leaf[material]
                        shared = {mesh.positions[i] for i in first_leaf_triangle[material]} & \
                            {mesh.positions[i] for i in triangle}
                        if len(shared) != 2:
                            stats["leaf_pairs_without_shared_edge"] += 1
                        continue
                    pending_leaf[material] = True
                    center, half, uv_min, uv_max = leaf_card(mesh, triangle)
                    c = pga2005_xfile.transform_point(center, matrix)
                    leaves.append((c, half * y_scale, uv_min, uv_max, material))
                    first_leaf_triangle[material] = triangle
                    continue
                out = by_material.setdefault(material, [])
                for vertex, corner in zip(triangle, corners):
                    normal_index = mesh.normal_faces[f][corner] if has_normals else -1
                    key = (id(mesh), vertex, normal_index)
                    index = lookup.get(key)
                    if index is None:
                        index = len(vertices)
                        lookup[key] = index
                        p = pga2005_xfile.transform_point(mesh.positions[vertex], matrix)
                        n = (pga2005_xfile.normalize(pga2005_xfile.transform_vector(
                            mesh.normals[normal_index], normal_matrix)) if has_normals else (0.0, 1.0, 0.0))
                        uv = mesh.uvs[vertex] if vertex < len(mesh.uvs) else (0.0, 0.0)
                        color = mesh.colors.get(vertex, (1.0, 1.0, 1.0, 1.0))
                        rgba = tuple(max(0, min(255, round(c * 255))) for c in color)
                        vertices.append((p, n, uv, rgba))
                    out.append(index)
        stats["unpaired_leaf_triangles"] += len(pending_leaf)
    indices, ranges = [], []
    for material in sorted(by_material):
        ranges.append((material, len(indices), len(by_material[material])))
        indices.extend(by_material[material])
    data = ghom_bytes(vertices, indices, ranges, leaves)
    header = read_ghom(data)
    animation_sets = xf.animation_sets()
    return data, {"materials": materials, "x_vertex_count": sum(len(m.positions) for m in xf.meshes()),
                  "vertex_count": len(vertices), "triangle_count": len(indices) // 3,
                  "leaf_count": len(leaves), "bounds_min": list(header["bounds_min"]),
                  "bounds_max": list(header["bounds_max"]), "x_format": xf.format, "stats": stats,
                  "embedded_animation_sets": len(animation_sets)}


def tree_lod_payloads(library: CourseFile, object_index: int) -> list[dict]:
    """LibraryC::GetAnimTree/GetMedTreeMesh/GetMinorTreeMesh (0x1000c170/1d0/230)."""
    tables = [(0, 0x78), (1, 0x88)]
    if (library.version & 0x7fff) > 4:
        tables.append((2, 0xd4))
    lods = []
    count = library.u16(0x48)
    for lod, field in tables:
        if library.u32(field) == 0 or not 0 <= object_index < count:
            continue
        entry = table_entry(library, field, object_index)
        if entry["bytes"] <= 0:
            continue
        payload = library.range(entry["source_offset"], entry["bytes"])
        if len(payload) < 12:
            raise ValueError("Truncated tagTreeMesh")
        hierarchy, animation = struct.unpack_from("<II", payload, 0)
        lod_scale = struct.unpack_from("<f", payload, 8)[0]
        if not (12 <= hierarchy < animation <= len(payload)) or not math.isfinite(lod_scale):
            raise ValueError("Invalid tagTreeMesh offsets")
        lods.append({"lod": lod, "table": field, "entry": entry, "lod_scale": lod_scale,
                     "xfile": payload[hierarchy:animation], "animation": payload[animation:]})
    return lods


# ------------------------------------------------------------- instances

def accepts(layer: int, selector: int) -> bool:
    """CourseDataManager::AddVisiblePatch predicate (0x10009160)."""
    return ((layer ^ selector) & 0x1f) == 0 and ((layer & ~0x1f) == 0 or (layer & selector & ~0x1f) != 0)


def decode_instances(course: CourseFile) -> tuple[list[dict], dict]:
    data = course.data
    patch_count = course.u16(0x46)
    table = course.u32(0x104)
    if table + patch_count * PATCH_STRIDE != course.header_bytes:
        raise ValueError("Unexpected patch table bounds")
    type_count = course.u16(0x48)
    instances, trailing = [], 0
    for patch in range(patch_count):
        base = table + patch * PATCH_STRIDE
        count = struct.unpack_from("<h", data, base + 0x2f)[0]
        if count <= 0:
            continue
        source, _, _, size = struct.unpack_from("<IIII", data, base)
        relative = struct.unpack_from("<I", data, base + 0x55)[0]
        end = struct.unpack_from("<I", data, base + 0x89)[0]
        if relative + count * SURFACE_STRUCTURE_BYTES > size or source + size > len(data):
            raise ValueError(f"Patch {patch}: tree records escape the payload")
        if end >= relative:
            trailing += max(0, end - relative - count * SURFACE_STRUCTURE_BYTES)
        layer = struct.unpack_from("<H", data, base + 0x61)[0]
        ox, oz = struct.unpack_from("<ii", data, base + 0x13)
        oy = struct.unpack_from("<i", data, base + 0x4d)[0]
        for k in range(count):
            offset = source + relative + k * SURFACE_STRUCTURE_BYTES
            x, y, z, scale, rotation, kind, x0, y0, z0, x1, y1, z1 = struct.unpack_from(
                "<hhhfBBhhhhhh", data, offset)
            if kind >= type_count:
                raise ValueError(f"Patch {patch} tree {k}: type {kind} >= {type_count}")
            if not math.isfinite(scale) or scale <= 0:
                raise ValueError(f"Patch {patch} tree {k}: invalid scale")
            instances.append({"hole": layer & 0x1f, "layer": layer, "patch": patch, "index": k, "type": kind,
                              "position": (x + ox, y + oy, z + oz), "rotation_byte": rotation,
                              "rotation_index": rotation % 5, "scale": scale,
                              "bounds_min": (x0 + ox, y0 + oy, z0 + oz), "bounds_max": (x1 + ox, y1 + oy, z1 + oz),
                              "source_offset": offset})
    return instances, {"patch_count": patch_count, "trailing_duplicate_bytes": trailing}


def instance_matrix(position, rotation_index: int, scale: float) -> list[float]:
    """CRVegetation::ComputeTreeMatrix (0x101da420), D3D row-vector convention."""
    angle = rotation_index * ROTATION_STEP
    c, s = math.cos(angle) * scale, math.sin(angle) * scale
    return [c, 0.0, -s, 0.0, 0.0, scale, 0.0, 0.0, s, 0.0, c, 0.0, position[0], position[1], position[2], 1.0]


# --------------------------------------------------------------- course

def decode_panoramas(course: CourseFile, libraries: list[CourseFile], store: TextureStore, output: Path,
                     ini: bytes | None) -> dict | None:
    """Distant backdrop strips: TCR pan blocks (count hdr+0x68, table hdr+0x84; CourseDataManager::GetPan
    0x10007bc0). Same polyObject layout as the sky dome; vertices are already in world coordinates."""
    count = course.u16(0x68)
    if not count or not course.u32(0x84):
        return None
    material_table, material_count = course.u32(0x80), course.u16(0x50)
    blocks = []
    for index in range(count):
        entry = table_entry(course, 0x84, index)
        if not entry["source_offset"] or entry["bytes"] < POLY_GROUPS:
            continue
        poly = poly_object(course.range(entry["source_offset"], entry["bytes"]), f"pan {index}")
        vertices, indices, ranges, groups = [], [], [], []
        for g, group in enumerate(poly["groups"]):
            if not 0 <= group["material"] < material_count:
                raise ValueError(f"Pan {index}: material out of range")
            moff = material_table + group["material"] * DESCRIPTOR_BYTES
            number, texture_index = course.data[moff + 18] >> 2, course.u16(moff + 4)
            texture = library_texture(libraries[number], number, texture_index, store)
            base = len(vertices)
            for x, y, z, argb, u, v, _, _ in group["points"]:
                vertices.append(((x, y, z), (0.0, 0.0, 0.0), (u, v),
                                 ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255, (argb >> 24) & 255)))
            first = len(indices)
            for tri in group["triangles"]:
                indices.extend(base + i for i in tri)
            ranges.append((g, first, len(indices) - first))
            groups.append({"material": g, "tcr_material": group["material"], "texture": texture["texture"],
                           "texture_name": texture["name"], "section_flags": texture["section_flags"]})
        data = ghom_bytes(vertices, indices, ranges, [], has_normals=False)
        blocks.append({"index": index, "mesh": write_mesh(output, data), "bounds_min": list(poly["bounds"][:3]),
                       "bounds_max": list(poly["bounds"][3:]), "groups": groups, "source": entry})
    per_hole = {}
    if ini:
        sections = read_ini(ini)
        for name, values in sections.items():
            parts = name.split()
            if len(parts) == 2 and parts[0].upper() == "HOLE" and parts[1].isdigit():
                if "HolePanId" in values or "PanRotate" in values:
                    per_hole[parts[1]] = {"HolePanId": values.get("HolePanId"), "PanRotate": values.get("PanRotate")}
        locked = sections.get("PanEditing", {})
    return {"blocks": blocks, "per_hole_ini": per_hole,
            "pan_editing_ini": locked if ini else None,
            "placement": "Vertices are world coordinates (raw inches). Per-hole selection is read from "
                         "[HOLE n] HolePanId / PanRotate (CourseInfoC::GetHolePanId 0x1000ab10, GetPanRotation "
                         "0x1000abf0); the CRPanorama draw code was not analysed, so 'block index = HolePanId' "
                         "and the rotation semantics are unverified.",
            "evidence": "CourseDataManager::GetPan 0x10007bc0; LibraryC::GetPanBlock 0x1000c320"}


def decode_course_objects(course_data: bytes, library_data: list[bytes], output: Path,
                          ini: bytes | None = None) -> dict:
    course = CourseFile(course_data, "TCR")
    libraries = ordered_libraries(course, [CourseFile(d, f"TCL {i}") for i, d in enumerate(library_data)])
    store = TextureStore(output)
    type_count = course.u16(0x48)
    material_table = course.u32(0x80)
    material_count = course.u16(0x50)
    name_maps = [texture_names(lib) for lib in libraries]
    models, types, mesh_files = {}, [], {}

    # CourseDataManager::TextureIdFromFilePath (0x10007e10): compare the .x texture's file stem,
    # case-insensitively, with each TCR material's library texture name minus its last
    # extension; the first match wins and a miss falls back to material 0.
    stems = {}
    for material_id in range(material_count):
        moff = material_table + material_id * DESCRIPTOR_BYTES
        texture_index, number = course.u16(moff + 4), course.data[moff + 18] >> 2
        if number < len(libraries) and texture_index < libraries[number].u16(0x50):
            payload, _ = libraries[number].descriptor(0x7c, texture_index)
            name = libraries[number].text(payload).lower()
            stems.setdefault(name.rsplit(".", 1)[0] if "." in name else name, (material_id, number, texture_index))

    def resolve(texture_file):
        stem = texture_file.rsplit(".", 1)[0] if "." in texture_file else texture_file
        fallback = stem not in stems
        if fallback:
            moff = material_table
            material_id, number, index = 0, course.data[moff + 18] >> 2, course.u16(moff + 4)
        else:
            material_id, number, index = stems[stem]
        entry = library_texture(libraries[number], number, index, store)
        return {"texture": entry["texture"], "texture_name": entry["name"], "texture_key": entry["key"],
                "section_flags": entry["section_flags"], "library_index": number, "texture_index": index,
                "tcr_material": material_id, "fallback_material_0": fallback,
                "kind": "leaf_card" if entry["section_flags"] & LEAF_SECTION_FLAG else "mesh",
                "alpha_test": bool(entry["section_flags"] & TREE_SECTION_FLAG)}

    for k in range(type_count):
        large = table_entry(course, 0x6c, k)
        anim = table_entry(course, 0x78, k) if course.u32(0x78) else large
        library_number, object_index = anim["library"], anim["index"]
        if library_number >= len(libraries):
            raise ValueError(f"Object type {k}: library {library_number} unavailable")
        library = libraries[library_number]
        if not 0 <= object_index < library.u16(0x48):
            raise ValueError(f"Object type {k}: library object {object_index} out of range")
        model_key = f"{library_number}:{object_index}"
        if model_key not in models:
            lods = []
            for lod in tree_lod_payloads(library, object_index):
                data, meta = build_tree_mesh(lod["xfile"], resolve)
                path = write_mesh(output, data)
                mesh_files[path] = len(data)
                animation = None
                if lod["animation"]:
                    try:
                        xf = pga2005_xfile.parse(lod["animation"])
                        sets = xf.animation_sets()
                        animation = {"bytes": len(lod["animation"]), "sha256": sha256(lod["animation"]),
                                     "animation_sets": len(sets),
                                     "animated_bones": sum(len(s.animations) for s in sets),
                                     "keys_per_track": sorted({len(k.keys) for s in sets for a in s.animations
                                                               for k in a.keys})}
                    except pga2005_xfile.XFileError as error:
                        animation = {"bytes": len(lod["animation"]), "error": str(error)}
                lods.append({"lod": lod["lod"], "mesh": path, "lod_scale": lod["lod_scale"],
                             "xfile_sha256": sha256(lod["xfile"]), "source": lod["entry"],
                             "animation": animation, **meta})
            # Low LOD: TCR "small" polyObject (Get3DObjectBySize(type, 0), CourseData 0x10008600).
            small_entry = table_entry(course, 0x70, k)
            if small_entry["source_offset"]:
                small = poly_object(course.range(small_entry["source_offset"], small_entry["bytes"]), f"small {k}")
                material_id = small["groups"][0]["material"]
                if not 0 <= material_id < material_count:
                    raise ValueError("Billboard material out of range")
                moff = material_table + material_id * DESCRIPTOR_BYTES
                texture_index, billboard_library = course.u16(moff + 4), course.data[moff + 18] >> 2
            else:
                lib_small = table_entry(library, 0x70, object_index)
                small = poly_object(library.range(lib_small["source_offset"], lib_small["bytes"]), f"small {k}")
                material_id, texture_index, billboard_library = None, small["groups"][0]["material"], library_number
            texture = library_texture(libraries[billboard_library], billboard_library, texture_index, store)
            points = [p for g in small["groups"] for p in g["points"]]
            bounds = small["bounds"]
            models[model_key] = {
                "key": model_key, "library_index": library_number, "object_index": object_index,
                "name": texture["name"][:-6] if texture["name"].lower().endswith(".x.tga") else texture["name"],
                "lods": lods,
                "billboard": {"texture": texture["texture"], "texture_name": texture["name"],
                              "texture_key": texture["key"], "tcr_material": material_id,
                              "width_local": bounds[3] - bounds[0], "x_local": [bounds[0], bounds[3]],
                              "y_local": [bounds[1], bounds[4]],
                              "uv_min": [min(p[4] for p in points), min(p[5] for p in points)],
                              "uv_max": [max(p[4] for p in points), max(p[5] for p in points)],
                              "source": small_entry}}
        lighting = None
        if course.u32(0x90):
            entry = table_entry(course, 0x90, k)
            if entry["bytes"] >= 12:
                payload = course.range(entry["source_offset"], entry["bytes"])
                lod_count = 3 if max((l.version & 0x7fff) for l in libraries) > 4 else 2
                sizes = list(struct.unpack_from(f"<{lod_count}I", payload, 0))
                lighting = {"source": entry, "lod_byte_counts": sizes,
                            "bytes_per_vertex_per_rotation": [
                                size / (5 * lod["x_vertex_count"]) if lod.get("x_vertex_count") else None
                                for size, lod in zip(sizes, models[model_key]["lods"])]}
        types.append({"type": k, "model": model_key, "tcr_large_descriptor": large,
                      "tcr_tree_descriptor": anim, "name": models[model_key]["name"],
                      "baked_lighting": lighting})

    panoramas = decode_panoramas(course, libraries, store, output, ini)
    instances, instance_info = decode_instances(course)
    for instance in instances:
        model = models[types[instance["type"]]["model"]]
        instance["model"] = model["key"]
    holes = {}
    for instance in instances:
        holes.setdefault(instance["hole"], []).append(instance)
    fields = ["type", "x", "y", "z", "rotation_index", "scale", "min_x", "min_y", "min_z",
              "max_x", "max_y", "max_z", "layer", "patch"]
    instances_json = {
        "schema_version": 1, "coordinates": "raw left-handed source inches (same frame as terrain.ghpc)",
        "fields": fields,
        "transform": "world = model * S(scale) * RotY(rotation_index * 2*pi/5) + (x,y,z) in D3D row-vector "
                     "form: x' = s*(x*cos a + z*sin a) + X; y' = s*y + Y; z' = s*(-x*sin a + z*cos a) + Z",
        "selection": "draw an instance for hole H when the terrain patch predicate accepts its layer "
                     "(selector (0x420 & ~0x1f) | H); every PBL tree has condition bits 0",
        "holes": {str(h): [[i["type"], *i["position"], i["rotation_index"], round(i["scale"], 7),
                            *i["bounds_min"], *i["bounds_max"], i["layer"], i["patch"]]
                           for i in sorted(rows, key=lambda r: (r["patch"], r["index"]))]
                  for h, rows in sorted(holes.items())}}
    counts = {str(h): {"instances": len(rows),
                       "by_type": {str(t): sum(1 for r in rows if r["type"] == t) for t in range(type_count)
                                   if any(r["type"] == t for r in rows)}}
              for h, rows in sorted(holes.items())}
    summary = {"object_types": type_count, "models": len(models), "instances": len(instances),
               "panorama_blocks": len(panoramas["blocks"]) if panoramas else 0,
               "holes": len(holes), "tree_mesh_files": len(mesh_files),
               "tree_mesh_bytes": sum(mesh_files.values()), "textures": len(store.entries)}
    course_sections = read_ini(ini) if ini else {}
    objects_json = {
        "schema_version": 1, "course_title": course.title, "source_tcr_sha256": course.digest,
        # Per-course sky placement (CourseInfoC::GetSkyDomeScaleX/ScaleZ/YOffset) and the INI's
        # default sky condition; sky.json only keeps the values of the course decoded with it.
        "sky_ini": {"SkyDome": course_sections.get("SkyDome", {}),
                    "Conditions.Skydome": course_sections.get("Conditions", {}).get("Skydome")},
        "source_libraries": [{"index": i, "guid": l.guid, "sha256": l.digest, "title": l.title,
                              "version": l.version, "new_style_trees": (l.version & 0x7fff) > 4,
                              "object_count": l.u16(0x48)}
                             for i, l in enumerate(libraries)],
        "decoder_dll_sha256": {"CourseData.dll": COURSE_DLL_SHA256, "Engine.dll": ENGINE_DLL_SHA256},
        "method": "Static CourseData/Engine-bound reconstruction; no original code execution",
        "coordinates": "Raw left-handed source inches, identical to terrain.ghpc; native code applies its "
                       "terrain transform to world-space positions after the instance matrix (mirroring Z "
                       "reverses triangle winding).",
        "summary": summary, "per_hole": counts, "instance_info": instance_info,
        "types": types, "models": models, "panoramas": panoramas, "textures": list(store.entries.values()),
        "mesh_format": GHOM_FORMAT,
        "render_rules": {
            "lods": "LOD0 high (skinned, optionally animated), LOD1 medium, LOD2 minor, LOD3 billboard",
            "lod_selection": "CRVegetation::FlagHighLowTrees 0x101cd96d: new-style trees choose the highest "
                             "LOD whose threshold the distance exceeds (LOD1/LOD2/LOD3 distances); at or "
                             "beyond LOD3 distance the billboard is drawn",
            "default_distances_inches": TREE_LOD_DISTANCES,
            "lod_scale": "tagTreeMesh +8; ComputeTreeMatrix multiplies it in only for old-style trees "
                         "(library version <= 4). PBL is new-style: use the instance scale for every LOD.",
            "leaf_cards": "Leaf materials (section flag 0x100000) are camera-facing squares "
                          "(CRVegetation::RotateLeaves 0x101d3434). Corners = centre + half_size * "
                          "R*(+-1,+-1,0), R = camera yaw/pitch; the original adds a per-leaf twist "
                          "(5 random angles in [-pi/6, pi/6]) and a small wind sway.",
            "billboard": "LOD3: one quad centred on the instance, width = scale * width_local, from the "
                         "instance Y to its stored bounds max Y, rotated about Y to face the camera "
                         "(CreateLowLODBuffers 0x101cb4ba, TransformLowLODs 0x101cce99); UV (0,0) top-left "
                         "to (1,1).",
            "alpha": {"test": True, "reference": VEGETATION_ALPHA_REF, "blend": False,
                      "note": "Alpha reference is animated during LOD cross-fades in the original."},
            "culling": "Billboards are drawn without culling; leaf cards face the camera.",
            "tree_ambient": "render.ini [TreeAmbient] value is added to high/medium tree vertex lighting",
        },
        "evidence": {
            "instances": "tagSurfaceStructureCompressed::GetSurfaceStructure 0x1000e660; tagPatch::Num3DTrees "
                         "0x10003000; CRVegetation::FillTreeStructs 0x101cbcb8",
            "rotation": "float32 0x3fa0d97c (2*pi/5) at 0x1002adb0 and 0x102d96bc",
            "types": "CourseDataManager::GetTreeLibraryInfo 0x10009e30, Get3DObjectBySize 0x10008600, "
                     "LoadAllTrees 0x10007f80",
            "meshes": "LibraryC::GetAnimTree 0x1000c170, GetMedTreeMesh 0x1000c1d0, GetMinorTreeMesh 0x1000c230",
            "leaf_cards": "CTreeSkinMesh::CreateCleanPoints 0x100112e0; CRVegetation::RotateLeaves 0x101d3434",
            "matrix": "CRVegetation::ComputeTreeMatrix 0x101da420",
        },
        "limitations": [
            "Skinning weights and the LOD0 sway animation are reported, not exported; meshes are bind pose.",
            "Per-type low-LOD width factor CRData+0x24 is not traced (assumed 1.0).",
            "Baked per-vertex tree lighting (TCR +0x90: per type and LOD, 5 rotation variants x one byte "
            "per .x vertex) is located and sized but not exported: the engine's vertex order is unresolved.",
            "Composite-course tree colour tints (CCourse::GetTreeColor) are not decoded.",
            "Only observed version-7 TCR/TCL layouts are supported.",
        ],
    }
    return {"objects": objects_json, "instances": instances_json, "instance_rows": instances,
            "models": models, "types": types}


# --------------------------------------------------------------------- sky

SKY_PRESET_KEYS = {"SKY": ["SKYTYPE"], "SkydomeAnimationControls": ["deltaU", "deltaV"],
                   "GlobalLightingValues": ["Diffuse", "SkydomeDiffuse"],
                   "Fog": ["Enabled", "Start", "End", "Color"], "LensFlare": ["Enabled", "Position", "SunSize"]}


def read_ini(data: bytes) -> dict:
    sections, current = {}, None
    for line in data.decode("cp1252", errors="replace").splitlines():
        line = line.split(";", 1)[0].split("//", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and "]" in line:
            current = sections.setdefault(line[1:line.index("]")].strip(), {})
        elif "=" in line and current is not None:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip()
    return sections


def decode_sky(skydome: bytes, output: Path, extra_textures: dict[str, bytes] | None = None,
               render_presets: dict[str, bytes] | None = None, course_ini: bytes | None = None) -> dict:
    library = CourseFile(skydome, "Skydome.tcl")
    store = TextureStore(output)
    count = library.u16(0x68)
    if not 0 < count <= 64 or library.u32(0x84) == 0:
        raise ValueError("Skydome library has no pan blocks")
    domes = []
    for index in range(count):
        entry = table_entry(library, 0x84, index)
        payload = library.range(entry["source_offset"], entry["bytes"])
        poly = poly_object(payload, f"sky pan {index}")
        name = payload[0x20:0x3d].split(b"\0", 1)[0].decode("cp1252", errors="replace")
        vertices, indices, ranges, groups = [], [], [], []
        for g, group in enumerate(poly["groups"]):
            texture = library_texture(library, 0, group["material"], store)
            base = len(vertices)
            for x, y, z, argb, u, v, _, _ in group["points"]:
                rgba = ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255, (argb >> 24) & 255)
                vertices.append(((x, y, z), (0.0, 0.0, 0.0), (u, v), rgba))
            first = len(indices)
            for tri in group["triangles"]:
                indices.extend(base + i for i in tri)
            ranges.append((g, first, len(indices) - first))
            flags = texture["section_flags"]
            groups.append({"material": g, "texture": texture["texture"], "texture_name": texture["name"],
                           "texture_key": texture["key"], "section_flags": flags,
                           "alpha_blend": bool(flags & ALPHA_BLEND_SECTION_FLAG),
                           "cloud_layer": bool(flags & CLOUD_SECTION_FLAG),
                           "vertices": len(group["points"]), "triangles": len(group["triangles"])})
        data = ghom_bytes(vertices, indices, ranges, [], has_normals=False)
        path = write_mesh(output, data)
        bounds = poly["bounds"]
        domes.append({"pan_index": index, "sky_type": index + 1, "name": name, "mesh": path,
                      "bounds_min": list(bounds[:3]), "bounds_max": list(bounds[3:]),
                      "center_xz": [(bounds[0] + bounds[3]) / 2, (bounds[2] + bounds[5]) / 2],
                      "groups": groups, "source": entry})
    extras = []
    for name, data in sorted((extra_textures or {}).items()):
        entry = store.add("extra-" + name.lower().replace(".dds", "").replace(".", "-").replace("/", "-"),
                          name, data)
        extras.append(entry)
    presets = []
    for name, data in sorted((render_presets or {}).items(), key=lambda kv: (len(kv[0]), kv[0])):
        ini = read_ini(data)
        first = data.split(b"\n", 1)[0].decode("cp1252", errors="replace").strip()
        preset = {"file": name, "label": first.lstrip("#").strip()}
        for section, keys in SKY_PRESET_KEYS.items():
            for key in keys:
                if section in ini and key in ini[section]:
                    preset[f"{section}.{key}"] = ini[section][key]
        presets.append(preset)
    course_sky = None
    if course_ini:
        ini = read_ini(course_ini)
        course_sky = {"SkyDome": ini.get("SkyDome", {}), "Conditions.Skydome": ini.get("Conditions", {}).get("Skydome")}
    return {
        "schema_version": 1, "source_sha256": library.digest, "source_guid": library.guid,
        "coordinates": "raw left-handed source inches; the dome is re-centred on the camera every frame",
        "mesh_format": GHOM_FORMAT, "domes": domes, "extra_textures": extras,
        "textures": list(store.entries.values()), "render_presets": presets, "course_ini": course_sky,
        "render_rules": {
            "selection": "pan block = SKYTYPE - 1 (CRSkydome loader 0x101bf995 -> LibraryC::GetPanBlock "
                         "0x1000c320; SKYTYPE from the active renderN.ini [SKY] via CGlobalRenderSettings+4, "
                         "clamped to 1..8)",
            "placement": "world = vertex * Scale(SkyDome.ScaleX, 1, SkyDome.ScaleZ) then translate by "
                         "(camera.x - center_x, courseMinY + SkyDome.YOffset, camera.z - center_z) "
                         "(draw routine 0x101bfdb1)",
            "state": "no depth test or depth write, no lighting, drawn first; SkydomeDiffuse tints it",
            "alpha_blend": "groups whose section flag has bit 0x1 blend",
            "cloud_layers": "section flag 0x1000 groups scroll their UVs by [SkydomeAnimationControls] "
                            "deltaU/deltaV per second; for sky types 4-6 their UVs are rebuilt from the "
                            "vertex direction (asin), and procedural clouds may replace them",
        },
        "evidence": {"loader": "Engine.dll 0x101bf69d (CRSkydome ctor), 0x101bf995, 0x101bf09d (pan parser)",
                     "draw": "Engine.dll 0x101bfdb1", "ini": "CourseInfoC::GetSkyDomeScaleX/ScaleZ/YOffset "
                     "0x1000acd0/0x1000ad50/0x1000add0; SKYTYPE reader 0x101e88bc"},
    }


# -------------------------------------------------------------- validation

class TerrainFloor:
    """Height queries against a GHPC v3 terrain, restricted to one hole's patches."""

    def __init__(self, data: bytes, cell: float = 512.0):
        if data[:4] != b"GHPC" or struct.unpack_from("<I", data, 4)[0] != 3:
            raise ValueError("Expected GHPC v3 terrain")
        _, self.vertex_count, self.triangle_count, _ = struct.unpack_from("<IIII", data, 4)
        self.patch_count = struct.unpack_from("<I", data, 44)[0]
        self.data, self.cell = data, cell
        self.vertices_offset = 48
        self.triangles_offset = 48 + self.vertex_count * 24
        self.patches_offset = self.triangles_offset + self.triangle_count * 16
        if self.patches_offset + self.patch_count * 20 != len(data):
            raise ValueError("GHPC size mismatch")

    def patches(self):
        for p in range(self.patch_count):
            yield struct.unpack_from("<5I", self.data, self.patches_offset + p * 20)

    def build(self, selector: int) -> dict:
        grid, data = {}, self.data
        for layer, _, _, first, count in self.patches():
            if not accepts(layer, selector):
                continue
            for t in range(first, first + count):
                a, b, c, terrain_id = struct.unpack_from("<4I", data, self.triangles_offset + t * 16)
                pts = [struct.unpack_from("<3f", data, self.vertices_offset + v * 24) for v in (a, b, c)]
                x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
                z0, z1 = min(p[2] for p in pts), max(p[2] for p in pts)
                for gx in range(int(x0 // self.cell), int(x1 // self.cell) + 1):
                    for gz in range(int(z0 // self.cell), int(z1 // self.cell) + 1):
                        grid.setdefault((gx, gz), []).append((pts, terrain_id))
        return grid

    def heights(self, grid: dict, x: float, z: float) -> list[tuple[float, int]]:
        out = []
        for ((ax, ay, az), (bx, by, bz), (cx, cy, cz)), terrain_id in grid.get(
                (int(x // self.cell), int(z // self.cell)), ()):
            det = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
            if abs(det) < 1e-9:
                continue
            l1 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / det
            l2 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / det
            l3 = 1.0 - l1 - l2
            if min(l1, l2, l3) >= -1e-6:
                out.append((l1 * ay + l2 * by + l3 * cy, terrain_id))
        return out


def percentile(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    k = (len(ordered) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def validate_floor(instances: list[dict], terrain: bytes, materials: dict | None = None) -> dict:
    """``materials``: optional materials.json document, used to name the surface under each tree."""
    floor = TerrainFloor(terrain)
    per_hole, all_errors, missing, surfaces = {}, [], 0, {}
    holes = sorted({i["hole"] for i in instances})
    for hole in holes:
        grid = floor.build((STANDARD_SELECTOR & ~0x1f) | hole)
        errors, absent = [], 0
        for instance in instances:
            if instance["hole"] != hole or not accepts(instance["layer"], (STANDARD_SELECTOR & ~0x1f) | hole):
                continue
            x, y, z = instance["position"]
            heights = floor.heights(grid, x, z)
            if not heights:
                absent += 1
                continue
            error, terrain_id = min(((y - h, t) for h, t in heights), key=lambda e: abs(e[0]))
            errors.append(error)
            surfaces[terrain_id] = surfaces.get(terrain_id, 0) + 1
        missing += absent
        all_errors.extend(errors)
        absolute = [abs(e) for e in errors]
        per_hole[str(hole)] = {"checked": len(errors), "no_floor": absent,
                               "median_abs": round(percentile(absolute, 0.5), 3),
                               "p95_abs": round(percentile(absolute, 0.95), 3),
                               "max_abs": round(max(absolute), 3) if absolute else None}
    absolute = [abs(e) for e in all_errors]
    return {"method": "instance y minus the nearest same-hole floor height (selector 0x420|hole) under its XZ",
            "units": "inches", "checked": len(all_errors), "no_floor": missing,
            "median_signed": round(percentile(all_errors, 0.5), 3),
            "median_abs": round(percentile(absolute, 0.5), 3), "p90_abs": round(percentile(absolute, 0.9), 3),
            "p95_abs": round(percentile(absolute, 0.95), 3), "p99_abs": round(percentile(absolute, 0.99), 3),
            "max_abs": round(max(absolute), 3) if absolute else None,
            "within_1in": sum(1 for e in absolute if e <= 1), "within_6in": sum(1 for e in absolute if e <= 6),
            "within_12in": sum(1 for e in absolute if e <= 12), "per_hole": per_hole,
            "surface_under_instances": surface_summary(surfaces, materials)}


def surface_summary(surfaces: dict, materials: dict | None) -> dict:
    by_id = {m["id"]: m for m in (materials or {}).get("materials", [])}
    flags = {}
    rows = []
    for terrain_id, count in sorted(surfaces.items(), key=lambda kv: -kv[1]):
        material = by_id.get(terrain_id, {})
        surface = (material.get("surface_types") or [{}])[0]
        bits = surface.get("flags")
        rows.append({"terrain_id": terrain_id, "name": material.get("name"), "count": count,
                     "surface_flags": bits})
        if bits is not None:
            for bit, label in ((0x1, "fairway"), (0x4, "green"), (0x8, "bunker"), (0x40, "water"),
                               (0x1000, "tee"), (0x2, "rough"), (0x20, "unplayable")):
                if bits & bit:
                    flags[label] = flags.get(label, 0) + count
    return {"by_flag": flags, "top": rows[:12]}


def convex_hull(points: list[tuple]) -> list[tuple]:
    points = sorted(set(points))
    if len(points) <= 2:
        return points

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in points:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(points):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def validate_bounds(result: dict, output: Path) -> dict:
    """Compare each instance's stored bounds with its LOD0 mesh (vertices plus leaf cards as the
    authored static squares) under the instance transform.

    ``rendered`` uses the quantised angle the engine draws (rotation_index * 72 deg). ``sector_fit``
    searches 0.5-degree steps inside the instance's 72-degree sector: the stored bounds match
    an authored continuous angle whose floor(angle / 72 deg) is the stored rotation byte.
    """
    models, hulls, ys = result["models"], {}, {}
    for key, model in models.items():
        mesh = read_ghom((output / model["lods"][0]["mesh"]).read_bytes())
        points = [(v[0], v[2]) for v in mesh["vertices"]]
        heights = [v[1] for v in mesh["vertices"]]
        for leaf in mesh["leaves"]:
            (cx, cy, cz), h = leaf[0:3], leaf[3]
            points += [(cx - h, cz), (cx + h, cz)]
            heights += [cy - h, cy + h]
        hulls[key], ys[key] = convex_hull(points), (min(heights), max(heights))
    extents_cache = {}

    def extents(key, half_degrees):
        cache_key = (key, half_degrees)
        if cache_key not in extents_cache:
            angle = math.radians(half_degrees / 2.0)
            c, s = math.cos(angle), math.sin(angle)
            xs = [x * c + z * s for x, z in hulls[key]]
            zs = [-x * s + z * c for x, z in hulls[key]]
            extents_cache[cache_key] = (min(xs), max(xs), min(zs), max(zs))
        return extents_cache[cache_key]

    def error(instance, half_degrees):
        x0, x1, z0, z1 = extents(instance["model"], half_degrees % 720)
        y0, y1 = ys[instance["model"]]
        s, (px, py, pz) = instance["scale"], instance["position"]
        predicted = (px + s * x0, py + s * y0, pz + s * z0, px + s * x1, py + s * y1, pz + s * z1)
        stored = (*instance["bounds_min"], *instance["bounds_max"])
        return max(abs(a - b) for a, b in zip(predicted, stored))

    rendered, fitted, offsets = [], [], []
    for instance in result["instance_rows"]:
        base = instance["rotation_index"] * 144
        rendered.append(error(instance, base))
        best = min((error(instance, base + step), step) for step in range(0, 145))
        fitted.append(best[0])
        offsets.append(best[1] / 2.0)
    return {"method": validate_bounds.__doc__.strip().replace("\n", " "), "units": "inches",
            "instances": len(rendered),
            "rendered_angle": {"median": round(percentile(rendered, 0.5), 3),
                               "p95": round(percentile(rendered, 0.95), 3)},
            "sector_fit": {"median": round(percentile(fitted, 0.5), 3), "p90": round(percentile(fitted, 0.9), 3),
                           "p99": round(percentile(fitted, 0.99), 3), "max": round(max(fitted), 3),
                           "fitted_offset_degrees_quartiles": [round(percentile(offsets, q), 1)
                                                               for q in (0.25, 0.5, 0.75)]}}


# ----------------------------------------------------------------------- CLI

def prepare_course(root: Path, course: str, validate: bool = True, tcr: Path | None = None,
                   tcls: list[Path] | None = None, output: Path | None = None,
                   terrain: Path | None = None) -> dict:
    """Decode one prepared course's objects into Library/Imported/pga2005/<course>/objects.
    Validation needs that course's terrain.ghpc (and materials.json for surface names)."""
    source = root / "Library/SourceMedia/pga2005/disc3/COURSES" / course
    output = output or root / "Library/Imported/pga2005" / course / "objects"
    ini_path = source / f"{course}.INI"
    result = decode_course_objects((tcr or source / f"{course}.TCR").read_bytes(),
                                   [p.read_bytes() for p in (tcls or [source / f"{course}.TCL"])], output,
                                   ini_path.read_bytes() if ini_path.exists() else None)
    objects = result["objects"]
    terrain_path = terrain or output.parent / "terrain.ghpc"
    if validate and terrain_path.exists():
        materials_path = output.parent / "materials.json"
        materials = json.loads(materials_path.read_text()) if materials_path.exists() else None
        terrain_bytes = terrain_path.read_bytes()
        objects["validation"] = {"floor": validate_floor(result["instance_rows"], terrain_bytes, materials),
                                 "bounds": validate_bounds(result, output),
                                 "terrain_sha256": sha256(terrain_bytes)}
    atomic_write(output / "instances.json", (json.dumps(result["instances"], separators=(",", ":")) + "\n").encode())
    atomic_write(output / "objects.json", (json.dumps(objects, indent=1) + "\n").encode())
    return {"summary": objects["summary"], "validation": objects.get("validation")}


def prepare_sky(root: Path, course: str, skydome: Path | None = None, output: Path | None = None) -> dict:
    """Decode the shared install sky domes into Library/Imported/pga2005/sky."""
    media = root / "Library/SourceMedia/pga2005"
    skydome = skydome or media / "install/CoursesRoot/skydome.TCL"
    output = output or root / "Library/Imported/pga2005/sky"
    extras = {}
    for name in ("cloudturb.dds", "sun1.dds", "lflare1a.dds", "lflare1b.dds"):
        path = skydome.parent / name
        if path.exists():
            extras[name] = path.read_bytes()
    flare_dir = media / "install/DataImages/Game/Lensflare"
    if flare_dir.is_dir():
        for path in sorted(flare_dir.glob("*.dds")):
            extras["Lensflare/" + path.name] = path.read_bytes()
    presets = {p.name: p.read_bytes() for p in (media / "engine/Executable").glob("render*.ini")}
    ini = media / "disc3/COURSES" / course / f"{course}.INI"
    sky = decode_sky(skydome.read_bytes(), output, extras, presets, ini.read_bytes() if ini.exists() else None)
    atomic_write(output / "sky.json", (json.dumps(sky, indent=1) + "\n").encode())
    return {"domes": len(sky["domes"]), "textures": len(sky["textures"])}


def main():
    root = Path(__file__).resolve().parent.parent
    media = root / "Library/SourceMedia/pga2005"
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--course", default="PBL")
    parser.add_argument("--tcr", type=Path)
    parser.add_argument("--tcl", type=Path, action="append")
    parser.add_argument("--output", type=Path, help="Default Library/Imported/pga2005/<COURSE>/objects")
    parser.add_argument("--terrain", type=Path, help="GHPC v3 for floor validation (default: course terrain.ghpc)")
    parser.add_argument("--skydome", type=Path, default=media / "install/CoursesRoot/skydome.TCL")
    parser.add_argument("--sky-output", type=Path, default=root / "Library/Imported/pga2005/sky")
    parser.add_argument("--no-course", action="store_true")
    parser.add_argument("--no-sky", action="store_true")
    parser.add_argument("--no-validate", action="store_true")
    args = parser.parse_args()
    course = args.course.upper()
    if not course.isalnum():
        parser.error("Invalid course id")
    report = {}
    if not args.no_course:
        report["course"] = prepare_course(root, course, not args.no_validate, args.tcr, args.tcl, args.output,
                                          args.terrain)
    if not args.no_sky:
        report["sky"] = prepare_sky(root, course, args.skydome, args.sky_output)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, struct.error) as error:
        raise SystemExit(f"Object decode failed: {error}")
