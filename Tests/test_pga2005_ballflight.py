"""Tests for Tools/pga2005_ballflight_reference.py.

The expected numbers are re-derived by hand from docs/research/PGA2005-PHYSICS.md
(not from a running game), so they check that the reference implements the
written specification. None of them is runtime evidence of the original.
"""
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import pga2005_ballflight_reference as bf
from pga2005_ballflight_reference import (BALL_TYPES, CADDY_MAX_DISTANCE, Conditions, Launch,
                                          PBL_SURFACES, PUTTER, f32, flat_terrain,
                                          full_swing_power, simulate_shot)


FAIRWAY = flat_terrain(PBL_SURFACES["fairway"])
GREEN = flat_terrain(PBL_SURFACES["green"])


def finite(values):
    return all(math.isfinite(v) for v in values)


class TableTests(unittest.TestCase):
    def test_club_tables_have_45_entries_and_known_values(self):
        for table in (bf._SPEED, bf._LAUNCH, bf._PITCH, bf._SPIN):
            self.assertEqual(len(table), 45)
        self.assertEqual(bf._SPEED[0], 0.454135047)      # 0x1038b540
        self.assertEqual(bf._SPEED[PUTTER], 0.0471)
        self.assertEqual(bf._LAUNCH[19], 0.63896)        # 0x1038b6a8 + 19*8
        self.assertEqual(bf._PITCH[33], 0.1)             # 0x1038b810 + 33*8
        self.assertEqual(bf._SPIN[0], 0.8675)            # 0x1038b978
        self.assertEqual(len(CADDY_MAX_DISTANCE), 45)

    def test_gravity_and_ball_constants(self):
        self.assertAlmostEqual(bf.GRAVITY_60HZ * 3600 * 0.0254, 9.80, places=2)
        self.assertAlmostEqual(bf.BALL_INERTIA, 0.4 * bf.BALL_MASS * bf.BALL_RADIUS_SQ, places=7)
        self.assertAlmostEqual(bf.TANGENT_MASS, bf.BALL_MASS / 3.5, places=7)
        self.assertAlmostEqual(bf.R_OVER_I, bf.BALL_RADIUS / bf.BALL_INERTIA, places=6)  # f32-derived constants

    def test_condition_scales(self):
        self.assertEqual(Conditions.from_settings(3, 2).wet, 1.0)
        self.assertAlmostEqual(Conditions.from_settings(5, 2).wet, 1.4, places=6)
        self.assertAlmostEqual(Conditions.from_settings(3, 3).rough, 0.7, places=6)
        self.assertAlmostEqual(full_swing_power(0, 2), 15.5555553, places=5)
        self.assertEqual(full_swing_power(PUTTER, 2), 8.0)
        # SetupBall: wet > 1 becomes wet - (1 - ability)*(wet - 1); Novice ability 0.25.
        self.assertAlmostEqual(Conditions.from_settings(4, difficulty=0).wet, 1.05, places=6)
        self.assertAlmostEqual(Conditions.from_settings(4, difficulty=3).wet, 1.2, places=6)
        self.assertAlmostEqual(Conditions.from_settings(2, difficulty=0).wet, 0.8, places=6)


class LaunchTests(unittest.TestCase):
    def test_driver_launch_vector_matches_hand_derivation(self):
        power = 14.0
        result = simulate_shot(Launch(club=0, power=power), FAIRWAY, max_ticks=1)
        # Impact 0x101f4e6a with square path/face: club velocity (0,0,S),
        # face normal n = (0, sin a, cos a); ball = (n (S cos a) + 0.1 vt) * c0.
        a = 0.125260075
        scale = 0.454135047 * 8.333333015441895 / f32(1.0 / power)
        keep = 1.0 - 0.8999999761581421
        c0 = f32(0.95)
        vy = (math.sin(a) * scale * math.cos(a) + keep * (-scale * math.sin(a) * math.cos(a))) * c0
        vz = (math.cos(a) * scale * math.cos(a) + keep * scale * math.sin(a) ** 2) * c0
        vx, vy0, vz0 = result.launch_velocity
        self.assertAlmostEqual(vx, 0.0, places=12)
        self.assertAlmostEqual(vy0, vy, places=9)
        self.assertAlmostEqual(vz0, vz, places=9)
        # Backspin: omega_x = -0.9 * S * sin(a) * c1 * spin / 0.84.
        wx = -0.8999999761581421 * scale * math.sin(a) * f32(0.95) * 0.8675 / bf.BALL_RADIUS
        self.assertAlmostEqual(result.launch_spin[0], wx, places=9)
        self.assertAlmostEqual(result.launch_spin[1], 0.0, places=12)

    def test_putt_launch_is_tangent_and_scaled_by_1_8(self):
        result = simulate_shot(Launch(club=PUTTER, power=4.0), GREEN, max_ticks=1)
        expected = 0.0471 * 8.333333015441895 / f32(1.0 / 4.0) * 1.7999999523162842
        self.assertAlmostEqual(result.launch_velocity[2], expected, places=12)
        self.assertEqual(result.launch_spin, (0.0, 0.0, 0.0))

    def test_lie_power_factor_rough_and_bunker(self):
        rec, factor = bf.BallFlight.consider_terrain(PBL_SURFACES["rough"], 0, 1.3, 1.0, 0.0)
        self.assertAlmostEqual(factor, (0.3 * 0.20000000298023224 + 1.0) * f32(0.8), places=6)
        rec, factor = bf.BallFlight.consider_terrain(PBL_SURFACES["bunker"], 3, 1.0, 1.3, 0.0)
        self.assertEqual(rec.name, "Plug Sand")
        self.assertAlmostEqual(factor, (0.3 * 0.20000000298023224 + 1.0) * f32(0.3), places=6)


