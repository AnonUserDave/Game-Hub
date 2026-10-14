#!/usr/bin/env python3
"""Write golden ball-flight fixtures for the Swift port (PGABallFlight.swift).

Runs Tools/pga2005_ballflight_reference.py over a fixed list of scenarios and
writes numbers only (inputs, carry/total/apex, ticks, final state, a few
trajectory samples) to Tests/Fixtures/pga2005_ballflight_golden.json. No game
media is read or written; the Pebble Beach surface records used here are the
numeric coefficients already embedded in the reference.

StopBall's lie draws use a SplitMix64 generator that mirrors PGARandom in
PGACore.swift (unit() and int(bound)) instead of Python's Mersenne Twister, so
Swift can replay the same draws. The reference itself is unchanged.

    python3 Tools/make_ballflight_fixtures.py [--output PATH] [--check]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pga2005_ballflight_reference as bf  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Tests" / "Fixtures" / "pga2005_ballflight_golden.json"
MASK = (1 << 64) - 1
SAMPLE_TICKS = (1, 2, 3, 5, 10, 20, 40, 60, 90, 120, 180, 240, 300, 400, 500, 700, 900, 1200, 1600, 2000)


class SplitMix64:
    """PGARandom (PGACore.swift): SplitMix64, unit() in [0, 1), int(bound) = next % bound."""

    def __init__(self, state):
        self.state = int(state) & MASK

    def _next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def random(self):
        return (self._next() >> 11) / float(1 << 53)

    def randrange(self, bound):
        return 0 if bound <= 1 else self._next() % bound


# simulate_shot builds random.Random(seed); substitute the replayable generator.
bf.random = types.SimpleNamespace(Random=SplitMix64)


def make_terrain(spec):
    base = bf.PBL_SURFACES[spec["surface"]]
    regions = []
    for region in spec.get("regions", []):
        lo = region.get("min", -math.inf)
        hi = region.get("max", math.inf)
        axis = region["axis"]
        regions.append((lambda x, z, lo=lo, hi=hi, axis=axis: lo < (x if axis == "x" else z) < hi,
                        bf.PBL_SURFACES[region["surface"]]))
    slope = tuple(spec.get("slope", (0.0, 0.0)))
    terrain = bf.flat_terrain(base, spec.get("height", 0.0), slope, regions)
    limit = spec.get("max_z")
    if limit is None:
        return terrain
    return lambda x, z: None if z > limit else terrain(x, z)


def launch_spec(club, power, **kw):
    spec = {"club": club, "power": power}
    spec.update(kw)
    return spec


def conditions_spec(conditions: bf.Conditions):
    return {"wet": conditions.wet, "rough": conditions.rough, "sand": conditions.sand,
            "wind_mph": list(conditions.wind_mph), "magnet": conditions.magnet}


FAIRWAY = {"surface": "fairway"}
GREEN = {"surface": "green"}


def scenarios():
    out = []

    def add(name, launch, terrain=FAIRWAY, conditions=None, ball=1, fps=60, pin=None, seed=0):
        out.append({"name": name, "launch": launch, "terrain": terrain,
                    "conditions": conditions_spec(conditions or bf.Conditions()),
                    "ball": ball, "fps": fps, "pin": pin, "seed": seed})

    # Every club at full power (Advanced) on a flat PBL fairway, Solid Core ball.
    for club in range(20):
        add(f"full_{club:02d}_{bf.CLUB_NAMES[club].lower().replace(' ', '_')}",
            launch_spec(club, bf.full_swing_power(club, 2)))
    for club in (21, 26, 32):
        add(f"chip_variant_{club}", launch_spec(club, bf.full_swing_power(club, 2)))
    add("full_driver_two_piece", launch_spec(0, bf.full_swing_power(0, 2)), ball=0)
    add("full_driver_wound_balata", launch_spec(0, bf.full_swing_power(0, 2)), ball=2)
    add("full_driver_novice", launch_spec(0, bf.full_swing_power(0, 0)))
    add("full_7iron_30fps", launch_spec(14, 14.0), fps=30)

    # Partial swings.
    for fraction in (0.25, 0.5, 0.75):
        add(f"partial_7iron_{int(fraction * 100)}", launch_spec(14, bf.full_swing_power(14, 2) * fraction))
    add("partial_driver_50", launch_spec(0, bf.full_swing_power(0, 2) * 0.5))
    add("partial_pw_60", launch_spec(17, bf.full_swing_power(17, 2) * 0.6))

    # Hooks, slices, aims and launch adjustments.
    add("hook_driver", launch_spec(0, 14.0, path=0.03, face=-0.02))
    add("slice_driver", launch_spec(0, 14.0, path=-0.03, face=0.02))
    add("hook_7iron_path", launch_spec(14, bf.full_swing_power(14, 2), path=0.05))
    add("slice_7iron_path", launch_spec(14, bf.full_swing_power(14, 2), path=-0.05))
    add("open_face_driver", launch_spec(0, 14.0, face=0.05))
    add("aim_driver", launch_spec(0, 14.0, aim=0.4, aim_offset=-0.05))
    add("aim_putt", launch_spec(bf.PUTTER, 3.0, aim=-1.2), terrain=GREEN)
    add("launch_adjust_7iron", launch_spec(14, 14.0, loft_adjust=0.1, launch_adjust=0.05, spin_mult=1.2))
    add("loft_floor_7iron", launch_spec(14, 14.0, loft_adjust=-0.5))
    add("offset_start", launch_spec(3, 14.0, position=[1234.5, 56.25, -789.125], aim=2.5),
        terrain={"surface": "fairway", "height": 56.25})

    # Wind.
    for name, wind in (("tail", (0, 10)), ("head", (0, -10)), ("cross", (10, 0)), ("quarter", (-15, 5))):
        add(f"wind_{name}_driver", launch_spec(0, 14.0), conditions=bf.Conditions(wind_mph=wind))
    add("wind_head_pw", launch_spec(17, bf.full_swing_power(17, 2)), conditions=bf.Conditions(wind_mph=(0, -20)))

    # Sloped landings.
    for name, slope in (("down", (0.0, -0.05)), ("up", (0.0, 0.08)), ("side", (0.06, 0.0))):
        add(f"slope_{name}_driver", launch_spec(0, bf.full_swing_power(0, 2)),
            terrain={"surface": "fairway", "slope": list(slope)})
    add("slope_diag_7iron", launch_spec(14, bf.full_swing_power(14, 2)),
        terrain={"surface": "fairway", "slope": [0.1, 0.05]})

    # Landing on other surfaces.
    add("land_green_pw_spin", launch_spec(17, bf.full_swing_power(17, 2)),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 3800.0, "surface": "green"}]})
    add("land_green_sw", launch_spec(18, bf.full_swing_power(18, 2)),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 2500.0, "surface": "green"}]})
    add("land_fringe_driver", launch_spec(0, bf.full_swing_power(0, 2)),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 9000.0, "surface": "fringe"}]})
    add("land_tee_7iron", launch_spec(14, bf.full_swing_power(14, 2)),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 5000.0, "surface": "tee"}]})
    add("land_heavy_rough_7iron", launch_spec(14, bf.full_swing_power(14, 2)),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 5000.0, "surface": "heavy_rough"}]})
    for seed in (1, 2, 4):              # Md, Dp, Lt
        add(f"land_rough_7iron_seed{seed}", launch_spec(14, bf.full_swing_power(14, 2)),
            terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 4000.0, "surface": "rough"}]}, seed=seed)
    for seed in (0, 7, 14, 38):         # SplitMix states chosen to draw Med, Dp, Dp and Plug lies
        add(f"land_bunker_sw_seed{seed}", launch_spec(18, 15.5),
            terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 3500.0, "surface": "bunker"}]}, seed=seed)
    for seed in (0, 10):
        add(f"land_bunker_driver_seed{seed}", launch_spec(0, bf.full_swing_power(0, 2)),
            terrain={"surface": "fairway", "regions": [{"axis": "z", "min": 8500.0, "surface": "bunker"}]}, seed=seed)
    add("out_of_world_driver", launch_spec(0, bf.full_swing_power(0, 2)), terrain={"surface": "fairway", "max_z": 6000.0})

    # Bunker lies (start inside a bunker band).
    bunker_start = {"surface": "fairway", "regions": [{"axis": "z", "max": 100.0, "surface": "bunker"}]}
    for lie in range(4):
        add(f"bunker_lie{lie}_sw", launch_spec(18, bf.full_swing_power(18, 2), lie_index=lie), terrain=bunker_start)
    add("bunker_blend_sw", launch_spec(18, bf.full_swing_power(18, 2), sand_blend=0.5), terrain=bunker_start)
    add("bunker_blend_5iron", launch_spec(12, bf.full_swing_power(12, 2), lie_index=1, sand_blend=0.3), terrain=bunker_start)
    add("bunker_wood", launch_spec(3, bf.full_swing_power(3, 2), sand_blend=0.2), terrain=bunker_start)
    add("bunker_sand_difficulty", launch_spec(18, bf.full_swing_power(18, 2), lie_index=3),
        terrain=bunker_start, conditions=bf.Conditions(sand=1.3))

    # Rough lies.
    rough_start = {"surface": "fairway", "regions": [{"axis": "z", "max": 100.0, "surface": "rough"}]}
    for lie in range(3):
        add(f"rough_lie{lie}_7iron", launch_spec(14, bf.full_swing_power(14, 2), lie_index=lie), terrain=rough_start)
    for length in (1, 3):
        add(f"rough_length{length}_7iron", launch_spec(14, bf.full_swing_power(14, 2)), terrain=rough_start,
            conditions=bf.Conditions.from_settings(rough_length=length))
    add("rough_novice_magnet", launch_spec(14, bf.full_swing_power(14, 0)), terrain=rough_start,
        conditions=bf.Conditions.from_settings(difficulty=0))
    add("rough_pitch_shot", launch_spec(17, bf.full_swing_power(17, 2), shot_type=5), terrain=rough_start)
    add("rough_lie_comp", launch_spec(14, bf.full_swing_power(14, 2), lie_index=2, lie_comp=0.5), terrain=rough_start)
    add("heavy_rough_lie_7iron", launch_spec(14, bf.full_swing_power(14, 2), lie_index=1),
        terrain={"surface": "fairway", "regions": [{"axis": "z", "max": 100.0, "surface": "heavy_rough"}]})

    # Putts at several powers on Slow / Normal / Fast greens, plus the extremes.
    for cond, label in ((2, "slow"), (3, "normal"), (4, "fast")):
        for power in (1.0, 2.0, 3.0, 4.0, 6.4, 8.0):
            add(f"putt_{label}_p{power:g}", launch_spec(bf.PUTTER, power), terrain=GREEN,
                conditions=bf.Conditions.from_settings(green_cond=cond))
    add("putt_very_slow_p3", launch_spec(bf.PUTTER, 3.0), terrain=GREEN, conditions=bf.Conditions.from_settings(green_cond=1))
    add("putt_very_fast_p3", launch_spec(bf.PUTTER, 3.0), terrain=GREEN, conditions=bf.Conditions.from_settings(green_cond=5))
    add("putt_fast_novice_p3", launch_spec(bf.PUTTER, 3.0), terrain=GREEN,
        conditions=bf.Conditions.from_settings(green_cond=4, difficulty=0))
    add("putt_fringe_p3", launch_spec(bf.PUTTER, 3.0), terrain={"surface": "fringe"})
    add("putt_fairway_p4", launch_spec(bf.PUTTER, 4.0))
    add("putt_rough_p4", launch_spec(bf.PUTTER, 4.0), terrain={"surface": "rough"})

    # Breaking putts.
    for name, slope in (("left", (0.02, 0.0)), ("right", (-0.02, 0.0)), ("up", (0.0, 0.02)),
                        ("down", (0.0, -0.02)), ("diag", (0.015, -0.01))):
        add(f"putt_break_{name}", launch_spec(bf.PUTTER, 3.0), terrain={"surface": "green", "slope": list(slope)})

    # Cup: holed, lip-outs, misses (pin 10 ft away).
    pin = [0.0, 0.0, 120.0]
    for power in (1.6, 2.0, 2.2, 2.6, 3.0, 4.0, 5.0):
        add(f"cup_p{power:g}", launch_spec(bf.PUTTER, power), terrain=GREEN, pin=pin)
    add("cup_wide", launch_spec(bf.PUTTER, 2.2, aim=0.03), terrain=GREEN, pin=pin)
    for offset in (1.0, 1.6, 2.2):
        add(f"cup_offset_{offset:g}_p2.6", launch_spec(bf.PUTTER, 2.6), terrain=GREEN, pin=[offset, 0.0, 120.0])
    add("cup_sloped_p2.4", launch_spec(bf.PUTTER, 2.4), terrain={"surface": "green", "slope": [0.01, 0.0]}, pin=[-1.0, -1.0 * 0.01, 120.0])
    add("cup_chip_pw", launch_spec(17, 4.0), terrain=GREEN, pin=[0.0, 0.0, 600.0])
    return out


def run(scenario):
    launch = dict(scenario["launch"])
    if "position" in launch:
        launch["position"] = tuple(launch["position"])
    cond = scenario["conditions"]
    conditions = bf.Conditions(wet=cond["wet"], rough=cond["rough"], sand=cond["sand"],
                               wind_mph=tuple(cond["wind_mph"]), magnet=cond["magnet"])
    pin = tuple(scenario["pin"]) if scenario["pin"] is not None else None
    result = bf.simulate_shot(bf.Launch(**launch), make_terrain(scenario["terrain"]), conditions,
                              ball=bf.BALL_TYPES[scenario["ball"]], fps=scenario["fps"], pin=pin, seed=scenario["seed"])
    by_tick = {point[0]: point for point in result.trajectory}
    samples = [list(by_tick[tick]) for tick in SAMPLE_TICKS if tick in by_tick and tick != result.ticks]
    samples.append(list(result.trajectory[-1]))
    kinds = [event[0] for event in result.events]
    return {
        "carry": result.carry, "total": result.total, "roll": result.roll, "apex": result.apex,
        "ticks": result.ticks, "first_bounce_tick": result.first_bounce_tick,
        "holed": result.holed, "touched_cup": result.touched_cup, "out_of_world": result.out_of_world,
        "next_lie_index": result.next_lie_index, "bounces": result.bounces, "end_state": result.end_state,
        "end_surface": result.end_surface,
        "final_position": list(result.final_position), "final_velocity": list(result.final_velocity),
        "launch_velocity": list(result.launch_velocity), "launch_spin": list(result.launch_spin),
        "events": kinds, "samples": samples,
    }


def build():
    fixture = {
        "schema_version": 1,
        "generator": "Tools/make_ballflight_fixtures.py",
        "reference": "Tools/pga2005_ballflight_reference.py",
        "note": "Numbers from the Python reference model (static reconstruction, never compared with the running game). "
                "Units: inches, 60 Hz ticks unless fps says otherwise, left-handed internal frame. "
                "Seeds are SplitMix64 states (PGARandom).",
        "sample_ticks": list(SAMPLE_TICKS),
        "tables": {"speed": list(bf._SPEED), "launch": list(bf._LAUNCH), "pitch": list(bf._PITCH),
                   "spin": list(bf._SPIN), "caddy_max_distance": list(bf.CADDY_MAX_DISTANCE)},
        "full_swing_power": [{"club": club, "difficulty": difficulty, "power": bf.full_swing_power(club, difficulty)}
                             for club in (0, 3, 14, 18, 20, 26) for difficulty in range(4)],
        "conditions": [],
        "consider_terrain": [],
        "scenarios": [],
    }
    for green in range(1, 6):
        for rough in range(1, 4):
            for difficulty in (None, 0, 1, 2, 3):
                c = bf.Conditions.from_settings(green, rough, difficulty)
                fixture["conditions"].append({"green_cond": green, "rough_length": rough, "difficulty": difficulty,
                                              "wet": c.wet, "rough": c.rough, "magnet": c.magnet})
    for name in ("rough", "bunker", "heavy_rough", "fairway"):
        surface = bf.PBL_SURFACES[name]
        for lie in range(-1, len(surface.records) + 1):
            for rough, sand, magnet in ((1.0, 1.0, 0.0), (1.3, 1.3, 0.8), (0.7, 0.7, 0.45)):
                record, factor = bf.BallFlight.consider_terrain(surface, lie, rough, sand, magnet)
                fixture["consider_terrain"].append({"surface": name, "lie_index": lie, "rough": rough, "sand": sand,
                                                    "magnet": magnet, "record": record.name, "factor": factor})
    for scenario in scenarios():
        scenario["result"] = run(scenario)
        fixture["scenarios"].append(scenario)
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="fail if the committed fixture differs")
    args = parser.parse_args()
    text = json.dumps(build(), indent=1, allow_nan=False) + "\n"
    if args.check:
        current = args.output.read_text() if args.output.exists() else ""
        if current != text:
            print(f"{args.output} is stale; rerun Tools/make_ballflight_fixtures.py", file=sys.stderr)
            return 1
        print(f"{args.output} is current")
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)
    print(f"wrote {args.output} ({len(text) // 1024} KiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
