"""Out-of-bounds/unplayable lines, pivots, coastline and course conditions.

Synthetic fixtures always run. The original-course checks run only when the
locally supplied (Git-ignored) course files are present.
"""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from decode_pga2005_holes import check_hazard, decode_holes, intersect_line

COURSES = ROOT / "Library/SourceMedia/pga2005/disc3/COURSES"
ORIGIN = (120.0, 0.0, 240.0)


def feet(x, z, y=0.0):
    """Inverse of the observed TCR relation raw = feet * 12 - origin."""
    return f"{(x + ORIGIN[0]) / 12:.6f}, {y / 12:.6f}, {(z + ORIGIN[2]) / 12:.6f}"


def feet_xz(x, z):
    return f"{(x + ORIGIN[0]) / 12:.6f}, {(z + ORIGIN[2]) / 12:.6f}"


SQUARE = [(-200, -200), (1200, -200), (1200, 200), (-200, 200), (-200, -200)]
HAZARD_LINE = [(-200, 100), (1200, 100)]


def tcr_fixture(stored_count=-2):
    data = bytearray(0x800)
    struct.pack_into("<H", data, 0, 7)
    struct.pack_into("<I", data, 0x3e, len(data))
    struct.pack_into("<3f", data, 0x318, *ORIGIN)
    root = 0x400
    struct.pack_into("<I", data, 0xe0, root)
    struct.pack_into("<I", data, root, 0x300)
    struct.pack_into("<H", data, root + 0x10, 1)
    struct.pack_into("<I", data, root + 0x12, 0x80)
    record = root + 0x80
    struct.pack_into("<6Hhh", data, record, 4, 300, 1, 1, 1, 1, 0, stored_count)
    struct.pack_into("<5I", data, record + 0x10, 0xc0, 0xcc, 0xd8, 0xe4, 0xe4)
    for offset, x in ((0xc0, 0.0), (0xcc, 500.0), (0xd8, 1000.0)):
        struct.pack_into("<3f", data, root + offset, x, 0.0, 0.0)
    polygon, points = root + 0xe4, 0xe4 + 2 * 0x1e
    for kind, line in ((2, SQUARE), (1, HAZARD_LINE)):
        xs, zs = [p[0] for p in line], [p[1] for p in line]
        struct.pack_into("<IihI4f", data, polygon, 0xffffffff, kind, len(line), points,
                         min(xs), min(zs), max(xs), max(zs))
        for i, (x, z) in enumerate(line):
            struct.pack_into("<3f", data, root + points + 12 * i, x, 0.0, z)
        polygon += 0x1e
        points += 12 * len(line)
    return data


def ini_fixture():
    lines = ["[Conditions]", "Skydome=1", "GreenCond=4", "RoughLength=1", "WindSpeed=5", "",
             "[HOLE 1]", "par=4", "handicap=1,1,1,1,1", "yardage=300,300,300,300,300",
             f"tee0={feet(0, 0)}", f"pin0={feet(1000, 0)}",
             f"pivot0={feet(500, 0)}", f"pivot0={feet(9999, 9999)}", ""]
    for k, (kind, line) in enumerate(((2, SQUARE), (1, HAZARD_LINE)), 1):
        lines += [f"[Hole 1 OB {k}]", f"type={kind}"]
        lines += [f"point{i} = {feet_xz(x, z)}" for i, (x, z) in enumerate(line)]
        lines += [f"points = {len(line)}", ""]
    lines += ["[Hole 1 Coastline]", f"Point0={feet(-500, 50)}", f"Point1={feet(300, 50)}"]
    return ("\r\n".join(lines) + "\r\n").encode("cp1252")


class IntersectLineTests(unittest.TestCase):
    def test_return_codes_follow_utils_intersect_line(self):
        self.assertEqual(intersect_line(0, 0, 0, 10, -5, 5, 5, 5), 1)
        self.assertEqual(intersect_line(0, 0, 0, 10, -5, 15, 5, 15), 0)
        self.assertEqual(intersect_line(0, 0, 0, 10, -5, 0, 5, 0), 2)
        self.assertEqual(intersect_line(0, 0, 0, 10, -5, 10, 5, 10), 3)
        self.assertEqual(intersect_line(0, 0, 0, 10, 0, 5, 5, 5), 4)
        self.assertEqual(intersect_line(0, 0, 0, 10, -5, 5, 0, 5), 5)
        self.assertEqual(intersect_line(0, 0, 10, 10, 0, 1, 10, 11), 0)  # parallel


