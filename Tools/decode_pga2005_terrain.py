#!/usr/bin/env python3
"""Recover source TCR terrain vertices for a native research viewer.

This is a version-7 static decoder derived from shipped CourseData/Engine DLLs,
not a replacement game engine. It emits original vertices and triangle groups;
texture/material reconstruction remains incomplete. Proprietary output stays
in ignored Library/Imported. See docs/research/PGA2005-REA.md for evidence.

GHPC v3 adds one record per source patch with the u16 at descriptor +0x61.
Its low five bits name the hole whose local world owns the patch; the higher
bits are course-condition variant masks. Holes share one coordinate space but
overlap, so a consumer must select a single hole's patches.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

from import_pga2005 import atomic_write
from inspect_pga2005 import ISO9660

PATCH_STRIDE = 0x136
PATCH_LAYER_FIELD = 0x61
SOURCE_DLL_SHA256 = "36664435b88646e6b96d55f81573e1fdb73ee88e7f54762c4a723c693832e82c"
MAX_VERTICES = 4_000_000


def packed_coordinate(data: bytes, offset: int) -> int:
    """Source0x1000e110: high byte followed by little-endian low word."""
    high, low = data[offset], struct.unpack_from("<H", data, offset + 1)[0]
    value = (high << 16) | low
    if high & 8:
        value |= 0xfff00000
    return value - 0x100000000 if value & 0x80000000 else value


def decode(data: bytes, mesh: bool = True) -> tuple[bytes, dict]:
    if len(data) < 0x324:
        raise ValueError("Truncated TCR header")
    version = struct.unpack_from("<H", data, 0)[0]
    if version != 7:
        raise ValueError(f"Only observed TCR version 7 is supported, received {version}")
    header_size = struct.unpack_from("<I", data, 0x3e)[0]
    patch_count = struct.unpack_from("<H", data, 0x46)[0]
    table = struct.unpack_from("<I", data, 0x104)[0]
    if (not 0x324 <= header_size <= len(data) or table < 0x324
            or table + patch_count * PATCH_STRIDE != header_size):
        raise ValueError("Unsupported or malformed patch table bounds")
    scale_y, scale_xz = struct.unpack_from("<ff", data, 0xd8)
    origin = struct.unpack_from("<fff", data, 0x318)
    if (not all(math.isfinite(v) for v in (scale_y, scale_xz, *origin))
            or scale_y <= 0 or scale_xz <= 0):
        raise ValueError("Invalid compressed vertex scales/origin")
    records = bytearray()
    triangles = bytearray()
    patch_records = bytearray()
    group_count = 0
    material_counts = {}
    minimum, maximum = [math.inf] * 3, [-math.inf] * 3
    patches = []
    total = 0
    for i in range(patch_count):
        base = table + i * PATCH_STRIDE
        source, location, data_location, size = struct.unpack_from("<IIII", data, base)
        counts = struct.unpack_from("<4H", data, base + 0x33)
        # Source GetNumPoints uses max of four layer counts. All share the same
        # initial point buffer in this observed file family; retain each count.
        count = max(counts)
        if source < header_size or source + size > len(data) or count * 20 > size:
            raise ValueError(f"Patch {i} has invalid payload/vertex bounds")
        layer = struct.unpack_from("<H", data, base + PATCH_LAYER_FIELD)[0]
        patch_vertex_base = total
        patch_triangle_base = len(triangles) // 16
        total += count
        if total > MAX_VERTICES:
            raise ValueError("Vertex resource bound exceeded")
        for j in range(count):
            offset = source + j * 20
            xyz = (packed_coordinate(data, offset) / scale_xz + origin[0],
                   packed_coordinate(data, offset + 3) / scale_y + origin[1],
                   packed_coordinate(data, offset + 6) / scale_xz + origin[2])
            uv = struct.unpack_from("<ff", data, offset + 12)
            if not all(math.isfinite(v) and abs(v) < 1e10 for v in (*xyz, *uv)):
                raise ValueError(f"Patch {i}, vertex {j} has invalid coordinates/UV")
            for k, value in enumerate(xyz):
                minimum[k], maximum[k] = min(minimum[k], value), max(maximum[k], value)
            # Source GetDiffuse assembles opaque RGB from bytes9,10,11.
            records.extend(struct.pack("<3f4B2f", *xyz, data[offset + 9],
                                       data[offset + 10], data[offset + 11], 255, *uv))
        if mesh:
            poly = struct.unpack_from("<I", data, base + 0x81)[0]
            if poly + 0x3d > size:
                raise ValueError(f"Patch {i} primary polygon object exceeds payload")
            groups = struct.unpack_from("<I", data, source + poly + 0x18)[0]
            if poly + 0x3d + groups * 0x2c > size:
                raise ValueError(f"Patch {i} material groups exceed payload")
            covered_vertices = 0
            for group in range(groups):
                entry = source + poly + 0x41 + group * 0x2c
                index_relative, faces, vertex_relative, vertices, terrain_id = struct.unpack_from("<iIiII", data, entry)
                vertex_offset, index_offset = poly + vertex_relative, poly + index_relative
                if (vertex_offset != covered_vertices * 20 or vertex_offset < 0
                        or vertex_offset + vertices * 20 > count * 20
                        or index_offset < 0 or index_offset + faces * 6 > size):
                    raise ValueError(f"Patch {i} group {group} has unsupported vertex/index layout")
                base_index = patch_vertex_base + covered_vertices
                covered_vertices += vertices
                for face in range(faces):
                    indices = struct.unpack_from("<3H", data, source + index_offset + face * 6)
                    if any(v >= vertices for v in indices) or len(set(indices)) != 3:
                        raise ValueError(f"Patch {i} group {group} invalid triangle {face}")
                    triangles.extend(struct.pack("<4I", *(base_index + v for v in indices), terrain_id))
                material_counts[terrain_id] = material_counts.get(terrain_id, 0) + faces
            if covered_vertices != count:
                raise ValueError(f"Patch {i} groups do not cover the primary vertex buffer")
            group_count += groups
            patch_records.extend(struct.pack("<5I", layer, patch_vertex_base, count,
                                             patch_triangle_base, len(triangles) // 16 - patch_triangle_base))
        patches.append({"index": i, "descriptor_offset": base, "source_offset": source,
                        "payload_bytes": size, "layer_vertex_counts": list(counts),
                        "decoded_vertices": count, "layer_field": layer,
                        "hole": layer & 0x1f, "condition_mask": layer & ~0x1f})
    if total == 0:
        raise ValueError("No vertices in course")
    triangle_count = len(triangles) // 16
    header = (b"GHPC" + struct.pack("<IIII6fI", 3, total, triangle_count, group_count, *minimum, *maximum, patch_count)
              if mesh else b"GHPC" + struct.pack("<II6f", 1, total, *minimum, *maximum))
    holes, conditions = {}, {}
    for patch in patches:
        holes[patch["hole"]] = holes.get(patch["hole"], 0) + 1
        conditions[patch["condition_mask"]] = conditions.get(patch["condition_mask"], 0) + 1
    title = data[22:62].split(b"\0", 1)[0].decode("cp1252")
    report = {"schema_version": 1, "title": title, "tcr_version": version,
              "source_tcr_sha256": hashlib.sha256(data).hexdigest(),
              "source_decoder_dll_sha256": SOURCE_DLL_SHA256,
              "evidence": {
                  "header": "CourseData.dll MappedCourseC::ReadHeaders 0x1000d180",
                  "patch_table": "CourseDataManager::LoadAPatch 0x10008990; stride 0x136",
                  "counts": "tagPatch::GetNumPoints 0x10002f60",
                  "scales": "CourseDataManager::Init 0x100095c0; SetScales 0x1000de40",
                  "position_uv": "TerrainVertexCompressed::GetTerrainVertex 0x1000e110",
                  "color": "TerrainVertexCompressed::GetDiffuse 0x1000e0f0"},
              "method": "Static source-bound coordinate reconstruction; no original code execution",
              "header_bytes": header_size, "patch_count": patch_count,
              "point_count": total, "triangle_count": triangle_count, "group_count": group_count,
              "patch_layers": {
                  "field": "u16 at patch descriptor +0x61",
                  "hole_bits": "0x001f: one-based hole whose local world owns the patch",
                  "condition_bits": "0xffe0: course-condition variant masks; 0 = always present for that hole",
                  "patches_by_hole": {str(k): v for k, v in sorted(holes.items())},
                  "patches_by_condition_mask": {hex(k): v for k, v in sorted(conditions.items())},
                  "classification": "Static data observation corroborated by per-hole tee/pin floor checks; original selection code pending"},
              "material_triangle_counts": material_counts,
              "bounds_raw": {"min": minimum, "max": maximum},
              "scales": {"y": scale_y, "xz": scale_xz, "origin": list(origin)},
              "format": {"file": "terrain.ghpc", "version": 3 if mesh else 1,
                         "header_bytes": 48 if mesh else 36, "record_bytes": 24,
                         "record": "little-endian xyz:f32[3], rgba:u8[4], uv:f32[2]",
                         "triangle_record_bytes": 16 if mesh else 0,
                         "triangle_record": "little-endian vertex_indices:u32[3], terrain_id:u32",
                         "patch_record_bytes": 20 if mesh else 0,
                         "patch_record": "little-endian layer_field:u32, first_vertex:u32, vertex_count:u32, first_triangle:u32, triangle_count:u32"},
              "limitations": [
                  "Primary terrain geometry only; alternate LOD layers, vegetation and other objects are not reconstructed.",
                  "Each hole is a separate overlapping local world; drawing every patch at once overlays 18 holes and all condition variants.",
                  "Source positions are a left-handed (DirectX-style) world; a right-handed renderer must mirror one axis.",
                  "Baked diffuse values alone do not reproduce original terrain textures/lighting.",
                  "Course world coordinates are preserved; inch-based physical units are inferred, not yet runtime-verified.",
                  "INI hole metadata and TCR world coordinates still need an independently confirmed transform.",
                  "Position calculations are rounded to float32 on output; original x87 intermediate rounding has not been reproduced.",
                  "This decoder is bounded to the observed version-7 compressed terrain layout; no global format support claim."]}
    report["patches"] = patches
    if mesh:
        report["evidence"]["triangle_groups"] = "Engine.dll AddPatchToMesh 0x102039b5, CreateMesh 0x10203dad, CRTerrain::VBAddPolys_Terrain 0x101c4be2"
    return header + records + triangles + (patch_records if mesh else b""), report


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Extracted version-7 .TCR file")
    parser.add_argument("--course", default="PBL", help="Course ID on supplied courses disc")
    parser.add_argument("--media", type=Path, default=root / "Library/SourceMedia/pga2005/EA-TigerWoodsPGATour2005-CD3-CoursesDisc.B6I")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--points-only", action="store_true", help="Export GHPC v1 points without triangle groups")
    args = parser.parse_args()
    if not args.course.isalnum() or len(args.course) > 16:
        raise ValueError("Invalid course identifier")
    course = args.course.upper()
    if args.source:
        data = args.source.read_bytes()
        source_name = str(args.source)
    else:
        iso = ISO9660(args.media)
        try:
            entry = next((e for e in iso.files() if e["path"] == f"COURSES/{course}/{course}.TCR"), None)
            if entry is None:
                raise ValueError(f"No {course} TCR found on courses disc")
            data = b"".join(iso.chunks(entry))
            source_name = entry["path"]
        finally:
            iso.close()
    result, report = decode(data, mesh=not args.points_only)
    output = args.output or root / "Library/Imported/pga2005" / course
    report["source_path"] = source_name
    report["output_sha256"] = hashlib.sha256(result).hexdigest()
    atomic_write(output / "terrain.ghpc", result)
    atomic_write(output / "terrain-report.json", (json.dumps(report, indent=2) + "\n").encode())
    print(f"{report['title']}: {report['patch_count']} patches, {report['point_count']} original vertices, {report['triangle_count']} original triangles")
    print(output / "terrain.ghpc")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, struct.error) as error:
        raise SystemExit(f"Terrain decode failed: {error}")
