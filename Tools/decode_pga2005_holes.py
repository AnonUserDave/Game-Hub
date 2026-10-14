#!/usr/bin/env python3
"""Read authoritative original version-7 TCR hole/tee/pin arrays statically.

Bound to Engine.dll CHole::ReadHoleInfo (0x1018249b). Coordinates are copied
without inventing INI transforms or executing original code.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

from decode_pga2005_library import CourseFile
from import_pga2005 import atomic_write, parse_course_ini


def decode_holes(data: bytes, ini_data: bytes | None = None):
    course = CourseFile(data, "TCR")
    root = course.u32(0xe0)
    size = course.u32(root)
    course.range(root, size, header=True)
    count = course.u16(root + 0x10)
    if not 0 < count <= 64 or size < 0x12 + count * 4:
        raise ValueError("Invalid course hole-information block")

    def block_range(offset, length):
        if offset < root or offset + length > root + size:
            raise ValueError("Hole data escapes course-information block")
        return course.range(offset, length, header=True)

    def points(relative, count):
        if not 0 <= count <= 1024:
            raise ValueError("Invalid hole point count")
        offset = root + relative
        block_range(offset, count * 12)
        result = []
        for i in range(count):
            xyz = struct.unpack_from("<3f", data, offset + i * 12)
            if not all(math.isfinite(v) and abs(v) < 1e10 for v in xyz):
                raise ValueError("Invalid hole coordinates")
            result.append({"index": i, "xyz_raw": list(xyz), "source_offset": offset + i * 12})
        return result

    ini_holes = {h["number"]: h for h in parse_course_ini(ini_data)["holes"]} if ini_data else {}
    holes, comparisons = [], []
    origin = struct.unpack_from("<3f", data, 0x318)
    for number in range(1, count + 1):
        relative = course.u32(root + 0xe + number * 4)
        record = root + relative
        block_range(record, 0x1c)
        par, old_yardage, handicap, tees, aiming, pins = struct.unpack_from("<6H", data, record)
        entry = {"number": number, "par": par, "handicap": handicap,
                 "legacy_yardage": old_yardage,
                 "tee_count": tees, "pin_count": pins, "aim_point_count": aiming,
                 "tees": points(course.u32(record + 0x10), tees),
                 "pins": points(course.u32(record + 0x18), pins),
                 "aim_points": points(course.u32(record + 0x14), aiming),
                 "provenance": {"hole_record_offset": record,
                                "hole_record_relative_to_info_block": relative}}
        if number in ini_holes:
            ini = ini_holes[number]
            if "yardage" in ini:
                entry["yardages_by_tee"] = ini["yardage"]
                entry["yardage_provenance"] = "Original INI yardage override, consumed by CHole::ReadIni 0x10182acd"
            for kind in ("tees", "pins"):
                by_index = {int(p["key"].removeprefix(kind[:-1])): p for p in ini[kind]}
                for native in entry[kind]:
                    if native["index"] not in by_index:
                        continue
                    raw = by_index[native["index"]]["xyz_raw"]
                    predicted = [raw[0] * 12 - origin[0], raw[1] * 12, raw[2] * 12 - origin[2]]
                    comparisons.append(max(abs(a - b) for a, b in zip(predicted, native["xyz_raw"])))
        holes.append(entry)
    result = {"schema_version": 1, "course_title": course.title,
              "source_tcr_sha256": course.digest,
              "source_decoder_dll_sha256": "94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728",
              "coordinate_space": "Original TCR world XYZ; copied unchanged from source float32 arrays",
              "units": "Original engine units; inches corroborated by CHole::TotalYards distance/36 conversion",
              "hole_count": count, "holes": holes,
              "field_classification": {"par": "Source CHole::ReadHoleInfo field at record+0",
                                       "handicap": "Source CHole::ReadHoleInfo field at record+4",
                                       "legacy_yardage": "Stored u16 at record+2; yardage interpretation corroborated against original INI"},
              "provenance": {"info_block_offset": root, "info_block_bytes": size,
                             "reader": "Engine.dll CHole::ReadHoleInfo 0x1018249b",
                             "tee_accessor": "CHole::TeePosition 0x1017fd5c",
                             "pin_accessor": "CHole::PinPosition 0x1017ff55",
                             "position_copy": "Utils.dll APosition::APosition 0x10010560 / UpdatePosition 0x10010940"},
              "limitations": ["Primary authored tee/pin choices are preserved; original dynamic pin/tee selection rules still need reconstruction.",
                              "Legacy yardage is the TCR record field; original INI overrides are kept separately when supplied.",
                              "Aim-point semantics and gameplay settings require additional verification."]}
    if comparisons:
        result["ini_coordinate_comparison"] = {"matched_points": len(comparisons),
            "max_absolute_error": max(comparisons),
            "observed_relation": "TCR XYZ ~= (INI.x*12-origin.x, INI.y*12, INI.z*12-origin.z)",
            "classification": "Static numerical corroboration; emitted coordinates come directly from TCR"}
    if ini_data:
        result["source_ini_sha256"] = hashlib.sha256(ini_data).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--course", required=True, type=Path)
    parser.add_argument("--ini", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = decode_holes(args.course.read_bytes(), args.ini.read_bytes() if args.ini else None)
    atomic_write(args.output, (json.dumps(result, indent=2) + "\n").encode())
    print(json.dumps({"hole_count": result["hole_count"],
                      "tee_count": sum(h["tee_count"] for h in result["holes"]),
                      "pin_count": sum(h["pin_count"] for h in result["holes"]),
                      "ini_coordinate_comparison": result.get("ini_coordinate_comparison")}, indent=2))


if __name__ == "__main__":
    main()