class CheckHazardTests(unittest.TestCase):
    line = [(0, 0), (500, 0), (1000, 0)]
    polygons = [{"type": 2, "points_raw": [list(p) for p in SQUARE]},
                {"type": 1, "points_raw": [list(p) for p in HAZARD_LINE]}]

    def test_inside_unplayable_and_out_of_bounds(self):
        self.assertEqual(check_hazard(self.line, self.polygons, (500, 50)), 0)
        self.assertEqual(check_hazard(self.line, self.polygons, (500, 150)), 0x20)
        self.assertEqual(check_hazard(self.line, self.polygons, (500, -300)), 0x80)
        self.assertEqual(check_hazard(self.line, self.polygons, (1300, 0)), 0x80)

    def test_unplayable_takes_precedence_over_out_of_bounds(self):
        self.assertEqual(check_hazard(self.line, self.polygons, (500, 300)), 0x20)

    def test_ball_on_a_line_is_not_a_crossing(self):
        self.assertEqual(check_hazard(self.line, self.polygons, (500, 100)), 0)

    def test_flagged_polygon_count_parity_is_preserved(self):
        polygons = self.polygons + [{"type": 1, "points_raw": [[-200, 120], [1200, 120]]}]
        self.assertEqual(check_hazard(self.line, polygons, (500, 150)), 0)

    def test_vertex_is_counted_once_and_lines_are_not_closed(self):
        fence = [{"type": 2, "points_raw": [[0, -100], [100, -100], [200, -100]]}]
        self.assertEqual(check_hazard([(100, 0)], fence, (100, -300)), 0x80)
        self.assertEqual(check_hazard([(100, 0)], fence, (600, -300)), 0)  # passes beyond the open end

    def test_reference_point_is_nearest_hole_line_point(self):
        loop = [{"type": 2, "points_raw": [[900, -50], [1100, -50], [1100, 50], [900, 50], [900, -50]]}]
        # Inside the loop around the pin: nearest line point is the pin, also inside.
        self.assertEqual(check_hazard(self.line, loop, (1000, 20)), 0)
        # Outside it but nearest to the aim point: no crossing either.
        self.assertEqual(check_hazard(self.line, loop, (600, 20)), 0)
        # Outside it but nearest to the pin: one crossing.
        self.assertEqual(check_hazard(self.line, loop, (1000, 120)), 0x80)


class DecodeRulesTests(unittest.TestCase):
    def test_polygons_are_read_from_the_tcr_hole_record(self):
        hole = decode_holes(bytes(tcr_fixture()))["holes"][0]
        self.assertEqual([p["type"] for p in hole["ob_polygons"]], [2, 1])
        self.assertEqual([p["kind"] for p in hole["ob_polygons"]], ["out_of_bounds", "unplayable"])
        self.assertEqual(hole["ob_polygons"][0]["points_raw"], [list(map(float, p)) for p in SQUARE])
        self.assertEqual([p["closed"] for p in hole["ob_polygons"]], [True, False])
        self.assertEqual(hole["ob_polygons"][1]["bbox_raw"], [-200.0, 100.0, 1200.0, 100.0])
        self.assertNotIn("pivots_raw", hole)

    def test_positive_stored_polygon_count_means_none(self):
        self.assertEqual(decode_holes(bytes(tcr_fixture(stored_count=2)))["holes"][0]["ob_polygons"], [])

    def test_polygon_points_cannot_escape_information_block(self):
        data = tcr_fixture()
        struct.pack_into("<I", data, 0x400 + 0xe4 + 0xa, 0x2fc)
        with self.assertRaisesRegex(ValueError, "escapes"):
            decode_holes(bytes(data))

    def test_ini_conditions_pivots_coastline_and_comparison(self):
        result = decode_holes(bytes(tcr_fixture()), ini_fixture())
        self.assertEqual(result["conditions"], {"skydome": 1, "green_cond": 4, "rough_length": 1, "wind_speed": 5})
        hole = result["holes"][0]
        self.assertEqual(len(hole["pivots_raw"]), 1)
        for got, want in zip(hole["pivots_raw"][0], (500.0, 0.0, 0.0)):
            self.assertAlmostEqual(got, want, places=3)
        self.assertEqual(hole["pivot_ini_duplicate_keys"], 1)
        self.assertEqual(hole["ob_polygons"][0]["ini_section"], "Hole 1 OB 1")
        self.assertEqual(len(hole["ob_polygons"][1]["points_feet"]), 2)
        coast = hole["coastline_raw"]
        self.assertEqual(coast[0][0], 0.0)  # clamped to the course minimum like MakeGameWorldPosition
        self.assertAlmostEqual(coast[1][0], 300.0, places=3)
        self.assertAlmostEqual(coast[1][1], 50.0, places=3)
        comparison = result["ini_ob_comparison"]
        self.assertEqual(comparison["mismatches"], [])
        self.assertLess(comparison["max_absolute_error"], 0.01)
        self.assertLess(comparison["pivot_vs_aim_point_max_error"], 0.01)

    def test_absent_conditions_are_omitted(self):
        ini = ini_fixture().replace(b"WindSpeed=5\r\n", b"")
        self.assertNotIn("wind_speed", decode_holes(bytes(tcr_fixture()), ini)["conditions"])

    def test_ini_type_mismatch_is_reported(self):
        ini = ini_fixture().replace(b"type=1", b"type=2")
        mismatches = decode_holes(bytes(tcr_fixture()), ini)["ini_ob_comparison"]["mismatches"]
        self.assertEqual(mismatches, [{"hole": 1, "section": "Hole 1 OB 2", "reason": "type or point count"}])


