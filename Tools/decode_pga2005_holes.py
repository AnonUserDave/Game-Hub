#!/usr/bin/env python3
"""Read authoritative original version-7 TCR hole/tee/pin arrays statically.

Bound to Engine.dll CHole::ReadHoleInfo (0x1018249b). Coordinates are copied
without inventing INI transforms or executing original code. The per-hole
out-of-bounds/unplayable lines come from the compiled TCR polygon arrays read
by CHole::CheckHazard (0x10181371); the INI copies are kept for comparison.
Rules derived from these records are documented in
docs/research/PGA2005-RULES.md; `check_hazard` below is a reference port.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

from decode_pga2005_library import CourseFile
from import_pga2005 import atomic_write, parse_course_ini

POLYGON_BYTES = 0x1e  # CourseInfoHeader2::Fixup (CourseData 0x1000db50) strides 0x1e
# CHole::CheckHazard: type 1 and 3 mark the lie 0x20 (unplayable), type 2 marks
# 0x80 (out of bounds). Type 3 additionally needs the ball inside the bbox and
# only occurs in the (empty) course-level array.
POLYGON_KINDS = {1: "unplayable", 2: "out_of_bounds", 3: "unplayable"}
# Course INI [Conditions], read by CourseData CourseInfoC::GetDefault* with
# GetPrivateProfileIntA; key -> (output name, reader default).
CONDITION_KEYS = {"skydome": ("skydome", 1), "greencond": ("green_cond", 3),
                  "roughlength": ("rough_length", 2), "windspeed": ("wind_speed", 1)}
INTERSECT_EPSILON = 0.001  # Utils.dll IntersectLine constant 0x100325a8
VERTICAL_SLOPE = 1e300     # Utils.dll IntersectLine constant 0x10032628


def intersect_line(x1, y1, x2, y2, x3, y3, x4, y4):
    """Port of Utils.dll IntersectLine(double...) 0x1000cdc0.

    Returns 0 (no hit or parallel), 1 (proper hit), 2 (at p1), 3 (at p2),
    4 (at p3) or 5 (at p4); the endpoint checks run in that order.
    """
    eps = INTERSECT_EPSILON
    m1 = (y1 - y2) / (x1 - x2) if abs(x1 - x2) >= eps else VERTICAL_SLOPE
    m2 = (y3 - y4) / (x3 - x4) if abs(x3 - x4) >= eps else VERTICAL_SLOPE
    b1 = y1 - m1 * x1 if abs(m1 - VERTICAL_SLOPE) >= eps else 1e300
    b2 = y3 - m2 * x3 if abs(m2 - VERTICAL_SLOPE) >= eps else 1e300
    if abs(m1 - m2) < eps:
        return 0
    if abs(m1 - VERTICAL_SLOPE) >= eps:
        if abs(m2 - VERTICAL_SLOPE) >= eps:
            x = (b1 - b2) / (m2 - m1)
            y = x * m1 + b1 if abs(m1) >= eps else y2
        else:
            x = x3
            y = y2 - ((x2 - x3) * (y2 - y1)) / (x2 - x1)
    else:
        x = x1
        y = y4 - ((y4 - y3) * (x4 - x1)) / (x4 - x3)
    near = [abs(x - x1) < eps, abs(x - x2) < eps, abs(x - x3) < eps, abs(x - x4) < eps,
            abs(y - y1) < eps, abs(y - y2) < eps, abs(y - y3) < eps, abs(y - y4) < eps]
    spans = [0.0 if near[0] or near[1] else (x - x2) * (x - x1),
             0.0 if near[2] or near[3] else (x - x4) * (x - x3),
             0.0 if near[4] or near[5] else (y - y2) * (y - y1),
             0.0 if near[6] or near[7] else (y - y4) * (y - y3)]
    if any(v > 0.0 for v in spans):
        return 0
    for code, (a, b) in enumerate(((0, 4), (1, 5), (2, 6), (3, 7)), 2):
        if near[a] and near[b]:
            return code
    return 1


def check_hazard(hole_line, polygons, point):
    """Reference port of CHole::CheckHazard 0x10181371 for hole polygons.

    hole_line: [(x, z), ...] = selected tee, aim points, selected pin.
    polygons: [{"type": t, "points_raw": [[x, z], ...]}, ...] in TCR order.
    point: (x, z) ball position. Returns 0x20 (unplayable), 0x80 (out of
    bounds) or 0. The original also sets 0x80 when there is no terrain under
    the ball; that terrain query is outside this reference.
    """
    origin = min(hole_line, key=lambda p: math.hypot(p[0] - point[0], p[1] - point[1]))
    unplayable = out = 0
    for polygon in polygons:
        crossings, edges = 0, polygon["points_raw"]
        for a, b in zip(edges, edges[1:]):  # n-1 edges: lines are not closed implicitly
            code = intersect_line(origin[0], origin[1], point[0], point[1], a[0], a[1], b[0], b[1])
            if code in (1, 4):
                crossings += 1
            elif code == 3:  # ball exactly on the line counts as not crossing
                crossings = 0
                break
        if crossings % 2:
            if polygon["type"] in (1, 3):
                unplayable += 1
            elif polygon["type"] == 2:
                out += 1
    if unplayable % 2:
        return 0x20
    if out % 2:
        return 0x80
    return 0


def _profile(ini_data):
    """GetPrivateProfile view: case-insensitive, first section/key wins."""
    sections = {}
    for section in parse_course_ini(ini_data)["sections"]:
        entries = sections.setdefault(section["name"].strip().lower(), {})
        for entry in section["entries"]:
            entries.setdefault(entry["key"].lower(), entry["value"])
    return sections


def _profile_int(value):
    digits = value.strip()
    sign = -1 if digits.startswith("-") else 1
    digits = digits.lstrip("+-")
    number = ""
    for ch in digits:
        if not ch.isdigit():
            break
        number += ch
    return sign * int(number) if number else 0


def _floats(value, count):
    parts = [float(v.strip()) for v in value.split(",")]
    if len(parts) != count or not all(math.isfinite(v) and abs(v) < 1e9 for v in parts):
        raise ValueError("Invalid INI coordinate list")
    return parts


def _indexed(entries, prefix):
    """prefix0, prefix1, ... until the first missing key (GetPrivateProfile loop)."""
    result, index = [], 0
    while f"{prefix}{index}" in entries:
        result.append(entries[f"{prefix}{index}"])
        index += 1
    return result


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

    def polygons(relative, count, array_label):
        if not 0 <= count <= 256:
            raise ValueError("Invalid polygon count")
        result = []
        for i in range(count):
            offset = root + relative + i * POLYGON_BYTES
            block_range(offset, POLYGON_BYTES)
            head, kind, n, pts, *bbox = struct.unpack_from("<IihI4f", data, offset)
            if not 2 <= n <= 1024:
                raise ValueError("Invalid polygon point count")
            if not all(math.isfinite(v) and abs(v) < 1e10 for v in bbox):
                raise ValueError("Invalid polygon bounds")
            xz = []
            for point in points(pts, n):
                x, _, z = point["xyz_raw"]
                xz.append([x, z])
            result.append({"index": i, "type": kind, "kind": POLYGON_KINDS.get(kind, "unknown"),
                           "closed": xz[0] == xz[-1], "points_raw": xz,
                           "bbox_raw": list(bbox), "source_offset": offset,
                           "source_array": array_label, "header_word": head})
        return result

    ini_holes = {h["number"]: h for h in parse_course_ini(ini_data)["holes"]} if ini_data else {}
    profile = _profile(ini_data) if ini_data else {}
    holes, comparisons, ob_errors, pivot_errors = [], [], [], []
    ob_mismatches, pivot_mismatches = [], []
    origin = struct.unpack_from("<3f", data, 0x318)

    def ini_xz_to_raw(x, z, clamp=False):
        # TCR frame = (feet - courseMin) * 12; CCourse::MakeGameWorldPosition
        # 0x1017e052 also clamps runtime INI points (coastline) to the minimum.
        rx, rz = x * 12 - origin[0], z * 12 - origin[2]
        return [max(rx, 0.0), max(rz, 0.0)] if clamp else [rx, rz]

    # Course-level arrays (CourseInfoHeader2 +0xc/+0x6a and +0xe/+0x6e); only
    # the first is read by CheckHazard. Both are empty in every shipped course.
    course_polygons = []
    if size >= 0x72:
        count_a, count_b = struct.unpack_from("<hh", data, root + 0xc)
        array_a, array_b = struct.unpack_from("<II", data, root + 0x6a)
        course_polygons = (polygons(array_a, -count_a if count_a <= 0 else 0, "course+0x6a")
                           + polygons(array_b, -count_b if count_b <= 0 else 0, "course+0x6e"))
    for number in range(1, count + 1):
        relative = course.u32(root + 0xe + number * 4)
        record = root + relative
        block_range(record, 0x1c)
        par, old_yardage, handicap, tees, aiming, pins = struct.unpack_from("<6H", data, record)
        block_range(record, 0x24)
        # CourseInfoHeader2 per-hole fixup (CourseData 0x1000dc70) stores the
        # polygon count negated; a positive stored value is reset to zero.
        stored_polygons = struct.unpack_from("<h", data, record + 0xe)[0]
        polygon_count = -stored_polygons if stored_polygons <= 0 else 0
        entry = {"number": number, "par": par, "handicap": handicap,
                 "legacy_yardage": old_yardage,
                 "tee_count": tees, "pin_count": pins, "aim_point_count": aiming,
                 "tees": points(course.u32(record + 0x10), tees),
                 "pins": points(course.u32(record + 0x18), pins),
                 "aim_points": points(course.u32(record + 0x14), aiming),
                 "ob_polygons": polygons(course.u32(record + 0x20), polygon_count, "hole+0x20"),
                 "provenance": {"hole_record_offset": record,
                                "hole_record_relative_to_info_block": relative,
                                "polygon_count_stored": stored_polygons}}
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
        if profile:
            hole_section = profile.get(f"hole {number}", {})
            # [Hole n OB k]: GetPrivateProfile-style lookup, k = 1, 2, ... until missing.
            ini_polygons, k = [], 1
            while f"hole {number} ob {k}" in profile:
                section = profile[f"hole {number} ob {k}"]
                feet = [_floats(v, 2) for v in _indexed(section, "point")]
                ini_polygons.append({"section": f"Hole {number} OB {k}",
                                     "type": _profile_int(section.get("type", "0")),
                                     "declared_points": _profile_int(section.get("points", "0")),
                                     "points_feet": feet})
                k += 1
            if len(ini_polygons) != len(entry["ob_polygons"]):
                ob_mismatches.append({"hole": number, "reason": "polygon count",
                                      "tcr": len(entry["ob_polygons"]), "ini": len(ini_polygons)})
            for native, ini_polygon in zip(entry["ob_polygons"], ini_polygons):
                native["ini_section"] = ini_polygon["section"]
                native["points_feet"] = ini_polygon["points_feet"]
                if (ini_polygon["type"] != native["type"] or len(ini_polygon["points_feet"]) != len(native["points_raw"])
                        or ini_polygon["declared_points"] != len(native["points_raw"])):
                    ob_mismatches.append({"hole": number, "section": ini_polygon["section"],
                                          "reason": "type or point count"})
                    continue
                for (fx, fz), (x, z) in zip(ini_polygon["points_feet"], native["points_raw"]):
                    rx, rz = ini_xz_to_raw(fx, fz)
                    ob_errors.append(max(abs(rx - x), abs(rz - z)))
            # Pivots: the INI repeats pivotN keys; GetPrivateProfile keeps the first.
            pivots_feet = [_floats(v, 3) for v in _indexed(hole_section, "pivot")]
            entry["pivots_feet"] = pivots_feet
            entry["pivots_raw"] = [[x * 12 - origin[0], y * 12, z * 12 - origin[2]] for x, y, z in pivots_feet]
            entry["pivot_ini_duplicate_keys"] = sum(1 for p in ini_holes.get(number, {}).get("pivots", [])) - len(pivots_feet)
            if len(pivots_feet) == len(entry["aim_points"]):
                for predicted, native in zip(entry["pivots_raw"], entry["aim_points"]):
                    pivot_errors.append(max(abs(a - b) for a, b in zip(predicted, native["xyz_raw"])))
            else:
                pivot_mismatches.append({"hole": number, "tcr_aim_points": len(entry["aim_points"]),
                                         "ini_pivots": len(pivots_feet)})
            # [Hole n Coastline] PointN = x, y, z: read at runtime by
            # CRTerrain::CreateVertexBuffers_Terrain for the surf/wave strip.
            coast = profile.get(f"hole {number} coastline", {})
            coastline_feet = [_floats(v, 3) for v in _indexed(coast, "point")]
            entry["coastline_feet"] = coastline_feet
            entry["coastline_raw"] = [ini_xz_to_raw(x, z, clamp=True) for x, _, z in coastline_feet]
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
              "ob_polygon_semantics": {
                  "reader": "Engine.dll CHole::CheckHazard 0x10181371 (Utils.dll IntersectLine 0x1000cdc0)",
                  "test": "Count crossings of the XZ segment from the nearest hole-line point (selected tee, aim points, selected pin) to the ball with each polygon's n-1 edges (no implicit closing edge). Odd crossings flag the polygon; an odd number of flagged type 1/3 polygons makes the lie unplayable (0x20), else an odd number of flagged type 2 polygons makes it out of bounds (0x80).",
                  "types": {"1": "unplayable line (lie 0x20, drop with one-stroke penalty)",
                            "2": "out-of-bounds line (lie 0x80, stroke and distance)",
                            "3": "unplayable, course-level array only, tested only inside its bbox"},
                  "evaluated": "When the ball comes to rest (CGolfBall::BallAtRest 0x10135d98), at turn end and for drop/stance checks; not during flight",
                  "rules_document": "docs/research/PGA2005-RULES.md"},
              "course_ob_polygons": course_polygons,
              "limitations": ["Tee/pin choice per round depends on settings bytes the protected TW2005.exe front end fills; see docs/research/PGA2005-RULES.md.",
                              "Legacy yardage is the TCR record field; original INI overrides are kept separately when supplied.",
                              "OB/unplayable lines are copied from the TCR; the terrain-presence OB test (no terrain under the ball) needs the terrain mesh."]}
    if profile:
        conditions = {}
        for key, (name, _default) in CONDITION_KEYS.items():
            if key in profile.get("conditions", {}):
                conditions[name] = _profile_int(profile["conditions"][key])
        if conditions:
            result["conditions"] = conditions
        result["conditions_provenance"] = {
            "reader": "CourseData.dll CourseInfoC::GetDefaultSkydome 0x1000ae50, GetDefaultGreenCond 0x1000aec0, GetDefaultRoughLength 0x1000af30, GetDefaultWindSpeed 0x1000afa0 (GetPrivateProfileIntA on [Conditions])",
            "reader_defaults": {name: default for name, default in CONDITION_KEYS.values()},
            "settings_bytes": "CGameSettings +0x11 SkyType, +0x10 GreenCond, +0x0e RoughLength, +0x0f WindSpeed (copy into settings is in the protected TW2005.exe; matched by enum names)"}
        result["ini_ob_comparison"] = {"polygons_matched": sum(len(h["ob_polygons"]) for h in holes) - len(ob_mismatches),
                                       "points_compared": len(ob_errors),
                                       "max_absolute_error": max(ob_errors) if ob_errors else None,
                                       "mismatches": ob_mismatches,
                                       "pivots_compared": len(pivot_errors),
                                       "pivot_vs_aim_point_max_error": max(pivot_errors) if pivot_errors else None,
                                       "pivot_count_mismatches": pivot_mismatches,
                                       "relation": "TCR XZ ~= (INI.x*12-origin.x, INI.z*12-origin.z); TCR aim points ~= first-occurrence INI pivots"}
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