class FlightTests(unittest.TestCase):
    def test_flat_fairway_driver_invariants(self):
        result = simulate_shot(Launch(club=0, power=full_swing_power(0, 2)), FAIRWAY, ball=BALL_TYPES[0])
        self.assertEqual(result.end_state, bf.STATE_DONE)
        self.assertTrue(finite(result.final_position))
        self.assertGreater(result.carry_yards, 240)
        self.assertGreater(result.roll_yards, 5)
        self.assertLess(result.ticks, bf.MAX_TICKS)
        self.assertAlmostEqual(result.final_position[0], 0.0, places=6)
        self.assertGreater(result.apex, 12 * 30)

    def test_full_swings_land_near_caddie_table(self):
        # Caddy::GetMaxClubDistance 0x101132c9 is an independent table in the
        # binary; full human swings (difficulty 2, ball type 0) land within 10%.
        for club in range(20):
            result = simulate_shot(Launch(club=club, power=full_swing_power(club, 2)), FAIRWAY,
                                   ball=BALL_TYPES[0], record_every=1000)
            ratio = result.total / CADDY_MAX_DISTANCE[club]
            self.assertGreater(ratio, 0.95, bf.CLUB_NAMES[club])
            self.assertLess(ratio, 1.10, bf.CLUB_NAMES[club])

    def test_distance_increases_with_power_and_shorter_clubs_go_shorter(self):
        totals = [simulate_shot(Launch(club=14, power=p), FAIRWAY).total for p in (6, 9, 12, 15)]
        self.assertEqual(totals, sorted(totals))
        irons = [simulate_shot(Launch(club=c, power=14), FAIRWAY).carry for c in range(8, 20)]
        self.assertEqual(irons, sorted(irons, reverse=True))

    def test_hook_slice_mirror_symmetry(self):
        left = simulate_shot(Launch(club=0, power=14, path=0.03, face=-0.02), FAIRWAY)
        right = simulate_shot(Launch(club=0, power=14, path=-0.03, face=0.02), FAIRWAY)
        self.assertAlmostEqual(left.final_position[0], -right.final_position[0], places=6)
        self.assertAlmostEqual(left.final_position[2], right.final_position[2], places=6)
        # Face open relative to path curves toward +X (D-plane behaviour).
        open_face = simulate_shot(Launch(club=0, power=14, face=0.05), FAIRWAY)
        straight_line_x = open_face.launch_velocity[0] / open_face.launch_velocity[2] * open_face.first_bounce[2]
        self.assertGreater(open_face.first_bounce[0], straight_line_x)

    def test_wind_effects(self):
        base = simulate_shot(Launch(club=0, power=14), FAIRWAY)
        tail = simulate_shot(Launch(club=0, power=14), FAIRWAY, Conditions(wind_mph=(0, 10)))
        head = simulate_shot(Launch(club=0, power=14), FAIRWAY, Conditions(wind_mph=(0, -10)))
        cross = simulate_shot(Launch(club=0, power=14), FAIRWAY, Conditions(wind_mph=(10, 0)))
        self.assertGreater(tail.carry, base.carry)
        self.assertLess(head.carry, base.carry)
        self.assertGreater(cross.final_position[0], 100)

    def test_wind_is_ignored_below_18_inches(self):
        flight = bf.BallFlight(Launch(club=0, power=14), FAIRWAY, Conditions(wind_mph=(30, 0)),
                               bf.NEUTRAL_BALL, 60, None, bf.random.Random(0), 1)
        flight.start_ball()
        flight.flying()
        self.assertAlmostEqual(flight.v[0], 0.0, places=12)

    def test_frame_rate_scaling_is_close(self):
        at60 = simulate_shot(Launch(club=14, power=14), FAIRWAY, fps=60)
        at30 = simulate_shot(Launch(club=14, power=14), FAIRWAY, fps=30)
        self.assertAlmostEqual(at30.carry / at60.carry, 1.0, delta=0.03)

    def test_deterministic(self):
        a = simulate_shot(Launch(club=5, power=13), FAIRWAY, seed=4)
        b = simulate_shot(Launch(club=5, power=13), FAIRWAY, seed=4)
        self.assertEqual(a.trajectory, b.trajectory)