def point_in_polygon(point, polygon):
    x, z = point
    inside = False
    for (x1, z1), (x2, z2) in zip(polygon, polygon[1:]):
        if (z1 > z) != (z2 > z) and x < (x2 - x1) * (z - z1) / (z2 - z1) + x1:
            inside = not inside
    return inside


@unittest.skipUnless((COURSES / "PBL/PBL.TCR").is_file(), "original course media not supplied")
class OriginalCourseRulesTests(unittest.TestCase):
    def decode(self, code):
        return decode_holes((COURSES / f"{code}/{code}.TCR").read_bytes(), (COURSES / f"{code}/{code}.INI").read_bytes())

    def test_pebble_hole_one_boundary_surrounds_the_hole(self):
        result = self.decode("PBL")
        hole = result["holes"][0]
        self.assertEqual([(p["type"], len(p["points_raw"]), p["closed"]) for p in hole["ob_polygons"]], [(2, 44, True)])
        boundary = hole["ob_polygons"][0]["points_raw"]
        for point in hole["tees"] + hole["pins"] + hole["aim_points"]:
            self.assertTrue(point_in_polygon((point["xyz_raw"][0], point["xyz_raw"][2]), boundary))
        self.assertEqual(result["conditions"], {"skydome": 1, "green_cond": 3, "rough_length": 2, "wind_speed": 2})
        self.assertEqual(sum(len(h["ob_polygons"]) for h in result["holes"]), 31)
        self.assertEqual(sum(1 for h in result["holes"] if h["coastline_raw"]), 18)

    def test_every_installed_course_matches_its_ini_and_keeps_pins_in_play(self):
        codes = sorted(p.name for p in COURSES.iterdir() if (p / f"{p.name}.TCR").is_file() and (p / f"{p.name}.INI").is_file())
        for code in codes:
            with self.subTest(course=code):
                result = self.decode(code)
                comparison = result["ini_ob_comparison"]
                self.assertEqual(comparison["mismatches"], [])
                self.assertEqual(comparison["pivot_count_mismatches"], [])
                self.assertLess(comparison["max_absolute_error"], 0.05)
                self.assertLess(comparison["pivot_vs_aim_point_max_error"], 0.05)
                self.assertEqual(result["course_ob_polygons"], [])
                for hole in result["holes"]:
                    line = [(p["xyz_raw"][0], p["xyz_raw"][2]) for p in hole["tees"][:1] + hole["aim_points"] + hole["pins"][:1]]
                    for pin in hole["pins"]:
                        candidate = line[:-1] + [(pin["xyz_raw"][0], pin["xyz_raw"][2])]
                        self.assertEqual(check_hazard(candidate, hole["ob_polygons"], candidate[-1]), 0)
                    for aim in hole["aim_points"]:
                        self.assertEqual(check_hazard(line, hole["ob_polygons"], (aim["xyz_raw"][0], aim["xyz_raw"][2])), 0)


if __name__ == "__main__":
    unittest.main()
