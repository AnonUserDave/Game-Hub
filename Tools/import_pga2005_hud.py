#!/usr/bin/env python3
"""Convert the original PGA Tour 2005 in-game HUD images for the native module.

Reads DDS files from the extracted install tree (DataImages/Game) and writes
PNG copies plus a provenance manifest to the ignored Library/Imported folder.
Only images the native HUD uses are converted. No game code runs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from import_pga2005 import atomic_write, decode_dds, png_bytes

# Native name -> path under DataImages/Game. Layout of these pieces in the
# original HUD is not decoded; the native HUD places them approximately.
HUD_IMAGES = {
    "swing-on": "SwingMeter/swingon.dds",
    "swing-off": "SwingMeter/swingoff.dds",
    "shot-panel": "Shot/main_back.dds",
    "feedback-panel": "SwingFeedback/main_back.dds",
    "feedback-ball": "SwingFeedback/golf_ball.dds",
    "lie-back": "Interface/lieback.dds",
    "distance-back": "Interface/dist_Back.dds",
    "overhead-back": "Interface/overheadInfoBackground.dds",
    "name-back": "Interface/name_Disp_back.dds",
    "aim-arrow": "Interface/aim/aim_arrow.dds",
    "uphill": "Interface/uphill.dds",
    "downhill": "Interface/downhill.dds",
    "ball-marker": "Interface/ballMarker.dds",
    "small-flag": "Interface/SmallFlag.dds",
    "scorecard": "ScoreCard/main_back.dds",
    "load-back": "Load/LoadBackground.dds",
    "load-bar": "Load/LoadBar.dds",
    "sun": "Lensflare/sun1.dds",
    "corona": "Lensflare/corona.dds",
    "flare1": "Lensflare/flare1.dds",
    "flare2": "Lensflare/flare2.dds",
    "flare3": "Lensflare/flare3.dds",
    "flare4": "Lensflare/flare4.dds",
    # render*.ini list "lflarea/lflareb.dds"; the shipped files are lflare1a/1b.
    "flare-a": "Lensflare/lflare1a.dds",
    "flare-b": "Lensflare/lflare1b.dds",
    "rainbow": "Lensflare/rainbow.dds",
    "ball-shadow": "Ball/Ballshad.dds",
    "hole-decal": "Ball/Hole.dds",
    "cup-interior": "Ball/CupInterior.dds",
    "cup-bottom": "Ball/CupBottom.dds",
    "logo-pebble": "End/PEBLOGO.dds",
}
# Images stored in power-of-two textures whose visible area is smaller.
CROPS = {"load-back": (0, 0, 1024, 768), "scorecard": (0, 0, 738, 444)}
# Club bag graphics, plain and highlighted ("On").
CLUBS = ["D1", "W2", "W3", "W4", "W5", "W7", "I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "PW", "SW", "LW", "Putter"]
for club in CLUBS:
    HUD_IMAGES[f"club-{club}"] = f"Bag/{club}.dds"
    HUD_IMAGES[f"club-{club}-on"] = f"Bag/{club}On.dds"
for index in range(1, 17):
    HUD_IMAGES[f"wind-{index:02d}"] = f"Interface/wind/wind{index:02d}.dds"


def convert(game_images: Path, output: Path) -> dict:
    entries, missing = [], []
    for name, relative in sorted(HUD_IMAGES.items()):
        source = game_images / relative
        if not source.is_file():
            missing.append(relative)
            continue
        dds = source.read_bytes()
        if len(dds) > 8 * 1024 * 1024:
            raise ValueError(f"{relative}: unexpectedly large DDS")
        width, height, rgba = decode_dds(dds)
        if name in CROPS:
            x0, y0, x1, y1 = CROPS[name]
            if x1 <= width and y1 <= height:
                rgba = b"".join(rgba[(row * width + x0) * 4:(row * width + x1) * 4] for row in range(y0, y1))
                width, height = x1 - x0, y1 - y0
        atomic_write(output / f"{name}.png", png_bytes(width, height, rgba))
        entries.append({"name": name, "source": f"DataImages/Game/{relative}", "width": width, "height": height,
                        "dds_sha256": hashlib.sha256(dds).hexdigest()})
    manifest = {"schema_version": 1, "images": entries, "missing": missing,
                "limitations": ["Original HUD art only; on-screen layout, fonts and animation of the original HUD are not decoded."]}
    atomic_write(output / "hud.json", (json.dumps(manifest, indent=2) + "\n").encode())
    return manifest


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", type=Path, default=root / "Library/SourceMedia/pga2005/install",
                        help="Extracted install tree containing DataImages/Game")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005/hud")
    args = parser.parse_args()
    manifest = convert(args.install / "DataImages/Game", args.output)
    print(f"HUD: {len(manifest['images'])} images, {len(manifest['missing'])} missing")


if __name__ == "__main__":
    main()