class PuttTests(unittest.TestCase):
    def hand_putt_distance(self, power, wet=1.0):
        """Slip at constant speed, then decelerate by R per tick (spec 3.4/3.5)."""
        g = bf.GRAVITY_60HZ
        v = 0.0471 * 8.333333015441895 / f32(1.0 / power) * 1.7999999523162842
        friction = g * f32(0.7) * 1.5 * (2.0 - wet)
        dw = friction * 2.5 / bf.BALL_RADIUS
        w, x = 0.0, 0.0
        while True:                       # RollingAndSlipping
            w += dw
            x += v
            if v <= w * bf.BALL_RADIUS:
                break
        resist = (g * 5.0 / 7.0) * f32(0.2) * 0.574999988079071 * (2.0 - wet)
        while True:                       # PureRolling
            if resist <= v:
                v -= resist
                x += v
            else:
                x += v                    # StopBall tick still moves
                return x

    def test_flat_putt_distance_matches_hand_model(self):
        for power in (1.0, 2.5, 4.0, 6.4):
            result = simulate_shot(Launch(club=PUTTER, power=power), GREEN)
            self.assertAlmostEqual(result.total, self.hand_putt_distance(power), delta=1e-6)
            self.assertAlmostEqual(result.final_position[0], 0.0, places=9)

    def test_green_speed_order_and_discontinuity(self):
        dist = {}
        for cond in (1, 2, 3, 4, 5):
            dist[cond] = simulate_shot(Launch(club=PUTTER, power=3.0), GREEN,
                                       Conditions.from_settings(green_cond=cond)).total
        self.assertLess(dist[1], dist[2])
        self.assertLess(dist[2], dist[3])
        self.assertLess(dist[3], dist[4])
        self.assertLess(dist[4], dist[5])
        # wet 0.8 -> x1.56 resistance, 1.0 -> x1.0: Slow is much slower than Normal.
        self.assertLess(dist[2] / dist[3], 0.75)

    def test_side_slope_breaks_downhill_symmetrically(self):
        up_x = simulate_shot(Launch(club=PUTTER, power=3.0), flat_terrain(PBL_SURFACES["green"], slope=(0.02, 0)))
        down_x = simulate_shot(Launch(club=PUTTER, power=3.0), flat_terrain(PBL_SURFACES["green"], slope=(-0.02, 0)))
        self.assertLess(up_x.final_position[0], -6.0)
        self.assertAlmostEqual(up_x.final_position[0], -down_x.final_position[0], places=6)

    def test_uphill_putt_is_shorter(self):
        flat = simulate_shot(Launch(club=PUTTER, power=3.0), GREEN)
        uphill = simulate_shot(Launch(club=PUTTER, power=3.0), flat_terrain(PBL_SURFACES["green"], slope=(0, 0.02)))
        downhill = simulate_shot(Launch(club=PUTTER, power=3.0), flat_terrain(PBL_SURFACES["green"], slope=(0, -0.02)))
        self.assertLess(uphill.total, flat.total)
        self.assertGreater(downhill.total, flat.total)

    def test_cup_capture_and_misses(self):
        pin = (0.0, 0.0, 120.0)
        holed = simulate_shot(Launch(club=PUTTER, power=2.2), GREEN, pin=pin)
        self.assertTrue(holed.holed)
        self.assertLessEqual(holed.final_position[1], -4.0 + 1e-9 + 0.0)
        too_fast = simulate_shot(Launch(club=PUTTER, power=5.0), GREEN, pin=pin)
        self.assertFalse(too_fast.holed)
        self.assertTrue(too_fast.touched_cup)
        wide = simulate_shot(Launch(club=PUTTER, power=2.2, aim=0.03), GREEN, pin=pin)
        self.assertFalse(wide.holed)
        self.assertFalse(wide.touched_cup)
        short = simulate_shot(Launch(club=PUTTER, power=1.6), GREEN, pin=pin)
        self.assertFalse(short.holed)


class BunkerAndRoughTests(unittest.TestCase):
    def test_bunker_landing_stops_quickly_and_chooses_a_sand_lie(self):
        terrain = flat_terrain(PBL_SURFACES["fairway"], regions=[(lambda x, z: z > 3500, PBL_SURFACES["bunker"])])
        lies = set()
        for seed in range(12):
            result = simulate_shot(Launch(club=18, power=15.5), terrain, seed=seed)
            self.assertEqual(result.end_surface, "pbl_bunker")
            self.assertLess(abs(result.roll), 24.0)
            lies.add(result.next_lie_index)
        self.assertTrue(lies <= {0, 1, 2, 3})
        self.assertIn(0, lies)

    def test_rough_lie_reduces_power_and_rough_length_matters(self):
        rough = flat_terrain(PBL_SURFACES["rough"])
        clean = simulate_shot(Launch(club=14, power=14), FAIRWAY).carry
        carries = [simulate_shot(Launch(club=14, power=14), rough,
                                 Conditions.from_settings(rough_length=r)).carry for r in (1, 2, 3)]
        self.assertGreater(carries[0], carries[1])
        self.assertGreater(carries[1], carries[2])
        self.assertLess(carries[1], clean)


if __name__ == "__main__":
    unittest.main()
