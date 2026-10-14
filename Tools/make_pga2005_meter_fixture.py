#!/usr/bin/env python3
"""Write Tests/Fixtures/pga2005-meter.json from the reference tri-click meter.

Numbers only (angles, states, results), used by the Swift port's tests to
match Tools/decode_pga2005_cameras.TriClickMeter frame for frame.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

from decode_pga2005_cameras import PUTTER, TriClickMeter

SCENARIOS = [
    # name, level, putter, two_click, power click ms, accuracy click ms
    ("intermediate-auto-clicks", 1, False, False, None, None),
    ("novice-short-late", 0, False, False, 1300, 2300),
    ("advanced-very-late", 2, False, False, 1250, 2500),
    ("expert-overswing-early", 3, False, False, 1290, 1900),
    ("intermediate-missed-power", 1, False, False, -1, 2900),
    ("intermediate-missed-accuracy", 1, False, False, 1380, -1),
    ("advanced-putter", 2, True, False, 900, 1700),
    ("intermediate-two-click", 1, False, True, 1200, -1),
]


def run(level, putter, two_click, power_ms, accuracy_ms, seed=7, dt=16):
    jitter = random.Random(seed).randrange(0x7FFF) % 20
    meter = TriClickMeter(level, PUTTER if putter else 8, two_click=two_click, rng=random.Random(seed))
    t, trace = 0, []
    # Default "perfect" times: click when the marker first reaches 90 and then 270.
    while not meter.finished and t < 10000:
        if power_ms is None and meter.state == 2 and meter.angle <= 91:
            meter.click()
        elif power_ms is not None and power_ms >= 0 and t >= power_ms and meter.state == 2:
            meter.click()
        if accuracy_ms is None and meter.state == 4 and meter.angle >= 269:
            meter.click()
        elif accuracy_ms is not None and accuracy_ms >= 0 and t >= accuracy_ms and meter.state == 4:
            meter.click()
        meter.step(dt)
        t += dt
        trace.append([t, round(meter.angle, 4), meter.state])
    return {"jitter": jitter, "dt": dt, "power": meter.power, "direction": meter.direction_percent,
            "power_angle": meter.power_angle, "accuracy_angle": meter.accuracy_angle,
            "missed_power": meter.missed_power, "missed_direction": meter.missed_direction,
            "finished_ms": t, "trace": trace}


def main():
    root = Path(__file__).resolve().parent.parent
    cases = []
    for name, level, putter, two_click, power_ms, accuracy_ms in SCENARIOS:
        result = run(level, putter, two_click, power_ms, accuracy_ms)
        cases.append({"name": name, "level": level, "putter": putter, "two_click": two_click,
                      "power_click_ms": power_ms, "accuracy_click_ms": accuracy_ms, **result})
    out = root / "Tests/Fixtures/pga2005-meter.json"
    out.write_text(json.dumps({"schema_version": 1, "generator": "Tools/make_pga2005_meter_fixture.py",
                               "cases": cases}, indent=1) + "\n")
    for case in cases:
        print(f"{case['name']}: power {case['power']:.3f} direction {case['direction']:.3f} done {case['finished_ms']} ms")


if __name__ == "__main__":
    main()
