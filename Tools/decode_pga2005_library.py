#!/usr/bin/env python3
"""Recover version-7 original course materials/textures from owned TCR/TCL files.

Static, standard-library decoder based on CourseData.dll named functions.
No Windows code executes. Original DDS and PNG outputs belong in ignored
Library/Imported. See docs/research/PGA2005-REA.md for evidence and limitations.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import uuid

from import_pga2005 import atomic_write, decode_dds, png_bytes


MAX_FILE_BYTES = 256 * 1024 * 1024
DESCRIPTOR_BYTES = 19
SECTION_BYTES = 83
SURFACE_BYTES = 68
SOURCE_DLL_SHA256 = "36664435b88646e6b96d55f81573e1fdb73ee88e7f54762c4a723c693832e82c"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class CourseFile:
    def __init__(self, data: bytes, label: str):
        self.data, self.label = data, label
        if not 0x324 <= len(data) <= MAX_FILE_BYTES:
            raise ValueError(f"{label}: invalid file byte count")
        self.version = self.u16(0)
        if self.version != 7:
            raise ValueError(f"{label}: only observed version 7 is supported")
        self.header_bytes = self.u32(0x3e)
        self.range(0, self.header_bytes)
        if self.header_bytes < 0x324:
            raise ValueError(f"{label}: truncated declared header")
        self.guid_bytes = data[2:18]
        self.guid = str(uuid.UUID(bytes_le=self.guid_bytes))
        self.digest = sha256(data)
        self.title = self.text(data[22:62])

    @staticmethod
    def text(data):
        return data.split(b"\0", 1)[0].decode("cp1252")

    def range(self, offset: int, count: int, *, header=False):
        limit = self.header_bytes if header else len(self.data)
        if offset < 0 or count < 0 or offset + count > limit:
            raise ValueError(f"{self.label}: invalid range {offset}+{count}/{limit}")
        return self.data[offset:offset + count]

    def u16(self, offset):
        return struct.unpack("<H", self.range(offset, 2))[0]

    def u32(self, offset):
        return struct.unpack("<I", self.range(offset, 4))[0]

    def descriptor(self, table_field: int, index: int):
        if index < 0:
            raise ValueError("Negative descriptor index")
        offset = self.u32(table_field) + index * DESCRIPTOR_BYTES
        self.range(offset, DESCRIPTOR_BYTES, header=True)
        source, location, data_location, count, references, flags = struct.unpack_from(
            "<IIIIHB", self.data, offset)
        payload = self.range(source, count)
        return payload, {"descriptor_offset": offset, "source_offset": source,
                         "source_bytes": count, "source_sha256": sha256(payload),
                         "location": location, "data_location": data_location,
                         "references": references, "flags": flags}


def surface_records(library: CourseFile, texture_index: int):
    count = library.u16(0x50)
    if not 0 <= texture_index < count:
        raise ValueError("Texture section index exceeds library count")
    section_offset = library.u32(0xe4) + texture_index * SECTION_BYTES
    section = library.range(section_offset, SECTION_BYTES, header=True)
    surface_count = struct.unpack_from("<H", section, 0x4d)[0]
    surface_offset = struct.unpack_from("<I", section, 0x4f)[0]
    if surface_count > 1024:
        raise ValueError("Unsupported terrain surface count")
    library.range(surface_offset, surface_count * SURFACE_BYTES, header=True)
    records = []
    for i in range(surface_count):
        offset = surface_offset + i * SURFACE_BYTES
        raw = library.range(offset, SURFACE_BYTES, header=True)
        coefficients = struct.unpack_from("<10f", raw)
        if not all(math.isfinite(value) for value in coefficients):
            raise ValueError("Non-finite terrain coefficients")
        records.append({"index": i, "name": library.text(raw[0x2e:]),
                        "flags": struct.unpack_from("<I", raw, 0x28)[0],
                        "coefficients": list(coefficients),
                        "lie_graphic_index": struct.unpack_from("<H", raw, 0x2c)[0],
                        "source_offset": offset})
    return records, {"source_offset": section_offset,
                     "raw_hex": section.hex(), "surface_count": surface_count}


def decode_materials(course_data: bytes, library_data: list[bytes],
                     output: Path, used_ids: set[int] | None = None):
    course = CourseFile(course_data, "TCR")
    libraries = [CourseFile(data, f"TCL {i}") for i, data in enumerate(library_data)]
    by_guid = {}
    for library in libraries:
        if library.guid_bytes in by_guid:
            raise ValueError("Duplicate library GUID")
        by_guid[library.guid_bytes] = library
    library_count = course.u16(0x5e)
    if not 0 < library_count <= 64:
        raise ValueError("Unsupported course library reference count")
    course.range(0x10c, library_count * 16, header=True)
    ordered = []
    for i in range(library_count):
        guid = course.range(0x10c + i * 16, 16, header=True)
        if guid not in by_guid:
            raise ValueError(f"Missing TCL for library GUID {uuid.UUID(bytes_le=guid)}")
        ordered.append(by_guid[guid])
    material_count = course.u16(0x50)
    table = course.u32(0x80)
    course.range(table, material_count * DESCRIPTOR_BYTES, header=True)
    selected = sorted(used_ids if used_ids is not None else range(material_count))
    if not selected or any(i < 0 or i >= material_count for i in selected):
        raise ValueError("Invalid requested material IDs")
    materials, images, cache = [], [], {}
    output.mkdir(parents=True, exist_ok=True)
    for material_id in selected:
        offset = table + material_id * DESCRIPTOR_BYTES
        texture_index = course.u16(offset + 4)
        library_index = course.data[offset + 18] >> 2
        if library_index >= len(ordered):
            raise ValueError("Material references unavailable library index")
        library = ordered[library_index]
        if texture_index >= library.u16(0x50):
            # Original code silently selects texture zero; strict importer keeps
            # unexpected inputs visible instead of giving the wrong material.
            raise ValueError("Material references out-of-range texture")
        key = (library_index, texture_index)
        if key not in cache:
            payload, descriptor = library.descriptor(0x80, texture_index)
            if len(payload) < 132 or payload[4:8] != b"DDS ":
                raise ValueError(f"Material {material_id}: unsupported texture payload")
            dds_bytes = struct.unpack_from("<I", payload)[0]
            if dds_bytes != len(payload) - 4:
                raise ValueError("DDS length prefix does not match descriptor byte count")
            dds = payload[4:]
            width, height, rgba = decode_dds(dds)
            stem = f"library-{library_index}-texture-{texture_index:04d}"
            png_path = f"textures/{stem}.png"
            dds_path = f"textures/{stem}.dds"
            atomic_write(output / png_path, png_bytes(width, height, rgba))
            atomic_write(output / dds_path, dds)
            name_payload, name_descriptor = library.descriptor(0x7c, texture_index)
            entry = {"library_index": library_index, "texture_index": texture_index,
                     "name": library.text(name_payload), "texture": png_path,
                     "original_dds": dds_path, "width": width, "height": height,
                     "dds_fourcc": dds[84:88].decode("ascii", errors="replace").rstrip("\0"),
                     "mipmap_count": struct.unpack_from("<I", dds, 28)[0],
                     "dds_sha256": sha256(dds), "rgba_sha256": sha256(rgba),
                     "provenance": {"library_guid": library.guid,
                                    "library_sha256": library.digest,
                                    "texture_descriptor": descriptor,
                                    "name_descriptor": name_descriptor}}
            cache[key] = entry
            images.append(entry)
        entry = cache[key]
        surfaces, section = surface_records(library, texture_index)
        materials.append({"id": material_id, "library_index": library_index,
                          "texture_index": texture_index, "name": entry["name"],
                          "texture": entry["texture"], "original_dds": entry["original_dds"],
                          "width": entry["width"], "height": entry["height"],
                          "surface_types": surfaces,
                          "provenance": {"course_descriptor_offset": offset,
                                         "library_guid": library.guid,
                                         "library_sha256": library.digest,
                                         "texture_section": section}})
    return {"schema_version": 1, "course_title": course.title,
            "source_tcr_sha256": course.digest, "source_decoder_dll_sha256": SOURCE_DLL_SHA256,
            "method": "Static CourseData.dll-bound TCR/TCL descriptor reconstruction; no target execution",
            "summary": {"course_material_count": material_count,
                        "selected_material_count": len(materials), "texture_count": len(images),
                        "library_count": len(ordered)},
            "libraries": [{"index": i, "guid": l.guid, "sha256": l.digest,
                           "title": l.title, "texture_count": l.u16(0x50)}
                          for i, l in enumerate(ordered)],
            "materials": materials, "textures": images,
            "sampling": {"wrap_s": "repeat", "wrap_t": "repeat",
                         "png_pixels": "Deterministic decoded original DDS base level; PNG adds no further loss"},
            "evidence": {"material_link": "CourseDataManager::GetTextureInfo 0x10009940",
                         "texture_payload": "LibraryC::GetTexture 0x1000c070; GetTextureDescriptor 0x1000c7d0",
                         "texture_name": "LibraryC::GetTextureName 0x1000bfe0",
                         "texture_section": "LibraryC::GetFullTextureInfo 0x1000c560",
                         "surface_records": "LibraryC::GetTerrainInfo 0x1000c5a0; TerrainPropsInfo 0x10009c50; TerrainPropsLieText 0x10009de0"},
            "limitations": ["Only observed version-7 TCR/TCL layouts are supported.",
                            "PNG stores the original DDS base level; original DDS mip levels are retained separately.",
                            "Shader effects, texture-coordinate adjustments, alpha blending, lighting and water animation still need native renderer parity work.",
                            "Original GPU DDS interpolation rounding still needs visual comparison.",
                            "Surface names/flags and ten coefficient values are preserved; coefficient meanings and flag semantics are not fully reconstructed."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--course", required=True, type=Path)
    parser.add_argument("--library", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mesh-report", type=Path, help="Restrict to source-matched used mesh material IDs")
    args = parser.parse_args()
    course_data = args.course.read_bytes()
    used_ids = None
    if args.mesh_report:
        report = json.loads(args.mesh_report.read_text())
        if report.get("source_tcr_sha256") != sha256(course_data):
            parser.error("Mesh report SHA-256 does not match requested TCR")
        used_ids = {int(i) for i in report["material_triangle_counts"]}
    result = decode_materials(course_data, [p.read_bytes() for p in args.library], args.output, used_ids)
    atomic_write(args.output / "materials.json", (json.dumps(result, indent=2) + "\n").encode())
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
