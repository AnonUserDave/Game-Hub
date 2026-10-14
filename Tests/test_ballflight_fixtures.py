"""The committed Swift golden fixture must match the Python reference.

Tests/Swift/PGABallFlightTests.swift compares the Swift port with
Tests/Fixtures/pga2005_ballflight_golden.json. If the reference changes, rerun
Tools/make_ballflight_fixtures.py so both sides keep testing the same model.
"""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import make_ballflight_fixtures as fixtures  # noqa: E402


class BallFlightFixtureTests(unittest.TestCase):
    def test_committed_fixture_is_current(self):
        expected = json.dumps(fixtures.build(), indent=1, allow_nan=False) + "\n"
        self.assertEqual(fixtures.DEFAULT_OUTPUT.read_text(), expected,
                         "Rerun python3 Tools/make_ballflight_fixtures.py")

    def test_splitmix_mirrors_pga_random(self):
        # PGARandom(state: 0): first SplitMix64 outputs (reference values of the algorithm).
        rng = fixtures.SplitMix64(0)
        self.assertEqual(rng._next(), 0xE220A8397B1DCDAF)
        self.assertEqual(rng._next(), 0x6E789E6AA1B965F4)
        self.assertEqual(fixtures.SplitMix64(0).randrange(1), 0)

    def test_fixture_covers_required_scenarios(self):
        data = json.loads(fixtures.DEFAULT_OUTPUT.read_text())
        results = {s["name"]: s["result"] for s in data["scenarios"]}
        self.assertEqual(sum(name.startswith("full_") and name[5:7].isdigit() for name in results), 20)
        self.assertTrue(any(r["holed"] for r in results.values()))
        self.assertTrue(any(r["touched_cup"] and not r["holed"] and "cup_rim" in r["events"] for r in results.values()))
        self.assertTrue(any("spin_kick" in r["events"] for r in results.values()))
        self.assertTrue(any(r["out_of_world"] for r in results.values()))
        self.assertEqual({r["next_lie_index"] for n, r in results.items() if n.startswith("land_bunker")}, {0, 2, 3})
        self.assertEqual({r["next_lie_index"] for n, r in results.items() if n.startswith("land_rough")}, {0, 1, 2})


if __name__ == "__main__":
    unittest.main()
