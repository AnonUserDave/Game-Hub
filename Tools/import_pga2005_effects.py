#!/usr/bin/env python3
"""Convert the original PGA Tour 2005 shot-effect art for the native module.

anim.stn (decoded by Tools/decode_pga2005_cameras.py) triggers six effects:
divot (1), sand spray (2), water splash (3), tee (4), grass clippings (5) and
sand kick-up (8). Their sprites and meshes ship in the install tree; this
writes PNG sprites and a small numbers-only mesh file to the ignored
Library/Imported/pga2005/effects folder. The particle motion itself lives in
Engine.dll and is not decoded; the native module approximates it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import pga2005_xfile
from import_pga2005 import atomic_write, decode_dds, png_bytes

SPRITES = {
    "sand": "CoursesRoot/sand01.dds",
    "grass": "CoursesRoot/grass01.dds",
    "splash": "CoursesRoot/splash01.dds",
    "divot-mark": "Courses_-_Generic/divot_mark.dds",
    "divot": "Courses_-_Generic/divot01.dds",
}
# The source files carry no unit; the tee is 57 units tall with a 13-unit
# head (millimetres for a 2⅛ in tee) and divots 17 × 8 units (taken as
# centimetres for a typical iron divot). Both scales are native assumptions.
MESHES = {
    "tee": ("Courses_-_Generic/tee01.x", 0.001),
    "divot1": ("Courses_-_Generic/divot01.x", 0.01),
    "divot2": ("Courses_-_Generic/divot02.x", 0.01),
    "divot3": ("Courses_-_Generic/divot03.x", 0.01),
}


def mesh_record(data: bytes, meters_per_unit: float) -> dict:
    meshes = pga2005_xfile.parse(data).meshes()
    if len(meshes) != 1:
        raise ValueError("expected one mesh")
    arrays = meshes[0].render_arrays()
    positions = arrays["positions"]
    if not positions or len(positions) > 4096 or len(arrays["indices"]) % 3:
        raise ValueError("unexpected mesh size")
    return {"meters_per_unit": meters_per_unit,
            "positions": [round(c, 5) for p in positions for c in p],
            "normals": [round(c, 5) for n in arrays["normals"] for c in n],
            "uvs": [round(c, 5) for uv in arrays["uvs"] for c in uv],
            "indices": list(arrays["indices"]),
            "sha256": hashlib.sha256(data).hexdigest()}


def convert(install: Path, output: Path) -> dict:
    sprites, meshes, missing = {}, {}, []
    for name, relative in SPRITES.items():
        source = install / relative
        if not source.is_file():
            missing.append(relative)
            continue
        dds = source.read_bytes()
        if len(dds) > 4 * 1024 * 1024:
            raise ValueError(f"{relative}: unexpectedly large DDS")
        width, height, rgba = decode_dds(dds)
        atomic_write(output / f"{name}.png", png_bytes(width, height, rgba))
        sprites[name] = {"source": relative, "width": width, "height": height, "dds_sha256": hashlib.sha256(dds).hexdigest()}
    for name, (relative, scale) in MESHES.items():
        source = install / relative
        if not source.is_file():
            missing.append(relative)
            continue
        meshes[name] = {"source": relative, **mesh_record(source.read_bytes(), scale)}
    manifest = {"schema_version": 1, "sprites": sprites, "meshes": meshes, "missing": missing,
                "animations": {"1": "divot", "2": "sand spray", "3": "water splash", "4": "tee",
                               "5": "grass clippings", "8": "sand kick-up"},
                "limitations": ["Particle counts, speeds and lifetimes live in Engine.dll and are not decoded; mesh unit scales are assumptions."]}
    atomic_write(output / "effects.json", (json.dumps(manifest, indent=1) + "\n").encode())
    return manifest


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", type=Path, default=root / "Library/SourceMedia/pga2005/install")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005/effects")
    args = parser.parse_args(argv)
    manifest = convert(args.install, args.output)
    print(f"Effects: {len(manifest['sprites'])} sprites, {len(manifest['meshes'])} meshes, {len(manifest['missing'])} missing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
