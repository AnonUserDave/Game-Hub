#!/usr/bin/env python3
"""Prepare original course assets for the native lab from locally supplied media.

One command, standard Python only, no Windows installer/game execution. Source
and converted data remain in the Git-ignored local library.
"""
import argparse
import json
from pathlib import Path

from inspect_pga2005 import ISO9660, extract_media
from import_pga2005 import atomic_write, run_import
from decode_pga2005_terrain import decode
from decode_pga2005_library import decode_materials
from decode_pga2005_holes import decode_holes


def save_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2) + "\n").encode())


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=root / "Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip")
    parser.add_argument("--courses", nargs="+", choices=["AUS", "EDW", "FAN", "HAR", "JPN", "MON", "PBL", "SAW", "SHR", "STA", "TUR"], default=["PBL", "TUR"])
    args = parser.parse_args()
    media_dir = root / "Library/SourceMedia/pga2005"
    media = media_dir / "EA-TigerWoodsPGATour2005-CD3-CoursesDisc.B6I"
    if not media.exists():
        extract_media(args.archive, media_dir)
    iso = ISO9660(media)
    source_dir = media_dir / "disc3"
    try:
        wanted = {f"COURSES/{code}/{code}.{extension}" for code in args.courses for extension in ("TCR", "TCL", "INI")}
        found = set()
        for entry in iso.files():
            if entry["path"] in wanted:
                iso.inspect_file(entry, include_hash=True)
                iso.extract(entry, source_dir)
                found.add(entry["path"])
        if found != wanted:
            raise ValueError(f"Missing original course files: {sorted(wanted - found)}")
    finally:
        iso.close()
    images = run_import(media, root / "Library/Imported/pga2005")
    print(f"Imported {len(images['images'])} disc images and {len(images['courses'])} course INIs.")
    for code in args.courses:
        source = source_dir / "COURSES" / code
        output = root / "Library/Imported/pga2005" / code
        tcr = (source / f"{code}.TCR").read_bytes()
        terrain, report = decode(tcr)
        atomic_write(output / "terrain.ghpc", terrain)
        save_json(output / "terrain-report.json", report)
        used = {int(i) for i in report["material_triangle_counts"]}
        materials = decode_materials(tcr, [(source / f"{code}.TCL").read_bytes()], output, used)
        save_json(output / "materials.json", materials)
        holes = decode_holes(tcr, (source / f"{code}.INI").read_bytes())
        save_json(output / "holes.json", holes)
        print(f"{code}: {report['point_count']:,} vertices, {report['triangle_count']:,} triangles, {len(materials['materials'])} original materials, {holes['hole_count']} holes")


if __name__ == "__main__":
    main()
